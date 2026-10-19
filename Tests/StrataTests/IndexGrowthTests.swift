import Foundation
import Testing
@testable import Strata

struct IndexGrowthTests {
    private func append(_ range: Range<Int>, to store: IndexStore) {
        var names: [UInt8] = [], items: [ScannedItem] = []
        for number in range {
            let bytes = Array("file-\(number).txt".utf8)
            items.append(ScannedItem(nameOffset: names.count, nameLength: bytes.count, isDirectory: false, isPackage: false,
                                     isSymlink: number == 5, isHidden: number == 6, isMountPoint: false,
                                     size: Int64(number + 1), mtime: UInt32(number), fileKey: UInt32(number + 1)))
            names.append(contentsOf: bytes)
        }
        names.withUnsafeBytes { _ = store.appendChildren(items, nameBuffer: $0, of: 0,
                                                        ownNoise: [Bool](repeating: false, count: items.count)) }
    }

    private func fixture(files: Int) -> IndexStore {
        let store = IndexStore()
        store.reserve(entries: files + 1)
        _ = store.addRoot(path: "/synthetic", mtime: 0)
        for base in stride(from: 0, to: files, by: 4096) { append(base..<min(base + 4096, files), to: store) }
        store.aggregate()
        return store
    }

    private func addresses(_ store: IndexStore) -> [UInt] {
        func address<T>(_ column: ContiguousArray<T>) -> UInt {
            column.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        return [address(store.parent), address(store.firstChild), address(store.nextSibling), address(store.nameStart),
                address(store.nameLength), address(store.size), address(store.fileCount), address(store.mtime),
                address(store.fileKey), address(store.flags), address(store.names)]
    }

    private func expectSameColumns(_ reopened: IndexStore, _ original: IndexStore) {
        #expect(reopened.parent == original.parent)
        #expect(reopened.firstChild == original.firstChild)
        #expect(reopened.nextSibling == original.nextSibling)
        #expect(reopened.nameStart == original.nameStart)
        #expect(reopened.nameLength == original.nameLength)
        #expect(reopened.names == original.names)
        #expect(reopened.size == original.size)
        #expect(reopened.fileCount == original.fileCount)
        #expect(reopened.mtime == original.mtime)
        #expect(reopened.fileKey == original.fileKey)
        #expect(reopened.flags == original.flags)
    }

    @Test func aBurstAfterLoadingKeepsEveryColumnBufferAndPersistsAllItems() throws {
        let tree = try TestTree("state/")
        let count = 200_000, burst = 4096
        try IndexPersistence.save(fixture(files: count), eventID: 1, excluded: [], to: tree.url("state/index.sealed"))
        let (loaded, _) = try IndexPersistence.load(from: tree.url("state/index.sealed"))
        try #require(loaded.count == count + 1)
        let buffers = addresses(loaded)
        let first = Int32(loaded.count)
        append(count..<(count + burst), to: loaded)
        loaded.integrateNew(from: first)
        #expect(addresses(loaded) == buffers)
        #expect(loaded.count == count + burst + 1)
        #expect(loaded.fileCount[0] == count + burst)
        let total = Int64(count + burst) * Int64(count + burst + 1) / 2
        #expect(loaded.size[0] == total)
        for number in [0, 5, 6, count - 1, count, count + burst - 1] {
            let id = try #require(loaded.lookup("/synthetic/file-\(number).txt"))
            #expect(loaded.size[Int(id)] == Int64(number + 1))
            #expect(loaded.mtime[Int(id)] == UInt32(number))
            #expect(loaded.fileKey[Int(id)] == UInt32(number + 1))
        }
        #expect(loaded.flags[6] & IndexStore.Flag.symlink != 0)
        #expect(loaded.flags[7] & IndexStore.Flag.hidden != 0)
        try IndexPersistence.save(loaded, eventID: 2, excluded: [], to: tree.url("state/new.sealed"))
        let (reopened, header) = try IndexPersistence.load(from: tree.url("state/new.sealed"))
        #expect(header.eventID == 2)
        #expect(reopened.count == loaded.count)
        #expect(reopened.size[0] == total)
        expectSameColumns(reopened, loaded)
        #expect(reopened.lookup("/synthetic/file-\(count + burst - 1).txt") != nil)
        #expect(tree.snapshot() == ["state/", "state/index.sealed", "state/new.sealed"])
    }

    @Test func reservedCapacityIsNeverReadOrSavedAsFileEntries() throws {
        let tree = try TestTree("state/")
        let original = fixture(files: 10_000)
        try IndexPersistence.save(original, eventID: 42, excluded: ["/private"], to: tree.url("state/index.sealed"))
        let (loaded, header) = try IndexPersistence.load(from: tree.url("state/index.sealed"))
        try #require(loaded.count == original.count)
        #expect(loaded.names == original.names)
        #expect(loaded.parent == original.parent)
        #expect(loaded.flags == original.flags)
        #expect(loaded.fileCount == original.fileCount)
        try IndexPersistence.save(loaded, eventID: 42, excluded: header.excluded, to: tree.url("state/reopened.sealed"))
        let before = try #require(SecureStorage.read(tree.url("state/index.sealed")))
        let after = try #require(SecureStorage.read(tree.url("state/reopened.sealed")))
        #expect(before == after)
        #expect(tree.snapshot() == ["state/", "state/index.sealed", "state/reopened.sealed"])
    }

    @Test(arguments: [0, 1, 4095, 4096, 8192])
    func emptySmallAndReserveBoundaryIndexesRoundTrip(_ entries: Int) throws {
        let tree = try TestTree("state/")
        let original = entries == 0 ? IndexStore() : fixture(files: entries - 1)
        try IndexPersistence.save(original, eventID: 42, excluded: ["/private"], to: tree.url("state/index.sealed"))
        let (loaded, header) = try IndexPersistence.load(from: tree.url("state/index.sealed"))
        try #require(loaded.count == entries)
        expectSameColumns(loaded, original)
        #expect(header.eventID == 42 && header.excluded == ["/private"])
        #expect(header.roots.map(\.path) == original.roots.map(\.path))
        try IndexPersistence.save(loaded, eventID: header.eventID, excluded: header.excluded, to: tree.url("state/reopened.sealed"))
        let before = try #require(SecureStorage.read(tree.url("state/index.sealed")))
        let after = try #require(SecureStorage.read(tree.url("state/reopened.sealed")))
        #expect(before == after)
        #expect(tree.snapshot() == ["state/", "state/index.sealed", "state/reopened.sealed"])
    }

    @Test func growthBeyondTheReserveStillPreservesEveryItemAndItsMetadata() throws {
        let tree = try TestTree("state/")
        let count = 4096, burst = 4096
        try IndexPersistence.save(fixture(files: count), eventID: 1, excluded: [], to: tree.url("state/index.sealed"))
        let (loaded, _) = try IndexPersistence.load(from: tree.url("state/index.sealed"))
        let first = Int32(loaded.count)
        append(count..<(count + burst), to: loaded)
        loaded.integrateNew(from: first)
        #expect(loaded.count == count + burst + 1)
        #expect(loaded.fileCount[0] == count + burst)
        #expect(loaded.size[0] == Int64(count + burst) * Int64(count + burst + 1) / 2)
        try IndexPersistence.save(loaded, eventID: 2, excluded: [], to: tree.url("state/new.sealed"))
        let (reopened, _) = try IndexPersistence.load(from: tree.url("state/new.sealed"))
        expectSameColumns(reopened, loaded)
        #expect(reopened.lookup("/synthetic/file-\(count + burst - 1).txt") != nil)
        #expect(tree.snapshot() == ["state/", "state/index.sealed", "state/new.sealed"])
    }

    @Test(arguments: ["shortColumn", "truncatedCiphertext", "badTag"])
    func truncatedAndUnauthenticatedIndexesAreRefusedWithoutChangingFiles(_ damage: String) throws {
        let tree = try TestTree("state/", "kept.txt")
        let file = tree.url("state/index.sealed")
        try IndexPersistence.save(fixture(files: 10_000), eventID: 1, excluded: [], to: file)
        if damage == "shortColumn" {
            // An authenticated but incomplete last column reaches the buffer's partial-read failure path.
            let plain = try #require(SecureStorage.read(file))
            try SecureStorage.write(Data(plain.dropLast(17)), to: file)
        } else {
            var encrypted = try Data(contentsOf: file)
            if damage == "truncatedCiphertext" { encrypted.removeLast(13) }
            else { encrypted[encrypted.count - 1] ^= 0x80 }
            try encrypted.write(to: file)
        }
        let before = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { _ = try IndexPersistence.load(from: file) }
        #expect(try Data(contentsOf: file) == before)
        #expect(tree.text("kept.txt") == "kept.txt")
        #expect(tree.snapshot() == ["kept.txt", "state/", "state/index.sealed"])
    }

    @Test(arguments: [UInt64.max, UInt64(Int.max), UInt64(Int.max) + 1])
    func unrepresentableAndOversizedColumnLengthsAreRefusedBeforeAllocation(_ length: UInt64) throws {
        let tree = try TestTree("state/", "kept.txt")
        let file = tree.url("state/index.sealed")
        try IndexPersistence.save(IndexStore(), eventID: 1, excluded: [], to: file)
        var plain = try #require(SecureStorage.read(file))
        // With no roots or exclusions, the first column's count follows the 24-byte version-6 header.
        try #require(plain.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) } == 0)
        withUnsafeBytes(of: length.littleEndian) { plain.replaceSubrange(24..<32, with: $0) }
        try SecureStorage.write(plain, to: file)
        let before = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { _ = try IndexPersistence.load(from: file) }
        #expect(try Data(contentsOf: file) == before)
        #expect(tree.text("kept.txt") == "kept.txt")
        #expect(tree.snapshot() == ["kept.txt", "state/", "state/index.sealed"])
    }
}
