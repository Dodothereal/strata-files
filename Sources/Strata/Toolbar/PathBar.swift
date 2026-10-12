import AppKit

/// The address bar. Shows the location as clickable breadcrumbs; click empty space or press ⌘L to type a path, with
/// Tab completion. The chevrons between crumbs list that folder's subfolders for sideways jumps.
final class PathBar: NSView, NSTextFieldDelegate {
    /// Folder to show, plus an item inside it to select (when a file path was typed).
    var onNavigate: ((URL, URL?) -> Void)?
    var onFinishEditing: (() -> Void)?

    var url: URL? {
        didSet {
            title = nil
            if !isEditing { rebuild() }
        }
    }

    /// A title shown instead of breadcrumbs (Search, Recents…), kept across editing.
    private var title: (text: String, symbol: String)?

    /// Root of the git work tree being shown, if any; the branch pill follows its crumb.
    var gitRoot: URL? {
        didSet { if gitRoot?.path != oldValue?.path, !isEditing, url != nil { rebuild() } }
    }

    /// Set its `model` from the git status; hidden while the model is nil.
    let branchPill = GitBranchPill()

    private let crumbs = NSStackView()
    private let field = NSTextField()
    private(set) var isEditing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.alignment = .centerY
        crumbs.detachesHiddenViews = true
        // Let a deep path squeeze into the bar by dropping middle crumbs (their visibility priorities below) instead of
        // forcing the bar wider: past the toolbar's room, AppKit would move every toolbar item into the overflow menu.
        crumbs.setClippingResistancePriority(.defaultLow, for: .horizontal)
        crumbs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crumbs)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Go to folder…"
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.isHidden = true
        addSubview(field)

        // A wish, weaker than the toolbar's own sizing: the bar gives up width before other items overflow.
        let preferred = widthAnchor.constraint(equalToConstant: 520)
        preferred.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            preferred,
            crumbs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    /// Shows a single non-navigating crumb, for places that aren't folders (Search, Recents).
    func showTitle(_ title: String, symbol: String) {
        self.title = (title, symbol)
        if isEditing { endEditing(restoreFocus: false) }
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let crumb = CrumbButton(title: title, symbol: symbol, emphasized: true)
        crumb.isEnabled = true
        crumbs.addArrangedSubview(crumb)
    }

    // MARK: - Breadcrumbs

    private func rebuild() {
        if let title {
            showTitle(title.text, symbol: title.symbol)
            return
        }
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else { return }
        let parts = Self.components(of: url)
        let repoRootPath = gitRoot?.standardizedFileURL.path
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let crumb = CrumbButton(title: part.title, symbol: part.symbol, emphasized: isLast)
            crumb.toolTip = Format.tildePath(part.url)
            crumb.target = self
            crumb.action = #selector(crumbClicked(_:))
            crumb.destination = part.url
            let group = NSStackView(views: [crumb])
            group.spacing = 0
            let isRepoRoot = part.url.standardizedFileURL.path == repoRootPath
            if isRepoRoot {
                group.addArrangedSubview(branchPill)
                group.setCustomSpacing(2, after: crumb)
                group.setCustomSpacing(2, after: branchPill)
            }
            if !isLast {
                let chevron = ChevronButton(folder: part.url) { [weak self] target in self?.onNavigate?(target, nil) }
                group.addArrangedSubview(chevron)
            }
            crumbs.addArrangedSubview(group)
            // When space runs out, middle folders go first; the root and the current folder stay.
            let priority: Float = index == 0 || isLast ? 1000 : isRepoRoot ? 900 : Float(500 + index)
            crumbs.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: priority), for: group)
        }
    }

    @objc private func crumbClicked(_ sender: CrumbButton) {
        guard let destination = sender.destination else { return }
        onNavigate?(destination, nil)
    }

    private static func components(of url: URL) -> [(title: String, url: URL, symbol: String?)] {
        let path = url.standardizedFileURL.path
        let home = Places.home.standardizedFileURL.path
        var parts: [(title: String, url: URL, symbol: String?)] = []
        let root: String
        if path == home || path.hasPrefix(home + "/") {
            root = home
            // Icon only, unless home is the folder being shown.
            parts.append((path == home ? NSUserName() : "", URL(fileURLWithPath: home), "house.fill"))
        } else if path.hasPrefix("/Volumes/"), let name = path.split(separator: "/").dropFirst().first {
            root = "/Volumes/\(name)"
            parts.append((String(name), URL(fileURLWithPath: root), "externaldrive.fill"))
        } else {
            root = "/"
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
            parts.append((values?.volumeLocalizedName ?? "Macintosh HD", URL(fileURLWithPath: "/"), "internaldrive.fill"))
        }
        var current = URL(fileURLWithPath: root)
        for component in path.dropFirst(root.count).split(separator: "/") {
            current = current.appending(path: String(component))
            // Another disk's Trash is `.Trashes/<uid>`: shown as one "Trash" step.
            if component == ".Trashes", Trash.isTrash(current.appending(path: String(getuid()))) { continue }
            if Trash.isTrash(current) {
                parts.append(("Trash", current, "trash"))
            } else {
                parts.append((String(component), current, nil))
            }
        }
        return parts
    }

    // MARK: - Editing

    func beginEditing() {
        guard let url, !isEditing else { return }
        isEditing = true
        crumbs.isHidden = true
        field.isHidden = false
        var text = Format.tildePath(url)
        if !text.hasSuffix("/") { text += "/" }
        field.stringValue = text
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        crumbs.isHidden = false
        rebuild()
        if restoreFocus { onFinishEditing?() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endEditing(restoreFocus: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(restoreFocus: true)
            return true
        case #selector(NSResponder.insertTab(_:)):
            complete()
            return true
        default:
            return false
        }
    }

    private func resolvedPath() -> String {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || url == nil { return expanded }
        return url!.appending(path: expanded).path
    }

    private func commit() {
        let path = resolvedPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            shake()
            return
        }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let isFolder = isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path)
        endEditing(restoreFocus: true)
        if isFolder {
            onNavigate?(target, nil)
        } else {
            onNavigate?(target.deletingLastPathComponent(), target)
        }
    }

    /// Completes the last path component against the folders on disk, as far as it's unambiguous.
    private func complete() {
        let path = resolvedPath()
        let directory = path.hasSuffix("/") ? path : (path as NSString).deletingLastPathComponent
        let prefix = path.hasSuffix("/") ? "" : (path as NSString).lastPathComponent
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else {
            shake()
            return
        }
        let matches = names.filter { name in
            guard name.lowercased().hasPrefix(prefix.lowercased()), !name.hasPrefix(".") || prefix.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &isDir) && isDir.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = matches.first else {
            NSSound.beep()
            return
        }
        let completed: String
        if matches.count == 1 {
            completed = first + "/"
        } else {
            var common = first.lowercased()
            for name in matches.dropFirst() {
                common = String(common.commonPrefix(with: name.lowercased()))
            }
            completed = String(first.prefix(common.count))
            if completed.count == prefix.count { NSSound.beep() }
        }
        let newPath = (directory as NSString).appendingPathComponent(completed)
        field.stringValue = (newPath as NSString).abbreviatingWithTildeInPath + (matches.count == 1 ? "/" : "")
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -9, 9, -6, 6, -3, 3, 0]
        animation.duration = 0.4
        layer?.add(animation, forKey: "shake")
        NSSound.beep()
    }
}

