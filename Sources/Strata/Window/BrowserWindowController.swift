import AppKit

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let pathBar = Self("pathBar")
    static let search = Self("search")
    static let viewMode = Self("viewMode")
    static let dualPane = Self("dualPane")
}

/// One browser window (or tab): one or two panes, each with its own place and history, sharing the sidebar,
/// path bar, search field and inspector, which follow whichever pane has focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let largeFilesQuery = "size:>500mb"

    private var panes: [Pane]
    /// The pane with focus; navigation, search and the inspector act on it.
    private(set) var pane: Pane
    var onClose: (() -> Void)?

    private let split: MainSplitViewController
    private let pathBar = PathBar()
    private var searchItem: NSSearchToolbarItem?
    private var viewModeItem: NSToolbarItemGroup?
    private var dualPaneItem: NSToolbarItem?
    private var responderObservation: NSKeyValueObservation?
    let palette = CommandPalette()
    var pathQuery = PathQuery()
    var browser: BrowserViewController { pane.browser }
    var splitController: NSSplitViewController { split }
    var isDualPane: Bool { panes.count > 1 }

    private var destination: Destination {
        get { pane.destination }
        set { pane.destination = newValue }
    }

    var location: URL { pane.location }

    init(location: URL, select: URL? = nil, secondPane: URL? = nil) {
        let first = Pane(location: location)
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
        pathBar.onNavigate = { [weak self] url, select in self?.navigate(to: url, select: select) }
        pathBar.onFinishEditing = { [weak self] in self?.focusList() }
        split.scopeBar.onScopeChange = { [weak self] everywhere in self?.changeSearchScope(everywhere: everywhere) }
        split.scopeBar.onSave = { [weak self] in self?.saveSearch() }
        NotificationCenter.default.addObserver(self, selector: #selector(indexPhaseChanged), name: .indexPhaseDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: .indexDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gitStatusChanged), name: .gitStatusDidChange, object: nil)
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
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ pane: Pane) {
        pane.browser.delegate = self
        pane.host.onActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            activate(pane)
            window?.makeFirstResponder(pane.browser.focusView)
        }
        pane.browser.outlineView.onTab = { [weak self] in self?.focusOtherPane(nil) }
    }

    // MARK: - Panes

    @objc func toggleDualPane(_ sender: Any?) {
        toggleDualPane(at: nil)
    }

    /// Adds a second pane (at `url`, or where the current one is), or closes the pane without focus.
    func toggleDualPane(at url: URL?) {
        if isDualPane {
            let closing = panes.first { $0 !== pane }!
            split.panes.remove(closing.host)
            panes.removeAll { $0 === closing }
        } else {
            let second = Pane(location: url ?? pane.location)
            configure(second)
            panes.append(second)
            split.panes.add(second.host)
            go(.folder(second.location), in: second, recordHistory: false)
        }
        refreshPanels()
        // Filled symbol while two panes are showing.
        dualPaneItem?.image = NSImage(systemSymbolName: isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                                      accessibilityDescription: "Dual Pane")
        updateHeaders()
    }

    @objc func focusOtherPane(_ sender: Any?) {
        guard let other = panes.first(where: { $0 !== pane }) else { return }
        activate(other)
        window?.makeFirstResponder(other.browser.focusView)
    }

    /// Copies (or moves) the selection into the other pane's folder, like a commander's F5/F6.
    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(move: false) }
    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(move: true) }

    private func transferToOtherPane(move: Bool) {
        guard let other = panes.first(where: { $0 !== pane }), case .folder(let target) = other.destination else { return }
        let urls = browser.selectedURLs
        guard !urls.isEmpty else { return }
        let job = TransferQueue.shared.enqueue(urls, to: target, mode: move ? .move : .copy,
                                               undo: window?.undoManager, conflicts: .sheet(for: window))
        job.onFinish = { [weak self] job in
            guard self != nil else { return }
            other.browser.select(job.createdItems)
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

    private func open(_ target: SidebarTarget) {
        switch target {
        case .folder(let url): navigate(to: url)
        case .recents: go(.recents)
        case .search(let saved): go(.search(saved.query, scope: saved.scopePath.map { URL(fileURLWithPath: $0) }))
        case .duplicates: go(.duplicates)
        case .largeFiles: go(.search(Self.largeFilesQuery, scope: nil))
        }
    }

    private func go(_ target: Destination, in targetPane: Pane? = nil, select: URL? = nil, recordHistory: Bool = true) {
        let p = targetPane ?? pane
        if target != .duplicates { p.duplicateSearch?.set() }
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
            Frecency.shared.record(url)
            Prefs.lastLocation = url
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
            window?.title = FileManager.default.displayName(atPath: url.path)
            window?.representedURL = url
            setSearchField("")
            split.scopeBar.isHidden = true
        case .search(let text, let scope):
            setSearchField(text)
            pathBar.showTitle("Search", symbol: "magnifyingglass")
            if text == Self.largeFilesQuery && scope == nil {
                split.sidebar.highlight(.largeFiles)
            } else {
                split.sidebar.highlight(SavedSearches.all.first { $0.query == text && $0.scopePath == scope?.path }.map { .search($0) })
            }
            window?.title = "Search: \(text)"
            window?.representedURL = nil
            split.scopeBar.configure(folderName: FileManager.default.displayName(atPath: (scope ?? location).path),
                                     everywhere: scope == nil)
            split.scopeBar.isHidden = false
        case .duplicates:
            setSearchField("")
            pathBar.showTitle("Duplicates", symbol: "square.on.square")
            split.sidebar.highlight(.duplicates)
            window?.title = "Duplicates"
            window?.representedURL = nil
            split.scopeBar.isHidden = true
        case .recents:
            setSearchField("")
            pathBar.showTitle("Recents", symbol: "clock")
            split.sidebar.highlight(.recents)
            window?.title = "Recents"
            window?.representedURL = nil
            split.scopeBar.isHidden = true
        }
        viewModeItem?.selectedIndex = browser.mode.position
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
            guard location.path != "/" else { return }
            navigate(to: location.deletingLastPathComponent(), select: location)
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

    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openWindow(at: location, tabbedWith: window)
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        browser.setViewMode(sender)
    }

    /// Keeps the toolbar's view switcher in sync when ⌘1–⌘4 change the mode.
    @objc func syncViewMode(_ sender: Any?) {
        browser.setViewMode(sender)
        viewModeItem?.selectedIndex = browser.mode.position
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
        guard FileIndex.shared.isReady else {
            // The index is still being built for the first time: filter this folder meanwhile.
            browser.setFilter(query)
            return
        }
        if case .search(_, let scope) = destination {
            destination = .search(query, scope: scope)
            window?.title = "Search: \(query)"
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

    private func saveSearch() {
        guard case .search(let text, let scope) = destination else { return }
        var searches = SavedSearches.all
        let saved = SavedSearch(name: text, query: text, scopePath: scope?.path)
        guard !searches.contains(saved) else { return }
        searches.append(saved)
        SavedSearches.all = searches
        split.sidebar.highlight(.search(saved))
    }

    private func runSearch(in p: Pane) {
        p.searchGeneration += 1
        let generation = p.searchGeneration
        let target = p.destination
        Task {
            switch target {
            case .search(let text, let scope):
                guard let result = await FileIndex.shared.understand(text, in: scope) else {
                    p.browser.showMessage(symbol: "hourglass", title: "Indexing…", message: "Search works as soon as the first index is built.")
                    return
                }
                // Documents whose text matches (on-device, Documents/Desktop/Downloads) follow the name matches.
                let contentQuery = result.interpretation?.contentQuery ?? (result.interpretation == nil ? text : nil)
                let contentHits = contentQuery.map { $0.count >= 3 } == true ? await StrataAI.index.search(contentQuery!, limit: 15) : []
                guard generation == p.searchGeneration, p.destination == target else { return }
                var entries = result.hits.map(FileEntry.init(hit:))
                let known = Set(entries.map { $0.url.standardizedFileURL.path })
                let byContent = contentHits
                    .filter { hit in
                        !known.contains(hit.url.standardizedFileURL.path) && (scope.map { hit.url.path.hasPrefix($0.path + "/") } ?? true)
                    }
                    .compactMap { FileEntry(url: $0.url) }
                entries += byContent
                p.browser.showResults(entries, total: result.total + byContent.count)
                guard p === pane else { return }
                let place = scope.map { "in “\(FileManager.default.displayName(atPath: $0.path))”" } ?? "everywhere"
                var summary = result.total + byContent.count == 0 ? "No matches \(place)"
                    : "\(Format.count(result.total + byContent.count, "match", "matches")) \(place)"
                if !byContent.isEmpty { summary += " · \(byContent.count) by content" }
                if let filter = result.interpretation { summary += " · " + filter.summary }
                split.scopeBar.setSummary(summary)
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

    /// Hashes candidates in the background; leaving the view cancels it.
    private func findDuplicates(in p: Pane) {
        p.searchGeneration += 1
        let generation = p.searchGeneration
        guard FileIndex.shared.isReady else {
            p.browser.showMessage(symbol: "hourglass", title: "Indexing…", message: "Duplicates appear once the first index is built.")
            return
        }
        p.browser.showMessage(symbol: "square.on.square", title: "Looking for duplicates…")
        let cancelled = CancelFlag()
        p.duplicateSearch?.set()
        p.duplicateSearch = cancelled
        Task {
            let groups = await FileIndex.shared.duplicates(progress: { done, total in
                Task { @MainActor in
                    guard generation == p.searchGeneration, total > 0 else { return }
                    p.browser.showMessage(symbol: "square.on.square", title: "Looking for duplicates…",
                                          message: "Checked \(done.formatted()) of \(Format.count(total, "size group", "size groups")).")
                }
            }, isCancelled: { cancelled.isSet }) ?? []
            guard generation == p.searchGeneration, p.destination == .duplicates else { return }
            let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
            let rows = groups.prefix(500).map { group in
                let entries = group.paths.compactMap { FileEntry(url: URL(fileURLWithPath: $0)) }
                let name = (group.paths.first as NSString?)?.lastPathComponent ?? ""
                return (title: name, detail: "\(group.paths.count) copies · \(Format.bytes(group.size)) each · \(Format.bytes(group.reclaimable)) to reclaim",
                        entries: entries)
            }.filter { $0.entries.count > 1 }
            if rows.isEmpty {
                p.browser.showMessage(symbol: "checkmark.circle", title: "No duplicates", message: "No identical files of 1 MB or more.")
            } else {
                p.browser.showGroups(rows, summary: "\(Format.count(groups.count, "set", "sets")) of duplicates · \(Format.bytes(reclaimable)) to reclaim")
            }
        }
    }

    @objc private func indexChanged() {
        for p in panes {
            switch p.destination {
            case .search, .recents: runSearch(in: p)
            case .folder, .duplicates: break
            }
        }
    }

    @objc private func indexPhaseChanged() {
        for p in panes where p.destination == .recents && FileIndex.shared.isReady { runSearch(in: p) }
        refreshPanels()
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (NSApp.delegate as? AppDelegate)?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        split.sidebar.reload()
        // Catch commits, checkouts and edits made in other apps while we were in the background.
        GitStatusStore.shared.invalidate(containing: location)
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

    /// Where each tab and pane is, for workspaces.
    var snapshot: [String] {
        panes.map { $0.location.path }
    }

    private func refreshPanels() {
        var status = browser.statusText
        if case .scanning(let items) = FileIndex.shared.phase {
            status += (status.isEmpty ? "" : "  ·  ") + "Indexing \(items.formatted()) items…"
        }
        split.status.text = status
        // Two panes: each shows its own counts under its list; the shared bar would sit across both.
        split.status.isHidden = isDualPane
        for p in panes { p.host.setStatus(isDualPane ? p.browser.statusText : nil) }
        let folder: FileEntry? = { if case .folder = destination { return pane.folderEntry } else { return nil } }()
        let browser = browser
        let location = location
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
        pathBar.url = url
        window?.title = FileManager.default.displayName(atPath: url.path)
        pane.folderEntry = FileEntry(url: url)
        refreshPanels()
    }
}

extension BrowserWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .pathBar, .flexibleSpace, .viewMode,
         .dualPane, .search, .transfers, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .back, .forward:
            let isBack = id == .back
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = isBack ? "Back" : "Forward"
            item.toolTip = isBack ? "Back (⌘[)" : "Forward (⌘])"
            item.image = NSImage(systemSymbolName: isBack ? "chevron.left" : "chevron.right", accessibilityDescription: item.label)
            item.target = self
            item.action = isBack ? #selector(goBack(_:)) : #selector(goForward(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            return item
        case .pathBar:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Location"
            item.view = pathBar
            item.visibilityPriority = .high
            return item
        case .viewMode:
            let item = BrowserViewMode.makeToolbarItem(id, target: self, action: #selector(viewModeChanged(_:)))
            item.selectedIndex = browser.mode.position
            item.visibilityPriority = .high
            viewModeItem = item
            return item
        case .dualPane:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Dual Pane"
            item.toolTip = "Show two folders side by side (⌘\\). Tab switches sides; F5 copies and F6 moves to the other side."
            item.image = NSImage(systemSymbolName: isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                                 accessibilityDescription: "Dual Pane")
            item.target = self
            item.action = #selector(toggleDualPane(_:))
            item.isBordered = true
            dualPaneItem = item
            return item
        case .transfers:
            let item = TransfersToolbarItem(itemIdentifier: id)
            item.onReveal = { [weak self] job in self?.navigate(to: job.destination, select: job.createdItems.last) }
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search"
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
        case .back: return !pane.backStack.isEmpty
        case .forward: return !pane.forwardStack.isEmpty
        default: return true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(syncViewMode(_:)):
            item.state = item.tag == browser.mode.rawValue ? .on : .off
            return true
        case #selector(goBack(_:)): return !pane.backStack.isEmpty
        case #selector(goForward(_:)): return !pane.forwardStack.isEmpty
        case #selector(toggleDualPane(_:)):
            item.state = isDualPane ? .on : .off
            return true
        case #selector(focusOtherPane(_:)):
            return isDualPane
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
