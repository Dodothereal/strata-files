import Foundation
import Testing
@testable import Strata

struct IndexPersistenceSafetyTests {
    private func fixture() -> IndexStore {
        let store = IndexStore()
        let root = store.addRoot(path: "/synthetic", mtime: 0)
        let names = Array("ab".utf8)
        let items = (0..<2).map { ScannedItem(nameOffset: $0, nameLength: 1, isDirectory: false, isPackage: false,
                                             isSymlink: false, isHidden: false, isMountPoint: false, size: 1, mtime: 0) }
        names.withUnsafeBytes { _ = store.appendChildren(items, nameBuffer: $0, of: root) }
        store.aggregate()
        return store
    }

    @Test(arguments: ["parentRange", "parentCycle", "childRange", "siblingCycle", "nameRange",
                      "rootRange", "duplicateRoot", "missingChild", "wrongParent", "negativeSize"])
    func malformedAuthenticatedIndexesAreRejected(_ damage: String) throws {
        let tree = try TestTree("state/", "kept.txt")
        let store = fixture()
        switch damage {
        case "parentRange": store.parent[1] = .max
        case "parentCycle": store.parent[1] = 1
        case "childRange": store.firstChild[0] = .max
        case "siblingCycle": store.nextSibling[2] = 1
        case "nameRange": store.nameStart[1] = .max
        case "rootRange": store.roots[0].id = .max
        case "duplicateRoot": store.roots.append(store.roots[0])
        case "missingChild": store.firstChild[0] = -1
        case "wrongParent": store.parent[2] = 1
        default: store.size[1] = -1
        }
        let url = tree.url("state/index.sealed")
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: url)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: url) }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["kept.txt", "state/", "state/index.sealed"])
    }

    @Test func unlinkedDeletedEntriesStillLoad() throws {
        let tree = try TestTree("state/")
        let store = fixture()
        store.remove(1)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: tree.url("state/index.sealed"))
        let (loaded, _) = try IndexPersistence.load(from: tree.url("state/index.sealed"))
        #expect(loaded.lookup("/synthetic/a") == nil)
        #expect(loaded.lookup("/synthetic/b") == 2)
        #expect(loaded.deletedCount() == 1)
        #expect(tree.snapshot() == ["state/", "state/index.sealed"])
    }
}
