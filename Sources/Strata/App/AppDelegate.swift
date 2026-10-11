import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let undoManager = UndoManager()
    private var windowControllers: [BrowserWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        registerRevealHandler()
        NSApp.mainMenu = MainMenu.build()
    }

    private var welcome: WelcomeSheetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileIndex.shared.start()
        StrataAI.startIndexing()
        // Loads history now, so a plain copy left by an earlier build is removed right away.
        _ = OperationLog.shared
        if windowControllers.isEmpty { openWindow(at: startLocation) }
        if !Privacy.hasFullDiskAccess, !UserDefaults.standard.bool(forKey: "welcomeShown"),
           let window = windowControllers.first?.window {
            let sheet = WelcomeSheetController()
            sheet.onGranted = { [weak self] in self?.windowControllers.forEach { $0.privacyChanged() } }
            welcome = sheet
            sheet.present(on: window)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Full Disk Access may have been switched on in Settings while we were in the background.
        let had = Privacy.hasFullDiskAccess
        Privacy.refresh()
        if Privacy.hasFullDiskAccess != had { windowControllers.forEach { $0.privacyChanged() } }
    }

    func registerRevealHandler() {
        // "Reveal in Finder" from other apps arrives as a 'misc'/'mvis' event when Strata is the file viewer.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleReveal(_:reply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    @objc private func handleReveal(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let count = list.numberOfItems
        let urls = count == 0 ? [list.fileURLValue].compactMap { $0 } : (1...count).compactMap { list.atIndex($0)?.fileURLValue }
        reveal(urls)
    }

    /// Opens each file's folder with the file selected (folders themselves open).
    private func reveal(_ urls: [URL]) {
        let byFolder = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }
        for (folder, items) in byFolder {
            if let key = NSApp.keyWindow?.windowController as? BrowserWindowController {
                key.navigate(to: folder, select: items.first)
                key.showWindow(nil)
            } else {
                openWindow(at: folder, select: items.first)
            }
        }
        NSApp.activate()
    }

    /// strata://search?q=…&in=…, strata://open?path=…, strata://recents, strata://duplicates
    private func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let controller = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windowControllers.first ?? openWindow(at: Places.home)
        switch url.host {
        case "search":
            guard let query = value("q") else { return }
            controller.search(query, in: value("in").map { URL(fileURLWithPath: $0) })
        case "open":
            guard let path = value("path") else { return }
            controller.navigate(to: URL(fileURLWithPath: path))
        case "recents":
            controller.goRecents(nil)
        case "duplicates":
            controller.showDuplicates()
        case "shortcuts":
            showShortcuts(nil)
            return
        default:
            break
        }
        controller.showWindow(nil)
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "strata" { handle(url) }
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue, !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                openWindow(at: url)
            } else {
                openWindow(at: url.deletingLastPathComponent(), select: url)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(at: startLocation) }
        return true
    }

    /// Where a new window opens: Settings ▸ "New windows open" (where you left off, or home).
    private var startLocation: URL {
        let last = Prefs.lastLocation.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return Prefs.newWindowsAtHome ? Places.home : last ?? Places.home
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TransferQueue.shared.shouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        FileIndex.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func toggleShelf(_ sender: Any?) {
        ShelfPanel.shared.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleShelf(_:)) { item.state = ShelfPanel.shared.isVisible ? .on : .off }
        return true
    }

    /// Reopens a saved workspace as one window with a tab per saved tab.
    func open(_ workspace: Workspace) {
        var first: NSWindow?
        for tab in workspace.tabs {
            guard let path = tab.first else { continue }
            let second = tab.count > 1 ? URL(fileURLWithPath: tab[1]) : nil
            let controller = openWindow(at: URL(fileURLWithPath: path), secondPane: second, tabbedWith: first)
            if first == nil { first = controller.window }
        }
    }

    @discardableResult
    func openWindow(at url: URL, select: URL? = nil, secondPane: URL? = nil, tabbedWith parent: NSWindow? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(location: url, select: select, secondPane: secondPane)
        windowControllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        if let parent, let window = controller.window {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            if let key = NSApp.keyWindow, let window = controller.window {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
            }
            controller.showWindow(nil)
        }
        return controller
    }

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutsWindowController.shared.show()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showHistory(_ sender: Any?) {
        HistoryWindowController.shared.showWindow(nil)
    }

    @objc func newWindow(_ sender: Any?) {
        let current = (NSApp.keyWindow?.windowController as? BrowserWindowController)?.location
        openWindow(at: Prefs.newWindowsAtHome ? Places.home : current ?? Places.home)
    }
}
