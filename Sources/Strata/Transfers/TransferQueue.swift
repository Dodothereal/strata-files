import AppKit

/// Every copy and move in the app. Jobs start measuring and asking about conflicts right away, then copy one at a
/// time per destination disk (same-volume moves are renames and never wait).
final class TransferQueue {
    static let shared = TransferQueue()

    /// Posted (object: the queue) when jobs are added, removed, change state, or a few times a second while running.
    static let didChangeNotification = Notification.Name("StrataTransferQueueDidChange")
    /// Posted (object: the job) each time a job finishes a pass: done, failed, cancelled, or after a retry.
    static let jobDidFinishNotification = Notification.Name("StrataTransferJobDidFinish")

    private(set) var jobs: [TransferJob] = []
    /// Called alongside `didChangeNotification`, for a single owner that prefers a closure.
    var onChange: (() -> Void)?

    private var busyDisks: [dev_t: ObjectIdentifier] = [:]
    private var waiters: [(job: ObjectIdentifier, order: Int, disk: dev_t, continuation: CheckedContinuation<Bool, Never>)] = []
    private var ticker: Task<Void, Never>?
    private var notifyScheduled = false

    init() {}

    // MARK: - Public

    /// Copies or moves `sources` into the folder `destination`. Name clashes go to `conflicts`; with `verify`, every
    /// copied file is read back and compared (SHA-256). When the job finishes, its undo is registered on `undo`.
    @discardableResult
    func enqueue(_ sources: [URL], to destination: URL, mode: TransferMode, verify: Bool = Prefs.verifyCopies,
                 undo: UndoManager?, conflicts: ConflictResolver) -> TransferJob {
        var options = TransferEngine.Options()
        options.verify = verify
        return enqueue(sources, to: destination, mode: mode, options: options, undo: undo, conflicts: conflicts)
    }

    @discardableResult
    func enqueue(_ sources: [URL], to destination: URL, mode: TransferMode, options: TransferEngine.Options,
                 undo: UndoManager?, conflicts: ConflictResolver) -> TransferJob {
        let folder = destination.standardizedFileURL
        let moves = sources.map { TransferMove(from: $0.standardizedFileURL, to: folder.appending(path: $0.lastPathComponent)) }
        return enqueue(moves: moves, destination: folder, mode: mode, options: options, undo: undo, conflicts: conflicts)
    }

    /// Item-by-item destinations, for undoing moves whose items came from different folders.
    @discardableResult
    func enqueue(moves: [TransferMove], destination: URL? = nil, mode: TransferMode,
                 options: TransferEngine.Options = .userDefault, undo: UndoManager?, conflicts: ConflictResolver,
                 logHistory: Bool = true, actionName: String? = nil, containers: [URL] = []) -> TransferJob {
        let folder = destination ?? moves.first?.to.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        let job = TransferJob(mode: mode, moves: moves, destination: folder, options: options, undo: undo,
                              conflicts: conflicts, queue: self)
        job.logsHistory = logHistory
        job.actionName = actionName
        job.containers = containers
        jobs.append(job)
        job.start()
        notify()
        startTicking()
        return job
    }

    /// Overall progress of every unfinished job, weighted by size, or nil when nothing is running.
    var overallProgress: Double? {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0) { $0 + $1.totalWork }
        guard total > 0 else { return 0 }
        return min(1, active.reduce(0) { $0 + $1.completedWork } / total)
    }

    var hasActiveJobs: Bool { jobs.contains { $0.state.isActive } }

    var hasFailures: Bool { jobs.contains { $0.canRetry } }

    var hasFinishedJobs: Bool { jobs.contains { !$0.state.isActive } }

    /// Removes finished, failed and cancelled jobs from the list.
    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
        notify()
    }

    func remove(_ job: TransferJob) {
        guard !job.state.isActive else { return }
        jobs.removeAll { $0 === job }
        notify()
    }

    /// For `applicationShouldTerminate`: asks before quitting while transfers run. Stopping them first removes
    /// partially written items and keeps every finished one, so nothing half-copied is left behind.
    func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active.count == 1 ? "A transfer is still in progress" : "\(active.count) transfers are still in progress"
        alert.informativeText = "Quitting stops them. Items already copied stay; the item being copied right now is removed."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        // Return keeps the transfers going; stopping them takes a deliberate click.
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        active.forEach { $0.cancel() }
        Task {
            for job in active { await job.finished() }
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Jobs

    func jobDidChange(_ job: TransferJob) {
        notify()
    }

    func jobDidFinish(_ job: TransferJob) {
        notifyNow()
        NotificationCenter.default.post(name: Self.jobDidFinishNotification, object: job)
        startTicking()
    }

    // MARK: - One writer per disk

    func isDiskFree(_ disk: dev_t, for job: TransferJob) -> Bool {
        busyDisks[disk] == nil || busyDisks[disk] == ObjectIdentifier(job)
    }

    /// Waits until no other job writes to `disk`. Returns false if the job was cancelled while waiting.
    func acquireDisk(_ disk: dev_t, for job: TransferJob) async -> Bool {
        if isDiskFree(disk, for: job) {
            busyDisks[disk] = ObjectIdentifier(job)
            return true
        }
        let order = jobs.firstIndex { $0 === job } ?? jobs.count
        return await withCheckedContinuation { continuation in
            waiters.append((ObjectIdentifier(job), order, disk, continuation))
        }
    }

    func releaseDisk(_ disk: dev_t, for job: TransferJob) {
        guard busyDisks[disk] == ObjectIdentifier(job) else { return }
        busyDisks[disk] = nil
        // First come, first served: the job enqueued earliest goes next.
        let candidates = waiters.indices.filter { waiters[$0].disk == disk }
        if let next = candidates.min(by: { waiters[$0].order < waiters[$1].order }) {
            let waiter = waiters.remove(at: next)
            busyDisks[disk] = waiter.job
            waiter.continuation.resume(returning: true)
        }
    }

    func stopWaiting(_ job: TransferJob) {
        let id = ObjectIdentifier(job)
        let stopped = waiters.filter { $0.job == id }
        waiters.removeAll { $0.job == id }
        stopped.forEach { $0.continuation.resume(returning: false) }
    }

    // MARK: - Updates

    /// Coalesces bursts of changes into one notification per run loop pass.
    private func notify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.notifyNow() }
        }
    }

    private func notifyNow() {
        notifyScheduled = false
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        onChange?()
    }

    private func startTicking() {
        guard ticker == nil, hasActiveJobs else { return }
        ticker = Task { [weak self] in
            while let self, self.hasActiveJobs {
                let now = ProcessInfo.processInfo.systemUptime
                for job in self.jobs where job.state.isActive { job.sample(now) }
                self.notifyNow()
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.ticker = nil
            self?.notifyNow()
        }
    }
}

