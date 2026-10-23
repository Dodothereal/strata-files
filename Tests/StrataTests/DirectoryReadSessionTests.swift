import AppKit
import Testing
@testable import Strata

struct DirectoryReadSessionTests {
    private typealias Reads = ControlledDirectoryReads

    private func browser(_ reads: Reads) -> BrowserViewController {
        let services = BrowserServices.configured(
            transfers: .shared,
            visits: .shared,
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared,
            directories: reads.reader)
        let browser = BrowserViewController(services: services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(.list, remember: false)
        return browser
    }

    @Test func navigatingDoesNotShowThePreviousVolumesFreeSpace() async throws {
        let tree = try TestTree("a/", "b/")
        let reads = Reads()
        defer { reads.stop() }
        let services = BrowserServices.configured(
            transfers: .shared,
            visits: .shared,
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared,
            directories: reads.reader,
            availableCapacity: { _ in 123 })
        let browser = BrowserViewController(services: services)
        _ = browser.view
        browser.load(tree.url("a"))
        let first = try #require(browser.directoryReads.task)
        try await reads.request(0).finish(.success([]))
        await first.value
        await browser.loading.capacityTask?.value
        #expect(browser.availableCapacity == 123)
        browser.load(tree.url("b"))
        #expect(browser.availableCapacity == nil)
        let next = try #require(browser.directoryReads.task)
        try await reads.request(1).finish(.success([]))
        await next.value
        #expect(tree.snapshot() == ["a/", "b/"])
    }

    @Test func nativeExpandedRowsKeepTheirCurrentReadAfterAnOlderResponse() async throws {
        let tree = try TestTree("folder/old.txt", "folder/new.txt")
        let reads = Reads()
        defer { reads.stop() }
        let browser = browser(reads)
        let folder = try #require(FileEntry(url: tree.url("folder")))
        let entry = try #require(FileEntry(url: tree.url("folder/new.txt")))
        browser.load(tree.root)
        let first = try #require(browser.directoryReads.task)
        try await reads.request(0).finish(.success([folder]))
        await first.value
        let node = try #require(browser.allRows.first)
        browser.outlineView.expandItem(node)
        let oldRequest = try await reads.request(1)
        let old = browser.loading.loadChildren(of: node, showHidden: false, applications: .standard) { _ in
            Issue.record("Native expansion did not own its read")
        }
        browser.refresh()
        let refreshed = try #require(browser.directoryReads.task)
        try await reads.request(2).finish(.success([folder]))
        await refreshed.value
        let currentRequest = try await reads.request(3)
        let current = browser.loading.loadChildren(of: node, showHidden: false, applications: .standard) { _ in
            Issue.record("Native refresh did not own its child read")
        }
        oldRequest.finish(.success([]))
        await old.value
        #expect(old.isCancelled && node.children == nil)
        #expect(browser.outlineView.isItemExpanded(node))
        currentRequest.finish(.success([entry]))
        await current.value
        #expect(browser.outlineView.numberOfRows == 2)
        #expect((browser.outlineView.item(atRow: 1) as? FileNode)?.entry == entry)
        browser.select([entry.url])
        #expect(browser.selectedURLs == [entry.url])
        #expect(tree.snapshot() == ["folder/", "folder/new.txt", "folder/old.txt"])
    }

    @Test func aNewFolderRejectsOldSuccessesAndErrorsInEveryView() async throws {
        let tree = try TestTree("a/old.txt", "b/new.txt", "untouched.txt")
        let old = try #require(FileEntry(url: tree.url("a/old.txt")))
        let new = try #require(FileEntry(url: tree.url("b/new.txt")))
        for mode in BrowserViewMode.ordered {
            for failOld in [false, true] {
                let reads = Reads()
                defer { reads.stop() }
                let browser = browser(reads)
                browser.setMode(mode, remember: false)
                browser.load(tree.url("a"))
                let oldWork = try #require(browser.directoryReads.task)
                let oldRequest = try await reads.request(0)
                browser.load(tree.url("b"), select: new.url)
                let newWork = try #require(browser.directoryReads.task)
                let newRequest = try await reads.request(1)
                newRequest.finish(.success([new]))
                await newWork.value
                #expect(browser.selectedURLs.map(\.fileViewKey) == [new.url.fileViewKey])
                oldRequest.finish(failOld ? .failure(CocoaError(.fileReadNoPermission)) : .success([old]))
                await oldWork.value
                #expect(browser.loadError == nil && !browser.isLoadingFolder)
                #expect(browser.topLevelEntries.map(\.url) == [new.url])
                #expect(browser.selectedURLs.map(\.fileViewKey) == [new.url.fileViewKey])
                #expect(browser.directory == tree.url("b"))
            }
        }
        #expect(tree.snapshot() == ["a/", "a/old.txt", "b/", "b/new.txt", "untouched.txt"])
    }

    @Test func resultsAndMessagesInvalidateOutstandingFolderReads() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let a = try #require(FileEntry(url: tree.url("a.txt")))
        let b = try #require(FileEntry(url: tree.url("b.txt")))
        for presentation in 0..<3 {
            let reads = Reads()
            defer { reads.stop() }
            let browser = browser(reads)
            browser.load(tree.root)
            let work = try #require(browser.directoryReads.task)
            let request = try await reads.request(0)
            switch presentation {
            case 0: browser.showResults([b], total: 1)
            case 1: browser.showGroups([(title: "Group", detail: "", entries: [b])], summary: "")
            default: browser.showMessage(symbol: "magnifyingglass", title: "Waiting")
            }
            request.finish(.success([a]))
            await work.value
            #expect(browser.isShowingResults)
            #expect(!browser.topLevelEntries.contains { $0.url == a.url })
            #expect(browser.loadError == nil)
            if presentation != 2 {
                browser.select([b.url])
                #expect(browser.selectedURLs == [b.url])
            }
        }
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func aRefreshSupersedesAReadOfTheSameFolderAndDeliversItsError() async throws {
        let tree = try TestTree("a.txt")
        let reads = Reads()
        defer { reads.stop() }
        let browser = browser(reads)
        browser.load(tree.root)
        let first = try #require(browser.directoryReads.task)
        let old = try await reads.request(0)
        browser.refresh()
        let latest = try #require(browser.directoryReads.task)
        let current = try await reads.request(1)
        current.finish(.failure(CocoaError(.fileReadNoPermission)))
        await latest.value
        old.finish(.success([try #require(FileEntry(url: tree.url("a.txt")))]))
        await first.value
        #expect((browser.loadError as? CocoaError)?.code == .fileReadNoPermission)
        #expect(browser.isLoaded && !browser.isLoadingFolder && browser.topLevelEntries.isEmpty)
        #expect(tree.snapshot() == ["a.txt"])
    }

    @Test func columnsRejectStaleReadsAndStopApplyingAfterTeardown() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let reads = Reads()
        defer { reads.stop() }
        let controller = ColumnBrowserViewController(directoryReader: reads.reader)
        let pane = ColumnPane(folder: tree.root, controller: controller)
        let a = try #require(FileEntry(url: tree.url("a.txt")))
        let b = try #require(FileEntry(url: tree.url("b.txt")))
        pane.load(showHidden: false, order: ColumnBrowserViewController.defaultOrder)
        let first = try #require(pane.directoryReads.task)
        let old = try await reads.request(0)
        pane.load(showHidden: true, order: ColumnBrowserViewController.defaultOrder)
        let latest = try #require(pane.directoryReads.task)
        let current = try await reads.request(1)
        #expect(current.showHidden && !old.showHidden)
        current.finish(.success([b]))
        await latest.value
        old.finish(.failure(CocoaError(.fileReadNoPermission)))
        await first.value
        #expect(pane.entries.map(\.url) == [b.url])
        pane.load(showHidden: true, order: ColumnBrowserViewController.defaultOrder)
        let removed = try #require(pane.directoryReads.task)
        let last = try await reads.request(2)
        pane.tearDown()
        last.finish(.success([a]))
        await removed.value
        #expect(pane.entries.map(\.url) == [b.url])
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func pendingReadsDoNotKeepTheirBrowserAlive() async throws {
        let tree = try TestTree("a.txt")
        let reads = Reads()
        defer { reads.stop() }
        var browser: BrowserViewController? = browser(reads)
        weak var owner: BrowserViewController?
        owner = browser
        browser?.load(tree.root)
        let work = try #require(browser?.directoryReads.task)
        let request = try await reads.request(0)
        browser = nil
        let deadline = ContinuousClock.now + .seconds(10)
        while owner != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let released = owner == nil
        #expect(released)
        request.finish(.success([try #require(FileEntry(url: tree.url("a.txt")))]))
        await work.value
        #expect(work.isCancelled)
        #expect(tree.snapshot() == ["a.txt"])
    }

    @Test func aCompletionCanStartTheNextReadWithoutLosingItsTask() async throws {
        let tree = try TestTree("installed/", "system/")
        let reads = Reads()
        defer { reads.stop() }
        let session = DirectoryReadSession(reader: reads.reader)
        let applications = ApplicationsFolders(installed: tree.url("installed"), system: tree.url("system"))
        var completions = 0
        let first = session.load(tree.root, showHidden: true, applications: applications) { _, _ in
            completions += 1
            session.load(tree.root, showHidden: false, applications: applications) { _, _ in completions += 1 }
        }
        let request = try await reads.request(0)
        #expect(request.showHidden && request.applications.system == applications.system)
        request.finish(.success([]))
        await first.value
        let next = try #require(session.task)
        let following = try await reads.request(1)
        #expect(!following.showHidden && following.applications.installed == applications.installed)
        following.finish(.success([]))
        await next.value
        #expect(session.task == nil && completions == 2)
        #expect(tree.snapshot() == ["installed/", "system/"])
    }
    @Test func aReloadHonorsEmptySelectionAndEachViewsSelectionPolicy() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let entries = try ["a.txt", "b.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        for mode in BrowserViewMode.ordered {
            let reads = Reads()
            defer { reads.stop() }
            let browser = browser(reads)
            browser.setMode(mode, remember: false)
            browser.load(tree.root)
            var work = try #require(browser.directoryReads.task)
            try await reads.request(0).finish(.success(entries))
            await work.value
            browser.select([entries[0].url])
            browser.selectWhenShown([])
            work = try #require(browser.directoryReads.task)
            try await reads.request(1).finish(.success(entries))
            await work.value
            // Gallery always keeps an item in front for its preview; the other views allow no selection.
            #expect(browser.selectedURLs == (mode == .gallery ? [entries[0].url] : []), "\(mode)")
            #expect(browser.pendingSelection == nil)
            browser.select([entries[1].url])
            browser.refresh()
            work = try #require(browser.directoryReads.task)
            try await reads.request(2).finish(.success(entries))
            await work.value
            #expect(browser.selectedURLs == [entries[1].url])
        }
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func pendingSelectionsApplyToRefreshedResultsAndGroups() throws {
        let tree = try TestTree("a.txt", "b.txt")
        let reads = Reads()
        defer { reads.stop() }
        let browser = browser(reads)
        let entries = try ["a.txt", "b.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        browser.showResults(entries, total: 2)
        browser.select([entries[0].url])
        browser.pendingSelection = [entries[1].url]
        browser.showResults(entries, total: 2)
        #expect(browser.selectedURLs == [entries[1].url])
        browser.pendingSelection = []
        browser.showResults(entries, total: 2)
        #expect(browser.selectedURLs.isEmpty && browser.pendingSelection == nil)
        browser.showGroups([(title: "Files", detail: "", entries: entries)], summary: "")
        browser.pendingSelection = [entries[0].url]
        browser.showGroups([(title: "Files", detail: "", entries: entries)], summary: "")
        #expect(browser.selectedURLs == [entries[0].url] && browser.pendingSelection == nil)
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func operationCompletionSelectsAfterReadingItsOriginalPaneInEveryView() async throws {
        let tree = try TestTree("left/old.txt", "left/new.txt", "right/other.txt")
        let old = try #require(FileEntry(url: tree.url("left/old.txt")))
        let new = try #require(FileEntry(url: tree.url("left/new.txt")))
        let other = try #require(FileEntry(url: tree.url("right/other.txt")))
        for mode in BrowserViewMode.ordered {
            let reads = Reads()
            defer { reads.stop() }
            let controller = window(tree.url("left"), second: tree.url("right"), reads: reads)
            defer { controller.window?.contentViewController = nil }
            let first = controller.browser, second = try #require(controller.otherBrowser)
            let firstLoad = try #require(first.directoryReads.task), secondLoad = try #require(second.directoryReads.task)
            try await reads.request(0).finish(.success([old]))
            try await reads.request(1).finish(.success([other]))
            await firstLoad.value
            await secondLoad.value
            first.setMode(mode, remember: false)
            first.select([old.url])
            let completion = controller.selectionAfterOperation()
            second.select([other.url])
            controller.window?.makeFirstResponder(second.focusView)
            try #require(controller.browser === second)
            completion([new.url, other.url])
            let refresh = try #require(first.directoryReads.task)
            let request = try await reads.request(2)
            #expect(request.folder.standardizedFileURL.fileViewKey == tree.url("left").standardizedFileURL.fileViewKey)
            #expect(first.selectedURLs == [old.url])
            request.finish(.success([old, new]))
            await refresh.value
            #expect(first.selectedURLs == [new.url])
            #expect(second.selectedURLs == [other.url] && controller.browser === second)
            #expect(controller.window?.isVisible == false)
        }
        #expect(tree.snapshot() == ["left/", "left/new.txt", "left/old.txt", "right/", "right/other.txt"])
    }

    @Test func operationCompletionRejectsLeavingAndReturningAndRemovedPanes() async throws {
        let tree = try TestTree("left/a.txt", "right/b.txt")
        let a = try #require(FileEntry(url: tree.url("left/a.txt")))
        let b = try #require(FileEntry(url: tree.url("right/b.txt")))
        let reads = Reads()
        defer { reads.stop() }
        let controller = window(tree.url("left"), second: tree.url("right"), reads: reads)
        defer { controller.window?.contentViewController = nil }
        let first = controller.browser, second = try #require(controller.otherBrowser)
        let firstLoad = try #require(first.directoryReads.task), secondLoad = try #require(second.directoryReads.task)
        try await reads.request(0).finish(.success([a]))
        try await reads.request(1).finish(.success([b]))
        await firstLoad.value
        await secondLoad.value
        let stale = controller.selectionAfterOperation()
        controller.navigate(to: tree.url("right"))
        var work = try #require(first.directoryReads.task)
        try await reads.request(2).finish(.success([b]))
        await work.value
        controller.navigate(to: tree.url("left"))
        work = try #require(first.directoryReads.task)
        try await reads.request(3).finish(.success([a]))
        await work.value
        stale([a.url])
        #expect(first.directoryReads.task == nil && first.pendingSelection == nil)
        controller.window?.makeFirstResponder(second.focusView)
        let removedPane = controller.pane
        let removed = controller.selectionAfterOperation()
        controller.window?.makeFirstResponder(first.focusView)
        controller.toggleDualPane(at: nil)
        removed([b.url])
        #expect(removedPane.browser.directoryReads.task == nil && removedPane.browser.pendingSelection == nil)
        #expect(controller.browser === first && !controller.isDualPane)
        #expect(tree.snapshot() == ["left/", "left/a.txt", "right/", "right/b.txt"])
    }

    @Test func changingSearchTextScopeOrCaseCancelsCapturedActions() async throws {
        let tree = try TestTree("a.txt")
        let reads = Reads()
        defer { reads.stop() }
        let controller = window(tree.root, second: nil, reads: reads)
        defer { controller.window?.contentViewController = nil }
        let pane = controller.pane, browser = pane.browser
        let entry = try #require(FileEntry(url: tree.url("a.txt")))
        let initial = try #require(browser.directoryReads.task)
        try await reads.request(0).finish(.success([entry]))
        await initial.value
        // All search controls write the pane's destination, including changes that keep the same history entry.
        let original = Destination.search("a", scope: nil)
        for changed in [Destination.search("b", scope: nil), .search("a", scope: tree.root), .search("case:a", scope: nil)] {
            pane.destination = original
            browser.showResults([entry], total: 1)
            let completion = controller.selectionAfterOperation()
            let revision = pane.navigationRevision
            browser.pendingSelection = [entry.url]
            pane.destination = changed
            #expect(pane.navigationRevision == revision + 1 && browser.pendingSelection == nil)
            pane.destination = original
            let searchGeneration = pane.searchGeneration
            completion([entry.url])
            #expect(pane.searchGeneration == searchGeneration && browser.pendingSelection == nil)
            #expect(browser.directoryReads.task == nil)
            let unchanged = pane.navigationRevision
            pane.destination = original
            #expect(pane.navigationRevision == unchanged)
        }
        #expect(tree.snapshot() == ["a.txt"])
    }

    @Test func deeperColumnRenameWaitsUntilTheItemIsApplied() async throws {
        let tree = try TestTree("folder/old.txt", "folder/new.txt", "folder/keep.txt", "else.txt")
        let reads = Reads()
        defer { reads.stop() }
        let (browser, pane) = try await deeperColumn(tree, reads: reads)
        let old = try #require(FileEntry(url: tree.url("folder/old.txt")))
        let new = try #require(FileEntry(url: tree.url("folder/new.txt")))
        browser.renameWhenShown(new.url, in: tree.url("folder"))
        var work = try #require(pane.directoryReads.task)
        #expect(views(browser.view, of: InlineRenameField.self).isEmpty)
        // A listing can arrive before the new item is visible on a remote filesystem.
        try await reads.request(2).finish(.success([old]))
        await work.value
        #expect(views(browser.view, of: InlineRenameField.self).isEmpty)
        pane.load(showHidden: false, order: ColumnBrowserViewController.defaultOrder)
        work = try #require(pane.directoryReads.task)
        try await reads.request(3).finish(.success([old, new]))
        await work.value
        let field = try #require(views(browser.view, of: InlineRenameField.self).first)
        #expect(field.stringValue == "new.txt")
        #expect(browser.selectedURLs == [new.url])
        #expect(tree.snapshot() == ["else.txt", "folder/", "folder/keep.txt", "folder/new.txt", "folder/old.txt"])
    }

    @Test func aColumnReloadCanDropTheOldSelectionWithoutCancellingTheNewItemsRename() async throws {
        for name in ["new.txt", "new/"] {
            let tree = try TestTree("folder/old.txt", "folder/" + name, "folder/keep.txt", "else.txt")
            let original = tree.snapshot()
            let reads = Reads()
            defer { reads.stop() }
            let (browser, pane) = try await deeperColumn(tree, reads: reads)
            let new = try #require(FileEntry(url: tree.url("folder/" + name)))
            browser.renameWhenShown(new.url, in: tree.url("folder"))
            let work = try #require(pane.directoryReads.task)
            // The old selected item disappears from the listing at the same time the created item becomes visible.
            try await reads.request(2).finish(.success([new]))
            await work.value
            let field = try #require(views(browser.view, of: InlineRenameField.self).first)
            #expect(field.stringValue == new.name && browser.selectedURLs == [new.url])
            #expect(tree.snapshot() == original)
        }
    }

    @Test func aPendingColumnRevealDoesNotOverrideARenameRequestedWhileItLoads() async throws {
        for keyboard in [false, true] {
            let tree = try TestTree("folder/old.txt", "folder/new.txt", "else.txt")
            let reads = Reads()
            defer { reads.stop() }
            let browser = browser(reads)
            browser.setMode(.columns, remember: false)
            browser.load(tree.root)
            let initial = try #require(browser.directoryReads.task)
            let root = try ["folder", "else.txt"].map { try #require(FileEntry(url: tree.url($0))) }
            try await reads.request(0).finish(.success(root))
            await initial.value
            browser.select([tree.url(keyboard ? "folder" : "folder/old.txt")])
            if keyboard {
                let rootPane = try #require(views(browser.columns.view, of: ColumnPane.self).first)
                let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, characters: "\u{F703}",
                                                         charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
                rootPane.tableView.keyDown(with: right)
            }
            let previous = try await reads.request(1)
            let pane = try #require(views(browser.columns.view, of: ColumnPane.self).last)
            let oldRead = try #require(pane.directoryReads.task)
            browser.renameWhenShown(tree.url("folder/new.txt"), in: tree.url("folder"))
            let currentRead = try #require(pane.directoryReads.task)
            let entries = try ["old.txt", "new.txt"].map { try #require(FileEntry(url: tree.url("folder/" + $0))) }
            try await reads.request(2).finish(.success(entries))
            await currentRead.value
            previous.finish(.success([entries[0]]))
            await oldRead.value
            browser.columns.view.layoutSubtreeIfNeeded()
            let field = try #require(views(browser.view, of: InlineRenameField.self).first)
            #expect(field.stringValue == "new.txt" && browser.selectedURLs == [entries[1].url])
            #expect(tree.snapshot() == ["else.txt", "folder/", "folder/new.txt", "folder/old.txt"])
        }
    }

    @Test func deferredColumnRenamesStopAfterNavigationSelectionModeChangesAndErrors() async throws {
        let tree = try TestTree("folder/old.txt", "folder/new.txt", "folder/keep.txt", "else.txt")
        let entries = try ["old.txt", "new.txt", "keep.txt"].map { try #require(FileEntry(url: tree.url("folder/" + $0))) }
        for change in 0..<4 {
            let reads = Reads()
            defer { reads.stop() }
            let (browser, pane) = try await deeperColumn(tree, reads: reads)
            browser.renameWhenShown(tree.url("folder/new.txt"), in: tree.url("folder"))
            let work = try #require(pane.directoryReads.task)
            let request = try await reads.request(2)
            switch change {
            case 0: browser.select([tree.url("else.txt")])
            case 1: pane.select([tree.url("folder/keep.txt")], scroll: false)
            case 2: browser.setMode(.grid, remember: false)
            default: break
            }
            request.finish(change == 3 ? .failure(CocoaError(.fileReadNoPermission)) : .success(entries))
            await work.value
            if change == 3 {
                pane.load(showHidden: false, order: ColumnBrowserViewController.defaultOrder)
                let retry = try #require(pane.directoryReads.task)
                try await reads.request(3).finish(.success(entries))
                await retry.value
            }
            #expect(views(browser.columns.view, of: InlineRenameField.self).isEmpty)
        }
        #expect(tree.snapshot() == ["else.txt", "folder/", "folder/keep.txt", "folder/new.txt", "folder/old.txt"])
    }

    @Test func endingAnInlineEditCannotApplyAListingSupersededByAnotherRead() async throws {
        let tree = try TestTree("old.txt", "stale.txt", "current.txt")
        let reads = Reads()
        defer { reads.stop() }
        let controller = window(tree.root, second: nil, reads: reads)
        defer { controller.window?.contentViewController = nil }
        let browser = controller.browser
        browser.setMode(.list, remember: false)
        let entries = try ["old.txt", "stale.txt", "current.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        var work = try #require(browser.directoryReads.task)
        try await reads.request(0).finish(.success([entries[0]]))
        await work.value
        browser.select([entries[0].url])
        browser.renameSelection(nil)
        let field = try #require(views(browser.view, of: NSTextField.self).first { $0.isEditable && $0.stringValue == "old.txt" })
        try #require(field.currentEditor() != nil)
        browser.refresh()
        work = try #require(browser.directoryReads.task)
        try await reads.request(1).finish(.success([entries[0], entries[1]]))
        await work.value
        #expect(browser.topLevelEntries.map(\.url) == [entries[0].url])
        browser.refresh()
        work = try #require(browser.directoryReads.task)
        let currentRead = try await reads.request(2)
        // End the native field edit without changing its name while the newer read is still pending.
        controller.window?.makeFirstResponder(browser.outlineView)
        #expect(browser.topLevelEntries.map(\.url) == [entries[0].url])
        currentRead.finish(.success([entries[0], entries[2]]))
        await work.value
        #expect(Set(browser.topLevelEntries.map(\.url)) == Set([entries[0].url, entries[2].url]))
        #expect(controller.window?.isVisible == false)
        #expect(tree.snapshot() == ["current.txt", "old.txt", "stale.txt"])
    }

    @Test func aFailedRootRenameRequestDoesNotRestartOnALaterRefresh() async throws {
        let tree = try TestTree("old.txt", "new.txt")
        for mode in [BrowserViewMode.list, .grid, .columns, .gallery] {
            let reads = Reads()
            defer { reads.stop() }
            let browser = browser(reads)
            browser.setMode(mode, remember: false)
            let entries = try ["old.txt", "new.txt"].map { try #require(FileEntry(url: tree.url($0))) }
            browser.load(tree.root)
            var work = try #require(browser.directoryReads.task)
            try await reads.request(0).finish(.success([entries[0]]))
            await work.value
            browser.renameWhenShown(entries[1].url, in: tree.root)
            work = try #require(browser.directoryReads.task)
            try await reads.request(1).finish(.failure(CocoaError(.fileReadNoPermission)))
            await work.value
            browser.refresh()
            work = try #require(browser.directoryReads.task)
            try await reads.request(2).finish(.success(entries))
            await work.value
            #expect(views(browser.view, of: InlineRenameField.self).isEmpty, "\(mode)")
            #expect(!views(browser.view, of: NSTextField.self).contains { $0.isEditable && $0.stringValue == "new.txt" }, "\(mode)")
        }
        #expect(tree.snapshot() == ["new.txt", "old.txt"])
    }

    private func deeperColumn(_ tree: TestTree, reads: Reads) async throws -> (BrowserViewController, ColumnPane) {
        let browser = browser(reads)
        browser.setMode(.columns, remember: false)
        browser.load(tree.root)
        let initial = try #require(browser.directoryReads.task)
        let rootEntries = try ["folder", "else.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        try await reads.request(0).finish(.success(rootEntries))
        await initial.value
        browser.select([tree.url("folder/old.txt")])
        let request = try await reads.request(1)
        let pane = try #require(views(browser.columns.view, of: ColumnPane.self).first {
            $0.folder.standardizedFileURL.fileViewKey == tree.url("folder").standardizedFileURL.fileViewKey
        })
        let work = try #require(pane.directoryReads.task)
        let children = try ["old.txt", "keep.txt"].map { try #require(FileEntry(url: tree.url("folder/" + $0))) }
        request.finish(.success(children))
        await work.value
        browser.columns.view.layoutSubtreeIfNeeded()
        #expect(browser.selectedURLs == [tree.url("folder/old.txt")])
        return (browser, pane)
    }

    private func window(_ folder: URL, second: URL?, reads: Reads) -> BrowserWindowController {
        _ = NSApplication.shared
        let services = BrowserServices.configured(
            transfers: .shared,
            visits: .shared,
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared,
            directories: reads.reader)
        let controller = BrowserWindowController(location: folder, secondPane: second, services: services)
        controller.split.splitView.autosaveName = nil
        controller.window?.setFrameAutosaveName("")
        return controller
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

}
