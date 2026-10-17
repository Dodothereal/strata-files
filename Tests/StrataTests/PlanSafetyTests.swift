import Foundation
import Testing
@testable import Strata

/// Ask Strata: whatever the model or the rules propose, a plan only renames, moves or trashes the selected items, keeps
/// them inside the window's folder unless you named another place, never replaces anything, and running it does only
/// the steps left checked.
struct PlanSafetyTests {
    private func validate(_ operations: [ProposedOperation], selecting paths: [String], in tree: TestTree,
                          base: String = "", instruction: String = "") async -> Plan {
        let items = await PlanItem.load(paths.map(tree.url))
        let folder = base.isEmpty ? tree.root : tree.url(base)
        return PlanValidator.validate(operations, request: .init(instruction: instruction, items: items, baseFolder: folder),
                                      source: .model, interpretation: "")
    }

    private func described(_ steps: [PlanStep]) -> [String] {
        steps.map { "\($0.kind.rawValue) \($0.source?.lastPathComponent ?? "-") \($0.destination?.lastPathComponent ?? "-")" }.sorted()
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<60 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func stepsOnItemsOutsideTheSelectionAreLeftOut() async throws {
        let tree = try TestTree("a.txt", "b.txt", "sub/")
        let plan = await validate([.trash(tree.url("b.txt")), .rename(tree.url("b.txt"), to: "x.txt"),
                                   .move(tree.url("b.txt"), into: "sub"), .trash(tree.url("a.txt"))],
                                  selecting: ["a.txt"], in: tree)
        #expect(described(plan.steps) == ["trash a.txt -"])
        #expect(plan.excluded.count == 3)
    }

    @Test func movesStayInTheFolderUnlessYouNamedAnother() async throws {
        let tree = try TestTree("base/", "base/a.txt", "base/sub/", "outside/")
        let outside = tree.url("outside").path
        for folder in ["../outside", "sub/../../outside", outside, "~", "/"] {
            let plan = await validate([.move(tree.url("base/a.txt"), into: folder)], selecting: ["base/a.txt"], in: tree, base: "base")
            #expect(plan.steps.isEmpty, "\(folder)")
        }
        // Named in the request: allowed there, and only there.
        let named = await validate([.move(tree.url("base/a.txt"), into: outside)], selecting: ["base/a.txt"], in: tree,
                                   base: "base", instruction: "move it to \(outside)")
        let destination = try #require(named.steps.first?.destination)
        #expect(named.steps.count == 1 && destination.lastPathComponent == "a.txt")
        #expect(destination.deletingLastPathComponent().resolvingSymlinksInPath().path == tree.url("outside").resolvingSymlinksInPath().path)
    }

    @Test func aNamedFolderCountsOnlyAsAWholePath() async throws {
        let tree = try TestTree("base/", "base/a.txt", "archive/", "archive/2024/")
        let instruction = "move these to \(tree.url("archive/2024").path)"
        // A folder above the one you named, or one whose name only starts the same, isn't the one you named.
        for folder in [tree.url("archive").path, tree.root.path, "~", "/", tree.url("archive/20").path] {
            let plan = await validate([.move(tree.url("base/a.txt"), into: folder)], selecting: ["base/a.txt"], in: tree,
                                      base: "base", instruction: instruction)
            #expect(plan.steps.isEmpty, "\(folder)")
        }
        let plan = await validate([.move(tree.url("base/a.txt"), into: tree.url("archive/2024").path)],
                                  selecting: ["base/a.txt"], in: tree, base: "base", instruction: instruction + ".")
        #expect(plan.steps.count == 1)
    }

    @Test func linkedFoldersLeadingOutAreRefused() async throws {
        let tree = try TestTree("outside/", "base/", "base/a.txt", "base/door -> outside")
        for folder in ["door", "door/deeper"] {
            let plan = await validate([.move(tree.url("base/a.txt"), into: folder)], selecting: ["base/a.txt"], in: tree, base: "base")
            #expect(plan.steps.isEmpty, "\(folder)")
        }
    }

    @Test func newNamesCantLeaveTheirFolder() async throws {
        let tree = try TestTree("a.txt", "sub/")
        for name in ["../a.txt", "sub/a.txt", "..", ".", ".hidden", "a:b", ""] {
            let plan = await validate([.rename(tree.url("a.txt"), to: name)], selecting: ["a.txt"], in: tree)
            #expect(plan.steps.isEmpty, "\(name)")
        }
    }

    @Test func nothingIsReplacedAndAFolderCantGoInsideItself() async throws {
        let tree = try TestTree("a.txt", "b.txt", "dir/", "dir/sub/", "box/", "box/a.txt")
        let plan = await validate([.rename(tree.url("a.txt"), to: "b.txt"), .move(tree.url("dir"), into: "dir/sub")],
                                  selecting: ["a.txt", "dir"], in: tree)
        #expect(plan.steps.isEmpty)
        let into = await validate([.move(tree.url("a.txt"), into: "box")], selecting: ["a.txt"], in: tree)
        #expect(into.steps.isEmpty)
        let twice = await validate([.rename(tree.url("a.txt"), to: "c.txt"), .rename(tree.url("b.txt"), to: "c.txt")],
                                   selecting: ["a.txt", "b.txt"], in: tree)
        #expect(described(twice.steps) == ["rename a.txt c.txt"])
    }

    @Test func runningAPlanDoesOnlyItsCheckedSteps() async throws {
        let tree = try TestTree("a.txt", "b.txt", "c.txt", "d.txt", "keep.txt", "Old/", "Old/x.txt")
        defer { tree.removeFromTrash() }
        var plan = await validate([.trash(tree.url("a.txt")), .trash(tree.url("b.txt")), .move(tree.url("c.txt"), into: "Done"),
                                   .rename(tree.url("d.txt"), to: "dee.txt")],
                                  selecting: ["a.txt", "b.txt", "c.txt", "d.txt"], in: tree)
        #expect(described(plan.steps) == ["createFolder - Done", "move c.txt c.txt", "rename d.txt dee.txt", "trash a.txt -", "trash b.txt -"])
        // Unchecked in the review: b.txt stays.
        let unchecked = try #require(plan.steps.firstIndex { $0.source?.lastPathComponent == "b.txt" })
        plan.steps[unchecked].isEnabled = false
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let outcome = await PlanExecutor.apply(plan, actionName: "AI Changes", undo: undo)
        undo.endUndoGrouping()
        #expect(outcome.failures.isEmpty)
        #expect(tree.snapshot() == ["Done/", "Done/c.txt", "Old/", "Old/x.txt", "b.txt", "dee.txt", "keep.txt"])
        // ⌘Z puts everything back, the trashed item included, and removes the folder it made.
        undo.undo()
        await wait { tree.snapshot().contains("a.txt") && !tree.snapshot().contains("Done/") }
        #expect(tree.snapshot() == ["Old/", "Old/x.txt", "a.txt", "b.txt", "c.txt", "d.txt", "keep.txt"])
    }
}
