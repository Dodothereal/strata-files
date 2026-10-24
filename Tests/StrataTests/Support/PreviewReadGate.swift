import Foundation

/// A provider deliberately stays suspended after cancellation, so tests can verify draining and late responses.
nonisolated final class PreviewReadGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CheckedContinuation<Value, Error>?
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func read() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiters = lock.withLock {
                    value = continuation
                    started = true
                    let waiters = startWaiters; startWaiters = []; return waiters
                }
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            let waiters = self.lock.withLock {
                self.cancelled = true
                let waiters = self.cancelWaiters; self.cancelWaiters = []; return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if started { return true }; startWaiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }

    func waitUntilCancelled() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if cancelled { return true }; cancelWaiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { let current = value; value = nil; return current }
        continuation?.resume(with: result)
    }
}
