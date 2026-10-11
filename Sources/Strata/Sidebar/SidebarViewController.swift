import AppKit

final class SidebarSection {
    let title: String
    var items: [SidebarItem]

    init(title: String, items: [SidebarItem]) {
        self.title = title
        self.items = items
    }
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
    let symbol: String

    init(_ place: Place) {
        title = place.title
        target = .folder(place.url.standardizedFileURL)
        symbol = place.symbol
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

    private let outline = NSOutlineView()
    private var sections: [SidebarSection] = []
    private var suppressSelection = false
    private var current: SidebarTarget?

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
        outline.registerForDraggedTypes([.fileURL])
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
    }

    func reload() {
        let favorites = [SidebarItem(title: "Recents", target: .recents, symbol: "clock")] + Places.favorites().map(SidebarItem.init)
        let pinned = Set(favorites.compactMap(\.url?.path))
        let home = Places.home.path
        let frequent = Frecency.shared.ranked()
            .filter { !pinned.contains($0.path) && $0.path != home && $0.path != "/" }
            .prefix(5)
            .map { SidebarItem(Place(title: FileManager.default.displayName(atPath: $0.path), url: $0, symbol: "folder")) }
        sections = [SidebarSection(title: "Favorites", items: favorites)]
        let searches = SavedSearches.all.map { SidebarItem(title: $0.name, target: .search($0), symbol: "magnifyingglass") }
        if !searches.isEmpty { sections.append(SidebarSection(title: "Searches", items: searches)) }
        if !frequent.isEmpty { sections.append(SidebarSection(title: "Frequent", items: Array(frequent))) }
        sections.append(SidebarSection(title: "Insights", items: [
            SidebarItem(title: "Large Files", target: .largeFiles, symbol: "externaldrive.badge.exclamationmark"),
            SidebarItem(title: "Duplicates", target: .duplicates, symbol: "square.on.square"),
        ]))
        sections.append(SidebarSection(title: "Locations", items: Places.volumes().map(SidebarItem.init)))
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
        cell.configure(title: item.title, symbol: item.symbol)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let item = outline.item(atRow: outline.selectedRow) as? SidebarItem else { return }
        onSelect?(item.target)
    }

    // Drop files on a sidebar location to move them there (Option copies).
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard (item as? SidebarItem)?.url != nil, index == NSOutlineViewDropOnItemIndex else { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = (item as? SidebarItem)?.url,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
        TransferQueue.shared.enqueue(urls, to: target, mode: copy ? .copy : .move, undo: view.window?.undoManager,
                                     conflicts: .sheet(for: view.window))
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
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

/// Finder's macOS 26 look: monochrome symbol and label that keep their color when selected.
final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// Explicit colors: the source-list style recolors the semantic label color with the accent on selection.
    private static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
    }
    private static let iconInk = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.6)
    }

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

    func configure(title: String, symbol: String) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        label.textColor = Self.ink
        icon.contentTintColor = Self.iconInk
    }
}

/// Right-click on a saved search offers to remove it.
extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem, case .search(let search) = item.target else { return }
        let remove = NSMenuItem(title: "Remove “\(search.name)”", action: #selector(removeSearch(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = SavedSearchBox(search: search)
        menu.addItem(remove)
    }
}

final class SavedSearchBox: NSObject {
    let search: SavedSearch
    init(search: SavedSearch) { self.search = search }
}
