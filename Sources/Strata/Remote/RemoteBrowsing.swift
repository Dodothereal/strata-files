import Foundation

/// Opening a saved server keeps its session pool and cached-copy owner together. Presentation chooses whether to
/// connect only (a workspace) or resolve the starting folder (a sidebar action).
nonisolated struct RemoteBrowsing: Sendable {
    let prepare: @Sendable (RemoteServer) throws -> URL
    let backend: @Sendable (String) async throws -> any RemoteBackend
    let serverBackend: @Sendable (RemoteServer) async throws -> any RemoteBackend
    let isCurrent: @Sendable (RemoteServer, URL) -> Bool
    let reveal: @Sendable (URL) async -> Bool

    @MainActor static let live = RemoteBrowsing(sessions: .shared, files: .shared)

    init(prepare: @escaping @Sendable (RemoteServer) throws -> URL,
         backend: @escaping @Sendable (String) async throws -> any RemoteBackend,
         reveal: @escaping @Sendable (URL) async -> Bool) {
        self.prepare = prepare
        self.backend = backend
        serverBackend = { try await backend($0.id) }
        isCurrent = { _, _ in true }
        self.reveal = reveal
    }

    init(prepare: @escaping @Sendable (RemoteServer) throws -> URL,
         backend: @escaping @Sendable (String) async throws -> any RemoteBackend,
         serverBackend: @escaping @Sendable (RemoteServer) async throws -> any RemoteBackend,
         isCurrent: @escaping @Sendable (RemoteServer, URL) -> Bool,
         reveal: @escaping @Sendable (URL) async -> Bool) {
        self.prepare = prepare
        self.backend = backend
        self.serverBackend = serverBackend
        self.isCurrent = isCurrent
        self.reveal = reveal
    }

    func connect(_ server: RemoteServer) async throws {
        _ = try await connection(server)
    }

    func open(_ server: RemoteServer) async throws -> URL {
        let (top, backend) = try await connection(server)
        var start = server.path ?? ""
        if start.isEmpty { start = try await backend.home() }
        try Task.checkCancellation()
        guard isCurrent(server, top) else { throw CancellationError() }
        let folder = RemoteCopies.url(forRemotePath: start, top: top)
        let found = await reveal(folder)
        try Task.checkCancellation()
        guard isCurrent(server, top) else { throw CancellationError() }
        return found ? folder : top
    }

    private func connection(_ server: RemoteServer) async throws -> (URL, any RemoteBackend) {
        try Task.checkCancellation()
        let top = try prepare(server)
        guard isCurrent(server, top) else { throw CancellationError() }
        let backend = try await serverBackend(server)
        try Task.checkCancellation()
        guard isCurrent(server, top) else { throw CancellationError() }
        return (top, backend)
    }
}

extension RemoteBrowsing {
    init(sessions: RemoteSessions, files: RemoteFiles) {
        let copies = files.copies
        self.init(prepare: { try copies.prepare($0) }, backend: { try await sessions.backend(for: $0) },
                  serverBackend: { try await sessions.backend(for: $0) },
                  isCurrent: { server, top in copies.server(containing: top)?.server == server },
                  reveal: { await files.reveal($0) })
    }
}
