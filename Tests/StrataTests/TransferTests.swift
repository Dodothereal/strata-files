import Foundation
import Testing
@testable import Strata

/// Copies and moves (drag and drop, paste, Copy/Move to Other Pane, Duplicate, sync): each item goes only where it was
/// sent; an existing item is replaced only when asked, and only once a complete copy is there to take its place; an
/// original is removed only after it was copied in full and didn't change meanwhile. A replaced item goes to your
/// real Trash: each test takes it back out.
@Suite(.serialized) struct TransferTests {
    private func run(_ item: TransferItem, verify: Bool = false) -> TransferItemResult {
        TransferEngine.perform(0, item, options: .init(verify: verify, clone: false), control: TransferControl(),
                               progress: TransferProgress())
    }

    private func discard(_ result: TransferItemResult) {
        if let trashed = result.replaced?.to, Trash.isInTrash(trashed) { try? FileManager.default.removeItem(at: trashed) }
    }

    /// Hidden temporary names ("·name.strata-XXXXXXXX") a replace writes under, left behind.
    private func leftovers(_ tree: TestTree) -> [String] {
        tree.snapshot().filter { $0.contains(".strata-") }
    }

    @Test func aCopyLeavesTheOriginalAndEverythingAround() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/inner.txt", "from/b.txt", "to/", "to/there.txt")
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copy))
        #expect(result.outcome == .done && !result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "from/a/", "from/a/inner.txt", "from/b.txt",
                                    "to/", "to/a/", "to/a/inner.txt", "to/there.txt"])
    }

    @Test func aMoveOnOneDiskTakesOnlyThatItem() throws {
        let tree = try TestTree("from/", "from/a.txt", "from/b.txt", "to/")
        let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: .rename))
        #expect(result.outcome == .done && result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "from/b.txt", "to/", "to/a.txt"])
        #expect(tree.text("to/a.txt") == "from/a.txt")
    }

    @Test func nothingIsWrittenOverWithoutBeingAsked() throws {
        let tree = try TestTree("from/", "from/a.txt", "to/", "to/a.txt")
        for operation in [TransferItem.Operation.rename, .copy, .copyThenDelete] {
            let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: operation))
            #expect(result.outcome == .failed, "\(operation)")
            #expect(tree.text("to/a.txt") == "to/a.txt" && tree.text("from/a.txt") == "from/a.txt", "\(operation)")
        }
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/a.txt"])
    }

    @Test func aMoveAcrossDisksRemovesOnlyTheCopiedOriginal() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/inner.txt", "from/keep.txt", "to/")
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copyThenDelete),
                         verify: true)
        #expect(result.outcome == .done && result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "from/keep.txt", "to/", "to/a/", "to/a/inner.txt"])
    }

    @Test func anOriginalThatChangedWhileBeingCopiedIsKept() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/inner.txt", "to/")
        let added = tree.url("from/a/saved meanwhile.txt")
        TransferEngine.hooks.beforeVerify = { _ in try? Data("new".utf8).write(to: added) }
        defer { TransferEngine.hooks = .init() }
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copyThenDelete),
                         verify: true)
        #expect(result.outcome != .done && !result.sourceRemoved)
        #expect(tree.text("from/a/inner.txt") == "from/a/inner.txt")
        #expect(FileManager.default.fileExists(atPath: added.path))
    }

    @Test func replacingSwapsOnlyTheNamedItemAndKeepsTheOldInTheTrash() throws {
        let tree = try TestTree("from/", "from/a.txt", "to/", "to/a.txt", "to/b.txt")
        let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: .copy,
                                      decision: .replace))
        defer { discard(result) }
        #expect(result.outcome == .done)
        #expect(tree.text("to/a.txt") == "from/a.txt" && tree.text("to/b.txt") == "to/b.txt")
        let trashed = try #require(result.replaced?.to)
        #expect(Trash.isInTrash(trashed))
        #expect((try? String(contentsOf: trashed, encoding: .utf8)) == "to/a.txt")
        #expect(leftovers(tree).isEmpty)
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/a.txt", "to/b.txt"])
    }

    @Test func aMoveThatReplacesTakesTheOriginalAlong() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/new.txt", "to/", "to/a/", "to/a/old.txt")
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .rename,
                                      decision: .replace))
        defer { discard(result) }
        #expect(result.outcome == .done && result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "to/", "to/a/", "to/a/new.txt"])
    }

    @Test func aCopyThatFailsToVerifyNeverReplacesAnything() throws {
        let tree = try TestTree("from/", "from/a.txt", "to/", "to/a.txt")
        // Something corrupts the copy before it's checked: the existing item must stay as it was.
        TransferEngine.hooks.beforeVerify = { copy in try? Data("corrupted".utf8).write(to: copy) }
        defer { TransferEngine.hooks = .init() }
        let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: .copy,
                                      decision: .replace), verify: true)
        defer { discard(result) }
        #expect(result.outcome == .failed && result.replaced == nil)
        #expect(tree.text("to/a.txt") == "to/a.txt" && tree.text("from/a.txt") == "from/a.txt")
        #expect(leftovers(tree).isEmpty)
    }

    @Test func aLinkIsCopiedAsALinkNotWhatItPointsTo() throws {
        let tree = try TestTree("target/", "target/big.txt", "from/", "from/link -> target", "to/")
        let result = run(TransferItem(source: tree.url("from/link"), destination: tree.url("to/link"), operation: .copyThenDelete))
        #expect(result.outcome == .done)
        #expect(tree.snapshot() == ["target/", "target/big.txt", "from/", "to/", "to/link -> target"].sorted())
    }

    // MARK: - Names and merges

    @Test func keepBothPicksAFreeNameNeverATakenOne() throws {
        let tree = try TestTree("a.txt", "a 2.txt", "a 3 -> nowhere", "folder/")
        #expect(FileOps.available(tree.url("a.txt"), copyStyle: false).lastPathComponent == "a 3.txt")
        #expect(FileOps.available(tree.url("free.txt"), copyStyle: false).lastPathComponent == "free.txt")
        #expect(FileOps.available(tree.url("folder"), copyStyle: true).lastPathComponent == "folder copy")
    }

    @Test func mergingCopiesWhatsMissingAndOnlyNewerItems() throws {
        let tree = try TestTree("src/", "src/new.txt", "src/older.txt", "src/newer.txt", "src/sub/", "src/sub/deep.txt",
                                "src/clash/", "dst/", "dst/older.txt", "dst/newer.txt", "dst/extra.txt", "dst/sub/",
                                "dst/sub/mine.txt", "dst/clash")
        func age(_ path: String, _ seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: tree.url(path).path)
        }
        try age("src/older.txt", 3600)
        try age("dst/newer.txt", 3600)
        let steps = TransferEngine.mergePlan(tree.url("src"), into: tree.url("dst"))
        let planned = steps.map { "\($0.source.path.dropFirst(tree.root.path.count + 1)) \($0.decision.map { "\($0)" } ?? "new")" }
        #expect(planned.sorted() == ["src/clash keepBoth", "src/new.txt new", "src/newer.txt replace", "src/sub/deep.txt new"])
        // Planning changes nothing; nothing only in the destination is ever part of a merge.
        #expect(tree.snapshot().contains("dst/extra.txt") && tree.snapshot().contains("dst/sub/mine.txt"))
    }
}
