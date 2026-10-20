import Foundation

/// Services shared by a window and its panes. Production windows share one set; headless windows can own independent
/// preferences, transfers and visit history without changing AppKit's responder chain or presentation controllers.
final class BrowserServices {
    static let shared = BrowserServices(transfers: .shared, visits: .shared)

    let preferences: Prefs
    lazy var viewOptions = ViewOptionsWindowController(preferences: preferences)

    let transfers: TransferQueue
    let visits: Frecency
    let directories: DirectoryReader

    init(transfers: TransferQueue, visits: Frecency, directories: DirectoryReader = .live, preferences: Prefs = .shared) {
        self.preferences = preferences
        self.transfers = transfers
        self.visits = visits
        self.directories = directories
    }
}
