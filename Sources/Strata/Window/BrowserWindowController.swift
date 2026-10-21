import AppKit

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let pathBar = Self("pathBar")
    static let search = Self("search")
    static let viewMode = Self("viewMode")
    static let dualPane = Self("dualPane")
    static let share = Self("share")
    static let sidebarMode = Self("sidebarMode")
}

/// One browser window (or tab): one or two panes, each with its own place and history, sharing the sidebar,
/// path bar, search field and inspector, which follow whichever pane has focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let largeFilesQuery = "kind:file size:>500mb"

    /// What a search is called in titles: Large Files by name, others by their text.
    static func searchTitle(_ text: String) -> String {
        text == largeFilesQuery ? String(localized: "Large Files")
            : String(localized: "Search: \(text)", comment: "Window title while searching; the search text")
    }

    let services: BrowserServices
    private var panes: [Pane]
    /// The pane with focus; navigation, search and the inspector act on it.
    private(set) var pane: Pane
    var onClose: (() -> Void)?

    let split: MainSplitViewController
    private let pathBar: PathBar
    private var searchItem: NSSearchToolbarItem?
    private var viewModeItem: NSToolbarItemGroup?
    private var sidebarModeItem: NSToolbarItemGroup?
    private var dualPaneItem: NSToolbarItem?
    private var responderObservation: NSKeyValueObservation?
    /// Index changes re-run searches no more often than `indexRefreshInterval`.
    private var indexRefreshScheduled = false
    private var lastIndexRefresh = Date.distantPast
    let palette = CommandPalette()
    var pathQuery = PathQuery()
    var browser: BrowserViewController { pane.browser }
    /// In dual pane, the pane that isn't focused (Copy and Move to Other Pane send there).
    var otherBrowser: BrowserViewController? { panes.first { $0 !== pane }?.browser }
    var splitController: NSSplitViewController { split }
    var isDualPane: Bool { panes.count > 1 }

    var destination: Destination {
        get { pane.destination }
        set { pane.destination = newValue }
    }

    var location: URL { pane.location }

    init(location: URL, select: URL? = nil, secondPane: URL? = nil, services: BrowserServices = .shared) {
        self.services = services
        pathBar = PathBar(visits: services.visits, preferences: services.preferences)
        let first = Pane(location: location, services: services)
        panes = [first]
        pane = first
        split = MainSplitViewController(firstPane: first.host)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "dev.strata.browser"
        window.minSize = NSSize(width: 760, height: 420)
        window.isRestorable = false
        super.init(window: window)

        window.delegate = self
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 780))
        let toolbar = NSToolbar(identifier: "dev.strata.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        if !window.setFrameAutosaveName("StrataBrowserWindow") { window.center() }

        configure(first)
        split.sidebar.onSelect = { [weak self] target in self?.open(target) }
        split.sidebar.onOpenInNewTab = { [weak self] url in
            self?.openTab(at: url)
        }
        pathBar.onNavigate = { [weak self] url, select in self?.navigate(to: url, select: select) }
        pathBar.onFinishEditing = { [weak self] in self?.focusList() }
        split.scopeBar.onScopeChange = { [weak self] everywhere in self?.changeSearchScope(everywhere: everywhere) }
        split.scopeBar.onSave = { [weak self] in self?.saveSearch() }
        split.scopeBar.onMatchCase = { [weak self] on in self?.setSearchCase(on) }
        NotificationCenter.default.addObserver(self, selector: #selector(indexPhaseChanged), name: .indexPhaseDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: .indexDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gitStatusChanged), name: .gitStatusDidChange, object: nil)
        services.preferences.notifications.addObserver(self, selector: #selector(sidebarModePrefChanged), name: .prefsChanged, object: nil)
        services.remote.notifications.addObserver(self, selector: #selector(serverDisconnected(_:)), name: .remoteServerDisconnected, object: services.remote.servers)
        // The Inspector's Cloud row follows downloads and uploads.
        NotificationCenter.default.addObserver(self, selector: #selector(cloudStatusChanged), name: .cloudStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(containerCopyProblem(_:)), name: .containerCopyProblem, object: nil)
        // Clicking into a pane gives it focus.
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let view = window.firstResponder as? NSView,
                      let owner = self.panes.first(where: { view.isDescendant(of: $0.host.view) }), owner !== self.pane else { return }
                self.activate(owner)
            }
        }
        go(.folder(first.location), select: select, recordHistory: false)
        if let secondPane { toggleDualPane(at: secondPane) }
        ThemeStyle.apply(to: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if let window { ThemeStyle.apply(to: window) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window { ThemeStyle.apply(to: window) }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { finishThemeTransition(in: window) }

    func windowDidFailToExitFullScreen(_ window: NSWindow) { finishThemeTransition(in: window) }

    private func finishThemeTransition(in window: NSWindow) {
        window.titlebarAccessoryViewControllers.compactMap { $0 as? ToolbarThemeController }
            .forEach { $0.finishFullScreenTransition() }
    }

    private func configure(_ pane: Pane) {
        pane.browser.delegate = self
        pane.host.onActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            activate(pane)
            window?.makeFirstResponder(pane.browser.focusView)
        }
        let tab: () -> Bool = { [weak self] in
            guard let self, isDualPane else { return false }
            focusOtherPane(nil)
            return true
        }
        pane.browser.onTab = tab
        pane.browser.outlineView.onTab = tab
    }

    // MARK: - Panes

    @objc func toggleDualPane(_ sender: Any?) {
        toggleDualPane(at: nil)
    }

    /// View ▸ Folder Tree in Sidebar: the tree of folders instead of Favorites, Locations and the rest (every window).
    @objc func toggleFolderTree(_ sender: Any?) {
        services.preferences.sidebarShowsTree.toggle()
        if split.splitViewItems.first?.isCollapsed == true { split.toggleSidebar(nil) }
    }

    /// Adds a second pane (at `url`, or where the current one is), or closes the pane without focus.
    func toggleDualPane(at url: URL?) {
        if isDualPane {
            let closing = panes.first { $0 !== pane }!
            closing.stopBackgroundWork()
            split.panes.remove(closing.host)
            panes.removeAll { $0 === closing }
        } else {
            let second = Pane(location: url ?? pane.location, services: services)
            configure(second)
            panes.append(second)
            split.panes.add(second.host)
            go(.folder(second.location), in: second, recordHistory: false)
        }
        refreshPanels()
        // Filled symbol while two panes are showing.
        dualPaneItem?.image = NSImage(systemSymbolName: isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                                      accessibilityDescription: String(localized: "Dual Pane"))
        updateHeaders()
    }

    @objc func focusOtherPane(_ sender: Any?) {
        guard let other = panes.first(where: { $0 !== pane }) else { return }
        activate(other)
        window?.makeFirstResponder(other.browser.focusView)
    }

    /// Both panes' folders, left then right, when two panes each show a folder and neither is inside the other (a
    /// sync between them would copy a folder into itself, or trash one side's own folder).
    var paneFolders: (left: URL, right: URL)? {
        guard panes.count == 2, case .folder(let left) = panes[0].destination, case .folder(let right) = panes[1].destination
        else { return nil }
        // Not a copy Strata fills in (a server's, a container's, an archive's): a sync can't write into one.
        guard !ReadOnlyCopies.contains(left), !ReadOnlyCopies.contains(right) else { return nil }
        let l = TransferJob.realPath(left.standardizedFileURL.path), r = TransferJob.realPath(right.standardizedFileURL.path)
        func inside(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b == "/" ? "/" : b + "/") }
        guard !inside(l, r), !inside(r, l) else { return nil }
        return (left, right)
    }

    /// View ▸ Compare with Other Pane: what differs between the two folders, and a sync.
    @objc func compareWithOtherPane(_ sender: Any?) {
        guard let (left, right) = paneFolders, let window, window.attachedSheet == nil else { return }
        let controller = CompareController(left: left, right: right, undo: window.undoManager, transfers: services.transfers, preferences: services.preferences)
        contentViewController?.presentAsSheet(controller)
    }

    /// Copies (or moves) the selection into the other pane's folder, like a commander's F5/F6.
    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(move: false) }
    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(move: true) }

    private func transferToOtherPane(move: Bool) {
        guard let other = panes.first(where: { $0 !== pane }), case .folder(let target) = other.destination else { return }
        let urls = browser.selectedURLs
        guard !urls.isEmpty else { return }
        // Onto a server: copied there (or moved within it), through the server.
        if RemoteCopies.contains(target) { return other.browser.copyToServer(urls, into: target, move: move) }
        let job = services.transfers.enqueue(urls, to: target, mode: move ? .move : .copy,
                                               undo: window?.undoManager, conflicts: .sheet(for: window))
        job.onFinish = { [weak self, weak other] job in
            guard self != nil, let other else { return }
            other.browser.select(job.createdItems)
        }
    }

    /// Completion for a reviewed operation. Keep its original pane and navigation, including leaving and returning
    /// to the same folder, and let the next applied listing select its results instead of guessing a delay.
    func selectionAfterOperation() -> ([URL]) -> Void {
        let origin = pane, revision = pane.navigationRevision, folder = pane.location.standardizedFileURL.fileViewKey
        return { [weak self, weak origin] results in
            guard let self, let origin, origin.navigationRevision == revision,
                  panes.contains(where: { $0 === origin }) else { return }
            origin.browser.pendingSelection = results.filter { $0.deletingLastPathComponent().standardizedFileURL.fileViewKey == folder }
            switch origin.destination {
            case .folder: origin.browser.reloadFolder(nil)
            case .search, .recents: runSearch(in: origin)
            case .duplicates: findDuplicates(in: origin)
            }
        }
    }

    private func activate(_ newPane: Pane) {
        guard newPane !== pane, panes.contains(where: { $0 === newPane }) else { return }
        pane = newPane
        updateChrome()
        refreshPanels()
    }

    private func updateHeaders() {
        for p in panes {
            let title = p.title
            p.host.setHeader(visible: isDualPane, title: title.text, symbol: title.symbol, active: p === pane)
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL, select: URL? = nil, recordHistory: Bool = true) {
        go(.folder(url.standardizedFileURL), select: select, recordHistory: recordHistory)
    }

    /// Inspector mount links can point into a copy that has not been listed yet. Its owner prepares the path before
    /// the pane navigates; an ordinary local folder opens immediately.
    @discardableResult
    func openFolder(_ folder: URL) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        let copies = services.copies
        guard copies.contains(folder) else { navigate(to: folder); return nil }
        return openFolder(operation: {
            guard await copies.reveal(folder) else { throw CocoaError(.fileReadNoSuchFile) }
            return folder
        }, failed: { _ in NSSound.beep() })
    }

    private func open(_ target: SidebarTarget) {
        switch target {
        case .folder(let url): navigate(to: url)
        case .recents: go(.recents)
        case .search(let saved): go(.search(saved.query, scope: saved.scopePath.map { URL(fileURLWithPath: $0) }))
        case .duplicates: go(.duplicates)
        case .largeFiles: go(.search(Self.largeFilesQuery, scope: nil))
        case .containers: openContainers()
        case .workspace(let name): if let workspace = services.workspaces.named(name) { services.workspaces.open(workspace) }
        case .server(let id): if let server = services.remote.servers.server(id: id) { openServer(server) }
        }
    }

    /// The containers of the engine Strata found, as folders.
    func openContainers() {
        guard let engine = ContainerStore.shared.engine, let folder = try? ContainerCopies.prepare(engine) else {
            NSSound.beep()
            return
        }
        navigate(to: folder)
    }

    /// Shows a container's files: its read-only copy, filled in from the container as you browse.
    @discardableResult
    func openContainer(_ id: String) -> Task<Void, Never> {
        let open = services.openContainer
        return openFolder(operation: { try await open(id) }, failed: { _ in NSSound.beep() })
    }

    /// Async destinations keep their originating pane, even when the other pane gets focus while waiting.
    @discardableResult
    func openFolder(notice: FolderOpenSession.Notice? = nil,
                    operation: @escaping @Sendable () async throws -> URL,
                    failed: @escaping (Error) -> Void) -> Task<Void, Never> {
        guard !isClosed else { return Task {} }
        let origin = pane
        let work = origin.opening.open(notice: notice, operation: operation) { [weak self, weak origin] result in
            guard let self, !isClosed, let origin, panes.contains(where: { $0 === origin }) else { return }
            switch result {
            case .success(let folder): go(.folder(folder.standardizedFileURL), in: origin)
            case .failure(let error):
                if pane === origin { refreshOpeningNotice() }
                failed(error)
            }
        }
        refreshOpeningNotice()
        return work
    }

    private func refreshOpeningNotice() {
        guard !showPendingOpening() else { return }
        if case .folder(let shown) = destination { updateNotice(for: shown) }
        else { split.noticeBar.hide() }
    }

    @discardableResult
    func showPendingOpening() -> Bool {
        let origin = pane
        guard let request = origin.opening.request, let notice = origin.opening.notice else { return false }
        split.noticeBar.show(symbol: notice.symbol, text: notice.text, button: String(localized: "Cancel")) { [weak self, weak origin] in
            guard let self, let origin, origin.opening.cancel(request) else { return }
            if pane === origin { refreshOpeningNotice() }
        }
        return true
    }


    /// `countVisit: false` for folders only passed through (spring loading): they don't become frequent places.
    private func go(_ target: Destination, in targetPane: Pane? = nil, select: URL? = nil, recordHistory: Bool = true,
                    countVisit: Bool = true) {
        let p = targetPane ?? pane
        // A link or Finder alias to a folder shows that folder, by its own path (however it was reached: a click,
        // a restored window, a workspace, spring loading), so the folder and the items listed in it always agree.
        var target = target, select = select
        if case .folder(let url) = target {
            let opened = FileEntry.openedFolder(url).standardizedFileURL
            if opened != url.standardizedFileURL, let item = select,
               item.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL {
                select = opened.appending(path: item.lastPathComponent)
            }
            target = .folder(opened)
        }
        p.columnLocation = nil
        p.waiting = nil
        if target != .duplicates { p.duplicateSearch?.set() }
        // Leaving a folder search stops its scan; a finished one stays a minute, so Back shows the results at once.
        // A search left behind stops (a Spotlight query would otherwise run on to its time limit).
        if case .search = target {} else {
            p.searchTask?.cancel()
            p.searchTask = nil
        }
        if case .search(_, let scope?) = target, p.folderSearch?.canServe(scope) == true {} else if p.folderSearch?.isFinished == false {
            p.folderSearch?.cancel()
            p.folderSearch = nil
        }
        if recordHistory, target != p.destination {
            p.backStack.append(p.destination)
            p.forwardStack.removeAll()
        }
        p.destination = target
        switch target {
        case .folder(let url):
            p.location = url
            p.folderEntry = FileEntry(url: url)
            p.browser.load(url, select: select)
            // An archive's copy is temporary: it doesn't become a frequent place or where the next window opens.
            if !ReadOnlyCopies.contains(url) && !services.copies.contains(url) {
                if countVisit { services.visits.record(url) }
                services.preferences.lastLocation = url
            }
        case .search, .recents:
            runSearch(in: p)
        case .duplicates:
            findDuplicates(in: p)
        }
        if p === pane {
            updateChrome()
            if !(window?.firstResponder is NSTextView) { focusList() }
        } else {
            updateHeaders()
        }
    }

    /// Path bar, sidebar, title, search field and scope bar for the focused pane.
    private func updateChrome() {
        switch destination {
        case .folder(let url):
            pathBar.url = url
            updateGitChrome()
            split.sidebar.highlight(.folder(url))
            window?.title = Places.displayName(url)
            // Not a container's copy: dragging the title's icon would hand out what isn't fully read yet.
            window?.representedURL = services.copies.contains(url) ? nil : url
            setSearchField("")
            split.scopeBar.isHidden = true
            updateNotice(for: url)
        case .search(let text, let scope):
            setSearchField(text)
            // The query itself, so a search shows what was asked (Large Files by name).
            pathBar.showTitle(text == Self.largeFilesQuery ? String(localized: "Large Files")
                                  : String(localized: "“\(text)”", comment: "Path bar title while searching: the search text in quotes"),
                              symbol: "magnifyingglass")
            if text == Self.largeFilesQuery && scope == nil {
                split.sidebar.highlight(.largeFiles)
            } else {
                split.sidebar.highlight(services.savedSearches.all.first { $0.query == text && $0.scopePath == scope?.path }.map { .search($0) })
            }
            window?.title = Self.searchTitle(text)
            window?.representedURL = nil
            split.scopeBar.configure(folderName: Places.displayName((scope ?? location)),
                                     everywhere: scope == nil, matchCase: IndexQuery.isCaseSensitive(text),
                                     caseApplies: Self.caseApplies(text))
            split.scopeBar.setSummary(pane.searchSummary)
            split.scopeBar.isHidden = false
            split.noticeBar.hide()
        case .duplicates:
            setSearchField("")
            pathBar.showTitle(String(localized: "Duplicates", comment: "Title of the view listing duplicate files"), symbol: "square.on.square")
            split.sidebar.highlight(.duplicates)
            window?.title = String(localized: "Duplicates", comment: "Title of the view listing duplicate files")
            window?.representedURL = nil
            split.scopeBar.isHidden = true
            split.noticeBar.hide()
        case .recents:
            setSearchField("")
            pathBar.showTitle(String(localized: "Recents", comment: "Title of the view listing recently used files"), symbol: "clock")
            split.sidebar.highlight(.recents)
            window?.title = String(localized: "Recents", comment: "Title of the view listing recently used files")
            window?.representedURL = nil
            split.scopeBar.isHidden = true
            split.noticeBar.hide()
        }
        showPendingOpening()
        syncViewModeItem()
        window?.toolbar?.validateVisibleItems()
        updateHeaders()
    }

    private func focusList() {
        window?.makeFirstResponder(browser.focusView)
    }

    private func setSearchField(_ text: String) {
        guard let field = searchItem?.searchField, field.stringValue != text else { return }
        field.stringValue = text
    }

    /// Selects the folder we came from when it's inside the destination (going back up, or to an enclosing folder).
    private func childToSelect(in destination: Destination, from origin: Destination) -> URL? {
        guard case .folder(let target) = destination, case .folder(let from) = origin else { return nil }
        let parent = target.standardizedFileURL.path
        let path = from.standardizedFileURL.path
        guard path.hasPrefix(parent == "/" ? "/" : parent + "/") else { return nil }
        let rest = path.dropFirst(parent == "/" ? 1 : parent.count + 1)
        guard let first = rest.split(separator: "/").first else { return nil }
        return target.appending(path: String(first)).standardizedFileURL
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = pane.backStack.popLast() else { return }
        pane.forwardStack.append(destination)
        go(previous, select: childToSelect(in: previous, from: destination), recordHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = pane.forwardStack.popLast() else { return }
        pane.backStack.append(destination)
        go(next, select: childToSelect(in: next, from: destination), recordHistory: false)
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        if case .folder = destination {
            // In column view "here" is the focused column's folder, not the first column's.
            let current = (browser.mode == .columns ? pane.columnLocation : nil) ?? location
            guard current.path != "/" else { return }
            // Up from an archive opened as a folder: the folder the archive is in, with the archive selected.
            if let (archive, top) = ArchiveCache.archive(containing: current), top.standardizedFileURL == current.standardizedFileURL {
                return navigate(to: archive.deletingLastPathComponent(), select: archive)
            }
            // The Containers folder has nothing above it (a container's `/` goes up to it); nor has a server's `/`.
            if ContainerCopies.engineFolder(current) != nil { return NSSound.beep() }
            if let (_, top) = services.remote.copies.server(containing: current), top.standardizedFileURL == current.standardizedFileURL { return NSSound.beep() }
            navigate(to: current.deletingLastPathComponent(), select: current)
        } else {
            navigate(to: location)
        }
    }

    @objc func goHome(_ sender: Any?) { navigate(to: Places.home) }
    @objc func goDesktop(_ sender: Any?) { navigate(to: Places.home.appending(path: "Desktop")) }
    @objc func goDocuments(_ sender: Any?) { navigate(to: Places.home.appending(path: "Documents")) }
    @objc func goDownloads(_ sender: Any?) { navigate(to: Places.home.appending(path: "Downloads")) }
    @objc func goApplications(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Applications")) }
    @objc func goRecents(_ sender: Any?) { go(.recents) }
    func showDuplicates() { go(.duplicates) }
    @objc func goToFolder(_ sender: Any?) { pathBar.beginEditing() }
    @objc func focusSearch(_ sender: Any?) { searchItem?.beginSearchInteraction() }

    /// Ask Strata needs something to work on: a selection, or a folder with items.
    private var canAskStrata: Bool {
        guard !browser.isInsideArchive, !browser.isLoadingFolder else { return false }
        guard case .folder = destination else { return !browser.selectedURLs.isEmpty }
        return !browser.selectedURLs.isEmpty || !browser.topLevelEntries.isEmpty
    }

    /// Volumes ⌘E would eject: selected volume roots, else the volume whose top level is showing.
    private var ejectTargets: [URL] {
        // Volumes are listed once, then matched by path (a big selection mustn't list them per item).
        let ejectable = Set(Places.volumes().filter(\.isEjectable).map { $0.url.standardizedFileURL.path })
        guard !ejectable.isEmpty else { return [] }
        let selected = browser.selectedURLs.filter { ejectable.contains($0.standardizedFileURL.path) }
        if !selected.isEmpty { return selected }
        if case .folder = destination, ejectable.contains(location.standardizedFileURL.path) { return [location] }
        return []
    }

    @objc func ejectVolume(_ sender: Any?) {
        for url in ejectTargets {
            if location.standardizedFileURL.path == url.standardizedFileURL.path { navigate(to: Places.home) }
            Places.eject(url, from: window)
        }
    }

    override func newWindowForTab(_ sender: Any?) { openTab(at: location) }

    private func openTab(at location: URL) {
        guard !isClosed, let window else { return }
        // A new tab joins the window's workspace and services: updating it saves this tab too.
        let name = groupWorkspaceName
        services.windows.open(location, nil, window, services)?.workspaceName = name
    }

    @objc private func sidebarModeChanged(_ sender: NSToolbarItemGroup) {
        let tree = sender.selectedIndex == 1
        if tree != services.preferences.sidebarShowsTree { services.preferences.sidebarShowsTree = tree }
        if split.splitViewItems.first?.isCollapsed == true { split.toggleSidebar(nil) }
    }

    /// A server's files were let go: panes showing them go home.
    @objc private func serverDisconnected(_ notification: Notification) {
        guard let id = notification.userInfo?["serverID"] as? String else { return }
        for p in panes where services.remote.copies.server(containing: p.location)?.server.id == id || p.location.standardizedFileURL == services.remote.copies.top(of: id).standardizedFileURL {
            let folder = WaitingFolder(path: p.location.path, mode: p.browser.mode.rawValue, server: id)
            go(.folder(Places.home), in: p)
            // Kept for its server folder, so updating a workspace (or the session) doesn't lose it.
            p.waiting = folder
        }
    }

    /// Every window's switch follows the setting (it's the same for all of them).
    @objc private func sidebarModePrefChanged() {
        sidebarModeItem?.selectedIndex = services.preferences.sidebarShowsTree ? 1 : 0
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        browser.setViewMode(sender)
        syncViewModeItem()
    }

    /// Points the toolbar's view switcher at the current mode.
    func syncViewModeItem() {
        viewModeItem?.selectedIndex = browser.effectiveMode.position
        viewModeItem?.isEnabled = !browser.isShowingResults
    }

    /// Keeps the toolbar's view switcher in sync when ⌘1–⌘5 change the mode.
    @objc func syncViewMode(_ sender: Any?) {
        browser.setViewMode(sender)
        syncViewModeItem()
    }

    // MARK: - Search

    /// Starts a search from outside the window (the `strata` command, URL scheme).
    func search(_ query: String, in scope: URL?) {
        go(.search(query, scope: scope))
    }

    /// The toolbar field searches the whole index; typing in the list still filters the current folder.
    private func searchTextChanged(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            if case .search = destination { leaveSearch() }
            return
        }
        // Spotlight answers tag searches, so they don't wait for the first index.
        guard FileIndex.shared.isReady || SpotlightQuery.parse(query) != nil else {
            // The index is still being built for the first time: filter this folder meanwhile.
            browser.setFilter(query)
            return
        }
        if case .search(_, let scope) = destination {
            destination = .search(query, scope: scope)
            window?.title = Self.searchTitle(query)
            // Typing or deleting case: shows on the checkbox.
            split.scopeBar.setMatchCase(IndexQuery.isCaseSensitive(query), applies: Self.caseApplies(query))
            updateHeaders()
            runSearch(in: pane)
        } else {
            go(.search(query, scope: nil))
        }
    }

    /// Clearing the field returns to the folder the search started from.
    private func leaveSearch() {
        if case .folder = pane.backStack.last {
            go(pane.backStack.removeLast(), recordHistory: false)
        } else {
            go(.folder(location), recordHistory: false)
        }
    }

    private func changeSearchScope(everywhere: Bool) {
        guard case .search(let text, _) = destination else { return }
        destination = .search(text, scope: everywhere ? nil : location)
        runSearch(in: pane)
    }

    /// Whether Match Case means anything for `text`: not for Spotlight's searches or plain-English readings.
    private static func caseApplies(_ text: String) -> Bool {
        SpotlightQuery.parse(text) == nil && NaturalQuery.interpret(text) == nil
    }

    /// Match Case: the same search with `case:` added or taken out (so a saved search keeps it).
    private func setSearchCase(_ on: Bool) {
        guard case .search(let text, let scope) = destination else { return }
        let updated = IndexQuery.settingCase(on, in: text)
        guard updated != text, !updated.isEmpty else { return }
        destination = .search(updated, scope: scope)
        updateChrome()
        runSearch(in: pane)
    }

    private func saveSearch() {
        guard case .search(let text, let scope) = destination else { return }
        let saved = SavedSearch(name: text, query: text, scopePath: scope?.path)
        guard services.savedSearches.save(saved) else { return }
        split.sidebar.highlight(.search(saved))
    }

    private func runSearch(in p: Pane) {
        p.searchGeneration += 1
        let generation = p.searchGeneration
        let target = p.destination
        // Only the latest search runs on: an earlier one (a Spotlight query a keystroke ago) is stopped.
        p.searchTask?.cancel()
        p.searchTask = Task {
            switch target {
            case .search(let text, let scope):
                // Finder tags aren't in the index: Spotlight answers those.
                if let query = SpotlightQuery.parse(text) {
                    await searchSpotlight(query, in: scope, pane: p, generation: generation, target: target)
                    return
                }
                if let scope, !FileIndex.shared.covers(scope) {
                    if !FileIndex.shared.isReady, FileIndex.shared.overlapsIndexedFolders(scope) {
                        // Reading your home folder now would duplicate the first index (and ask for the folders macOS
                        // guards in it).
                        p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                                              message: String(localized: "Search works as soon as the first index is built."))
                        showSummary("", for: p)
                        return
                    }
                    if Privacy.measuringWouldPrompt(scope, browsing: p.location) {
                        // A link or saved search pointing into a guarded folder you haven't opened: macOS would ask.
                        let name = Places.displayName(scope)
                        p.browser.showMessage(symbol: "lock", title: String(localized: "Open “\(name)” to search it"),
                                              message: String(localized: "macOS asks before apps read this folder. Open it in Strata once, then search it."))
                        showSummary("", for: p)
                        return
                    }
                    await searchDirectly(text, in: scope, pane: p, generation: generation, target: target)
                    return
                }
                p.folderSearch?.cancel()
                p.folderSearch = nil
                let givenUpBefore = NameRegex.namesGivenUp
                guard let result = await FileIndex.shared.understand(text, in: scope) else {
                    p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                                          message: String(localized: "Search works as soon as the first index is built."))
                    return
                }
                // Documents whose text matches (on-device, Documents/Desktop/Downloads) follow the name matches. Explicit
                // filters (ext:, size:…) apply to them too: they're skipped for syntax searches, and a plain-English
                // reading's kinds, sizes and dates must hold for each one.
                let plainNames = result.interpretation == nil && !IndexQuery.parse(text).hasFilters
                let contentQuery = result.interpretation?.contentQuery ?? (plainNames ? text : nil)
                var structural = result.interpretation
                structural?.nameContains = []
                structural?.keywords = []
                let contentHits = contentQuery.map { $0.count >= 3 } == true ? await StrataAI.index.search(contentQuery!, limit: 15) : []
                guard generation == p.searchGeneration, p.destination == target else { return }
                var entries = result.hits.map(FileEntry.init(hit:))
                let known = Set(entries.map { $0.url.standardizedFileURL.path })
                let byContent = contentHits
                    .filter { hit in
                        !known.contains(hit.url.standardizedFileURL.path) && (scope.map { hit.url.path.hasPrefix($0.path + "/") } ?? true)
                    }
                    .compactMap { FileEntry(url: $0.url) }
                    .filter { entry in structural.map { $0.matches(entry) } ?? true }
                entries += byContent
                let total = result.total + byContent.count
                p.browser.showResults(entries, total: total)
                var parts: [String]
                if let scope {
                    let name = Places.displayName(scope)
                    parts = [total == 0 ? String(localized: "No results in “\(name)”")
                        : String(localized: "\(total) results in “\(name)”", comment: "plural")]
                } else {
                    parts = [total == 0 ? String(localized: "No results everywhere")
                        : String(localized: "\(total) results everywhere", comment: "plural")]
                }
                if !byContent.isEmpty {
                    parts.append(String(localized: "\(byContent.count) by content", comment: "plural"))
                }
                if let filter = result.interpretation { parts.append(filter.summary) }
                if NameRegex.namesGivenUp > givenUpBefore {
                    parts.append(String(localized: "the pattern took too long on some names, so they’re left out"))
                }
                showSummary(parts.joined(separator: " · "), for: p)
            case .recents:
                guard let hits = await FileIndex.shared.recentFiles() else {
                    p.browser.showResults([], total: 0)
                    return
                }
                guard generation == p.searchGeneration, p.destination == target else { return }
                p.browser.showResults(hits.map(FileEntry.init(hit:)), total: hits.count)
            case .folder, .duplicates:
                break
            }
        }
    }

    /// Keeps `p`'s scope-bar line and shows it when `p` is the active pane (the other pane's shows when you switch).
    private func showSummary(_ summary: String, for p: Pane) {
        p.searchSummary = summary
        if p === pane { split.scopeBar.setSummary(summary) }
    }

    /// A search only Spotlight can answer (tags): in `scope`, or on the whole Mac.
    private func searchSpotlight(_ query: SpotlightQuery, in scope: URL?, pane p: Pane, generation: Int, target: Destination) async {
        p.folderSearch?.cancel()
        p.folderSearch = nil
        let result = await SpotlightSearch.run(query.predicate, scope: scope)
        let entries = await Self.entries(result.urls)
        guard generation == p.searchGeneration, p.destination == target else { return }
        p.browser.showResults(entries, total: result.total)
        var parts: [String]
        if let scope {
            let name = Places.displayName(scope)
            parts = [result.total == 0 ? String(localized: "No results in “\(name)”")
                : String(localized: "\(result.total) results in “\(name)”", comment: "plural")]
        } else {
            parts = [result.total == 0 ? String(localized: "No results on this Mac")
                : String(localized: "\(result.total) results on this Mac", comment: "plural")]
        }
        parts.append(query.summary)
        if result.total > result.urls.count {
            parts.append(String(localized: "first \(result.urls.count) shown", comment: "plural"))
        }
        if result.timedOut { parts.append(String(localized: "Spotlight took too long; results may be incomplete")) }
        showSummary(parts.joined(separator: " · "), for: p)
    }

    @concurrent
    private static func entries(_ urls: [URL]) async -> [FileEntry] {
        urls.compactMap(FileEntry.init(url:))
    }

    /// Searches a folder the index doesn't cover by reading it (`FolderSearch`): matches fill in while it reads, the
    /// scope bar counts what's been read, and the summary says the folder was searched directly. Typing more in the same
    /// folder reuses the scan.
    private func searchDirectly(_ text: String, in scope: URL, pane p: Pane, generation: Int, target: Destination) async {
        let search: FolderSearch
        if let current = p.folderSearch, current.canServe(scope) {
            search = current
        } else {
            p.folderSearch?.cancel()
            search = FolderSearch(folder: scope, indexed: FileIndex.shared.indexedParts(inside: scope))
            p.folderSearch = search
            search.start()
        }
        let name = Places.displayName(scope)
        let isCurrent = { generation == p.searchGeneration && p.destination == target }
        // Small folders are done almost at once: give them a moment so they don't flash "Searching…".
        if !search.isFinished { try? await Task.sleep(for: .milliseconds(120)) }
        var shown = -1
        while isCurrent() {
            let finished = search.isFinished
            let found = await search.search(text)
            guard isCurrent() else { return }
            if finished || found.total > 0, finished || found.total != shown {
                shown = found.total
                p.browser.showResults(found.hits.map(FileEntry.init(hit:)), total: found.total)
            } else if shown < 0 {
                shown = 0
                p.browser.showMessage(symbol: "magnifyingglass", title: String(localized: "Searching…"),
                                      message: String(localized: "“\(name)” isn’t in the index, so Strata is reading it directly."))
            }
            if finished {
                var parts = [found.total == 0 ? String(localized: "No results in “\(name)”")
                    : String(localized: "\(found.total) results in “\(name)”", comment: "plural")]
                if let filter = found.interpretation { parts.append(filter.summary) }
                parts.append(search.usesIndex ? String(localized: "searched directly, indexed folders from the index")
                                              : String(localized: "not indexed, searched directly"))
                showSummary(parts.joined(separator: " · "), for: p)
            } else {
                showSummary(String(localized: "Searching “\(name)” directly… \(search.scannedCount) items", comment: "plural"), for: p)
            }
            if finished {
                // The scan answers more searches here for a minute (`canServe`); after that its memory goes.
                Task { [weak p] in
                    try? await Task.sleep(for: .seconds(61))
                    if let p, p.folderSearch === search { p.folderSearch = nil }
                }
                return
            }
            // Searching the store takes its read lock, which pauses the scan: check less often once it's big.
            try? await Task.sleep(for: .milliseconds(search.scannedCount > 200_000 ? 1000 : 400))
        }
    }

    /// Hashes candidates in the background; leaving the view cancels it.
    private func findDuplicates(in p: Pane) {
        p.searchGeneration += 1
        let generation = p.searchGeneration
        guard FileIndex.shared.isReady else {
            p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                                  message: String(localized: "Duplicates appear once the first index is built."))
            return
        }
        p.browser.showMessage(symbol: "square.on.square", title: String(localized: "Looking for duplicates…"))
        let cancelled = CancelFlag()
        p.duplicateSearch?.set()
        p.duplicateSearch = cancelled
        Task {
            let groups = await FileIndex.shared.duplicates(progress: { done, total in
                Task { @MainActor in
                    guard generation == p.searchGeneration, total > 0 else { return }
                    p.browser.showMessage(symbol: "square.on.square", title: String(localized: "Looking for duplicates…"),
                                          message: String(localized: "Checked \(done.formatted()) of \(total) size groups.", comment: "plural"))
                }
            }, isCancelled: { cancelled.isSet }) ?? []
            guard generation == p.searchGeneration, p.destination == .duplicates else { return }
            let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
            let rows = groups.prefix(500).map { group in
                let entries = group.paths.compactMap { FileEntry(url: URL(fileURLWithPath: $0)) }
                let name = (group.paths.first as NSString?)?.lastPathComponent ?? ""
                let detail = [
                    String(localized: "\(group.paths.count) copies", comment: "plural"),
                    String(localized: "\(Format.bytes(group.size)) each", comment: "Size of each copy of a duplicate file"),
                    String(localized: "\(Format.bytes(group.reclaimable)) to reclaim", comment: "Disk space freed by removing the extra copies"),
                ].joined(separator: " · ")
                return (title: name, detail: detail, entries: entries)
            }.filter { $0.entries.count > 1 }
            if rows.isEmpty {
                p.browser.showMessage(symbol: "checkmark.circle", title: String(localized: "No duplicates"),
                                      message: String(localized: "No identical files of 1 MB or more."))
            } else {
                p.browser.showGroups(rows, summary: String(localized: "\(groups.count) sets of duplicates", comment: "plural") + " · "
                                     + String(localized: "\(Format.bytes(reclaimable)) to reclaim", comment: "Disk space freed by removing the extra copies"))
            }
        }
    }

    /// Searches and Recents follow the index as it changes, at most every couple of seconds: something in your home
    /// folder is always changing (caches, logs), and searching the whole index on each change kept the CPU busy.
    @objc private func indexChanged() {
        guard !indexRefreshScheduled else { return }
        indexRefreshScheduled = true
        let wait = max(0, Self.indexRefreshInterval - Date().timeIntervalSince(lastIndexRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            indexRefreshScheduled = false
            lastIndexRefresh = Date()
            for p in panes {
                switch p.destination {
                case .search, .recents: runSearch(in: p)
                case .folder, .duplicates: break
                }
            }
        }
    }

    private static let indexRefreshInterval: TimeInterval = 2

    @objc private func indexPhaseChanged() {
        for p in panes where p.destination == .recents && FileIndex.shared.isReady { runSearch(in: p) }
        refreshPanels()
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        panes.forEach { $0.stopBackgroundWork() }
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (NSApp.delegate as? AppDelegate)?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        split.sidebar.reload()
        // Catch commits, checkouts and edits made in other apps while we were in the background (tags in Finder too).
        GitStatusStore.shared.invalidate(containing: location)
        panes.forEach { $0.browser.rereadTags() }
    }

    @objc private func gitStatusChanged(_ notification: Notification) {
        updateGitChrome()
        split.inspector.gitStatusChanged(notification)
    }

    /// Branch pill after the repository's crumb: from the last status, or straight from HEAD until it arrives.
    private func updateGitChrome() {
        let store = GitStatusStore.shared
        guard case .folder = destination, let repository = store.repository(containing: location) else {
            pathBar.gitRoot = nil
            pathBar.branchPill.model = nil
            return
        }
        pathBar.gitRoot = repository.root
        pathBar.branchPill.model = store.snapshot(for: repository.root).map(GitBranchPill.Model.init)
            ?? GitBranchPill.Model(placeholderFor: repository)
    }

    func privacyChanged() {
        panes.forEach { $0.browser.privacyChanged() }
        FileIndex.shared.refreshConfig()
        StrataAI.startIndexing()
    }

    /// Where each tab and pane is, for workspaces. A pane waiting for its share or disk counts as being there.
    var snapshot: [String] {
        // A container's files are gone after quitting: such a pane comes back at home.
        // A server's folder is kept (opening the workspace connects to it again).
        panes.map { $0.waiting?.path ?? (ContainerCopies.contains($0.location) ? Places.home.path : $0.location.path) }
    }

    /// Each pane's view, for workspaces (`BrowserViewMode` raw values, in `snapshot`'s order).
    var snapshotModes: [Int] { panes.map { $0.waiting?.mode ?? $0.browser.mode.rawValue } }

    /// Shares that panes are waiting for: where each was mounted → the address that mounts it again.
    var waitingShares: [String: String] {
        var shares: [String: String] = [:]
        for case let waiting? in panes.map(\.waiting) {
            if let mountPoint = waiting.mountPoint, let address = waiting.address { shares[mountPoint] = address }
        }
        return shares
    }

    /// Panes kept for a folder they can't show yet, by position (0 is the left one).
    var waitingPanes: [(index: Int, folder: WaitingFolder)] {
        panes.enumerated().compactMap { index, pane in pane.waiting.map { (index, $0) } }
    }

    /// Keeps the pane at `index` for `folder` until it can go there.
    func wait(pane index: Int, for folder: WaitingFolder) {
        guard panes.indices.contains(index) else { return }
        panes[index].waiting = folder
    }

    /// The pane at `index` no longer waits (its folder is gone); it stays where it is.
    func stopWaiting(pane index: Int) {
        guard panes.indices.contains(index) else { return }
        panes[index].waiting = nil
    }

    /// The workspace this tab was opened from or saved as: Window ▸ Workspaces can update it, and opening it again
    /// brings this window forward. Use `groupWorkspaceName` for the window as a whole.
    var workspaceName: String?

    /// The workspace of this window's tabs (a tab added later with ⌘T belongs to it too).
    var groupWorkspaceName: String? {
        guard let window else { return workspaceName }
        return services.workspaces.ownedControllers(of: window).lazy.compactMap(\.workspaceName).first
    }

    /// Closed: a workspace still connecting leaves it alone.
    private(set) var isClosed = false

    /// Puts each pane in its saved view (nil: as it is), without changing the view new windows open in.
    func applyModes(_ modes: [Int?]) {
        let focused = pane
        for (p, raw) in zip(panes, modes) {
            guard let raw, let mode = BrowserViewMode(rawValue: raw) else { continue }
            p.browser.setMode(mode, remember: false)
        }
        // Changing a view focuses it: the pane that had focus gets it back.
        window?.makeFirstResponder(focused.browser.focusView)
        syncViewModeItem()
    }

    /// Shows `url` in the pane at `index` (0 is the left one), in the view `mode` (raw value) if given, without adding to
    /// its history.
    func navigatePane(_ index: Int, to url: URL, mode: Int? = nil) {
        guard !isClosed, panes.indices.contains(index) else { return }
        let target = panes[index]
        go(.folder(url.standardizedFileURL), in: target, recordHistory: false)
        if let mode, let viewMode = BrowserViewMode(rawValue: mode) {
            let focused = pane
            target.browser.setMode(viewMode, remember: false)
            window?.makeFirstResponder(focused.browser.focusView)
            syncViewModeItem()
        }
    }

    @objc private func cloudStatusChanged() {
        guard split.splitViewItems.last?.isCollapsed == false else { return }
        refreshPanels()
    }

    private func refreshPanels() {
        syncViewModeItem()
        var status = browser.statusText
        if case .scanning(let items) = FileIndex.shared.phase {
            status += (status.isEmpty ? "" : "  ·  ") + String(localized: "Indexing \(items) items…", comment: "plural")
        }
        split.status.text = status
        // Two panes: each shows its own counts under its list; the shared bar would sit across both.
        split.status.isHidden = isDualPane
        for p in panes { p.host.setStatus(isDualPane ? p.browser.statusText : nil) }
        let folder: FileEntry? = { if case .folder = destination { return pane.folderEntry } else { return nil } }()
        let browser = browser
        let location = location
        split.inspector.onShowFolder = { [weak self] folder, item in self?.navigate(to: folder, select: item) }
        split.inspector.onOpenFolder = { [weak self] folder in self?.openFolder(folder) }
        split.inspector.onOpenContainer = { [weak self] id in self?.openContainer(id) }
        split.inspector.show(entries: browser.selectedEntries, folder: folder,
                             folderSize: { url in browser.folderSize(url, request: true) },
                             canMeasure: { entry in
                                 entry.url == location ? !Privacy.measuringWouldPrompt(entry.url, browsing: entry.url)
                                     : browser.canMeasure(entry)
                             })
    }
}

