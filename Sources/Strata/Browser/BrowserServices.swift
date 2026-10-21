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
    let remoteBrowsing: RemoteBrowsing
    let directories: DirectoryReader
    let availableCapacity: @Sendable (URL) async -> Int64?
    let windows: BrowserWindows

    init(transfers: TransferQueue, visits: Frecency, directories: DirectoryReader = .live, preferences: Prefs = .shared, windows: BrowserWindows = .native,
         availableCapacity: @escaping @Sendable (URL) async -> Int64? = BrowserLoading.freeSpace,
         remoteBrowsing: RemoteBrowsing = .live) {
        self.preferences = preferences
        self.transfers = transfers
        self.visits = visits
        self.remoteBrowsing = remoteBrowsing
        self.directories = directories
        self.availableCapacity = availableCapacity
        self.windows = windows
    }
}
