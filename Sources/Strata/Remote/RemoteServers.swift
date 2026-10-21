import Foundation
import Synchronization

extension Notification.Name {
    /// A server was saved, edited or removed.
    static let remoteServersChanged = Notification.Name("StrataRemoteServersChanged")
}

/// The servers you've connected to, in the order they were added. Secrets aren't here: an S3 secret key is in your
/// login keychain (`RemoteKeychain`), SFTP logs in with your SSH keys or a password typed each time.
enum RemoteServers {
    private static let key = "remoteServers"

    static var all: [RemoteServer] {
        get {
            guard let data = Prefs.shared.defaults.data(forKey: key),
                  let saved = try? JSONDecoder().decode([RemoteServer].self, from: data) else { return [] }
            // Only what would be accepted if typed in again.
            return saved.filter { $0.validate() == nil && UUID(uuidString: $0.id) != nil }
        }
        set {
            Prefs.shared.defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
            RemoteRegistry.update(newValue)
            NotificationCenter.default.post(name: .remoteServersChanged, object: nil)
        }
    }

    static func server(id: String) -> RemoteServer? {
        all.first { $0.id == id }
    }

    /// Saves `server` (replacing the one with its ID).
    static func save(_ server: RemoteServer) {
        var saved = all.filter { $0.id != server.id }
        if let index = all.firstIndex(where: { $0.id == server.id }) {
            saved.insert(server, at: min(index, saved.count))
        } else {
            saved.append(server)
        }
        all = saved
    }

    /// Forgets `server`, its keychain item, and its files in Strata's caches.
    static func remove(_ server: RemoteServer) {
        all = all.filter { $0.id != server.id }
        RemoteKeychain.shared.delete(server)
        Task {
            await RemoteSessions.shared.disconnect(server.id)
            await RemoteFiles.shared.discard(server.id)
        }
    }

    /// Fills the registry the copies' paths are mapped with (at launch).
    static func load() {
        RemoteRegistry.update(all)
    }
}

/// The saved servers by ID, readable from any thread (mapping a copy's path to its server happens off the main thread).
nonisolated enum RemoteRegistry {
    private static let servers = Mutex<[String: RemoteServer]>([:])

    static func update(_ list: [RemoteServer]) {
        servers.withLock { $0 = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    static func server(id: String) -> RemoteServer? {
        servers.withLock { $0[id] }
    }
}
