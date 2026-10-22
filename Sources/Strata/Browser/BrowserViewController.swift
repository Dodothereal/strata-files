import AppKit
import Quartz

protocol BrowserViewControllerDelegate: AnyObject {
    func browser(_ browser: BrowserViewController, navigateTo url: URL)
    func browserSelectionDidChange(_ browser: BrowserViewController)
    func browserContentDidChange(_ browser: BrowserViewController)
    /// Column view moved deeper without changing the browser's folder.
    func browser(_ browser: BrowserViewController, columnLocationChanged url: URL)
    /// A drag rested on `url` long enough to spring it open; `drag` is the drag's sequence number.
    func browser(_ browser: BrowserViewController, springLoadTo url: URL, drag: Int)
    /// An archive opened as a folder is ready: show its copy (if this pane is still the one you're using).
    func browser(_ browser: BrowserViewController, showArchiveCopy folder: URL)
    /// An archive is being unpacked to browse (nil when done); `stop` cancels it.
    func browser(_ browser: BrowserViewController, openingArchive archive: URL?, stop: (() -> Void)?)
    func browser(_ browser: BrowserViewController, reveal url: URL)
}

private extension NSUserInterfaceItemIdentifier {
    static let name = Self("name")
    static let modified = Self("modified")
    static let created = Self("created")
    static let added = Self("added")
    static let dimensions = Self("dimensions")
    static let width = Self("width")
    static let height = Self("height")
    static let duration = Self("duration")
    static let fileExtension = Self("extension")
    static let size = Self("size")
    static let kind = Self("kind")
    static let location = Self("location")
    static let nameCell = Self("NameCell")
    static let textCell = Self("TextCell")
    static let groupCell = Self("GroupCell")
}

final class BrowserViewController: NSViewController {
    let services: BrowserServices
    var preferences: Prefs { services.preferences }
    let loading: BrowserLoading
    var directoryReads: DirectoryReadSession { loading.reads }

