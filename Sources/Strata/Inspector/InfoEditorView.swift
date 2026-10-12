import AppKit

/// Get Info's editable part for one item, under the Inspector's details: Spotlight comments, the app that opens it (this
/// file, or Change All…), Locked, and who may read and write it. Changes apply at once; what's refused says why, here.
final class InfoEditorView: NSView, NSTextFieldDelegate, NSMenuDelegate {
    private(set) var url: URL?
    private var isFolder = false
    private var isPackage = false

    private let comments = NSTextField()
    private let openWithTitle = InfoEditorView.header("Open With")
    private let openWith = NSPopUpButton()
    private let changeAll = NSButton(title: "Change All…", target: nil, action: nil)
    private let locked = NSButton(checkboxWithTitle: "Locked", target: nil, action: nil)
    private let permissions = NSGridView()
    private var accessMenus: [FileInfoEditing.Who: NSPopUpButton] = [:]
    private var whoLabels: [FileInfoEditing.Who: NSTextField] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")
    private var apps: [URL] = []
    /// Whether `apps` lists every app that can open the item (read when the menu opens: it's slow to work out on every
    /// selection change).
    private var appsComplete = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        comments.placeholderString = "Add Comments"
        comments.font = .systemFont(ofSize: 12)
        comments.lineBreakMode = .byWordWrapping
        comments.usesSingleLineMode = false
        comments.cell?.wraps = true
        comments.cell?.isScrollable = false
        comments.maximumNumberOfLines = 4
        comments.delegate = self
        comments.setAccessibilityLabel("Comments")

        openWith.target = self
        openWith.action = #selector(openWithChanged(_:))
        openWith.controlSize = .small
        openWith.setAccessibilityLabel("Open With")
        openWith.menu?.delegate = self
        changeAll.target = self
        changeAll.action = #selector(changeAllClicked(_:))
        changeAll.controlSize = .small
        changeAll.bezelStyle = .push
        changeAll.toolTip = "Open all documents like this one with this app"

        locked.target = self
        locked.action = #selector(lockedChanged(_:))
        locked.controlSize = .small

        permissions.rowSpacing = 4
        permissions.columnSpacing = 8
        for who in FileInfoEditing.Who.allCases {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let menu = NSPopUpButton()
            menu.controlSize = .small
            menu.font = .systemFont(ofSize: 11)
            menu.target = self
            menu.action = #selector(accessChanged(_:))
            menu.tag = who.rawValue
            whoLabels[who] = label
            accessMenus[who] = menu
            permissions.addRow(with: [label, menu])
        }
        permissions.column(at: 0).xPlacement = .leading
        permissions.column(at: 1).xPlacement = .trailing

        message.font = .systemFont(ofSize: 11)
        message.textColor = .systemRed
        message.isHidden = true

        let openWithRow = NSStackView(views: [openWith, changeAll])
        openWithRow.spacing = 6
        let stack = NSStackView(views: [
            Self.header("Comments"), comments, openWithTitle, openWithRow, Self.header("Sharing & Permissions"), locked,
            permissions, message,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: comments)
        stack.setCustomSpacing(12, after: openWithRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            comments.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Room for a few lines: comments are often sentences.
            comments.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            openWithRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        openWith.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Shows `entry`'s settings. Showing the same item again refreshes them, leaving a comment being typed alone.
    func show(_ entry: FileEntry) {
        let same = url == entry.url
        // Moving on while a comment is being typed keeps it (for the item it was typed for).
        if !same, let previous = url, comments.currentEditor() != nil {
            saveComment(comments.stringValue, at: previous.path)
            window?.makeFirstResponder(nil)
        }
        url = entry.url
        isFolder = entry.isDirectory
        isPackage = entry.isDirectory && !entry.isFolder
        if !same { message.isHidden = true }
        let path = entry.url.path
        if !same || comments.currentEditor() == nil { comments.stringValue = FileInfoEditing.comment(at: path) }
        locked.state = FileInfoEditing.isLocked(at: path) ? .on : .off
        loadApps(entry, same: same)
        loadPermissions(path)
        updateEnabled(path)
    }

    /// A locked item takes no changes but unlocking; only its owner can lock or unlock it.
    private func updateEnabled(_ path: String) {
        let isLocked = locked.state == .on
        comments.isEditable = !isLocked
        comments.isEnabled = !isLocked
        openWith.isEnabled = !isLocked && !apps.isEmpty
        changeAll.isEnabled = !isLocked && !apps.isEmpty
        locked.isEnabled = FileInfoEditing.names(at: path)?.ownedByYou ?? false
    }

    // MARK: - Open With

    private func loadApps(_ entry: FileEntry, same: Bool) {
        // Folders open in Strata; apps and other packages open as themselves.
        let applies = !entry.isDirectory
        openWithTitle.isHidden = !applies
        openWith.superview?.isHidden = !applies
        guard applies, !same || apps.isEmpty else { return }
        // Just the current app for now; the rest when the menu opens.
        apps = NSWorkspace.shared.urlForApplication(toOpen: entry.url).map { [$0] } ?? []
        appsComplete = false
        fillAppMenu()
        // Nothing opens it: the menu says so, and Change All has nothing to change to.
        changeAll.isEnabled = !apps.isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openWith.menu, !appsComplete, let url else { return }
        appsComplete = true
        let current = apps.first
        apps = Array(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(40))
        if let current, !apps.contains(current) { apps.insert(current, at: 0) }
        fillAppMenu()
    }

    private func fillAppMenu() {
        guard let url else { return }
        let current = NSWorkspace.shared.urlForApplication(toOpen: url)
        openWith.removeAllItems()
        if apps.isEmpty {
            openWith.addItem(withTitle: "No App")
            openWith.isEnabled = false
            return
        }
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = app
            openWith.menu?.addItem(item)
        }
        if let current, let index = apps.firstIndex(of: current) { openWith.selectItem(at: index) }
        openWith.isEnabled = true
    }

    @objc private func openWithChanged(_ sender: NSPopUpButton) {
        guard let url, let app = sender.selectedItem?.representedObject as? URL else { return }
        // Picking the app it already opens with changes nothing (and mustn't pin this file to it).
        guard app != NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: url) { [weak self] error in
            DispatchQueue.main.async { self?.finish(error) }
        }
    }

