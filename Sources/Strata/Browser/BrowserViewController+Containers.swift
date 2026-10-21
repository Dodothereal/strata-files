import AppKit

/// Container-specific controls and shells. Shared file fetching belongs to the window's copy providers.
extension BrowserViewController {
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
        if isStackContext { return !stackProjectFolders().isEmpty }
        if let container = selectedContainers.first { return container.isRunning }
        guard let directory, ContainerCopies.contains(directory) else { return nil }
        guard let (source, _) = ContainerCopies.copy(containing: directory) else { return false }
        return ContainerStore.shared.container(id: source.id)?.isRunning == true
    }

    /// Containers started, stopped, came or went: the Containers folder follows (and its icons, which show who runs).
    @objc func containersChanged() {
        guard let directory else { return }
        if ContainerCopies.engineFolder(directory) != nil || ContainerCopies.isStack(directory) {
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

}
