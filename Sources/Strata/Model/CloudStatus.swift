import Foundation

/// iCloud Drive and File Provider (Dropbox, OneDrive, Google Drive…) state of an item: in the cloud only, on its way
/// down or up, or here. Read only for items in such folders, so ordinary folders pay nothing.
nonisolated enum CloudStatus: Sendable, Equatable {
    /// Only in the cloud (Download Now brings it here).
    case cloudOnly
    case downloading
    case uploading
    /// Here, not uploaded yet (its download can't be removed until it is).
    case waitingToUpload
    /// Here, and in the cloud (Remove Download frees the space).
    case downloaded

    static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey,
    ]

    /// The item's state, or nil when it isn't a cloud item.
    static func read(_ url: URL) -> CloudStatus? {
        // A fresh URL: resource values are cached per URL object, and these change while you watch.
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: keys), values.isUbiquitousItem == true else { return nil }
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded { return .cloudOnly }
        if values.ubiquitousItemIsUploaded == false { return .waitingToUpload }
        return .downloaded
    }

    /// Whether `folder` holds cloud items: iCloud Drive, a File Provider folder (`~/Library/CloudStorage`), or anything
    /// the system reports as ubiquitous.
    static func isCloudFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Library/Mobile Documents") || path.hasPrefix(home + "/Library/CloudStorage") { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    var symbolName: String {
        switch self {
        case .cloudOnly: "icloud"
        case .downloading: "icloud.and.arrow.down"
        case .uploading, .waitingToUpload: "icloud.and.arrow.up"
        case .downloaded: "checkmark.icloud"
        }
    }

    var label: String {
        switch self {
        // Neutral words: the same states appear in Dropbox, OneDrive and Google Drive folders.
        case .cloudOnly: String(localized: "Only in the cloud", comment: "Cloud status of an item")
        case .downloading: String(localized: "Downloading", comment: "Cloud status of an item")
        case .uploading: String(localized: "Uploading", comment: "Cloud status of an item")
        case .waitingToUpload: String(localized: "Waiting to upload", comment: "Cloud status of an item")
        case .downloaded: String(localized: "Downloaded", comment: "Cloud status of an item: here and in the cloud")
        }
    }

    /// Whether it's mid-transfer (worth checking again soon).
    var isActive: Bool { self == .downloading || self == .uploading || self == .waitingToUpload }
}

/// Asks the cloud provider to bring items here, or to free their space (they stay in the cloud). Each returns the items
/// it couldn't ask about, with why (an item not uploaded yet can't have its download removed).
enum CloudActions {
    static func download(_ urls: [URL]) -> [(URL, Error)] {
        urls.compactMap { url in
            do { try FileManager.default.startDownloadingUbiquitousItem(at: url) } catch { return (url, error) }
            return nil
        }
    }

    static func removeDownload(_ urls: [URL]) -> [(URL, Error)] {
        urls.compactMap { url in
            do { try FileManager.default.evictUbiquitousItem(at: url) } catch { return (url, error) }
            return nil
        }
    }
}

extension Notification.Name {
    /// Cloud states were read (or changed) for items in a shown folder; visible cells redraw their badges.
    static let cloudStatusChanged = Notification.Name("StrataCloudStatusChanged")
}

/// The cloud states of the items in the folders being shown, read off the main thread and only for cloud folders (others
/// cost one check per folder). Folders a window shows are kept; while anything in them is moving, they're read again
/// every couple of seconds, so badges follow the transfer.
final class CloudStore {
    static let shared = CloudStore()

    private var statuses: [String: CloudStatus] = [:]
    /// Cloud folders read, most recently loaded last.
    private var folders: [String] = []
    private var items: [String: [String]] = [:]
    private var poll: Timer?
    /// Folders to read again for a few rounds after Download Now or Remove Download (the change may take a moment to
    /// start), with the rounds left.
    private var forced: [String: Int] = [:]
    /// Past this many folders, the least recently loaded that no window shows are forgotten.
    private static let keptFolders = 48

    func status(for url: URL) -> CloudStatus? {
        statuses[url.standardizedFileURL.path]
    }

    /// Reads the states of `urls`, the items of `folder`, when it's a cloud folder.
    func load(_ urls: [URL], in folder: URL) {
        let key = folder.standardizedFileURL.path
        Task {
            guard let (paths, read) = await Self.read(urls, in: key) else {
                if items[key] != nil { forget(key) }
                return
            }
            remember(key, paths: paths, read)
        }
    }

    /// Reads these folders again (after Download Now or Remove Download), and keeps reading them for a while.
    func refresh(_ folders: Set<URL>) {
        for folder in folders {
            let key = folder.standardizedFileURL.path
            guard items[key] != nil else { continue }
            forced[key] = 5
            readAgain(key)
        }
    }

    private func remember(_ key: String, paths: [String], _ read: [String: CloudStatus]) {
        let previous = items[key] ?? []
        let changed = previous != paths || paths.contains { statuses[$0] != read[$0] }
        for path in previous { statuses[path] = nil }
        for (path, status) in read { statuses[path] = status }
        items[key] = paths
        folders.removeAll { $0 == key }
        folders.append(key)
        trim()
        if changed { NotificationCenter.default.post(name: .cloudStatusChanged, object: nil) }
        schedulePoll()
    }

    /// Forgets the oldest folders no window shows, past the limit.
    private func trim() {
        guard folders.count > Self.keptFolders else { return }
        let shown = BrowserWindowController.foldersShown()
        for key in folders where folders.count > Self.keptFolders && !shown.contains(key) { forget(key) }
    }

    private func forget(_ key: String) {
        for path in items.removeValue(forKey: key) ?? [] { statuses[path] = nil }
        folders.removeAll { $0 == key }
        forced[key] = nil
    }

    /// Polls while a transfer is under way in a shown folder, or one was just asked for.
    private func schedulePoll() {
        guard poll == nil, !foldersToPoll().isEmpty else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFired() }
        }
    }

    private func foldersToPoll() -> [String] {
        let shown = BrowserWindowController.foldersShown()
        return folders.filter { key in
            forced[key] != nil || shown.contains(key) && items[key]?.contains { statuses[$0]?.isActive == true } == true
        }
    }

    private func pollFired() {
        poll = nil
        for key in foldersToPoll() {
            if let rounds = forced[key] { forced[key] = rounds > 1 ? rounds - 1 : nil }
            readAgain(key)
        }
    }

    private func readAgain(_ key: String) {
        guard let paths = items[key] else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        Task {
            guard let (_, read) = await Self.read(urls, in: key), items[key] == paths else { return }
            remember(key, paths: paths, read)
        }
    }

    /// The paths of `urls` and their states, or nil when `folder` isn't a cloud folder (checked first: ordinary
    /// folders cost nothing more).
    @concurrent
    private static func read(_ urls: [URL], in folder: String) async -> (paths: [String], statuses: [String: CloudStatus])? {
        guard CloudStatus.isCloudFolder(URL(fileURLWithPath: folder)) else { return nil }
        let paths = urls.map { $0.standardizedFileURL.path }
        var result: [String: CloudStatus] = [:]
        for path in paths {
            if let status = CloudStatus.read(URL(fileURLWithPath: path)) { result[path] = status }
        }
        return (paths, result)
    }
}
