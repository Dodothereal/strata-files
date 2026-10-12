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
}