extension BrowserWindowController: BrowserViewControllerDelegate {
    func browser(_ browser: BrowserViewController, navigateTo url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        navigate(to: url)
    }

    func browser(_ browser: BrowserViewController, showArchiveCopy folder: URL) {
        // Not if you've since moved to the other pane or another window: the copy stays cached for next time.
        guard browser === pane.browser else { return }
        navigate(to: folder)
    }

    func browser(_ browser: BrowserViewController, openingArchive archive: URL?, stop: (() -> Void)?) {
        guard browser === pane.browser else { return }
        guard let archive else {
            if case .folder(let url) = destination { updateNotice(for: url) } else { split.noticeBar.hide() }
            return
        }
        split.noticeBar.show(symbol: "archivebox", text: String(localized: "Opening “\(archive.lastPathComponent)”…"),
                             button: stop == nil ? nil : String(localized: "Stop", comment: "Button: stop opening an archive"),
                             action: stop)
    }

    func browser(_ browser: BrowserViewController, reveal url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        navigate(to: url.deletingLastPathComponent(), select: url)
    }

    /// The folders every window's panes show.
    static func foldersShown() -> Set<String> {
        var shown: Set<String> = []
        for case let controller as BrowserWindowController in NSApp.windows.compactMap(\.windowController) {
            for pane in controller.panes {
                if let folder = pane.browser.directory { shown.insert(folder.standardizedFileURL.path) }
            }
        }
        return shown
    }

