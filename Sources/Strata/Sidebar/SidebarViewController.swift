import AppKit

final class SidebarSection {
    /// Names the section in code ("favorites"); `title` is what's shown, in your language.
    let id: String
    let title: String
    var items: [SidebarItem]

    init(id: String, title: String, items: [SidebarItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

extension NSPasteboard.PasteboardType {
    /// A favorite being reordered inside the sidebar (never a file URL: dropping it elsewhere mustn't move the folder).
    static let sidebarFavorite = NSPasteboard.PasteboardType("dev.strata.sidebar-favorite")
}

/// Where a sidebar row takes you.
enum SidebarTarget: Equatable {
    case folder(URL)
    case recents
    case search(SavedSearch)
    case duplicates
    case largeFiles
}

final class SidebarItem {
    let title: String
    let target: SidebarTarget
    var symbol: String
    var isEjectable = false
    /// A Finder tag's color for its dot (Tags section).
    var tint: NSColor?
    /// A Finder tag's stored name (Tags section): `title` shows it in your language, this is what's matched and removed.
    var tagName: String?

    init(_ place: Place) {
        title = place.title
        target = .folder(place.url.standardizedFileURL)
        symbol = place.symbol
        isEjectable = place.isEjectable
    }

    init(title: String, target: SidebarTarget, symbol: String) {
        self.title = title
        self.target = target
        self.symbol = symbol
    }

    var url: URL? {
        if case .folder(let url) = target { return url }
        return nil
    }
}

final class SidebarViewController: NSViewController {
    var onSelect: ((SidebarTarget) -> Void)?
    /// "Open in New Tab" from the context menu.
    var onOpenInNewTab: ((URL) -> Void)?

    private let outline = SidebarOutlineView()
    /// Opens the location a drag rests on, in the current pane.
    private lazy var springLoader = SpringLoader(view: outline, frame: { [weak self] folder in
        guard let self, let row = row(for: folder) else { return nil }
        return outline.rect(ofRow: row)
    }, open: { [weak self] folder, _ in
        guard let self, let row = row(for: folder) else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
    })

    private func row(for folder: URL) -> Int? {
        for section in sections {
            guard let item = section.items.first(where: { $0.url?.fileViewKey == folder.fileViewKey }) else { continue }
            let row = outline.row(forItem: item)
            return row >= 0 ? row : nil
        }
        return nil
    }
    private var sections: [SidebarSection] = []
    private var suppressSelection = false
    private var current: SidebarTarget?
    /// Whether the current drag may go on the Trash, worked out once per drag.
    private var trashVerdict: (drag: Int, operation: NSDragOperation)?

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL, .sidebarFavorite])
        outline.onDragEnd = { [weak self] in self?.springLoader.cancel() }
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        view = scroll
        reload()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .savedSearchesChanged, object: nil)
        // A tag used for the first time joins the Tags section.
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .tagsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .favoritesChanged, object: nil)
        for name in [Notification.Name.trashChanged, .operationLogChanged, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(trashMayHaveChanged), name: name, object: nil)
        }
    }

    func reload() {
        let favorites = [SidebarItem(title: String(localized: "Recents", comment: "Sidebar item: recently used files"), target: .recents, symbol: "clock")]
            + Places.favorites().map(SidebarItem.init)
        let pinned = Set(favorites.compactMap(\.url?.path))
        let home = Places.home.path
        let frequent = Frecency.shared.ranked()
            .filter { !pinned.contains($0.path) && $0.path != home && $0.path != "/" && !Trash.isTrash($0) }
            .prefix(5)
            .map { SidebarItem(Place(title: FileManager.default.displayName(atPath: $0.path), url: $0, symbol: "folder")) }
        sections = [SidebarSection(id: "favorites", title: String(localized: "Favorites", comment: "Sidebar section title"), items: favorites)]
        let searches = SavedSearches.all.map { SidebarItem(title: $0.name, target: .search($0), symbol: "magnifyingglass") }
        if !searches.isEmpty {
            sections.append(SidebarSection(id: "searches", title: String(localized: "Searches", comment: "Sidebar section title: saved searches"), items: searches))
        }
        if !frequent.isEmpty {
            sections.append(SidebarSection(id: "frequent", title: String(localized: "Frequent", comment: "Sidebar section title: folders you open often"),
                                           items: Array(frequent)))
        }
        sections.append(SidebarSection(id: "insights", title: String(localized: "Insights", comment: "Sidebar section title: Large Files and Duplicates"), items: [
            SidebarItem(title: String(localized: "Large Files", comment: "Sidebar item"), target: .largeFiles, symbol: "externaldrive.badge.exclamationmark"),
            SidebarItem(title: String(localized: "Duplicates", comment: "Sidebar item: identical files"), target: .duplicates, symbol: "square.on.square"),
        ]))
        sections.append(SidebarSection(id: "locations", title: String(localized: "Locations", comment: "Sidebar section title: disks and the Trash"),
                                       items: Places.volumes().map(SidebarItem.init)
            + [SidebarItem(title: String(localized: "Trash", comment: "Sidebar item: the Trash"), target: .folder(Trash.home), symbol: Self.trashSymbol)]))
        // Finder's Tags: the colored ones, then others you've used here. Each shows everything with that tag (Spotlight).
        let tags = TagStore.shared.suggestions.prefix(12).map { tag in
            let item = SidebarItem(title: tag.shownName, target: .search(SavedSearch(name: tag.name, query: SpotlightQuery.term(forTag: tag.name), scopePath: nil)),
                                   symbol: tag.displayColor == nil ? "circle" : "circle.fill")
            item.tint = tag.displayColor ?? .secondaryLabelColor
            item.tagName = tag.name
            return item
        }
        if !tags.isEmpty { sections.append(SidebarSection(id: "tags", title: String(localized: "Tags", comment: "Sidebar section title: Finder tags"), items: Array(tags))) }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        if let current { highlight(current) }
    }

    /// Selects the row for `target` (or nothing) without navigating.
    func highlight(_ target: SidebarTarget?) {
        current = target
        var row = -1
        for section in sections {
            if let item = section.items.first(where: { Self.matches($0.target, target) }) {
                row = outline.row(forItem: item)
                break
            }
        }
        suppressSelection = true
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        suppressSelection = false
    }

    @objc private func volumesChanged() { reload() }

    private static func matches(_ a: SidebarTarget, _ b: SidebarTarget?) -> Bool {
        switch (a, b) {
        case (.folder(let x), .folder(let y)?): x.standardizedFileURL.path == y.standardizedFileURL.path
        case (.recents, .recents?), (.duplicates, .duplicates?), (.largeFiles, .largeFiles?): true
        case (.search(let x), .search(let y)?): x == y
        default: false
        }
    }

    @objc private func removeSearch(_ sender: NSMenuItem) {
        guard let search = sender.representedObject as? SavedSearchBox else { return }
        SavedSearches.all.removeAll { $0 == search.search }
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let section = item as? SidebarSection { return section.items.count }
        return item == nil ? sections.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? SidebarSection { return section.items[index] }
        return sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarItem
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        item is SidebarItem ? SidebarRowView() : nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let id = NSUserInterfaceItemIdentifier("Header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let item = item as? SidebarItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("Item")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCellView ?? {
            let cell = SidebarCellView()
            cell.identifier = id
            return cell
        }()
        cell.configure(title: item.title, symbol: item.symbol, tint: item.tint)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let item = outline.item(atRow: outline.selectedRow) as? SidebarItem else { return }
        onSelect?(item.target)
    }

    // Favorites can be dragged to reorder them (a private type, so they never move folders on disk).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem, let url = item.url, isFavorite(item) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.path, forType: .sidebarFavorite)
        return pasteboardItem
    }

    private var favoritesSection: SidebarSection? { sections.first { $0.id == "favorites" } }

    private func isFavorite(_ item: SidebarItem) -> Bool {
        item.url != nil && favoritesSection?.items.contains { $0 === item } == true
    }

    /// Where between the favorites a drop lands (Recents stays first), or nil when it isn't between them.
    private func favoriteIndex(_ item: Any?, _ childIndex: Int) -> Int? {
        guard let section = item as? SidebarSection, section === favoritesSection, childIndex != NSOutlineViewDropOnItemIndex
        else { return nil }
        return max(0, childIndex - 1)
    }

    // Folders dropped between favorites are added there; files dropped on a location move or copy with Finder's rules
    // (shared with every view): move on the same disk, copy onto another one, Option copies.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // Files resting on a location spring it open; reordering favorites doesn't.
        let isReorder = info.draggingPasteboard.string(forType: .sidebarFavorite) != nil
        let urls = isReorder ? [] : FileDrop.urls(info)
        let resting = index == NSOutlineViewDropOnItemIndex ? (item as? SidebarItem)?.url : nil
        springLoader.hover(resting.flatMap { folder in
            // A favorite can be a package (an app): springing would open its insides. Dropping on the Trash trashes.
            urls.isEmpty || FileDrop.isInside(urls, folder) || NSWorkspace.shared.isFilePackage(atPath: folder.path)
                || Trash.isTrash(folder) || !SpringLoader.canOpen(folder, browsing: nil) ? nil : folder
        }, drag: info.draggingSequenceNumber)
        if isReorder {
            if favoriteIndex(item, index) != nil { return .move }
            // Reordering only: retarget a drop anywhere else in Favorites to just below its first row.
            if let favorite = item as? SidebarItem, isFavorite(favorite),
               let row = favoritesSection?.items.firstIndex(where: { $0 === favorite }) {
                outlineView.setDropItem(favoritesSection, dropChildIndex: max(1, row))
                return .move
            }
            return []
        }
        if favoriteIndex(item, index) != nil {
            let folders = urls.filter { TransferEngine.isPlainFolder($0) || $0.hasDirectoryPath }
            return folders.isEmpty ? [] : .link
        }
        guard let target = (item as? SidebarItem)?.url, index == NSOutlineViewDropOnItemIndex else { return [] }
        if Trash.isTrash(target) {
            if let verdict = trashVerdict, verdict.drag == info.draggingSequenceNumber { return verdict.operation }
            // Not what's already in a Trash, a Trash itself, or a whole disk.
            let refused = urls.isEmpty || urls.contains { url in
                Trash.isInTrash(url) || Trash.isTrash(url) || (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
            }
            trashVerdict = (info.draggingSequenceNumber, refused ? [] : .delete)
            return refused ? [] : .delete
        }
        return FileDrop.operation(urls, into: target, info: info)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        if let at = favoriteIndex(item, index) {
            if let path = info.draggingPasteboard.string(forType: .sidebarFavorite) {
                Places.addFavorites([URL(fileURLWithPath: path)], at: at)
            } else {
                Places.addFavorites(FileDrop.urls(info), at: at)
            }
            return true
        }
        guard let target = (item as? SidebarItem)?.url else { return false }
        let urls = FileDrop.urls(info)
        if Trash.isTrash(target) {
            moveToTrash(urls)
            return !urls.isEmpty
        }
        let operation = FileDrop.operation(urls, into: target, info: info)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        TransferQueue.shared.enqueue(urls, to: target, mode: operation == .move ? .move : .copy,
                                     undo: view.window?.undoManager, conflicts: .sheet(for: view.window))
        return true
    }
}

