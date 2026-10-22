import Foundation

/// Reads directories with `getattrlistbulk`, which returns names, types, sizes and dates for a whole batch of entries
/// in one system call: several times faster than `readdir` + `lstat` per file.
nonisolated package enum BulkDirectoryReader {
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "qlgenerator", "mdimporter", "prefPane",
        "xcodeproj", "xcworkspace", "playground", "photoslibrary", "musiclibrary", "tvlibrary", "rtfd", "pages",
        "numbers", "key", "scriptd", "lpdf", "nib", "xcassets", "car", "icon", "iconset", "pkg", "mpkg", "band",
        "logicx", "fcpbundle", "imovielibrary", "dSYM", "xcarchive", "docset", "safariextz", "wdgt", "saver", "theater",
    ]

    /// Lists `path`, appending entries to `items` and their names to `names`. Returns `errno` on failure, and
    /// `ECANCELED` when `shouldStop` says so between batches (a folder with a huge number of entries, or a slow disk,
    /// mustn't hold up quitting).
    package static func read(_ path: String, items: inout [ScannedItem], names: inout [UInt8], buffer: UnsafeMutableRawBufferPointer,
                     shouldStop: () -> Bool = { false }) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)

        while true {
            if shouldStop() { return ECANCELED }
            let count = getattrlistbulk(fd, &request, buffer.baseAddress, buffer.count, 0)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            var entry = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // Fields follow in a fixed order: error, name, type, mtime, flags, then directory and file attributes.
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 { continue }
                }
                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePointer = field + Int(nameRef.attr_dataoffset)
                let nameLength = max(0, Int(nameRef.attr_length) - 1) // includes the trailing NUL
                field += MemoryLayout<attrreference_t>.size

                var type: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var mtime: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let seconds = field.loadUnaligned(as: Int.self)
                    mtime = UInt32(clamping: seconds)
                    field += MemoryLayout<timespec>.size
                }
                var bsdFlags: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                    bsdFlags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileKey: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    let id = field.loadUnaligned(as: UInt64.self)
                    fileKey = UInt32(truncatingIfNeeded: id ^ (id >> 32))
                    field += 8
                }
                var mountStatus: UInt32 = 0
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    mountStatus = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var size: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                    size = max(0, field.loadUnaligned(as: Int64.self))
                    field += 8
                }

                let isDirectory = type == UInt32(VDIR.rawValue)
                let nameBytes = UnsafeRawBufferPointer(start: namePointer, count: nameLength)
                let isDotFile = nameLength > 0 && nameBytes[0] == UInt8(ascii: ".")
                items.append(ScannedItem(
                    nameOffset: names.count,
                    nameLength: nameLength,
                    isDirectory: isDirectory,
                    isPackage: isDirectory && isPackageName(nameBytes),
                    isSymlink: type == UInt32(VLNK.rawValue),
                    isHidden: isDotFile || bsdFlags & UInt32(UF_HIDDEN) != 0,
                    isMountPoint: mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
                    size: size,
                    mtime: mtime,
                    fileKey: fileKey))
                names.append(contentsOf: nameBytes)
            }
        }
    }

    private static func isPackageName(_ name: UnsafeRawBufferPointer) -> Bool {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1 else { return false }
        let ext = String(decoding: UnsafeRawBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self)
        return packageExtensions.contains(ext)
    }
}

/// Walks directory trees in parallel and records everything in an `IndexStore`.
nonisolated package final class IndexScanner: @unchecked Sendable {
    private struct Job {
        let id: Int32
        let path: String
    }

    private let store: IndexStore
    private let excluded: Set<String>
    private let noiseFolders: Set<String>
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var active = 0
    private var cancelled = false
    private var scanned = 0

    /// Items scanned so far (read from the progress timer on another thread, so under the lock).
    package var scannedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return scanned
    }

    /// - Parameters:
    ///   - excluded: absolute paths not to descend into (they still appear as entries).
    ///   - noiseFolders: absolute paths whose subtree is kept out of default search results.
    package init(store: IndexStore, excluded: Set<String>, noiseFolders: Set<String>) {
        self.store = store
        self.excluded = excluded
        self.noiseFolders = noiseFolders
    }

    package func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    package var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    /// Scans each folder's subtree (the folder itself must already be in the store). Blocks until done.
    package func scan(_ folders: [(id: Int32, path: String)], threads: Int = IndexScanner.performanceCores) {
        condition.lock()
        jobs.append(contentsOf: folders.map { Job(id: $0.id, path: $0.path) })
        condition.unlock()
        DispatchQueue.concurrentPerform(iterations: max(1, threads)) { _ in work() }
    }

    /// How many threads should read `path`'s volume. Measured on a 10+4-core Mac: a writable volume peaked at one
    /// thread per performance core (402k items/s with 10 threads, 357k with 16, where they mostly wait on each other in
    /// the kernel's path lookups); the sealed, read-only system volume peaked at 3 (252k items/s, against 48k with 16).
    package static func threadCount(for path: String) -> Int {
        var info = statfs()
        if statfs(path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) != 0 { return min(3, performanceCores) }
        return performanceCores
    }

    /// Performance cores (all cores on Macs that don't tell them apart).
    package static let performanceCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return ProcessInfo.processInfo.activeProcessorCount
    }()

    private func work() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var items: [ScannedItem] = []
        var names: [UInt8] = []
        items.reserveCapacity(512)
        names.reserveCapacity(16 * 1024)

        while let job = nextJob() {
            items.removeAll(keepingCapacity: true)
            names.removeAll(keepingCapacity: true)
            _ = BulkDirectoryReader.read(job.path, items: &items, names: &names, buffer: buffer) { self.isCancelled }
            // Work out child folder paths before taking the lock; only id assignment happens inside it.
            let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
            var folders: [(offset: Int, path: String, noise: Bool)] = []
            for (offset, item) in items.enumerated() where item.isDirectory && !item.isMountPoint {
                let path = prefix + String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
                if !excluded.contains(path) { folders.append((offset, path, noiseFolders.contains(path))) }
            }
            let ownNoise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
            let ids = store.write { store in
                let ids = names.withUnsafeBytes { store.appendChildren(items, nameBuffer: $0, of: job.id, ownNoise: ownNoise) }
                for folder in folders where folder.noise {
                    store.flags[Int(ids.lowerBound) + folder.offset] |= IndexStore.Flag.noise
                }
                return ids
            }
            let childJobs = folders.map { Job(id: ids.lowerBound + Int32($0.offset), path: $0.path) }
            finish(job, adding: childJobs, scanned: items.count)
        }
    }

    private func nextJob() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && active > 0 && !cancelled { condition.wait() }
        guard !cancelled, let job = jobs.popLast() else { return nil }
        active += 1
        return job
    }

    private func finish(_ job: Job, adding children: [Job], scanned: Int) {
        condition.lock()
        jobs.append(contentsOf: children)
        active -= 1
        self.scanned += scanned
        condition.broadcast()
        condition.unlock()
    }
}
