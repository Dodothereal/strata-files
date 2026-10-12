import AppKit

/// Inside the Trash: Put Back (⌘⌫ there, like Finder), and Delete Immediately anywhere.
extension BrowserViewController {
    /// Whether this pane (its active column, in Columns) shows a Trash folder, not search results.
    var isShowingTrash: Bool {
        !isShowingResults && targetDirectory.map(Trash.isTrash) == true
    }

    /// The selected items that sit directly in a Trash.
    var selectedTrashItems: [URL] {
        selectedURLs.filter(Trash.contains)
    }

    /// Moves the selected items back to where they were trashed from: undoable, recorded in History, and asking before
    /// replacing anything that took their place. Folders removed since are made again, like Finder does, and undo
    /// removes them again. Items whose origin isn't known stay, with a note.
    @objc func putBack(_ sender: Any?) {
        // While another folder loads, the selection is the previous folder's.
        guard !isLoadingFolder else { return }
        let items = selectedTrashItems
        guard !items.isEmpty else { return }
        let undo = undoManager, window = view.window
        Task { [weak self] in
            let locations = await Trash.originalLocations(of: items)
            var moves: [TransferMove] = []
            var made: [URL] = []
            var failures: [(url: URL, error: Error)] = []
            for item in items {
                guard let original = locations[item] else { continue }
                let folder = original.deletingLastPathComponent().standardizedFileURL
                if !TransferEngine.exists(folder) {
                    let missing = Self.missingFolders(down: folder)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        made += missing
                    } catch {
                        failures.append((item, error))
                        continue
                    }
                }
                moves.append(TransferMove(from: item, to: original))
            }
            if !moves.isEmpty {
                let job = TransferQueue.shared.enqueue(moves: moves, mode: .move, undo: undo, conflicts: .sheet(for: window),
                                                       actionName: "Put Back", containers: made)
                // Stopped or skipped at the conflict sheet: folders made for nothing go again.
                job.onFinish = { _ in Self.removeIfEmpty(made) }
            }
            let unknown = items.filter { locations[$0] == nil }
            if !unknown.isEmpty { self?.explainUnknownOrigin(unknown) }
            if !failures.isEmpty { Self.report(failures, title: "couldn’t be put back", in: window) }
        }
    }

    /// Deletes the selection for good, skipping the Trash, after asking (Finder's ⌥⌘⌫).
    @objc func deleteImmediately(_ sender: Any?) {
        guard !isLoadingFolder else { return }
        Self.confirmDelete(selectedURLs, in: view.window) { [weak self] in self?.refresh() }
    }

    /// Asks, then deletes `urls` for good. `noTrash`: they were headed for the Trash, but their disk has none.
    ///
    /// Disks, and items in folders you can't change, are refused up front: deleting one would remove its contents before
    /// failing on the item itself. Items inside other selected items are left to their parent. Everything else is
    /// tried, and whatever couldn't be deleted is listed.
    static func confirmDelete(_ urls: [URL], in window: NSWindow?, noTrash: Bool = false, then done: @escaping () -> Void) {
        var refused: [URL] = []
        let candidates = outermost(urls).filter { url in
            let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
            let changeable = access(url.deletingLastPathComponent().path, W_OK) == 0
            if isVolume || !changeable { refused.append(url) }
            return !isVolume && changeable
        }
        guard let first = candidates.first else {
            if let item = refused.first {
                let alert = NSAlert()
                alert.messageText = refused.count == 1 ? "“\(item.lastPathComponent)” can’t be deleted."
                                                       : "These \(refused.count.formatted()) items can’t be deleted."
                alert.informativeText = "Disks, and items in folders you don’t have permission to change, can’t be deleted here."
                present(alert, in: window) { _ in }
            }
            return
        }
        let alert = NSAlert()
        if noTrash {
            alert.messageText = candidates.count == 1 ? "“\(first.lastPathComponent)” will be deleted immediately."
                                                      : "These \(candidates.count.formatted()) items will be deleted immediately."
            alert.informativeText = (candidates.count == 1 ? "Its disk has no Trash." : "Their disk has no Trash.")
                + " You can’t undo this action."
        } else {
            alert.messageText = candidates.count == 1 ? "Delete “\(first.lastPathComponent)” immediately?"
                                                      : "Delete these \(candidates.count.formatted()) items immediately?"
            alert.informativeText = "You can’t undo this action."
        }
        if !refused.isEmpty {
            alert.informativeText += " \(Format.count(refused.count, "item", "items")) can’t be deleted and will stay."
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                let failures = await deleteAll(candidates)
                if candidates.contains(where: Trash.isInTrash) { NotificationCenter.default.post(name: .trashChanged, object: nil) }
                done()
                if !failures.isEmpty { report(failures, title: "couldn’t be deleted", in: window) }
            }
        }
    }

    /// Lists items that failed: the first few, each with why.
    static func report(_ failures: [(url: URL, error: Error)], title: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = failures.count == 1 ? "“\(failures[0].url.lastPathComponent)” \(title)."
                                                : "\(failures.count.formatted()) items \(title)."
        var lines = failures.prefix(5).map { "\($0.url.lastPathComponent): \($0.error.localizedDescription)" }
        if failures.count > 5 { lines.append("and \((failures.count - 5).formatted()) more") }
        alert.informativeText = lines.joined(separator: "\n")
        present(alert, in: window) { _ in }
    }

    /// As a sheet when the window can take one, else as a dialog.
    static func present(_ alert: NSAlert, in window: NSWindow?, then handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    // MARK: - Private

    private func explainUnknownOrigin(_ items: [URL]) {
        guard let first = items.first else { return }
        let alert = NSAlert()
        // Finder notes where things came from only a while later, so anything it trashed moments ago isn't known yet.
        if items.count == 1 {
            alert.messageText = "Strata doesn’t know where “\(first.lastPathComponent)” came from."
            alert.informativeText = "Where it was isn’t recorded. If Finder moved it to the Trash moments ago, use Put Back "
                + "in Finder, or try again in a few minutes. You can also drag it where you want."
        } else {
            alert.messageText = "Strata doesn’t know where \(items.count.formatted()) of these items came from."
            alert.informativeText = "Where they were isn’t recorded. If Finder moved them to the Trash moments ago, use Put "
                + "Back in Finder, or try again in a few minutes. You can also drag them where you want."
        }
        Self.present(alert, in: view.window) { _ in }
    }

    /// `urls` without those inside another of them.
    private static func outermost(_ urls: [URL]) -> [URL] {
        let paths = urls.map { $0.standardizedFileURL.path }.sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in paths where !kept.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
            kept.append(path)
        }
        return kept.map { URL(fileURLWithPath: $0) }
    }

    /// The folders that don't exist yet on the way down to `folder`, outermost first.
    private static func missingFolders(down folder: URL) -> [URL] {
        var missing: [URL] = []
        var current = folder
        while current.path != "/", !TransferEngine.exists(current) {
            missing.insert(current, at: 0)
            current.deleteLastPathComponent()
        }
        return missing
    }

    private static func removeIfEmpty(_ folders: [URL]) {
        for folder in folders.reversed() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: folder) }
        }
    }

    @concurrent
    private static func deleteAll(_ urls: [URL]) async -> [(url: URL, error: Error)] {
        var failures: [(url: URL, error: Error)] = []
        for url in urls {
            do { try FileManager.default.removeItem(at: url) } catch { failures.append((url, error)) }
        }
        return failures
    }
}