    @objc private func changeAllClicked(_ sender: Any?) {
        guard let url, let app = openWith.selectedItem?.representedObject as? URL, let window else { return }
        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription
        let alert = NSAlert()
        let appName = FileManager.default.displayName(atPath: app.path)
        alert.messageText = kind.map { "Open every “\($0)” with “\(appName)”?" } ?? "Open every document like this one with “\(appName)”?"
        alert.informativeText = "This changes the app macOS uses for every document of this kind, in Finder too."
        alert.addButton(withTitle: "Change All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenContentTypeOfFileAt: url) { error in
                DispatchQueue.main.async { self?.finish(error) }
            }
        }
    }

    // MARK: - Comments

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let url else { return }
        saveComment(comments.stringValue, at: url.path)
        comments.stringValue = FileInfoEditing.comment(at: url.path)
    }

    private func saveComment(_ text: String, at path: String) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != FileInfoEditing.comment(at: path) else { return }
        do {
            try FileInfoEditing.setComment(text, at: path)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    // MARK: - Locked and permissions

    @objc private func lockedChanged(_ sender: NSButton) {
        guard let url else { return }
        do {
            try FileInfoEditing.setLocked(sender.state == .on, at: url.path)
            finish(nil)
        } catch {
            finish(error)
        }
        locked.state = FileInfoEditing.isLocked(at: url.path) ? .on : .off
        loadPermissions(url.path)
        updateEnabled(url.path)
    }

    private func loadPermissions(_ path: String) {
        guard let names = FileInfoEditing.names(at: path), let mode = FileInfoEditing.mode(at: path) else {
            permissions.isHidden = true
            return
        }
        permissions.isHidden = false
        whoLabels[.owner]?.stringValue = names.ownedByYou ? "\(names.owner) (Me)" : names.owner
        whoLabels[.group]?.stringValue = names.group
        whoLabels[.everyone]?.stringValue = "everyone"
        // Only the owner may change them (and nothing changes while it's locked).
        let editable = names.ownedByYou && locked.state == .off
        for who in FileInfoEditing.Who.allCases {
            guard let menu = accessMenus[who] else { continue }
            let current = FileInfoEditing.access(mode, for: who)
            menu.removeAllItems()
            // A drop box is for folders; a file shows it only when it's already set that way.
            for access in FileInfoEditing.Access.allCases where access != .writeOnly || isFolder || current == .writeOnly {
                menu.addItem(withTitle: access.title)
                menu.lastItem?.tag = access.rawValue
            }
            menu.selectItem(withTag: current.rawValue)
            menu.isEnabled = editable
            menu.setAccessibilityLabel("Access for \(whoLabels[who]?.stringValue ?? "")")
        }
    }

    @objc private func accessChanged(_ sender: NSPopUpButton) {
        guard let url, let who = FileInfoEditing.Who(rawValue: sender.tag),
              let access = FileInfoEditing.Access(rawValue: sender.selectedTag()) else { return }
        // Taking your own access away from a folder shuts you out of it: ask first.
        if who == .owner, isFolder, access == .none || access == .writeOnly, let window {
            let alert = NSAlert()
            alert.messageText = "Remove your own access to “\(url.lastPathComponent)”?"
            alert.informativeText = "You won’t be able to open this folder until you give yourself access again."
            alert.addButton(withTitle: "Remove Access")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn { apply(access, for: who, to: url) } else { loadPermissions(url.path) }
            }
            return
        }
        apply(access, for: who, to: url)
    }

    private func apply(_ access: FileInfoEditing.Access, for who: FileInfoEditing.Who, to url: URL) {
        do {
            try FileInfoEditing.setAccess(access, for: who, at: url.path)
            finish(nil)
        } catch {
            finish(error)
        }
        loadPermissions(url.path)
    }

    /// Clears or shows the last change's problem.
    private func finish(_ error: Error?) {
        message.stringValue = error.map { "Couldn’t change that: \($0.localizedDescription)" } ?? ""
        message.isHidden = error == nil
        if error != nil, let url, let app = NSWorkspace.shared.urlForApplication(toOpen: url), let index = apps.firstIndex(of: app) {
            openWith.selectItem(at: index)
        }
    }
}
