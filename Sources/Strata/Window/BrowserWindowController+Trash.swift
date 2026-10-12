import AppKit

extension BrowserWindowController {
    /// Go ▸ Trash: your Trash on the startup disk.
    @objc func goTrash(_ sender: Any?) {
        navigate(to: Trash.home)
    }
}

extension BrowserWindowController {
    /// Under the toolbar while a Trash is shown: other disks keep their own Trash, so say when they hold something too.
    func updateNotice(for url: URL) {
        guard Trash.isTrash(url) else { return split.noticeBar.hide() }
        split.noticeBar.hide()
        Task { [weak self] in
            let others = await Trash.contents().filter { $0.count > 0 && $0.folder.standardizedFileURL != url.standardizedFileURL }
            guard let self, case .folder(let shown) = destination, shown == url, let first = others.first else { return }
            let text = others.count == 1
                ? "“\(first.disk)” has \(Format.count(first.count, "more item", "more items")) in its own Trash."
                : "Other disks have items in their own Trash: "
                    + ListFormatter.localizedString(byJoining: others.map { "“\($0.disk)” (\($0.count.formatted()))" }) + "."
            split.noticeBar.show(symbol: "externaldrive", text: text, button: "Show “\(first.disk)”") { [weak self] in
                self?.navigate(to: first.folder)
            }
        }
    }
}