/// A breadcrumb segment with a soft hover highlight.
final class CrumbButton: NSButton {
    var destination: URL?
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String?, emphasized: Bool) {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: emphasized ? .semibold : .regular),
            .foregroundColor: emphasized ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? "Home" : title)
            symbolConfiguration = .init(pointSize: 12, weight: .medium)
            contentTintColor = .secondaryLabelColor
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
        }
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += title.isEmpty ? 14 : 16
        size.height = 24
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHighlight(true) }
    override func mouseExited(with event: NSEvent) { setHighlight(false) }

    fileprivate func setHighlight(_ on: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
        }
    }
}

/// The separator between crumbs; click it to jump to a sibling folder.
final class ChevronButton: NSButton {
    private let folder: URL
    private let navigate: (URL) -> Void
    private var tracking: NSTrackingArea?

    init(folder: URL, navigate: @escaping (URL) -> Void) {
        self.folder = folder
        self.navigate = navigate
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Subfolders")
        symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 5
        target = self
        action = #selector(showMenu)
        toolTip = "Folders in \(folder.lastPathComponent)"
        setAccessibilityLabel("Folders in \(FileManager.default.displayName(atPath: folder.path))")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 22) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }

    @objc private func showMenu() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let folders = urls.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let menu = NSMenu()
        for url in folders.prefix(400) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = IconCache.shared.icon(forPath: url.path).copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if folders.isEmpty {
            let empty = NSMenuItem(title: "No Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigate(url)
    }
}
