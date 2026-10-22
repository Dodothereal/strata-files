import Foundation
import Synchronization

extension Notification.Name {
    /// A server was saved, edited or removed.
    static let remoteServersChanged = Notification.Name("StrataRemoteServersChanged")
}

/// The live application's saved servers. Independent environments own their store, registry and credentials together.
enum RemoteServers {
    static let store = RemoteServerStore(preferences: .shared, credentials: .shared, registry: RemoteRegistry.shared,
                                        notifications: .default)
    static var all: [RemoteServer] { store.all }
    static func server(id: String) -> RemoteServer? { store.server(id: id) }

    /// Forgets this confirmed definition, its credentials and its cached files, without affecting a later edit.
    static func remove(_ server: RemoteServer) {
        RemoteConnections.shared.remove(server) { store.forget(server) }
    }

    static func load() { store.load() }
}

/// The servers you've connected to, in their saved order. Credentials stay in the owning keychain, never preferences.
final class RemoteServerStore {
    private let preferences: Prefs
    let credentials: RemoteKeychain
    let registry: RemoteServerRegistry
    private let notifications: NotificationCenter
    private let key = "remoteServers"

    init(preferences: Prefs, credentials: RemoteKeychain, registry: RemoteServerRegistry,
         notifications: NotificationCenter) {
        self.preferences = preferences
        self.credentials = credentials
        self.registry = registry
        self.notifications = notifications
    }

    var all: [RemoteServer] {
        guard let data = preferences.defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([RemoteServer].self, from: data) else { return [] }
        return saved.filter { $0.validate() == nil && RemoteServer.isValidID($0.id) }
    }

    func server(id: String) -> RemoteServer? { all.first { $0.id == id } }

    func save(_ server: RemoteServer, secret: String? = nil) throws {
        guard RemoteServer.isValidID(server.id) else { throw RemoteError.unknownServer }
        if let problem = server.validate() { throw RemoteError.refused(problem.message) }
        if server.kind == .s3, let secret, !credentials.setSecret(secret, for: server) {
            throw RemoteError.refused(String(localized: "The secret key couldn’t be saved in your keychain."))
        }
        let previous = all
        var saved = previous.filter { $0.id != server.id }
        if let index = previous.firstIndex(where: { $0.id == server.id }) {
            saved.insert(server, at: min(index, saved.count))
        } else {
            saved.append(server)
        }
        persist(saved)
    }

    /// No suspension or work after notification: an observer may immediately save this ID with a new secret.
    @discardableResult
    func forget(_ server: RemoteServer) -> Bool {
        guard self.server(id: server.id) == server else { return false }
        guard credentials.delete(server) else { return false }
        persist(all.filter { $0.id != server.id })
        return true
    }

    func load() { registry.update(all) }

    private func persist(_ servers: [RemoteServer]) {
        preferences.defaults.set(try? JSONEncoder().encode(servers), forKey: key)
        registry.update(servers)
        notifications.post(name: .remoteServersChanged, object: self)
    }
}

/// Mapping cached paths happens off the main thread; each environment publishes its own immutable definitions here.
nonisolated final class RemoteServerRegistry: Sendable {
    private let servers = Mutex<[String: RemoteServer]>([:])

    func update(_ list: [RemoteServer]) {
        servers.withLock { $0 = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    func server(id: String) -> RemoteServer? { servers.withLock { $0[id] } }
}

nonisolated enum RemoteRegistry {
    static let shared = RemoteServerRegistry()
    static func update(_ list: [RemoteServer]) { shared.update(list) }
    static func server(id: String) -> RemoteServer? { shared.server(id: id) }
}
