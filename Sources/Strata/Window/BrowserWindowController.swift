import AppKit

extension NSToolbarItem.Identifier {
    static let back = Self("back")
    static let forward = Self("forward")
    static let pathBar = Self("pathBar")
    static let search = Self("search")
    static let viewMode = Self("viewMode")
    static let dualPane = Self("dualPane")
    static let share = Self("share")
}

/// One browser window (or tab): one or two panes, each with its own place and history, sharing the sidebar,
/// path bar, search field and inspector, which follow whichever pane has focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let largeFilesQuery = "kind:file size:>500mb"

    /// What a search is called in titles: Large Files by name, others by their text.
    static func searchTitle(_ text: String) -> String {
        text == largeFilesQuery ? "Large Files" : "Search: \(text)"
    }

    private var panes: [Pane]
    /// The pane with focus; navigation, search and the inspector act on it.
    private(set) var pane: Pane
    var onClose: (() -> Void)?

    let split: MainSplitViewController
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

    var destination: Destination {
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
        split.sidebar.onOpenInNewTab = { [weak self] url in
            guard let self, let app = NSApp.delegate as? AppDelegate else { return }
            app.openWindow(at: url, tabbedWith: self.window)
        }
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

    /// Adds a second pane (at `url`, or where the current one is), or closes the pane without focus.
    func toggleDualPane(at url: URL?) {
        if isDualPane {
            let closing = panes.first { $0 !== pane }!
            closing.stopBackgroundWork()
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

    /// `countVisit: false` for folders only passed through (spring loading): they don't become frequent places.
    private func go(_ target: Destination, in targetPane: Pane? = nil, select: URL? = nil, recordHistory: Bool = true,
                    countVisit: Bool = true) {
        let p = targetPane ?? pane
        p.columnLocation = nil
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
            if !ArchiveCache.contains(url) {
                if countVisit { Frecency.shared.record(url) }
                Prefs.lastLocation = url
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
            window?.representedURL = url
            setSearchField("")
            split.scopeBar.isHidden = true
            updateNotice(for: url)
        case .search(let text, let scope):
            setSearchField(text)
            // The query itself, so a search shows what was asked (Large Files by name).
            pathBar.showTitle(text == Self.largeFilesQuery ? "Large Files" : "“\(text)”", symbol: "magnifyingglass")
            if text == Self.largeFilesQuery && scope == nil {
                split.sidebar.highlight(.largeFiles)
            } else {
                split.sidebar.highlight(SavedSearches.all.first { $0.query == text && $0.scopePath == scope?.path }.map { .search($0) })
            }
            window?.title = Self.searchTitle(text)
            window?.representedURL = nil
            split.scopeBar.configure(folderName: Places.displayName((scope ?? location)),
                                     everywhere: scope == nil)
            split.scopeBar.setSummary(pane.searchSummary)
            split.scopeBar.isHidden = false
            split.noticeBar.hide()
        case .duplicates:
            setSearchField("")
            pathBar.showTitle("Duplicates", symbol: "square.on.square")
            split.sidebar.highlight(.duplicates)
            window?.title = "Duplicates"
            window?.representedURL = nil
            split.scopeBar.isHidden = true
            split.noticeBar.hide()
        case .recents:
            setSearchField("")
            pathBar.showTitle("Recents", symbol: "clock")
            split.sidebar.highlight(.recents)
            window?.title = "Recents"
            window?.representedURL = nil
            split.scopeBar.isHidden = true
            split.noticeBar.hide()
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
            // In column view "here" is the focused column's folder, not the first column's.
            let current = (browser.mode == .columns ? pane.columnLocation : nil) ?? location
            guard current.path != "/" else { return }
            // Up from an archive opened as a folder: the folder the archive is in, with the archive selected.
            if let (archive, top) = ArchiveCache.archive(containing: current), top.standardizedFileURL == current.standardizedFileURL {
                return navigate(to: archive.deletingLastPathComponent(), select: archive)
            }
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

    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openWindow(at: location, tabbedWith: window)
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        browser.setViewMode(sender)
    }

    /// Points the toolbar's view switcher at the current mode.
    func syncViewModeItem() {
        viewModeItem?.selectedIndex = browser.mode.position
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
        // Spotlight answers tag searches, so they don't wait for the first index.
        guard FileIndex.shared.isReady || SpotlightQuery.parse(query) != nil else {
            // The index is still being built for the first time: filter this folder meanwhile.
            browser.setFilter(query)
            return
        }
        if case .search(_, let scope) = destination {
            destination = .search(query, scope: scope)
            window?.title = Self.searchTitle(query)
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
                        p.browser.showMessage(symbol: "hourglass", title: "Indexing…", message: "Search works as soon as the first index is built.")
                        showSummary("", for: p)
                        return
                    }
                    if Privacy.measuringWouldPrompt(scope, browsing: p.location) {
                        // A link or saved search pointing into a guarded folder you haven't opened: macOS would ask.
                        let name = Places.displayName(scope)
                        p.browser.showMessage(symbol: "lock", title: "Open “\(name)” to search it",
                                              message: "macOS asks before apps read this folder. Open it in Strata once, then search it.")
                        showSummary("", for: p)
                        return
                    }
                    await searchDirectly(text, in: scope, pane: p, generation: generation, target: target)
                    return
                }
                p.folderSearch?.cancel()
                p.folderSearch = nil
                guard let result = await FileIndex.shared.understand(text, in: scope) else {
                    p.browser.showMessage(symbol: "hourglass", title: "Indexing…", message: "Search works as soon as the first index is built.")
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
                p.browser.showResults(entries, total: result.total + byContent.count)
                let place = scope.map { "in “\(Places.displayName($0))”" } ?? "everywhere"
                var summary = result.total + byContent.count == 0 ? "No results \(place)"
                    : "\(Format.count(result.total + byContent.count, "result", "results")) \(place)"
                if !byContent.isEmpty { summary += " · \(byContent.count) by content" }
                if let filter = result.interpretation { summary += " · " + filter.summary }
                showSummary(summary, for: p)
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
        let place = scope.map { "in “\(Places.displayName($0))”" } ?? "on this Mac"
        var summary = result.total == 0 ? "No results \(place)" : "\(Format.count(result.total, "result", "results")) \(place)"
        summary += " · \(query.summary)"
        if result.total > result.urls.count { summary += " · first \(result.urls.count.formatted()) shown" }
        if result.timedOut { summary += " · Spotlight took too long; results may be incomplete" }
        showSummary(summary, for: p)
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
        let place = "“\(Places.displayName(scope))”"
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
                p.browser.showMessage(symbol: "magnifyingglass", title: "Searching…",
                                      message: "\(place) isn’t in the index, so Strata is reading it directly.")
            }
            if finished {
                var summary = found.total == 0 ? "No results in \(place)"
                    : "\(Format.count(found.total, "result", "results")) in \(place)"
                if let filter = found.interpretation { summary += " · " + filter.summary }
                showSummary(summary + (search.usesIndex ? " · searched directly, indexed folders from the index"
                                                        : " · not indexed, searched directly"), for: p)
            } else {
                showSummary("Searching \(place) directly… \(Format.count(search.scannedCount, "item", "items"))", for: p)
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
        split.noticeBar.show(symbol: "archivebox", text: "Opening “\(archive.lastPathComponent)”…",
                             button: stop == nil ? nil : "Stop", action: stop)
    }

    func browser(_ browser: BrowserViewController, reveal url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        navigate(to: url.deletingLastPathComponent(), select: url)
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
        pane.columnLocation = url
        pathBar.url = url
        window?.title = Places.displayName(url)
        pane.folderEntry = FileEntry(url: url)
        refreshPanels()
    }
}

extension BrowserWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .pathBar, .flexibleSpace, .viewMode,
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
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"
            item.toolTip = "Share the selection: AirDrop, Messages, Mail and more"
            item.delegate = self
            // The first to go into the overflow menu when the window is narrow, before Dual Pane and Search.
            item.visibilityPriority = .low
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
