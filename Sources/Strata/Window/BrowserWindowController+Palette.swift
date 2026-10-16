import AppKit

extension BrowserWindowController {
    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        if palette.isVisible {
            palette.close()
            return
        }
        palette.goToPath = { [weak self] url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue, !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                self?.navigate(to: url)
            } else {
                self?.navigate(to: url.deletingLastPathComponent(), select: url)
            }
        }
        pathQuery = PathQuery()
        palette.queryItems = { [weak self] query in self?.pathQueryItems(query) ?? [] }
        palette.lateItems = { [weak self] query in await self?.indexItems(query) ?? [] }
        palette.show(in: window, items: paletteItems())
    }

    /// Anything on disk, from the index (plain English understood: "pdfs from last week"); ranked below folders you use
    /// and items in this folder.
    private func indexItems(_ query: String) async -> [PaletteItem] {
        guard query.count >= 2, !query.hasPrefix("/"), !query.hasPrefix("~"),
              let result = await FileIndex.shared.understand(query, limit: 30) else { return [] }
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        return result.hits.map { hit in
            let entry = FileEntry(hit: hit)
            let isFolder = entry.isFolder
            let matches = Fuzzy.match(query.split(separator: " ").first.map(String.init) ?? query, entry.name)?.indices ?? []
            return PaletteItem(title: entry.name, subtitle: Format.tildePath(entry.url.deletingLastPathComponent()),
                               icon: isFolder ? folderIcon : IconCache.shared.icon(for: entry), kind: isFolder ? .folder : .match,
                               fixedScore: max(0, hit.score - 1000) / 2 + 8, titleMatches: matches, url: entry.url) { [weak self] in
                if isFolder { self?.navigate(to: entry.url) } else { self?.navigate(to: entry.url.deletingLastPathComponent(), select: entry.url) }
            }
        }
    }

    private func pathQueryItems(_ query: String) -> [PaletteItem] {
        let visited = Array(Frecency.shared.ranked().prefix(400))
        let roots = (Places.favorites() + Places.volumes()).map(\.url) + [Places.home] + visited.prefix(100)
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        return pathQuery.resolve(query, roots: roots, visited: visited).map { hit in
            let url = hit.url
            return PaletteItem(title: url.lastPathComponent, subtitle: Format.tildePath(url.deletingLastPathComponent()),
                               icon: hit.isFolder ? folderIcon : IconCache.shared.icon(forPath: url.path),
                               kind: hit.isFolder ? .folder : .match, fixedScore: hit.score, titleMatches: hit.nameMatches, url: url) { [weak self] in
                if hit.isFolder { self?.navigate(to: url) } else { self?.navigate(to: url.deletingLastPathComponent(), select: url) }
            }
        }
    }

    private func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        var seen: Set<String> = [location.path]
        let folderIcon = NSWorkspace.shared.icon(for: .folder)

        // Here first: what's in this folder is the most likely target.
        for entry in browser.topLevelEntries {
            items.append(PaletteItem(title: entry.name, subtitle: entry.kind, icon: IconCache.shared.icon(for: entry),
                                     kind: .file, boost: 6, url: entry.url) { [weak self] in
                guard let self else { return }
                if entry.isFolder { navigate(to: entry.url) } else { NSWorkspace.shared.open(entry.url); browser.select([entry.url]) }
            })
            if entry.isFolder { seen.insert(entry.url.path) }
        }
        for (rank, url) in Frecency.shared.ranked().prefix(400).enumerated() where seen.insert(url.path).inserted {
            items.append(PaletteItem(title: Places.displayName(url),
                                     subtitle: Format.tildePath(url.deletingLastPathComponent()), icon: folderIcon,
                                     kind: .folder, boost: max(0, 24 - rank / 2), url: url) { [weak self] in self?.navigate(to: url) })
        }
        for place in Places.favorites() + Places.volumes() where seen.insert(place.url.path).inserted {
            items.append(PaletteItem(title: place.title, subtitle: Format.tildePath(place.url), icon: IconCache.shared.icon(forPath: place.url.path),
                                     kind: .folder, boost: 4, url: place.url) { [weak self] in self?.navigate(to: place.url) })
        }
        return items + workspaceItems() + commandItems()
    }

    /// Saved workspaces: the one this window came from isn't offered (it's here already).
    private func workspaceItems() -> [PaletteItem] {
        let current = groupWorkspaceName
        return Workspaces.all.filter { $0.name != current }.map { workspace in
            let image = NSImage(systemSymbolName: Workspaces.symbol(workspace), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            return PaletteItem(title: workspace.name, subtitle: Workspaces.summary(workspace), icon: image, kind: .workspace,
                               keywords: workspace.tabs.joined().map { FileManager.default.displayName(atPath: $0) }, boost: 10) {
                Workspaces.open(workspace)
            }
        }
    }

    private func commandItems() -> [PaletteItem] {
        let hasSelection = !browser.selectedURLs.isEmpty
        // Titles worked out in code (already localized) come through here; literal ones through `command` below.
        func localizedCommand(_ title: String, _ symbol: String, _ shortcut: String?, keywords: [String] = [],
                              _ run: @escaping () -> Void) -> PaletteItem {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            // The shortcut as currently set (Settings ▸ Shortcuts can change or remove it).
            let live = shortcut.map { ShortcutStore.shared.live($0) }.flatMap { $0.isEmpty ? nil : $0 }
            return PaletteItem(title: title, subtitle: "", icon: image, kind: .action, shortcut: live, keywords: keywords, run: run)
        }
        func command(_ title: String.LocalizationValue, _ symbol: String, _ shortcut: String?, keywords: [String] = [],
                     _ run: @escaping () -> Void) -> PaletteItem {
            localizedCommand(String(localized: title), symbol, shortcut, keywords: keywords, run)
        }
        var commands = [
            command("New Folder", "folder.badge.plus", "⇧⌘N") { [weak self] in self?.browser.newFolder(nil) },
            command("New Tab", "plus.rectangle.on.rectangle", "⌘T") { [weak self] in self?.newWindowForTab(nil) },
            command("New Window", "macwindow.badge.plus", "⌘N") { (NSApp.delegate as? AppDelegate)?.newWindow(nil) },
            command("Open in Terminal", "terminal", "⌃⌘T") { [weak self] in self?.browser.openInTerminal(nil) },
            command("Copy Path", "link", "⌥⌘C") { [weak self] in self?.browser.copyPath(nil) },
            localizedCommand(Prefs.showHidden ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files"),
                             Prefs.showHidden ? "eye.slash" : "eye.circle", "⇧⌘.") {
                Prefs.showHidden.toggle()
            },
            localizedCommand(Prefs.foldersFirst ? String(localized: "Mix Folders with Files") : String(localized: "Keep Folders on Top"),
                             "folder", nil) { Prefs.foldersFirst.toggle() },
            localizedCommand(splitController.splitViewItems.last?.isCollapsed == true ? String(localized: "Show Inspector")
                                 : String(localized: "Hide Inspector"), "sidebar.right", "⌘I") { [weak self] in
                self?.splitController.toggleInspector(nil)
            },
            localizedCommand(splitController.splitViewItems.first?.isCollapsed == true ? String(localized: "Show Sidebar")
                                 : String(localized: "Hide Sidebar"), "sidebar.left", "⌃⌘S") { [weak self] in
                self?.splitController.toggleSidebar(nil)
            },
            localizedCommand(Prefs.sidebarShowsTree ? String(localized: "Show Places in Sidebar") : String(localized: "Show Folder Tree in Sidebar"),
                             "list.bullet.indent", nil, keywords: ["Tree", "Folders", "Favorites", "Navigation", "Hierarchy"]) { [weak self] in
                self?.toggleFolderTree(nil)
            },
            localizedCommand(isDualPane ? String(localized: "Single Pane") : String(localized: "Dual Pane"), "rectangle.split.2x1", "⌘\\") { [weak self] in
                self?.toggleDualPane(nil)
            },
            command("View as Icons", "square.grid.2x2", "⌘1") { [weak self] in self?.browser.setMode(.grid); self?.syncViewModeItem() },
            command("View as List", "list.bullet", "⌘2") { [weak self] in self?.browser.setMode(.list); self?.syncViewModeItem() },
            command("View as Columns", "rectangle.split.3x1", "⌘3") { [weak self] in self?.browser.setMode(.columns); self?.syncViewModeItem() },
            command("View as Gallery", "squares.below.rectangle", "⌘4") { [weak self] in
                self?.browser.setMode(.gallery)
                self?.syncViewModeItem()
            },
            command("View as Disk Usage", "square.split.bottomrightquarter", "⌘5") { [weak self] in
                self?.browser.setMode(.treemap)
                self?.syncViewModeItem()
            },
            command("Back", "chevron.left", "⌘[") { [weak self] in self?.goBack(nil) },
            command("Forward", "chevron.right", "⌘]") { [weak self] in self?.goForward(nil) },
            command("Recents", "clock", "⇧⌘F") { [weak self] in self?.goRecents(nil) },
            command("Trash", "trash", nil) { [weak self] in self?.goTrash(nil) },
            command("Empty Trash…", "trash", "⇧⌘⌫", keywords: ["Delete", "Erase"]) {
                (NSApp.delegate as? AppDelegate)?.emptyTrash(nil)
            },
            command("Go to Folder…", "folder.badge.questionmark", "⇧⌘G") { [weak self] in self?.goToFolder(nil) },
            command("Save Workspace…", "rectangle.stack.badge.plus", nil,
                    keywords: ["New Workspace", "Create Workspace", "Add Workspace", "Layout", "Setup", "Session", "Tabs"]) { [weak self] in
                guard let window = self?.window else { return }
                Workspaces.saveCurrent(from: window)
            },
            command("Connect to Server…", "network", "⌥⌘K", keywords: ["SMB", "Network", "Share", "Mount", "NAS", "WebDAV"]) { [weak self] in
                self?.connectToServer(nil)
            },
            command("Undo", "arrow.uturn.backward", "⌘Z") { [weak self] in self?.window?.undoManager?.undo() },
            command("History…", "clock.arrow.circlepath", "⌥⌘Z") { (NSApp.delegate as? AppDelegate)?.showHistory(nil) },
            command("Shelf", "tray", "⌥⌘S") { (NSApp.delegate as? AppDelegate)?.toggleShelf(nil) },
            command("Settings…", "gearshape", "⌘,") { (NSApp.delegate as? AppDelegate)?.showSettings(nil) },
            command("Keyboard Shortcuts", "keyboard", "⌘/") { (NSApp.delegate as? AppDelegate)?.showShortcuts(nil) },
            command("Edit Location", "character.cursor.ibeam", "⌘L") { [weak self] in self?.goToFolder(nil) },
            command("Enclosing Folder", "arrow.up", "⌘↑") { [weak self] in self?.goToEnclosingFolder(nil) },
            command("Reload", "arrow.clockwise", "⌘R") { [weak self] in self?.browser.reloadFolder(nil) },
            command("Show in Finder", "macwindow", nil) { [weak self] in self?.browser.showInFinder(nil) },
            command("Duplicates", "square.on.square", nil) { [weak self] in self?.showDuplicates() },
        ]
        if hasSelection {
            commands.insert(contentsOf: [
                command("Quick Look", "eye", "Space") { [weak self] in self?.browser.toggleQuickLook(nil) },
                command("Add to Shelf", "tray.and.arrow.down", nil) { [weak self] in self?.browser.addToShelf(nil) },
                command("Tags…", "tag", nil, keywords: ["Label", "Color"]) { [weak self] in self?.browser.editTags(nil) },
                command("Share…", "square.and.arrow.up", nil, keywords: ["AirDrop", "Send", "Mail", "Messages"]) { [weak self] in
                    self?.browser.share(nil)
                },
                command("Duplicate", "plus.square.on.square", "⌘D") { [weak self] in self?.browser.duplicate(nil) },
                localizedCommand(browser.renameTitle, "pencil", browser.selectedURLs.count > 1 ? nil : "↩",
                                 keywords: ["Batch", "Replace", "Number"]) { [weak self] in self?.browser.renameSelection(nil) },

                command("Delete Immediately…", "xmark.bin", "⌥⌘⌫", keywords: ["Remove", "Erase"]) { [weak self] in
                    self?.browser.deleteImmediately(nil)
                },
            ], at: 0)
        }
        if let name = groupWorkspaceName, let workspace = Workspaces.named(name) {
            commands.append(localizedCommand(String(localized: "Update “\(workspace.name)”", comment: "Window ▸ Workspaces: save this window into the workspace it was opened from"),
                                             "arrow.triangle.2.circlepath", nil, keywords: ["Workspace", "Save"]) { [weak self] in
                guard let window = self?.window else { return }
                Workspaces.update(workspace.name, from: window)
            })
        }
        if paneFolders != nil {
            commands.append(command("Compare with Other Pane…", "arrow.left.arrow.right.square", nil,
                                    keywords: ["Sync", "Diff", "Mirror", "Synchronize", "Folders"]) { [weak self] in
                self?.compareWithOtherPane(nil)
            })
        }
        if !browser.selectedURLs.isEmpty, !browser.isShowingTrash, browser.effectiveMode != .treemap, browser.canWriteBesideSelection {
            commands.insert(localizedCommand(browser.compressTitle, "doc.zipper", nil, keywords: ["Zip", "Archive"]) { [weak self] in
                self?.browser.compress(nil)
            }, at: 0)
        }
        if !browser.selectedApps.isEmpty {
            commands.insert(localizedCommand(browser.appUpdatesTitle, "arrow.down.app", nil, keywords: ["Update", "Upgrade", "Version", "App Store"]) { [weak self] in
                self?.browser.checkAppsForUpdates(nil)
            }, at: 0)
        }
        // Containers selected in the Containers folder: what can be done to them, and a shell in one.
        let containers = browser.selectedContainers
        if !containers.isEmpty {
            for action in ContainerControl.actions(for: containers).reversed() {
                commands.insert(localizedCommand(ContainerControl.title(action), ContainerControl.symbol(action), nil,
                                                 keywords: ["Container", "Docker", action.rawValue.capitalized]) { [weak self] in
                    guard let self else { return }
                    ContainerControl.run(action, on: browser.selectedContainers, in: window)
                }, at: 0)
            }
        }
        if !browser.selectedArchives.isEmpty, !browser.isShowingTrash, browser.canWriteBesideSelection {
            commands.insert(localizedCommand(browser.extractTitle, "archivebox", nil, keywords: ["Unzip", "Expand", "Decompress"]) { [weak self] in
                self?.browser.extract(nil)
            }, at: 0)
        }
        // In the Trash: Put Back. Never offered for something inside a trashed folder.
        let selected = browser.selectedURLs
        if !selected.isEmpty, browser.isOnServer {
            // A server has no Trash: deleting there asks first.
            commands.insert(localizedCommand(String(localized: "Delete…", comment: "Menu command: delete for good (on a server, which has no Trash)"),
                                             "trash", "⌘⌫", keywords: ["Remove", "Erase", "Trash"]) { [weak self] in self?.browser.moveToTrash(nil) }, at: 0)
        } else if !selected.isEmpty, selected.allSatisfy(Trash.contains) {
            commands.insert(command("Put Back", "tray.and.arrow.up", "⌘⌫") { [weak self] in self?.browser.putBack(nil) }, at: 0)
        } else if !selected.isEmpty, !selected.contains(where: Trash.isInTrash) {
            commands.insert(command("Move to Trash", "trash", "⌘⌫") { [weak self] in self?.browser.moveToTrash(nil) }, at: 0)
        }
        commands.append(contentsOf: aiPaletteItems())
        if !Privacy.hasFullDiskAccess {
            commands.append(command("Grant Full Disk Access…", "lock.open", nil) { NSWorkspace.shared.open(Privacy.settingsURL) })
        }
        // A read-only copy (an archive opened as a folder, a container's files): nothing in it changes, so commands that
        // would do nothing aren't offered. A container's files aren't handed to Finder, the Shelf or the share sheet.
        if browser.isInsideArchive {
            // On a server, new folders, renaming one item and deleting go to the server.
            let onServer = browser.isOnServer
            var hidden = Set((onServer ? ["Tags…", "Duplicate", "Delete Immediately…"]
                : ["New Folder", "Tags…", "Duplicate", "Delete Immediately…", "Move to Trash"]).map { String(localized: String.LocalizationValue($0)) })
            if !onServer || browser.selectedURLs.count > 1 { hidden.insert(browser.renameTitle) }
            if browser.directory.map(LazyCopies.contains) == true {
                hidden.formUnion(["Add to Shelf", "Share…", "Show in Finder"].map { String(localized: String.LocalizationValue($0)) })
            }
            if browser.canOpenTerminalInContainer == false || browser.serverKind == .s3 { hidden.insert(String(localized: "Open in Terminal")) }
            commands.removeAll { hidden.contains($0.title) }
        }
        return commands
    }
}
