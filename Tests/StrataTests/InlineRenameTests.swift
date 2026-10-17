import Foundation
import Testing
@testable import Strata

/// Renaming one item in place (Return, a slow click, File ▸ Rename): only that item changes name, it stays in its
/// folder, it never takes the name of another item, and undo gives the old name back.
struct InlineRenameTests {
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<60 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func onlyThatItemChangesName() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "b/", "b/a.txt", "link -> a.txt")
        let renamed = try await FileOps.rename(tree.url("a.txt"), to: "c.txt", undo: nil)
        #expect(renamed.lastPathComponent == "c.txt")
        #expect(tree.snapshot() == ["ab.txt", "b/", "b/a.txt", "c.txt", "link -> a.txt"])
        #expect(tree.text("c.txt") == "a.txt")
    }

    @Test func aLinkIsRenamedNotWhatItPointsTo() async throws {
        let tree = try TestTree("target.txt", "link -> target.txt")
        _ = try await FileOps.rename(tree.url("link"), to: "renamed link", undo: nil)
        #expect(tree.snapshot() == ["renamed link -> target.txt", "target.txt"])
    }

    @Test func neverTheNameOfAnotherItem() async throws {
        let tree = try TestTree("a.txt", "b.txt", "folder/")
        for name in ["b.txt", "B.TXT", "folder", "FOLDER"] {
            await #expect(throws: (any Error).self, "\(name)") { _ = try await FileOps.rename(tree.url("a.txt"), to: name, undo: nil) }
        }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "folder/"])
        #expect(tree.text("b.txt") == "b.txt")
    }

    @Test func onlyTheCaseCanChange() async throws {
        let tree = try TestTree("report.txt", "other.txt")
        _ = try await FileOps.rename(tree.url("report.txt"), to: "Report.TXT", undo: nil)
        #expect(tree.snapshot() == ["Report.TXT", "other.txt"])
        #expect(tree.text("Report.TXT") == "report.txt")
    }

    @Test func aNameNeverMovesTheItem() async throws {
        let tree = try TestTree("folder/", "folder/a.txt", "folder/x/")
        for name in ["../escape.txt", "x/a.txt", "..", ".", ""] {
            await #expect(throws: (any Error).self, "\(name)") {
                _ = try await FileOps.rename(tree.url("folder/a.txt"), to: name, undo: nil)
            }
        }
        #expect(tree.snapshot() == ["folder/", "folder/a.txt", "folder/x/"])
    }

    @Test func undoGivesTheOldNameBack() async throws {
        let tree = try TestTree("a.txt", "keep.txt")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        _ = try await FileOps.rename(tree.url("a.txt"), to: "b.txt", undo: undo)
        undo.endUndoGrouping()
        #expect(tree.snapshot() == ["b.txt", "keep.txt"])
        undo.undo()
        await wait { tree.snapshot() == ["a.txt", "keep.txt"] }
        #expect(tree.snapshot() == ["a.txt", "keep.txt"])
    }

    @Test func nothingInAnArchiveCopyIsRenamed() async {
        // Anything under the archives' copies is read-only; the check comes before anything on disk.
        let inside = ArchiveCache.root.appending(path: "never-made-\(UUID().uuidString)/contents/a.txt")
        await #expect(throws: (any Error).self) { _ = try await FileOps.rename(inside, to: "b.txt", undo: nil) }
        #expect(!FileManager.default.fileExists(atPath: inside.deletingLastPathComponent().path))
    }
}
