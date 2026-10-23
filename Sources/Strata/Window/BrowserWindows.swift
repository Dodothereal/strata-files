import AppKit

/// Window creation stays at the application boundary. Workspaces supply their owner; AppKit still presents and tabs
/// production windows, while headless tests can create unshown controllers without borrowing the app delegate.
struct BrowserWindows {
    var controllers: () -> [BrowserWindowController]
    var open: (URL, URL?, NSWindow?, BrowserServices) -> BrowserWindowController?

    static let headless = BrowserWindows(controllers: { [] }, open: { _, _, _, _ in nil })

    static let native = BrowserWindows(
        controllers: { NSApp.windows.compactMap { $0.windowController as? BrowserWindowController } },
        open: { location, second, parent, services in
            (NSApp.delegate as? AppDelegate)?.openWindow(at: location, secondPane: second, tabbedWith: parent, services: services)
        })
}