/// Finder-style selection: a soft gray rounded highlight, with the label keeping its normal color.
final class SidebarRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 10, dy: 1)
        NSColor.labelColor.withAlphaComponent(effectiveAppearance.isHighContrast ? 0.25 : 0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

/// Finder's macOS 26 look: monochrome symbol and label that keep their color when selected.
final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// Explicit colors: the source-list style recolors the semantic label color with the accent on selection.
    /// Fully opaque with Increase Contrast.
    private static let ink = NSColor.ink(light: 0.85, dark: 0.9)
    private static let iconInk = NSColor.ink(light: 0.6, dark: 0.75)

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tint: NSColor?

    func configure(title: String, symbol: String, tint: NSColor? = nil) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.tint = tint
        // Tag dots are smaller than the other icons, like Finder's.
        icon.symbolConfiguration = .init(pointSize: tint == nil ? 14 : 10, weight: tint == nil ? .regular : .semibold)
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        label.textColor = Self.ink
        icon.contentTintColor = tint ?? Self.iconInk
    }
}

/// Right-click: folders and volumes open in a new tab, copy their path or eject; saved searches can be removed.
extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        // Tags you added can leave the sidebar; the seven colored ones stay, like Finder's.
        if item.tint != nil {
            let name = item.tagName ?? item.title
            let isStandard = FinderTag.standard.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if !isStandard {
                let remove = NSMenuItem(title: String(localized: "Remove “\(item.title)” from Sidebar"), action: #selector(forgetTag(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = name
                menu.addItem(remove)
            }
            return
        }
        if case .search(let search) = item.target {
            let remove = NSMenuItem(title: String(localized: "Remove “\(search.name)”", comment: "Sidebar menu: remove a saved search"), action: #selector(removeSearch(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = SavedSearchBox(search: search)
            menu.addItem(remove)
            return
        }
        guard let url = item.url else { return }
        if Trash.isTrash(url) {
            add("Open in New Tab", #selector(openInNewTab(_:)), url)
            menu.addItem(.separator())
            let empty = NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "")
            menu.addItem(empty)
            return
        }
        let favorite = isFavorite(item)
        add("Open in New Tab", #selector(openInNewTab(_:)), url)
        add("Copy Path", #selector(copyItemPath(_:)), url)
        menu.addItem(.separator())
        if favorite {
            add("Remove from Sidebar", #selector(removeFavorite(_:)), url)
        } else if !item.isEjectable {
            add("Add to Favorites", #selector(addFavorite(_:)), url)
        }
        if item.isEjectable {
            menu.addItem(.separator())
            add("Eject “\(item.title)”", #selector(ejectItem(_:)), url)
        }
    }

    private func add(_ title: String.LocalizationValue, _ action: Selector, _ url: URL) {
        let entry = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = url
        outline.menu?.addItem(entry)
    }

    /// Full or empty, like the Dock's (empty when Strata can't look: that needs Full Disk Access).
    private static var trashSymbol: String { Trash.isHomeEmpty ? "trash" : "trash.fill" }

    @objc private func trashMayHaveChanged() {
        guard let item = sections.lazy.flatMap(\.items).first(where: { $0.url == Trash.home }),
              item.symbol != Self.trashSymbol else { return }
        item.symbol = Self.trashSymbol
        outline.reloadItem(item)
    }

    /// Files dropped on the Trash go there like ⌘⌫: undoable, in History, and Put Back knows where they came from.
    private func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let window = view.window
        Task { @MainActor in
            do {
                try await FileOps.trashInBackground(urls, undo: window?.undoManager)
            } catch let noTrash as FileOps.NoTrash {
                BrowserViewController.confirmDelete(noTrash.urls, in: window, noTrash: true) {}
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }

    @objc private func forgetTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        TagStore.shared.forget(name)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    @objc private func copyItemPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.removeFavorite(url)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.addFavorites([url])
    }

    @objc private func ejectItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.eject(url, from: view.window)
    }
}

final class SavedSearchBox: NSObject {
    let search: SavedSearch
    init(search: SavedSearch) { self.search = search }
}

/// The sidebar's outline, telling the controller when a drag leaves or ends (to stop spring loading).
final class SidebarOutlineView: NSOutlineView {
    var onDragEnd: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragEnd?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDragEnd?()
    }
}
