import Foundation

/// Reading items from a container before they're handed on (copied to the clipboard, opened, previewed): shown in the
/// Transfers list with a Stop button, so a big file or folder isn't a silent wait.
final class ContainerFetchJob {
    let urls: [URL]
    let containerName: String
    private(set) var state: TransferState = .queued
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private let then: () -> Void
    var onChange: ((ContainerFetchJob) -> Void)?
    var onFinish: ((ContainerFetchJob) -> Void)?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    /// `then` runs once everything is read (not when it fails or is stopped).
    init(_ urls: [URL], then: @escaping () -> Void) {
        self.urls = urls
        self.then = then
        containerName = urls.first.flatMap(LazyCopies.sourceName) ?? ""
    }

    func start() {
        guard state == .queued else { return }
        state = .running
        onChange?(self)
        task = Task {
            do {
                try await LazyCopies.prepareForCopying(urls)
                try Task.checkCancellation()
                guard !urls.contains(where: LazyCopies.isPlaceholder) else { throw ContainerAPIError.notFound }
                state = .finished
                then()
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = Task.isCancelled ? .cancelled : .failed
                if let first = urls.first { errorMessage = LazyCopies.message(for: error, about: first) }
            }
            finish()
        }
    }

    func cancel() {
        task?.cancel()
        if state == .queued {
            state = .cancelled
            finish()
        }
    }

    func finished() async {
        guard state.isActive else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    private func finish() {
        onChange?(self)
        onFinish?(self)
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension ContainerFetchJob: QueueJob {
    var title: String {
        state.isActive ? String(localized: "Reading from “\(containerName)”", comment: "Transfers list: items being read from a container")
            : String(localized: "Read from “\(containerName)”", comment: "Transfers list: items read from a container")
    }

    var statusText: String {
        switch state {
        case .queued, .scanning, .running, .paused: String(localized: "Working…", comment: "Transfers list: a job in progress")
        case .finished: String(localized: "Done", comment: "Transfers list: job status")
        case .failed: errorMessage ?? String(localized: "Failed", comment: "Transfers list: job status")
        case .cancelled: String(localized: "Stopped", comment: "Transfers list: job status (cancelled)")
        }
    }

    var failureSummary: String? { errorMessage }
    var symbolName: String { "shippingbox" }
    var fractionCompleted: Double? { state == .finished ? 1 : nil }
    var failureCount: Int { 0 }
    var canPause: Bool { false }
    var canResume: Bool { false }
    var canCancel: Bool { state.isActive }
    var canRetry: Bool { false }
    var createdItems: [URL] { [] }
    var destination: URL { urls.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/") }
    var totalWork: Double { 1_000_000 }
    var completedWork: Double { state.isActive ? 0 : totalWork }
    func pause() {}
    func resume() {}
    func retryFailed() {}
    func sample(_ now: TimeInterval) {}
}
