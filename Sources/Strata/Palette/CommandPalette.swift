import AppKit

/// One thing the palette can do: jump to a folder, open a file, or run a command.
struct PaletteItem {
    enum Kind: String {
        case folder = "Folder"
        case file = "Here"
        case action = "Command"
        case path = "Go to"
        case match = "File"
    }

    let title: String
    let subtitle: String
    let icon: NSImage
    let kind: Kind
    var shortcut: String? = nil
    /// Added to the fuzzy score; frequently visited folders get more.
    var boost: Int = 0
    /// For items produced for a specific query (path lookups): their score and highlighted title characters.
    var fixedScore: Int? = nil
    var titleMatches: [Int] = []
    /// The file or folder this item opens, to avoid listing it twice.
    var url: URL? = nil
    let run: () -> Void
}

/// ⌘K: a floating glass panel that fuzzy-searches folders you visit, items in this folder, and every command.
final class CommandPalette: NSObject {
    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private var source: [PaletteItem] = []
    private var results: [(item: PaletteItem, matches: [Int])] = []
    private var scored: [(item: PaletteItem, matches: [Int], score: Int)] = []
    private var lateResults: Task<Void, Never>?
    private weak var parent: NSWindow?

    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 8
    private static let fieldHeight: CGFloat = 58
    private static let width: CGFloat = 660

    override init() {
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                             styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.delegate = self
        buildContent()
    }

    var isVisible: Bool { panel.isVisible }

    func show(in window: NSWindow, items: [PaletteItem]) {
        parent = window
        source = items
        field.stringValue = ""
        update()
        let frame = window.frame
        let height = panel.frame.height
        panel.setFrame(NSRect(x: frame.midX - Self.width / 2, y: frame.maxY - 110 - height, width: Self.width, height: height),
                       display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    // MARK: - Layout

    private func buildContent() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 22

        let content = NSView()
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = "Jump to a folder (try github/acme), open a file, or run a command…"
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.refusesFirstResponder = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.documentView = table

        content.addSubview(icon)
        content.addSubview(field)
        content.addSubview(separator)
        content.addSubview(scroll)
        heightConstraint = content.heightAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            heightConstraint,
            content.widthAnchor.constraint(equalToConstant: Self.width),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        glass.contentView = content
        panel.contentView = glass
    }

    // MARK: - Results

    private func update() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        lateResults?.cancel()
        if query.isEmpty {
            scored = []
            results = source.filter { $0.kind == .folder }.prefix(7).map { ($0, []) }
                + source.filter { $0.kind == .action }.prefix(5).map { ($0, []) }
        } else {
            scored = []
            if let path = pathItem(for: query) { scored.append((path, [], 1000)) }
            if PathQuery.isPathQuery(query) {
                for item in queryItems?(query) ?? [] { scored.append((item, item.titleMatches, item.fixedScore ?? 0)) }
            }
            for item in source {
                if let match = Fuzzy.match(query, item.title) {
                    scored.append((item, match.indices, match.score + item.boost))
                } else if item.kind == .folder, let match = Fuzzy.match(query, item.subtitle) {
                    scored.append((item, [], match.score / 2 + item.boost - 10))
                }
            }
            scored.sort { $0.score > $1.score }
            results = scored.prefix(60).map { ($0.item, $0.matches) }
            if let lateItems {
                lateResults = Task { [weak self] in
                    let extra = await lateItems(query)
                    guard let self, !Task.isCancelled,
                          self.field.stringValue.trimmingCharacters(in: .whitespaces) == query else { return }
                    self.merge(extra)
                }
            }
        }
        showResults()
    }

    private func merge(_ extra: [PaletteItem]) {
        let known = Set(scored.compactMap { $0.item.url?.standardizedFileURL.path })
        let fresh = extra.filter { item in item.url.map { !known.contains($0.standardizedFileURL.path) } ?? true }
        guard !fresh.isEmpty else { return }
        let selectedTitle = table.selectedRow >= 0 && table.selectedRow < results.count ? results[table.selectedRow].item.title : nil
        scored += fresh.map { ($0, $0.titleMatches, $0.fixedScore ?? 0) }
        scored.sort { $0.score > $1.score }
        results = scored.prefix(60).map { ($0.item, $0.matches) }
        showResults(keeping: selectedTitle)
    }

