import Foundation

/// Services shared by a window and its panes. Production windows share one set; headless windows can own independent
/// preferences, transfers and visit history without changing AppKit's responder chain or presentation controllers.
final class BrowserServices {
    static let shared = BrowserServices(transfers: .shared, visits: .shared)

    let preferences: Prefs
    lazy var workspaces = Workspaces(services: self)
    lazy var connectionSettings = ServerConnectionSettings(preferences: preferences)
    lazy var savedSearches = SavedSearches(preferences: preferences)
    lazy var viewOptions = ViewOptionsWindowController(preferences: preferences)

    let transfers: TransferQueue
    let visits: Frecency
    let remote: RemoteServices
    let remoteBrowsing: RemoteBrowsing
    let copies: CopyProviders
    let openContainer: @MainActor @Sendable (String) async throws -> URL
    let directories: DirectoryReader
    let availableCapacity: @Sendable (URL) async -> Int64?
    let windows: BrowserWindows

    init(transfers: TransferQueue, visits: Frecency, directories: DirectoryReader? = nil, preferences: Prefs = .shared, windows: BrowserWindows = .native,
         availableCapacity: @escaping @Sendable (URL) async -> Int64? = BrowserLoading.freeSpace,
         remote: RemoteServices = .shared, remoteBrowsing: RemoteBrowsing? = nil, copies: CopyProviders? = nil,
         openContainer: @escaping @MainActor @Sendable (String) async throws -> URL = { id in
             let store = ContainerStore.shared
             guard let engine = store.engine, let container = store.container(id: id) else { throw ContainerAPIError.notFound }
             return try await ContainerFiles.shared.open(container, on: engine)
         }) {
        self.preferences = preferences
        self.transfers = transfers
        self.visits = visits
        self.remote = remote
        self.remoteBrowsing = remoteBrowsing ?? remote.browsing
        self.copies = copies ?? CopyProviders(servers: remote.files, containers: .shared)
        self.openContainer = openContainer
        self.directories = directories ?? DirectoryReader(copies: self.copies)
        self.availableCapacity = availableCapacity
        self.windows = windows
    }
}
