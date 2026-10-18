import CryptoKit
import Foundation
import Testing
import os
@testable import Strata

struct IndexPersistenceTests {
    private struct Stopped: Error {}

    private func fixture(_ tree: TestTree, count: Int = 20_000) -> IndexStore {
        let store = IndexStore()
        store.write {
            let root = store.addRoot(path: tree.url("files").path, mtime: 10)
            var names: [UInt8] = []
            var items: [ScannedItem] = []
            for i in 0..<count {
                let name = Array("private-file-\(i).dat".utf8)
                items.append(ScannedItem(nameOffset: names.count, nameLength: name.count, isDirectory: false,
                                         isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false,
                                         size: Int64(i + 1), mtime: 100, fileKey: UInt32(i + 50)))
                names.append(contentsOf: name)
            }
            names.withUnsafeBytes { _ = store.appendChildren(items, nameBuffer: $0, of: root) }
            store.aggregate()
        }
        return store
    }

    private func edit(_ store: IndexStore, id: Int = 10, by amount: Int64 = 1) {
        store.write {
            store.size[id] += amount
            store.mtime[id] += 1
            store.propagate(from: Int32(id), bytes: amount, files: 0)
        }
    }

    private func expectEqual(_ a: IndexStore, _ b: IndexStore, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.parent == b.parent, sourceLocation: sourceLocation)
        #expect(a.firstChild == b.firstChild, sourceLocation: sourceLocation)
        #expect(a.nextSibling == b.nextSibling, sourceLocation: sourceLocation)
        #expect(a.nameStart == b.nameStart, sourceLocation: sourceLocation)
        #expect(a.nameLength == b.nameLength, sourceLocation: sourceLocation)
        #expect(a.size == b.size, sourceLocation: sourceLocation)
        #expect(a.fileCount == b.fileCount, sourceLocation: sourceLocation)
        #expect(a.mtime == b.mtime, sourceLocation: sourceLocation)
        #expect(a.fileKey == b.fileKey, sourceLocation: sourceLocation)
        #expect(a.flags == b.flags, sourceLocation: sourceLocation)
        #expect(a.names == b.names, sourceLocation: sourceLocation)
        #expect(a.roots.map(\.path) == b.roots.map(\.path), sourceLocation: sourceLocation)
        #expect(a.roots.map(\.id) == b.roots.map(\.id), sourceLocation: sourceLocation)
    }

    private func listing(_ changes: Bool = true) -> [String] {
        (["files/", "state/", "state/index.sealed", "untouched.txt"] +
         (changes ? ["state/index.sealed.changes"] : [])).sorted()
    }

    @Test func aSmallChangeWritesOnlyEncryptedBlocksAndRestartsExactly() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        let first = try IndexPersistence.save(store, eventID: 100, excluded: [], to: file)
        let snapshot = try Data(contentsOf: file)
        edit(store)
        let saved = try IndexPersistence.save(store, eventID: 200, excluded: [], to: file)
        #expect(first.kind == .snapshot)
        #expect(saved.kind == .changes)
        #expect(saved.bytesWritten < first.bytesWritten / 10)
        #expect(try Data(contentsOf: file) == snapshot)
        let encrypted = try Data(contentsOf: IndexPersistence.changesURL(for: file))
        #expect(encrypted.range(of: Data("private-file-".utf8)) == nil)
        let (loaded, header) = try IndexPersistence.load(from: file)
        expectEqual(store, loaded)
        #expect(header.eventID == 200)
        #expect(tree.text("untouched.txt") == "untouched.txt")
        #expect(tree.snapshot() == listing())
    }

    @Test func repeatedSavesAndRestartsKeepAllEarlierChanges() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        var store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        let snapshot = try Data(contentsOf: file)
        for step in 1...6 {
            edit(store, id: step * 2500, by: Int64(step * 100))
            #expect(try IndexPersistence.save(store, eventID: UInt64(step + 1), excluded: [], to: file).kind == .changes)
            let (loaded, header) = try IndexPersistence.load(from: file)
            expectEqual(store, loaded)
            #expect(header.eventID == UInt64(step + 1))
            store = loaded
        }
        #expect(try Data(contentsOf: file) == snapshot)
        #expect(tree.snapshot() == listing())
    }

    @Test func unchangedSavesWriteNothingAndChangesCanRevertToTheSnapshot() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        let original = fixture(tree)
        edit(store)
        try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        let changes = try Data(contentsOf: IndexPersistence.changesURL(for: file))
        let saved = try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        #expect(saved.kind == .unchanged)
        #expect(saved.bytesWritten == 0)
        #expect(try Data(contentsOf: IndexPersistence.changesURL(for: file)) == changes)
        store.write { store.size = original.size; store.mtime = original.mtime }
        try IndexPersistence.save(store, eventID: 3, excluded: [], to: file)
        let (loaded, header) = try IndexPersistence.load(from: file)
        expectEqual(original, loaded)
        #expect(header.eventID == 3)
        #expect(tree.snapshot() == listing())
    }

    @Test func additionsRemovalsFlagsAndSubtreesRoundTripEveryColumn() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        store.write {
            store.removeChildren([2, 4000, 19000], of: 0)
            store.flags[15] |= IndexStore.Flag.hidden
            let first = Int32(store.count)
            var name = Array("new-folder".utf8)
            let folderItem = ScannedItem(nameOffset: 0, nameLength: name.count, isDirectory: true, isPackage: false,
                                        isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 50, fileKey: 123)
            let folder = name.withUnsafeBytes { store.appendChildren([folderItem], nameBuffer: $0, of: 0).lowerBound }
            name = Array("linked-file".utf8)
            let item = ScannedItem(nameOffset: 0, nameLength: name.count, isDirectory: false, isPackage: false,
                                  isSymlink: true, isHidden: false, isMountPoint: false, size: 17, mtime: 55, fileKey: 321)
            name.withUnsafeBytes { _ = store.appendChildren([item], nameBuffer: $0, of: folder) }
            store.integrateNew(from: first)
        }
        #expect(try IndexPersistence.save(store, eventID: 2, excluded: [], to: file).kind == .changes)
        let (loaded, _) = try IndexPersistence.load(from: file)
        expectEqual(store, loaded)
        #expect(loaded.lookup(tree.url("files/private-file-1.dat").path) == nil)
        #expect(loaded.lookup(tree.url("files/new-folder/linked-file").path) != nil)
        #expect(tree.snapshot() == listing())
    }

    @Test func interruptedChangesAndCheckpointsLeaveThePreviousPairUsable() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        edit(store)
        try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        let (previous, _) = try IndexPersistence.load(from: file)
        let base = try Data(contentsOf: file), changes = try Data(contentsOf: IndexPersistence.changesURL(for: file))
        edit(store, id: 20)
        for policy in [IndexPersistence.Policy(), IndexPersistence.Policy(maximumBytes: 0)] {
            #expect(throws: Stopped.self) {
                try IndexPersistence.save(store, eventID: 3, excluded: [], to: file, policy: policy,
                                          beforeCommit: { throw Stopped() })
            }
            #expect(try Data(contentsOf: file) == base)
            #expect(try Data(contentsOf: IndexPersistence.changesURL(for: file)) == changes)
            let (loaded, header) = try IndexPersistence.load(from: file)
            expectEqual(previous, loaded)
            #expect(header.eventID == 2)
        }
        try IndexPersistence.save(store, eventID: 3, excluded: [], to: file)
        expectEqual(store, try IndexPersistence.load(from: file).0)
        #expect(tree.snapshot() == listing())
    }

    @Test func aCrashAfterCheckpointNeverReplaysChangesFromTheOldGeneration() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        edit(store)
        try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        edit(store, by: 9)
        #expect(throws: Stopped.self) {
            try IndexPersistence.save(store, eventID: 3, excluded: [], to: file,
                                      policy: .init(maximumBytes: 0), afterSnapshotCommit: { throw Stopped() })
        }
        let (loaded, header) = try IndexPersistence.load(from: file)
        expectEqual(store, loaded)
        #expect(header.eventID == 3)
        edit(loaded, id: 25)
        try IndexPersistence.save(loaded, eventID: 4, excluded: [], to: file)
        expectEqual(loaded, try IndexPersistence.load(from: file).0)
        #expect(tree.snapshot() == listing())
    }

    @Test func sizeAndRevisionLimitsCheckpointAndRemoveTheOldChanges() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        edit(store)
        try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        edit(store)
        let result = try IndexPersistence.save(store, eventID: 3, excluded: [], to: file, policy: .init(maximumSaves: 1))
        #expect(result.kind == .snapshot)
        #expect(!FileManager.default.fileExists(atPath: IndexPersistence.changesURL(for: file).path))
        expectEqual(store, try IndexPersistence.load(from: file).0)
        edit(store)
        #expect(try IndexPersistence.save(store, eventID: 4, excluded: [], to: file, policy: .init(maximumBytes: 1)).kind == .snapshot)
        expectEqual(store, try IndexPersistence.load(from: file).0)
        #expect(tree.snapshot() == listing(false))
    }

    @Test func legacySnapshotsMigrateAndPrivacyChangesCheckpoint() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let original = fixture(tree)
        try original.read { try IndexPersistence.saveSnapshot(original, eventID: 10, excluded: [], to: file, generation: nil) }
        let (store, header) = try IndexPersistence.load(from: file)
        #expect(header.generation == nil)
        expectEqual(original, store)
        edit(store)
        #expect(try IndexPersistence.save(store, eventID: 11, excluded: [], to: file).kind == .snapshot)
        edit(store)
        try IndexPersistence.save(store, eventID: 12, excluded: [], to: file)
        store.write { store.removeChildren([10], of: 0) }
        #expect(try IndexPersistence.save(store, eventID: 13, excluded: ["/private-folder"], to: file).kind == .snapshot)
        let (loaded, current) = try IndexPersistence.load(from: file)
        expectEqual(store, loaded)
        #expect(current.excluded == ["/private-folder"])
        #expect(current.eventID == 13)
        #expect(tree.snapshot() == listing(false))
    }

    @Test func corruptOrTruncatedChangesFailClosedAndAnAbsentLogKeepsTheOldWatermark() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed"), delta = IndexPersistence.changesURL(for: file)
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 10, excluded: [], to: file)
        edit(store)
        try IndexPersistence.save(store, eventID: 20, excluded: [], to: file)
        let valid = try Data(contentsOf: delta)
        for length in [0, 24, valid.count - 1] {
            try valid.prefix(length).write(to: delta)
            #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        }
        var damaged = valid; damaged[damaged.count / 2] ^= 1
        try damaged.write(to: delta)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        try (valid + Data([0])).write(to: delta)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        try FileManager.default.removeItem(at: delta)
        let (loaded, header) = try IndexPersistence.load(from: file)
        #expect(header.eventID == 10)
        #expect(loaded.mtime[10] == 100)
        #expect(tree.snapshot() == listing(false))
    }

    @Test func authenticatedMalformedLengthsAndPointersAreRejected() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed"), delta = IndexPersistence.changesURL(for: file)
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 10, excluded: [], to: file)
        edit(store)
        try IndexPersistence.save(store, eventID: 20, excluded: [], to: file)
        let plain = try #require(SecureStorage.read(delta))
        var oversized = plain
        oversized.replaceSubrange(40..<48, with: withUnsafeBytes(of: UInt64.max) { Data($0) })
        try SecureStorage.write(oversized, to: delta)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        try SecureStorage.write(plain, to: delta)
        let (current, _) = try IndexPersistence.load(from: file)
        current.write { current.nextSibling[2] = 2 }
        try IndexPersistence.save(current, eventID: 30, excluded: [], to: file)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        #expect(tree.snapshot() == listing())
    }

    @Test func changesNeverFollowASymlinkAndCheckpointLeavesLookalikesAlone() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt", "state/index.sealed.changes-lookalike")
        let file = tree.url("state/index.sealed"), delta = IndexPersistence.changesURL(for: file)
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        try FileManager.default.createSymbolicLink(at: delta, withDestinationURL: tree.url("untouched.txt"))
        let (loaded, header) = try IndexPersistence.load(from: file)
        #expect(header.eventID == 1)
        expectEqual(store, loaded)
        edit(store)
        try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        #expect(tree.text("untouched.txt") == "untouched.txt")
        #expect(tree.text("state/index.sealed.changes-lookalike") == "state/index.sealed.changes-lookalike")
        #expect(tree.snapshot() == (listing(false) + ["state/index.sealed.changes-lookalike"]).sorted())
    }

    @Test func compactionAndLargeChangesUseFreshSnapshots() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        edit(store)
        try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        store.write { store.removeChildren([2, 4, 6], of: 0) }
        let compacted = store.read { store.compacted() }
        #expect(try IndexPersistence.save(compacted, eventID: 3, excluded: [], to: file).kind == .snapshot)
        expectEqual(compacted, try IndexPersistence.load(from: file).0)
        compacted.write {
            for i in compacted.flags.indices { compacted.mtime[i] += 1; compacted.fileKey[i] += 1; compacted.flags[i] |= IndexStore.Flag.hidden }
            for i in 1..<compacted.count { compacted.size[i] += 1 }
            compacted.size[0] += Int64(compacted.count - 1)
        }
        #expect(try IndexPersistence.save(compacted, eventID: 4, excluded: [], to: file).kind == .snapshot)
        expectEqual(compacted, try IndexPersistence.load(from: file).0)
        #expect(tree.snapshot() == listing(false))
    }

    @Test func emptyStoresAndChangedDestinationsDoNotReuseAnotherSnapshot() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed"), other = tree.url("state/other.sealed")
        let store = IndexStore()
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        expectEqual(store, try IndexPersistence.load(from: file).0)
        #expect(try IndexPersistence.save(store, eventID: 1, excluded: [], to: file).kind == .unchanged)
        #expect(try IndexPersistence.save(store, eventID: 1, excluded: [], to: other).kind == .snapshot)
        expectEqual(store, try IndexPersistence.load(from: other).0)
        #expect(tree.snapshot() == (listing(false) + ["state/other.sealed"]).sorted())
    }

    @Test func twoLoadedInstancesAndExternalReplacementNeverMixTheirBases() async throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let original = fixture(tree)
        try IndexPersistence.save(original, eventID: 1, excluded: [], to: file)
        let (a, _) = try IndexPersistence.load(from: file), (b, _) = try IndexPersistence.load(from: file)
        let gate = OSAllocatedUnfairLock(initialState: 0)
        let start = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        DispatchQueue.global().async {
            defer { start.signal(); gate.withLock { $0 = 2 } }
            do {
                a.write { a.mtime[10] += 1 }
                try IndexPersistence.save(a, eventID: 2, excluded: [], to: file, beforeCommit: {
                    gate.withLock { $0 = 1 }; start.signal()
                    if done.wait(timeout: .now() + 10) == .timedOut { throw Stopped() }
                })
            } catch { errors.withLock { $0.append(String(describing: error)) } }
        }
        // A blocking wait and the second writer both run on Dispatch, while the suite can keep making progress.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard start.wait(timeout: .now() + 10) == .success else {
                    errors.withLock { $0.append("The first writer did not start") }; continuation.resume(); return
                }
                done.signal()
                do {
                    b.write { b.mtime[20] += 1 }
                    try IndexPersistence.save(b, eventID: 3, excluded: [], to: file)
                } catch { errors.withLock { $0.append(String(describing: error)) } }
                continuation.resume()
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while gate.withLock({ $0 }) != 2 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        #expect(errors.withLock { $0 }.isEmpty)
        let (loaded, header) = try IndexPersistence.load(from: file)
        // The stale instance publishes a complete checkpoint with its own watermark, rather than applying its
        // changes to the other writer's newer log. Keep the older watermark so restart replays changes that this
        // stale instance may not have seen. Subsequent writes must not advance past that recovery point either.
        expectEqual(b, loaded)
        #expect(header.eventID == 1)
        edit(b, id: 30)
        try IndexPersistence.save(b, eventID: 4, excluded: [], to: file)
        let (again, after) = try IndexPersistence.load(from: file)
        expectEqual(b, again)
        #expect(after.eventID == 1)
        #expect(tree.snapshot() == listing())
    }

    @Test func partialTemporaryFilesAreIgnoredAndDirectoriesAreNeverRemoved() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt", "state/index.sealed.changes/keep.txt",
                                "state/index.sealed.changes.dead.tmp")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        expectEqual(store, try IndexPersistence.load(from: file).0)
        edit(store)
        #expect(throws: (any Error).self) { try IndexPersistence.save(store, eventID: 2, excluded: [], to: file) }
        #expect(tree.text("state/index.sealed.changes/keep.txt") == "state/index.sealed.changes/keep.txt")
        #expect(tree.text("untouched.txt") == "untouched.txt")
        #expect(tree.snapshot() == (listing(false) + ["state/index.sealed.changes/", "state/index.sealed.changes/keep.txt",
                                                     "state/index.sealed.changes.dead.tmp"]).sorted())
    }

    @Test func malformedSnapshotLengthsAndNamesThrowInsteadOfTrapping() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        store.write { store.nameStart[0] = UInt32.max }
        try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        let clean = fixture(tree)
        try IndexPersistence.save(clean, eventID: 3, excluded: [], to: file)
        var plain = try #require(SecureStorage.read(file))
        let rootLength = 4 + 4 + 16 + 8 + 4 + 4 + 4 + tree.url("files").path.utf8.count + 4
        plain.replaceSubrange(rootLength..<(rootLength + 8), with: withUnsafeBytes(of: UInt64.max) { Data($0) })
        try SecureStorage.write(plain, to: file)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        #expect(tree.snapshot() == listing(false))
    }

    @Test func measureWriteVolumeAndRestartWork() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree, count: 200_000)
        var initialBytes = 0, deltaBytes = 0
        let clock = ContinuousClock()
        let fullTime = try clock.measure { initialBytes = try IndexPersistence.save(store, eventID: 1, excluded: [], to: file).bytesWritten }
        var initial: IndexStore?, updated: IndexStore?
        let initialLoad = try clock.measure { initial = try IndexPersistence.load(from: file).0 }
        expectEqual(store, try #require(initial))
        edit(store)
        let deltaTime = try clock.measure { deltaBytes = try IndexPersistence.save(store, eventID: 2, excluded: [], to: file).bytesWritten }
        let deltaLoad = try clock.measure { updated = try IndexPersistence.load(from: file).0 }
        expectEqual(store, try #require(updated))
        #expect(deltaBytes < initialBytes / 100)
        print("Index experiment, 200k entries: snapshot \(initialBytes) bytes in \(fullTime); changes \(deltaBytes) bytes in \(deltaTime); initial restart \(initialLoad); incremental restart \(deltaLoad).")
        #expect(tree.snapshot() == listing())
    }

    @Test func missingGrowthPagesAndAnOlderEventWatermarkAreRejected() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed"), delta = IndexPersistence.changesURL(for: file)
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 10, excluded: [], to: file)
        edit(store)
        try IndexPersistence.save(store, eventID: 20, excluded: [], to: file)
        let plain = try #require(SecureStorage.read(delta))
        var missing = plain
        missing.replaceSubrange(40..<48, with: withUnsafeBytes(of: UInt64(store.parent.count * 4 + 16384)) { Data($0) })
        try SecureStorage.write(missing, to: delta)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        var backwards = plain
        backwards.replaceSubrange(32..<40, with: withUnsafeBytes(of: UInt64(9)) { Data($0) })
        try SecureStorage.write(backwards, to: delta)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: file) }
        #expect(tree.snapshot() == listing())
    }

    @Test func appendedNamesAndColumnsCrossBlockBoundariesWithoutGaps() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let store = fixture(tree)
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        store.write {
            let first = Int32(store.count)
            var names: [UInt8] = [], items: [ScannedItem] = []
            for i in 0..<1000 {
                let name = Array("Résumé-β-long-file-name-\(i).txt".utf8)
                items.append(ScannedItem(nameOffset: names.count, nameLength: name.count, isDirectory: false,
                                         isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false,
                                         size: Int64(i), mtime: 999, fileKey: UInt32(i)))
                names.append(contentsOf: name)
            }
            names.withUnsafeBytes { _ = store.appendChildren(items, nameBuffer: $0, of: 0) }
            store.integrateNew(from: first)
        }
        #expect(try IndexPersistence.save(store, eventID: 2, excluded: [], to: file).kind == .changes)
        let (loaded, _) = try IndexPersistence.load(from: file)
        expectEqual(store, loaded)
        #expect(loaded.lookup(tree.url("files/Résumé-β-long-file-name-999.txt").path) != nil)
        #expect(tree.snapshot() == listing())
    }

    @Test func aReplacementByAnOlderBuildDuringLoadingIsRejected() throws {
        let tree = try TestTree("files/", "state/", "untouched.txt")
        let file = tree.url("state/index.sealed")
        let first = fixture(tree), replacement = fixture(tree)
        try IndexPersistence.save(first, eventID: 1, excluded: [], to: file)
        edit(replacement, id: 20)
        #expect(throws: (any Error).self) {
            try IndexPersistence.load(from: file, afterSnapshotRead: {
                // Bypass the new directory lock as an older app does, replacing the snapshot in this exact gap.
                try replacement.read {
                    try IndexPersistence.saveSnapshot(replacement, eventID: 2, excluded: [], to: file, generation: nil)
                }
            })
        }
        expectEqual(replacement, try IndexPersistence.load(from: file).0)
        #expect(tree.snapshot() == listing(false))
    }
}
