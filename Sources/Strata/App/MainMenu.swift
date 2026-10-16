import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Strata", [
            item("About Strata", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), symbol: "arrow.triangle.2.circlepath"),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", symbol: "gearshape"),
            .separator(),
            item("Empty Trash…", #selector(AppDelegate.emptyTrash(_:)), "\u{8}", [.command, .shift], symbol: "trash.slash"),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide Strata", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Strata", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n", symbol: "macwindow.badge.plus"),
            item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t", symbol: "plus.rectangle.on.rectangle"),
            item("New Folder", #selector(BrowserViewController.newFolder(_:)), "n", [.command, .shift], symbol: "folder.badge.plus"),
            .separator(),
            item("Open", #selector(BrowserViewController.openSelection(_:)), "o", symbol: "arrow.up.forward.app"),
            item("Open in Terminal", #selector(BrowserViewController.openInTerminal(_:)), "t", [.command, .control], symbol: "terminal"),
            item("Ask Strata…", #selector(BrowserWindowController.askStrata(_:)), "a", [.command, .option], symbol: "sparkles"),
            item("Show in Finder", #selector(BrowserViewController.showInFinder(_:)), symbol: "macwindow"),
            item("Add to Sidebar", #selector(BrowserViewController.addToSidebar(_:)), symbol: "sidebar.left"),
            .separator(),
            item("Quick Look", #selector(BrowserViewController.toggleQuickLook(_:)), "y", symbol: "eye"),
            item("Rename", #selector(BrowserViewController.renameSelection(_:)), symbol: "pencil"),
            item("Tags…", #selector(BrowserViewController.editTags(_:)), symbol: "tag"),
            item("Compress", #selector(BrowserViewController.compress(_:)), symbol: "doc.zipper"),
            item("Extract", #selector(BrowserViewController.extract(_:)), symbol: "archivebox"),
            item("Duplicate", #selector(BrowserViewController.duplicate(_:)), "d"),
            item("Copy to Other Pane", #selector(BrowserWindowController.copyToOtherPane(_:)), function(NSF5FunctionKey), [], symbol: "rectangle.on.rectangle"),
            item("Move to Other Pane", #selector(BrowserWindowController.moveToOtherPane(_:)), function(NSF6FunctionKey), [], symbol: "rectangle.righthalf.inset.filled.arrow.right"),
            .separator(),
            item("Share…", #selector(BrowserViewController.share(_:)), symbol: "square.and.arrow.up"),
            .separator(),
            item("Move to Trash", #selector(BrowserViewController.moveToTrash(_:)), "\u{8}", symbol: "trash"),
            alternate(item("Delete Immediately…", #selector(BrowserViewController.deleteImmediately(_:)), "\u{8}", [.command, .option], symbol: "xmark.bin")),
            item("Eject", #selector(BrowserWindowController.ejectVolume(_:)), "e", symbol: "eject"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            item("History…", #selector(AppDelegate.showHistory(_:)), "z", [.command, .option], symbol: "clock.arrow.circlepath"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Move Item Here", #selector(BrowserViewController.pasteAndMove(_:)), "v", [.command, .option], symbol: "arrow.right.doc.on.clipboard"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Path", #selector(BrowserViewController.copyPath(_:)), "c", [.command, .option], symbol: "link"),
        ]))
        main.addItem(submenu("View", BrowserViewMode.menuItems(action: #selector(BrowserWindowController.syncViewMode(_:))) + [
            .separator(),
            item("Bigger Icons", #selector(BrowserViewController.biggerIcons(_:)), "+", symbol: "plus.magnifyingglass"),
            hidden(item("Bigger Icons", #selector(BrowserViewController.biggerIcons(_:)), "=", symbol: "plus.magnifyingglass")),
            item("Smaller Icons", #selector(BrowserViewController.smallerIcons(_:)), "-", symbol: "minus.magnifyingglass"),
            .separator(),
            sortByMenu(),
            .separator(),
            item("Show Hidden Files", #selector(BrowserViewController.toggleHiddenFiles(_:)), ".", [.command, .shift], symbol: "eye.slash"),
            item("Keep Folders on Top", #selector(BrowserViewController.toggleFoldersFirst(_:)), symbol: "folder"),
            .separator(),
            item("Dual Pane", #selector(BrowserWindowController.toggleDualPane(_:)), "\\", symbol: "rectangle.split.2x1"),
            item("Focus Other Pane", #selector(BrowserWindowController.focusOtherPane(_:)), "\\", [.command, .option], symbol: "arrow.left.arrow.right"),
            item("Compare with Other Pane…", #selector(BrowserWindowController.compareWithOtherPane(_:)), symbol: "arrow.left.arrow.right.square"),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Folder Tree in Sidebar", #selector(BrowserWindowController.toggleFolderTree(_:)), symbol: "list.bullet.indent"),
            item("Toggle Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "i", symbol: "sidebar.right"),
            .separator(),
            item("Command Palette…", #selector(BrowserWindowController.showCommandPalette(_:)), "k", symbol: "command"),
            item("Search", #selector(BrowserWindowController.focusSearch(_:)), "f", symbol: "magnifyingglass"),
            item("Reload", #selector(BrowserViewController.reloadFolder(_:)), "r", symbol: "arrow.clockwise"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], symbol: "arrow.up.left.and.arrow.down.right"),
        ]))
        main.addItem(submenu("Go", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "[", symbol: "chevron.left"),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]", symbol: "chevron.right"),
            item("Enclosing Folder", #selector(BrowserWindowController.goToEnclosingFolder(_:)), arrow(NSUpArrowFunctionKey), symbol: "arrow.up"),
            item("Open Selection", #selector(BrowserViewController.openSelection(_:)), arrow(NSDownArrowFunctionKey), id: "go.openSelection", symbol: "arrow.down"),
            .separator(),
            item("Recents", #selector(BrowserWindowController.goRecents(_:)), "f", [.command, .shift], symbol: "clock"),
            item("Home", #selector(BrowserWindowController.goHome(_:)), "h", [.command, .shift], symbol: "house"),
            item("Desktop", #selector(BrowserWindowController.goDesktop(_:)), "d", [.command, .shift], symbol: "menubar.dock.rectangle"),
            item("Documents", #selector(BrowserWindowController.goDocuments(_:)), "o", [.command, .shift], symbol: "doc"),
            item("Downloads", #selector(BrowserWindowController.goDownloads(_:)), "l", [.command, .option], symbol: "arrow.down.circle"),
            item("Applications", #selector(BrowserWindowController.goApplications(_:)), "a", [.command, .shift], symbol: "square.grid.2x2"),
            item("Trash", #selector(BrowserWindowController.goTrash(_:)), symbol: "trash"),
            .separator(),
            item("Go to Folder…", #selector(BrowserWindowController.goToFolder(_:)), "g", [.command, .shift], symbol: "folder.badge.questionmark"),
            item("Edit Location", #selector(BrowserWindowController.goToFolder(_:)), "l", id: "go.editLocation", symbol: "character.cursor.ibeam"),
            item("Connect to Server…", #selector(BrowserWindowController.connectToServer(_:)), "k", [.command, .option], symbol: "network"),
        ]))
        let workspacesTitle = String(localized: "Workspaces", comment: "Window menu: submenu of saved sets of tabs")
        let workspaces = NSMenuItem(title: workspacesTitle, action: nil, keyEquivalent: "")
        workspaces.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
        let workspacesMenu = NSMenu(title: workspacesTitle)
        workspacesMenu.delegate = WorkspaceMenu.shared
        workspaces.submenu = workspacesMenu
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Shelf", #selector(AppDelegate.toggleShelf(_:)), "s", [.command, .option], symbol: "tray"),
            workspaces,
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu("Help", [
            item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/", symbol: "keyboard"),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    /// `id`: a name for Settings ▸ Shortcuts when another command shares the action (otherwise the action names it).
    /// `symbol`: its icon. macOS gives standard commands (Copy, Undo, Minimize…) theirs; every other command names one,
    /// or it sits indented without one among those that have them.
    private static func item(_ title: String.LocalizationValue, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, id: String? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let id { item.identifier = NSUserInterfaceItemIdentifier(id) }
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// A menu item that isn't shown but whose shortcut still works (⌘= for Bigger Icons on keyboards where + needs Shift).
    private static func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    /// Finder's Sort By shortcuts: ⌃⌥⌘1 Name, ⌃⌥⌘2 Kind, ⌃⌥⌘5 Date Modified, ⌃⌥⌘6 Date Created, ⌃⌥⌘7 Size.
    private static func sortByMenu() -> NSMenuItem {
        let titles: [(String.LocalizationValue, String)] = [("Name", "1"), ("Kind", "2"), ("Date Modified", "5"), ("Date Created", "6"), ("Size", "7")]
        let items = titles.enumerated().map { index, entry in
            let menuItem = item(entry.0, #selector(BrowserViewController.sortBy(_:)), entry.1, [.command, .option, .control])
            menuItem.tag = index
            return menuItem
        }
        let sortBy = submenu("Sort By", items)
        sortBy.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        return sortBy
    }

    private static func submenu(_ title: String.LocalizationValue, _ items: [NSMenuItem]) -> NSMenuItem {
        let title = String(localized: title)
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let title = String(localized: "Services", comment: "App menu: the system Services submenu")
        let services = NSMenu(title: title)
        NSApp.servicesMenu = services
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = services
        return item
    }

    /// Shown in place of the item above it while Option is held (Move to Trash → Delete Immediately…).
    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isAlternate = true
        return item
    }

    private static func function(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }
}

/// Window ▸ Workspaces: save the current window's tabs, update the workspace it came from, reopen, rename or delete.
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    static let shared = WorkspaceMenu()

    private var keyController: BrowserWindowController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? BrowserWindowController
    }

    private var keyWorkspaceName: String? { keyController?.groupWorkspaceName }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let save = NSMenuItem(title: String(localized: "Save Workspace…"), action: #selector(save(_:)), keyEquivalent: "")
        save.target = self
        save.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        menu.addItem(save)
        // The window came from a workspace (or was saved as one): it can be saved into it again.
        if let name = keyWorkspaceName, let workspace = Workspaces.named(name) {
            let update = NSMenuItem(title: String(localized: "Update “\(workspace.name)”", comment: "Window ▸ Workspaces: save this window into the workspace it was opened from"),
                                    action: #selector(update(_:)), keyEquivalent: "")
            update.target = self
            update.representedObject = workspace.name
            update.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(update)
        }
        let saved = Workspaces.all
        guard !saved.isEmpty else { return }
        menu.addItem(.separator())
        for workspace in saved {
            let item = NSMenuItem(title: workspace.name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.name
            item.image = NSImage(systemSymbolName: Workspaces.symbol(workspace), accessibilityDescription: nil)
            item.toolTip = Workspaces.help(workspace)
            item.state = keyWorkspaceName == workspace.name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(submenu(String(localized: "Rename Workspace", comment: "Window ▸ Workspaces: submenu listing saved workspaces to rename"),
                             saved, #selector(rename(_:)), symbol: "pencil"))
        menu.addItem(submenu(String(localized: "Delete Workspace", comment: "Window ▸ Workspaces: submenu listing saved workspaces to delete"),
                             saved, #selector(remove(_:)), symbol: "trash"))
    }

    private func submenu(_ title: String, _ saved: [Workspace], _ action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let menu = NSMenu()
        for workspace in saved {
            let entry = NSMenuItem(title: workspace.name, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = workspace.name
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    @objc private func save(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        Workspaces.saveCurrent(from: window)
    }

    @objc private func update(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        Workspaces.update(name, from: window)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let workspace = Workspaces.named(name) else { return }
        Workspaces.open(workspace, from: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Workspaces.askToRename(name, in: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Workspaces.confirmDelete(name, in: NSApp.keyWindow ?? NSApp.mainWindow)
    }
}
