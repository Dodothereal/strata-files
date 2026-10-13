import AppKit
import Quartz

/// A container's files (see `ContainerCopies`): what's selected is fetched as you select it, so Quick Look, dragging and
/// copying have the real file; opening waits for it. Larger files are fetched when they're opened or copied.
extension BrowserViewController {
    /// Selected files up to this size are fetched right away.
    static let containerAutoFetchLimit: Int64 = 256 << 20

    /// The containers selected in a Containers folder.
    var selectedContainers: [ContainerInfo] {
        selectedURLs.compactMap { url in
            guard let (source, top) = ContainerCopies.copy(containing: url), top.standardizedFileURL == url.standardizedFileURL else { return nil }
            return ContainerStore.shared.container(id: source.id)
        }
    }

    /// Context menu and palette: does the menu item's action (`representedObject`, an action's name) to the selection.
    @objc func containerAction(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let action = ContainerAction(rawValue: raw) else { return }
        ContainerControl.run(action, on: selectedContainers, in: view.window)
    }

    /// Open in Terminal, in a container's files: a shell in the container, in the folder shown (or at `/` for a
    /// container selected in the Containers folder). False outside containers.
    func openTerminalInContainer() -> Bool {
        guard let engine = ContainerStore.shared.engine else {
            // Never a shell on this Mac in Strata's copy.
            guard directory.map(ContainerCopies.contains) == true else { return false }
            NSSound.beep()
            return true
        }
        if let container = selectedContainers.first {
            if !ContainerControl.openTerminal(in: container, at: "/", engine: engine) { NSSound.beep() }
            return true
        }
        let selected = selectedEntries
        let folder = selected.count == 1 && selected[0].isFolder ? selected[0].url : targetDirectory
        guard let folder, let (source, top) = ContainerCopies.copy(containing: folder) else {
            // The Containers folder itself: there's no container to open a shell in.
            guard directory.map(ContainerCopies.contains) == true else { return false }
            NSSound.beep()
            return true
        }
        let path = ContainerCopies.containerPath(of: folder.resolvingSymlinksInPath(), top: top) ?? "/"
        guard let container = ContainerStore.shared.container(id: source.id),
              ContainerControl.openTerminal(in: container, at: path, engine: engine) else {
            NSSound.beep()
            return true
        }
        return true
    }

    /// Whether Open in Terminal can open a shell in the container shown (or selected): it has to be running.
    var canOpenTerminalInContainer: Bool? {
        if let container = selectedContainers.first { return container.isRunning }
        guard let directory, ContainerCopies.contains(directory) else { return nil }
        guard let (source, _) = ContainerCopies.copy(containing: directory) else { return false }
        return ContainerStore.shared.container(id: source.id)?.isRunning == true
    }

    /// Starts fetching the selected files that are still placeholders (a few, up to a size: Select All doesn't read a
    /// whole folder). A new selection stops the last one's.
    func fetchSelectedContainerFiles() {
        containerFetch?.cancel()
        containerFetch = nil
        guard let directory, ContainerCopies.contains(directory) else { return }
        let files = selectedEntries.filter { !$0.isDirectory }
        guard files.count <= 20 else { return }
        let urls = files.map(\.url).filter(ContainerCopies.isPlaceholder)
        guard !urls.isEmpty else { return }
        containerFetch = Task { await ContainerFiles.shared.fetchSelection(urls, limit: Self.containerAutoFetchLimit) }
    }

    /// Runs `action` once `urls` (the placeholders among them) are fetched; says what went wrong if they can't be. A big
    /// fetch shows in Transfers, with a Stop button.
    func afterFetching(_ urls: [URL], _ action: @escaping () -> Void) {
        let pending = urls.filter(ContainerCopies.isPlaceholder)
        guard !pending.isEmpty else { return action() }
        let bytes = pending.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        if bytes > 8 << 20 { return TransferQueue.shared.add(ContainerFetchJob(pending, then: action)) }
        Task {
            do {
                try await ContainerFiles.shared.fetch(pending)
                // Still not here (it changed in the container meanwhile, say): say so rather than open nothing.
                guard !pending.contains(where: ContainerCopies.isPlaceholder) else { throw ContainerAPIError.notFound }
                action()
            } catch {
                let source = pending.first.flatMap { ContainerCopies.copy(containing: $0)?.source }
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(pending[0].lastPathComponent)” couldn’t be read from its container.",
                                           comment: "A file in a container couldn't be fetched")
                alert.informativeText = source.map { ContainerFiles.message(for: error, source: $0) } ?? error.localizedDescription
                Self.present(alert, in: view.window) { _ in }
            }
        }
    }

    /// Containers started, stopped, came or went: the Containers folder follows (and its icons, which show who runs).
    @objc func containersChanged() {
        guard let directory else { return }
        if ContainerCopies.engineFolder(directory) != nil {
            reloadFolder(nil)
            reloadVisibleCells()
            return
        }
        // Inside a container that was made again under its name (`compose up`): its files are the old one's, so back to
        // Containers, where it starts over.
        let store = ContainerStore.shared
        if store.engine != nil, let (source, top) = ContainerCopies.copy(containing: directory), store.container(id: source.id) == nil,
           store.containers.contains(where: { $0.name == source.name }) {
            delegate?.browser(self, navigateTo: top.deletingLastPathComponent())
        }
    }

    /// Files arrived from a container: rows show their thumbnails, Quick Look shows what it couldn't before.
    @objc func containerFilesFetched(_ notification: Notification) {
        guard let urls = notification.object as? [URL], let directory, ContainerCopies.contains(directory) else { return }
        // This folder or one below it (columns, folders expanded in the list).
        let shown = [directory.standardizedFileURL.path, directory.resolvingSymlinksInPath().standardizedFileURL.path]
        guard urls.contains(where: { url in shown.contains { url.standardizedFileURL.path.hasPrefix($0 + "/") } }) else { return }
        reloadVisibleCells()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.refreshCurrentPreviewItem()
        }
    }
}
