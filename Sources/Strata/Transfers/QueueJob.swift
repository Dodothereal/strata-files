import Foundation

/// Anything the Transfers list shows and the queue tracks: copies and moves, compressing and extracting.
protocol QueueJob: AnyObject {
    var title: String { get }
    var statusText: String { get }
    /// What went wrong, for a tooltip.
    var failureSummary: String? { get }
    var symbolName: String { get }
    var state: TransferState { get }
    var fractionCompleted: Double? { get }
    /// Items that failed while the rest finished.
    var failureCount: Int { get }
    var canPause: Bool { get }
    var canResume: Bool { get }
    var canCancel: Bool { get }
    var canRetry: Bool { get }
    /// What the job made, for Show in Folder.
    var createdItems: [URL] { get }
    var destination: URL { get }
    /// Weights for the overall progress of everything running.
    var totalWork: Double { get }
    var completedWork: Double { get }
    func pause()
    func resume()
    func cancel()
    func retryFailed()
    /// Picks up progress; called a few times a second while the job runs.
    func sample(_ now: TimeInterval)
    /// Returns once the job has stopped running.
    func finished() async
}

extension TransferJob: QueueJob {
    var failureCount: Int { failures.count }
}

extension ArchiveJob: QueueJob {
    var failureSummary: String? { errorMessage }
    var failureCount: Int { 0 }
    var canPause: Bool { false }
    var canResume: Bool { false }
    var canCancel: Bool { state.isActive }
    var canRetry: Bool { false }
    var createdItems: [URL] { result.map { [$0] } ?? [] }
    /// Weighed by the archive's unpacked size (or as a medium file when that isn't known), like copies by theirs.
    var totalWork: Double { weight }
    var completedWork: Double { state.isActive ? (fractionCompleted ?? 0) * weight : weight }
    func pause() {}
    func resume() {}
    func retryFailed() {}
    func sample(_ now: TimeInterval) { sample() }
}
