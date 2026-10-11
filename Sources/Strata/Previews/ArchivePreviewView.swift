import AppKit
import UniformTypeIdentifiers

/// The contents of a zip or tar archive as an expandable tree, without extracting anything.
final class ArchivePreviewView: PreviewView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var root = ArchiveNode(name: "", isDirectory: true)
    private var icons: [String: NSImage] = [:]
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    private let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))

    init(url: URL, kind: ArchiveKind) {
        super.init(frame: .zero)
        configure()
        load({ try await ArchiveLister.list(url, kind: kind) }) { [weak self] listing in
            self?.show(listing)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        nameColumn.minWidth = 120
        nameColumn.headerCell = GridLeadingHeaderCell()
        nameColumn.title = "Name"
        sizeColumn.headerCell = GridHeaderCell()
        sizeColumn.title = "Size"
        sizeColumn.width = 72
        sizeColumn.minWidth = 56
        sizeColumn.headerCell.alignment = .right
        dateColumn.headerCell = GridHeaderCell()
        dateColumn.title = "Date Modified"
        dateColumn.width = 150
        dateColumn.minWidth = 90
        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(sizeColumn)
        outlineView.addTableColumn(dateColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.style = .plain
        outlineView.rowHeight = 22
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 14
        outlineView.backgroundColor = .clear
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = false
        outlineView.focusRingType = .none
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // Names take whatever the size (and, when there's room, date) columns leave.
        dateColumn.isHidden = bounds.width < 440
        let fixed = sizeColumn.width + (dateColumn.isHidden ? 0 : dateColumn.width)
        nameColumn.width = max(nameColumn.minWidth, scrollView.contentSize.width - fixed)
    }

    private func show(_ listing: ArchiveListing) {
        root = listing.root.value
        outlineView.reloadData()
        // Archives usually wrap everything in one folder; open it (and any single folder inside it).
        var node = root
        while node.children.count == 1, let only = node.children.first, only.isDirectory {
            outlineView.expandItem(only)
            node = only
        }
        if root.children.count + node.children.count <= 12 {
            for child in node.children where child.isDirectory { outlineView.expandItem(child) }
        }
        var parts = [listing.files == 1 ? "1 file" : "\(listing.files.formatted()) files"]
        if listing.folders > 0 { parts.append(listing.folders == 1 ? "1 folder" : "\(listing.folders.formatted()) folders") }
        parts.append(Format.bytes(listing.uncompressed))
        let note = listing.note ?? listing.compressed.map { "\(Format.bytes($0)) compressed" }
        footer.show(parts, note: note)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? ArchiveNode) ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? ArchiveNode) ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ArchiveNode)?.isDirectory == true && !((item as? ArchiveNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveNode, let tableColumn else { return nil }
        switch tableColumn.identifier.rawValue {
        case "name":
            let identifier = NSUserInterfaceItemIdentifier("ArchiveName")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ArchiveNameCell ?? ArchiveNameCell()
            cell.identifier = identifier
            cell.configure(name: node.name, icon: icon(for: node))
            return cell
        default:
            let identifier = NSUserInterfaceItemIdentifier("ArchiveDetail")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? GridCellView ?? GridCellView()
            cell.identifier = identifier
            let isSize = tableColumn.identifier.rawValue == "size"
            let text = isSize ? Format.bytes(node.size) : node.modified.map { Format.date($0) } ?? "—"
            cell.configure(.text(text), numeric: isSize, leading: false, secondary: true)
            return cell
        }
    }

    private func icon(for node: ArchiveNode) -> NSImage {
        let ext = node.isDirectory ? "/" : (node.name as NSString).pathExtension.lowercased()
        if let cached = icons[ext] { return cached }
        let type: UTType = node.isDirectory ? .folder : UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        icons[ext] = image
        return image
    }
}

/// Small icon and file name, for the archive tree.
final class ArchiveNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, icon image: NSImage) {
        label.stringValue = name
        icon.image = image
    }
}
