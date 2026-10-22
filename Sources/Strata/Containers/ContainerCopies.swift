import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Which container a copy is of, and how to reach its engine.
nonisolated struct ContainerSource: Codable, Sendable, Equatable {
    let socket: String
    let apiVersion: String
    let engineName: String
    let id: String
    let name: String

    var engine: ContainerEngine { ContainerEngine(socket: socket, name: engineName, apiVersion: apiVersion) }
}

/// An engine, as recorded on its Containers folder.
nonisolated struct EngineRecord: Codable, Sendable, Equatable {
    let socket: String
    let apiVersion: String
    let name: String

    init(_ engine: ContainerEngine) {
        socket = engine.socket
        apiVersion = engine.apiVersion
        name = engine.name
    }

    var engine: ContainerEngine { ContainerEngine(socket: socket, name: name, apiVersion: apiVersion) }
}

/// Container files, browsed as read-only copies in Strata's caches. `Containers/<engine>/` is the Containers folder.
/// A Compose project's containers live in a folder named after the project; every other container is a folder of its
/// own beside those. Each container folder is that container's `/`, filled in folder by folder as you browse (see
/// `ContainerFiles`). Which engine and container a folder is of is kept in an extended attribute on it, so nothing but
/// the container's own files shows inside.
///
/// Like an archive's copy (see `ArchiveCache`), nothing in it is changed from Strata; it only ever reads the container.
/// A file not fetched yet is a *placeholder*: the right size and date, but no permissions at all, so nothing can read
/// zeros from it by mistake. Links are rewritten to point inside the copy: an absolute link in a container means a path
/// in that container, never one on this Mac. Everything is removed when Strata quits.
nonisolated enum ContainerCopies {
    static let root: URL = {
        SecureStorage.caches.appending(path: "Containers.noindex", directoryHint: .isDirectory).standardizedFileURL
    }()

    private static let rootPath = root.path
    private static let sourceAttribute = "dev.strata.container"
    private static let engineAttribute = "dev.strata.engine"
    private static let sources = Mutex<[String: ContainerSource]>([:])
    private static let engines = Mutex<[String: EngineRecord]>([:])

    /// An engine's folder name: the same engine always gets the same one.
    static func engineKey(_ socket: String) -> String {
        SHA256.hash(data: Data(socket.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The engine's Containers folder, made if needed.
    static func prepare(_ engine: ContainerEngine) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootPath) {
            // Spotlight has no business indexing other machines' files (`.noindex` keeps it out).
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let folder = root.appending(path: engineKey(engine.socket), directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = EngineRecord(engine)
        try setAttribute(engineAttribute, record, on: folder)
        engines.withLock { $0[folder.path] = record }
        return folder
    }

    /// A container's folder (its `/`), made if needed. One from a Compose project is made inside that project's folder.
    static func prepare(_ container: ContainerInfo, on engine: ContainerEngine) throws -> URL {
        guard isContainerName(container.name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = try stackFolder(for: container, in: prepare(engine))
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        try record(container, on: engine, in: fd, folder: parent)
        return parent.appending(path: container.name, directoryHint: .isDirectory)
    }

    /// Where `container`'s folder goes: its Compose project's folder, or the engine's folder when it isn't in one.
    /// The project folder is made if needed. When a container's folder already has the project's name (a container on
    /// its own, called that), it stays beside the stacks, as `CopyWriter.syncContainers` places it: never inside that
    /// container's files.
    static func stackFolder(for container: ContainerInfo, in engineFolder: URL) throws -> URL {
        guard let name = stackName(container) else { return engineFolder }
        let fd = open(engineFolder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let taken = recordedSource(name, in: fd) != nil
        close(fd)
        if taken { return engineFolder }
        let stack = engineFolder.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stack, withIntermediateDirectories: true)
        return stack
    }

    /// The Compose project a container is grouped under, when that name can be a folder. Nil leaves it beside the stacks.
    static func stackName(_ container: ContainerInfo) -> String? {
        guard let project = container.compose?.project, isContainerName(project) else { return nil }
        return project
    }

    /// Makes (or keeps) the folder for `container` in the Containers folder open at `fd`, recording its source and
    /// giving it the container's date.
    static func record(_ container: ContainerInfo, on engine: ContainerEngine, in fd: Int32, folder: URL) throws {
        let name = container.name
        guard isContainerName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFDIR { CopyWriter.removeAt(fd, name) }
        mkdirat(fd, name, 0o755)
        // Two containers whose names differ only in case can't both have a folder on this disk: the first keeps it.
        guard CopyWriter.names(in: fd).contains(name) else { throw CocoaError(.fileWriteFileExists) }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(child) }
        try CopyWriter.markDownloaded(child)
        let source = ContainerSource(socket: engine.socket, apiVersion: engine.apiVersion, engineName: engine.name,
                                     id: container.id, name: name)
        let data = try JSONEncoder().encode(source)
        guard data.withUnsafeBytes({ fsetxattr(child, sourceAttribute, $0.baseAddress, $0.count, 0, 0) }) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        CopyWriter.remember(container.created, onFolder: child)
        sources.withLock { $0[folder.appending(path: name).standardizedFileURL.path] = source }
    }

    /// The container recorded on the folder named `name` in the folder open at `fd`, if any.
    static func recordedSource(_ name: String, in fd: Int32) -> ContainerSource? {
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return nil }
        defer { close(child) }
        return readAttribute(sourceAttribute, ContainerSource.self, from: child)
    }

    /// A container's name as a folder name: what Docker allows, nothing hidden.
    static func isContainerName(_ name: String) -> Bool {
        isSafeName(name) && !name.hasPrefix(".") && name.utf8.count <= 128
    }

    /// Whether `url` is the cache or inside it.
    static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// For an engine's Containers folder itself: the engine.
    static func engineFolder(_ url: URL) -> ContainerEngine? {
        guard let parts = components(url), parts.count == 1 else { return nil }
        return engineRecord(root.appending(path: parts[0], directoryHint: .isDirectory))?.engine
    }

    /// The Containers folder `url` is in or is (nil outside them).
    static func containersFolder(of url: URL) -> URL? {
        guard let first = components(url)?.first else { return nil }
        return root.appending(path: first, directoryHint: .isDirectory)
    }

    /// For a path inside a container's folder: which container it's of, and its top folder (the container's `/`).
    /// A container sits in the engine's folder, or one level down inside its Compose project.
    static func copy(containing url: URL) -> (source: ContainerSource, top: URL)? {
        guard let parts = components(url), parts.count >= 2 else { return nil }
        for depth in [2, 3] where depth <= parts.count {
            let top = parts.prefix(depth).reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
            if let source = source(of: top) { return (source, top) }
        }
        return nil
    }

    /// Whether `url` is a container's top folder.
    static func isContainerTop(_ url: URL) -> Bool {
        guard let parts = components(url), (2...3).contains(parts.count) else { return false }
        return source(of: url) != nil
    }

    /// A Compose project's folder: directly in the engine's folder, and not a container itself.
    static func isStack(_ url: URL) -> Bool {
        guard components(url)?.count == 2, engineFolder(url.deletingLastPathComponent()) != nil else { return false }
        return source(of: url) == nil
    }

    private static func components(_ url: URL) -> [String]? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let parts = path.dropFirst(rootPath.count + 1).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, !first.hasPrefix(".") else { return nil }
        return parts
    }

    private static func source(of top: URL) -> ContainerSource? {
        let path = top.standardizedFileURL.path
        if let known = sources.withLock({ $0[path] }) { return known }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let source = readAttribute(sourceAttribute, ContainerSource.self, from: fd), ContainerAPI.isContainerID(source.id),
              source.socket.hasPrefix("/"), source.name == URL(fileURLWithPath: path).lastPathComponent else { return nil }
        sources.withLock { $0[path] = source }
        return source
    }

    private static func engineRecord(_ folder: URL) -> EngineRecord? {
        let path = folder.standardizedFileURL.path
        if let known = engines.withLock({ $0[path] }) { return known }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let record = readAttribute(engineAttribute, EngineRecord.self, from: fd), record.socket.hasPrefix("/"),
              EngineDiscovery.isAPIVersion(record.apiVersion) else { return nil }
        engines.withLock { $0[path] = record }
        return record
    }

    /// Forgets what's known about the folder at `path` (it was removed).
    static func forget(_ path: String) {
        sources.withLock { cache in cache = cache.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
        engines.withLock { cache in cache = cache.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
    }

    private static func setAttribute(_ name: String, _ value: some Encodable, on folder: URL) throws {
        let data = try JSONEncoder().encode(value)
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        guard data.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func readAttribute<T: Decodable>(_ name: String, _ type: T.Type, from fd: Int32) -> T? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = fgetxattr(fd, name, &buffer, buffer.count, 0, 0)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(buffer[0..<count]))
    }

    /// `url`'s path inside the container ("/etc/hosts"); nil outside `top`.
    static func containerPath(of url: URL, top: URL) -> String? {
        let path = url.standardizedFileURL.path, topPath = top.standardizedFileURL.path
        if path == topPath { return "/" }
        guard path.hasPrefix(topPath + "/") else { return nil }
        return String(path.dropFirst(topPath.count))
    }

    /// Where the container's `path` is in the copy.
    static func url(forContainerPath path: String, top: URL) -> URL {
        normalized(path).reduce(top) { $0.appending(path: $1) }
    }

    /// How an item in a copy is shown: "web:/etc/hosts". Nil outside copies.
    static func apparentPath(_ url: URL) -> String? {
        guard let (source, top) = copy(containing: url), let path = containerPath(of: url, top: top) else { return nil }
        return "\(source.name):\(path)"
    }

    /// The components of `path` with `.` and empty parts gone and `..` taken back, stopping at `/` the way the
    /// container's root does.
    static func normalized(_ path: String, from base: [String] = []) -> [String] {
        var parts = path.hasPrefix("/") ? [] : base
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts
    }

    /// The target to give a link at container path `link` that points to `target` in the container: relative, so it
    /// resolves inside the copy, and never above its top (as `..` never goes above a container's `/`).
    static func copyLinkTarget(_ target: String, at link: String) -> String? {
        guard !target.isEmpty, !target.contains("\0"), target.utf8.count <= 4096 else { return nil }
        let folder = Array(normalized(link).dropLast())
        let resolved = normalized(target, from: folder)
        let up = Array(repeating: "..", count: folder.count)
        let parts = up + resolved
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// A name a container listing may give a copy: one path component, nothing that steps elsewhere.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }

    /// A file in a copy that hasn't been fetched from its container yet (a regular file with no permissions).
    static func isPlaceholder(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && isPlaceholderMode(info.st_mode)
    }

    /// A placeholder can't be read or written; it keeps only the container's execute bits, so a program shows as a
    /// Unix executable before it's fetched. A fetched file is always readable.
    static func isPlaceholderMode(_ mode: mode_t) -> Bool { mode & 0o666 == 0 }

    /// Removes an engine's folder, a Compose project's folder, or a container's folder. Never the cache itself, and
    /// never a folder inside a container (its files aren't Strata's to delete).
    static func remove(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return }
        let depth = path.dropFirst(rootPath.count + 1).split(separator: "/").count
        guard (1...3).contains(depth) else { return }
        // Three deep is a container in a project's folder, never a folder in a container's own files.
        if depth == 3, source(of: folder.deletingLastPathComponent()) != nil { return }
        forget(path)
        Archiver.removeTree(folder)
    }

    /// Items copied out of a copy (a container's, a server's) become ordinary files: Strata's bookkeeping (which
    /// container a folder is, folders' dates) stays behind, and they're yours to change (in the copy they're
    /// read-only). Links that would lead outside what was copied are dropped: written by another machine, they'd
    /// otherwise point into this Mac's own folders from wherever the copy lands.
    ///
    /// With `source` (what `url` was copied from), only what came from it is touched: copied into a folder that was
    /// already there (a merge), the folder's own items, links included, stay exactly as they were.
    static func finishCopyingOut(_ url: URL, from source: URL? = nil) {
        let names = [sourceAttribute, engineAttribute, "dev.strata.modified"]
        let root = url.standardizedFileURL.pathComponents
        let fm = FileManager.default
        func isFromCopy(_ path: String, _ relative: String, _ info: stat) -> Bool {
            guard let source else { return true }
            let counterpart = relative.isEmpty ? source.path : source.path + "/" + relative
            var theirs = stat()
            guard lstat(counterpart, &theirs) == 0, theirs.st_mode & S_IFMT == info.st_mode & S_IFMT else { return false }
            guard info.st_mode & S_IFMT == S_IFLNK else { return true }
            let target = try? fm.destinationOfSymbolicLink(atPath: path)
            return target != nil && target == (try? fm.destinationOfSymbolicLink(atPath: counterpart))
        }
        func leadsOutside(_ path: String) -> Bool {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
            if target.hasPrefix("/") { return true }
            var parts = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.pathComponents
            for part in target.split(separator: "/") where part != "." {
                if part == ".." {
                    guard parts.count > root.count else { return true }
                    parts.removeLast()
                } else {
                    parts.append(String(part))
                }
            }
            return !parts.starts(with: root)
        }
        /// False for what isn't the copy's (nothing under it is looked at either).
        func finish(_ path: String, _ relative: String) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0, isFromCopy(path, relative, info) else { return false }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK, leadsOutside(path) {
                unlink(path)
                return false
            }
            if kind == S_IFDIR { for name in names { removexattr(path, name, XATTR_NOFOLLOW) } }
            if kind == S_IFDIR || kind == S_IFREG, info.st_mode & 0o200 == 0 { chmod(path, (info.st_mode & 0o7777) | 0o200) }
            return true
        }
        let top = url.path
        guard finish(top, ""), let walker = fm.enumerator(atPath: top) else { return }
        while let relative = walker.nextObject() as? String {
            if !finish(top + "/" + relative, relative) { walker.skipDescendants() }
        }
    }

    /// At quit (and at launch, for anything a crash left): containers' files don't outlive Strata (a container's files
    /// can be secrets). Moved aside at once and removed in the background (`removeSetAside`), so it never holds things up.
    /// `folder`: the copies' folder (another one in tests).
    static func setAsideForRemoval(_ folder: URL = root) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let aside = folder.deletingLastPathComponent().appending(path: "Containers-removed-\(UUID().uuidString).noindex")
        try? FileManager.default.moveItem(at: folder, to: aside)
        sources.withLock { $0.removeAll() }
        engines.withLock { $0.removeAll() }
    }

    /// Removes what was set aside (beside the copies' folder, `parent`).
    static func removeSetAside(in parent: URL = root.deletingLastPathComponent()) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix("Containers-removed-") {
            Archiver.removeTree(parent.appending(path: name))
        }
    }
}

/// Strata's read-only copies: archives opened as folders and container files. Nothing inside one is changed from
/// Strata, and nothing is moved or saved into one.
nonisolated enum ReadOnlyCopies {
    static func contains(_ url: URL) -> Bool {
        contains(url, copies: .live)
    }

    static func contains(_ url: URL, copies: CopyProviders) -> Bool {
        ArchiveCache.contains(url) || ContainerCopies.contains(url) || RemoteCopies.contains(url)
            || copies.contains(url) || copies.remoteCopies.contains(url)
    }
}
