import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Strata", [
            item("About Strata", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
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
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("New Folder", #selector(BrowserViewController.newFolder(_:)), "n", [.command, .shift]),
            .separator(),
            item("Open", #selector(BrowserViewController.openSelection(_:)), "o"),
            item("Open in Terminal", #selector(BrowserViewController.openInTerminal(_:)), "t", [.command, .control]),
            item("Ask Strata…", #selector(BrowserWindowController.askStrata(_:)), "a", [.command, .option]),
            item("Show in Finder", #selector(BrowserViewController.showInFinder(_:))),
            .separator(),
            item("Quick Look", #selector(BrowserViewController.toggleQuickLook(_:)), "y"),
            item("Rename", #selector(BrowserViewController.renameSelection(_:))),
            item("Duplicate", #selector(BrowserViewController.duplicate(_:)), "d"),
            item("Copy to Other Pane", #selector(BrowserWindowController.copyToOtherPane(_:)), function(NSF5FunctionKey), []),
            item("Move to Other Pane", #selector(BrowserWindowController.moveToOtherPane(_:)), function(NSF6FunctionKey), []),
            item("Move to Trash", #selector(BrowserViewController.moveToTrash(_:)), "\u{8}"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            item("History…", #selector(AppDelegate.showHistory(_:)), "z", [.command, .option]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Move Item Here", #selector(BrowserViewController.pasteAndMove(_:)), "v", [.command, .option]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Path", #selector(BrowserViewController.copyPath(_:)), "c", [.command, .option]),
        ]))
        main.addItem(submenu("View", BrowserViewMode.menuItems(action: #selector(BrowserWindowController.syncViewMode(_:))) + [
            .separator(),
            item("Bigger Icons", #selector(BrowserViewController.biggerIcons(_:)), "+"),
            item("Smaller Icons", #selector(BrowserViewController.smallerIcons(_:)), "-"),
            .separator(),
            item("Show Hidden Files", #selector(BrowserViewController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("Keep Folders on Top", #selector(BrowserViewController.toggleFoldersFirst(_:))),
            .separator(),
            item("Dual Pane", #selector(BrowserWindowController.toggleDualPane(_:)), "\\"),
            item("Focus Other Pane", #selector(BrowserWindowController.focusOtherPane(_:)), "\\", [.command, .option]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Toggle Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "i"),
            .separator(),
            item("Command Palette…", #selector(BrowserWindowController.showCommandPalette(_:)), "k"),
            item("Search", #selector(BrowserWindowController.focusSearch(_:)), "f"),
            item("Reload", #selector(BrowserViewController.reloadFolder(_:)), "r"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        main.addItem(submenu("Go", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
            item("Enclosing Folder", #selector(BrowserWindowController.goToEnclosingFolder(_:)), arrow(NSUpArrowFunctionKey)),
            item("Open Selection", #selector(BrowserViewController.openSelection(_:)), arrow(NSDownArrowFunctionKey)),
            .separator(),
            item("Recents", #selector(BrowserWindowController.goRecents(_:)), "f", [.command, .shift]),
            item("Home", #selector(BrowserWindowController.goHome(_:)), "h", [.command, .shift]),
            item("Desktop", #selector(BrowserWindowController.goDesktop(_:)), "d", [.command, .shift]),
            item("Documents", #selector(BrowserWindowController.goDocuments(_:)), "o", [.command, .shift]),
            item("Downloads", #selector(BrowserWindowController.goDownloads(_:)), "l", [.command, .option]),
            item("Applications", #selector(BrowserWindowController.goApplications(_:)), "a", [.command, .shift]),
            .separator(),
            item("Go to Folder…", #selector(BrowserWindowController.goToFolder(_:)), "g", [.command, .shift]),
            item("Edit Location", #selector(BrowserWindowController.goToFolder(_:)), "l"),
        ]))
        let workspaces = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        let workspacesMenu = NSMenu(title: "Workspaces")
        workspacesMenu.delegate = WorkspaceMenu.shared
        workspaces.submenu = workspacesMenu
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Shelf", #selector(AppDelegate.toggleShelf(_:)), "s", [.command, .option]),
            item("History", #selector(AppDelegate.showHistory(_:))),
            workspaces,
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu("Help", [
            item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/"),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        item.submenu = services
        return item
    }

    private static func function(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }
}

/// Window ▸ Workspaces: save the current window's tabs, reopen or delete saved ones.
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    static let shared = WorkspaceMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let save = NSMenuItem(title: "Save Workspace…", action: #selector(save(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        let saved = Workspaces.all
        guard !saved.isEmpty else { return }
        menu.addItem(.separator())
        for workspace in saved {
            let item = NSMenuItem(title: workspace.name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.name
            item.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Workspace", action: nil, keyEquivalent: "")
        let deleteMenu = NSMenu()
        for workspace in saved {
            let item = NSMenuItem(title: workspace.name, action: #selector(remove(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.name
            deleteMenu.addItem(item)
        }
        delete.submenu = deleteMenu
        menu.addItem(delete)
    }

    @objc private func save(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        Workspaces.saveCurrent(from: window)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let workspace = Workspaces.all.first(where: { $0.name == name }) else { return }
        (NSApp.delegate as? AppDelegate)?.open(workspace)
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Workspaces.all.removeAll { $0.name == name }
    }
}
