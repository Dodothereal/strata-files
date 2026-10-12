import AppKit

/// iCloud Drive and File Provider items: Download Now brings them here, Remove Download frees their space (they stay in
/// the cloud), like Finder's context menu.
extension BrowserViewController {
    /// The selected items' cloud states (empty outside cloud folders).
    var selectedCloudStatuses: [CloudStatus] {
        selectedURLs.compactMap { CloudStore.shared.status(for: $0) }
    }

    @objc func downloadNow(_ sender: Any?) {
        let urls = selectedURLs.filter { CloudStore.shared.status(for: $0) == .cloudOnly }
        guard !urls.isEmpty else { return }
        let failures = CloudActions.download(urls)
        if !failures.isEmpty { Self.report(failures.map { (url: $0.0, error: $0.1) }, title: "couldn’t be downloaded", in: view.window) }
        CloudStore.shared.refresh(Set(urls.map { $0.deletingLastPathComponent() }))
    }

    @objc func removeDownload(_ sender: Any?) {
        let urls = selectedURLs.filter { CloudStore.shared.status(for: $0) == .downloaded }
        guard !urls.isEmpty else { return }
        let failures = CloudActions.removeDownload(urls)
        if !failures.isEmpty {
            let title = failures.count == 1 ? "couldn’t have its download removed" : "couldn’t have their downloads removed"
            Self.report(failures.map { (url: $0.0, error: $0.1) }, title: title, in: view.window)
        }
        CloudStore.shared.refresh(Set(urls.map { $0.deletingLastPathComponent() }))
    }
}
