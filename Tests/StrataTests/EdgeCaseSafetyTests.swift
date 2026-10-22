import AppKit
import Foundation
import Testing
@testable import Strata
@testable import StrataIndex
@testable import StrataModel
@testable import StrataPreviews
@testable import StrataSupport

struct EdgeCaseSafetyTests {
    @Test func extremeSpotlightAndNaturalQueriesNeverOverflowOrTrap() {
        for raw in [
            "width:99999999999999999999999",
            "height:>100000000000000000000000",
            "pages:<99999999999999999999999",
            "size:>1e308gb",
            "duration:>1e300h",
            "duration:99999999999999999999999s",
        ] {
            _ = SpotlightQuery.parse(raw)
        }

        for natural in [
            "modified 9999999999999999999 weeks ago",
            "created last 9999999999999999999 months",
            "from 9223372036854775807",
            "modified:>9999999999999999999w",
            "size:>1e308gb",
        ] {
            let interpreted = QueryInterpreter.parse(natural)
            #expect(interpreted.source == .rules)
        }
    }

    @Test func summarizerSectionsHandleZeroAndSingleSectionLimits() {
        let text = String(repeating: "abcdef", count: 1000)
        #expect(Summarizer.sections(text, size: 0, limit: 4).kept.isEmpty)
        #expect(Summarizer.sections(text, size: -10, limit: 4).kept.isEmpty)
        #expect(Summarizer.sections(text, size: 100, limit: 0).kept.isEmpty)
        let single = Summarizer.sections(text, size: 100, limit: 1)
        #expect(single.kept.count == 1 && single.kept[0].count == 100)
    }

    @Test func halfPrecisionEncodingHandlesEmptyVectors() {
        let encoded = Half.encode([])
        #expect(encoded.isEmpty)
        let roundTrip = Half.encode([1.5, -2.0])
        #expect(roundTrip.count == 2)
        var decoded = [Float](repeating: 0, count: 2)
        roundTrip.withUnsafeBufferPointer { buffer in
            decoded.withUnsafeMutableBufferPointer { out in
                Half.decode(buffer, into: out.baseAddress!)
            }
        }
        #expect(decoded == [1.5, -2.0])
    }

    @Test func streamDemuxRejectsOversizeFrameHeaderBeforeBufferingPayload() {
        var demux = StreamDemux(outputLimit: 1024, errorLimit: 1024)
        let hugeHeader = Data([1, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: UnixHTTP.Failure.tooLarge) {
            _ = try demux.feed(hugeHeader)
        }
        #expect(demux.output.isEmpty)
    }

    @Test func treemapProducesFiniteRectsForExtremeRatiosAndDetachesDisplayLink() throws {
        let frames = Treemap.squarify([1e16, 1, 1], in: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(frames.count == 3)
        for frame in frames {
            #expect(frame.origin.x.isFinite && frame.origin.y.isFinite)
            #expect(frame.width.isFinite && frame.height.isFinite)
            #expect(frame.width >= 0 && frame.height >= 0)
        }
        #expect(Treemap.squarify([10, 5], in: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)) == [.zero, .zero])

        let tree = try TestTree("a.txt", "b.txt")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        weak var weakController: TreemapViewController?
        do {
            let controller = TreemapViewController()
            weakController = controller
            window.contentView = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            controller.view.layoutSubtreeIfNeeded()
            let first = [TreemapItem(url: tree.url("a.txt"), name: "a.txt", bytes: 1000, isFolder: false)]
            let second = [TreemapItem(url: tree.url("a.txt"), name: "a.txt", bytes: 500, isFolder: false),
                          TreemapItem(url: tree.url("b.txt"), name: "b.txt", bytes: 500, isFolder: false)]
            controller.setItems(first, animated: false)
            controller.setItems(second, animated: true)
            window.contentView = nil
        }
        #expect(weakController == nil)
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func namedPipesDoNotBlockInspectorGitProjectOrDelimitedReaders() async throws {
        let tree = try TestTree("kept.txt")
        let fifo = tree.url("compose.yaml")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let writer = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(writer >= 0)
        defer { close(writer) }
        let payload = "services:\n  web:\n    image: nginx\n"
        let written = payload.withCString { write(writer, $0, payload.utf8.count) }
        try #require(written == payload.utf8.count)

        #expect(ComposeInspectorView.serviceNames(in: fifo).isEmpty)
        #expect(ProjectDetector.makeTargets(fifo, directory: tree.root, source: "Makefile").isEmpty)
        #expect(ProjectDetector.justRecipes(fifo, directory: tree.root, source: "justfile").isEmpty)
        #expect(await TextExtractor.extract(fifo) == nil)
        await #expect(throws: (any Error).self) {
            _ = try await DelimitedLoader.load(fifo, separator: 0x2C)
        }

        // None of the readers consumed the pipe's bytes.
        var remaining = [UInt8](repeating: 0, count: payload.utf8.count)
        let readCount = remaining.withUnsafeMutableBytes { read(writer, $0.baseAddress, $0.count) }
        #expect(readCount == payload.utf8.count)
        #expect(tree.snapshot() == ["compose.yaml", "kept.txt"])
    }

    @Test func previewPanelAndPreviewPaneHandleBoundaryInputsSafely() throws {
        let tree = try TestTree("a.txt")
        let entry = try #require(FileEntry(url: tree.url("a.txt")))
        let browser = BrowserViewController()
        _ = browser.view
        #expect(browser.previewPanel(nil, previewItemAt: -1) == nil)
        #expect(browser.previewPanel(nil, previewItemAt: 0) == nil)
        browser.showResults([entry], total: 1)
        browser.select([entry.url])
        #expect((browser.previewPanel(nil, previewItemAt: 0) as? URL) == entry.url)
        #expect(browser.previewPanel(nil, previewItemAt: 1) == nil)

        let pane = ColumnPreviewPane()
        pane.frame = NSRect(x: 0, y: 0, width: 10, height: 200)
        pane.show(entry)
        pane.layoutSubtreeIfNeeded()
        #expect(pane.frame.width == 10)
        #expect(tree.snapshot() == ["a.txt"])
    }

    @Test func indexStoreAndDuplicateFinderSaturateInsteadOfOverflowing() {
        let group = DuplicateGroup(size: Int64.max, paths: ["/a", "/b", "/c"])
        #expect(group.reclaimable == Int64.max)

        let store = IndexStore()
        store.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            let names = Array("a\0b".utf8)
            let items = [
                ScannedItem(nameOffset: 0, nameLength: 1, isDirectory: false, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: Int64.max - 10, mtime: 0),
                ScannedItem(nameOffset: 2, nameLength: 1, isDirectory: false, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 100, mtime: 0),
            ]
            _ = names.withUnsafeBytes { store.appendChildren(items, nameBuffer: $0, of: root) }
            store.aggregate()
            #expect(store.size[Int(root)] == Int64.max)
            #expect(store.fileCount[Int(root)] == 2)
        }
    }
}
