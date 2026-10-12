import AppKit

/// Edits the tags of one or more items in a token field with suggestions (Tags… in the context menu, and the
/// inspector). Shows the tags every item shares; adding one adds it to all of them, removing one removes it from all,
/// and each item keeps its other tags.
final class TagField: NSTokenField, NSTokenFieldDelegate {
    var urls: [URL] = [] {
        didSet { reload() }
    }
    weak var undo: UndoManager?
    /// Where errors are shown (a popover closing as they happen can't show them).
    weak var errorWindow: NSWindow?
    private var shown: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        tokenStyle = .rounded
        placeholderString = "Add Tags"
        font = .systemFont(ofSize: 12)
        completionDelay = 0
        cell?.wraps = true
        cell?.isScrollable = false
        setAccessibilityLabel("Tags")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// As tall as its tokens need at its width, so no tag hides past the first line.
    override var intrinsicContentSize: NSSize {
        guard let cell, bounds.width > 0 else { return super.intrinsicContentSize }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude))
        return NSSize(width: NSView.noIntrinsicMetric, height: max(24, ceil(size.height)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    func controlTextDidChange(_ notification: Notification) {
        invalidateIntrinsicContentSize()
    }

    /// Shows what the items have now (after a change elsewhere).
    func reload() {
        let sets = urls.map { Set(TagStore.shared.tags(for: $0).map { $0.name.lowercased() }) }
        let common = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
        // In the first item's order, which is the order they were added.
        shown = urls.first.map { TagStore.shared.tags(for: $0).map(\.name).filter { common.contains($0.lowercased()) } } ?? []
        objectValue = shown
        invalidateIntrinsicContentSize()
    }

    /// Writes what changed since the field was filled.
    func commit() {
        let tokens = (objectValue as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let before = Set(shown.map { $0.lowercased() })
        let after = Set(tokens.map { $0.lowercased() })
        let added = tokens.filter { !before.contains($0.lowercased()) }
        let removed = before.subtracting(after)
        guard !added.isEmpty || !removed.isEmpty else { return }
        do {
            try TagStore.shared.update(urls, adding: added, removing: removed, undo: undo)
        } catch {
            let alert = NSAlert(error: error)
            if let host = errorWindow ?? NSApp.mainWindow, host.attachedSheet == nil {
                alert.beginSheetModal(for: host, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
        reload()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
    }

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
                    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        let present = Set((objectValue as? [String] ?? []).map { $0.lowercased() })
        return TagStore.shared.suggestions.map(\.name)
            .filter { !present.contains($0.lowercased()) && $0.range(of: substring, options: [.caseInsensitive, .anchored]) != nil }
    }
}

/// "Tags…": the tag field in a popover next to the selection.
final class TagEditorController: NSViewController, NSPopoverDelegate {
    private let field = TagField()
    private let urls: [URL]
    private weak var tagUndo: UndoManager?

    init(urls: [URL], undo: UndoManager?) {
        self.urls = urls
        self.tagUndo = undo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: urls.count == 1 ? "Tags for “\(urls[0].lastPathComponent)”"
                                                                  : "Tags for \(urls.count.formatted()) items")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        field.urls = urls
        field.undo = tagUndo
        field.errorWindow = NSApp.mainWindow
        let stack = NSStackView(views: [title, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 280),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    /// Closing the popover keeps what was typed, like Finder.
    func popoverWillClose(_ notification: Notification) {
        field.commit()
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = self
        popover.delegate = self
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}
