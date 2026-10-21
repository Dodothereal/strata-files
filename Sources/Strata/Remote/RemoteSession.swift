import Foundation

extension Notification.Name {
    /// A server connected or disconnected (`object`: its ID).
    static let remoteSessionsChanged = Notification.Name("StrataRemoteSessionsChanged")
}

nonisolated enum RemoteError: Error, LocalizedError, Equatable {
    case unknownServer
    case noSecret
    case exists(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .unknownServer: String(localized: "That server isn’t saved in Strata anymore.")
        case .noSecret: String(localized: "There’s no secret key for this bucket in your keychain. Edit the server to add it.")
        case .exists(let name): String(localized: "“\(name)” is already there.")
        case .refused(let message): message
        }
    }
}

/// What Strata does on a server, whatever kind it is. Paths are the server's: absolute, "/" at the top (for a bucket,
/// "/" is the bucket itself and a folder is a key prefix). What an item is (file, folder, link) is always asked of the
/// server, never taken from Strata's copy, which may be out of date.
nonisolated protocol RemoteBackend: AnyObject, Sendable {
    /// Where browsing starts: the login's folder (SFTP), or "/".
    func home() async throws -> String
    func list(_ path: String) async throws -> [ListedEntry]
    /// At most `limit` bytes (the size it was listed with); `stop` ends it early.
    func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws
    /// Replaces what's at `path` (a file; a link there is replaced, not written through). Nothing half-written is left
    /// behind when it fails or is stopped.
    func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws
    func makeFolder(_ path: String) async throws
    /// Fails when something is already at `newPath`.
    func rename(_ path: String, to newPath: String) async throws
    /// A folder goes with everything in it; a link is removed, never followed.
    func remove(_ path: String) async throws
    /// What's at `path` now, or nil.
    func kind(of path: String) async throws -> RemoteItemKind?
    var isAlive: Bool { get }
    func close()
}

nonisolated enum RemoteItemKind: Sendable, Equatable { case file, folder, link, other }

nonisolated extension RemoteBackend {
    func exists(_ path: String) async throws -> Bool {
        try await kind(of: path) != nil
    }
}

