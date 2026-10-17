import Foundation
import Testing
@testable import Strata

/// Move to Trash and undo (⌘Z, and later from History): only the chosen items go to the Trash, and undo only ever
/// moves those very items back, never something that took their place since. The Trash tests use your real Trash and
/// take back out exactly what they put in; History is a test run's own (see `SecureStorage.isTestRun`).
struct TrashUndoTests {
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<60 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// The last History entry for items of `tree`.
    private func entry(for tree: TestTree) -> OperationLog.Entry? {
        OperationLog.shared.entries.last { $0.pairs.contains { $0[0].hasPrefix(tree.root.path + "/") } }
    }

    // MARK: - Move to Trash

    @Test func onlyTheSelectionGoesAndUndoPutsItBack() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "b/", "b/c.txt", "d.txt")
        defer { tree.removeFromTrash() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await FileOps.trashInBackground([tree.url("a.txt"), tree.url("b")], undo: undo)
        undo.endUndoGrouping()
        #expect(tree.snapshot() == ["ab.txt", "d.txt"])
        let trashed = try #require(entry(for: tree))
        #expect(trashed.pairs.map { URL(fileURLWithPath: $0[0]).lastPathComponent }.sorted() == ["a.txt", "b"])
        #expect(trashed.pairs.allSatisfy { Trash.isInTrash(URL(fileURLWithPath: $0[1])) })

        undo.undo()
        await wait { tree.snapshot().count == 5 }
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "b/", "b/c.txt", "d.txt"])
        #expect(tree.text("b/c.txt") == "b/c.txt")
    }

    @Test func aLinkGoesToTheTrashNotWhatItPointsTo() async throws {
        let tree = try TestTree("target/", "target/precious.txt", "link -> target")
        defer { tree.removeFromTrash() }
        try await FileOps.trashInBackground([tree.url("link")], undo: nil)
        #expect(tree.snapshot() == ["target/", "target/precious.txt"])
    }

    @Test func historyUndoBringsBackWhatWasTrashedAndOnlyThat() async throws {
        let tree = try TestTree("a.txt", "b.txt", "c.txt")
        defer { tree.removeFromTrash() }
        try await FileOps.trashInBackground([tree.url("a.txt"), tree.url("b.txt")], undo: nil)
        let trashed = try #require(entry(for: tree))
        #expect(OperationLog.shared.canUndo(trashed))
        try await OperationLog.shared.undo(trashed, undoManager: nil)
        #expect(tree.snapshot() == ["a.txt", "b.txt", "c.txt"])
        #expect(OperationLog.shared.entries.first { $0.id == trashed.id }?.undone == true)
    }

    // MARK: - Undo from History

    @Test func undoLeavesAloneWhatTookTheOldPlace() async throws {
        let tree = try TestTree("a.txt")
        try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt"))], actionName: "Rename", undo: nil)
        let renamed = try #require(entry(for: tree))
        // Something new is saved where the item was: undoing must not move the item over it.
        try Data("new".utf8).write(to: tree.url("a.txt"))
        #expect(!OperationLog.shared.canUndo(renamed))
        await #expect(throws: (any Error).self) { try await OperationLog.shared.undo(renamed, undoManager: nil) }
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
        #expect(tree.text("a.txt") == "new" && tree.text("b.txt") == "a.txt")
    }

    @Test func undoNeverMovesBackAnItemThatWasSwappedForAnother() async throws {
        let tree = try TestTree("a.txt")
        try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt"))], actionName: "Rename", undo: nil)
        let renamed = try #require(entry(for: tree))
        // "b.txt" is now a different file: it isn't what the rename left there, so it stays where it is.
        try FileManager.default.removeItem(at: tree.url("b.txt"))
        try Data("someone else's".utf8).write(to: tree.url("b.txt"))
        #expect(!OperationLog.shared.canUndo(renamed))
        await #expect(throws: (any Error).self) { try await OperationLog.shared.undo(renamed, undoManager: nil) }
        #expect(tree.snapshot() == ["b.txt"])
        #expect(tree.text("b.txt") == "someone else's")
    }

    @Test func undoMovesBackOnlyTheMovedItems() async throws {
        let tree = try TestTree("from/", "from/a.txt", "from/b.txt", "from/stays.txt", "to/", "to/there.txt")
        try await FileOps.move([(from: tree.url("from/a.txt"), to: tree.url("to/a.txt")),
                                (from: tree.url("from/b.txt"), to: tree.url("to/b.txt"))], actionName: "Move", undo: nil)
        #expect(tree.snapshot() == ["from/", "from/stays.txt", "to/", "to/a.txt", "to/b.txt", "to/there.txt"])
        let moved = try #require(entry(for: tree))
        try await OperationLog.shared.undo(moved, undoManager: nil)
        #expect(tree.snapshot() == ["from/", "from/a.txt", "from/b.txt", "from/stays.txt", "to/", "to/there.txt"])
    }

    // MARK: - ⌘Z, after something took an item's place

    /// Runs `body` as one undo group, as one command would be.
    private func undoable(_ body: (UndoManager) async throws -> Void) async rethrows -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await body(undo)
        undo.endUndoGrouping()
        return undo
    }

    /// Swaps the item at `path` for another file of that name.
    private func swap(_ tree: TestTree, _ path: String) throws {
        try FileManager.default.removeItem(at: tree.url(path))
        try Data("someone else's".utf8).write(to: tree.url(path))
    }

    @Test func undoingACopyTrashesOnlyItsOwnCopies() async throws {
        let tree = try TestTree("a.txt", "b.txt", "to/", "to/keep.txt")
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("a.txt"), tree.url("b.txt")], to: tree.url("to"), mode: .copy,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        try swap(tree, "to/b.txt")
        undo.undo()
        await wait { !tree.snapshot().contains("to/a.txt") }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/b.txt", "to/keep.txt"])
        #expect(tree.text("to/b.txt") == "someone else's")
        // Redo brings the copy back out of the Trash (and leaves nothing of the test there).
        undo.redo()
        await wait { tree.snapshot().contains("to/a.txt") }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/a.txt", "to/b.txt", "to/keep.txt"])
    }

    @Test func undoingANewFolderLeavesOneMadeInItsPlace() async throws {
        let tree = try TestTree("keep.txt")
        let undo = try await undoable { undo in _ = try FileOps.newFolder(in: tree.root, undo: undo) }
        let made = try #require(tree.snapshot().first { $0.hasSuffix("/") })
        try FileManager.default.removeItem(at: tree.url(made))
        try FileManager.default.createDirectory(at: tree.url(made), withIntermediateDirectories: false)
        try Data("theirs".utf8).write(to: tree.url(made + "theirs.txt"))
        undo.undo()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(tree.snapshot() == ["keep.txt", made, made + "theirs.txt"])
    }

    @Test func undoingARenameLeavesAFileSwappedInSince() async throws {
        let tree = try TestTree("a.txt", "c.txt")
        let undo = try await undoable { undo in
            try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt")), (from: tree.url("c.txt"), to: tree.url("d.txt"))],
                                   actionName: "Rename", undo: undo)
        }
        try swap(tree, "b.txt")
        undo.undo()
        await wait { tree.snapshot().contains("c.txt") }
        // "d.txt" was the renamed file: it goes back. "b.txt" isn't any more: it stays.
        #expect(tree.snapshot() == ["b.txt", "c.txt"])
        #expect(tree.text("b.txt") == "someone else's")
        // Redo renames again exactly what undo moved back.
        undo.redo()
        await wait { tree.snapshot().contains("d.txt") }
        #expect(tree.snapshot() == ["b.txt", "d.txt"])
        #expect(tree.text("d.txt") == "c.txt")
    }

    @Test func undoingAMoveJobMovesBackOnlyItsOwnItems() async throws {
        let tree = try TestTree("from/", "from/a.txt", "from/b.txt", "to/")
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("from/a.txt"), tree.url("from/b.txt")], to: tree.url("to"), mode: .move,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        try swap(tree, "to/b.txt")
        undo.undo()
        await wait { tree.snapshot().contains("from/a.txt") }
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/b.txt"])
        #expect(tree.text("to/b.txt") == "someone else's")
        undo.redo()
        await wait { tree.snapshot().contains("to/a.txt") }
        #expect(tree.snapshot() == ["from/", "to/", "to/a.txt", "to/b.txt"])
        // Undone again, then swapped before the redo: redo leaves that file where it is.
        undo.undo()
        await wait { tree.snapshot().contains("from/a.txt") }
        try swap(tree, "from/a.txt")
        undo.redo()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/b.txt"])
        #expect(tree.text("from/a.txt") == "someone else's")
    }
}