    /// Archive copies shown in any window's panes (their top folders), which pruning must leave alone.
    static func archiveCopiesShown() -> Set<String> {
        var shown: Set<String> = []
        for case let controller as BrowserWindowController in NSApp.windows.compactMap(\.windowController) {
            for pane in controller.panes {
                if let folder = pane.browser.directory, let (_, top) = ArchiveCache.archive(containing: folder) {
                    shown.insert(top.standardizedFileURL.path)
                }
            }
        }
        return shown
    }

    /// One Back step for a whole spring-loaded dive, and the folders passed through don't count as visits.
    func browser(_ browser: BrowserViewController, springLoadTo url: URL, drag: Int) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        let firstHop = owner.springDrag != drag
        owner.springDrag = drag
        go(.folder(url.standardizedFileURL), recordHistory: firstHop, countVisit: false)
    }

    func browserSelectionDidChange(_ browser: BrowserViewController) {
        if browser === pane.browser { refreshPanels() }
    }

    func browserContentDidChange(_ browser: BrowserViewController) {
        if browser === pane.browser {
            refreshPanels()
        } else if let owner = panes.first(where: { $0.browser === browser }) {
            owner.host.setStatus(isDualPane ? browser.statusText : nil)
        }
        updateHeaders()
    }

    /// Column view went deeper: show that folder in the path bar and title, without a new history entry.
    func browser(_ browser: BrowserViewController, columnLocationChanged url: URL) {
        guard browser === pane.browser, case .folder = destination else { return }
        if (pane.columnLocation ?? pane.location).fileViewKey != url.fileViewKey {
            pane.opening.cancel()
            refreshOpeningNotice()
        }
        pane.columnLocation = url
        pathBar.url = url
        window?.title = Places.displayName(url)
        pane.folderEntry = FileEntry(url: url)
        refreshPanels()
    }
}