nonisolated enum RemotePath {
    /// `name` inside the folder `path`.
    static func join(_ path: String, _ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    static func parent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else { return "/" }
        return String(trimmed[..<slash])
    }

    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - SFTP

/// An SFTP server through `ssh -s host sftp`: your SSH setup logs in; a password or a new host's fingerprint is asked
/// in a dialog (the `strata` helper as SSH_ASKPASS). Its blocking calls run on a queue of their own; cancelling the
/// task stops a transfer between chunks.
nonisolated final class SFTPBackend: RemoteBackend {
    private let client: SFTPClient
    private static let queue = DispatchQueue(label: "dev.strata.sftp", qos: .userInitiated, attributes: .concurrent)
    /// Deeper than this, deleting a folder stops (a loop of links, or a server making it up).
    private static let maxDepth = 512

    /// Starts ssh and logs in (which can wait on you, in the password dialog). Cancelling ends ssh.
    static func connect(_ server: RemoteServer, askpass: [String: String]) async throws -> SFTPBackend {
        let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: server.sshArguments,
                                    environment: askpass, connect: false)
        try await withTaskCancellationHandler {
            try await run { try client.connect() }
        } onCancel: {
            client.close()
        }
        try Task.checkCancellation()
        return SFTPBackend(client: client)
    }

    init(client: SFTPClient) {
        self.client = client
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Blocking work that stops when the task is cancelled (`stop` is set).
    private static func run<T: Sendable>(stop: StopFlag, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await run(work)
        } onCancel: {
            stop.set()
        }
    }

    var isAlive: Bool { client.isConnected }
    func close() { client.close() }

    func home() async throws -> String {
        try await Self.run { [client] in try client.realPath(".") }
    }

    func list(_ path: String) async throws -> [ListedEntry] {
        try await Self.run { [client] in
            try client.list(path).map { entry in
                let attributes = entry.attributes
                let kind: ListedEntry.Kind = attributes.isDirectory ? .directory : attributes.isSymlink ? .symlink
                    : attributes.isRegularFile ? .file : .other
                var target = ""
                var targetIsDirectory = false
                if kind == .symlink {
                    let full = RemotePath.join(path, entry.name)
                    target = (try? client.readLink(full)) ?? ""
                    targetIsDirectory = (try? client.stat(full))?.isDirectory == true
                }
                var listed = ListedEntry(name: entry.name, kind: kind, size: ListedEntry.saneSize(Int64(clamping: attributes.size ?? 0)),
                                         mode: (attributes.permissions ?? 0o644) & 0o7777,
                                         modified: attributes.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                         linkTarget: target)
                listed.targetIsDirectory = targetIsDirectory
                return listed
            }
        }
    }

    func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        try await Self.run(stop: stop) { [client] in
            try client.download(path, to: destination, limit: limit, progress: progress, stop: { stop.isSet })
        }
    }

    func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        let permissions = ((try? FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions]) as? NSNumber)
            .map { UInt32($0.uint16Value) & 0o777 } ?? 0o644
        try await Self.run(stop: stop) { [client] in
            // Written under a temporary name next to it, then put in place: a stopped or failed copy never leaves a
            // half-written file, and a link at the name is replaced rather than written through.
            let temp = RemotePath.join(RemotePath.parent(path), ".\(RemotePath.name(path)).strata-\(UUID().uuidString.prefix(8))")
            do {
                try client.upload(source, to: temp, permissions: permissions, modificationDate: modified, progress: progress, stop: { stop.isSet })
                if client.canReplace {
                    try client.replace(path, with: temp)
                } else {
                    // Without one-step replacing: a file (or link) in the way goes first. Never a folder.
                    if let existing = try? client.lstat(path) {
                        guard !existing.isDirectory else { throw RemoteError.exists(RemotePath.name(path)) }
                        try client.removeFile(path)
                    }
                    try client.rename(temp, to: path)
                }
            } catch {
                try? client.removeFile(temp)
                throw error
            }
        }
    }

    func makeFolder(_ path: String) async throws {
        try await Self.run { [client] in try client.makeFolder(path) }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await Self.run { [client] in
            if (try? client.lstat(newPath)) != nil { throw RemoteError.exists(RemotePath.name(newPath)) }
            try client.rename(path, to: newPath)
        }
    }

    func remove(_ path: String) async throws {
        try await Self.run { [client] in try Self.removeTree(path, client: client) }
    }

    /// Depth first with a list of its own (no deep recursion). Whether each item is a folder is asked of the server
    /// itself (lstat), so a link to a folder is removed as a link: what it points to is never touched.
    private static func removeTree(_ root: String, client: SFTPClient) throws {
        guard try client.lstat(root).isDirectory else { return try client.removeFile(root) }
        var stack: [(path: String, depth: Int, emptied: Bool)] = [(root, 0, false)]
        while let (path, depth, emptied) = stack.popLast() {
            if emptied {
                try client.removeFolder(path)
                continue
            }
            guard depth < maxDepth else { throw RemoteError.refused(String(localized: "That folder goes too deep to delete from Strata.")) }
            stack.append((path, depth, true))
            for entry in try client.list(path) {
                // A name that can't be one isn't followed anywhere; the folder then can't be emptied, and says so.
                guard ContainerCopies.isSafeName(entry.name) else { continue }
                let child = RemotePath.join(path, entry.name)
                // The listing's word for it may follow links: a folder is checked before going inside.
                if entry.attributes.isDirectory, try client.lstat(child).isDirectory {
                    stack.append((child, depth + 1, false))
                } else {
                    try client.removeFile(child)
                }
            }
        }
    }

    func kind(of path: String) async throws -> RemoteItemKind? {
        try await Self.run { [client] in
            do {
                let attributes = try client.lstat(path)
                return attributes.isDirectory ? .folder : attributes.isSymlink ? .link : attributes.isRegularFile ? .file : .other
            } catch SFTPError.status(SFTPError.noSuchFile, _) {
                return nil
            }
        }
    }
}

// MARK: - S3

