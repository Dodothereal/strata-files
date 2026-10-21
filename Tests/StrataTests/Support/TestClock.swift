import Foundation

/// Cache tests advance their own time instead of depending on how quickly a worker or the main actor resumes.
nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1000)

    func now() -> Date { lock.withLock { instant } }
    func advance(by interval: TimeInterval) { lock.withLock { instant.addTimeInterval(interval) } }
}
