import Foundation

/// One directory entry as read by the scanner, before it gets an id.
nonisolated struct ScannedItem: Sendable {
    var nameOffset: Int
    var nameLength: Int
    var isDirectory: Bool
    var isPackage: Bool
    var isSymlink: Bool
    var isHidden: Bool
    var isMountPoint: Bool
    var size: Int64
    var mtime: UInt32
}

/// Every file and folder under the indexed roots, stored column by column so millions of entries stay compact
/// (about 35 bytes plus the name each) and fast to scan.
///
/// Children always get larger ids than their parent, which lets folder sizes be summed in one reverse pass.
/// Deleted entries are flagged rather than removed; ids stay stable until the next full rebuild.
/// Thread safety: a readers–writer lock; use `read` and `write` around any access.
nonisolated final class IndexStore: @unchecked Sendable {
    enum Flag {
        static let directory: UInt8 = 1 << 0
        static let package: UInt8 = 1 << 1
        static let symlink: UInt8 = 1 << 2
        static let hidden: UInt8 = 1 << 3
        /// Inside build output, caches, VCS internals or ~/Library: indexed for sizes, kept out of search by default.
        static let noise: UInt8 = 1 << 4
        static let deleted: UInt8 = 1 << 5
    }

    var parent = ContiguousArray<Int32>()
    var firstChild = ContiguousArray<Int32>()
    var nextSibling = ContiguousArray<Int32>()
    var nameStart = ContiguousArray<UInt32>()
    var nameLength = ContiguousArray<UInt16>()
    /// Files: logical size. Folders: total of everything inside (after `aggregate`).
    var size = ContiguousArray<Int64>()
    /// Files: 1. Folders: number of files inside.
    var fileCount = ContiguousArray<UInt32>()
    var mtime = ContiguousArray<UInt32>()
    var flags = ContiguousArray<UInt8>()
    var names = ContiguousArray<UInt8>()
    /// Root entries and their absolute paths.
    var roots: [(id: Int32, path: String)] = []

    private let lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)

    init() {
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    var count: Int { parent.count }

    func read<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    func write<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    // MARK: - Building (callers hold the write lock)

    func addRoot(path: String, mtime: UInt32) -> Int32 {
        let id = Int32(parent.count)
        let bytes = Array(path.utf8)
        append(parent: -1, name: bytes[...], flags: Flag.directory, size: 0, files: 0, mtime: mtime)
        roots.append((id, path))
        return id
    }

    /// Appends `items` (names read from `nameBuffer`) as children of `parentID`; returns their ids in order.
    /// `ownNoise` (from `ownNoise(_:nameBuffer:)`, computed before taking the lock) marks build/cache folders.
    @discardableResult
    func appendChildren(_ items: [ScannedItem], nameBuffer: UnsafeRawBufferPointer, of parentID: Int32,
                        ownNoise: [Bool]? = nil) -> Range<Int32> {
        let first = Int32(parent.count)
        let noise = ownNoise ?? Self.ownNoise(items, nameBuffer: nameBuffer)
        var inherited = flags[Int(parentID)] & (Flag.hidden | Flag.noise)
        // The insides of apps and similar sealed packages aren't the user's files: keep them out of search.
        if isOpaquePackage(parentID) { inherited |= Flag.noise }
        for (index, item) in items.enumerated() {
            let name = UnsafeRawBufferPointer(rebasing: nameBuffer[item.nameOffset..<(item.nameOffset + item.nameLength)])
            var f: UInt8 = inherited
            if item.isDirectory { f |= Flag.directory }
            if item.isPackage { f |= Flag.package }
            if item.isSymlink { f |= Flag.symlink }
            if item.isHidden { f |= Flag.hidden }
            if noise[index] { f |= Flag.noise }
            appendRaw(parent: parentID, name: name, flags: f, size: item.isDirectory ? 0 : item.size,
                      files: item.isDirectory ? 0 : 1, mtime: item.mtime)
        }
        let last = Int32(parent.count)
        guard first < last else { return first..<last }
        // Link the new children in front of any existing ones.
        for id in first..<(last - 1) { nextSibling[Int(id)] = id + 1 }
        nextSibling[Int(last - 1)] = firstChild[Int(parentID)]
        firstChild[Int(parentID)] = first
        return first..<last
    }

    private func append(parent parentID: Int32, name: ArraySlice<UInt8>, flags f: UInt8, size bytes: Int64, files: UInt32, mtime time: UInt32) {
        name.withUnsafeBytes { appendRaw(parent: parentID, name: $0, flags: f, size: bytes, files: files, mtime: time) }
    }

    private func appendRaw(parent parentID: Int32, name: UnsafeRawBufferPointer, flags f: UInt8, size bytes: Int64, files: UInt32, mtime time: UInt32) {
        parent.append(parentID)
        firstChild.append(-1)
        nextSibling.append(-1)
        nameStart.append(UInt32(names.count))
        nameLength.append(UInt16(min(name.count, Int(UInt16.max))))
        names.append(contentsOf: name.prefix(Int(UInt16.max)))
        size.append(bytes)
        fileCount.append(files)
        mtime.append(time)
        flags.append(f)
    }

    /// Sums file sizes and counts into every folder. Run once after a full scan.
    func aggregate() {
        for i in stride(from: parent.count - 1, through: 0, by: -1) {
            let p = parent[i]
            guard p >= 0, flags[i] & Flag.deleted == 0 else { continue }
            size[Int(p)] += size[i]
            fileCount[Int(p)] += fileCount[i]
        }
    }

    /// Folds entries appended since `first` (a refreshed folder's new children and their scanned subtrees) into their
    /// folders' totals, and those totals into every older ancestor.
    func integrateNew(from first: Int32) {
        guard Int(first) < parent.count else { return }
        for i in stride(from: parent.count - 1, through: Int(first), by: -1) where flags[i] & Flag.deleted == 0 {
            let p = parent[i]
            if p >= first {
                size[Int(p)] += size[i]
                fileCount[Int(p)] += fileCount[i]
            } else {
                propagate(from: Int32(i), bytes: size[i], files: Int64(fileCount[i]))
            }
        }
    }

    /// Reserves room for `entries` up front. Untouched reserved pages cost no memory, while growing by doubling
    /// would leave every outgrown copy behind in the allocator.
    func reserve(entries: Int) {
        parent.reserveCapacity(entries)
        firstChild.reserveCapacity(entries)
        nextSibling.reserveCapacity(entries)
        nameStart.reserveCapacity(entries)
        nameLength.reserveCapacity(entries)
        size.reserveCapacity(entries)
        fileCount.reserveCapacity(entries)
        mtime.reserveCapacity(entries)
        flags.reserveCapacity(entries)
        names.reserveCapacity(entries * 24)
    }

    /// Files and folders in use on the volumes holding `paths`: an upper bound for how many entries a scan adds.
    static func estimatedEntries(under paths: [String]) -> Int {
        var volumes: [Int32: Int] = [:]
        for path in paths {
            var info = statfs()
            guard statfs(path, &info) == 0 else { continue }
            volumes[info.f_fsid.val.0] = Int(info.f_files &- info.f_ffree)
        }
        return min(volumes.values.reduce(0, +) + 100_000, 60_000_000)
    }

    /// Adds a size/count change to every ancestor of `id` (not to `id` itself).
    func propagate(from id: Int32, bytes: Int64, files: Int64) {
        guard bytes != 0 || files != 0 else { return }
        var p = parent[Int(id)]
        while p >= 0 {
            size[Int(p)] += bytes
            fileCount[Int(p)] = UInt32(clamping: Int64(fileCount[Int(p)]) + files)
            p = parent[Int(p)]
        }
    }

    /// Flags `id` and everything under it as deleted, unlinks it, and subtracts its totals from its ancestors.
    func remove(_ id: Int32) {
        guard flags[Int(id)] & Flag.deleted == 0 else { return }
        propagate(from: id, bytes: -size[Int(id)], files: -Int64(fileCount[Int(id)]))
        unlink(id)
        var stack: [Int32] = [id]
        while let current = stack.popLast() {
            flags[Int(current)] |= Flag.deleted
            var child = firstChild[Int(current)]
            while child >= 0 {
                stack.append(child)
                child = nextSibling[Int(child)]
            }
        }
    }

    private func unlink(_ id: Int32) {
        let p = parent[Int(id)]
        guard p >= 0 else { return }
        if firstChild[Int(p)] == id {
            firstChild[Int(p)] = nextSibling[Int(id)]
            return
        }
        var previous = firstChild[Int(p)]
        while previous >= 0 {
            let next = nextSibling[Int(previous)]
            if next == id {
                nextSibling[Int(previous)] = nextSibling[Int(id)]
                return
            }
            previous = next
        }
    }

    // MARK: - Reading (callers hold at least the read lock)

    func isLive(_ id: Int32) -> Bool { flags[Int(id)] & Flag.deleted == 0 }
    func isDirectory(_ id: Int32) -> Bool { flags[Int(id)] & Flag.directory != 0 }

    func name(_ id: Int32) -> String {
        let start = Int(nameStart[Int(id)])
        let length = Int(nameLength[Int(id)])
        return names.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[start..<(start + length)]), as: UTF8.self) }
    }

    func path(of id: Int32) -> String {
        var chain: [Int32] = []
        var current = id
        while current >= 0 {
            chain.append(current)
            current = parent[Int(current)]
        }
        guard let root = chain.popLast() else { return "" }
        var path = name(root)
        for component in chain.reversed() {
            if !path.hasSuffix("/") { path += "/" }
            path += name(component)
        }
        return path
    }

    func children(of id: Int32) -> [Int32] {
        var result: [Int32] = []
        var child = firstChild[Int(id)]
        while child >= 0 {
            result.append(child)
            child = nextSibling[Int(child)]
        }
        return result
    }

    /// The live entry at an absolute path, walking down from the root that contains it.
    func lookup(_ path: String) -> Int32? {
        guard let root = roots.first(where: { path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }) else { return nil }
        var current = root.id
        guard isLive(current) else { return nil }
        for component in path.dropFirst(root.path.count).split(separator: "/") {
            guard let child = child(of: current, named: component) else { return nil }
            current = child
        }
        return current
    }

    private func child(of id: Int32, named component: Substring) -> Int32? {
        let wanted = Array(component.utf8)
        var child = firstChild[Int(id)]
        while child >= 0 {
            if nameEquals(child, wanted) { return child }
            child = nextSibling[Int(child)]
        }
        // Names can differ only in Unicode normalization (NFC typed vs NFD on disk).
        if wanted.contains(where: { $0 >= 0x80 }) {
            let target = String(component)
            child = firstChild[Int(id)]
            while child >= 0 {
                if name(child) == target { return child }
                child = nextSibling[Int(child)]
            }
        }
        return nil
    }

    func nameEquals(_ id: Int32, _ bytes: [UInt8]) -> Bool {
        let length = Int(nameLength[Int(id)])
        guard length == bytes.count else { return false }
        let start = Int(nameStart[Int(id)])
        return names.withUnsafeBufferPointer { buffer in
            bytes.withUnsafeBufferPointer { wanted in
                memcmp(buffer.baseAddress! + start, wanted.baseAddress!, length) == 0
            }
        }
    }

    /// Raw views of the columns for hot loops; valid only inside `body` while the caller holds the lock.
    struct Columns: @unchecked Sendable {
        let parent: UnsafeBufferPointer<Int32>
        let nameStart: UnsafeBufferPointer<UInt32>
        let nameLength: UnsafeBufferPointer<UInt16>
        let size: UnsafeBufferPointer<Int64>
        let mtime: UnsafeBufferPointer<UInt32>
        let flags: UnsafeBufferPointer<UInt8>
        let names: UnsafeBufferPointer<UInt8>

        @inline(__always)
        func name(_ i: Int) -> UnsafeBufferPointer<UInt8> {
            let start = Int(nameStart[i])
            return UnsafeBufferPointer(rebasing: names[start..<(start + Int(nameLength[i]))])
        }
    }

    func withColumns<T>(_ body: (Columns) throws -> T) rethrows -> T {
        try parent.withUnsafeBufferPointer { parent in
            try nameStart.withUnsafeBufferPointer { nameStart in
                try nameLength.withUnsafeBufferPointer { nameLength in
                    try size.withUnsafeBufferPointer { size in
                        try mtime.withUnsafeBufferPointer { mtime in
                            try flags.withUnsafeBufferPointer { flags in
                                try names.withUnsafeBufferPointer { names in
                                    try body(Columns(parent: parent, nameStart: nameStart, nameLength: nameLength, size: size,
                                                     mtime: mtime, flags: flags, names: names))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Noise

    private static let noiseNames: [[UInt8]] = [
        "node_modules", ".git", ".hg", ".svn", "DerivedData", "__pycache__", ".venv", "venv", ".gradle", ".next",
        ".nuxt", ".turbo", ".cache", "Caches", ".npm", ".yarn", ".pnpm-store", ".build", ".swiftpm", ".Trash",
        ".godot", ".mypy_cache", ".pytest_cache", ".ruff_cache", "Pods",
    ].map { Array($0.utf8) }

    /// Folders that are build output only next to the project file that produces them (a "target" folder is noise
    /// beside Cargo.toml, but may be anything elsewhere). Markers ending in "." match by suffix (".csproj").
    private static let buildOutputRules: [(marker: [UInt8], suffix: Bool, folders: [[UInt8]])] = [
        ("Cargo.toml", false, ["target"]), (".csproj", true, ["bin", "obj"]), (".fsproj", true, ["bin", "obj"]),
        ("build.gradle", false, ["build"]), ("build.gradle.kts", false, ["build"]),
        ("package.json", false, ["dist", "out", "coverage"]), ("pom.xml", false, ["target"]),
    ].map { (Array($0.0.utf8), $0.1, $0.2.map { Array($0.utf8) }) }

    /// Which of `items` are folders that are noise in their own right: caches and VCS internals by name, or build
    /// output beside the project file that produces it. Pure and lock-free (raw byte comparisons only).
    static func ownNoise(_ items: [ScannedItem], nameBuffer: UnsafeRawBufferPointer) -> [Bool] {
        func bytes(_ item: ScannedItem) -> UnsafeRawBufferPointer {
            UnsafeRawBufferPointer(rebasing: nameBuffer[item.nameOffset..<(item.nameOffset + item.nameLength)])
        }
        func equal(_ a: UnsafeRawBufferPointer, _ b: [UInt8]) -> Bool {
            a.count == b.count && b.withUnsafeBytes { memcmp($0.baseAddress!, a.baseAddress!, a.count) == 0 }
        }
        var outputs: [[UInt8]] = []
        for item in items where !item.isDirectory {
            let name = bytes(item)
            for rule in buildOutputRules {
                let hit = rule.suffix
                    ? name.count > rule.marker.count && equal(UnsafeRawBufferPointer(rebasing: name[(name.count - rule.marker.count)...]), rule.marker)
                    : equal(name, rule.marker)
                if hit { outputs.append(contentsOf: rule.folders) }
            }
        }
        return items.map { item in
            guard item.isDirectory else { return false }
            let name = bytes(item)
            return isNoiseFolder(name) || outputs.contains { equal(name, $0) }
        }
    }

    /// Packages whose contents are implementation details (apps, frameworks, libraries), unlike project and asset
    /// packages (.xcodeproj, .playground, .xcassets…) whose contents are the user's own files.
    private static let opaquePackageExtensions: Set<String> = [
        "app", "framework", "plugin", "kext", "appex", "xpc", "qlgenerator", "mdimporter", "prefpane", "saver",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "pages",
        "numbers", "key", "dsym", "xcarchive", "wdgt", "systemextension", "driver",
    ]

    func isOpaquePackage(_ id: Int32) -> Bool {
        guard flags[Int(id)] & Flag.package != 0 else { return false }
        let name = self.name(id)
        guard let dot = name.lastIndex(of: ".") else { return false }
        return Self.opaquePackageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    static func isNoiseFolder(_ name: UnsafeRawBufferPointer) -> Bool {
        noiseNames.contains { candidate in
            candidate.count == name.count && candidate.withUnsafeBytes { memcmp($0.baseAddress!, name.baseAddress!, name.count) == 0 }
        }
    }
}
