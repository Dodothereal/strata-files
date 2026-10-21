import Foundation
import Synchronization
import Testing
@testable import Strata

struct RemoteSessionOwnershipTests {
    nonisolated private final class Backend: RemoteBackend {
        private struct State { var alive = true; var closes = 0 }
        private let state = Mutex(State())
        var closeCount: Int { state.withLock { $0.closes } }
        var isAlive: Bool { state.withLock { $0.alive } }
        func drop() { state.withLock { $0.alive = false } }
        func close() { state.withLock { $0.alive = false; $0.closes += 1 } }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] { [] }
        func kind(of path: String) async throws -> RemoteItemKind? { nil }
        func download(_ path: String, to destination: URL, limit: Int64,
                      progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw RemoteError.unknownServer }
        func upload(_ source: URL, to path: String, modified: Date?,
                    progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw RemoteError.unknownServer }
        func makeFolder(_ path: String) async throws { throw RemoteError.unknownServer }
        func rename(_ path: String, to newPath: String) async throws { throw RemoteError.unknownServer }
        func remove(_ path: String) async throws { throw RemoteError.unknownServer }
    }

    private enum Failure: Error { case refused }

    private actor Factory {
        private(set) var calls: [RemoteServer] = []
        private(set) var changes: [Bool] = []
        private var waiting: [Int: CheckedContinuation<any RemoteBackend, any Error>] = [:]
        private let held: Set<Int>
        private let holdStatus: Bool?
        private var statusWasHeld = false
        private var statusWaiter: CheckedContinuation<Void, Never>?
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var statusStartWaiters: [CheckedContinuation<Void, Never>] = []

        init(held: Set<Int> = [0, 1], holdStatus: Bool? = nil) {
            self.held = held
            self.holdStatus = holdStatus
        }

        func connect(_ server: RemoteServer) async throws -> any RemoteBackend {
            let index = calls.count
            calls.append(server)
            let started = startWaiters.filter { $0.count <= calls.count }
            startWaiters.removeAll { $0.count <= calls.count }
            for waiter in started { waiter.continuation.resume() }
            if !held.contains(index) { return Backend() }
            return try await withCheckedThrowingContinuation { waiting[index] = $0 }
        }

        func finish(_ index: Int, with backend: Backend) { waiting.removeValue(forKey: index)?.resume(returning: backend) }
        func fail(_ index: Int) { waiting.removeValue(forKey: index)?.resume(throwing: Failure.refused) }
        func changed(_ connected: Bool) async {
            changes.append(connected)
            if holdStatus == connected && !statusWasHeld {
                statusWasHeld = true
                await withCheckedContinuation { continuation in
                    statusWaiter = continuation
                    let started = statusStartWaiters
                    statusStartWaiters.removeAll()
                    for waiter in started { waiter.resume() }
                }
            }
        }
        func releaseStatus() { statusWaiter?.resume(); statusWaiter = nil }
        func waitForHeldStatus() async {
            guard statusWaiter == nil else { return }
            await withCheckedContinuation { statusStartWaiters.append($0) }
        }

        func waitForCalls(_ count: Int) async {
            guard calls.count < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        // The cancelled-attempt mutation intentionally never calls the factory again. Poll on the same actor as
        // the test's request tasks, so waiting cannot expire while those tasks are still queued behind other suites.
        @MainActor func waitForReplacement() async -> Bool {
            for _ in 0..<500 {
                if await calls.count >= 2 { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

    }

    @Test func aNewConnectionDoesNotJoinTheCancelledAttempt() async throws {
        for oldFirst in [false, true] {
            for oldFails in [false, true] {
                let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
                let factory = Factory()
                let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
                    connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
                let old = Backend(), replacement = Backend()
                let first = Task { try await sessions.backend(for: server.id) }
                await factory.waitForCalls(1)
                await sessions.disconnect(server.id)
                let second = Task { try await sessions.backend(for: server.id) }
                let restarted = await factory.waitForReplacement()
                #expect(restarted)
                let firstResult: Result<any RemoteBackend, any Error>
                let secondResult: Result<any RemoteBackend, any Error>
                if oldFirst || !restarted {
                    // The fallback also releases the cancelled request when testing the buggy implementation.
                    if oldFails { await factory.fail(0) } else { await factory.finish(0, with: old) }
                    firstResult = await first.result
                    await factory.finish(1, with: replacement)
                    secondResult = await second.result
                } else {
                    await factory.finish(1, with: replacement)
                    secondResult = await second.result
                    if oldFails { await factory.fail(0) } else { await factory.finish(0, with: old) }
                    firstResult = await first.result
                }
                switch firstResult {
                case .success: Issue.record("The cancelled attempt returned a backend")
                case .failure(let error): #expect(oldFails ? error is Failure : error is CancellationError)
                }
                switch secondResult {
                case .success(let backend): #expect(backend === replacement && backend.isAlive)
                case .failure(let error): Issue.record(error)
                }
                #expect(old.closeCount == (oldFails ? 0 : 1) && replacement.closeCount == 0)
                #expect(await sessions.isConnected(server.id))
                #expect(await factory.calls == [server, server])
                #expect(await factory.changes == [true])
                await sessions.disconnect(server.id)
                #expect(replacement.closeCount == 1)
                #expect(await factory.changes == [true, false])
            }
        }
    }

    @Test func concurrentCallersShareThePublishedBackendAndUnknownServersNeverConnect() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [0])
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        await #expect(throws: RemoteError.unknownServer) { try await sessions.backend(for: "not-saved") }
        #expect(await factory.calls.isEmpty)
        let backend = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        let others = (0..<12).map { _ in Task { try await sessions.backend(for: server.id) } }
        await factory.finish(0, with: backend)
        #expect(try await first.value === backend)
        for request in others { #expect(try await request.value === backend) }
        #expect(try await sessions.backend(for: server.id) === backend)
        #expect(await factory.calls == [server])
        #expect(await factory.changes == [true])
        await sessions.disconnect(server.id)
        await sessions.disconnect(server.id)
        #expect(backend.closeCount == 1)
        #expect(await factory.changes == [true, false])
    }

    @Test func disconnectionDuringStatusPublicationCannotReturnAClosedBackend() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(held: [0], holdStatus: true)
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let backend = Backend()
        let request = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: backend)
        await factory.waitForHeldStatus()
        await sessions.disconnect(server.id)
        await factory.releaseStatus()
        switch await request.result {
        case .success: Issue.record("A disconnected backend escaped to its caller")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(backend.closeCount == 1)
        #expect(await !sessions.isConnected(server.id))
        #expect(await factory.changes == [true, false])
    }

    @Test func independentPoolsKeepTheirOwnServersBackendsAndStatus() async throws {
        let first = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "First", host: "first.invalid")
        var second = first
        second.host = "second.invalid"
        let otherServer = second
        let a = Factory(held: [0]), b = Factory(held: [0])
        let left = RemoteSessions(server: { $0 == first.id ? first : nil },
            connect: { try await a.connect($0) }, changed: { _, value in await a.changed(value) })
        let right = RemoteSessions(server: { $0 == otherServer.id ? otherServer : nil },
            connect: { try await b.connect($0) }, changed: { _, value in await b.changed(value) })
        let leftBackend = Backend(), rightBackend = Backend()
        let leftRequest = Task { try await left.backend(for: first.id) }
        let rightRequest = Task { try await right.backend(for: first.id) }
        await a.waitForCalls(1)
        await b.waitForCalls(1)
        await a.finish(0, with: leftBackend)
        await b.finish(0, with: rightBackend)
        #expect(try await leftRequest.value === leftBackend)
        #expect(try await rightRequest.value === rightBackend)
        #expect(await a.calls == [first])
        #expect(await b.calls == [otherServer])
        await left.disconnect(first.id)
        #expect(leftBackend.closeCount == 1 && rightBackend.closeCount == 0)
        #expect(await right.isConnected(first.id))
        #expect(try await right.backend(for: first.id) === rightBackend)
        #expect(await a.changes == [true, false])
        #expect(await b.changes == [true])
        await right.disconnect(first.id)
        #expect(rightBackend.closeCount == 1)
    }

    @Test func aDroppedConnectionIsRetiredEvenWhenReconnectingFails() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory()
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let backend = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: backend)
        #expect(try await first.value === backend)
        backend.drop()
        let retry = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(2)
        #expect(backend.closeCount == 1)
        #expect(await factory.changes == [true, false])
        await factory.fail(1)
        switch await retry.result {
        case .success: Issue.record("The failed connection succeeded")
        case .failure(let error): #expect(error is Failure)
        }
        #expect(await !sessions.isConnected(server.id))
        let repaired = try await sessions.backend(for: server.id)
        #expect(repaired.isAlive && repaired !== backend)
        #expect(await factory.calls == [server, server, server])
        #expect(await factory.changes == [true, false, true])
        await sessions.disconnect(server.id)
        #expect(!repaired.isAlive && backend.closeCount == 1)
        #expect(await factory.changes == [true, false, true, false])
    }


    @Test func reconnectingDuringDroppedStatusPublicationReusesTheNewConnection() async throws {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let factory = Factory(holdStatus: false)
        let sessions = RemoteSessions(server: { $0 == server.id ? server : nil },
            connect: { try await factory.connect($0) }, changed: { _, value in await factory.changed(value) })
        let old = Backend(), replacement = Backend()
        let first = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(1)
        await factory.finish(0, with: old)
        #expect(try await first.value === old)
        old.drop()
        let noticing = Task { try await sessions.backend(for: server.id) }
        await factory.waitForHeldStatus()
        let reconnecting = Task { try await sessions.backend(for: server.id) }
        await factory.waitForCalls(2)
        await factory.finish(1, with: replacement)
        #expect(try await reconnecting.value === replacement)
        await factory.releaseStatus()
        #expect(try await noticing.value === replacement)
        #expect(old.closeCount == 1 && replacement.closeCount == 0)
        #expect(await factory.calls == [server, server])
        #expect(await factory.changes == [true, false, true])
        await sessions.disconnect(server.id)
        #expect(replacement.closeCount == 1)
    }

}
