import AppKit
import Quartz

protocol BrowserViewControllerDelegate: AnyObject {
    func browser(_ browser: BrowserViewController, navigateTo url: URL)
    func browserSelectionDidChange(_ browser: BrowserViewController)
    func browserContentDidChange(_ browser: BrowserViewController)
    /// Column view moved deeper without changing the browser's folder.
    func browser(_ browser: BrowserViewController, columnLocationChanged url: URL)
}

/// One row in the list. Children load the first time a folder is expanded.
final class FileNode {
    var entry: FileEntry
    weak var parent: FileNode?
    var children: [FileNode]?
    var isLoadingChildren = false
    var matchIndices: [Int] = []
    /// Set on header rows that group other rows (duplicate sets); they aren't files themselves.
    var groupTitle: String?
    var groupDetail: String?

    init(entry: FileEntry, parent: FileNode? = nil) {
        self.entry = entry
        self.parent = parent
    }

    var url: URL { entry.url }
}

enum SortKey: String {
    case name, modified, size, kind
}

private extension NSUserInterfaceItemIdentifier {
    static let name = Self("name")
    static let modified = Self("modified")
    static let size = Self("size")
    static let kind = Self("kind")
    static let location = Self("location")
    static let nameCell = Self("NameCell")
    static let textCell = Self("TextCell")
    static let groupCell = Self("GroupCell")
}

final class BrowserViewController: NSViewController {
    weak var delegate: BrowserViewControllerDelegate?
    private(set) var directory: URL?
    private(set) var loadError: Error?
    private(set) var isLoaded = false
    /// A different folder is being read; the rows still showing belong to the previous one, so file commands wait.
    private(set) var isLoadingFolder = false
    private(set) var filter = ""
    private(set) var availableCapacity: Int64?

    let outlineView = FileOutlineView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
    private let filterPill = FilterPill()
    private let sizer = FolderSizer()

    private var nodes: [FileNode] = []
    private var rows: [FileNode] = []
    /// Rows by standardized path: folder URLs from directory listings end in "/", URLs built elsewhere don't.
    private var nodesByPath: [String: FileNode] = [:]
    private var generation = 0
    private var watcher: DirectoryWatcher?
    /// Keeps git status for the shown folder's repository fresh (FSEvents) while this folder is shown.
    private var gitObservation: GitObservation?
    private var sortKey: SortKey = .name
    private var ascending = true
    private var pendingSelection: [URL] = []
    private var pendingRename: URL?
    private var renaming: FileNode?
    private var resortWork: DispatchWorkItem?
    /// Showing search results or Recents instead of a folder's contents.
    private(set) var isShowingResults = false
    private var resultsTotal = 0
    private var resultsSummary: String?
    private var folderSortDescriptors: [NSSortDescriptor] = []
    /// How the folder is presented. Results (search, Recents, Duplicates) always use the list.
    private(set) var mode = BrowserViewMode(rawValue: Prefs.viewMode) ?? .list
    var gridController: GridViewController?
    var columnController: ColumnBrowserViewController?
    var treemapController: TreemapViewController?

