import AppKit

/// iCloud Drive and File Provider items: Download Now brings them here, Remove Download frees their space (they stay in
/// the cloud), like Finder's context menu.
extension BrowserViewController {
    /// The selected items' cloud states (empty outside cloud folders).
    var selectedCloudStatuses: [CloudStatus] {
        selectedURLs.compactMap { CloudStore.shared.status(for: $0) }
    }

    var downloadableCloudURLs: [URL] {
        selectedURLs.filter { url in
            let status = CloudStore.shared.status(for: url)
            if status == .cloudOnly { return true }
            var info = stat()
            return status == .providerOnly && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }
    }

    @objc func downloadNow(_ sender: Any?) {
        let urls = downloadableCloudURLs
        guard !urls.isEmpty else { return }
        var failures: [(URL, Error)] = []
        let choices = urls.compactMap { url -> CloudActions.Download? in
            do { return try CloudActions.Download(url, status: CloudStore.shared.status(for: url)) }
            catch { failures.append((url, error)); return nil }
        }
        let capturedFailures = failures
        Task { [weak self, weak window = view.window] in
            let failures = capturedFailures + (await CloudActions.download(choices))
            if let self, let window, self.view.window === window, window.isVisible, !failures.isEmpty {
                Self.report(failures.map { (url: $0.0, error: $0.1) }, .download, in: window)
            }
            CloudStore.shared.refresh(Set(urls.map { $0.deletingLastPathComponent() }))
        }
    }

    @objc func removeDownload(_ sender: Any?) {
        let urls = CloudActions.removable(selectedURLs) { CloudStore.shared.status(for: $0) }
        guard !urls.isEmpty else { return }
        let failures = CloudActions.removeDownload(urls)
        if !failures.isEmpty { Self.report(failures.map { (url: $0.0, error: $0.1) }, .removeDownload, in: view.window) }
        CloudStore.shared.refresh(Set(urls.map { $0.deletingLastPathComponent() }))
    }
}
