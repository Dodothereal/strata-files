import CoreServices
import Foundation
import Testing
import os
@testable import Strata

struct IndexWorkerTests {
    private struct Fixture {
        let worker: IndexWorker
        let config: IndexConfig
        let store: IndexStore
        let changes: OSAllocatedUnfairLock<Int>
    }

    private func start(_ tree: TestTree) async throws -> Fixture {
        let config = IndexConfig(roots: [tree.root.path], excluded: [tree.url(".state").path], noise: [],
                                 file: tree.url(".state/index.sealed"))
        let worker = IndexWorker()
        let store = OSAllocatedUnfairLock<IndexStore?>(initialState: nil)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        worker.onStore = { value in store.withLock { $0 = value } }
        worker.onChange = { changes.withLock { $0 += 1 } }
        worker.start(config)
        let deadline = ContinuousClock.now + .seconds(15)
        while store.withLock({ $0 == nil }) || !FileManager.default.fileExists(atPath: config.file.path) {
            try #require(ContinuousClock.now < deadline, "The temporary index did not finish its initial save.")
            try await Task.sleep(for: .milliseconds(10))
        }
        return Fixture(worker: worker, config: config, store: try #require(store.withLock { $0 }), changes: changes)
    }

    private func save(_ worker: IndexWorker) async {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                worker.saveNow()
                done.resume()
            }
        }
    }

    @Test func appConfigurationExcludesItsOwnPrivateState() throws {
        let config = FileIndex.currentConfig()
        let resolved = try #require(realpath(SecureStorage.directory.path, nil))
        defer { free(resolved) }
        let directory = String(cString: resolved)
        #expect(config.excluded.contains(directory))
        #expect(config.file.deletingLastPathComponent().path == SecureStorage.directory.path)
    }

    @Test func stateFolderEventsDoNotNotifyOrRewriteTheIndex() async throws {
        let tree = try TestTree(".state/", "a.txt", ".state-lookalike/visible.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add([".state/history.sealed", ".state/index.sealed.temporary.tmp"])
        fixture.worker.receive([
            .init(path: tree.url(".state").path + "/", flags: 0, id: 1),
            .init(path: tree.url(".state/history.sealed").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(fixture.store.read { fixture.store.lookup(tree.url(".state/history.sealed").path) } == nil)
        #expect(fixture.store.read { fixture.store.lookup(tree.url(".state-lookalike/visible.txt").path) } != nil)
        #expect(tree.snapshot() == [".state-lookalike/", ".state-lookalike/visible.txt", ".state/",
                                    ".state/history.sealed", ".state/index.sealed", ".state/index.sealed.temporary.tmp", "a.txt"])
    }

    @Test func aMixedBatchStillPersistsUserFilesBesideTheExcludedState() async throws {
        let tree = try TestTree(".state/", "files/a.txt")
        let fixture = try await start(tree)
        try tree.add([".state/history.sealed", "files/new.txt"])
        fixture.worker.receive([
            .init(path: tree.url(".state").path, flags: 0, id: 1),
            .init(path: tree.url("files").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file)
        #expect(loaded.lookup(tree.url("files/new.txt").path) != nil)
        #expect(loaded.lookup(tree.url(".state/history.sealed").path) == nil)
        #expect(tree.text("files/a.txt") == "files/a.txt")
        #expect(tree.snapshot() == [".state/", ".state/history.sealed", ".state/index.sealed", "files/", "files/a.txt", "files/new.txt"])
    }
}
