import AppKit
import StrataPreviews

/// Native, independent browsing inside a Space preview. AppKit owns expansion, selection and split-view sizing.
@MainActor final class PreviewBrowserController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let session: PreviewSession
    let outline = PreviewOutlineView()
    let fileView: PreviewFileView
    private let preferences: Prefs
    private let thumbnails: FileThumbnails
    private let copies: CopyProviders
    private let scroll = NSScrollView()
    private let split = NSSplitViewController()
    private let treeItem: NSSplitViewItem
    private let path = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let nameColumn = NSTableColumn(identifier: .init("previewName"))
    private let sizeColumn = NSTableColumn(identifier: .init("previewSize"))
    private let kindColumn = NSTableColumn(identifier: .init("previewKind"))
    private let dateColumn = NSTableColumn(identifier: .init("previewDate"))

    init(session: PreviewSession, preferences: Prefs, thumbnails: FileThumbnails, copies: CopyProviders) {
        self.session = session
        self.preferences = preferences
        self.thumbnails = thumbnails
        self.copies = copies
        fileView = PreviewFileView(thumbnails: thumbnails, copies: copies)
        let tree = NSViewController()
        tree.view = scroll
        treeItem = NSSplitViewItem(viewController: tree)
        super.init(nibName: nil, bundle: nil)
        let preview = NSViewController()
        preview.view = fileView
        treeItem.minimumThickness = 240
        treeItem.canCollapse = true
        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 220
        split.addSplitViewItem(treeItem)
        split.addSplitViewItem(previewItem)
        session.onChange = { [weak self] in self?.changed($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { preferences.notifications.removeObserver(self) }

    override func loadView() {
        view = NSView()
        ThemeStyle.bind(view, to: .content)
        configureOutline()
        preferences.notifications.addObserver(self, selector: #selector(appearanceChanged), name: .appearanceChanged, object: nil)
        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split.view)
        path.font = .systemFont(ofSize: 11)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let footer = NSStackView(views: [path, progress, status])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        ThemeStyle.bind(footer, to: .content)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        view.addSubview(separator)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: view.topAnchor), split.view.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor), separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func configureOutline() {
        nameColumn.title = String(localized: "Name", comment: "Column title")
        sizeColumn.title = String(localized: "Size", comment: "Column title")
        kindColumn.title = String(localized: "Kind", comment: "Column title")
        dateColumn.title = String(localized: "Date Modified", comment: "Column title")
        nameColumn.minWidth = 120
        nameColumn.width = 240
        sizeColumn.width = 80
        kindColumn.width = 110
        dateColumn.width = 140
        sizeColumn.headerCell.alignment = .right
        for column in [nameColumn, sizeColumn, kindColumn, dateColumn] {
            outline.addTableColumn(column)
            ThemeStyle.bind(column)
        }
        outline.outlineTableColumn = nameColumn
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.style = .inset
        outline.rowHeight = FileViewStyle.listHeight(for: preferences)
        outline.intercellSpacing = NSSize(width: 10, height: 0)
        outline.indentationPerLevel = 16
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self
        ThemeStyle.bind(outline, to: .content)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        ThemeStyle.bind(scroll, to: .content)
    }

    @objc private func appearanceChanged() {
        outline.rowHeight = FileViewStyle.listHeight(for: preferences)
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scroll.contentSize.width
        dateColumn.isHidden = width < 540
        kindColumn.isHidden = width < 660
        let fixed = sizeColumn.width + (dateColumn.isHidden ? 0 : dateColumn.width) + (kindColumn.isHidden ? 0 : kindColumn.width)
        nameColumn.width = max(nameColumn.minWidth, width - fixed - 4)
    }

    private func changed(_ change: PreviewSession.Change) {
        _ = view
        switch change {
        case .root:
            treeItem.isCollapsed = !session.isContainer
            outline.reloadData()
            fileView.show(nil, root: session.root)
            view.window?.title = session.root?.displayName ?? ""
        case .children(let item):
            let expanded = outline.isItemExpanded(item)
            outline.reloadItem(item, reloadChildren: true)
            if expanded { outline.expandItem(item) }
        case .selection:
            fileView.show(session.selected, root: session.root)
        }
        updateFooter()
    }

    private func updateFooter() {
        guard let root = session.root else { return }
        let url = session.selected?.entry?.url ?? root.url
        path.stringValue = copies.displayPath(url) ?? Format.tildePath(url)
        if session.isLoading {
            progress.startAnimation(nil)
            status.stringValue = String(localized: "Loading…")
        } else {
            progress.stopAnimation(nil)
            if let error = session.error {
                status.stringValue = error.localizedDescription
            } else if let archive = session.archive {
                status.stringValue = String(localized: "\(archive.files) files", comment: "plural") + " · " + Format.bytes(archive.uncompressed) + (archive.note.map { " · " + $0 } ?? "")
            } else if session.isContainer {
                status.stringValue = String(localized: "\(session.roots.count) items", comment: "plural")
            } else {
                status.stringValue = root.size.map(Format.bytes) ?? root.kind
            }
        }
    }

    func close() {
        session.close()
        fileView.close()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? PreviewItem else { return session.roots.count }
        if node.children == nil { session.expand(node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = (item as? PreviewItem)?.children ?? session.roots
        guard children.indices.contains(index) else { return item ?? self }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? PreviewItem else { return false }
        return node.isDirectory && (node.children?.isEmpty != true)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ThemeRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? PreviewItem, let column = tableColumn else { return nil }
        if column === nameColumn {
            let identifier = NSUserInterfaceItemIdentifier("previewNameCell")
            let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? NameCellView ?? NameCellView()
            cell.identifier = identifier
            let image = item.entry.map { thumbnails.icon(for: $0) }
                ?? IconCache.shared.icon(forType: item.isDirectory ? .folder : .data)
            cell.configure(name: item.name, icon: image, matches: [], dimmed: item.entry?.isHidden == true,
                           thumbnails: thumbnails, typography: FileViewTypography(preferences: preferences))
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("previewTextCell")
        let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? TextCellView ?? TextCellView()
        cell.identifier = identifier
        let text = column === sizeColumn ? item.size.map(Format.bytes) ?? "—"
            : column === dateColumn ? Format.date(item.modified) : item.kind
        cell.configure(text, alignment: column === sizeColumn ? .right : .left, dimmed: item.entry?.isHidden == true)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        session.select(outline.item(atRow: outline.selectedRow) as? PreviewItem)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? PreviewItem { session.collapse(item) }
    }
}

/// Space retains its usual preview meaning when the tree has focus; text controls handle their own typing.
@MainActor final class PreviewOutlineView: NSOutlineView {
    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty) {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}
