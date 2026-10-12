import AppKit

extension Notification.Name {
    /// Posted after Strata empties the Trash or deletes something for good.
    static let trashChanged = Notification.Name("StrataTrashChanged")
}

/// Your Trash: each disk's Trash folder, where an item in it came from (for Put Back), and emptying it.
enum Trash {
    /// The startup disk's Trash, in your home folder.
    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".Trash", directoryHint: .isDirectory).standardizedFileURL
    nonisolated private static let homePath = home.path
    nonisolated private static let uid = String(getuid())

    /// One disk's Trash and what's in it.
    struct Contents: Sendable {
        let folder: URL
        /// The disk's name ("Macintosh HD", "Backup").
        let disk: String
        let count: Int
    }

    /// Every Trash of yours: the home one and each other local disk's `.Trashes/<your user id>`. Only real folders
    /// count: a disk could carry a symlink there, and emptying must never reach anything outside the Trash. Network
    /// disks are left out (their server could swap a folder for a link between a check and a delete).
    nonisolated static func folders() -> [URL] {
        var result: [URL] = []
        if isRealFolder(home) { result.append(home) }
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            guard (try? volume.resourceValues(forKeys: Set(keys)))?.volumeIsLocal == true else { continue }
            let trashes = volume.appending(path: ".Trashes", directoryHint: .isDirectory)
            let mine = trashes.appending(path: uid, directoryHint: .isDirectory)
            if isRealFolder(trashes), isRealFolder(mine) { result.append(mine) }
        }
        return result
    }

    /// Whether `folder` is one of your Trash folders (judged by where it is, without listing the disks).
    nonisolated static func isTrash(_ folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        if folder.path == homePath { return true }
        let trashes = folder.deletingLastPathComponent()
        guard folder.lastPathComponent == uid, trashes.lastPathComponent == ".Trashes" else { return false }
        let volume = trashes.deletingLastPathComponent()
        return (try? volume.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    /// Whether `item` sits directly in a Trash (things inside a trashed folder can't be put back on their own).
    nonisolated static func contains(_ item: URL) -> Bool {
        isTrash(item.deletingLastPathComponent())
    }

    /// Whether `url` is in a Trash at any depth.
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(homePath + "/") { return true }
        // Other disks' Trashes: `/Volumes/<disk>/.Trashes/<uid>/…`.
        guard path.contains("/.Trashes/") else { return false }
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while folder.path != "/" {
            if isTrash(folder) { return true }
            folder.deleteLastPathComponent()
        }
        return false
    }

    /// Whether the home Trash has anything in it (for its icon). Reads at most a few entries.
    nonisolated static var isHomeEmpty: Bool {
        guard let dir = opendir(homePath) else { return true }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != ".", name != "..", name != ".DS_Store" { return false }
        }
        return true
    }

    /// What every Trash holds, per disk.
    @concurrent
    static func contents() async -> [Contents] {
        folders().map { folder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let volume = folder.path == homePath ? URL(fileURLWithPath: "/") : folder.deletingLastPathComponent().deletingLastPathComponent()
            let disk = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? volume.lastPathComponent
            return Contents(folder: folder, disk: disk, count: names.filter { $0 != ".DS_Store" }.count)
        }
    }

    // MARK: - Put Back

    /// Where each of `items` (directly in a Trash) was before it went there. History knows what Strata trashed; the
    /// Trash's records know what Finder and other apps trashed (Finder writes its records a little later). Items whose
    /// origin isn't known, or would be unsafe to restore to, are left out.
    static func originalLocations(of items: [URL]) async -> [URL: URL] {
        let items = items.filter(contains)
        guard !items.isEmpty else { return [:] }
        let moved = OperationLog.shared.movedFrom(items)
        var result: [URL: URL] = [:]
        var needRecords: [URL] = []
        for item in items {
            // History wins unless the item was put in the Trash again after Strata last moved it (by Finder, say).
            if let hit = moved[item.standardizedFileURL.path], !isInTrash(hit.from),
               hit.date.timeIntervalSince(added(item) ?? .distantPast) > -5 {
                result[item] = hit.from
            } else {
                needRecords.append(item)
            }
        }
        for (trash, inTrash) in Dictionary(grouping: needRecords, by: { $0.deletingLastPathComponent().standardizedFileURL }) {
            let (records, written) = await finderRecords(trash)
            for item in inTrash {
                // A record older than the item is about something else that once had its name.
                guard let record = records[item.lastPathComponent], let added = added(item),
                      written.timeIntervalSince(added) > -2,
                      let location = location(record, of: item, onDiskOf: trash) else { continue }
                result[item] = location
            }
        }
        return result
    }

    /// Where a record says `item` came from: its folder is relative to the root of the disk the Trash is on. Records are
    /// untrusted, so the result must stay on that disk without passing through a symlink, use plain names (never ".."),
    /// keep the item's extension, and not be in a Trash.
    nonisolated static func location(_ record: DSStore.PutBack, of item: URL, onDiskOf trash: URL) -> URL? {
        let parts = record.folder.split(separator: "/").map(String.init)
        let names = parts + [record.name]
        guard !record.name.isEmpty, !record.name.contains("/"),
              !names.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") }),
              (record.name as NSString).pathExtension.lowercased() == item.pathExtension.lowercased() else { return nil }
        // The home Trash is on the startup disk ("/"); any other is `<disk>/.Trashes/<uid>`.
        let base = trash.standardizedFileURL.path == homePath ? URL(fileURLWithPath: "/", isDirectory: true)
                                                              : trash.deletingLastPathComponent().deletingLastPathComponent()
        var info = stat()
        guard lstat(trash.path, &info) == 0 else { return nil }
        let device = info.st_dev
        var url = base
        var exists = true
        for part in parts {
            url.append(path: part, directoryHint: .isDirectory)
            // Existing folders on the way must be real folders on the Trash's disk; missing ones are made.
            guard exists else { continue }
            if lstat(url.path, &info) != 0 { exists = false; continue }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == device else { return nil }
        }
        url.append(path: record.name)
        return isInTrash(url) ? nil : url
    }

    // MARK: - Emptying

    /// Deletes everything in every Trash for good, off the main thread. Returns the items that couldn't be deleted (a
    /// locked file, say) with why. Each Trash's records file goes too: its Put Back records would be stale.
    @concurrent
    static func empty() async -> [(url: URL, error: Error)] {
        empty(folders())
    }

    /// Deletes everything in `trashes`, which must be Trash folders (see `folders()`). Before each deletion the Trash
    /// folder must still be the same real folder it was when listed.
    nonisolated static func empty(_ trashes: [URL]) -> [(url: URL, error: Error)] {
        var failures: [(url: URL, error: Error)] = []
        for folder in trashes {
            var before = stat()
            guard lstat(folder.path, &before) == 0, before.st_mode & S_IFMT == S_IFDIR else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                var now = stat()
                guard lstat(folder.path, &now) == 0, now.st_mode & S_IFMT == S_IFDIR,
                      now.st_dev == before.st_dev, now.st_ino == before.st_ino else { break }
                // Listed from the Trash itself, so each is directly inside it. removeItem deletes a symlink, not what
                // it points to, and doesn't follow links inside folders.
                let item = folder.appending(path: name)
                do {
                    try FileManager.default.removeItem(at: item)
                } catch {
                    if name != ".DS_Store" { failures.append((item, error)) }
                }
            }
        }
        return failures
    }

    // MARK: - Private

    nonisolated private static func isRealFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    nonisolated private static func added(_ item: URL) -> Date? {
        (try? item.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
    }

    /// Put Back records for one Trash and when they were written, read again only when the records file changes.
    private static var recordCache: [String: (modified: Date, records: [String: DSStore.PutBack])] = [:]

    private static func finderRecords(_ trash: URL) async -> (records: [String: DSStore.PutBack], written: Date) {
        let file = trash.appending(path: ".DS_Store")
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return ([:], .distantPast) }
        if let cached = recordCache[trash.path], cached.modified == modified { return (cached.records, modified) }
        let records = await parse(file)
        recordCache[trash.path] = (modified, records)
        return (records, modified)
    }

    @concurrent
    private static func parse(_ file: URL) async -> [String: DSStore.PutBack] {
        DSStore.putBackRecords(at: file)
    }

    static let emptySound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif",
        byReference: true)
}
