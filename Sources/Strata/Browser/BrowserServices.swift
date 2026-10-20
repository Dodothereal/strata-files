import Foundation

/// Services shared by a window and its panes. Production windows share one set; headless windows can own independent
/// transfers and visit history without changing AppKit's responder chain or presentation controllers.
final class BrowserServices {
    static let shared = BrowserServices(transfers: .shared, visits: .shared)

    let transfers: TransferQueue
    let visits: Frecency

    init(transfers: TransferQueue, visits: Frecency) {
        self.transfers = transfers
        self.visits = visits
    }
}
