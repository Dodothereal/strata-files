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
    let containers: ContainerFiles
    let containerStore: ContainerStore
    let copies: CopyProviders
    let clipboard: Clipboard
    let openContainer: @MainActor @Sendable (String) async throws -> URL
    let directories: DirectoryReader
    let mediaReader: MediaInfoLoader.Reader
    let thumbnails: FileThumbnails
    let itemInfo: ItemInfoLoader
    let availableCapacity: @Sendable (URL) async -> Int64?
    let windows: BrowserWindows

    init(transfers: TransferQueue, visits: Frecency, directories: DirectoryReader? = nil, preferences: Prefs = .shared, windows: BrowserWindows = .native,
         availableCapacity: @escaping @Sendable (URL) async -> Int64? = BrowserLoading.freeSpace,
         remote: RemoteServices = .shared, remoteBrowsing: RemoteBrowsing? = nil,
         containers: ContainerFiles = .shared, containerStore: ContainerStore = .shared,
         copies: CopyProviders? = nil,
         clipboard: Clipboard = .shared,
         mediaReader: @escaping MediaInfoLoader.Reader = MediaInfoLoader.read,
         thumbnails: FileThumbnails? = nil, itemInfo: ItemInfoLoader? = nil,
         openContainer: (@MainActor @Sendable (String) async throws -> URL)? = nil) {
        self.preferences = preferences
        self.transfers = transfers
        self.visits = visits
        self.remote = remote
        self.remoteBrowsing = remoteBrowsing ?? remote.browsing
        self.containers = containers
        self.containerStore = containerStore
        self.copies = copies ?? CopyProviders(servers: remote.files, containers: containers)
        self.clipboard = clipboard
        if transfers !== TransferQueue.shared && !transfers.hasCustomCopies {
            transfers.copies = self.copies
        }
        self.openContainer = openContainer ?? { id in
            guard let engine = containerStore.engine, let container = containerStore.container(id: id) else { throw ContainerAPIError.notFound }
            return try await containers.open(container, on: engine)
        }
        self.directories = directories ?? DirectoryReader(copies: self.copies)
        self.mediaReader = mediaReader
        self.thumbnails = thumbnails ?? FileThumbnails(copies: self.copies, containerStore: containerStore)
        self.itemInfo = itemInfo ?? ItemInfoLoader(copies: self.copies, containerStore: containerStore, mediaReader: mediaReader)
        self.availableCapacity = availableCapacity
        self.windows = windows
    }
}
