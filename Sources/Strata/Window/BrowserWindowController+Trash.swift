import AppKit

extension BrowserWindowController {
    /// Go ▸ Trash: your Trash on the startup disk.
    @objc func goTrash(_ sender: Any?) {
        navigate(to: Trash.home)
    }

    /// Go ▸ Connect to Server…: mounts a share (macOS asks for the login), then shows it.
    @objc func connectToServer(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let controller = ConnectToServerController()
        controller.onConnected = { [weak self] mounted in self?.navigate(to: mounted) }
        contentViewController?.presentAsSheet(controller)
    }
}

extension BrowserWindowController {
    /// Under the toolbar: inside an archive opened as a folder, say so; while a Trash is shown, say when other disks'
    /// Trashes hold something too (each disk keeps its own).
    func updateNotice(for url: URL) {
        if let engine = ContainerCopies.engineFolder(url) {
            return split.noticeBar.show(symbol: "shippingbox",
                                        text: String(localized: "Containers on \(engine.name). Each opens as a read-only copy of its files.",
                                                     comment: "Notice over the Containers folder; placeholder: Docker Desktop, OrbStack…"),
                                        button: String(localized: "Reload", comment: "Button: read a container's folder again")) { [weak self] in
                self?.browser.reloadFolder(nil)
            }
        }
        if let (source, _) = ContainerCopies.copy(containing: url) {
            return split.noticeBar.show(symbol: "shippingbox",
                                        text: String(localized: "Files in “\(source.name)” on \(source.engineName): a read-only copy, read from the container as you browse.",
                                                     comment: "Notice over a container's files; placeholders: the container, then its engine (Docker Desktop, OrbStack…)"),
                                        button: String(localized: "Reload", comment: "Button: read a container's folder again")) { [weak self] in
                self?.browser.reloadFolder(nil)
            }
        }
        if let (archive, _) = ArchiveCache.archive(containing: url) {
            return split.noticeBar.show(symbol: "archivebox",
                                        text: String(localized: "Inside “\(archive.lastPathComponent)”, a read-only copy. Copy things out to keep them."),
                                        button: String(localized: "Extract All")) { [weak self] in
                self?.browser.extractArchive(archive)
            }
        }
        guard Trash.isTrash(url) else { return split.noticeBar.hide() }
        split.noticeBar.hide()
        Task { [weak self] in
            let others = await Trash.contents().filter { $0.count > 0 && $0.folder.standardizedFileURL != url.standardizedFileURL }
            guard let self, case .folder(let shown) = destination, shown == url, let first = others.first else { return }
            let text: String
            if others.count == 1 {
                text = String(localized: "“\(first.disk)” has \(first.count) more items in its own Trash.", comment: "plural")
            } else {
                let disks = ListFormatter.localizedString(byJoining: others.map {
                    String(localized: "“\($0.disk)” (\($0.count.formatted()))", comment: "A disk and how many items its Trash holds")
                })
                text = String(localized: "Other disks have items in their own Trash: \(disks).", comment: "A list of disks with their item counts")
            }
            split.noticeBar.show(symbol: "externaldrive", text: text,
                                 button: String(localized: "Show “\(first.disk)”", comment: "Button: show that disk's Trash")) { [weak self] in
                self?.navigate(to: first.folder)
            }
        }
    }

    /// A container's folder couldn't be read: say why, over the folder (if it's the one shown).
    @objc func containerCopyProblem(_ notification: Notification) {
        guard case .folder(let shown) = destination, let folder = notification.userInfo?["folder"] as? URL,
              let message = notification.userInfo?["message"] as? String else { return }
        // The folder shown, or one below it (a column, a folder expanded in the list).
        let shownPath = shown.resolvingSymlinksInPath().standardizedFileURL.path, problem = folder.standardizedFileURL.path
        guard problem == shownPath || problem.hasPrefix(shownPath + "/") else { return }
        split.noticeBar.show(symbol: "exclamationmark.triangle", text: message,
                             button: String(localized: "Try Again", comment: "Button: read a container's folder again")) { [weak self] in
            guard let self else { return }
            updateNotice(for: shown)
            browser.reloadFolder(nil)
        }
    }
}