/// A bucket on S3 or an S3-compatible service. Nothing here ever acts on the bucket itself: every change needs a key.
nonisolated final class S3Backend: RemoteBackend {
    private let client: S3Client

    convenience init(_ server: RemoteServer, credentials: RemoteKeychain) throws {
        guard server.bucket != nil, server.region != nil, server.accessKeyID != nil else { throw RemoteError.unknownServer }
        guard let secret = credentials.secret(for: server) else { throw RemoteError.noSecret }
        try self.init(server, secret: secret)
    }

    /// A proposed credential stays private to this backend until its connection is verified and saved.
    init(_ server: RemoteServer, secret: String) throws {
        guard let bucket = server.bucket, let region = server.region, let keyID = server.accessKeyID else { throw RemoteError.unknownServer }
        client = S3Client(host: server.host, port: server.port, bucket: bucket, region: region, pathStyle: server.pathStyle ?? false,
                          credentials: S3Credentials(accessKeyID: keyID, secretAccessKey: secret))
    }

    /// Over `client` as it is (tests answer its requests themselves).
    init(client: S3Client) {
        self.client = client
    }

    var isAlive: Bool { true }
    func close() {}

    /// "/photos/2026" → "photos/2026".
    private static func key(_ path: String) -> String {
        String(path.drop { $0 == "/" })
    }

    private static func prefix(_ path: String) -> String {
        let key = key(path)
        return key.isEmpty ? "" : (key.hasSuffix("/") ? key : key + "/")
    }

    /// A key to change: never "", which would be the bucket itself.
    private static func changeable(_ path: String) throws -> String {
        let key = key(path)
        guard !key.isEmpty else { throw RemoteError.refused(String(localized: "The bucket itself can’t be changed from Strata.")) }
        return key
    }

    func home() async throws -> String { "/" }

    func list(_ path: String) async throws -> [ListedEntry] {
        let prefix = Self.prefix(path)
        return try await client.list(prefix).compactMap { item in
            guard item.key.hasPrefix(prefix) else { return nil }
            var name = String(item.key.dropFirst(prefix.count))
            if item.isFolder, name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return ListedEntry(name: name, kind: item.isFolder ? .directory : .file, size: ListedEntry.saneSize(item.size),
                               mode: item.isFolder ? 0o755 : 0o644, modified: item.modified, linkTarget: "")
        }
    }

    /// Structured: stopping (cancelling the task) cancels the request.
    func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        guard !stop.isSet else { throw SFTPError.stopped }
        try await client.download(Self.changeable(path), to: destination, limit: limit, progress: progress, stop: stop)
    }

    /// One PUT: the object appears whole or not at all.
    func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        guard !stop.isSet else { throw SFTPError.stopped }
        try await client.upload(source, to: Self.changeable(path), progress: progress)
    }

    func makeFolder(_ path: String) async throws {
        _ = try Self.changeable(path)
        try await client.makeFolder(Self.prefix(path))
    }

    func rename(_ path: String, to newPath: String) async throws {
        let from = try Self.changeable(path), to = try Self.changeable(newPath)
        if try await exists(newPath) { throw RemoteError.exists(RemotePath.name(newPath)) }
        if try await client.head(from) != nil {
            // Copied (and the copy confirmed), then the old one removed.
            try await client.copy(from, to: to)
            try await client.delete(from)
            return
        }
        // A folder is every key under its prefix: all copied first, then the old ones removed.
        let fromPrefix = Self.prefix(path), toPrefix = Self.prefix(newPath)
        let items = try await client.listAll(fromPrefix).filter { $0.key.hasPrefix(fromPrefix) }
        for item in items { try await client.copy(item.key, to: toPrefix + item.key.dropFirst(fromPrefix.count)) }
        if items.isEmpty { try await client.makeFolder(toPrefix) }
        for item in items { try await client.delete(item.key) }
    }

    func remove(_ path: String) async throws {
        let key = try Self.changeable(path)
        if try await client.head(key) != nil { return try await client.delete(key) }
        let prefix = Self.prefix(path)
        for item in try await client.listAll(prefix) where item.key.hasPrefix(prefix) {
            try await client.delete(item.key)
        }
    }

    func kind(of path: String) async throws -> RemoteItemKind? {
        let key = Self.key(path)
        if key.isEmpty { return .folder }
        if try await client.head(key) != nil { return .file }
        if try await !client.list(Self.prefix(path)).isEmpty { return .folder }
        return try await client.head(Self.prefix(path)) != nil ? .folder : nil
    }
}

