import AppKit

/// Compare with Other Pane: the differences between the two panes' folders, what a sync would do with each (changeable
/// per row), and Sync. Copies run in the Transfers list, verified, with undo and History; what a mirror removes goes to
/// the Trash.
final class CompareController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let left: URL
    private let right: URL
    private weak var undo: UndoManager?

    private var differences: [FolderCompare.Difference] = []
    private var shown: [FolderCompare.Difference] = []
    private var actions: [String: FolderCompare.Action] = [:]
    private var control: FolderCompare.Control?
    private var lastResult: FolderCompare.Result?

    private let contents = NSButton(checkboxWithTitle: "Compare contents", target: nil, action: nil)
    private let filter = NSPopUpButton()
    private let direction = NSPopUpButton()
    private let mirror = NSButton(checkboxWithTitle: "Move extras to the Trash", target: nil, action: nil)
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let syncButton = NSButton(title: "Sync", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private enum Filter: Int, CaseIterable {
        case all, onlyLeft, onlyRight, newer, changed

        var title: String {
            switch self {
            case .all: "All Differences"
            case .onlyLeft: "Only on the Left"
            case .onlyRight: "Only on the Right"
            case .newer: "Newer on One Side"
            case .changed: "Different, Same Date"
            }
        }

        func includes(_ kind: FolderCompare.Kind) -> Bool {
            switch self {
            case .all: true
            case .onlyLeft: kind == .onlyLeft
            case .onlyRight: kind == .onlyRight
            case .newer: kind == .leftNewer || kind == .rightNewer
            case .changed: kind == .changed || kind == .kindsDiffer
            }
        }
    }

    init(left: URL, right: URL, undo: UndoManager?) {
        self.left = left
        self.right = right
        self.undo = undo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Compare Folders")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        // The folders by name (both always visible); where they are, on hover.
        let sides = NSTextField(labelWithString: "“\(left.lastPathComponent)” (left)   ⇄   “\(right.lastPathComponent)” (right)")
        sides.font = .systemFont(ofSize: 12)
        sides.textColor = .secondaryLabelColor
        sides.lineBreakMode = .byTruncatingMiddle
        sides.toolTip = "Left: \(Format.tildePath(left))\nRight: \(Format.tildePath(right))"
        sides.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contents.target = self
        contents.action = #selector(rescan(_:))
        contents.toolTip = "Read files of the same size to find ones whose contents differ (slower)"
        for item in Filter.allCases { filter.addItem(withTitle: item.title) }
        filter.target = self
        filter.action = #selector(filterChanged(_:))
        filter.setAccessibilityLabel("Show")
        for item in FolderCompare.Direction.allCases { direction.addItem(withTitle: item.title) }
        direction.target = self
        direction.action = #selector(directionChanged(_:))
        direction.setAccessibilityLabel("Sync direction")
        mirror.target = self
        mirror.action = #selector(directionChanged(_:))
        mirror.isEnabled = false
        mirror.toolTip = "One-way syncs only: items only on the side being synced to go to the Trash, so both sides match"
        let syncLabel = NSTextField(labelWithString: "Sync:")
        let showLabel = NSTextField(labelWithString: "Show:")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let options = NSStackView(views: [showLabel, filter, contents, spacer, syncLabel, direction, mirror])
        options.spacing = 8

        for (id, title, width) in [("status", "", 26.0), ("path", "Item", 280.0), ("left", "Left: \(left.lastPathComponent)", 150.0),
                                   ("action", "Sync", 140.0), ("right", "Right: \(right.lastPathComponent)", 150.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "status" ? 26 : 80
            if id == "status" { column.maxWidth = 26 }
            table.addTableColumn(column)
        }
        table.rowHeight = 26
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Differences")
        // Right-click (or the keyboard's menu) sets what the selected rows do, all at once.
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.keyEquivalent = "\u{1b}"
        syncButton.target = self
        syncButton.action = #selector(sync(_:))
        syncButton.keyEquivalent = "\r"
        syncButton.isEnabled = false
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spinner, summary, footerSpacer, closeButton, syncButton])
        footer.spacing = 8

        let stack = NSStackView(views: [title, sides, options, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 800),
            sides.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = container
        runComparison()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        control?.cancel()
    }

    // MARK: - Comparing

    @objc private func rescan(_ sender: Any?) {
        runComparison()
    }

    private func runComparison() {
        control?.cancel()
        let control = FolderCompare.Control()
        self.control = control
        differences = []
        shown = []
        table.reloadData()
        syncButton.isEnabled = false
        spinner.startAnimation(nil)
        summary.stringValue = "Comparing…"
        let left = left, right = right, contents = contents.state == .on, hidden = Prefs.showHidden
        let progress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in
                guard let self, self.control === control else { return }
                self.summary.stringValue = "Comparing… \(count.formatted()) items"
            }
        }
        Task { [weak self] in
            let result = await FolderCompare.compare(left, right, contents: contents, includeHidden: hidden, control: control,
                                                     progress: progress)
            guard let self, self.control === control, !result.cancelled else { return }
            show(result)
        }
    }

    private func show(_ result: FolderCompare.Result) {
        spinner.stopAnimation(nil)
        lastResult = result
        differences = result.differences
        resetActions()
        applyFilter()
    }

    /// Every row back to what the chosen sync does by default.
    private func resetActions() {
        let way = FolderCompare.Direction(rawValue: direction.indexOfSelectedItem) ?? .bothWays
        let mirrors = way != .bothWays && mirror.state == .on
        actions = Dictionary(uniqueKeysWithValues: differences.map {
            ($0.id, FolderCompare.defaultAction(for: $0.kind, direction: way, mirror: mirrors))
        })
    }

    @objc private func filterChanged(_ sender: Any?) {
        applyFilter()
    }

    @objc private func directionChanged(_ sender: Any?) {
        mirror.isEnabled = direction.indexOfSelectedItem != FolderCompare.Direction.bothWays.rawValue
        resetActions()
        table.reloadData()
        updateSummary()
    }

    private func applyFilter() {
        let chosen = Filter(rawValue: filter.indexOfSelectedItem) ?? .all
        shown = differences.filter { chosen.includes($0.kind) }
        table.reloadData()
        updateSummary()
    }

    private func updateSummary() {
        guard let result = lastResult else { return }
        if let failure = result.failure {
            summary.stringValue = failure
            syncButton.isEnabled = false
            return
        }
        if differences.isEmpty {
            summary.stringValue = result.truncated
                ? "No differences in the first \(FolderCompare.itemLimit.formatted()) items of each side"
                : "The folders match (\(Format.count(result.identical, "item", "items")) compared)"
            syncButton.isEnabled = false
            return
        }
        let chosen = differences.compactMap { actions[$0.id] }
        let right = chosen.filter { $0 == .copyRight }.count
        let left = chosen.filter { $0 == .copyLeft }.count
        let trashed = chosen.filter { $0 == .trashLeft || $0 == .trashRight }.count
        var parts = [Format.count(differences.count, "difference", "differences")]
        if right > 0 { parts.append("\(right.formatted()) to copy →") }
        if left > 0 { parts.append("\(left.formatted()) to copy ←") }
        if trashed > 0 { parts.append("\(trashed.formatted()) to the Trash") }
        let unknown = differences.filter { $0.kind == .unknown }.count
        if unknown > 0 { parts.append("\(unknown.formatted()) can’t be compared") }
        // A partial list can't be synced: what it doesn't show could be overwritten or trashed by mistake.
        if result.truncated { parts.append("too many items to sync: only the first \(FolderCompare.itemLimit.formatted()) of each side were compared") }
        summary.stringValue = parts.joined(separator: " · ")
        syncButton.isEnabled = right + left + trashed > 0 && result.isComplete
        syncButton.title = right + left + trashed > 0 ? "Sync \(Format.count(right + left + trashed, "Item", "Items"))" : "Sync"
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, row < shown.count else { return nil }
        let difference = shown[row]
        switch column {
        case "status":
            let image = reuse(tableView, "status") { NSImageView() }
            image.image = NSImage(systemSymbolName: difference.kind.symbol, accessibilityDescription: difference.kind.title)
            image.contentTintColor = [.changed, .kindsDiffer, .unknown].contains(difference.kind) ? .systemOrange : .secondaryLabelColor
            image.toolTip = difference.note ?? difference.kind.title
            return image
        case "path":
            let field = reuse(tableView, "path") { Self.label() }
            field.stringValue = difference.id
            field.toolTip = "\(difference.id) — \(difference.note ?? difference.kind.title)"
            let isFolder = (difference.left ?? difference.right)?.isDirectory == true
            field.font = isFolder ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingMiddle
            return field
        case "left", "right":
            let field = reuse(tableView, "side") { Self.label() }
            let item = column == "left" ? difference.left : difference.right
            field.stringValue = item.map(Self.describe) ?? "—"
            field.font = .systemFont(ofSize: 11)
            let newer = (column == "left" && difference.kind == .leftNewer) || (column == "right" && difference.kind == .rightNewer)
            field.textColor = newer ? .labelColor : .secondaryLabelColor
            return field
        case "action":
            let popup = reuse(tableView, "action") { () -> NSPopUpButton in
                let popup = NSPopUpButton()
                popup.controlSize = .small
                popup.font = .systemFont(ofSize: 11)
                popup.isBordered = false
                popup.target = self
                popup.action = #selector(actionChanged(_:))
                return popup
            }
            popup.removeAllItems()
            for action in FolderCompare.actions(for: difference.kind) {
                popup.addItem(withTitle: action.title)
                popup.lastItem?.tag = action.rawValue
            }
            popup.selectItem(withTag: (actions[difference.id] ?? .skip).rawValue)
            popup.isEnabled = difference.kind != .unknown
            popup.setAccessibilityLabel("Sync \(difference.id)")
            return popup
        default:
            return nil
        }
    }

    /// A cell from the table's pool (scrolling thousands of rows makes no new views), or a new one.
    private func reuse<View: NSView>(_ tableView: NSTableView, _ kind: String, make: () -> View) -> View {
        let id = NSUserInterfaceItemIdentifier("compare." + kind)
        if let view = tableView.makeView(withIdentifier: id, owner: nil) as? View { return view }
        let view = make()
        view.identifier = id
        return view
    }

    private static func label() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func describe(_ item: FolderCompare.Item) -> String {
        let date = item.modified.formatted(date: .abbreviated, time: .shortened)
        if item.isLink { return "Link · \(date)" }
        if item.isDirectory { return "Folder · \(date)" }
        return "\(Format.bytes(item.size)) · \(date)"
    }

    @objc private func actionChanged(_ sender: NSPopUpButton) {
        let row = table.row(for: sender)
        guard row >= 0, let action = FolderCompare.Action(rawValue: sender.selectedTag()) else { return }
        // Several rows selected, one of them changed: they all follow (where that choice fits).
        set(action, rows: table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: row))
    }

    private func set(_ action: FolderCompare.Action, rows: IndexSet) {
        for index in rows where index < shown.count {
            let difference = shown[index]
            if FolderCompare.actions(for: difference.kind).contains(action) { actions[difference.id] = action }
        }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: table.column(withIdentifier: .init("action"))))
        updateSummary()
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = FolderCompare.Action(rawValue: sender.tag) else { return }
        let clicked = table.clickedRow
        let rows = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        set(action, rows: rows)
    }

    // MARK: - Syncing

    @objc private func close(_ sender: Any?) {
        control?.cancel()
        dismiss(nil)
    }

    @objc private func sync(_ sender: Any?) {
        guard lastResult?.isComplete == true else { return }
        var toRight: [TransferMove] = [], toLeft: [TransferMove] = [], trashLeft: [URL] = [], trashRight: [URL] = []
        var replacesOtherKind = 0
        for difference in differences {
            let l = left.appending(path: difference.leftPath), r = right.appending(path: difference.rightPath)
            let action = actions[difference.id] ?? .skip
            if difference.kind == .kindsDiffer, action == .copyRight || action == .copyLeft { replacesOtherKind += 1 }
            switch action {
            case .copyRight: toRight.append(TransferMove(from: l, to: r))
            case .copyLeft: toLeft.append(TransferMove(from: r, to: l))
            case .trashLeft: trashLeft.append(l)
            case .trashRight: trashRight.append(r)
            case .skip: break
            }
        }
        let trash = trashLeft + trashRight
        guard !(toRight.isEmpty && toLeft.isEmpty && trash.isEmpty), let window = view.window else { return }
        let count = toRight.count + toLeft.count + trash.count
        let leftName = "“\(left.lastPathComponent)” on the left", rightName = "“\(right.lastPathComponent)” on the right"
        let alert = NSAlert()
        alert.messageText = "Sync \(Format.count(count, "item", "items"))?"
        var lines: [String] = []
        if !toRight.isEmpty { lines.append("\(Format.count(toRight.count, "item", "items")) copied to \(rightName)") }
        if !toLeft.isEmpty { lines.append("\(Format.count(toLeft.count, "item", "items")) copied to \(leftName)") }
        if !trashRight.isEmpty { lines.append("\(Format.count(trashRight.count, "item", "items")) in \(rightName) moved to the Trash") }
        if !trashLeft.isEmpty { lines.append("\(Format.count(trashLeft.count, "item", "items")) in \(leftName) moved to the Trash") }
        if replacesOtherKind > 0 {
            lines.append("\(Format.count(replacesOtherKind, "item replaces", "items replace")) a file with a folder or a folder with a file")
        }
        let hidden = differences.count - shown.count
        if hidden > 0 { lines.append("(This includes rows the Show menu hides.)") }
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\nWhatever a copy replaces goes to the Trash first. Copies are checked after they’re written. Edit ▸ Undo undoes the copies and the Trash step separately."
        alert.addButton(withTitle: "Sync")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let undo = undo, left = left, right = right, parent = window.sheetParent
            dismiss(nil)
            Task { @MainActor in
                // Extras go first, so nothing a copy writes can be trashed after it.
                if !trash.isEmpty {
                    do {
                        try await FileOps.trashInBackground(trash, undo: undo)
                    } catch {
                        let failed = NSAlert(error: error)
                        failed.messageText = "Some items couldn’t be moved to the Trash, so the sync stopped there."
                        if let parent { failed.beginSheetModal(for: parent, completionHandler: nil) }
                        return
                    }
                }
                var options = TransferEngine.Options()
                options.verify = true
                if !toRight.isEmpty {
                    TransferQueue.shared.enqueue(moves: toRight, destination: right, mode: .copy, options: options, undo: undo,
                                                 conflicts: .replace, actionName: "Sync")
                }
                if !toLeft.isEmpty {
                    TransferQueue.shared.enqueue(moves: toLeft, destination: left, mode: .copy, options: options, undo: undo,
                                                 conflicts: .replace, actionName: "Sync")
                }
            }
        }
    }
}

extension CompareController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        let rows = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        let kinds = Set(rows.compactMap { $0 < shown.count ? shown[$0].kind : nil })
        let possible = FolderCompare.Action.allCases.filter { action in kinds.contains { FolderCompare.actions(for: $0).contains(action) } }
        for action in possible {
            let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            menu.addItem(item)
        }
    }
}