    init(services: BrowserServices = .shared) {
        self.services = services
        mode = BrowserViewMode(rawValue: services.preferences.viewMode) ?? .list
        loading = BrowserLoading(reader: services.directories, capacity: services.availableCapacity)
        mediaInfo = MediaInfoLoader(copies: services.copies, reader: services.mediaReader)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    weak var delegate: BrowserViewControllerDelegate?
    var applicationFolders = ApplicationsFolders.standard
    var directory: URL? { loading.directory }
    var loadError: Error? { loading.error }
    var isLoaded: Bool { loading.isLoaded }
    /// Tab in any view; the window switches panes in dual-pane mode (true) or lets focus move on (false).
    var onTab: (() -> Bool)?
    /// A different folder is being read; the rows still showing belong to the previous one, so file commands wait.
    var isLoadingFolder: Bool { loading.isLoadingFolder }
    override func viewDidLayout() {
        super.viewDidLayout()
        fitColumnsToWidth()
    }

    /// In a narrow list (a dual-pane side, a small window) Kind, then Date and Where, give up width down to their
    /// minimums before the columns run off the edge; Name keeps the rest.
    private func fitColumnsToWidth() {
        let visible = outlineView.tableColumns.filter { !$0.isHidden }
        let spacing = outlineView.intercellSpacing.width * CGFloat(visible.count + 1)
        var excess = visible.reduce(0) { $0 + $1.width } + spacing - scrollView.contentView.bounds.width
        guard excess > 1 else { return }
        for id in [NSUserInterfaceItemIdentifier.kind, .location, .fileExtension, .dimensions, .width, .height, .duration, .added, .created, .modified, .name] {
            guard excess > 0, let column = outlineView.tableColumn(withIdentifier: id), !column.isHidden else { continue }
            let give = min(excess, column.width - column.minWidth)
            guard give > 0 else { continue }
            column.width -= give
            excess -= give
        }
    }

    /// Name gets whatever the other visible columns leave (it's the column that absorbs width changes).
    private func fitNameColumn() {
        guard let name = outlineView.tableColumn(withIdentifier: .name) else { return }
        let others = outlineView.tableColumns.filter { $0 !== name && !$0.isHidden }
        let spacing = outlineView.intercellSpacing.width * CGFloat(others.count + 1)
        let available = scrollView.contentView.bounds.width - others.reduce(0) { $0 + $1.width } - spacing
        name.width = max(name.minWidth, available)
    }

    /// Date and Kind widths from before showing results (they make room for "Where").
    private var columnWidthsBeforeResults: [(NSUserInterfaceItemIdentifier, CGFloat)] = []
    var filter: String { listing.filter }
    var availableCapacity: Int64? { loading.availableCapacity }

    let outlineView = FileOutlineView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
    private let filterPill = FilterPill()
    private let sizer = FolderSizer()
    let mediaInfo: MediaInfoLoader

    private let listing = BrowserListing()
    private var nodes: [FileNode] { listing.nodes }
    private var rows: [FileNode] { listing.rows }
    private var generation: Int { directoryReads.generation }
    /// Optional provider reads for the current selection (see `prefetchSelection`).
    var selectionFetch: Task<Void, Never>?
    /// Explicit file fetch before opening or Quick Look; cancelled when the navigation context changes.
    var actionFetch: Task<Void, Never>?
    /// Bumped whenever this pane changes folder, column location or results context.
    private(set) var navigationRevision = 0
    /// The latest asynchronous file or server command started by this pane.
    var commandWork: Task<Void, Never>?

    private var watchers: [DirectoryWatcher] = []
    /// Keeps git status for the shown folder's repository fresh (FSEvents) while this folder is shown.
    private var gitObservation: GitObservation?
    lazy var ordering = BrowserOrdering(
        choice: .init(key: SortKey(rawValue: preferences.sortColumn) ?? .name, ascending: preferences.sortAscending),
        foldersFirst: { [weak self] in self?.preferences.foldersFirst ?? true },
        metadata: .init(folderSize: { [weak self] in self?.folderSize($0)?.bytes },
                        childFolderSizes: { FileIndex.shared.childFolderSizes($0).mapValues(\.bytes) },
                        media: { [weak self] in self?.mediaInfo.cached($0) },
                        requestMedia: { [weak self] in self?.mediaInfo.request($0) }))
    private var updatingSortDescriptor = false
    /// Selected once the folder shows them (after the reload a change brings).
    var pendingSelection: [URL]?
    /// Opens the folder row a drag rests on (only rows still on screen).
    private lazy var springLoader = SpringLoader(view: outlineView, frame: { [weak self] folder in
        guard let self, let node = node(for: folder) else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? outlineView.rect(ofRow: row) : nil
    }, open: { [weak self] folder, drag in
        guard let self, node(for: folder) != nil else { return }
        springLoad(folder, drag: drag)
    })
    /// A drag is over the list: folders don't expand on hover then (they spring open instead).
    private var isDragOver = false
    /// Renamed (inline) once the folder shows it: a new folder.
    var pendingRename: URL?
    private var renaming: FileNode?
    private weak var renamingField: NSTextField?
    /// The folder read again while a name was being edited in place: shown once the edit ends.
    private var deferredApply: (entries: [FileEntry], preservingState: Bool, fromTop: Bool, generation: Int)?
    private var resortWork: DispatchWorkItem?
    private var deferredMetadataOrder = false
    /// Showing search results or Recents instead of a folder's contents.
    var isShowingResults: Bool { ordering.isShowingResults }
    private var resultsTotal = 0
    private var resultsSummary: String?
    /// How the folder is presented. Results (search, Recents, Duplicates) always use the list.
    private(set) var mode: BrowserViewMode
    let presentations = BrowserPresentations()
    var gridController: GridViewController? { presentations.gridController }
    var columnController: ColumnBrowserViewController? { presentations.columnController }
    var treemapController: TreemapViewController? { presentations.treemapController }
    var galleryController: GalleryViewController? { presentations.galleryController }

    func setStoredMode(_ newMode: BrowserViewMode) { mode = newMode }
    var outlineScrollView: NSScrollView { scrollView }
    /// Rows after filtering (what the views show) and all rows of the folder.
    var visibleRows: [FileNode] { rows }
    var allRows: [FileNode] { nodes }
    func openEntries(_ entries: [FileEntry]) { open(entries) }
    func contextMenu() -> NSMenu { makeContextMenu() }
    func moveOrCopy(_ urls: [URL], into target: URL, move: Bool) { transfer(urls, into: target, move: move) }

    isolated deinit {
        selectionFetch?.cancel()
        actionFetch?.cancel()
        resortWork?.cancel()
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        configureOutline()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        ThemeStyle.bind(scrollView, to: .content)
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
        mediaInfo.onUpdate = { [weak self] entry in self?.mediaInfoArrived(entry) }
        installActiveView()
        preferences.notifications.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(appearanceChanged), name: .appearanceChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(listColumnsChanged), name: .listColumnsChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(viewOptionsChanged), name: .viewOptionsChanged, object: nil)
        services.clipboard.notifications.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: .indexDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gitStatusChanged), name: .gitStatusDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged), name: .tagsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(containerFilesFetched(_:)), name: .containerFilesFetched, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(containersChanged), name: .containersChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged), name: .tagsLoaded, object: nil)
        // Cloud badges redraw the same way.
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged), name: .cloudStatusChanged, object: nil)
    }

    private func configureOutline() {
        let ov = outlineView
        ov.style = .inset
        ov.rowHeight = FileViewStyle.listHeight(for: preferences)
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
        ThemeStyle.bind(ov, to: .content)
        ov.dataSource = self
        ov.delegate = self
        ov.target = self
        ov.doubleAction = #selector(openSelection(_:))
        ov.copies = services.copies
        ov.registerForDraggedTypes(FileDrop.types)
        ov.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        ov.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        ov.draggingDestinationFeedbackStyle = .regular

        addColumn(.name, String(localized: "Name"), width: 340, min: 160, ascending: true)
        for column in ListColumn.allCases {
            addColumn(NSUserInterfaceItemIdentifier(column.rawValue), column.title, width: column.preferredWidth,
                      min: column.minWidth, ascending: column.ascending, alignment: column.alignment)
        }
        addColumn(.location, String(localized: "Where"), width: 220, min: 100, ascending: true)
        ov.tableColumn(withIdentifier: .location)?.isHidden = true
        ov.outlineTableColumn = ov.tableColumns.first
        for column in ov.tableColumns {
            ThemeStyle.bind(column)
        }
        // Right-click the column titles to show or hide a column (Name always shows; Where comes with results).
        let columnsMenu = NSMenu()
        for id in Self.optionalColumns {
            guard let column = ov.tableColumn(withIdentifier: id) else { continue }
            let item = NSMenuItem(title: column.title, action: #selector(toggleListColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            columnsMenu.addItem(item)
        }
        ov.headerView?.menu = columnsMenu
        applyColumnVisibility(fitName: false)
        syncSortDescriptor()

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
            if filter.isEmpty && !preferences.returnOpens { renameSelection(nil) } else { openSelection(nil) }
        }
        ov.onNameClick = { [weak self] row in
            guard let self, let node = outlineView.item(atRow: row) as? FileNode, node.groupTitle == nil else { return }
            renameClicked(node.url)
        }
        ov.onSpace = { [weak self] in
            guard let self else { return }
            if filter.isEmpty { toggleQuickLook(nil) } else { setFilter(filter + " ") }
        }
        ov.contextMenu = { [weak self] in self?.makeContextMenu() }
        ov.onDragEnd = { [weak self] in
            self?.springLoader.cancel()
            self?.isDragOver = false
        }
    }

    /// The list columns that can be shown or hidden, in the order of the menu on their titles.
    private static var optionalColumns: [NSUserInterfaceItemIdentifier] { ListColumn.allCases.map { .init($0.rawValue) } }

    @objc private func toggleListColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preferences.hiddenListColumns.formSymmetricDifference([id])
    }

    @objc private func listColumnsChanged() { applyColumnVisibility(fitName: true) }

    /// Shows the columns you haven't hidden (and ticks them in the menu on the titles); Name takes up the difference
    /// (before the list is laid out, the window's first layout does that).
    private func applyColumnVisibility(fitName: Bool) {
        let hidden = preferences.hiddenListColumns
        for id in Self.optionalColumns {
            outlineView.tableColumn(withIdentifier: id)?.isHidden = hidden.contains(id.rawValue)
        }
        for item in outlineView.headerView?.menu?.items ?? [] {
            item.state = (item.representedObject as? String).map { hidden.contains($0) ? .off : .on } ?? .off
        }
        if fitName { fitNameColumn() }
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
        // Tags may have changed elsewhere (Finder) since they were last read here.
        TagStore.shared.invalidate(url)
        let isNewDirectory = url != directory || isShowingResults
        if isShowingResults { leaveResults() }
        loading.navigate(to: url, newFolder: isNewDirectory)
        if isNewDirectory {
            cancelPendingActions()
            deferredApply = nil
            listing.setFilter("")
            filterPill.update(query: "", matches: 0)
            sizer.cancelPending()
            mediaInfo.cancelPending()
            watchers = applicationFolders.directories(for: FileEntry.openedFolder(url)).compactMap { folder in
                DirectoryWatcher(url: folder) { [weak self] in self?.refresh() }
            }
            gitObservation = GitStatusStore.shared.observe(url)
            pendingSelection = select.map { [$0] } ?? []
        }
        // Revealing an item in the folder already showing selects it too.
        if !isNewDirectory, let select { pendingSelection = [select] }
        reload(scrollToTop: isNewDirectory && select == nil)
        // Keep the old rows briefly for fast reads; slow folders show a native loading state.
        if isNewDirectory {
            let loading = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, isLoadingFolder, generation == loading else { return }
                showLoading()
            }
        }
    }

    private func showLoading() {
        listing.clear()
        outlineView.reloadData()
        scrollToTop()
        pushContent()
        emptyState.show(symbol: "hourglass", title: String(localized: "Loading…"))
        delegate?.browserSelectionDidChange(self)
    }

    /// Re-reads the current folder, keeping selection, expanded folders and scroll position.
    @objc func refresh() { refresh(invalidateCopy: false) }

    private func refresh(invalidateCopy: Bool) {
        guard directory != nil, !isShowingResults else { return }
        TagStore.shared.invalidate(directory)
        // FSEvents normally keeps git status current; without it, entries changing is our cue.
        if let observation = gitObservation, !observation.isWatching {
            GitStatusStore.shared.invalidate(root: observation.repository.root)
        }
        reload(scrollToTop: false, invalidateCopy: invalidateCopy)
    }

    private func reload(scrollToTop: Bool, invalidateCopy: Bool = false) {
        guard let url = directory else { return }
        loading.reload(showHidden: preferences.showHidden, applications: applicationFolders, scrollToTop: scrollToTop,
                       invalidateCopy: invalidateCopy) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let delivery):
                TagStore.shared.load(delivery.entries, in: url)
                CloudStore.shared.load(delivery.entries.map(\.url), in: url)
                Privacy.markAccessible(url)
                apply(delivery.entries, preservingState: !delivery.fromTop, fromTop: delivery.fromTop)
            case .failure:
                showLoadError()
            }
        } capacityChanged: { [weak self] in
            guard let self else { return }
            delegate?.browserContentDidChange(self)
        }
    }

    /// Shows `entries`. `fromTop`: a folder just opened, shown from its top before anything it selects is scrolled to.
    private func apply(_ entries: [FileEntry], preservingState: Bool, fromTop: Bool = false) {
        // Reloading the list would end a rename in progress, half typed.
        if isRenamingInPlace {
            deferredApply = (entries, preservingState, fromTop, generation)
            return
        }
        deferredApply = nil
        // A refresh may wait on a provider or native editing. Preserve the latest selection, not its starting one.
        let selection = pendingSelection ?? (preservingState ? selectedURLs : [])
        let expanded = preservingState ? nodes.filter { outlineView.isItemExpanded($0) } : []
        listing.replace(entries, preservingNodes: preservingState, sort: sort)
        loading.applied()
        outlineView.reloadData()
        if fromTop { scrollToTop() }
        for node in expanded where self.node(for: node.url) === node {
            outlineView.expandItem(node)
            loadChildren(of: node)
        }
        // Icons, columns and disk usage get the new rows first: selecting or renaming before that looked in the
        // previous folder's items, so a revealed file or a new folder came up unselected outside the list.
        pushContent(animated: preservingState)
        select(selection)
        pendingSelection = nil
        if let rename = pendingRename, node(for: rename) != nil {
            pendingRename = nil
            beginRename(rename)
        }
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    private func loadChildren(of node: FileNode) {
        loading.loadChildren(of: node, showHidden: preferences.showHidden, applications: applicationFolders) { [weak self, weak node] entries in
            guard let self, let node, self.node(for: node.url) === node else { return }
            TagStore.shared.load(entries, in: node.url)
            CloudStore.shared.load(entries.map(\.url), in: node.url)
            listing.replaceChildren(of: node, with: entries, sort: sort)
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    static func key(_ url: URL) -> String { BrowserListing.key(url) }

    func node(for url: URL) -> FileNode? { listing.node(for: url) }

    /// The URL a row of this folder uses for `url`. Icons, columns and disk usage match paths exactly, and a listing
    /// reached through a symlink doesn't spell them like the folder does ("/tmp/x" lists "/private/tmp/x/a").
    private func rowURL(_ url: URL) -> URL { node(for: url)?.url ?? url }

    private func showLoadError() {
        cancelPendingActions()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        deferredApply = nil
        listing.clear()
        outlineView.reloadData()
        // Icons, Columns, Gallery and Disk Usage keep their own copy of the items: clear it too.
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
                    emptyState.show(symbol: "lock", title: String(localized: "You don’t have permission to see this folder’s contents"))
                } else {
                    emptyState.show(
                        symbol: "lock",
                        title: String(localized: "Strata can’t read this folder"),
                        message: String(localized: "macOS protects this location. Give Strata Full Disk Access to browse it."),
                        button: (String(localized: "Open Privacy Settings"), { NSWorkspace.shared.open(Privacy.settingsURL) }))
                }
            } else if error.code == NSFileReadNoSuchFileError {
                emptyState.show(symbol: "questionmark.folder", title: String(localized: "This folder no longer exists"))
            } else {
                emptyState.show(symbol: "exclamationmark.triangle", title: String(localized: "Couldn’t open this folder"), message: error.localizedDescription)
            }
        } else if isLoaded && rows.isEmpty {
            if isShowingResults && filter.isEmpty {
                emptyState.show(symbol: "magnifyingglass", title: String(localized: "No Results"))
            } else if filter.isEmpty {
                emptyState.show(symbol: "folder", title: String(localized: "Empty Folder", comment: "Shown in place of the files of a folder that has none"))
            } else {
                emptyState.show(symbol: "magnifyingglass", title: String(localized: "No Matches"),
                                message: String(localized: "Nothing here matches “\(filter)”. Press Esc to clear the filter."))
            }
        } else {
            emptyState.isHidden = true
        }
    }

    private func scrollToTop() {
        // The rows just changed: size the list to them first, so nothing pulls the old offset back.
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Results

    /// Shows `entries` (search results or recent files) in place of the folder, keeping their order until a column
    /// header is clicked. `total` is how many matched before the list was capped.
    func showResults(_ entries: [FileEntry], total: Int) {
        // A search refreshed because the index changed nearly always finds the same files: the list, its selection
        // and the Inspector stay as they are, and only rows whose size or date moved are redrawn.
        if isShowingResults, pendingSelection == nil, resultsSummary == nil, loadError == nil, updateResultsInPlace(entries) {
            localizeResultNames()
            if resultsTotal != total {
                resultsTotal = total
                delegate?.browserContentDidChange(self)
            }
            return
        }
        // Read before switching to the list: in other views the list's own selection is stale and could point at a file
        // nobody picked.
        let selection = pendingSelection ?? selectedURLs
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        resultsTotal = total
        resultsSummary = nil
        listing.replace(entries, preservingNodes: false, sort: sort)
        localizeResultNames()
        outlineView.reloadData()
        select(selection, scroll: false)
        pendingSelection = nil
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    /// When `entries` are the files already listed (in any order: a clicked column header sorts them), takes their new
    /// sizes and dates and returns true. Otherwise changes nothing and returns false.
    private func updateResultsInPlace(_ entries: [FileEntry]) -> Bool {
        guard let changed = listing.updateResults(entries, sorted: ordering.choice != nil) else { return false }
        guard !changed.isEmpty else { return true }
        var rowsToReload = IndexSet()
        for node in changed {
            let row = outlineView.row(forItem: node)
            if row >= 0 { rowsToReload.insert(row) }
        }
        outlineView.reloadData(forRowIndexes: exceptRenaming(rowsToReload), columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
        delegate?.browserContentDidChange(self)
        if changed.contains(where: { outlineView.selectedRowIndexes.contains(outlineView.row(forItem: $0)) }) {
            delegate?.browserSelectionDidChange(self)
        }
        return true
    }

    /// Shows groups of files under header rows, all expanded (duplicate sets).
    func showGroups(_ groups: [(title: String, detail: String, entries: [FileEntry])], summary: String) {
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        resultsTotal = groups.count
        resultsSummary = summary
        listing.replaceGroups(groups)
        localizeResultNames()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let pendingSelection { select(pendingSelection, scroll: true) }
        pendingSelection = nil
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    /// Resolve index hits' visible names without blocking search or changing their file identities.
    private func localizeResultNames() {
        let gen = generation
        let targets = nodes.flatMap { $0.children ?? [$0] }.filter { $0.entry.isDirectory || $0.entry.isPackage }
        guard !targets.isEmpty else { return }
        let entries = targets.map(\.entry)
        Task { [weak self] in
            let localized = await FileEntry.localizedNames(entries)
            guard let self, isShowingResults, gen == generation, !isRenamingInPlace else { return }
            let selection = selectedURLs
            let expanded = nodes.filter { outlineView.isItemExpanded($0) }
            var changed = false
            for (node, pair) in zip(targets, zip(entries, localized)) where node.entry == pair.0 && pair.0 != pair.1 {
                node.entry = pair.1
                changed = true
            }
            guard changed else { return }
            listing.sort { nodes in
                if resultsSummary == nil { sort(&nodes) }
            }
            outlineView.reloadData()
            for node in expanded { outlineView.expandItem(node) }
            select(selection, scroll: false)
            delegate?.browserSelectionDidChange(self)
        }
    }

    /// Replaces the list with a message while results are being computed.
    func showMessage(symbol: String, title: String, message: String = "") {
        noteNavigationContextChanged()
        enterResults()
        loading.showResults(loaded: false)
        sizer.cancelPending()
        mediaInfo.cancelPending()
        listing.clear()
        resultsSummary = ""
        outlineView.reloadData()
        emptyState.show(symbol: symbol, title: title, message: message)
        delegate?.browserContentDidChange(self)
    }

    private func enterResults() {
        if !isShowingResults {
            cancelPendingActions()
            deferredApply = nil
            ordering.enterResults()
            installActiveView()
            syncSortDescriptor()
            // Make room for "Where" from Date and Kind, not from Name (the only column that gives up width on its own).
            columnWidthsBeforeResults = [.modified, .created, .kind].compactMap { id in outlineView.tableColumn(withIdentifier: id).map { (id, $0.width) } }
            outlineView.tableColumn(withIdentifier: .modified)?.width = 130
            outlineView.tableColumn(withIdentifier: .created)?.width = 130
            outlineView.tableColumn(withIdentifier: .kind)?.width = 120
            outlineView.tableColumn(withIdentifier: .location)?.isHidden = false
            fitNameColumn()
            listing.setFilter("")
            filterPill.update(query: "", matches: 0)
        }
    }

    private func leaveResults() {
        if let remembered = ordering.leaveResults() {
            preferences.sortColumn = remembered.key.rawValue
            preferences.sortAscending = remembered.ascending
        }
        installActiveView()
        outlineView.tableColumn(withIdentifier: .location)?.isHidden = true
        for (id, width) in columnWidthsBeforeResults { outlineView.tableColumn(withIdentifier: id)?.width = width }
        columnWidthsBeforeResults = []
        fitNameColumn()
        syncSortDescriptor()
    }

    // MARK: - Sorting and filtering

    private func sort(_ list: inout [FileNode]) { _ = ordering.sort(&list) }

    /// The same order feeds the native list and deeper columns.
    func ordered(_ a: FileEntry, _ b: FileEntry) -> Bool { ordering.ordered(a, b) }

    private func syncSortDescriptor() {
        let descriptors = ordering.choice.map { [NSSortDescriptor(key: $0.key.rawValue, ascending: $0.ascending)] } ?? []
        guard outlineView.sortDescriptors != descriptors else { return }
        updatingSortDescriptor = true
        defer { updatingSortDescriptor = false }
        outlineView.sortDescriptors = descriptors
    }

    func setFilter(_ text: String) {
        guard text != filter else { return }
        listing.setFilter(text)
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

    /// Re-sorts after folder sizes arrive while sorting by size, animating rows into place.
    private func scheduleResort() {
        guard ordering.choice != nil else { return }
        resortWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.resortAfterMetadata() } }
        resortWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func resortAfterMetadata() {
        guard ordering.choice != nil, filter.isEmpty else { return }
        if isRenamingInPlace { deferredMetadataOrder = true; return }
        let selection = selectedURLs
        var sorted = nodes
        let changedParents = ordering.sort(&sorted)
        if !changedParents.isEmpty {
            let expanded = (0..<outlineView.numberOfRows).compactMap { outlineView.item(atRow: $0) as? FileNode }
                .filter { outlineView.isItemExpanded($0) }
            // Root moves alone cannot update the outline's cached child rows. Keep native expansion and selection
            // while applying changed descendant orders; shallow lists retain the usual animated root moves below.
            listing.reorderRoots(sorted)
            outlineView.reloadData()
            for node in expanded { outlineView.expandItem(node) }
            select(selection, scroll: false)
            pushContent()
            return
        }
        guard sorted.map(ObjectIdentifier.init) != rows.map(ObjectIdentifier.init) else { return }
        var working = rows
        outlineView.beginUpdates()
        for (target, node) in sorted.enumerated() {
            guard let current = working.firstIndex(where: { $0 === node }), current != target else { continue }
            outlineView.moveItem(at: current, inParent: nil, to: target, inParent: nil)
            working.remove(at: current)
            working.insert(node, at: target)
        }
        listing.reorderRoots(sorted)
        outlineView.endUpdates()
        if mode == .grid || mode == .columns || mode == .gallery { pushContent() }
    }

    private func folderSizeArrived(_ url: URL) {
        if url == directory { delegate?.browserContentDidChange(self) }
        guard let node = node(for: url) else { return }
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: .size)
        if row >= 0, column >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [column]) }
        treemapController?.updateSize(folderSize(url)?.bytes, for: url)
        if mode == .grid { gridController?.reloadItems([url]) }
        if ordering.choice?.key == .size { scheduleResort() }
        if row >= 0, outlineView.selectedRowIndexes.contains(row) { delegate?.browserContentDidChange(self) }
    }

    private func mediaInfoArrived(_ entry: FileEntry) {
        guard let node = node(for: entry.url), node.entry == entry else { return }
        let row = outlineView.row(forItem: node)
        let columns = IndexSet(outlineView.tableColumns.indices.filter {
            let column = outlineView.tableColumns[$0]
            return !column.isHidden && ListColumn(rawValue: column.identifier.rawValue)?.isMedia == true
        })
        if row >= 0, !columns.isEmpty { outlineView.reloadData(forRowIndexes: [row], columnIndexes: columns) }
        if ordering.choice?.key.isMedia == true { scheduleResort() }
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
        if services.copies.contains(url) { return nil }
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
            activeView.select(urls.map(rowURL), scroll: scroll)
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
            parts = [resultsTotal > shown ? String(localized: "Top \(shown.formatted()) of \(resultsTotal) results", comment: "plural")
                                          : String(localized: "\(shown) results", comment: "plural")]
        } else {
            parts = [filter.isEmpty
                ? String(localized: "\(nodes.count) items", comment: "plural")
                : String(localized: "\(rows.count.formatted()) of \(nodes.count) items", comment: "plural")]
        }
        let selected = selectedEntries
        if !selected.isEmpty {
            let sizes = selected.map { $0.isDirectory ? folderSize($0.url)?.bytes : $0.size }
            let known = sizes.compactMap { $0 }
            parts.append(known.count == sizes.count
                ? String(localized: "\(selected.count) selected, \(Format.bytes(known.saturatingSum))", comment: "plural")
                : String(localized: "\(selected.count) selected", comment: "plural"))
        }
        if let availableCapacity, !isShowingResults {
            parts.append(String(localized: "\(Format.bytes(availableCapacity)) available", comment: "Status bar: free space on the folder’s disk"))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Actions

    @objc func openSelection(_ sender: Any?) {
        if sender as? NSOutlineView === outlineView, outlineView.clickedRow < 0 { return }
        open(selectedEntries)
    }

    func open(_ entries: [FileEntry], fileOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        guard !entries.isEmpty else { return }
        actionFetch?.cancel()
        actionFetch = nil
        // A container's files are fetched first.
        let files = entries.filter { !$0.isFolder }.map(\.url)
        if files.contains(where: services.copies.isPlaceholder) {
            let revision = navigationRevision
            actionFetch = afterFetching(files) { [weak self] in
                guard let self, navigationRevision == revision else { return }
                openFetched(entries, fileOpener: fileOpener)
            }
            return
        }
        openFetched(entries, fileOpener: fileOpener)
    }

    private func openFetched(_ entries: [FileEntry], fileOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        // One archive opens like a folder (Windows-style), unless that's turned off in Settings.
        if entries.count == 1, let entry = entries.first, opensAsFolder(entry) { return browseArchive(entry.url) }
        // A Finder alias to a folder opens that folder here, like a folder (macOS would hand it to Finder).
        let aliasedFolders = entries.filter { !$0.isFolder && !$0.isSymlink && FileEntry.openedFolder($0.url) != $0.url }
        for entry in entries where !entry.isFolder && !aliasedFolders.contains(entry) {
            fileOpener(entry.url)
        }
        if let folder = entries.first(where: \.isFolder) ?? aliasedFolders.first {
            delegate?.browser(self, navigateTo: folder.url)
        }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(selectedURLs, withApplicationAt: app)
    }

    func open(_ urls: [URL], withApplicationAt app: URL,
              opener: @escaping ([URL], URL) -> Void = { urls, app in
                  NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
              }) {
        guard !urls.isEmpty else { return }
        let revision = navigationRevision
        actionFetch?.cancel()
        actionFetch = afterFetching(urls) { [weak self] in
            guard let self, navigationRevision == revision else { return }
            opener(urls, app)
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        // A server has no Trash: deleting there asks first.
        if !urls.isEmpty, isOnServer { return deleteOnServer(urls) }
        guard !urls.isEmpty, !isInsideArchive else { return }
        // In the Trash, ⌘⌫ puts things back (Finder does the same). Trashing what's already in a Trash again would lose
        // where it came from.
        if urls.allSatisfy(Trash.contains) { return putBack(sender) }
        let copies = services.copies
        guard urls.allSatisfy({ FileOps.canTrash($0, copies: copies) }) else { return NSSound.beep() }
        // Keep the cursor where it was: select the row that slides into the first removed one's place.
        let removed = Set(urls.map(Self.key))
        let survivors = rows.filter { !removed.contains(Self.key($0.url)) }
        if let first = rows.firstIndex(where: { removed.contains(Self.key($0.url)) }), !survivors.isEmpty {
            pendingSelection = [survivors[min(first, survivors.count - 1)].url]
        }
        let undo = undoManager
        Task { [weak self] in
            do {
                try await FileOps.trashInBackground(urls, undo: undo, copies: copies)
            } catch let noTrash as FileOps.NoTrash {
                guard let self else { return }
                Self.confirmDelete(noTrash.urls, in: view.window, noTrash: true, copies: copies) { [weak self] in self?.refresh() }
            } catch {
                self?.presentFileError(error)
            }
            self?.refresh()
        }
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = selectedURLs
        // The menus are off in the Trash and in archives opened as folders; this also covers ⌘K.
        guard !urls.isEmpty, !isShowingTrash, !isInsideArchive else { return }
        // Copying onto itself with "keep both" gives Finder's "name copy" naming, with progress for big items.
        let job = services.transfers.enqueue(moves: urls.map { TransferMove(from: $0, to: $0) }, mode: .copy,
                                               undo: undoManager, conflicts: .keepBoth)
        job.onFinish = { [weak self] job in
            guard let self else { return }
            if !job.createdItems.isEmpty { pendingSelection = job.createdItems }
            refresh()
        }
    }

    /// Selects `urls` once the folder shows them (after the reload a change brings).
    func selectWhenShown(_ urls: [URL]) {
        pendingSelection = urls
        refresh()
    }

    @objc func newFolder(_ sender: Any?) {
        if let directory = targetDirectory, services.remote.copies.server(containing: directory) != nil, !isShowingResults { return newFolderOnServer(in: directory) }
        guard let directory = targetDirectory, !isShowingTrash, !isInsideArchive else { return }
        perform {
            let url = try FileOps.newFolder(in: directory, undo: self.undoManager, copies: self.services.copies)
            self.renameWhenShown(url, in: directory)
        }
    }

    /// File ▸ New File: an empty "untitled.txt" (the extension is in Settings ▸ General), selected and being renamed.
    @objc func newFile(_ sender: Any?) {
        if let directory = targetDirectory, services.remote.copies.server(containing: directory) != nil, !isShowingResults { return newFileOnServer(in: directory) }
        guard let directory = targetDirectory, !isShowingTrash, !isInsideArchive else { return }
        perform {
            let url = try FileOps.newFile(in: directory, extension: preferences.newFileExtension, undo: self.undoManager, copies: self.services.copies)
            self.renameWhenShown(url, in: directory)
        }
    }

    /// An item just made in `directory`: selected, and renamed once it's shown.
    func renameWhenShown(_ url: URL, in directory: URL) {
        guard !isShowingResults, !isLoadingFolder else { return }
        if effectiveMode == .columns, Self.key(directory) != self.directory.map(Self.key) {
            columns.renameWhenShown(url, in: directory)
            return
        }
        guard Self.key(directory) == self.directory.map(Self.key) else { return }
        pendingSelection = [url]
        pendingRename = url
        refresh()
    }

    func noteNavigationContextChanged() {
        navigationRevision += 1
        actionFetch?.cancel()
        actionFetch = nil
    }

    /// Navigation and failed reads must not leave a selection or rename waiting for an unrelated later listing.
    func cancelPendingActions() {
        noteNavigationContextChanged()
        selectionFetch?.cancel()
        selectionFetch = nil
        pendingSelection = nil
        pendingRename = nil
        columnController?.cancelPendingRename()
    }

    func stopBackgroundWork() {
        cancelPendingActions()
        resortWork?.cancel()
        resortWork = nil
        watchers = []
        gitObservation = nil
        loading.invalidate()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        columnController?.stopBackgroundWork()
        galleryController?.stopBackgroundWork()
    }

    @objc func renameSelection(_ sender: Any?) {
        if selectedEntries.count > 1 { return renameItems() }
        guard selectedEntries.count == 1, let url = selectedURLs.first else { return }
        beginRename(url)
    }

    /// A second, slower click on the name of the only selected item (Finder's click to rename): renamed in place
    /// wherever File ▸ Rename is allowed (not in an archive opened as a folder, Disk Usage or a folder still loading).
    func renameClicked(_ url: URL) {
        let rename = NSMenuItem(title: "", action: #selector(renameSelection(_:)), keyEquivalent: "")
        guard selectedURLs.count == 1, validateMenuItem(rename) else { return }
        beginRename(url)
    }

    /// Rename N Items…: a rule for all of them, previewed live, applied as one undoable step.
    func renameItems() {
        let urls = selectedURLs
        guard urls.count > 1, !isInsideArchive, !isLoadingFolder else { return }
        let base = targetDirectory ?? directory ?? urls[0].deletingLastPathComponent()
        let controller = BatchRenameController(urls: urls, baseFolder: base, undo: undoManager)
        controller.onApplied = { [weak self] results in
            if !results.isEmpty { self?.selectWhenShown(results) }
        }
        presentAsSheet(controller)
    }

    /// "Rename", or "Rename 3 Items…" for several, like Finder.
    var renameTitle: String {
        let count = selectedEntries.count
        return count > 1 ? String(localized: "Rename \(count) Items…", comment: "plural")
                         : String(localized: "Rename", comment: "Menu command: rename the selected item")
    }

    /// View ▸ Sort By: the same orders as the list's column headers, for every view. Tags follow `sortMenuKeys`.
    static let sortMenuKeys: [(key: NSUserInterfaceItemIdentifier, ascending: Bool)] = [
        (.name, true), (.kind, true), (.modified, false), (.created, false), (.size, false),
    ]

    @objc func sortBy(_ sender: NSMenuItem) {
        guard Self.sortMenuKeys.indices.contains(sender.tag) else { return }
        let choice = Self.sortMenuKeys[sender.tag]
        // Like Finder, picking the current order again keeps its direction.
        if outlineView.sortDescriptors.first?.key == choice.key.rawValue { return }
        outlineView.sortDescriptors = [NSSortDescriptor(key: choice.key.rawValue, ascending: choice.ascending)]
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        let copies = services.copies
        let clipboard = services.clipboard
        // A container's or a server's items are read first (folders with all they hold, shown in Transfers), then go on
        // the clipboard as a staged copy: pasting anywhere (Finder too) gets all of them as ordinary files, never a
        // half-read copy or a link written by another machine.
        let fromContainers = urls.filter(copies.contains)
        guard fromContainers.isEmpty else {
            return services.transfers.add(CopyFetchJob(fromContainers, copies: copies) { [weak self] in
                let task = Task {
                    let staged = await Task.detached(priority: .userInitiated) { copies.stageForClipboard(urls) }.value
                    if !staged.isEmpty { clipboard.write(staged, cut: false) }
                }
                self?.commandWork = task
            })
        }
        clipboard.write(urls, cut: false)
    }

    @objc func cut(_ sender: Any?) {
        services.clipboard.write(selectedURLs, cut: true)
    }

    @objc func paste(_ sender: Any?) {
        guard !isInsideArchive || isOnServer else { return }
        pasteItems(forceMove: false)
    }

    @objc func pasteAndMove(_ sender: Any?) {
        guard !isInsideArchive || isOnServer else { return }
        pasteItems(forceMove: true)
    }

    private func pasteItems(forceMove: Bool) {
        guard let directory = targetDirectory else { return }
        let clipboard = services.clipboard
        let (urls, isCut) = clipboard.read()
        guard !urls.isEmpty else { return }
        // Onto a server: copied there (what's on this Mac stays, even after Cut; a Cut on that server moves it there).
        if services.remote.copies.contains(directory) { return copyToServer(urls, into: directory, move: forceMove || isCut) }
        transfer(urls, into: directory, move: forceMove || isCut)
        if isCut { clipboard.clearCut() }
    }

    @objc func copyPath(_ sender: Any?) {
        let here = (effectiveMode == .columns ? columns.activeDirectory : nil) ?? directory
        let urls = selectedURLs.isEmpty ? [here].compactMap { $0 } : selectedURLs
        let copies = services.copies
        // In a container's files, the path in the container ("/etc/hosts"); a container itself, its name. On a server,
        // the server's address and path ("deploy@web-1:/srv/app"). Never the path of Strata's copy, which is gone when
        // it quits.
        let paths = urls.compactMap { url -> String? in
            if copies.remoteCopies.contains(url) { return copies.remoteCopies.displayPath(url) }
            if copies.containerCopies.contains(url) {
                guard let (source, top) = copies.containerCopies.copy(containing: url),
                      let path = ContainerCopies.containerPath(of: url, top: top) else {
                    return nil
                }
                return top.standardizedFileURL == url.standardizedFileURL ? source.name : path
            }
            if copies.contains(url) { return copies.displayPath(url) }
            return url.path
        }
        guard !paths.isEmpty else { return NSSound.beep() }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Adds the selected folders (or, with nothing selected, this folder) to the sidebar's favorites.
    @objc func addToSidebar(_ sender: Any?) {
        let folders = selectedEntries.filter(\.isFolder).map(\.url)
        // A temporary copy of an archive's contents doesn't belong in the sidebar.
        Places.addFavorites((folders.isEmpty ? [directory].compactMap { $0 } : folders).filter { !isReadOnlyCopy($0) },
                            preferences: preferences)
    }

    @objc func addToShelf(_ sender: Any?) {
        ShelfPanel.shared.add(selectedURLs)
    }

    /// Shows the system share picker (AirDrop, Messages, Mail, …) for the selection, pointing at the first selected item.
    @objc func share(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let (rect, edge) = selectionAnchor()
        NSSharingServicePicker(items: urls).show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    /// The selection's tags in a popover with suggestions (Finder's Tags…).
    @objc func editTags(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, urls.allSatisfy(TagStore.canTag) else { return }
        let (rect, _) = selectionAnchor()
        TagEditorController(urls: urls, undo: undoManager).show(relativeTo: rect, of: view)
    }

    /// Where to point a popover about the selection: the first selected item on screen (not under the toolbar), or
    /// the top middle of the folder when none is. The edge says which way the popover should open.
    func selectionAnchor() -> (rect: NSRect, edge: NSRectEdge) {
        let area = view.safeAreaRect
        if let window = view.window {
            let anchor = selectedURLs.prefix(200).lazy.compactMap { [self] url -> NSRect? in
                guard let screenRect = iconScreenRect(for: url) else { return nil }
                let rect = view.convert(window.convertFromScreen(screenRect), from: nil).intersection(area)
                return rect.isEmpty ? nil : rect
            }.first
            if let anchor { return (anchor, .maxY) }
        }
        return (NSRect(x: area.midX, y: area.maxY - 8, width: 1, height: 1), .minY)
    }

    /// Where an item's icon is on screen, when it's visible: for Quick Look's zoom and to point the share picker at it.
    func iconScreenRect(for url: URL) -> NSRect? {
        if let activeView { return activeView.screenRect(for: url) }
        guard let node = node(for: url), let window = view.window else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return nil }
        let cell = outlineView.frameOfCell(atColumn: outlineView.column(withIdentifier: .name), row: row)
        let side = NameCellView.iconSide
        let iconRect = NSRect(x: cell.minX + 1, y: cell.midY - side / 2, width: side, height: side)
        guard outlineView.visibleRect.intersects(iconRect) else { return nil }
        return window.convertToScreen(outlineView.convert(iconRect, to: nil))
    }

    @objc func showInFinder(_ sender: Any?) {
        // Inside an archive opened as a folder, Finder shows the archive (not Strata's copy in its caches).
        if isInsideArchive { return showArchiveInFinder(sender) }
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        let target = selectedURLs.first?.deletingLastPathComponent() ?? directory
        guard let target else { return }
        NSWorkspace.shared.open([target], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openInTerminal(_ sender: Any?) {
        // A Compose project's folder on this Mac, not the copy Strata keeps of its containers.
        if openStackInTerminal() { return }
        // In a container's files: a shell in the container. On an SFTP server: a shell there.
        if openTerminalInContainer() || openTerminalOnServer() { return }
        let selected = selectedEntries
        let folder = selected.count == 1 && selected[0].isFolder ? selected[0].url : targetDirectory
        guard let folder else { return }
        guard let terminal = preferences.terminalURL else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The selection is a Compose project (or the folder shown is one, with nothing selected).
    var isStackContext: Bool {
        let copies = services.copies.containerCopies
        if selectedEntries.isEmpty { return directory.map(copies.isStack) == true }
        return selectedEntries.allSatisfy { copies.isStack($0.url) }
    }

    /// Project folders on this Mac for the stacks in the context menu.
    func stackProjectFolders() -> [URL] {
        let stacks = selectedEntries.isEmpty ? [directory].compactMap { $0 } : selectedEntries.map(\.url)
        let copies = services.copies.containerCopies, store = services.containerStore
        return stacks.compactMap { StackProjects.existingFolder(of: $0, copies: copies, store: store) }
    }

    /// Opens those project folders in the terminal. True when this was a stack, even if the folder is gone.
    private func openStackInTerminal() -> Bool {
        guard isStackContext else { return false }
        let folders = stackProjectFolders()
        guard let terminal = preferences.terminalURL, !folders.isEmpty else { NSSound.beep(); return true }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: configuration)
        return true
    }

    @objc private func openStackWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let folders = stackProjectFolders()
        guard !folders.isEmpty else { return NSSound.beep() }
        for folder in folders { ProjectEditors.open(folder, with: app) }
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        preferences.showHidden.toggle()
    }

    @objc func toggleFoldersFirst(_ sender: Any?) {
        preferences.foldersFirst.toggle()
    }

    @objc func reloadFolder(_ sender: Any?) {
        for node in nodes where node.entry.isDirectory { FolderSizer.invalidate(node.url) }
        if let repository = gitObservation?.repository { GitStatusStore.shared.refresh(repository, force: true) }
        // Invalidation and the following read belong to the same request, cancelled together on navigation.
        refresh(invalidateCopy: true)
    }

    @objc private func prefsChanged() {
        listing.sort(using: sort)
        refresh()
    }

    /// Density or text size changed: every view takes the new row height and font (nothing is read again).
    @objc private func appearanceChanged() {
        outlineView.rowHeight = FileViewStyle.listHeight(for: preferences)
        outlineView.reloadData()
        columnController?.restyle()
        if let gridController { gridController.restyle() }
        galleryController?.refreshVisibleItems()
    }

    @objc private func viewOptionsChanged() {
        guard let gridController else { return }
        gridController.showsItemInfo = preferences.iconViewOptions.showsInfo
        gridController.setIconSize(CGFloat(preferences.gridIconSize), animated: false)
        gridController.refreshVisibleItems(reconfigure: true)
    }

    /// Index totals moved: refresh visible sizes (and the order, when sorting by size).
    @objc private func indexChanged() {
        // Folder sizes come from the index; a file's is its own.
        let column = outlineView.column(withIdentifier: .size)
        let visible = outlineView.rows(in: outlineView.visibleRect)
        let folders = IndexSet((visible.location..<NSMaxRange(visible)).filter { row in
            (outlineView.item(atRow: row) as? FileNode)?.entry.isDirectory == true
        })
        if column >= 0, !folders.isEmpty {
            outlineView.reloadData(forRowIndexes: folders, columnIndexes: [column])
        }
        if ordering.choice?.key == .size { scheduleResort() }
        if effectiveMode == .treemap { pushContent(animated: true) }
        if effectiveMode == .grid { gridController?.refreshVisibleItems(reconfigure: true) }
        delegate?.browserContentDidChange(self)
    }

    /// Status arrived or changed: redraw visible rows (badges and ignored-dimming).
    @objc private func gitStatusChanged(_ notification: Notification) {
        guard let root = notification.userInfo?["root"] as? URL, let directory,
              directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return }
        clipboardChanged()
        gridController?.refreshVisibleItems()
        columnController?.refreshVisibleRows()
    }

    /// Reads the shown folder's tags again (Finder may have changed them while Strata was in the background).
    func rereadTags() {
        guard let directory, !isShowingResults else { return }
        TagStore.shared.invalidate(directory)
        TagStore.shared.load(nodes.map(\.entry), in: directory)
        CloudStore.shared.load(nodes.map(\.url), in: directory)
    }

    /// Tags changed (here or in another window) or were read: redraw what's shown.
    @objc private func tagsChanged() {
        reloadVisibleCells()
    }

    /// Every view mode's visible items configured again (icons, badges, thumbnails).
    func reloadVisibleCells() {
        clipboardChanged()
        gridController?.refreshVisibleItems(reconfigure: true)
        columnController?.refreshVisibleRows()
        galleryController?.refreshVisibleItems(reconfigure: true)
    }

    @objc private func clipboardChanged() {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        outlineView.reloadData(forRowIndexes: exceptRenaming(IndexSet(integersIn: visible.location..<NSMaxRange(visible))),
                               columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
    }

    /// Whether a name in the list is being edited right now.
    private var isRenamingInPlace: Bool { renaming != nil && renamingField?.currentEditor() != nil }

    /// `rows` without the one whose name is being edited: reloading a row gives it a new cell, which ends the edit.
    private func exceptRenaming(_ rows: IndexSet) -> IndexSet {
        guard isRenamingInPlace, let renaming else { return rows }
        let row = outlineView.row(forItem: renaming)
        guard row >= 0 else { return rows }
        var rows = rows
        rows.remove(row)
        return rows
    }

    /// Copies and moves go through the transfer queue: progress, pause, conflicts asked up front, undo.
    private func transfer(_ urls: [URL], into target: URL, move: Bool) {
        if services.remote.copies.contains(target) { return copyToServer(urls, into: target, move: move) }
        let job = services.transfers.enqueue(urls, to: target, mode: move ? .move : .copy,
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
        commandWork = Task { [weak self] in
            do { try await body() } catch { self?.presentFileError(error) }
        }
    }

    private func presentFileError(_ error: Error) {
        guard let window = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
        refresh()
    }

    // MARK: - Rename

    /// Renames with Finder's checks: no "/" or leading dot, and a confirmation when a file's extension changes.
    func renameItem(_ url: URL, to newName: String) {
        let oldName = url.lastPathComponent
        guard !newName.isEmpty, newName != oldName else { return }
        if newName.contains("/") {
            renameRefused(String(localized: "The name “\(newName)” can’t be used."),
                          String(localized: "Names can’t contain “/”. Try a different name."))
            return
        }
        if newName.hasPrefix("."), !oldName.hasPrefix(".") {
            renameRefused(String(localized: "You can’t use a name that begins with a dot “.”."),
                          String(localized: "These names are reserved for the system, and the item would be hidden. Please choose another name."))
            return
        }
        let commit = { [self] in
            if services.remote.copies.contains(url) { return renameOnServer(url, to: newName) }
            performAsync { [self] in
                let renamed = try await FileOps.rename(url, to: newName, undo: undoManager, copies: services.copies)
                pendingSelection = [renamed]
                refresh()
            }
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let (oldExtension, newExtension) = ((oldName as NSString).pathExtension, (newName as NSString).pathExtension)
        guard !isFolder, oldExtension.lowercased() != newExtension.lowercased(), let window = view.window else {
            commit()
            return
        }
        let alert = NSAlert()
        if oldExtension.isEmpty {
            alert.messageText = String(localized: "Are you sure you want to add the extension “.\(newExtension)” to the end of the name?")
        } else if newExtension.isEmpty {
            alert.messageText = String(localized: "Are you sure you want to remove the extension “.\(oldExtension)”?")
        } else {
            alert.messageText = String(localized: "Are you sure you want to change the extension from “.\(oldExtension)” to “.\(newExtension)”?")
        }
        alert.informativeText = String(localized: "If you make this change, your document may open in a different app.")
        alert.addButton(withTitle: oldExtension.isEmpty ? String(localized: "Don’t Add", comment: "Alert button: don’t add the file extension")
                                                        : String(localized: "Keep .\(oldExtension)", comment: "Alert button: keep the file extension (“Keep .txt”)"))
        alert.addButton(withTitle: newExtension.isEmpty ? String(localized: "Remove", comment: "Alert button: remove the file extension")
                                                        : String(localized: "Use .\(newExtension)", comment: "Alert button: use the new file extension (“Use .md”)"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { commit() }
        }
    }

    private func renameRefused(_ message: String, _ detail: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    private func beginRename(_ url: URL) {
        // An archive opened as a folder isn't changed (a server's files are, through the server).
        let remoteCopies = services.remote.copies
        guard !isReadOnlyCopy(url) || (remoteCopies.contains(url) && RemoteCopies.remotePath(of: url, top: remoteCopies.server(containing: url)?.top ?? url) != "/") else { return }
        if let activeView {
            activeView.beginRename(rowURL(url))
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
        renamingField = field
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
            openQuickLook { panel.makeKeyAndOrderFront(nil) }
        }
    }

    func openQuickLook(showPanel: @escaping () -> Void = { QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil) }) {
        let urls = selectedURLs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
        let selectedKeys = Set(selectedURLs.map(Self.key))
        guard !selectedKeys.isEmpty else { return }
        let revision = navigationRevision
        let hadWindow = viewIfLoaded?.window != nil
        actionFetch?.cancel()
        // A container's file being fetched: show it once it's here.
        actionFetch = afterFetching(urls) { [weak self] in
            guard let self, navigationRevision == revision,
                  (!hadWindow || viewIfLoaded?.window?.isVisible == true),
                  !Set(selectedURLs.map(Self.key)).isDisjoint(with: selectedKeys) else { return }
            showPanel()
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
        // `addTitled` takes a title that's already localized (Rename 3 Items…), `add` a literal.
        func addTitled(_ title: String, _ action: Selector, _ symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        func add(_ title: String.LocalizationValue, _ action: Selector, _ symbol: String? = nil) {
            addTitled(String(localized: title), action, symbol)
        }
        func add(_ command: StrataCommand, title: String? = nil) {
            let item = command.menuItem(title: title, target: self, withShortcut: false)
            item.image = command.image
            menu.addItem(item)
        }
        func addStackOpenItems() {
            guard !stackProjectFolders().isEmpty else { return }
            add(.openInTerminal)
            let apps = ProjectEditors.installed()
            guard !apps.isEmpty else { return }
            let submenu = NSMenu()
            for app in apps {
                let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(openStackWithApplication(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                submenu.addItem(item)
            }
            let openWith = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
            openWith.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
            openWith.submenu = submenu
            menu.addItem(openWith)
        }
        let hiddenFilesTitle = preferences.showHidden ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files")
        if selected.isEmpty {
            // On a server: a new folder there, or pasting onto it; a shell there (SFTP).
            if isOnServer {
                add(.newFolder)
                add(.newFile)
                if services.clipboard.hasFiles { add(.paste) }
                menu.addItem(.separator())
                if directory.flatMap({ services.remote.copies.server(containing: $0)?.server.kind }) == .sftp {
                    add(.openInTerminal)
                }
                add(.copyPath)
                menu.addItem(.separator())
                add(.toggleHiddenFiles, title: hiddenFilesTitle)
                return menu
            }
            // Inside an archive opened as a folder nothing is added; Finder is shown the archive itself.
            if isInsideArchive {
                if directory.map(services.copies.containerCopies.isStack) == true {
                    addStackOpenItems()
                } else if directory.map(services.copies.containerCopies.engineFolder) == nil {
                    add(.openInTerminal)
                }
                if directory.map(ArchiveCache.contains) == true { add("Show Archive in Finder", #selector(showArchiveInFinder(_:)), "macwindow") }
                menu.addItem(.separator())
                add(.toggleHiddenFiles, title: hiddenFilesTitle)
                return menu
            }
            add(.newFolder)
            add(.newFile)
            if services.clipboard.hasFiles { add(.paste) }
            menu.addItem(.separator())
            add(.openInTerminal)
            add(.copyPath)
            add(.showInFinder)
            menu.addItem(.separator())
            add(.toggleHiddenFiles, title: hiddenFilesTitle)
            if isShowingTrash {
                menu.addItem(.separator())
                addEmptyTrash()
            }
            return menu
        }
        func addEmptyTrash() {
            let empty = NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "")
            empty.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(empty)
        }
        // In the Trash, Finder leads with Put Back and Delete Immediately.
        let inTrash = selected.allSatisfy { Trash.contains($0.url) }
        let reachesIntoTrash = !inTrash && selected.contains { Trash.isInTrash($0.url) }
        if inTrash {
            add(.putBack)
            add(.deleteImmediately)
            menu.addItem(.separator())
        }
        add(.openSelection)
        // Containers: what can be done to them, then a shell in one.
        let containers = selectedContainers
        if !containers.isEmpty {
            menu.addItem(.separator())
            for action in ContainerControl.actions(for: containers) {
                add(.container(action))
            }
            add(.openInTerminal)
            menu.addItem(.separator())
        }
        // With archives opening normally (Settings), browsing one is still a click away.
        if selected.count == 1, let entry = selected.first, !entry.isFolder, !opensAsFolder(entry),
           ArchiveKind(fileName: entry.name) != nil {
            add("Open as Folder", #selector(openArchiveAsFolder(_:)), "archivebox")
        }
        if let first = selected.first, !first.isFolder {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
            if !apps.isEmpty {
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first.url)
                let submenu = NSMenu()
                for app in apps.prefix(24) {
                    var title = FileManager.default.displayName(atPath: app.path)
                    if app == defaultApp { title = String(localized: "\(title) (default)", comment: "Open With submenu: the app that opens the file by default") }
                    let item = NSMenuItem(title: title, action: #selector(openWithApplication(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = app
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    submenu.addItem(item)
                }
                let openWith = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
                openWith.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
                openWith.submenu = submenu
                menu.addItem(openWith)
            }
        }
        if !selectedApps.isEmpty { add(.checkAppsForUpdates, title: appUpdatesTitle) }
        // iCloud Drive and File Provider folders: bring items here, or free their space.
        let cloud = selectedCloudStatuses
        if !inTrash, cloud.contains(.cloudOnly) { add("Download Now", #selector(downloadNow(_:)), "icloud.and.arrow.down") }
        if !inTrash, cloud.contains(.downloaded) { add("Remove Download", #selector(removeDownload(_:)), "icloud.slash") }
        add(.toggleQuickLook)
        // The system's own item: it keeps its picker alive and shows the share sheet next to the menu. Not for a
        // container's files: they're only read when copied out.
        let inContainer = directory.map(services.copies.contains) == true
        if !inContainer { menu.addItem(NSSharingServicePicker(items: selected.map(\.url)).standardShareMenuItem) }
        menu.addItem(.separator())
        // On a server: rename one, delete (it asks: no Trash there), copy out.
        if isOnServer {
            if selected.count == 1 { add(.renameSelection, title: renameTitle) }
            addTitled(String(localized: "Delete…", comment: "Menu command: delete for good (on a server, which has no Trash)"),
                      #selector(moveToTrash(_:)), "trash")
            menu.addItem(.separator())
            add(.copy)
            add(.copyPath)
            return menu
        }
        // Inside an archive opened as a folder nothing changes: copying out is what's offered.
        let inArchive = isInsideArchive
        if inArchive {
            add(.copy)
            if !inContainer { add(.addToShelf) }
            if containers.isEmpty {
                if !selectedEntries.isEmpty, selectedEntries.allSatisfy({ services.copies.containerCopies.isStack($0.url) }) {
                    if !stackProjectFolders().isEmpty { menu.addItem(.separator()) }
                    addStackOpenItems()
                } else {
                    menu.addItem(.separator())
                    add(.openInTerminal)
                }
            }
            if directory.map(ArchiveCache.contains) == true { add("Show Archive in Finder", #selector(showArchiveInFinder(_:)), "macwindow") }
            return menu
        }
        add(.renameSelection, title: renameTitle)
        if inTrash {
            addEmptyTrash()
        } else {
            add(.compress, title: compressTitle)
            if !selectedArchives.isEmpty { add(.extract, title: extractTitle) }
            add(.duplicate)
            if !reachesIntoTrash { add(.moveToTrash) }
        }
        menu.addItem(.separator())
        add(.copy)
        add(.cut)
        add(.copyPath)
        add(.addToShelf)
        // Finder's tags: the seven colors to click, and Tags… for any tag.
        if !inTrash, selected.allSatisfy({ !$0.isVolume && TagStore.canTag($0.url) }) {
            menu.addItem(.separator())
            let urls = selected.map(\.url)
            var applied: [String: Bool] = [:]
            // Checkmarks for what every item has (not worked out for huge selections: each item would be read).
            if urls.count <= 300 {
                for tag in FinderTag.standard {
                    applied[tag.name.lowercased()] = urls.allSatisfy { url in
                        TagStore.shared.tags(for: url).contains { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }
                    }
                }
            }
            let row = NSMenuItem()
            row.view = TagMenuView(applied: applied) { [weak self] tag in
                guard let self else { return }
                do { try TagStore.shared.toggle(tag, on: urls, undo: undoManager) } catch { presentFileError(error) }
            }
            menu.addItem(row)
            add(.editTags)
        }
        if selectedEntries.contains(where: \.isFolder) { add(.addToSidebar) }
        menu.addItem(.separator())
        add(.openInTerminal)
        add(.showInFinder)
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

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // A drag resting on a folder springs it open; the outline's own expand-on-hover would compete.
        !isDragOver
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.groupTitle != nil { return true }
        guard filter.isEmpty, !isShowingResults else { return false }
        return node.entry.isFolder
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ThemeRowView() }

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
        let dimmed = entry.isHidden || services.clipboard.isCut(entry.url) || git.isIgnored(entry.url)
        if column.identifier == .name {
            let cell = outlineView.makeView(withIdentifier: .nameCell, owner: nil) as? NameCellView ?? {
                let cell = NameCellView()
                cell.identifier = .nameCell
                return cell
            }()
            cell.configure(name: entry.displayName, icon: IconCache.shared.icon(for: entry), matches: node.matchIndices, dimmed: dimmed,
                           git: git.badge(for: entry.url, isDirectory: entry.isDirectory), tags: TagStore.shared.tags(for: entry.url),
                           cloud: CloudStore.shared.status(for: entry.url), thumbnail: preferences.showIconPreviews ? entry : nil,
                           thumbnails: services.thumbnails, scale: outlineView.window?.backingScaleFactor ?? 2,
                           typography: FileViewTypography(preferences: preferences))
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .textCell, owner: nil) as? TextCellView ?? {
            let cell = TextCellView()
            cell.identifier = .textCell
            return cell
        }()
        switch column.identifier {
        case .modified: cell.configure(Format.date(entry.modified), alignment: .left, dimmed: dimmed)
        case .created: cell.configure(Format.date(entry.created), alignment: .left, dimmed: dimmed)
        case .added: cell.configure(Format.date(entry.added), alignment: .left, dimmed: dimmed)
        case .fileExtension: cell.configure(entry.url.pathExtension, alignment: .left, dimmed: dimmed)
        case .dimensions, .width, .height, .duration:
            mediaInfo.request(entry)
            let info = mediaInfo.cached(entry)
            let text: String?
            switch column.identifier {
            case .dimensions: text = info?.dimensions
            case .width: text = info?.width.map(String.init)
            case .height: text = info?.height.map(String.init)
            default: text = info?.durationText
            }
            cell.configure(text ?? (info == nil && mediaInfo.canRead(entry) ? "…" : "—"),
                           alignment: column.headerCell.alignment, dimmed: dimmed)
        case .size: cell.configure(sizeText(node), alignment: .right, dimmed: dimmed)
        case .location: cell.configure(Format.tildePath(entry.url.deletingLastPathComponent()), alignment: .left, dimmed: dimmed)
        default: cell.configure(entry.kind, alignment: .left, dimmed: dimmed)
        }
        return cell
    }

    private func sizeText(_ node: FileNode) -> String {
        guard node.entry.isDirectory else { return Format.bytes(node.entry.size ?? 0) }
        // A container's folder holds only what's been browsed: its size isn't known.
        if services.copies.contains(node.url) { return "—" }
        if let size = FileIndex.shared.folderSize(node.url) ?? sizer.cached(node.url) { return Format.bytes(size.bytes) }
        guard canMeasure(node.entry) else { return "—" }
        sizer.request(node.url)
        return "…"
    }

    /// Symlinks and volumes aren't walked, and neither are guarded folders that would trigger a consent prompt.
    func canMeasure(_ entry: FileEntry) -> Bool {
        guard entry.isDirectory, !entry.isSymlink, !entry.isVolume, !services.copies.contains(entry.url), let directory else { return false }
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
        prefetchSelection()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !updatingSortDescriptor, let descriptor = outlineView.sortDescriptors.first,
              let key = SortKey(rawValue: descriptor.key ?? "") else { return }
        applySort(key, ascending: descriptor.ascending)
    }

    func applySort(_ key: SortKey, ascending direction: Bool, remember: Bool = true) {
        ordering.choose(.init(key: key, ascending: direction), remember: remember)
        syncSortDescriptor()
        if remember { preferences.sortColumn = key.rawValue; preferences.sortAscending = direction }
        let selection = selectedURLs
        listing.sort(using: sort)
        outlineView.reloadData()
        pushContent()
        select(selection, scroll: false)
    }

    // Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node.groupTitle == nil else { return nil }
        return ContainerDragItem.writer(for: node.url, copies: services.copies)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let urls = draggedURLs(info) ?? []
        isDragOver = true
        springLoader.hover(springTarget(item, index, urls), drag: info.draggingSequenceNumber)
        guard !urls.isEmpty, let target = retargetDrop(outlineView, item) else { return [] }
        // The rules every view shares: never into itself, no moves that change nothing, nothing into an archive opened
        // as a folder, copies out of one.
        return FileDrop.operation(urls, into: target, info: info, copies: services.copies)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        isDragOver = false
        guard let urls = draggedURLs(info), let target = (item as? FileNode)?.url ?? directory else { return false }
        let operation = FileDrop.operation(urls, into: target, info: info, copies: services.copies)
        guard !operation.isEmpty else { return false }
        transfer(urls, into: target, move: operation == .move)
        return true
    }

    /// The folder row a file drag rests on (not between rows, not one of the dragged items or inside one), to spring
    /// open.
    private func springTarget(_ item: Any?, _ index: Int, _ dragged: [URL]) -> URL? {
        guard !dragged.isEmpty, index == NSOutlineViewDropOnItemIndex, let node = item as? FileNode, node.groupTitle == nil,
              node.entry.isFolder, !FileDrop.isInside(dragged, node.url),
              SpringLoader.canOpen(node.url, browsing: directory) else { return nil }
        return node.url
    }

    /// Opens a folder a drag rested on. Ignored while another folder loads: the rows on screen are the previous one's.
    func springLoad(_ folder: URL, drag: Int) {
        guard !isLoadingFolder else { return }
        delegate?.browser(self, springLoadTo: folder, drag: drag)
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
        FileDrop.urls(info, copies: services.copies)
    }
}

// MARK: - Rename editing

extension BrowserViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let node = renaming else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        renamingField = nil
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        if let deferred = deferredApply, deferred.generation == generation {
            apply(deferred.entries, preservingState: deferred.preservingState, fromTop: deferred.fromTop)
        } else {
            deferredApply = nil
            let row = outlineView.row(forItem: node)
            if row >= 0 { outlineView.reloadData(forRowIndexes: [row], columnIndexes: [outlineView.column(withIdentifier: .name)]) }
        }
        view.window?.makeFirstResponder(outlineView)
        if deferredMetadataOrder {
            deferredMetadataOrder = false
            resortAfterMetadata()
        }
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
            #selector(newFile(_:)), #selector(renameSelection(_:)), #selector(toggleQuickLook(_:)), #selector(pasteAndMove(_:)),
            #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)), #selector(share(_:)),
            #selector(putBack(_:)), #selector(deleteImmediately(_:)), #selector(compress(_:)), #selector(extract(_:)),
        ]
        // While a name is being edited, ⌘⌫, ⌘D, ⇧⌘N and ⌥⌘N belong to the text, not the file. While another folder loads,
        // the rows on screen are the previous folder's.
        if let action = item.action, fileCommands.contains(action),
           view.window?.firstResponder is NSText || isLoadingFolder {
            return false
        }
        let selectionCount = selectedEntries.count
        let hasSelection = selectionCount > 0
        // An archive opened as a folder is a copy that isn't saved back: nothing in it is changed from Strata.
        let changes: [Selector] = [
            #selector(newFolder(_:)), #selector(newFile(_:)), #selector(paste(_:)), #selector(pasteAndMove(_:)), #selector(renameSelection(_:)),
            #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)), #selector(duplicate(_:)), #selector(cut(_:)),
            #selector(compress(_:)), #selector(extract(_:)), #selector(putBack(_:)),
            #selector(editTags(_:)), #selector(addToSidebar(_:)),
        ]
        // On a server: new files and folders, renaming one item, deleting and pasting go to the server; the rest stays off.
        let serverChanges: [Selector] = [#selector(newFolder(_:)), #selector(newFile(_:)), #selector(paste(_:)), #selector(pasteAndMove(_:)),
                                         #selector(renameSelection(_:)), #selector(moveToTrash(_:)), #selector(deleteImmediately(_:))]
        if isOnServer, let action = item.action, serverChanges.contains(action) {
            // Like on this Mac: not in search results, a folder that didn't load, or Disk Usage.
            let showsFolder = !isShowingResults && loadError == nil && effectiveMode != .treemap
            switch action {
            case #selector(moveToTrash(_:)):
                item.title = String(localized: "Delete…", comment: "Menu command: delete for good (on a server, which has no Trash)")
                return hasSelection
            case #selector(deleteImmediately(_:)): return hasSelection
            case #selector(renameSelection(_:)): return showsFolder && selectedEntries.count == 1
            case #selector(paste(_:)), #selector(pasteAndMove(_:)): return showsFolder && services.clipboard.hasFiles
            default: return showsFolder
            }
        }
        // Back from a server: the File menu says Move to Trash again (Delete… was the server's).
        if item.action == #selector(moveToTrash(_:)) { item.title = String(localized: "Move to Trash") }
        if let action = item.action, changes.contains(action), isInsideArchive { return false }
        switch item.action {
        case #selector(moveToTrash(_:)):
            // Finder's File menu says Put Back for things in the Trash, and won't trash what's inside a trashed folder.
            let inTrash = hasSelection && selectedEntries.allSatisfy { Trash.contains($0.url) }
            item.title = inTrash ? String(localized: "Put Back") : String(localized: "Move to Trash")
            return hasSelection && (inTrash || !selectedEntries.contains { Trash.isInTrash($0.url) || Trash.isTrash(anySpelling: $0.url) })
        case #selector(putBack(_:)):
            return hasSelection && selectedEntries.allSatisfy { Trash.contains($0.url) }
        case #selector(checkAppsForUpdates(_:)):
            item.title = appUpdatesTitle
            return !selectedApps.isEmpty
        // A container's files are read only when copied out: no shelf, no share sheet, no Finder.
        case #selector(addToShelf(_:)) where directory.map(services.copies.contains) == true,
             #selector(share(_:)) where directory.map(services.copies.contains) == true,
             #selector(showInFinder(_:)) where directory.map(services.copies.contains) == true:
            return false
        case #selector(openInTerminal(_:)) where serverKind != nil:
            // On a server it's a shell there over ssh; a bucket has none.
            return serverKind == .sftp
        case #selector(openInTerminal(_:)) where isStackContext:
            return !stackProjectFolders().isEmpty
        case #selector(openInTerminal(_:)) where canOpenTerminalInContainer != nil:
            // In a container's files it's a shell in the container, which has to be running.
            return canOpenTerminalInContainer == true
        case #selector(containerAction(_:)):
            guard let raw = item.representedObject as? String, let action = ContainerAction(rawValue: raw) else { return false }
            return selectedContainers.contains { action.applies(to: $0.state) && services.containerStore.busy[$0.id] == nil }
        case #selector(duplicate(_:)):
            return hasSelection && !isShowingTrash
        case #selector(editTags(_:)):
            return hasSelection && selectedEntries.allSatisfy { !$0.isVolume && TagStore.canTag($0.url) }
        case #selector(compress(_:)):
            // Finder names what it compresses: "Compress “Photos”", "Compress 3 Items".
            item.title = hasSelection ? compressTitle : String(localized: "Compress", comment: "Menu command: zip the selected items")
            return hasSelection && !isShowingTrash && effectiveMode != .treemap && canWriteBesideSelection
        case #selector(extract(_:)):
            item.title = extractTitle
            return !selectedArchives.isEmpty && !isShowingTrash && canWriteBesideSelection
        case #selector(openSelection(_:)), #selector(deleteImmediately(_:)),
             #selector(copy(_:)), #selector(cut(_:)), #selector(toggleQuickLook(_:)), #selector(share(_:)):
            return hasSelection
        case #selector(renameSelection(_:)):
            item.title = renameTitle
            return selectionCount >= 1 && effectiveMode != .treemap
        case #selector(paste(_:)), #selector(pasteAndMove(_:)):
            return directory != nil && !isShowingResults && services.clipboard.hasFiles && !isShowingTrash
        case #selector(newFolder(_:)), #selector(newFile(_:)):
            // Disk Usage can't show an empty folder or file, so a new one would seem to vanish.
            return directory != nil && !isShowingResults && loadError == nil && effectiveMode != .treemap && !isShowingTrash
        case #selector(toggleHiddenFiles(_:)):
            item.state = preferences.showHidden ? .on : .off
            return true
        case #selector(biggerIcons(_:)), #selector(smallerIcons(_:)):
            // Icons zoom the icons; List and Columns, the names' text.
            let bigger = item.action == #selector(biggerIcons(_:))
            switch effectiveMode {
            case .grid:
                item.title = bigger ? String(localized: "Bigger Icons") : String(localized: "Smaller Icons")
                return true
            case .list, .columns:
                item.title = bigger ? String(localized: "Bigger Text", comment: "View menu: make file names bigger (⌘+)")
                    : String(localized: "Smaller Text", comment: "View menu: make file names smaller (⌘−)")
                return bigger ? preferences.nameTextSize < Self.textSizes.upperBound : preferences.nameTextSize > Self.textSizes.lowerBound
            case .gallery, .treemap:
                return false
            }
        case #selector(toggleFoldersFirst(_:)):
            item.state = preferences.foldersFirst ? .on : .off
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
        return iconScreenRect(for: url) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = (item as? NSURL) as URL? else { return nil }
        guard let entry = selectedEntries.first(where: { Self.key($0.url) == Self.key(url) }) ?? node(for: url)?.entry else { return nil }
        // The thumbnail the row shows, so the zoom starts from what's on screen.
        let scale = view.window?.backingScaleFactor ?? 2
        if preferences.showIconPreviews, services.thumbnails.canThumbnail(entry),
           let thumbnail = services.thumbnails.cached(entry, size: NameCellView.iconSide, scale: scale) { return thumbnail.image }
        return IconCache.shared.icon(for: entry)
    }
}
