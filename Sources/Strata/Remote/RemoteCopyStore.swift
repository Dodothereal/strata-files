import Foundation

/// A server environment's copy locations and server lookup travel together. Paths from another environment never
/// resolve here, even when both environments use the same saved server ID.
nonisolated struct RemoteCopyStore: Sendable {
    let root: URL
    private let rootPath: String
    private let lookup: @Sendable (String) -> RemoteServer?

    init(root: URL, server: @escaping @Sendable (String) -> RemoteServer?) {
        self.root = root.standardizedFileURL
        rootPath = self.root.path
        lookup = server
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    func server(containing url: URL) -> (server: RemoteServer, top: URL)? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let id = path.dropFirst(rootPath.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard UUID(uuidString: id) != nil, let server = lookup(id), server.id == id else { return nil }
        return (server, top(of: id))
    }

    func top(of id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    func prepare(_ server: RemoteServer) throws -> URL {
        guard UUID(uuidString: server.id) != nil else { throw RemoteError.unknownServer }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(parent) }
        if mkdirat(parent, server.id, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        var info = stat()
        guard fstatat(parent, server.id, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return top(of: server.id)
    }

    func displayPath(_ url: URL) -> String? {
        guard let (server, top) = server(containing: url), let path = RemoteCopies.remotePath(of: url, top: top) else { return nil }
        switch server.kind {
        case .sftp: return "\(server.user.map { $0 + "@" } ?? "")\(server.host):\(path)"
        case .s3: return "s3://\(server.bucket ?? "")\(path == "/" ? "" : path)"
        }
    }

    func isPlaceholder(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && ContainerCopies.isPlaceholderMode(info.st_mode)
    }

    func remove(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        let parent = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return }
        defer { close(parent) }
        Archiver.removeTree(id, in: parent)
    }
}
