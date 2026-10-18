import Foundation

/// Saves the index as raw columns so the next launch can load millions of entries in well under a second
/// and then catch up from the FSEvents journal instead of rescanning.
nonisolated enum IndexPersistence {
    private static let magic: UInt32 = 0x5354_5258 // "STRX"
    // 5: only app-like packages' contents are noise, plus build output beside its project file; 6: file IDs (a full
    // rescan picks that up); 7: a snapshot generation binds its cumulative encrypted changes file.
    private static let version: UInt32 = 7

    struct Header {
        var eventID: UInt64
        var roots: [(id: Int32, path: String)]
        var excluded: [String]
        var generation: UUID? = nil
    }

    /// Streams the columns, encrypted, straight to disk (no in-memory copy of the whole file), then swaps the file in
    /// atomically.
    static func saveSnapshot(_ store: IndexStore, eventID: UInt64, excluded: [String], to url: URL,
                             generation: UUID?, beforeCommit: (() throws -> Void)? = nil) throws {
        let writer = try SecureStorage.Writer(url: url)
        func put(_ bytes: UnsafeRawBufferPointer) { writer.write(bytes) }
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { put($0) } }
        func putString(_ string: String) {
            let bytes = Array(string.utf8)
            put(UInt32(bytes.count))
            bytes.withUnsafeBytes { put($0) }
        }
        func putColumn<T>(_ column: ContiguousArray<T>) {
            put(UInt64(column.count))
            column.withUnsafeBytes { put($0) }
        }

        // The persistence session holds the store read lock throughout this write.
        do {
            put(magic)
            put(generation == nil ? UInt32(6) : version)
            if let generation { put(generation.uuid) }
            put(eventID)
            put(UInt32(store.roots.count))
            for root in store.roots {
                put(root.id)
                putString(root.path)
            }
            put(UInt32(excluded.count))
            excluded.forEach(putString)
            putColumn(store.parent)
            putColumn(store.firstChild)
            putColumn(store.nextSibling)
            putColumn(store.nameStart)
            putColumn(store.nameLength)
            putColumn(store.size)
            putColumn(store.fileCount)
            putColumn(store.mtime)
            putColumn(store.fileKey)
            putColumn(store.flags)
            putColumn(store.names)
        }
        try beforeCommit?()
        try writer.commit()
    }

    static func loadSnapshot(from url: URL) throws -> (IndexStore, Header) {
        let reader = try SecureStorage.Reader(url: url)
        struct Corrupt: Error {}
        func get<T>(_: T.Type) throws -> T {
            try withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
                try reader.read(into: UnsafeMutableRawBufferPointer(buffer))
                return UnsafeMutableRawBufferPointer(buffer).loadUnaligned(as: T.self)
            }
        }
        func getString() throws -> String {
            let length = Int(try get(UInt32.self))
            guard length <= 1 << 20 else { throw Corrupt() }
            var bytes = [UInt8](repeating: 0, count: length)
            try bytes.withUnsafeMutableBytes { try reader.read(into: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        func getColumn<T>(_: T.Type) throws -> ContiguousArray<T> {
            let rawCount = try get(UInt64.self)
            guard rawCount <= UInt64(reader.maximumLength / MemoryLayout<T>.stride) else { throw Corrupt() }
            let count = Int(rawCount)
            var failure: Error?
            let column = ContiguousArray<T>(unsafeUninitializedCapacity: count) { buffer, initialized in
                do {
                    try reader.read(into: UnsafeMutableRawBufferPointer(buffer))
                    initialized = count
                } catch {
                    failure = error
                    initialized = 0
                }
            }
            if let failure { throw failure }
            return column
        }

        guard try get(UInt32.self) == magic else { throw Corrupt() }
        let format = try get(UInt32.self)
        guard format == 6 || format == version else { throw Corrupt() }
        let generation = format == version ? UUID(uuid: try get(uuid_t.self)) : nil
        var header = Header(eventID: try get(UInt64.self), roots: [], excluded: [], generation: generation)
        for _ in 0..<Int(try get(UInt32.self)) {
            let id = try get(Int32.self)
            header.roots.append((id, try getString()))
        }
        for _ in 0..<Int(try get(UInt32.self)) { header.excluded.append(try getString()) }

        let store = IndexStore()
        store.parent = try getColumn(Int32.self)
        store.firstChild = try getColumn(Int32.self)
        store.nextSibling = try getColumn(Int32.self)
        store.nameStart = try getColumn(UInt32.self)
        store.nameLength = try getColumn(UInt16.self)
        store.size = try getColumn(Int64.self)
        store.fileCount = try getColumn(UInt32.self)
        store.mtime = try getColumn(UInt32.self)
        store.fileKey = try getColumn(UInt32.self)
        store.flags = try getColumn(UInt8.self)
        store.names = try getColumn(UInt8.self)
        store.roots = header.roots
        let count = store.parent.count
        guard [store.firstChild.count, store.nextSibling.count, store.nameStart.count, store.nameLength.count,
               store.size.count, store.fileCount.count, store.mtime.count, store.fileKey.count,
               store.flags.count].allSatisfy({ $0 == count })
        else { throw Corrupt() }
        try reader.finish()
        return (store, header)
    }
}
