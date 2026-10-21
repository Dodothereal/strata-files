import Foundation

/// Persistence is separate from connecting. A proposed secret is written only at the successful attempt's commit
/// point; a failed or cancelled attempt has no registry entry or keychain change to roll back.
struct RemoteConnectionCatalog {
    let servers: () -> [RemoteServer]
    let secret: (RemoteServer) -> String?
    let save: (RemoteServer, String?) throws -> Void

    static let live = RemoteConnectionCatalog(servers: { RemoteServers.all }, secret: { RemoteKeychain.shared.secret(for: $0) },
        save: { server, secret in
            if let secret, !RemoteKeychain.shared.setSecret(secret, for: server) {
                throw RemoteError.refused(String(localized: "The secret key couldn’t be saved in your keychain."))
            }
            RemoteServers.save(server)
        })
}

nonisolated struct RemoteConnectionRequest: Sendable {
    let id: UUID
    fileprivate let stopped: StopFlag
    fileprivate let task: Task<RemoteServer, Error>
    var isCancelled: Bool { stopped.isSet }

    func cancel() { stopped.set(); task.cancel() }

    var value: RemoteServer {
        get async throws {
            try await withTaskCancellationHandler { try await task.value } onCancel: { cancel() }
        }
    }
}

/// Shared by the application's sheets. Connections authenticate independently; only the short handoff that retires
/// old copies and publishes a verified connection is serialized per server. A cancelled slow login cannot hold up
/// a retry, and old cleanup cannot erase a newer connection's files or credentials.
final class RemoteConnections {
    static let shared: RemoteConnections = makeShared()

    private static func makeShared() -> RemoteConnections {
        RemoteConnections(catalog: .live, sessions: RemoteSessions.shared, connector: .native,
                          discard: discardCopies, disconnected: announceDisconnection)
    }

    private static func discardCopies(_ id: String) async { await RemoteFiles.shared.discard(id) }
    private static func announceDisconnection(_ id: String) {
        NotificationCenter.default.post(name: .remoteServerDisconnected, object: id)
    }

    private let catalog: RemoteConnectionCatalog
    private let sessions: RemoteSessions
    private let connector: RemoteConnector
    private let discard: @MainActor (String) async -> Void
    private let disconnected: (String) -> Void
    private var current: [String: RemoteConnectionRequest] = [:]
    private struct Handoff { let id: UUID; let task: Task<Bool, Error> }
    private var handoffs: [String: Handoff] = [:]

    init(catalog: RemoteConnectionCatalog, sessions: RemoteSessions, connector: RemoteConnector,
         discard: @escaping @MainActor (String) async -> Void, disconnected: @escaping (String) -> Void) {
        self.catalog = catalog
        self.sessions = sessions
        self.connector = connector
        self.discard = discard
        self.disconnected = disconnected
    }

    var savedServers: [RemoteServer] { catalog.servers() }
    func hasSecret(for server: RemoteServer) -> Bool { catalog.secret(server) != nil }

    @discardableResult
    func connect(_ server: RemoteServer, secret: String? = nil) -> RemoteConnectionRequest {
        let id = UUID(), stopped = StopFlag()
        let previous = savedServers.first { $0.id == server.id }
        let proposedSecret = server.kind == .s3 ? secret : nil
        let previousSecret: String?
        do {
            guard UUID(uuidString: server.id) != nil else { throw RemoteError.unknownServer }
            if let problem = server.validate() { throw RemoteError.refused(problem.message) }
            previousSecret = server.kind == .s3 ? catalog.secret(server) : nil
            if server.kind == .s3, proposedSecret == nil && previousSecret == nil { throw RemoteError.noSecret }
        } catch {
            return RemoteConnectionRequest(id: id, stopped: stopped, task: Task { throw error })
        }
        cancel(server.id)
        let task = Task { [self] in
            defer { if current[server.id]?.id == id { current[server.id] = nil } }
            try checkCurrent(server.id, id: id, stopped: stopped)
            let backend = try await connector.connect(server, proposedSecret ?? previousSecret)
            var installed = false
            defer { if !installed { backend.close() } }
            try checkCurrent(server.id, id: id, stopped: stopped)
            if server.kind == .s3 { _ = try await backend.list("/") }
            try checkCurrent(server.id, id: id, stopped: stopped)
            installed = try await publish(backend, server: server, secret: proposedSecret, previous: previous,
                previousSecret: previousSecret, id: id, stopped: stopped)
            guard installed else { throw CancellationError() }
            return server
        }
        let request = RemoteConnectionRequest(id: id, stopped: stopped, task: task)
        current[server.id] = request
        return request
    }

    /// Removing or explicitly disconnecting a saved server also stops private attempts that have not published yet.
    func cancel(_ serverID: String) { current.removeValue(forKey: serverID)?.cancel() }

    private func checkCurrent(_ serverID: String, id: UUID, stopped: StopFlag) throws {
        guard current[serverID]?.id == id, !stopped.isSet, !Task.isCancelled else { throw CancellationError() }
    }

    private func publish(_ backend: any RemoteBackend, server: RemoteServer, secret: String?, previous: RemoteServer?,
                         previousSecret: String?, id: UUID, stopped: StopFlag) async throws -> Bool {
        let preceding = handoffs[server.id]?.task
        let handoffID = UUID()
        let task = Task { [self] in
            if let preceding { _ = try? await preceding.value }
            try checkCurrent(server.id, id: id, stopped: stopped)
            guard savedServers.first(where: { $0.id == server.id }) == previous else { throw CancellationError() }
            let replacement = try await sessions.reserveReplacement(for: server.id)
            do {
                try checkCurrent(server.id, id: id, stopped: stopped)
                guard savedServers.first(where: { $0.id == server.id }) == previous else { throw CancellationError() }
                // A changed login can expose different files even when the host and bucket stay the same.
                let changedLogin = previous?.kind != server.kind || previous?.accessKeyID != server.accessKeyID || (secret != nil && secret != previousSecret)
                if let previous, previous.reachesSomewhereElse(than: server) || changedLogin {
                    await discard(server.id)
                    try checkCurrent(server.id, id: id, stopped: stopped)
                    disconnected(server.id)
                }
                try checkCurrent(server.id, id: id, stopped: stopped)
                return try await sessions.install(backend, replacing: replacement) { [self] in
                    try checkCurrent(server.id, id: id, stopped: stopped)
                    guard replacement.isValid, savedServers.first(where: { $0.id == server.id }) == previous else {
                        throw CancellationError()
                    }
                    // No suspension between the last ownership check and saving. Once this succeeds, cancellation
                    // cannot undo the committed server; a later disconnect still prevents publishing its backend.
                    try catalog.save(server, secret)
                    if current[server.id]?.id == id { current[server.id] = nil }
                }
            } catch {
                await sessions.release(replacement)
                throw error
            }
        }
        handoffs[server.id] = Handoff(id: handoffID, task: task)
        defer { if handoffs[server.id]?.id == handoffID { handoffs[server.id] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
