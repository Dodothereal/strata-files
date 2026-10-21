import Foundation

/// Opening a saved server keeps its session pool and cached-copy owner together. Presentation chooses whether to
/// connect only (a workspace) or resolve the starting folder (a sidebar action).
nonisolated struct RemoteBrowsing: Sendable {
    let prepare: @Sendable (RemoteServer) throws -> URL
    let backend: @Sendable (String) async throws -> any RemoteBackend
    let reveal: @Sendable (URL) async -> Bool

    @MainActor static let live = RemoteBrowsing(sessions: .shared, files: .shared)

    func connect(_ server: RemoteServer) async throws {
        _ = try await connection(server)
    }

    func open(_ server: RemoteServer) async throws -> URL {
        let (top, backend) = try await connection(server)
        var start = server.path ?? ""
        if start.isEmpty { start = try await backend.home() }
        try Task.checkCancellation()
        let folder = RemoteCopies.url(forRemotePath: start, top: top)
        let found = await reveal(folder)
        try Task.checkCancellation()
        return found ? folder : top
    }

    private func connection(_ server: RemoteServer) async throws -> (URL, any RemoteBackend) {
        try Task.checkCancellation()
        let top = try prepare(server)
        let backend = try await backend(server.id)
        try Task.checkCancellation()
        return (top, backend)
    }
}

extension RemoteBrowsing {
    init(sessions: RemoteSessions, files: RemoteFiles) {
        let copies = files.copies
        self.init(prepare: { try copies.prepare($0) }, backend: { try await sessions.backend(for: $0) },
                  reveal: { await files.reveal($0) })
    }
}
