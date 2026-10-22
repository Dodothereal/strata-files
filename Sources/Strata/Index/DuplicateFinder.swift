import CryptoKit
import Foundation
import StrataSupport

/// A set of files with identical contents.
nonisolated package struct DuplicateGroup: Sendable {
    package let size: Int64
    package let paths: [String]

    /// Space freed by keeping one copy.
    package var reclaimable: Int64 { max(0, size).saturatingMultiply(Int64(max(0, paths.count - 1))) }
}

/// Finds duplicate files among indexed ones: same size first (free, from the index), then a hash of the first and
/// last 64 KB, then a full SHA-256 only for files that still look identical.
nonisolated package enum DuplicateFinder {
    package static func candidates(in store: IndexStore, minSize: Int64) -> [[(path: String, size: Int64)]] {
        store.read { store in
            var bySize: [Int64: [Int32]] = [:]
            let skip = IndexStore.Flag.directory | IndexStore.Flag.noise | IndexStore.Flag.hidden | IndexStore.Flag.deleted
                | IndexStore.Flag.symlink
            // App internals carry the noise flag, so the skip mask already leaves them out.
            for id in 0..<store.count where store.flags[id] & skip == 0 && store.size[id] >= minSize {
                bySize[store.size[id], default: []].append(Int32(id))
            }
            return bySize.filter { $0.value.count > 1 }.map { size, ids in ids.map { (store.path(of: $0), size) } }
        }
    }

    /// Hashes candidates and returns real duplicate groups, largest savings first. `progress` gets (done, total).
    package static func find(_ candidates: [[(path: String, size: Int64)]], progress: @Sendable (Int, Int) -> Void,
                     isCancelled: @Sendable () -> Bool) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        let total = candidates.count
        for (index, group) in candidates.enumerated() {
            if isCancelled() { return [] }
            progress(index, total)
            guard let first = group.first, group.count > 1 else { continue }
            let size = first.size
            // Hard links are one file under several names: deleting one frees nothing, so each counts once.
            var inodes: Set<[UInt64]> = []
            let distinct = group.filter { file in
                var info = stat()
                guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
                return inodes.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted
            }
            guard distinct.count > 1 else { continue }
            var byQuickHash: [Data: [String]] = [:]
            for file in distinct {
                if let hash = quickHash(file.path, size: size) { byQuickHash[hash, default: []].append(file.path) }
            }
            for paths in byQuickHash.values where paths.count > 1 {
                // Up to 128 KB the head and tail hashes cover the whole file.
                if size <= 128 * 1024 {
                    groups.append(DuplicateGroup(size: size, paths: paths.sorted()))
                    continue
                }
                var byFullHash: [Data: [String]] = [:]
                for path in paths {
                    if isCancelled() { return [] }
                    if let hash = fullHash(path) { byFullHash[hash, default: []].append(path) }
                }
                for same in byFullHash.values where same.count > 1 {
                    groups.append(DuplicateGroup(size: size, paths: same.sorted()))
                }
            }
        }
        progress(total, total)
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    private static func openRegularFile(_ path: String) -> FileHandle? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func quickHash(_ path: String, size: Int64) -> Data? {
        guard let handle = openRegularFile(path) else { return nil }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk) {
            guard (try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))) != nil, let tail = try? handle.read(upToCount: chunk) else { return nil }
            hasher.update(data: tail)
        }
        return Data(hasher.finalize())
    }

    private static func fullHash(_ path: String) -> Data? {
        guard let handle = openRegularFile(path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` returns nil (not empty data) at the end of the file.
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return Data(hasher.finalize())
    }
}