    func setStoredMode(_ newMode: BrowserViewMode) { mode = newMode }
    var outlineScrollView: NSScrollView { scrollView }
    /// Rows after filtering (what the views show) and all rows of the folder.
    var visibleRows: [FileNode] { rows }
    var allRows: [FileNode] { nodes }
    func openEntries(_ entries: [FileEntry]) { open(entries) }
    func contextMenu() -> NSMenu { makeContextMenu() }
    func moveOrCopy(_ urls: [URL], into target: URL, move: Bool) { transfer(urls, into: target, move: move) }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        configureOutline()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        root.addSubview(scrollView)
        root.addSubview(emptyState)
        root.addSubview(filterPill)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
            filterPill.centerXAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerXAnchor),
            filterPill.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])
        view = root

        sizer.onUpdate = { [weak self] url in self?.folderSizeArrived(url) }
        installActiveView()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: .indexDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gitStatusChanged), name: .gitStatusDidChange, object: nil)
    }

    private func configureOutline() {
        let ov = outlineView
        ov.style = .inset
        ov.rowHeight = 26
        ov.intercellSpacing = NSSize(width: 10, height: 0)
        ov.allowsMultipleSelection = true
        ov.allowsEmptySelection = true
        ov.allowsColumnReordering = true
        ov.allowsColumnResizing = true
        ov.allowsTypeSelect = false
        ov.indentationPerLevel = 16
        ov.autoresizesOutlineColumn = false
        ov.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        ov.focusRingType = .none
        ov.dataSource = self
        ov.delegate = self
        ov.target = self
        ov.doubleAction = #selector(openSelection(_:))
        ov.registerForDraggedTypes([.fileURL])
        ov.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        ov.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        ov.draggingDestinationFeedbackStyle = .regular

        addColumn(.name, "Name", width: 340, min: 160, ascending: true)
        addColumn(.modified, "Date Modified", width: 170, min: 110, ascending: false)
        addColumn(.size, "Size", width: 84, min: 60, ascending: false, alignment: .right)
        addColumn(.kind, "Kind", width: 150, min: 80, ascending: true)
        addColumn(.location, "Where", width: 220, min: 100, ascending: true)
        ov.tableColumn(withIdentifier: .location)?.isHidden = true
        ov.outlineTableColumn = ov.tableColumns.first
        ov.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]

        ov.onType = { [weak self] text in self?.setFilter((self?.filter ?? "") + text) }
        ov.onBackspace = { [weak self] in
            guard let self, !filter.isEmpty else { return false }
            setFilter(String(filter.dropLast()))
            return true
        }
        ov.onEscape = { [weak self] in
            guard let self, !filter.isEmpty else { return false }
            setFilter("")
            return true
        }
        ov.onReturn = { [weak self] in
            guard let self else { return }
            if filter.isEmpty && !Prefs.returnOpens { renameSelection(nil) } else { openSelection(nil) }
        }
        ov.onSpace = { [weak self] in
            guard let self else { return }
            if filter.isEmpty { toggleQuickLook(nil) } else { setFilter(filter + " ") }
        }
        ov.contextMenu = { [weak self] in self?.makeContextMenu() }
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat,
                           ascending: Bool, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = min
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: ascending)
        outlineView.addTableColumn(column)
    }

    // MARK: - Loading

    func load(_ url: URL, select: URL? = nil) {
        let isNewDirectory = url != directory || isShowingResults
        if isShowingResults { leaveResults() }
        directory = url
        if isNewDirectory {
            filter = ""
            filterPill.update(query: "", matches: 0)
            sizer.cancelPending()
            watcher = DirectoryWatcher(url: url) { [weak self] in self?.refresh() }
            gitObservation = GitStatusStore.shared.observe(url)
            pendingSelection = select.map { [$0] } ?? []
            isLoadingFolder = true
            // Most folders load within a frame; a slow one (a network share, a huge folder) clears the old rows and
            // says so instead of leaving the previous folder's files on screen under the new location.
            let loading = generation + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, isLoadingFolder, generation == loading else { return }
                showLoading()
            }
        }
        reload(scrollToTop: isNewDirectory && select == nil)
    }

    private func showLoading() {
        nodes = []
        rows = []
        nodesByPath = [:]
        outlineView.reloadData()
        pushContent()
        emptyState.show(symbol: "hourglass", title: "Loading…")
        delegate?.browserSelectionDidChange(self)
    }

    /// Re-reads the current folder, keeping selection, expanded folders and scroll position.
    @objc func refresh() {
        guard directory != nil, !isShowingResults else { return }
        // FSEvents normally keeps git status current; without it, entries changing is our cue.
        if let observation = gitObservation, !observation.isWatching {
            GitStatusStore.shared.invalidate(root: observation.repository.root)
        }
        if pendingSelection.isEmpty { pendingSelection = selectedURLs }
        reload(scrollToTop: false)
    }

    private func reload(scrollToTop: Bool) {
        guard let url = directory else { return }
        generation += 1
        let gen = generation
        let showHidden = Prefs.showHidden
        Task {
            do {
                let entries = try await DirectoryLoader.load(url, showHidden: showHidden)
                guard gen == generation else { return }
                loadError = nil
                isLoadingFolder = false
                Privacy.markAccessible(url)
                apply(entries, preservingState: !scrollToTop)
                if scrollToTop, outlineView.selectedRow < 0 { self.scrollToTop() }
            } catch {
                guard gen == generation else { return }
                showError(error)
            }
            let capacity = await Self.availableCapacity(of: url)
            guard gen == generation else { return }
            availableCapacity = capacity
            delegate?.browserContentDidChange(self)
        }
    }

    @concurrent
    private nonisolated static func availableCapacity(of url: URL) async -> Int64? {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func apply(_ entries: [FileEntry], preservingState: Bool) {
        let previous = preservingState ? nodesByPath : [:]
        let expanded = preservingState ? nodes.filter { outlineView.isItemExpanded($0) } : []
        nodes = entries.map { entry in
            if let node = previous[Self.key(entry.url)], node.parent == nil {
                node.entry = entry
                return node
            }
            return FileNode(entry: entry)
        }
        sort(&nodes)
        rebuildIndex()
        applyFilter()
        isLoaded = true
        outlineView.reloadData()
        for node in expanded where self.node(for: node.url) === node {
            outlineView.expandItem(node)
            node.isLoadingChildren = false
            loadChildren(of: node)
        }
        select(pendingSelection)
        pendingSelection = []
        if let rename = pendingRename, node(for: rename) != nil {
            pendingRename = nil
            beginRename(rename)
        }
        pushContent(animated: preservingState)
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    private func loadChildren(of node: FileNode) {
        guard !node.isLoadingChildren else { return }
        node.isLoadingChildren = true
        let gen = generation
        let url = node.url
        let showHidden = Prefs.showHidden
        Task {
            let entries = (try? await DirectoryLoader.load(url, showHidden: showHidden)) ?? []
            node.isLoadingChildren = false
            guard gen == generation else { return }
            let old = Dictionary((node.children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            var children = entries.map { entry -> FileNode in
                if let existing = old[entry.url] {
                    existing.entry = entry
                    return existing
                }
                return FileNode(entry: entry, parent: node)
            }
            sort(&children)
            node.children = children
            rebuildIndex()
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private func node(for url: URL) -> FileNode? { nodesByPath[Self.key(url)] }

    private func rebuildIndex() {
        nodesByPath.removeAll(keepingCapacity: true)
        var stack = nodes
        while let node = stack.popLast() {
            if node.groupTitle == nil { nodesByPath[Self.key(node.url)] = node }
            if let children = node.children { stack.append(contentsOf: children) }
        }
    }

    private func showError(_ error: Error) {
        loadError = error
        isLoaded = true
        isLoadingFolder = false
        nodes = []
        rows = []
        nodesByPath = [:]
        outlineView.reloadData()
        // Icons, Columns and Disk Usage keep their own copy of the items: clear it too.
        pushContent()
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    private func updateEmptyState() {
        if let error = loadError as NSError? {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if error.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
                if Privacy.hasFullDiskAccess {
                    // Full Disk Access is on, so this is ordinary file permissions (another user's or the system's).
                    emptyState.show(symbol: "lock", title: "You don’t have permission to see this folder’s contents")
                } else {
                    emptyState.show(
                        symbol: "lock",
                        title: "Strata can’t read this folder",
                        message: "macOS protects this location. Give Strata Full Disk Access to browse it.",
                        button: ("Open Privacy Settings", { NSWorkspace.shared.open(Privacy.settingsURL) }))
                }
            } else if error.code == NSFileReadNoSuchFileError {
                emptyState.show(symbol: "questionmark.folder", title: "This folder no longer exists")
            } else {
                emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn’t open this folder", message: error.localizedDescription)
            }
        } else if isLoaded && rows.isEmpty {
            if isShowingResults && filter.isEmpty {
                emptyState.show(symbol: "magnifyingglass", title: "No results")
            } else if filter.isEmpty {
                emptyState.show(symbol: "folder", title: "Empty Folder")
            } else {
                emptyState.show(symbol: "magnifyingglass", title: "No matches", message: "Nothing here matches “\(filter)”. Press Esc to clear the filter.")
            }
        } else {
            emptyState.isHidden = true
        }
    }

    private func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Results

    /// Shows `entries` (search results or recent files) in place of the folder, keeping their order until a column
    /// header is clicked. `total` is how many matched before the list was capped.
    func showResults(_ entries: [FileEntry], total: Int) {
        enterResults()
        generation += 1
        let selection = selectedURLs
        resultsTotal = total
        resultsSummary = nil
        loadError = nil
        isLoaded = true
        nodes = entries.map { FileNode(entry: $0) }
        if !outlineView.sortDescriptors.isEmpty { sort(&nodes) }
        rebuildIndex()
        applyFilter()
        outlineView.reloadData()
        select(selection, scroll: false)
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    /// Shows groups of files under header rows, all expanded (duplicate sets).
    func showGroups(_ groups: [(title: String, detail: String, entries: [FileEntry])], summary: String) {
        enterResults()
        generation += 1
        resultsTotal = groups.count
        resultsSummary = summary
        loadError = nil
        isLoaded = true
        nodes = groups.compactMap { group in
            guard let first = group.entries.first else { return nil }
            let header = FileNode(entry: first)
            header.groupTitle = group.title
            header.groupDetail = group.detail
            header.children = group.entries.map { FileNode(entry: $0, parent: header) }
            return header
        }
        rebuildIndex()
        applyFilter()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    /// Replaces the list with a message while results are being computed.
    func showMessage(symbol: String, title: String, message: String = "") {
        enterResults()
        generation += 1
        nodes = []
        rows = []
        nodesByPath = [:]
        resultsSummary = ""
        outlineView.reloadData()
        emptyState.show(symbol: symbol, title: title, message: message)
        delegate?.browserContentDidChange(self)
    }

    private func enterResults() {
        isLoadingFolder = false
        if !isShowingResults {
            isShowingResults = true
            installActiveView()
            folderSortDescriptors = outlineView.sortDescriptors
            outlineView.sortDescriptors = []
            outlineView.tableColumn(withIdentifier: .location)?.isHidden = false
            filter = ""
            filterPill.update(query: "", matches: 0)
        }
    }

    private func leaveResults() {
        isShowingResults = false
        installActiveView()
        outlineView.tableColumn(withIdentifier: .location)?.isHidden = true
        outlineView.sortDescriptors = folderSortDescriptors.isEmpty
            ? [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)] : folderSortDescriptors
    }

    // MARK: - Sorting and filtering

    private func sort(_ list: inout [FileNode]) {
        list.sort { ordered($0.entry, $1.entry) }
        for node in list { if var children = node.children { sort(&children); node.children = children } }
    }

    /// The current sort order (column, direction, folders on top), shared with the column view.
    func ordered(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if Prefs.foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
        let result: ComparisonResult
        switch sortKey {
        case .name: result = a.name.localizedStandardCompare(b.name)
        case .modified: result = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .size: result = compare(sizeValue(a), sizeValue(b))
        case .kind: result = a.kind.localizedStandardCompare(b.kind)
        }
        if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    private func sizeValue(_ entry: FileEntry) -> Int64 {
        entry.isDirectory ? (folderSize(entry.url)?.bytes ?? -1) : (entry.size ?? 0)
    }

    func setFilter(_ text: String) {
        guard text != filter else { return }
        filter = text
        applyFilter()
        outlineView.reloadData()
        if !rows.isEmpty {
            outlineView.selectRowIndexes([0], byExtendingSelection: false)
            outlineView.scrollRowToVisible(0)
        }
        filterPill.update(query: text, matches: rows.count)
        pushContent()
        if let first = rows.first, activeView != nil { activeView?.select([first.url], scroll: true) }
        updateEmptyState()
        delegate?.browserContentDidChange(self)
    }

    private func applyFilter() {
        guard !filter.isEmpty else {
            for node in nodes { node.matchIndices = [] }
            rows = nodes
            return
        }
        var scored: [(node: FileNode, score: Int)] = []
        for node in nodes {
            if let match = Fuzzy.match(filter, node.entry.name) {
                node.matchIndices = match.indices
                scored.append((node, match.score))
            } else {
                node.matchIndices = []
            }
        }
        rows = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score
                : $0.node.entry.name.localizedStandardCompare($1.node.entry.name) == .orderedAscending
        }.map(\.node)
    }

    /// Re-sorts after folder sizes arrive while sorting by size, animating rows into place.
    private func scheduleResort() {
        resortWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.resortAnimated() } }
        resortWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func resortAnimated() {
        guard filter.isEmpty else { return }
        var sorted = nodes
        sort(&sorted)
        guard sorted.map(ObjectIdentifier.init) != rows.map(ObjectIdentifier.init) else { return }
        var working = rows
        outlineView.beginUpdates()
        for (target, node) in sorted.enumerated() {
            guard let current = working.firstIndex(where: { $0 === node }), current != target else { continue }
            outlineView.moveItem(at: current, inParent: nil, to: target, inParent: nil)
            working.remove(at: current)
            working.insert(node, at: target)
        }
        nodes = sorted
        rows = sorted
        outlineView.endUpdates()
        if mode == .grid || mode == .columns { pushContent() }
    }

    private func folderSizeArrived(_ url: URL) {
        if url == directory { delegate?.browserContentDidChange(self) }
        guard let node = node(for: url) else { return }
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: .size)
        if row >= 0, column >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [column]) }
        treemapController?.updateSize(folderSize(url)?.bytes, for: url)
        if mode == .grid { gridController?.reloadItems([url]) }
        if sortKey == .size { scheduleResort() }
        if row >= 0, outlineView.selectedRowIndexes.contains(row) { delegate?.browserContentDidChange(self) }
    }

    // MARK: - Selection

    private var selectedNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }
    }

    /// The selection in whichever presentation is active.
    var selectedEntries: [FileEntry] { activeView?.selectedEntries ?? selectedNodes.map(\.entry) }
    var selectedURLs: [URL] { selectedEntries.map(\.url) }
    var itemCount: Int { nodes.count }
    var topLevelEntries: [FileEntry] { nodes.map(\.entry) }
    var visibleCount: Int { rows.count }

    /// Cached size of a folder; with `request`, starts measuring it when unknown and allowed.
    func folderSize(_ url: URL, request: Bool = false) -> FolderSize? {
        if let size = FileIndex.shared.folderSize(url) { return size }
        if let size = sizer.cached(url) { return size }
        if request, !Privacy.measuringWouldPrompt(url, browsing: directory ?? url) { sizer.request(url) }
        return nil
    }

    /// Re-measures folders after Full Disk Access is granted.
    func privacyChanged() {
        refresh()
    }

    func select(_ urls: [URL], scroll: Bool = true) {
        if let activeView {
            activeView.select(urls, scroll: scroll)
            return
        }
        let indexes = IndexSet(urls.compactMap { node(for: $0) }.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll, let first = indexes.first { outlineView.scrollRowToVisible(first) }
    }

    var statusText: String {
        guard isLoaded, loadError == nil else { return "" }
        var parts: [String]
        if let resultsSummary, isShowingResults {
            parts = resultsSummary.isEmpty ? [] : [resultsSummary]
        } else if isShowingResults {
            let shown = filter.isEmpty ? nodes.count : rows.count
            parts = [resultsTotal > shown ? "Top \(shown.formatted()) of \(Format.count(resultsTotal, "result", "results"))"
                                          : Format.count(shown, "result", "results")]
        } else {
            parts = [filter.isEmpty
                ? Format.count(nodes.count, "item", "items")
                : "\(rows.count.formatted()) of \(Format.count(nodes.count, "item", "items"))"]
        }
        let selected = selectedEntries
        if !selected.isEmpty {
            let sizes = selected.map { $0.isDirectory ? folderSize($0.url)?.bytes : $0.size }
            let known = sizes.compactMap { $0 }
            var text = "\(selected.count.formatted()) selected"
            if known.count == sizes.count { text += ", \(Format.bytes(known.reduce(0, +)))" }
            parts.append(text)
        }
        if let availableCapacity, !isShowingResults { parts.append("\(Format.bytes(availableCapacity)) available") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Actions

    @objc func openSelection(_ sender: Any?) {
        if sender as? NSOutlineView === outlineView, outlineView.clickedRow < 0 { return }
        open(selectedEntries)
    }

    private func open(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        for entry in entries where !entry.isFolder {
            NSWorkspace.shared.open(entry.url)
        }
        if let folder = entries.first(where: \.isFolder) {
            delegate?.browser(self, navigateTo: folder.url)
        }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        // Keep the cursor where it was: select the row that slides into the first removed one's place.
        let removed = Set(urls.map(Self.key))
        let survivors = rows.filter { !removed.contains(Self.key($0.url)) }
        if let first = rows.firstIndex(where: { removed.contains(Self.key($0.url)) }), !survivors.isEmpty {
            pendingSelection = [survivors[min(first, survivors.count - 1)].url]
        }
        perform { try FileOps.trash(urls, undo: self.undoManager) }
        refresh()
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        // Copying onto itself with "keep both" gives Finder's "name copy" naming, with progress for big items.
        let job = TransferQueue.shared.enqueue(moves: urls.map { TransferMove(from: $0, to: $0) }, mode: .copy,
                                               undo: undoManager, conflicts: .keepBoth)
        job.onFinish = { [weak self] job in
            guard let self else { return }
            if !job.createdItems.isEmpty { pendingSelection = job.createdItems }
            refresh()
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard let directory = targetDirectory else { return }
        perform {
            let url = try FileOps.newFolder(in: directory, undo: self.undoManager)
            if self.mode == .columns, directory != self.directory {
                // A deeper column picks the folder up from its own watcher; rename once it's shown.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { _ = self.activeView?.beginRename(url) }
                return
            }
            self.pendingSelection = [url]
            self.pendingRename = url
            self.refresh()
        }
    }

    @objc func renameSelection(_ sender: Any?) {
        guard selectedEntries.count == 1, let url = selectedURLs.first else { return }
        beginRename(url)
    }

    /// View ▸ Sort By: the same orders as the list's column headers, for every view. Tags follow `sortMenuKeys`.
    static let sortMenuKeys: [(key: NSUserInterfaceItemIdentifier, ascending: Bool)] = [
        (.name, true), (.kind, true), (.modified, false), (.size, false),
    ]

    @objc func sortBy(_ sender: NSMenuItem) {
        guard Self.sortMenuKeys.indices.contains(sender.tag) else { return }
        let choice = Self.sortMenuKeys[sender.tag]
        // Like Finder, picking the current order again keeps its direction.
        if outlineView.sortDescriptors.first?.key == choice.key.rawValue { return }
        outlineView.sortDescriptors = [NSSortDescriptor(key: choice.key.rawValue, ascending: choice.ascending)]
    }

    @objc func copy(_ sender: Any?) {
        Clipboard.write(selectedURLs, cut: false)
    }

    @objc func cut(_ sender: Any?) {
        Clipboard.write(selectedURLs, cut: true)
    }

    @objc func paste(_ sender: Any?) {
        pasteItems(forceMove: false)
    }

    @objc func pasteAndMove(_ sender: Any?) {
        pasteItems(forceMove: true)
    }

    private func pasteItems(forceMove: Bool) {
        guard let directory = targetDirectory else { return }
        let (urls, isCut) = Clipboard.read()
        guard !urls.isEmpty else { return }
        transfer(urls, into: directory, move: forceMove || isCut)
        if isCut { Clipboard.clearCut() }
    }

    @objc func copyPath(_ sender: Any?) {
        let urls = selectedURLs.isEmpty ? [directory].compactMap { $0 } : selectedURLs
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc func addToShelf(_ sender: Any?) {
        ShelfPanel.shared.add(selectedURLs)
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        let target = selectedURLs.first?.deletingLastPathComponent() ?? directory
        guard let target else { return }
        NSWorkspace.shared.open([target], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openInTerminal(_ sender: Any?) {
        let selected = selectedEntries
        let folder = selected.count == 1 && selected[0].isFolder ? selected[0].url : targetDirectory
        guard let folder else { return }
        guard let terminal = Prefs.terminalURL else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        Prefs.showHidden.toggle()
    }

    @objc func toggleFoldersFirst(_ sender: Any?) {
        Prefs.foldersFirst.toggle()
    }

    @objc func reloadFolder(_ sender: Any?) {
        for node in nodes where node.entry.isDirectory { FolderSizer.invalidate(node.url) }
        if let repository = gitObservation?.repository { GitStatusStore.shared.refresh(repository, force: true) }
        refresh()
    }

    @objc private func prefsChanged() {
        sort(&nodes)
        refresh()
    }

    /// Index totals moved: refresh visible sizes (and the order, when sorting by size).
    @objc private func indexChanged() {
        let column = outlineView.column(withIdentifier: .size)
        let visible = outlineView.rows(in: outlineView.visibleRect)
        if column >= 0, visible.length > 0 {
            outlineView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [column])
        }
        if sortKey == .size, !outlineView.sortDescriptors.isEmpty { scheduleResort() }
        if effectiveMode == .treemap { pushContent(animated: true) }
        if effectiveMode == .grid { gridController?.refreshVisibleItems() }
        delegate?.browserContentDidChange(self)
    }

    /// Status arrived or changed: redraw visible rows (badges and ignored-dimming).
    @objc private func gitStatusChanged(_ notification: Notification) {
        guard let root = notification.userInfo?["root"] as? URL, let directory,
              directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return }
        clipboardChanged()
    }

    @objc private func clipboardChanged() {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                               columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
    }

    /// Copies and moves go through the transfer queue: progress, pause, conflicts asked up front, undo.
    private func transfer(_ urls: [URL], into target: URL, move: Bool) {
        let job = TransferQueue.shared.enqueue(urls, to: target, mode: move ? .move : .copy,
                                               undo: undoManager, conflicts: .sheet(for: view.window))
        job.onFinish = { [weak self] job in
            guard let self else { return }
            if target.standardizedFileURL == directory?.standardizedFileURL, !job.createdItems.isEmpty {
                pendingSelection = job.createdItems
            }
            refresh()
        }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { presentFileError(error) }
    }

    private func performAsync(_ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() } catch { presentFileError(error) }
        }
    }

    private func presentFileError(_ error: Error) {
        guard let window = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
        refresh()
    }

    // MARK: - Rename

    func renameItem(_ url: URL, to newName: String) {
        guard !newName.isEmpty, !newName.contains("/") else { return }
        performAsync { [self] in
            let renamed = try await FileOps.rename(url, to: newName, undo: undoManager)
            pendingSelection = [renamed]
            refresh()
        }
    }

    private func beginRename(_ url: URL) {
        if let activeView {
            activeView.beginRename(url)
            return
        }
        guard let node = node(for: url) else { return }
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: .name)
        guard row >= 0, column >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renaming = node
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.stringValue = node.entry.name
        field.delegate = self
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let name = node.entry.name as NSString
            let base = node.entry.isFolder ? name : name.deletingPathExtension as NSString
            editor.selectedRange = NSRange(location: 0, length: base.length)
        }
    }

    // MARK: - Quick Look

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // Quick Look calls these on the main thread; the SDK just doesn't annotate them.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let selected = selectedEntries
        func add(_ title: String, _ action: Selector, _ symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if selected.isEmpty {
            add("New Folder", #selector(newFolder(_:)), "folder.badge.plus")
            if Clipboard.hasFiles { add("Paste", #selector(paste(_:)), "doc.on.clipboard") }
            menu.addItem(.separator())
            add("Open in Terminal", #selector(openInTerminal(_:)), "terminal")
            add("Copy Path", #selector(copyPath(_:)), "link")
            add("Show in Finder", #selector(showInFinder(_:)), "macwindow")
            menu.addItem(.separator())
            add(Prefs.showHidden ? "Hide Hidden Files" : "Show Hidden Files", #selector(toggleHiddenFiles(_:)), "eye")
            return menu
        }
        add("Open", #selector(openSelection(_:)), "arrow.up.forward.app")
        if let first = selected.first, !first.isFolder {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
            if !apps.isEmpty {
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first.url)
                let submenu = NSMenu()
                for app in apps.prefix(24) {
                    var title = FileManager.default.displayName(atPath: app.path)
                    if app == defaultApp { title += " (default)" }
                    let item = NSMenuItem(title: title, action: #selector(openWithApplication(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = app
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    submenu.addItem(item)
                }
                let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWith.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
                openWith.submenu = submenu
                menu.addItem(openWith)
            }
        }
        add("Quick Look", #selector(toggleQuickLook(_:)), "eye")
        menu.addItem(.separator())
        if selected.count == 1 { add("Rename", #selector(renameSelection(_:)), "pencil") }
        add("Duplicate", #selector(duplicate(_:)), "plus.square.on.square")
        add("Move to Trash", #selector(moveToTrash(_:)), "trash")
        menu.addItem(.separator())
        add("Copy", #selector(copy(_:)), "doc.on.doc")
        add("Cut", #selector(cut(_:)), "scissors")
        add("Copy Path", #selector(copyPath(_:)), "link")
        add("Add to Shelf", #selector(addToShelf(_:)), "tray.and.arrow.down")
        menu.addItem(.separator())
        add("Open in Terminal", #selector(openInTerminal(_:)), "terminal")
        add("Show in Finder", #selector(showInFinder(_:)), "macwindow")
        return menu
    }
}

// MARK: - Data source and delegate

extension BrowserViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return rows.count }
        guard let children = node.children else {
            loadChildren(of: node)
            return 0
        }
        return children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return rows[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.groupTitle != nil { return true }
        guard filter.isEmpty, !isShowingResults else { return false }
        return node.entry.isFolder
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        if let title = node.groupTitle {
            let cell = outlineView.makeView(withIdentifier: .groupCell, owner: nil) as? GroupHeaderCellView ?? {
                let cell = GroupHeaderCellView()
                cell.identifier = .groupCell
                return cell
            }()
            cell.configure(title: title, detail: node.groupDetail ?? "", icon: IconCache.shared.icon(for: node.entry))
            return cell
        }
        guard let column = tableColumn else { return nil }
        let entry = node.entry
        let git = GitStatusStore.shared
        let dimmed = entry.isHidden || Clipboard.isCut(entry.url) || git.isIgnored(entry.url)
        if column.identifier == .name {
            let cell = outlineView.makeView(withIdentifier: .nameCell, owner: nil) as? NameCellView ?? {
                let cell = NameCellView()
                cell.identifier = .nameCell
                return cell
            }()
            cell.configure(name: entry.name, icon: IconCache.shared.icon(for: entry), matches: node.matchIndices, dimmed: dimmed,
                           git: git.badge(for: entry.url, isDirectory: entry.isDirectory))
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .textCell, owner: nil) as? TextCellView ?? {
            let cell = TextCellView()
            cell.identifier = .textCell
            return cell
        }()
        switch column.identifier {
        case .modified: cell.configure(Format.date(entry.modified), alignment: .left, dimmed: dimmed)
        case .size: cell.configure(sizeText(node), alignment: .right, dimmed: dimmed)
        case .location: cell.configure(Format.tildePath(entry.url.deletingLastPathComponent()), alignment: .left, dimmed: dimmed)
        default: cell.configure(entry.kind, alignment: .left, dimmed: dimmed)
        }
        return cell
    }

    private func sizeText(_ node: FileNode) -> String {
        guard node.entry.isDirectory else { return Format.bytes(node.entry.size ?? 0) }
        if let size = FileIndex.shared.folderSize(node.url) ?? sizer.cached(node.url) { return Format.bytes(size.bytes) }
        guard canMeasure(node.entry) else { return "—" }
        sizer.request(node.url)
        return "…"
    }

    /// Symlinks and volumes aren't walked, and neither are guarded folders that would trigger a consent prompt.
    func canMeasure(_ entry: FileEntry) -> Bool {
        guard entry.isDirectory, !entry.isSymlink, !entry.isVolume, let directory else { return false }
        if FileIndex.shared.folderSize(entry.url) != nil { return true }
        return !Privacy.measuringWouldPrompt(entry.url, browsing: directory)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FileNode)?.groupTitle != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileNode)?.groupTitle == nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        delegate?.browserSelectionDidChange(self)
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = SortKey(rawValue: descriptor.key ?? "") else { return }
        sortKey = key
        ascending = descriptor.ascending
        let selection = selectedURLs
        sort(&nodes)
        applyFilter()
        outlineView.reloadData()
        pushContent()
        select(selection, scroll: false)
    }

    // Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node.groupTitle == nil else { return nil }
        return node.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let urls = draggedURLs(info), !urls.isEmpty, let target = retargetDrop(outlineView, item) else { return [] }
        let targetPath = target.standardizedFileURL.path
        if urls.contains(where: { targetPath == $0.path || targetPath.hasPrefix($0.path + "/") }) { return [] }
        let operation = dragOperation(urls, target, info)
        if operation == .move, urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == targetPath }) {
            return []
        }
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let urls = draggedURLs(info), let target = (item as? FileNode)?.url ?? directory else { return false }
        let operation = dragOperation(urls, target, info)
        guard !operation.isEmpty else { return false }
        transfer(urls, into: target, move: operation == .move)
        return true
    }

    private func retargetDrop(_ outlineView: NSOutlineView, _ item: Any?) -> URL? {
        if let node = item as? FileNode {
            if node.entry.isFolder {
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return node.url
            }
            if let parent = node.parent {
                outlineView.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return parent.url
            }
        }
        guard !isShowingResults else { return nil }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return directory
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    /// Finder semantics: move within a volume, copy across volumes, Option forces a copy.
    private func dragOperation(_ urls: [URL], _ target: URL, _ info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        let wantsCopy = NSEvent.modifierFlags.contains(.option) || !Self.sameVolume(urls[0], target)
        if wantsCopy || !mask.contains(.move) { return mask.contains(.copy) ? .copy : mask.contains(.generic) ? .copy : [] }
        return .move
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let va, let vb else { return false }
        return va.isEqual(vb)
    }
}

// MARK: - Rename editing

extension BrowserViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renaming else { return }
        renaming = nil
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [outlineView.column(withIdentifier: .name)]) }
        view.window?.makeFirstResponder(outlineView)
        guard !newName.isEmpty, newName != node.entry.name else { return }
        renameItem(node.url, to: newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let node = renaming {
            (control as? NSTextField)?.stringValue = node.entry.name
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }
}

// MARK: - Menu validation

extension BrowserViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let fileCommands: [Selector] = [
            #selector(openSelection(_:)), #selector(moveToTrash(_:)), #selector(duplicate(_:)), #selector(newFolder(_:)),
            #selector(renameSelection(_:)), #selector(toggleQuickLook(_:)), #selector(pasteAndMove(_:)),
            #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)),
        ]
        // While a name is being edited, ⌘⌫, ⌘D and ⇧⌘N belong to the text, not the file. While another folder loads,
        // the rows on screen are the previous folder's.
        if let action = item.action, fileCommands.contains(action),
           view.window?.firstResponder is NSText || isLoadingFolder {
            return false
        }
        let selectionCount = selectedEntries.count
        let hasSelection = selectionCount > 0
        switch item.action {
        case #selector(openSelection(_:)), #selector(moveToTrash(_:)), #selector(duplicate(_:)),
             #selector(copy(_:)), #selector(cut(_:)), #selector(toggleQuickLook(_:)):
            return hasSelection
        case #selector(renameSelection(_:)):
            return selectionCount == 1 && effectiveMode != .treemap
        case #selector(paste(_:)), #selector(pasteAndMove(_:)):
            return directory != nil && !isShowingResults && Clipboard.hasFiles
        case #selector(newFolder(_:)):
            // Disk Usage can't show an empty folder, so a new one would seem to vanish.
            return directory != nil && !isShowingResults && loadError == nil && effectiveMode != .treemap
        case #selector(toggleHiddenFiles(_:)):
            item.state = Prefs.showHidden ? .on : .off
            return true
        case #selector(biggerIcons(_:)), #selector(smallerIcons(_:)):
            return effectiveMode == .grid
        case #selector(toggleFoldersFirst(_:)):
            item.state = Prefs.foldersFirst ? .on : .off
            return true
        case #selector(sortBy(_:)):
            let key = Self.sortMenuKeys.indices.contains(item.tag) ? Self.sortMenuKeys[item.tag].key.rawValue : ""
            item.state = outlineView.sortDescriptors.first?.key == key ? .on : .off
            return !isShowingResults
        default:
            return true
        }
    }
}

// MARK: - Quick Look panel

extension BrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        selectedURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        focusView.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = (item as? NSURL) as URL? else { return .zero }
        if let activeView { return activeView.screenRect(for: url) ?? .zero }
        guard let node = node(for: url), let window = view.window else { return .zero }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return .zero }
        let cell = outlineView.frameOfCell(atColumn: outlineView.column(withIdentifier: .name), row: row)
        let iconRect = NSRect(x: cell.minX + 1, y: cell.midY - 9, width: 18, height: 18)
        guard outlineView.visibleRect.intersects(iconRect) else { return .zero }
        return window.convertToScreen(outlineView.convert(iconRect, to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = (item as? NSURL) as URL? else { return nil }
        if let entry = selectedEntries.first(where: { Self.key($0.url) == Self.key(url) }) { return IconCache.shared.icon(for: entry) }
        guard let node = node(for: url) else { return nil }
        return IconCache.shared.icon(for: node.entry)
    }
}
