import CryptoKit
import Foundation

nonisolated extension IndexPersistence {
    /// A cumulative changes file is replaced atomically, just like the full snapshot. It always describes the
    /// difference from one snapshot generation: losing an incomplete write leaves the previous pair usable.
    struct Policy {
        var maximumBytes = 16 * 1024 * 1024
        var maximumSaves = 128
    }

    struct SaveResult {
        enum Kind { case snapshot, changes, unchanged }
        var kind: Kind
        var bytesWritten: Int
    }

    struct Stamp: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var type: UInt16
        var seconds: Int
        var nanoseconds: Int
    }

    struct Baseline {
        var path: String
        var generation: UUID
        var hashes: [[SHA256.Digest]]
        var savedHashes: [[SHA256.Digest]]
        var snapshot: Stamp
        var changes: Stamp?
        var revision: Int
        var eventID: UInt64
        var excluded: Set<String>
        var roots: [String]
        var replayFrom: UInt64? = nil
    }

    private struct Patch {
        var page: Int
        var bytes: Data
    }

    private struct Column {
        var length: Int
        var patches: [Patch]
    }

    private struct Changes {
        var generation: UUID
        var revision: Int
        var eventID: UInt64
        var columns: [Column]
    }

    private struct Failure: Error {}
    private struct TooLarge: Error {}
    private static let pageSize = 16 * 1024
    private static let changesMagic: UInt32 = 0x5354_5244
    private static let changesVersion: UInt32 = 1

    static func changesURL(for file: URL) -> URL { file.appendingPathExtension("changes") }

    /// All instances using this format lock the containing directory while reading or publishing the pair. No lock
    /// file is needed, and a crash releases the lock. An older app's snapshot has no generation and is migrated again.
    private final class DirectoryLock {
        private var fd: Int32

        init(_ file: URL, shared: Bool) throws {
            fd = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure() }
            while flock(fd, shared ? LOCK_SH : LOCK_EX) != 0 {
                if errno == EINTR { continue }
                close(fd)
                fd = -1
                throw Failure()
            }
        }

        func unlock() {
            if fd >= 0 { close(fd); fd = -1 }
        }

        deinit { if fd >= 0 { close(fd) } }
    }

    private static func stamp(_ file: URL) throws -> Stamp? {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw Failure()
        }
        return Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size, type: info.st_mode & S_IFMT,
                     seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    @discardableResult
    static func save(_ store: IndexStore, eventID: UInt64, excluded: [String], to file: URL,
                     policy: Policy = Policy(), beforeCommit: (() throws -> Void)? = nil,
                     afterSnapshotCommit: (() throws -> Void)? = nil) throws -> SaveResult {
        let lock = try DirectoryLock(file, shared: false)
        defer { lock.unlock() }
        let snapshotStamp = try stamp(file)
        let deltaStamp = try stamp(changesURL(for: file))
        let prepared: (Baseline, SaveResult) = try store.read {
            let hashes = try hashes(of: store)
            let roots = store.roots.map { "\($0.id):\($0.path)" }
            var replayFrom = store.persistence?.replayFrom
            if let previous = store.persistence, previous.path == file.path,
               previous.snapshot != snapshotStamp || previous.changes != deltaStamp {
                // Another instance changed the pair. This instance may not have received all its filesystem
                // events yet: checkpoint its own consistent store, but keep replaying from its older watermark.
                // Preserve that floor until a restart catches up or a full filesystem rebuild makes a new store.
                replayFrom = min(replayFrom ?? previous.eventID, previous.eventID)
            }
            let watermark = min(eventID, replayFrom ?? eventID)
            if var baseline = store.persistence, baseline.path == file.path,
               baseline.snapshot == snapshotStamp, baseline.changes == deltaStamp,
               baseline.roots == roots, baseline.excluded == Set(excluded) {
                if baseline.savedHashes == hashes, baseline.eventID == watermark {
                    return (baseline, SaveResult(kind: .unchanged, bytesWritten: 0))
                }
                let budget = min(16 * 1024 * 1024, policy.maximumBytes, Int(baseline.snapshot.size) / 4)
                if baseline.revision < policy.maximumSaves,
                   let columns = try? difference(store, from: baseline.hashes, current: hashes, budget: budget) {
                    let changes = Changes(generation: baseline.generation, revision: baseline.revision + 1,
                                          eventID: watermark, columns: columns)
                    let target = changesURL(for: file)
                    try write(changes, to: target, beforeCommit: beforeCommit)
                    guard let written = try stamp(target) else { throw Failure() }
                    baseline.savedHashes = hashes
                    baseline.changes = written
                    baseline.revision += 1
                    baseline.eventID = watermark
                    baseline.replayFrom = replayFrom
                    return (baseline, SaveResult(kind: .changes, bytesWritten: Int(written.size)))
                }
            }
            let generation = UUID()
            try saveSnapshot(store, eventID: watermark, excluded: excluded, to: file,
                             generation: generation, beforeCommit: beforeCommit)
            guard let written = try stamp(file) else { throw Failure() }
            try afterSnapshotCommit?()
            // A changes file from the previous generation may remain if the app quits here. Loading ignores it;
            // cleanup is only after the snapshot commits. Never remove a directory or follow a planted link.
            if let old = try stamp(changesURL(for: file)), old.type != S_IFDIR {
                guard unlink(changesURL(for: file).path) == 0 else { throw Failure() }
            }
            let baseline = Baseline(path: file.path, generation: generation, hashes: hashes, savedHashes: hashes,
                                    snapshot: written, changes: try stamp(changesURL(for: file)), revision: 0, eventID: watermark,
                                    excluded: Set(excluded), roots: roots, replayFrom: replayFrom)
            return (baseline, SaveResult(kind: .snapshot, bytesWritten: Int(written.size)))
        }
        store.write { store.persistence = prepared.0 }
        return prepared.1
    }

    static func load(from file: URL, afterSnapshotRead: (() throws -> Void)? = nil) throws -> (IndexStore, Header) {
        let lock = try DirectoryLock(file, shared: true)
        defer { lock.unlock() }
        let before = try stamp(file)
        let (store, original) = try loadSnapshot(from: file)
        try afterSnapshotRead?()
        // Older builds do not take this directory lock. If one replaced the snapshot while it was being read,
        // reject the pair rather than associating the old store's hashes with the replacement file's identity.
        guard let snapshotStamp = try stamp(file), snapshotStamp == before else { throw Failure() }
        guard let generation = original.generation else {
            try validate(store)
            return (store, original)
        }
        let baseHashes = try hashes(of: store)
        var savedHashes = baseHashes
        let target = changesURL(for: file)
        let deltaStamp = try stamp(target)
        var header = original
        var revision = 0
        if let deltaStamp, deltaStamp.type == S_IFREG {
            // The writer never emits a changes file above this bound. Refuse oversized or malformed input before
            // allocating its declared columns; a failed load rebuilds from the filesystem rather than trusting it.
            guard deltaStamp.size <= 17 * 1024 * 1024 else { throw Failure() }
            if let changes = try readChanges(from: target, generation: generation, base: store) {
                guard changes.eventID >= original.eventID else { throw Failure() }
                try apply(changes.columns, to: store)
                // Unchanged pages still have their snapshot hashes. Hash only authenticated replacement pages;
                // replay needn't read the entire restored index a second time just to establish its baseline.
                for (index, column) in changes.columns.enumerated() {
                    let pages = (column.length + pageSize - 1) / pageSize
                    if pages < savedHashes[index].count { savedHashes[index].removeLast(savedHashes[index].count - pages) }
                    if pages > savedHashes[index].count {
                        savedHashes[index].append(contentsOf: repeatElement(SHA256.hash(data: Data()), count: pages - savedHashes[index].count))
                    }
                    for patch in column.patches { savedHashes[index][patch.page] = SHA256.hash(data: patch.bytes) }
                }
                header.eventID = changes.eventID
                revision = changes.revision
            }
        }
        try validate(store)
        store.persistence = Baseline(path: file.path, generation: generation, hashes: baseHashes,
                                     savedHashes: savedHashes,
                                     snapshot: snapshotStamp, changes: deltaStamp, revision: revision,
                                     eventID: header.eventID, excluded: Set(header.excluded),
                                     roots: store.roots.map { "\($0.id):\($0.path)" })
        return (store, header)
    }

    private static func columns(_ store: IndexStore, _ body: (Int, UnsafeRawBufferPointer) throws -> Void) throws {
        var index = 0
        func visit<T>(_ values: ContiguousArray<T>) throws {
            try values.withUnsafeBytes { try body(index, $0) }
            index += 1
        }
        try visit(store.parent); try visit(store.firstChild); try visit(store.nextSibling)
        try visit(store.nameStart); try visit(store.nameLength); try visit(store.size)
        try visit(store.fileCount); try visit(store.mtime); try visit(store.fileKey)
        try visit(store.flags); try visit(store.names)
    }

    private static func hashes(of store: IndexStore) throws -> [[SHA256.Digest]] {
        var result: [[SHA256.Digest]] = []
        try columns(store) { _, bytes in
            result.append(stride(from: 0, to: bytes.count, by: pageSize).map { offset in
                var hash = SHA256()
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[offset..<min(offset + pageSize, bytes.count)]))
                return hash.finalize()
            })
        }
        return result
    }

    private static func difference(_ store: IndexStore, from hashes: [[SHA256.Digest]],
                                   current: [[SHA256.Digest]], budget: Int) throws -> [Column] {
        var result: [Column] = []
        var size = 172
        guard size <= budget else { throw TooLarge() }
        try columns(store) { index, bytes in
            var patches: [Patch] = []
            for offset in stride(from: 0, to: bytes.count, by: pageSize) {
                let page = offset / pageSize
                if page < hashes[index].count, current[index][page] == hashes[index][page] { continue }
                let data = Data(bytes: bytes.baseAddress! + offset, count: min(pageSize, bytes.count - offset))
                size += data.count + 8
                guard size <= budget else { throw TooLarge() }
                patches.append(Patch(page: page, bytes: data))
            }
            result.append(Column(length: bytes.count, patches: patches))
        }
        return result
    }

    private static func write(_ changes: Changes, to file: URL, beforeCommit: (() throws -> Void)?) throws {
        let writer = try SecureStorage.Writer(url: file)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { writer.write($0) } }
        put(changesMagic); put(changesVersion); put(changes.generation.uuid)
        put(UInt64(changes.revision)); put(changes.eventID)
        for column in changes.columns {
            put(UInt64(column.length)); put(UInt32(column.patches.count))
            for patch in column.patches {
                put(UInt32(patch.page)); put(UInt32(patch.bytes.count))
                patch.bytes.withUnsafeBytes { writer.write($0) }
            }
        }
        try beforeCommit?()
        try writer.commit()
    }

    private static func readChanges(from file: URL, generation: UUID, base: IndexStore) throws -> Changes? {
        let reader = try SecureStorage.Reader(url: file)
        func get<T>(_: T.Type) throws -> T {
            try withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
                try reader.read(into: UnsafeMutableRawBufferPointer(buffer))
                return UnsafeRawPointer(buffer.baseAddress!).loadUnaligned(as: T.self)
            }
        }
        guard try get(UInt32.self) == changesMagic, try get(UInt32.self) == changesVersion else { throw Failure() }
        guard UUID(uuid: try get(uuid_t.self)) == generation else { return nil }
        let revision = try get(UInt64.self)
        guard revision > 0, revision <= UInt64(Int.max) else { throw Failure() }
        let eventID = try get(UInt64.self)
        var result: [Column] = []
        try columns(base) { index, bytes in
            let length = try get(UInt64.self)
            let count = try get(UInt32.self)
            let stride = index == 9 || index == 10 ? 1 : [4, 4, 4, 4, 2, 8, 4, 4, 4][index]
            let maximumLength = index == 10 ? UInt64(UInt32.max) : UInt64(Int32.max) * UInt64(stride)
            guard length <= maximumLength, length % UInt64(stride) == 0,
                  count <= reader.maximumLength / 8 else { throw Failure() }
            let totalPages = (Int(length) + pageSize - 1) / pageSize
            var patches: [Patch] = []
            var previous = -1
            for _ in 0..<count {
                let page = Int(try get(UInt32.self)), size = Int(try get(UInt32.self))
                guard page > previous, page < totalPages,
                      size == min(pageSize, Int(length) - page * pageSize) else { throw Failure() }
                var data = Data(count: size)
                try data.withUnsafeMutableBytes { try reader.read(into: $0) }
                patches.append(Patch(page: page, bytes: data))
                previous = page
            }
            // Every byte beyond the base column must come from an authenticated patch, including a partially
            // filled last page. Never allocate or expose a grown column with gaps filled by invented zeroes.
            if length > bytes.count {
                let required = (bytes.count / pageSize)..<totalPages
                let supplied = patches.filter { required.contains($0.page) }
                guard supplied.count == required.count else { throw Failure() }
            }
            result.append(Column(length: Int(length), patches: patches))
        }
        try reader.finish()
        return Changes(generation: generation, revision: Int(revision), eventID: eventID, columns: result)
    }

    private static func apply(_ columns: [Column], to store: IndexStore) throws {
        var index = 0
        func patch<T>(_ values: inout ContiguousArray<T>) throws {
            let column = columns[index]; index += 1
            let count = column.length / MemoryLayout<T>.stride
            if count == values.count {
                guard !column.patches.isEmpty else { return }
                values.withUnsafeMutableBytes { destination in
                    for patch in column.patches {
                        patch.bytes.withUnsafeBytes { bytes in
                            destination.baseAddress!.advanced(by: patch.page * pageSize).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                        }
                    }
                }
                return
            }
            let old = values
            values = ContiguousArray<T>(unsafeUninitializedCapacity: count) { buffer, initialized in
                let destination = UnsafeMutableRawBufferPointer(buffer)
                old.withUnsafeBytes { bytes in
                    let kept = min(bytes.count, destination.count)
                    if kept > 0 { destination.baseAddress!.copyMemory(from: bytes.baseAddress!, byteCount: kept) }
                }
                for patch in column.patches {
                    patch.bytes.withUnsafeBytes { bytes in
                        destination.baseAddress!.advanced(by: patch.page * pageSize).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                    }
                }
                initialized = count
            }
        }
        try patch(&store.parent); try patch(&store.firstChild); try patch(&store.nextSibling)
        try patch(&store.nameStart); try patch(&store.nameLength); try patch(&store.size)
        try patch(&store.fileCount); try patch(&store.mtime); try patch(&store.fileKey)
        try patch(&store.flags); try patch(&store.names)
    }

    private static func validate(_ store: IndexStore) throws {
        let count = store.count
        guard count <= Int32.max, store.names.count <= UInt32.max,
              [store.firstChild.count, store.nextSibling.count, store.nameStart.count, store.nameLength.count,
               store.size.count, store.fileCount.count, store.mtime.count, store.fileKey.count, store.flags.count]
                .allSatisfy({ $0 == count }) else { throw Failure() }
        let roots = Set(store.roots.map(\.id))
        guard roots.count == store.roots.count, Set(store.roots.map(\.path)).count == roots.count else { throw Failure() }
        for root in store.roots {
            guard root.id >= 0, root.id < count, store.parent[Int(root.id)] == -1,
                  store.isDirectory(root.id), root.path.hasPrefix("/") else { throw Failure() }
        }
        for i in 0..<count {
            let parent = store.parent[i]
            guard parent >= -1, parent < i,
                  parent >= 0 || roots.contains(Int32(i)),
                  UInt64(store.nameStart[i]) + UInt64(store.nameLength[i]) <= UInt64(store.names.count) else { throw Failure() }
            let first = store.firstChild[i], next = store.nextSibling[i]
            guard first >= -1, first < count, next >= -1, next < count else { throw Failure() }
            if first >= 0 { guard store.parent[Int(first)] == i else { throw Failure() } }
            if next >= 0 { guard store.parent[Int(next)] == parent else { throw Failure() } }
        }
        for root in store.roots { guard store.name(root.id) == root.path else { throw Failure() } }
        // Parent ordering rules out ancestry cycles. Sibling chains also need an explicit cycle check.
        var visited = [UInt8](repeating: 0, count: count)
        for i in 0..<count where visited[i] == 0 {
            var node = Int32(i)
            while node >= 0, visited[Int(node)] == 0 { visited[Int(node)] = 1; node = store.nextSibling[Int(node)] }
            if node >= 0, visited[Int(node)] == 1 { throw Failure() }
            node = Int32(i)
            while node >= 0, visited[Int(node)] == 1 { visited[Int(node)] = 2; node = store.nextSibling[Int(node)] }
        }
    }
}
