import AppKit
import Testing
@testable import Strata

struct DirectoryReadSessionTests {
    private final class Reads {
        final class Request {
            let folder: URL
            let showHidden: Bool
            let applications: ApplicationsFolders
            var continuation: CheckedContinuation<[FileEntry], Error>?

            init(_ folder: URL, _ showHidden: Bool, _ applications: ApplicationsFolders,
                 _ continuation: CheckedContinuation<[FileEntry], Error>) {
                self.folder = folder
                self.showHidden = showHidden
                self.applications = applications
                self.continuation = continuation
            }

            func finish(_ result: Result<[FileEntry], Error>) {
                let waiting = continuation
                continuation = nil
                waiting?.resume(with: result)
            }
        }

        private(set) var requests: [Request] = []
        private var stopped = false
        var reader: DirectoryReader {
            DirectoryReader { folder, hidden, applications in
                try await self.read(folder, hidden, applications)
            }
        }

        private func read(_ folder: URL, _ hidden: Bool, _ applications: ApplicationsFolders) async throws -> [FileEntry] {
            if stopped { throw CancellationError() }
            // Deliberately ignore cancellation, like synchronous filesystem I/O that is already in flight.
            return try await withCheckedThrowingContinuation { requests.append(Request(folder, hidden, applications, $0)) }
        }

        func request(_ index: Int) async throws -> Request {
            let deadline = ContinuousClock.now + .seconds(20)
            while requests.count <= index {
                try #require(ContinuousClock.now < deadline, "The controlled reader was not called.")
                try await Task.sleep(for: .milliseconds(10))
            }
            return requests[index]
        }

        func stop() {
            stopped = true
            requests.forEach { $0.finish(.failure(CancellationError())) }
        }
    }

    private func browser(_ reads: Reads) -> BrowserViewController {
        let services = BrowserServices(transfers: .shared, visits: .shared, directories: reads.reader)
        let browser = BrowserViewController(services: services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(.list, remember: false)
        return browser
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
        weak var owner = browser
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
}
