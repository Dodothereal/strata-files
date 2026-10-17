import Foundation
import Testing
@testable import Strata

/// Compare Folders and Sync: only a one-way sync with "Move extras to the Trash" ever trashes anything, only on the side
/// being synced to, and only items the other side doesn't have; what couldn't be read is never touched.
struct FolderSyncTests {
    private func compare(_ tree: TestTree) async -> FolderCompare.Result {
        await FolderCompare.compare(tree.url("left"), tree.url("right"), contents: false, includeHidden: false,
                                    control: FolderCompare.Control()) { _ in }
    }

    private func actions(_ result: FolderCompare.Result, _ direction: FolderCompare.Direction, mirror: Bool)
        -> [(FolderCompare.Difference, FolderCompare.Action)] {
        result.differences.map { ($0, FolderCompare.defaultAction(for: $0.kind, direction: direction, mirror: mirror)) }
    }

    @Test func onlyAMirrorTrashesAndOnlyOnTheSideSyncedTo() {
        let kinds: [FolderCompare.Kind] = [.onlyLeft, .onlyRight, .leftNewer, .rightNewer, .changed, .kindsDiffer, .unknown]
        for direction in FolderCompare.Direction.allCases {
            for mirror in [false, true] {
                for kind in kinds {
                    let action = FolderCompare.defaultAction(for: kind, direction: direction, mirror: mirror)
                    let trashes = action == .trashLeft || action == .trashRight
                    #expect(!trashes || mirror, "\(direction) \(kind)")
                    #expect(action != .trashRight || (direction == .leftToRight && kind == .onlyRight), "\(direction) \(kind)")
                    #expect(action != .trashLeft || (direction == .rightToLeft && kind == .onlyLeft), "\(direction) \(kind)")
                    #expect(kind != .unknown || action == .skip)
                    #expect(FolderCompare.actions(for: kind).contains(action), "\(direction) \(kind)")
                }
            }
        }
    }

    @Test func aMirrorTrashesOnlyWhatTheSourceLacks() async throws {
        let tree = try TestTree("left/", "left/same.txt", "left/sub/", "left/sub/a.txt", "left/only left.txt",
                                "right/", "right/same.txt", "right/sub/", "right/sub/a.txt", "right/sub/extra.txt",
                                "right/extra folder/", "right/extra folder/inner.txt", "right/extra.txt")
        let result = await compare(tree)
        #expect(result.isComplete)
        let trashed = actions(result, .leftToRight, mirror: true).filter { $0.1 == .trashRight }.map(\.0.rightPath)
        #expect(Set(trashed) == ["sub/extra.txt", "extra folder", "extra.txt"])
        for path in trashed { #expect(!FileManager.default.fileExists(atPath: tree.url("left").appending(path: path).path)) }
        // The other way round, the right is the source: nothing on it is ever trashed.
        #expect(!actions(result, .rightToLeft, mirror: true).contains { $0.1 == .trashRight })
        #expect(actions(result, .rightToLeft, mirror: true).filter { $0.1 == .trashLeft }.map(\.0.leftPath) == ["only left.txt"])
        // Both ways, nothing is trashed at all.
        #expect(!actions(result, .bothWays, mirror: true).contains { $0.1 == .trashLeft || $0.1 == .trashRight })
    }

    @Test func aFolderThatCantBeReadIsLeftAlone() async throws {
        let tree = try TestTree("left/", "left/a.txt", "right/", "right/a.txt", "right/private/", "right/private/secret.txt")
        chmod(tree.url("right/private").path, 0)
        defer { chmod(tree.url("right/private").path, 0o755) }
        let result = await compare(tree)
        let mirrored = actions(result, .leftToRight, mirror: true)
        #expect(!mirrored.contains { $0.1 == .trashRight })
        #expect(mirrored.contains { $0.0.rightPath.hasPrefix("private") && $0.0.kind == .unknown })
    }

    @Test func namesThatDifferOnlyInCaseAreTheSameItem() async throws {
        let tree = try TestTree("left/", "left/report.txt", "right/", "right/Report.txt")
        let result = await compare(tree)
        #expect(!actions(result, .leftToRight, mirror: true).contains { $0.1 == .trashRight })
    }
}