// MARK: - Sessions

/// Which servers are connected, for the sidebar (kept by `RemoteSessions` as connections come and go).
@MainActor enum RemoteStatus {
    static var connected: Set<String> = []
}

/// One connection per server, made when it's first needed and made again if it dropped.
actor RemoteSessions {
    typealias ServerLookup = @Sendable (String) -> RemoteServer?
    typealias Connector = @Sendable (RemoteServer) async throws -> any RemoteBackend
    typealias StatusChange = @Sendable (String, Bool) async -> Void

    static let shared = RemoteSessions(server: { RemoteRegistry.server(id: $0) }, connect: makeBackend,
                                       changed: { await announce($0, connected: $1) })

    private let server: ServerLookup
    private let connect: Connector
    private let changed: StatusChange

    init(server: @escaping ServerLookup, connect: @escaping Connector, changed: @escaping StatusChange) {
        self.server = server
        self.connect = connect
        self.changed = changed
    }

    private struct Attempt {
        let token: UUID
        let task: Task<any RemoteBackend, Error>
    }

    private var backends: [String: any RemoteBackend] = [:]
    private var connecting: [String: Attempt] = [:]
    private var replacements: [String: RemoteSessionReplacement] = [:]

    func backend(for id: String) async throws -> any RemoteBackend {
        guard replacements[id] == nil else { throw CancellationError() }
        while let backend = backends[id] {
            if backend.isAlive { return backend }
            backends[id] = nil
            backend.close()
            await changed(id, false)
            guard replacements[id] == nil else { throw CancellationError() }
            // A status callback can yield to another caller that has already reconnected this server.
        }
        let attempt: Attempt
        if let pending = connecting[id] {
            attempt = pending
        } else {
            guard let server = server(id) else { throw RemoteError.unknownServer }
            let token = UUID()
            let task = Task<any RemoteBackend, Error> { try await establish(server, for: id, token: token) }
            attempt = Attempt(token: token, task: task)
            // Registered before anything awaits, so two panes share one connection and one password dialog.
            connecting[id] = attempt
        }
        let backend = try await attempt.task.value
        // All waiters revalidate after resuming, including when disconnection happened during a status update.
        guard backends[id] === backend, backend.isAlive else { throw CancellationError() }
        return backend
    }

    /// Only the producer publishes or closes its result. Waiters never adopt a cancelled attempt or clear a newer one.
    private func establish(_ server: RemoteServer, for id: String, token: UUID) async throws -> any RemoteBackend {
        do {
            let backend = try await connect(server)
            guard connecting[id]?.token == token, !Task.isCancelled else {
                backend.close()
                throw CancellationError()
            }
            connecting[id] = nil
            backends[id] = backend
            await changed(id, true)
            return backend
        } catch {
            if connecting[id]?.token == token { connecting[id] = nil }
            throw error
        }
    }

    func isConnected(_ id: String) -> Bool {
        backends[id]?.isAlive == true
    }

    /// A failed read retires only the connection it used. Explicit disconnect also cancels pending work; an old
    /// read must never cancel a new login or revoke a replacement's reservation.
    func retire(_ backend: any RemoteBackend, for id: String) async {
        guard backends[id] === backend else { return }
        backends[id] = nil
        backend.close()
        await changed(id, false)
    }

    func disconnect(_ id: String) async {
        replacements.removeValue(forKey: id)?.invalidate()
        connecting.removeValue(forKey: id)?.task.cancel()
        let had = backends.removeValue(forKey: id)
        had?.close()
        if had != nil { await changed(id, false) }
    }

    /// Stop readers from reconnecting to the old definition while its copies and saved settings change. Readers
    /// fail promptly instead of waiting: copy cleanup may itself be waiting for those reads to finish.
    func reserveReplacement(for id: String) async throws -> RemoteSessionReplacement {
        try Task.checkCancellation()
        let replacement = RemoteSessionReplacement(serverID: id)
        replacements.removeValue(forKey: id)?.invalidate()
        replacements[id] = replacement
        connecting.removeValue(forKey: id)?.task.cancel()
        let previous = backends.removeValue(forKey: id)
        previous?.close()
        if previous != nil { await changed(id, false) }
        guard replacements[id] === replacement, !Task.isCancelled else {
            release(replacement)
            throw CancellationError()
        }
        return replacement
    }

    func release(_ replacement: RemoteSessionReplacement) {
        replacement.invalidate()
        if replacements[replacement.serverID] === replacement { replacements[replacement.serverID] = nil }
    }

    /// The caller owns the backend until true is returned. Once accepted, only this pool closes it, including if
    /// a status callback disconnects it before this method returns. Saving runs at the coordinator's commit point.
    func install(_ backend: any RemoteBackend, replacing replacement: RemoteSessionReplacement,
                 save: @escaping @MainActor @Sendable () throws -> Void) async throws -> Bool {
        guard replacements[replacement.serverID] === replacement, replacement.isValid, !Task.isCancelled else {
            throw CancellationError()
        }
        try await save()
        guard replacements[replacement.serverID] === replacement, replacement.isValid else { return false }
        replacements[replacement.serverID] = nil
        replacement.invalidate()
        backends[replacement.serverID] = backend
        await changed(replacement.serverID, true)
        return true
    }

    nonisolated private static func makeBackend(_ server: RemoteServer) async throws -> any RemoteBackend {
        try await RemoteConnector.native.connect(server, server.kind == .s3 ? RemoteKeychain.shared.secret(for: server) : nil)
    }

    @MainActor private static func announce(_ id: String, connected: Bool) {
        if connected { RemoteStatus.connected.insert(id) } else { RemoteStatus.connected.remove(id) }
        NotificationCenter.default.post(name: .remoteSessionsChanged, object: id)
    }
}

