import Foundation

/// Servers' files, browsed as copies in Strata's caches: `Servers.noindex/<server ID>/` is the server's `/` (a bucket's
/// top), filled in folder by folder as you browse (see `RemoteFiles`). Files not fetched yet are placeholders, like a
/// container's (the right size and date, unreadable until fetched), and fetched ones are read-only and marked as
/// downloaded. Strata's own commands change the server first and then list the folder again; anything else writing
/// into a copy would be swept away, so the copies count as read-only everywhere else. Removed when Strata quits.
nonisolated enum RemoteCopies {
    static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "dev.strata.app", directoryHint: .isDirectory)
            .appending(path: "Servers.noindex", directoryHint: .isDirectory).standardizedFileURL
    }()

    private static let rootPath = root.path

    /// Whether `url` is in a server's copy (or is the Servers folder itself).
    static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// The server whose copy holds `url`, and the copy's top folder (the server's `/`).
    static func server(containing url: URL) -> (server: RemoteServer, top: URL)? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let id = path.dropFirst(rootPath.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard UUID(uuidString: id) != nil, let server = RemoteRegistry.server(id: id) else { return nil }
        return (server, top(of: id))
    }

    static func top(of id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    /// The server's own path for `url` in the copy at `top` ("/" for the top), without following links.
    static func remotePath(of url: URL, top: URL) -> String? {
        let path = url.standardizedFileURL.path
        let topPath = top.standardizedFileURL.path
        if path == topPath { return "/" }
        guard path.hasPrefix(topPath + "/") else { return nil }
        return String(path.dropFirst(topPath.count))
    }

    /// Where the server's `path` is in the copy at `top`.
    static func url(forRemotePath path: String, top: URL) -> URL {
        let parts = ContainerCopies.normalized(path)
        return parts.reduce(top) { $0.appending(path: $1) }
    }

    /// A server's copy, made if needed (0700, like the rest of Strata's caches).
    static func prepare(_ server: RemoteServer) throws -> URL {
        let top = top(of: server.id)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return top
    }

    /// The server's address and path for display ("deploy@web-1:/srv/app", "s3://bucket/photos").
    static func displayPath(_ url: URL) -> String? {
        guard let (server, top) = server(containing: url), let path = remotePath(of: url, top: top) else { return nil }
        switch server.kind {
        case .sftp: return "\(server.user.map { $0 + "@" } ?? "")\(server.host):\(path)"
        case .s3: return "s3://\(server.bucket ?? "")\(path == "/" ? "" : path)"
        }
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && ContainerCopies.isPlaceholderMode(info.st_mode)
    }

    /// Moves every copy aside (instantly) for `removeSetAside` to delete: at quit, and at launch for what a crash left.
    static func setAsideForRemoval() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let aside = root.deletingLastPathComponent().appending(path: "Servers-removed-\(UUID().uuidString).noindex")
        try? FileManager.default.moveItem(at: root, to: aside)
    }

    static func removeSetAside() {
        let parent = root.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix("Servers-removed-") {
            Archiver.removeTree(parent.appending(path: name))
        }
    }

    /// One server's copy, gone (disconnecting, removing the server).
    static func remove(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        let top = top(of: id)
        guard top.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return }
        Archiver.removeTree(top)
    }
}
