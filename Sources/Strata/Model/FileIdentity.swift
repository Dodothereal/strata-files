import Foundation

/// The item itself, without following a symlink. Live Undo compares birth time too, so reusing an inode does not
/// make a replacement its own. History keeps its existing on-disk formats, including records from older versions.
nonisolated struct FileIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    static func read(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino,
                            birthSeconds: info.st_birthtimespec.tv_sec, birthNanoseconds: info.st_birthtimespec.tv_nsec)
    }

    var legacyHistoryKey: String { "\(device):\(inode)" }

    func historyKey(volumeID: String?) -> String { "\(volumeID ?? String(device))/\(inode)" }

    /// Volume UUIDs survive remounting, unlike device numbers. Preserve the device-number fallback for volumes
    /// without a UUID; changing that representation would make already-saved History stop recognizing its items.
    static func historyKey(at path: String) -> String? {
        guard let identity = read(path) else { return nil }
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return identity.historyKey(volumeID: volume)
    }

    static func matchesHistory(_ recorded: String, at path: String) -> Bool {
        guard recorded.contains(":"), !recorded.contains("/") else { return historyKey(at: path) == recorded }
        return read(path)?.legacyHistoryKey == recorded
    }
}
