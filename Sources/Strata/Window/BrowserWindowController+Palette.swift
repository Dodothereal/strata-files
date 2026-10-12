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

    /// Anything on disk, from the index; ranked below folders you use and items in this folder.
    private func indexItems(_ query: String) async -> [PaletteItem] {
        guard query.count >= 2, !query.hasPrefix("/"), !query.hasPrefix("~"),
              let result = await FileIndex.shared.search(query, limit: 30) else { return [] }
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
        return items + commandItems()
    }

    private func commandItems() -> [PaletteItem] {
        let hasSelection = !browser.selectedURLs.isEmpty
        func command(_ title: String, _ symbol: String, _ shortcut: String?, keywords: [String] = [],
                     _ run: @escaping () -> Void) -> PaletteItem {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            return PaletteItem(title: title, subtitle: "", icon: image, kind: .action, shortcut: shortcut, keywords: keywords, run: run)
        }
        var commands = [
            command("New Folder", "folder.badge.plus", "⇧⌘N") { [weak self] in self?.browser.newFolder(nil) },
            command("New Tab", "plus.rectangle.on.rectangle", "⌘T") { [weak self] in self?.newWindowForTab(nil) },
            command("New Window", "macwindow.badge.plus", "⌘N") { (NSApp.delegate as? AppDelegate)?.newWindow(nil) },
            command("Open in Terminal", "terminal", "⌃⌘T") { [weak self] in self?.browser.openInTerminal(nil) },
            command("Copy Path", "link", "⌥⌘C") { [weak self] in self?.browser.copyPath(nil) },
            command(Prefs.showHidden ? "Hide Hidden Files" : "Show Hidden Files", Prefs.showHidden ? "eye.slash" : "eye.circle", "⇧⌘.") {
                Prefs.showHidden.toggle()
            },
            command(Prefs.foldersFirst ? "Mix Folders with Files" : "Keep Folders on Top", "folder", nil) { Prefs.foldersFirst.toggle() },
            command(splitController.splitViewItems.last?.isCollapsed == true ? "Show Inspector" : "Hide Inspector", "sidebar.right", "⌘I") { [weak self] in
                self?.splitController.toggleInspector(nil)
            },
            command(splitController.splitViewItems.first?.isCollapsed == true ? "Show Sidebar" : "Hide Sidebar", "sidebar.left", "⌃⌘S") { [weak self] in
                self?.splitController.toggleSidebar(nil)
            },
            command(isDualPane ? "Single Pane" : "Dual Pane", "rectangle.split.2x1", "⌘\\") { [weak self] in self?.toggleDualPane(nil) },
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
                command(browser.renameTitle, "pencil", browser.selectedURLs.count > 1 ? nil : "↩",
                        keywords: ["Batch", "Replace", "Number"]) { [weak self] in self?.browser.renameSelection(nil) },

                command("Delete Immediately…", "xmark.bin", "⌥⌘⌫", keywords: ["Remove", "Erase"]) { [weak self] in
                    self?.browser.deleteImmediately(nil)
                },
            ], at: 0)
        }
        if paneFolders != nil {
            commands.append(command("Compare with Other Pane…", "arrow.left.arrow.right.square", nil,
                                    keywords: ["Sync", "Diff", "Mirror", "Synchronize", "Folders"]) { [weak self] in
                self?.compareWithOtherPane(nil)
            })
        }
        if !browser.selectedURLs.isEmpty, !browser.isShowingTrash, browser.effectiveMode != .treemap, browser.canWriteBesideSelection {
            commands.insert(command(browser.compressTitle, "doc.zipper", nil, keywords: ["Zip", "Archive"]) { [weak self] in
                self?.browser.compress(nil)
            }, at: 0)
        }
        if !browser.selectedArchives.isEmpty, !browser.isShowingTrash, browser.canWriteBesideSelection {
            commands.insert(command(browser.extractTitle, "archivebox", nil, keywords: ["Unzip", "Expand", "Decompress"]) { [weak self] in
                self?.browser.extract(nil)
            }, at: 0)
        }
        // In the Trash: Put Back. Never offered for something inside a trashed folder.
        let selected = browser.selectedURLs
        if !selected.isEmpty, selected.allSatisfy(Trash.contains) {
            commands.insert(command("Put Back", "tray.and.arrow.up", "⌘⌫") { [weak self] in self?.browser.putBack(nil) }, at: 0)
        } else if !selected.isEmpty, !selected.contains(where: Trash.isInTrash) {
            commands.insert(command("Move to Trash", "trash", "⌘⌫") { [weak self] in self?.browser.moveToTrash(nil) }, at: 0)
        }
        commands.append(contentsOf: aiPaletteItems())
        if !Privacy.hasFullDiskAccess {
            commands.append(command("Grant Full Disk Access…", "lock.open", nil) { NSWorkspace.shared.open(Privacy.settingsURL) })
        }
        return commands
    }
}