extension BrowserWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarMode, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .pathBar, .flexibleSpace, .viewMode,
         .dualPane, .share, .search, .transfers, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .back, .forward:
            let isBack = id == .back
            let command = isBack ? StrataCommand.goBack : .goForward
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = command.title
            item.toolTip = isBack ? String(localized: "Back (⌘[)", comment: "Toolbar tooltip with its shortcut")
                : String(localized: "Forward (⌘])", comment: "Toolbar tooltip with its shortcut")
            item.image = command.image
            item.target = self
            item.action = command.action
            ToolbarThemeController.applyNavigation(to: item)
            item.visibilityPriority = .high
            return item
        case .pathBar:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = String(localized: "Location", comment: "Toolbar item: the path bar")
            item.view = pathBar
            item.visibilityPriority = .high
            return item
        case .sidebarMode:
            // Next to Hide Sidebar: what the sidebar shows, Places (Favorites, Locations…) or the folder tree.
            let places = String(localized: "Places", comment: "Sidebar switch: Favorites, Locations and the other sections")
            let folders = String(localized: "Folders", comment: "Sidebar switch: the tree of folders")
            let images = [NSImage(systemSymbolName: "star", accessibilityDescription: places)!,
                          NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: folders)!]
            let item = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne, labels: [places, folders],
                                          target: self, action: #selector(sidebarModeChanged(_:)))
            item.label = String(localized: "Sidebar", comment: "Toolbar item label: switch between Places and the folder tree")
            item.paletteLabel = String(localized: "Sidebar Contents", comment: "Toolbar customization palette label")
            item.controlRepresentation = .expanded
            item.subitems[0].toolTip = String(localized: "Favorites, disks and other places", comment: "Tooltip of the sidebar's Places switch")
            item.subitems[1].toolTip = String(localized: "Every folder, as a tree", comment: "Tooltip of the sidebar's Folders switch")
            item.selectedIndex = services.preferences.sidebarShowsTree ? 1 : 0
            item.visibilityPriority = .low
            sidebarModeItem = item
            return item
        case .viewMode:
            let item = BrowserViewMode.makeToolbarItem(id, target: self, action: #selector(viewModeChanged(_:)))
            item.selectedIndex = browser.effectiveMode.position
            item.isEnabled = !browser.isShowingResults
            item.visibilityPriority = .high
            viewModeItem = item
            return item
        case .dualPane:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = String(localized: "Dual Pane")
            item.toolTip = String(localized: "Show two folders side by side (⌘\\). Tab switches sides; F5 copies and F6 moves to the other side.")
            item.image = NSImage(systemSymbolName: isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                                 accessibilityDescription: String(localized: "Dual Pane"))
            item.target = self
            item.action = #selector(toggleDualPane(_:))
            item.isBordered = true
            dualPaneItem = item
            return item
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = String(localized: "Share", comment: "Toolbar button: share the selection")
            item.toolTip = String(localized: "Share the selection: AirDrop, Messages, Mail and more")
            item.delegate = self
            // The first to go into the overflow menu when the window is narrow, before Dual Pane and Search.
            item.visibilityPriority = .low
            return item
        case .transfers:
            let item = TransfersToolbarItem(itemIdentifier: id, queue: services.transfers)
            item.onReveal = { [weak self] job in self?.navigate(to: job.destination, select: job.createdItems.last) }
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = String(localized: "Search", comment: "Placeholder of the toolbar search field")
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .back: return validateMenuItem(StrataCommand.goBack.menuItem())
        case .forward: return validateMenuItem(StrataCommand.goForward.menuItem())
        case .viewMode: return !browser.isShowingResults
        default: return true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(syncViewMode(_:)):
            item.state = item.tag == browser.effectiveMode.rawValue ? .on : .off
            return !browser.isShowingResults || item.tag == BrowserViewMode.list.rawValue
        case #selector(goBack(_:)): return !pane.backStack.isEmpty
        case #selector(goForward(_:)): return !pane.forwardStack.isEmpty
        case #selector(toggleDualPane(_:)):
            item.state = isDualPane ? .on : .off
            return true
        case #selector(toggleFolderTree(_:)):
            item.state = services.preferences.sidebarShowsTree ? .on : .off
            return true
        case #selector(focusOtherPane(_:)):
            return isDualPane
        case #selector(compareWithOtherPane(_:)):
            return paneFolders != nil
        case #selector(ejectVolume(_:)):
            return !ejectTargets.isEmpty
        case #selector(askStrata(_:)):
            return canAskStrata
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            guard isDualPane, let other = panes.first(where: { $0 !== pane }), case .folder = other.destination else { return false }
            return !browser.selectedURLs.isEmpty
        case #selector(goToEnclosingFolder(_:)):
            if case .folder = destination { return location.path != "/" }
            return true
        default: return true
        }
    }
}

extension BrowserWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        searchTextChanged(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if case .search = destination { leaveSearch() } else { browser.setFilter("") }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            focusList()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            focusList()
            browser.openSelection(nil)
            return true
        default:
            return false
        }
    }
}

extension BrowserWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        browser.selectedURLs
    }
}