    private func showResults(keeping selectedTitle: String? = nil) {
        table.reloadData()
        let keep = selectedTitle.flatMap { title in results.firstIndex { $0.item.title == title } } ?? 0
        if !results.isEmpty { table.selectRowIndexes([keep], byExtendingSelection: false) }
        table.scrollRowToVisible(keep)

        let rows = CGFloat(min(results.count, Self.maxVisibleRows))
        let height = Self.fieldHeight + (rows > 0 ? rows * Self.rowHeight + 14 : 0)
        heightConstraint.constant = height
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Typing a path (`~/…` or `/…`) offers to go straight there.
    private func pathItem(for query: String) -> PaletteItem? {
        guard query.hasPrefix("/") || query.hasPrefix("~") else { return nil }
        let path = (query as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: path)
        return PaletteItem(title: Format.tildePath(url), subtitle: isDirectory.boolValue ? "Open folder" : "Reveal file",
                           icon: IconCache.shared.icon(forPath: path), kind: .path) { [weak self] in self?.goToPath?(url) }
    }

    /// Set by the owner: navigates to a typed path (folders open, files are revealed).
    var goToPath: ((URL) -> Void)?
    /// Set by the owner: items computed for the current query, such as `github/acme` path lookups.
    var queryItems: ((String) -> [PaletteItem])?
    /// Set by the owner: slower items (index search) merged in when they arrive.
    var lateItems: ((String) async -> [PaletteItem])?

    private func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let item = results[row].item
        close()
        item.run()
    }

    @objc private func rowClicked() {
        runSelected()
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

extension CommandPalette: NSTextFieldDelegate, NSWindowDelegate {
    func controlTextDidChange(_ notification: Notification) {
        update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("PaletteCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteCell ?? {
            let cell = PaletteCell()
            cell.identifier = id
            return cell
        }()
        cell.configure(results[row].item, matches: results[row].matches)
        cell.isRowSelected = row == tableView.selectedRow
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRow
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? PaletteCell)?.isRowSelected = row == selected
        }
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PaletteCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")
    /// The title sits above center with a subtitle, centered without one.
    private var titleAboveSubtitle: NSLayoutConstraint!
    private var titleCentered: NSLayoutConstraint!
    private var item: PaletteItem?
    private var matches: [Int] = []
    /// The palette's selection is a gray highlight (the field keeps focus), so the cell tracks it itself.
    var isRowSelected = false {
        didSet { if isRowSelected != oldValue { render() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, subtitle, accessory] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        accessory.font = .systemFont(ofSize: 11, weight: .medium)
        accessory.alignment = .right
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleAboveSubtitle = title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        titleCentered = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleAboveSubtitle,
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: PaletteItem, matches: [Int]) {
        self.item = item
        self.matches = matches
        icon.image = item.icon
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        guard let item else { return }
        let selected = isRowSelected
        let primary: NSColor = .labelColor
        let secondary: NSColor = .secondaryLabelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: primary, .paragraphStyle: paragraph,
        ])
        let characters = Array(item.title)
        var offsets: [Int] = []
        var offset = 0
        for c in characters {
            offsets.append(offset)
            offset += c.utf16.count
        }
        for i in matches where i < characters.count {
            text.addAttributes([.font: NSFont.systemFont(ofSize: 14, weight: .bold),
                                .foregroundColor: selected ? primary : NSColor.controlAccentColor],
                               range: NSRange(location: offsets[i], length: characters[i].utf16.count))
        }
        title.attributedStringValue = text
        subtitle.stringValue = item.subtitle
        subtitle.textColor = secondary
        subtitle.isHidden = item.subtitle.isEmpty
        titleAboveSubtitle.isActive = !item.subtitle.isEmpty
        titleCentered.isActive = item.subtitle.isEmpty
        accessory.stringValue = item.shortcut ?? item.kind.rawValue
        accessory.textColor = selected ? secondary : .tertiaryLabelColor
    }
}
