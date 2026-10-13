import AppKit

/// One section of the Inspector: a rounded card with an icon, a title, an optional accessory and a chevron that
/// collapses it (remembered per section). Every section looks and lines up the same way.
final class InspectorCard: NSView {
    /// The card's content; it spans the card's width inside the padding.
    let content: NSView
    private let card = CardView()
    private let chevron = NSButton()
    private let titleLabel: NSTextField
    private let body = NSView()
    private let id: String
    private var bodyHeightWhenCollapsed: NSLayoutConstraint?
    private var contentBottom: NSLayoutConstraint?
    private var bodyTop: NSLayoutConstraint?

    static let padding: CGFloat = 12

    init(id: String, title: String, symbol: String, content: NSView, accessory: NSView? = nil) {
        self.id = id
        self.content = content
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold).applying(.init(hierarchicalColor: .secondaryLabelColor))
        icon.setAccessibilityElement(false)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityElement(false)

        chevron.isBordered = false
        chevron.bezelStyle = .accessoryBarAction
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.target = self
        chevron.action = #selector(toggle)
        chevron.setAccessibilityLabel(title)

        var headerViews: [NSView] = [icon, titleLabel, NSView()]
        if let accessory {
            // A long accessory (an upstream branch, a size) gives way before the title does.
            accessory.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            headerViews.append(accessory)
        }
        headerViews.append(chevron)
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        // The whole header row collapses and expands, not just the chevron.
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle))
        header.addGestureRecognizer(click)

        body.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        card.addSubview(header)
        card.addSubview(body)
        let pad = Self.padding
        let bottom = content.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        contentBottom = bottom
        let top = body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8)
        bodyTop = top
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad + 4),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            header.heightAnchor.constraint(equalToConstant: 20),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            top,
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            content.topAnchor.constraint(equalTo: body.topAnchor),
            bottom,
        ])
        bodyHeightWhenCollapsed = body.heightAnchor.constraint(equalToConstant: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        apply(collapsed: isCollapsed, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var defaultsKey: String { "inspector.collapsed." + id }

    var isCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            apply(collapsed: newValue, animated: true)
        }
    }

    @objc private func toggle() {
        isCollapsed.toggle()
    }

    private func apply(collapsed: Bool, animated: Bool) {
        // Typing into a field that's being hidden would go on, unseen: editing ends first.
        if collapsed, let window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: content) {
            window.makeFirstResponder(nil)
        }
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.setAccessibilityValue(collapsed ? String(localized: "Collapsed") : String(localized: "Expanded"))
        // Collapsed: the body takes no room (its content stays laid out, just hidden).
        content.isHidden = collapsed
        contentBottom?.isActive = !collapsed
        bodyHeightWhenCollapsed?.isActive = collapsed
        bodyTop?.constant = collapsed ? 0 : 8
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                window?.layoutIfNeeded()
            }
        }
    }
}

/// Label–value rows with one label column, as every Inspector card lays them out.
final class InspectorRows: NSView {
    private let grid = NSGridView()
    static let labelWidth: CGFloat = 74
    /// What the grid shows: each row's title and value view.
    private var shown: [(title: String, value: NSView)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Text rows: values wrap in full (long sizes) and can be selected and copied.
    func setText(_ rows: [(String, String)]) {
        set(rows.map { ($0, Self.text($1)) })
    }

    /// A value as text that wraps and can be selected.
    static func text(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: 12)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// Rows whose values are controls (pop-up menus, switches).
    func set(_ rows: [(String, NSView)]) {
        // The Inspector refreshes whenever files change; the same rows again only update their text, so the card isn't
        // torn down and laid out anew (and a selection in a value survives).
        if updateInPlace(rows) { return }
        shown = rows.map { (title: $0.0, value: $0.1) }
        // NSGridView.removeRow leaves the cell views behind, so remove them explicitly.
        while grid.numberOfRows > 0 {
            let row = grid.row(at: 0)
            for index in 0..<row.numberOfCells { row.cell(at: index).contentView?.removeFromSuperview() }
            grid.removeRow(at: 0)
        }
        for (name, value) in rows {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = name
            grid.addRow(with: [label, value])
        }
        guard grid.numberOfColumns == 2 else { return }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = Self.labelWidth
        grid.column(at: 1).xPlacement = .fill
        // Text lines up on its baseline; a control (switch, pop-up menu) is centred against its label.
        for (index, row) in rows.enumerated() {
            if row.1 is NSTextField || row.1 is InspectorLocationView {
                grid.row(at: index).rowAlignment = .firstBaseline
            } else {
                grid.row(at: index).yPlacement = .center
            }
            // A control of a fixed size (the Locked switch) sits at the start of its cell. Stretched to fill it, its
            // hugging would outrank the divider and hold the whole Inspector at one width.
            if row.1.contentHuggingPriority(for: .horizontal) > .dragThatCannotResizeWindow {
                grid.cell(atColumnIndex: 1, rowIndex: index).xPlacement = .leading
            }
        }
    }

    /// Applies `rows` to the rows shown when they're the same rows (titles, and values of the same kind showing the
    /// same thing), changing only text that differs. False when the grid has to be rebuilt.
    private func updateInPlace(_ rows: [(String, NSView)]) -> Bool {
        guard rows.count == shown.count, grid.numberOfRows == shown.count else { return false }
        for (row, current) in zip(rows, shown) {
            guard row.0 == current.title else { return false }
            switch (row.1, current.value) {
            case let (new, old) where new === old: continue
            case let (new as NSTextField, old as NSTextField) where type(of: new) == type(of: old): continue
            case let (new as InspectorLocationView, old as InspectorLocationView) where new.showsSamePlace(as: old):
                // Same folder, but maybe another item in it to select when clicked.
                old.action = new.action
                continue
            default: return false
            }
        }
        for (row, current) in zip(rows, shown) {
            if let new = row.1 as? NSTextField, let old = current.value as? NSTextField, new !== old,
               old.stringValue != new.stringValue {
                old.stringValue = new.stringValue
            }
        }
        return true
    }
}

/// "Where": the folder's icon and name, with its path on one line underneath (all of it on hover). Clicking shows the
/// folder.
final class InspectorLocationView: NSView {
    fileprivate(set) var action: () -> Void
    private let folder: URL
    private let path: URL

    init(folder: URL, shownAs path: URL, action: @escaping () -> Void) {
        self.action = action
        self.folder = folder
        self.path = path
        super.init(frame: .zero)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: folder.path))
        icon.image?.size = NSSize(width: 16, height: 16)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: FileManager.default.displayName(atPath: path.path))
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        let location = NSTextField(labelWithString: Format.tildePath(path.deletingLastPathComponent()))
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingHead
        for label in [name, location] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(icon)
        addSubview(name)
        addSubview(location)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor, constant: 3),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            location.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            location.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            location.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            location.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = Format.tildePath(path)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Show “\(name.stringValue)”", comment: "Inspector: the item’s folder, as a button that shows it"))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the same folder, the same way (its action shows the same place too).
    func showsSamePlace(as other: InspectorLocationView) -> Bool {
        folder == other.folder && path == other.path
    }

    override var firstBaselineOffsetFromTop: CGFloat {
        subviews.compactMap { $0 as? NSTextField }.first?.firstBaselineOffsetFromTop ?? 12
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The icon and both lines are one button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
