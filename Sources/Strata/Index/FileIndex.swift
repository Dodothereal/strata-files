import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Entries or sizes changed (posted at most a few times per second).
    static let indexDidChange = Notification.Name("StrataIndexDidChange")
    static let indexPhaseDidChange = Notification.Name("StrataIndexPhaseDidChange")
}

/// The app's view of the file index: instant folder sizes and search across the home folder and Applications.
final class FileIndex {
    static let shared = FileIndex()

    private(set) var phase: IndexWorker.Phase = .loading
    private var store: IndexStore?
    private let worker = IndexWorker()
    private var started = false
    private var changePosted = false

    var isReady: Bool { store != nil }

    func start() {
        guard !started else { return }
        started = true
        worker.onStore = { store in Task { @MainActor in FileIndex.shared.store = store } }
        worker.onPhase = { phase in Task { @MainActor in FileIndex.shared.setPhase(phase) } }
        worker.onChange = { Task { @MainActor in FileIndex.shared.changed() } }
        worker.start(Self.currentConfig())
    }

    /// Re-evaluates what may be indexed (after Full Disk Access changes or a protected folder was opened).
    func refreshConfig() {
        guard started else { return }
        worker.update(Self.currentConfig())
    }

    /// Number of entries, including ones deleted since the last full scan.
    var itemCount: Int { store?.read { store?.count ?? 0 } ?? 0 }

    func rebuild() {
        guard started else { return }
        worker.rebuildNow()
    }

    func saveNow() {
        guard started else { return }
        worker.saveNow()
    }

    private func setPhase(_ phase: IndexWorker.Phase) {
        self.phase = phase
        NotificationCenter.default.post(name: .indexPhaseDidChange, object: self)
        if phase == .ready { changed() }
    }

    private func changed() {
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.changePosted = false
            NotificationCenter.default.post(name: .indexDidChange, object: self)
        }
    }

    // MARK: - Queries

    /// Total size and file count of a folder, if it's indexed.
    func folderSize(_ url: URL) -> FolderSize? {
        guard let store else { return nil }
        let path = url.standardizedFileURL.path
        return store.read {
            guard let id = store.lookup(path), store.isDirectory(id), !isExcludedLocked(store, id) else { return nil }
            return FolderSize(bytes: store.size[Int(id)], files: Int(store.fileCount[Int(id)]))
        }
    }

    /// Excluded folders are present as entries but never descended into, so their size would read as zero.
    private func isExcludedLocked(_ store: IndexStore, _ id: Int32) -> Bool {
        store.firstChild[Int(id)] < 0 && store.size[Int(id)] == 0 && excludedPaths.contains(store.path(of: id))
    }

    func search(_ text: String, in scope: URL? = nil, limit: Int = 500) async -> (hits: [IndexHit], total: Int)? {
        guard let store else { return nil }
        var query = IndexQuery.parse(text)
        if let scope { query.scopePath = scope.standardizedFileURL.path }
        guard !query.isEmpty else { return ([], 0) }
        return await Self.run(query, store, limit)
    }

    /// Like `search`, but plain English is understood too; returns how it was interpreted when it was.
    func understand(_ text: String, in scope: URL? = nil, limit: Int = 500) async -> (hits: [IndexHit], total: Int, interpretation: SearchFilter?)? {
        guard let store else { return nil }
        guard let interpreted = NaturalQuery.interpret(text) else {
            return await search(text, in: scope, limit: limit).map { ($0.hits, $0.total, nil) }
        }
        var query = interpreted.query
        if let scope { query.scopePath = scope.standardizedFileURL.path }
        let result = await Self.run(query, store, limit)
        return (result.hits, result.total, interpreted.filter)
    }

    func recentFiles(days: Int = 7, limit: Int = 400) async -> [IndexHit]? {
        guard let store else { return nil }
        let since = UInt32(max(0, Date().timeIntervalSince1970 - Double(days) * 86_400))
        return await Self.recent(store, since, limit)
    }

    /// Duplicate files of at least `minSize`, largest savings first. `progress` reports (done, total) size groups.
    func duplicates(minSize: Int64 = 1_000_000, progress: @escaping @Sendable (Int, Int) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async -> [DuplicateGroup]? {
        guard let store else { return nil }
        return await Self.findDuplicates(store, minSize, progress, isCancelled)
    }

    @concurrent
    private nonisolated static func findDuplicates(_ store: IndexStore, _ minSize: Int64, _ progress: @escaping @Sendable (Int, Int) -> Void,
                                                   _ isCancelled: @escaping @Sendable () -> Bool) async -> [DuplicateGroup] {
        let candidates = DuplicateFinder.candidates(in: store, minSize: minSize)
        return DuplicateFinder.find(candidates, progress: progress, isCancelled: isCancelled)
    }

    @concurrent
    private nonisolated static func run(_ query: IndexQuery, _ store: IndexStore, _ limit: Int) async -> (hits: [IndexHit], total: Int) {
        IndexSearch.run(query, in: store, limit: limit)
    }

    @concurrent
    private nonisolated static func recent(_ store: IndexStore, _ since: UInt32, _ limit: Int) async -> [IndexHit] {
        IndexSearch.recent(in: store, since: since, limit: limit)
    }

    // MARK: - Configuration

    private var excludedPaths: Set<String> = []

    private static func currentConfig() -> IndexConfig {
        let home = realPath(Places.home.path)
        var excluded: Set<String> = []
        if !Privacy.hasFullDiskAccess {
            // Reading these without Full Disk Access pops a consent prompt (or reads other apps' data);
            // folders you've opened in Strata are already allowed.
            for relative in ["Desktop", "Documents", "Downloads", "Library/Containers", "Library/Group Containers",
                             "Library/Mobile Documents", "Pictures/Photos Library.photoslibrary", ".Trash"] {
                let path = home + "/" + relative
                if !Privacy.isKnownAccessible(path) { excluded.insert(path) }
            }
        }
        // The encrypted index replaces the plain index.bin of earlier builds.
        SecureStorage.removeLegacy(SecureStorage.url("index.bin"))
        let config = IndexConfig(roots: [home, "/Applications"], excluded: excluded,
                                 noise: [home + "/Library"], file: SecureStorage.url("index.sealed"))
        shared.excludedPaths = excluded
        return config
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension FileEntry {
    /// An entry built from an index hit, without touching the disk.
    init(hit: IndexHit) {
        let url = URL(fileURLWithPath: hit.path, isDirectory: hit.isDirectory)
        let type = hit.isDirectory && !hit.isPackage ? UTType.folder : UTType(filenameExtension: url.pathExtension)
        self.init(url: url, name: url.lastPathComponent, isDirectory: hit.isDirectory, isPackage: hit.isPackage,
                  isHidden: url.lastPathComponent.hasPrefix("."), isSymlink: false, isVolume: false,
                  size: hit.isDirectory ? nil : hit.size,
                  modified: Date(timeIntervalSince1970: TimeInterval(hit.mtime)), created: nil, added: nil,
                  kind: hit.isDirectory && !hit.isPackage ? "Folder"
                      : FileEntry.kind(extension: url.pathExtension, isDirectory: hit.isDirectory, isPackage: hit.isPackage,
                                       size: hit.size, system: type?.localizedDescription),
                  contentType: type)
    }
}
