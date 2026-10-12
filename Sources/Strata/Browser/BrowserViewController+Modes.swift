import AppKit
import Quartz

/// List, icons, columns and disk usage: the other presentations are child view controllers fed the same rows.
extension BrowserViewController {
    /// Results (search, Recents, Duplicates) have no single folder, so they always use the list.
    var effectiveMode: BrowserViewMode { isShowingResults ? .list : mode }

    var activeView: FileCollectionController? {
        switch effectiveMode {
        case .list: nil
        case .grid: grid
        case .columns: columns
        case .treemap: treemap
        }
    }

    /// The view that should have keyboard focus.
    var focusView: NSView { activeView?.focusView ?? outlineView }

    /// Where new folders and pastes go: the focused column in column view, otherwise the current folder.
    var targetDirectory: URL? {
        if effectiveMode == .columns, let active = columnController?.activeDirectory { return active }
        return directory
    }

    @objc func setViewMode(_ sender: Any?) {
        let picked: BrowserViewMode? = if let group = sender as? NSToolbarItemGroup {
            BrowserViewMode.ordered.indices.contains(group.selectedIndex) ? BrowserViewMode.ordered[group.selectedIndex] : nil
        } else {
            BrowserViewMode(rawValue: (sender as? NSMenuItem)?.tag ?? 0)
        }
        guard let mode = picked else { return }
        setMode(mode)
    }

    func setMode(_ newMode: BrowserViewMode) {
        guard newMode != mode else { return }
        let selection = selectedURLs
        setStoredMode(newMode)
        Prefs.viewMode = newMode.rawValue
        installActiveView()
        pushContent()
        select(selection)
        view.window?.makeFirstResponder(focusView)
        delegate?.browserSelectionDidChange(self)
    }

    @objc func biggerIcons(_ sender: Any?) {
        grid.setIconSize(min(256, grid.iconSize * 1.25), animated: true)
        Prefs.gridIconSize = Double(grid.iconSize)
    }

    @objc func smallerIcons(_ sender: Any?) {
        grid.setIconSize(max(32, grid.iconSize / 1.25), animated: true)
        Prefs.gridIconSize = Double(grid.iconSize)
    }

    /// Shows the active presentation's view on top of the list (the list's scroll view hides).
    func installActiveView() {
        let active = activeView
        for controller in [gridController, columnController, treemapController] as [NSViewController?] {
            guard let controller, controller !== active, controller.isViewLoaded else { continue }
            controller.view.removeFromSuperview()
        }
        guard let active else {
            outlineScrollView.isHidden = false
            return
        }
        if active.parent == nil { addChild(active) }
        if active.view.superview == nil {
            active.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(active.view, positioned: .above, relativeTo: outlineScrollView)
            // Columns are scroll views nested in a scroll view, which don't get the toolbar inset: start them below it.
            let inset = active is ColumnBrowserViewController
            NSLayoutConstraint.activate([
                active.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                active.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                active.view.topAnchor.constraint(equalTo: inset ? view.safeAreaLayoutGuide.topAnchor : view.topAnchor),
                active.view.bottomAnchor.constraint(equalTo: inset ? view.safeAreaLayoutGuide.bottomAnchor : view.bottomAnchor),
            ])
        }
        outlineScrollView.isHidden = true
    }

    /// Hands the current rows (sorted, filtered, with match highlights) to the active presentation.
    func pushContent(animated: Bool = false) {
        guard let directory, !isShowingResults else { return }
        let shown = visibleRows
        var matches: [URL: [Int]] = [:]
        for node in shown where !node.matchIndices.isEmpty { matches[node.url] = node.matchIndices }
        switch effectiveMode {
        case .list:
            break
        case .grid:
            grid.directory = directory
            grid.setEntries(shown.map(\.entry), matches: matches)
        case .columns:
            columns.sortComparator = { [weak self] a, b in self?.ordered(a, b) ?? (a.name.localizedStandardCompare(b.name) == .orderedAscending) }
            columns.setRoot(directory, entries: shown.map(\.entry), matches: matches)
        case .treemap:
            // Folders that can't be measured without Full Disk Access would silently shrink the total: say so.
            treemap.unmeasured = shown.filter {
                $0.entry.isDirectory && !$0.entry.isSymlink && !$0.entry.isVolume && !canMeasure($0.entry)
            }.count
            treemap.setEntries(shown.map(\.entry), size: { [weak self] entry in
                guard let self else { return nil }
                guard entry.isDirectory else { return entry.size }
                return canMeasure(entry) ? folderSize(entry.url, request: true)?.bytes : 0
            }, animated: animated)
        }
    }

    // MARK: - Lazily created presentations

    var grid: GridViewController {
        if let gridController { return gridController }
        let controller = GridViewController()
        controller.fileDelegate = self
        controller.setIconSize(CGFloat(Prefs.gridIconSize), animated: false)
        gridController = controller
        return controller
    }

    var columns: ColumnBrowserViewController {
        if let columnController { return columnController }
        let controller = ColumnBrowserViewController()
        controller.fileDelegate = self
        controller.onLocationChange = { [weak self] url in
            guard let self else { return }
            delegate?.browser(self, columnLocationChanged: url)
        }
        columnController = controller
        return controller
    }

    var treemap: TreemapViewController {
        if let treemapController { return treemapController }
        let controller = TreemapViewController()
        controller.fileDelegate = self
        controller.onDrill = { [weak self] url in
            guard let self else { return }
            delegate?.browser(self, navigateTo: url)
        }
        treemapController = controller
        return controller
    }
}

extension BrowserViewController: FileCollectionViewDelegate {
    func fileView(_ view: NSViewController, open entries: [FileEntry]) {
        openEntries(entries)
    }

    func fileView(_ view: NSViewController, selectionDidChange urls: [URL]) {
        delegate?.browserSelectionDidChange(self)
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func fileView(_ view: NSViewController, menuFor entries: [FileEntry]) -> NSMenu? {
        contextMenu()
    }

    func fileView(_ view: NSViewController, springLoad folder: URL, drag: Int) {
        springLoad(folder, drag: drag)
    }

    func fileView(_ view: NSViewController, canSpringLoad folder: URL) -> Bool {
        SpringLoader.canOpen(folder, browsing: directory)
    }

    func fileView(_ view: NSViewController, drop urls: [URL], onto folder: URL?, copy: Bool) -> Bool {
        guard let target = folder ?? targetDirectory else { return false }
        moveOrCopy(urls, into: target, move: !copy)
        return true
    }

    /// Same keys as the list: typing filters, Return renames (or opens), Space previews, Esc clears the filter.
    func fileView(_ view: NSViewController, handle key: FileViewKey) -> Bool {
        switch key {
        case .type(let text):
            setFilter(filter + text)
        case .backspace:
            guard !filter.isEmpty else { return false }
            setFilter(String(filter.dropLast()))
        case .escape:
            guard !filter.isEmpty else { return false }
            setFilter("")
        case .returnKey:
            // Disk Usage can't rename in place, so Return opens there.
            if filter.isEmpty && !Prefs.returnOpens && effectiveMode != .treemap { renameSelection(nil) } else { openSelection(nil) }
        case .space:
            if filter.isEmpty { toggleQuickLook(nil) } else { setFilter(filter + " ") }
        case .tab:
            return onTab?() ?? false
        }
        return true
    }

    func fileView(_ view: NSViewController, rename entry: FileEntry, to name: String) {
        renameItem(entry.url, to: name)
    }
}