/// A replacement can be revoked by a disconnect while its owner is waiting on another actor.
nonisolated final class RemoteSessionReplacement: Sendable {
    let serverID: String
    private let invalidated = StopFlag()
    var isValid: Bool { !invalidated.isSet }
    fileprivate init(serverID: String) { self.serverID = serverID }
    fileprivate func invalidate() { invalidated.set() }
}

/// Makes a private backend from the exact proposed settings; it does not publish it or write credentials.
nonisolated struct RemoteConnector: Sendable {
    let connect: @Sendable (RemoteServer, String?) async throws -> any RemoteBackend

    static let native = RemoteConnector { server, secret in
        switch server.kind {
        case .sftp: return try await SFTPBackend.connect(server, askpass: await askpassEnvironment(for: server))
        case .s3:
            guard let secret else { throw RemoteError.noSecret }
            return try S3Backend(server, secret: secret)
        }
    }

    /// ssh asks for passwords and new hosts' fingerprints through the `strata` helper, in your language.
    @MainActor private static func askpassEnvironment(for server: RemoteServer) -> [String: String] {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/strata")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return [:] }
        return [
            "SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "STRATA_ASKPASS": "1",
            "STRATA_ASKPASS_LOGIN_TITLE": String(localized: "Log in to “\(server.name)”", comment: "Password dialog for an SFTP server"),
            "STRATA_ASKPASS_TRUST_TITLE": String(localized: "Connect to “\(server.name)”?", comment: "Dialog for a server not seen before"),
            "STRATA_ASKPASS_TRUST_NOTE": String(localized: "This Mac hasn’t connected to this server before. If you can, check that its fingerprint below matches the server’s."),
            "STRATA_ASKPASS_LOGIN": String(localized: "Log In"),
            "STRATA_ASKPASS_CONNECT": String(localized: "Connect", comment: "Button: connect to the server"),
            "STRATA_ASKPASS_CANCEL": String(localized: "Cancel"),
        ]
    }
}