/// Undo for finished transfers, with the same semantics as `FileOps`: undoing a copy moves the copies to the Trash
/// (which registers its own redo); undoing a move moves the items back. Items a job replaced come back out of the Trash.
enum TransferUndo {
    /// `containers`: folders made for the moved items (Put Back recreating a removed folder); undo removes them once
    /// they're empty again.
    static func register(created: [URL], moved: [TransferMove], replaced: [TransferMove], actionName: String,
                         undo: UndoManager?, logHistory: Bool = true, containers: [URL] = []) {
        let entry = logHistory
            ? OperationLog.shared.recordTransfer(actionName, created: created, moved: moved.map { (from: $0.from, to: $0.to) },
                                                 replaced: replaced.map { (from: $0.from, to: $0.to) }, containers: containers)
            : nil
        guard let undo, !(created.isEmpty && moved.isEmpty && replaced.isEmpty) else { return }
        if let entry { FileOps.registerLogMark(entry, undone: true, undo) }
        undo.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated {
                let existing = created.filter { TransferEngine.exists($0) }
                if !existing.isEmpty { _ = try? FileOps.trash(existing, undo: undo, record: false) }
                // Moved items go back first, then whatever they replaced comes out of the Trash into the freed spots.
                let back = moved.reversed().map(\.reversed) + replaced.reversed().map(\.reversed)
                perform(back, actionName: actionName, undo: undo)
                for folder in containers.reversed() {
                    // Only what is (still) empty: never remove something put there since.
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
                    if contents.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: folder) }
                }
                undo.setActionName(actionName)
            }
        }
        undo.setActionName(actionName)
    }

    /// Moves items and registers the inverse right away, so redo works even when the moves themselves take a while.
    /// Same-disk moves are instant renames done here; anything crossing disks becomes a queued job with progress.
    static func perform(_ moves: [TransferMove], actionName: String, undo: UndoManager?) {
        guard !moves.isEmpty else { return }
        let sameDisk = moves.allSatisfy {
            TransferEngine.device($0.from) == TransferEngine.device($0.to.deletingLastPathComponent())
        }
        var done = moves
        if sameDisk {
            done = []
            for move in moves {
                // A redo may go back into a folder its undo removed (one Put Back made): make it again.
                let parent = move.to.deletingLastPathComponent()
                if !TransferEngine.exists(parent) { try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
                let target = TransferEngine.exists(move.to) ? FileOps.available(move.to, copyStyle: false) : move.to
                if TransferEngine.rename(move.from, to: target) == 0 { done.append(TransferMove(from: move.from, to: target)) }
            }
            for folder in Set(done.flatMap { [$0.from, $0.to] }.map { $0.deletingLastPathComponent() }) {
                FolderSizer.invalidate(folder)
            }
        } else {
            // Part of an undo or redo: History already has the operation.
            let job = TransferQueue.shared.enqueue(moves: moves, mode: .move, undo: nil, conflicts: .keepBoth,
                                                   logHistory: false)
            guard let undo else { return }
            // Clashes may rename items on the way, so the inverse uses where they actually landed.
            undo.registerUndo(withTarget: undo) { undo in
                MainActor.assumeIsolated {
                    perform(job.completedMoves.reversed().map(\.reversed), actionName: actionName, undo: undo)
                }
            }
            undo.setActionName(actionName)
            return
        }
        guard let undo, !done.isEmpty else { return }
        let inverse = done.reversed().map(\.reversed)
        undo.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated { perform(inverse, actionName: actionName, undo: undo) }
        }
        undo.setActionName(actionName)
    }
}

extension TransferEngine.Options {
    /// Options for transfers the user starts, following Settings (Verify copies).
    static var userDefault: TransferEngine.Options {
        var options = TransferEngine.Options()
        options.verify = Prefs.verifyCopies
        return options
    }
}
