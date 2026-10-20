import AppKit
import CryptoKit
import Testing
@testable import Strata

struct TransferContextTests {
    private final class Environment {
        let name = "StrataTransferContextTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let preferences: Prefs
        let storage: SecureStorage.Context
        let history: OperationLog
        let queue: TransferQueue

        init(_ tree: TestTree) throws {
            defaults = try #require(UserDefaults(suiteName: name))
            preferences = Prefs(defaults: defaults, domainName: name)
            storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                             key: SymmetricKey(data: Data(repeating: 9, count: 32)))
            history = OperationLog(storage: storage)
            queue = TransferQueue(preferences: preferences, history: history)
        }

        isolated deinit { defaults.removePersistentDomain(forName: name) }
    }

    @Test func queueUsesItsOwnCurrentPreferencesAndExplicitOverrides() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "out/", "state/")
        let env = try Environment(tree)
        for verify in [false, true] {
            env.preferences.verifyCopies = verify
            let copy = env.queue.enqueue([tree.url("a.txt")], to: tree.url("out"), mode: .copy,
                                         undo: nil, conflicts: .keepBoth)
            #expect(copy.options.verify == verify)
            await copy.finished()
            #expect(copy.failures.isEmpty && copy.state == .finished)
            let move = env.queue.enqueue(moves: [], mode: .move, undo: nil, conflicts: .keepBoth)
            #expect(move.options.verify == verify)
            await move.finished()
            let explicit = env.queue.enqueue([], to: tree.url("out"), mode: .copy, verify: !verify,
                                             undo: nil, conflicts: .keepBoth)
            #expect(explicit.options.verify == !verify)
            await explicit.finished()
        }
        #expect(env.history.entries.count == 2)
        #expect(tree.text("a.txt") == "a.txt" && tree.text("ab.txt") == "ab.txt")
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "out/", "out/a 2.txt", "out/a.txt", "state/", "state/history.sealed"])
    }

    @Test func transferHistoryAndRepeatedUndoStayWithTheirOwner() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "other/", "other/a.txt", "out/", "link -> a.txt", "state/")
        let env = try Environment(tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let job = env.queue.enqueue([tree.url("a.txt")], to: tree.url("out"), mode: .move,
                                    undo: undo, conflicts: .keepBoth)
        await job.finished()
        undo.endUndoGrouping()
        #expect(job.failures.isEmpty && job.state == .finished)
        let id = try #require(env.history.entries.first?.id)
        let moved = ["ab.txt", "link -> a.txt", "other/", "other/a.txt", "out/", "out/a.txt", "state/", "state/history.sealed"]
        let restored = ["a.txt", "ab.txt", "link -> a.txt", "other/", "other/a.txt", "out/", "state/", "state/history.sealed"]
        #expect(tree.snapshot() == moved)
        for _ in 0..<3 {
            undo.undo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: env.storage).entries.first?.undone == true)
            #expect(tree.snapshot() == restored)
            undo.redo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: env.storage).entries.first?.undone == false)
            #expect(tree.snapshot() == moved)
        }
        #expect(!OperationLog.shared.entries.contains { $0.id == id })
        // Identity, not the saved path, determines whether Undo may touch an item.
        try FileManager.default.moveItem(at: tree.url("out/a.txt"), to: tree.url("out/original.txt"))
        try tree.add(["out/a.txt"])
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.text("out/a.txt") == "out/a.txt")
        #expect(tree.text("out/original.txt") == "a.txt")
        #expect(tree.snapshot() == ["ab.txt", "link -> a.txt", "other/", "other/a.txt", "out/", "out/a.txt",
                                   "out/original.txt", "state/", "state/history.sealed"])
    }

    @Test func queuedArchivesRecordInTheirOwnersHistory() async throws {
        let tree = try TestTree("source/a.txt", "ab.txt", "out/", "state/")
        let env = try Environment(tree)
        let compress = ArchiveJob(.compress([tree.url("source")]), undo: nil)
        env.queue.add(compress)
        await compress.finished()
        #expect(compress.state == .finished)
        let archive = try #require(compress.result)
        let extract = ArchiveJob(.extract(archive, into: tree.url("out")), undo: nil)
        env.queue.add(extract)
        await extract.finished()
        #expect(extract.state == .finished)
        #expect(env.history.entries.count == 2)
        let ids = Set(env.history.entries.map(\.id))
        #expect(Set(OperationLog(storage: env.storage).entries.map(\.id)) == ids)
        #expect(!OperationLog.shared.entries.contains { ids.contains($0.id) })
        #expect(tree.text("out/source/a.txt") == "source/a.txt")
        #expect(tree.snapshot() == ["ab.txt", "out/", "out/source/", "out/source/a.txt", "source.zip", "source/", "source/a.txt", "state/", "state/history.sealed"].sorted())
    }

    @Test func crossDiskUndoAndRedoUseTheOriginalQueue() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let tree = try TestTree("a.txt", "ab.txt", "state/")
            let env = try Environment(tree)
            env.preferences.verifyCopies = false
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            let job = env.queue.enqueue([tree.url("a.txt")], to: volume.root, mode: .move,
                                        undo: undo, conflicts: .keepBoth)
            await job.finished()
            undo.endUndoGrouping()
            #expect(job.failures.isEmpty && job.state == .finished)
            let id = try #require(env.history.entries.first?.id)
            for cycle in 0..<3 {
                undo.undo()
                await finishRelatedJobs(env.queue, tree: tree, volume: volume)
                #expect(env.queue.jobs.count == 2 + 2 * cycle)
                #expect(tree.snapshot() == ["a.txt", "ab.txt", "state/", "state/history.sealed"])
                #expect(!FileManager.default.fileExists(atPath: volume.url("a.txt").path))
                #expect(env.history.entries.first?.undone == true)
                undo.redo()
                await finishRelatedJobs(env.queue, tree: tree, volume: volume)
                #expect(env.queue.jobs.count == 3 + 2 * cycle)
                #expect(env.history.entries.first?.undone == false)
                #expect(try String(contentsOf: volume.url("a.txt"), encoding: .utf8) == "a.txt")
                #expect(tree.snapshot() == ["ab.txt", "state/", "state/history.sealed"])
            }
            #expect(env.history.entries.count == 1)
            #expect(!OperationLog.shared.entries.contains { $0.id == id })
            #expect(env.queue.jobs.compactMap { $0 as? TransferJob }.allSatisfy { !$0.options.verify })
            #expect(tree.snapshot() == ["ab.txt", "state/", "state/history.sealed"])
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }

    @Test func failedJobsRetryWithTheirHistoryAndCompletedJobsReleaseTheirQueue() async throws {
        let tree = try TestTree("out/", "state/")
        let env = try Environment(tree)
        var queue: TransferQueue? = TransferQueue(preferences: env.preferences, history: env.history)
        weak var owner = queue
        let job = try #require(queue).enqueue([tree.url("a.txt")], to: tree.url("out"), mode: .copy,
                                              undo: nil, conflicts: .keepBoth)
        await job.finished()
        #expect(job.canRetry && job.state == .failed)
        #expect(env.history.entries.isEmpty)
        try tree.add(["a.txt"])
        job.retryFailed()
        queue = nil
        await job.finished()
        #expect(job.state == .finished && job.failures.isEmpty)
        #expect(env.history.entries.count == 1)
        let id = try #require(env.history.entries.first?.id)
        #expect(!OperationLog.shared.entries.contains { $0.id == id })
        // The ticker may still be asleep. Wait for ownership to settle, not for an assumed timer interval.
        let deadline = ContinuousClock.now + .seconds(10)
        while owner != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner == nil)
        #expect(job.state == .finished && !job.canRetry)
        #expect(tree.text("out/a.txt") == "a.txt")
        #expect(tree.snapshot() == ["a.txt", "out/", "out/a.txt", "state/", "state/history.sealed"])
    }

    /// Also drain a misrouted job when deliberately breaking queue ownership in a mutation test.
    private func finishRelatedJobs(_ queue: TransferQueue, tree: TestTree, volume: ScratchVolume) async {
        await FileOps.undoWork?.value
        for job in queue.jobs { await job.finished() }
        let roots = [tree.root, volume.root].map { $0.standardizedFileURL.path + "/" }
        for job in TransferQueue.shared.jobs.compactMap({ $0 as? TransferJob }) {
            if job.sources.contains(where: { source in roots.contains { source.standardizedFileURL.path.hasPrefix($0) } }) {
                await job.finished()
            }
        }
    }
}
