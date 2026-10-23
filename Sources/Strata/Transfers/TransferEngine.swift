import CryptoKit
import Foundation

/// Pause and cancel switches shared by a job (main actor) and the thread doing its work.
nonisolated final class TransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    var isCancelled: Bool { condition.withLock { cancelled } }
    var isPaused: Bool { condition.withLock { paused && !cancelled } }

    func pause() { condition.withLock { paused = true } }

    func resume() {
        condition.withLock {
            paused = false
            condition.broadcast()
        }
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    /// Blocks while paused. Returns false once the job is cancelled.
    func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return !cancelled
    }
}

/// Counters the worker bumps as it goes; the job samples them a few times a second.
nonisolated final class TransferProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        var bytes: Int64 = 0
        var files = 0
        var verifiedBytes: Int64 = 0
        var currentName: String?
        var isVerifying = false
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot { lock.withLock { value } }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.withLock { body(&value) }
    }

    func reset() {
        lock.withLock { value = Snapshot() }
    }
}

/// Runs blocking file work on its own serial queue, off the cooperative pool, so a paused or slow copy never
/// starves Swift concurrency.
nonisolated final class TransferWorker: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// One top-level item of a job, as planned on the main actor and carried out by `TransferEngine.perform`.
nonisolated struct TransferItem: Sendable {
    enum Operation: Sendable {
        /// Same-volume move: one `rename(2)`.
        case rename
        /// `copyfile(3)`, cloning when the volume allows it.
        case copy
        /// Cross-volume move: copy, verify if asked, then remove the original.
        case copyThenDelete
    }

    enum Outcome: Sendable {
        case pending, done, partial, failed, skipped, cancelled
    }

    let source: URL
    /// Where it goes. For "keep both" and same-folder copies the final name is picked right before writing.
    var destination: URL
    var operation: Operation
    var decision: ConflictDecision?
    /// Same-folder copy: name it like Finder's duplicates ("name copy.ext").
    var copyStyleName = false
    var bytes: Int64 = 0
    var files = 1
    var outcome: Outcome = .pending
}

/// What `perform` did to one item.
nonisolated struct TransferItemResult: Sendable {
    var outcome: TransferItem.Outcome
    var destination: URL
    var failures: [TransferFailure] = []
    /// The item it replaced, now in the Trash.
    var replaced: TransferMove?
    /// Captured before moving the replaced item into the Trash, never inferred at the later worker handoff.
    var replacedIdentity: FileIdentity?
    /// The original is gone (move finished).
    var sourceRemoved = false
    /// What the item is where it landed (see `LandedFiles`), read as it was put there: for undo.
    var landed: FileIdentity?
}

/// The blocking work behind transfers. Everything here runs on a job's worker queue.
nonisolated enum TransferEngine {
    struct Options: Sendable {
        var verify = false
        /// APFS clones when source and destination share a volume. Tests turn it off to get real byte copies.
        var clone = true
    }

    /// Test-only knobs: throttle data copies and tamper with a copy before it's verified.
    struct Hooks: Sendable {
        var throttleBytesPerSecond: Int64?
        var beforeVerify: (@Sendable (URL) -> Void)?
        /// Report a controlled failure after copyfile finishes an entry, while its descriptor is still available.
        var copyFailure: (@Sendable (URL) -> Int32?)?
        /// Called with an item's place the moment it has landed there and been recorded (for undo), before anything
        /// else happens to it: a test swaps the file right then.
        var afterLanding: (@Sendable (URL) -> Void)?
        /// The worker has finished, before its result is applied on the main actor.
        var afterResult: (@Sendable (TransferItemResult) -> Void)?
    }

    private static let hooksLock = NSLock()
    nonisolated(unsafe) private static var storedHooks = Hooks()

    // Workers read snapshots while tests configure hooks. Keep field updates atomic too; callbacks run after
    // the getter has released the lock, so they may safely update the configuration themselves.
    static var hooks: Hooks {
        get { hooksLock.withLock { storedHooks } }
        set { hooksLock.withLock { storedHooks = newValue } }
        _modify {
            hooksLock.lock()
            defer { hooksLock.unlock() }
            yield &storedHooks
        }
    }

    // MARK: - Items

    /// Carries out one planned item: rename, or copy (+ verify) (+ remove the original), with "replace" done
    /// safely by copying under a temporary name and only then swapping the old item into the Trash.
    static func perform(_ index: Int, _ item: TransferItem, options: Options, control: TransferControl,
                        progress: TransferProgress) -> TransferItemResult {
        let replacing = item.decision == .replace
        var result = TransferItemResult(outcome: .failed, destination: item.destination)
        defer { hooks.afterResult?(result) }
        guard control.checkpoint() else { result.outcome = .cancelled; return result }
        progress.update { $0.currentName = item.source.lastPathComponent }

        func fail(_ message: String, stage: TransferFailure.Stage = .item) -> TransferItemResult {
            result.failures.append(TransferFailure(item: index, stage: stage, source: item.source,
                                                   destination: item.destination, message: message))
            result.outcome = .failed
            return result
        }

        var operation = item.operation
        if operation == .rename {
            var trashed: URL?
            if replacing {
                result.replacedIdentity = FileIdentity.read(item.destination.path)
                do { trashed = try trash(item.destination) } catch { return fail(trashMessage(item.destination, error)) }
            }
            // A rename keeps what the item is.
            let identity = FileIdentity.read(item.source.path)
            let code = rename(item.source, to: item.destination)
            if code == 0 {
                result.landed = identity
                hooks.afterLanding?(item.destination)
                if let trashed { result.replaced = TransferMove(from: item.destination, to: trashed) }
                progress.update {
                    $0.files += item.files
                    $0.bytes += item.bytes
                }
                result.outcome = .done
                result.sourceRemoved = true
                return result
            }
            if let trashed { _ = rename(trashed, to: item.destination) }
            guard code == EXDEV, !replacing else { return fail(describe(code)) }
            operation = .copyThenDelete
        }

        // Copy into place, or next to it under a hidden temporary name when replacing.
        let sourceParent = TransferRetryTarget.directoryIdentity(item.source.deletingLastPathComponent())
        let target = replacing ? temporaryURL(for: item.destination) : item.destination
        let copy = copy(item.source, to: target, clone: options.clone, control: control, progress: progress)
        if copy.cancelled {
            removeIfPresent(target, in: target, created: copy.created)
            result.outcome = .cancelled
            return result
        }
        if let fatal = copy.fatal {
            if !copy.destinationExisted { removeIfPresent(target, in: target, created: copy.created) }
            return fail(fatal)
        }
        if copy.cloned {
            progress.update {
                $0.files += item.files
                $0.bytes += item.bytes
            }
        }
        result.landed = copy.created[target.path] ?? FileIdentity.read(target.path)
        hooks.afterLanding?(target)
        var failures = copy.errors.map { error in
            let errorURL = URL(fileURLWithPath: error.destination)
            return TransferFailure(item: index, stage: .copy, source: URL(fileURLWithPath: error.source),
                                   destination: replacing ? nil : errorURL, message: error.message,
                                   retryTarget: TransferRetryTarget(errorURL, identity: error.identity,
                                                                    root: target, created: copy.created,
                                                                    source: item.source, sourceIdentities: copy.sourceIdentities))
        }

        if options.verify {
            hooks.beforeVerify?(target)
            let skip = Set(copy.errors.map(\.source))
            let check = verify(item.source, against: target, created: copy.created, skipping: skip,
                               control: control, progress: progress)
            if check.cancelled {
                removeIfPresent(target, in: target, created: copy.created)
                result.outcome = .cancelled
                return result
            }
            for mismatch in check.mismatches {
                // A bad copy is worse than none: drop it so a retry starts clean.
                let mismatchURL = URL(fileURLWithPath: mismatch.destination)
                removeIfPresent(mismatchURL, in: target, created: copy.created)
                let remaining = FileIdentity.read(mismatch.destination) == mismatch.identity ? mismatch.identity : nil
                failures.append(TransferFailure(item: index, stage: .verify, source: URL(fileURLWithPath: mismatch.source),
                                                destination: replacing ? nil : mismatchURL,
                                                message: mismatch.message,
                                                retryTarget: TransferRetryTarget(mismatchURL, identity: remaining,
                                                                                 root: target, created: copy.created,
                                                                                 source: item.source, sourceIdentities: copy.sourceIdentities)))
            }
        }

        if replacing {
            // Never swap a complete existing item for an incomplete one.
            guard failures.isEmpty else {
                removeIfPresent(target, in: target, created: copy.created)
                result.failures = failures.map {
                    TransferFailure(item: index, stage: .item, source: item.source, destination: item.destination,
                                    message: "\($0.displayName): \($0.message)")
                }
                return result
            }
            let trashed: URL
            result.replacedIdentity = FileIdentity.read(item.destination.path)
            do { trashed = try trash(item.destination) } catch {
                removeIfPresent(target, in: target, created: copy.created)
                return fail(trashMessage(item.destination, error))
            }
            let code = rename(target, to: item.destination)
            guard code == 0 else {
                _ = rename(trashed, to: item.destination)
                removeIfPresent(target, in: target, created: copy.created)
                return fail(describe(code))
            }
            result.replaced = TransferMove(from: item.destination, to: trashed)
        }

        guard failures.isEmpty else {
            result.failures = failures
            result.outcome = .partial
            return result
        }
        if operation == .copyThenDelete {
            let removeRetry = TransferRetryTarget(item.destination, identity: result.landed, root: item.destination,
                                                  created: copy.created, source: item.source,
                                                  sourceIdentities: copy.sourceIdentities)
            // Anything saved into the original while it was being copied isn't in the copy: keep the original then.
            if let change = changedSinceCopy(item.source, copy: item.destination) {
                let message = String(localized: "Copied, but the original was kept because it changed during the move (\(change))")
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                result.outcome = .partial
                return result
            }
            if let message = removeSource(item.source, destination: item.destination, landed: result.landed,
                                          sourceParent: sourceParent, sourceIdentities: copy.sourceIdentities) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                result.outcome = .partial
                return result
            }
            result.sourceRemoved = true
        }
        result.outcome = .done
        return result
    }

    /// Second attempt at the parts of an item that failed: individual files and folders, or removing the original.
    static func retry(_ index: Int, _ item: TransferItem, landed: FileIdentity?, failures: [TransferFailure], options: Options,
                      control: TransferControl, progress: TransferProgress) -> TransferItemResult {
        var result = TransferItemResult(outcome: .done, destination: item.destination, landed: landed)
        defer { hooks.afterResult?(result) }
        var latestSourceParent = failures.lazy.compactMap { $0.retryTarget?.sourceParent }.first
        var latestSourceIdentities = failures.lazy.compactMap { $0.retryTarget?.sourceIdentities }.first { !$0.isEmpty } ?? [:]
        for failure in retryFailures(failures) {
            guard control.checkpoint() else { result.outcome = .cancelled; return result }
            guard let destination = failure.destination else { continue }
            progress.update { $0.currentName = failure.source.lastPathComponent }
            let sameRoot = destination == item.destination || (landed != nil && FileIdentity.read(item.destination.path) == landed)
            guard sameRoot, let retryTarget = failure.retryTarget, retryTarget.matches(destination) else {
                result.failures.append(TransferFailure(item: index, stage: failure.stage, source: failure.source,
                    destination: destination, message: String(localized: "The items have moved or been changed since."),
                    retryTarget: failure.retryTarget))
                continue
            }
            guard retryTarget.matchesSource(failure.source) else {
                result.failures.append(TransferFailure(item: index, stage: failure.stage, source: failure.source,
                    destination: destination, message: String(localized: "The items have moved or been changed since."),
                    retryTarget: failure.retryTarget))
                continue
            }
            let owned = retryTarget.createdIdentities(for: destination, root: item.destination, rootIdentity: result.landed)
            var dstInfo = stat()
            let keepingDirectory = lstat(destination.path, &dstInfo) == 0 && (dstInfo.st_mode & S_IFMT == S_IFDIR)
            if !keepingDirectory {
                removeIfPresent(destination, in: item.destination, created: owned)
            }
            let copy = copy(failure.source, to: destination, replacingOwned: keepingDirectory ? owned : nil,
                            clone: options.clone, control: control, progress: progress)
            var mergedCreated = owned
            for (path, id) in copy.created { mergedCreated[path] = id }
            if copy.cancelled {
                removeIfPresent(destination, in: item.destination, created: mergedCreated, keepRootDirectory: keepingDirectory)
                result.outcome = .cancelled
                return result
            }
            if let fatal = copy.fatal {
                result.failures.append(TransferFailure(item: index, stage: .copy, source: failure.source,
                                                       destination: destination, message: fatal, retryTarget: failure.retryTarget))
                continue
            }
            for (path, id) in copy.sourceIdentities { latestSourceIdentities[path] = id }
            if latestSourceParent == nil {
                latestSourceParent = TransferRetryTarget.directoryIdentity(item.source.deletingLastPathComponent())
            }
            // Recreating a top-level file gives it a new identity. Repairing a child keeps the original folder's
            // ownership; never adopt whichever folder happens to occupy that path after the retry.
            if destination == item.destination { result.landed = copy.created[destination.path] ?? FileIdentity.read(destination.path) }
            hooks.afterLanding?(destination)
            result.failures += copy.errors.map {
                let errorURL = URL(fileURLWithPath: $0.destination)
                return TransferFailure(item: index, stage: .copy, source: URL(fileURLWithPath: $0.source),
                                       destination: errorURL, message: $0.message,
                                       retryTarget: TransferRetryTarget(errorURL, identity: $0.identity,
                                                                        root: item.destination, created: mergedCreated,
                                                                        source: item.source, sourceIdentities: latestSourceIdentities))
            }
            if options.verify {
                hooks.beforeVerify?(destination)
                let check = verify(failure.source, against: destination, created: copy.created,
                                   skipping: Set(copy.errors.map(\.source)), control: control, progress: progress)
                if check.cancelled {
                    removeIfPresent(destination, in: item.destination, created: mergedCreated, keepRootDirectory: keepingDirectory)
                    result.outcome = .cancelled
                    return result
                }
                for mismatch in check.mismatches {
                    let mismatchURL = URL(fileURLWithPath: mismatch.destination)
                    removeIfPresent(mismatchURL, in: item.destination, created: mergedCreated)
                    let remaining = FileIdentity.read(mismatch.destination) == mismatch.identity ? mismatch.identity : nil
                    result.failures.append(TransferFailure(item: index, stage: .verify,
                                                           source: URL(fileURLWithPath: mismatch.source),
                                                           destination: mismatchURL,
                                                           message: mismatch.message,
                                                           retryTarget: TransferRetryTarget(mismatchURL, identity: remaining,
                                                                                            root: item.destination, created: mergedCreated,
                                                                                            source: item.source, sourceIdentities: latestSourceIdentities)))
                }
            }
        }
        guard result.failures.isEmpty else { result.outcome = .partial; return result }
        if item.operation != .copy {
            let removeRetry = failures.lazy.compactMap(\.retryTarget).first
            if (result.landed != nil && FileIdentity.read(item.destination.path) != result.landed)
                || (removeRetry != nil && removeRetry?.matchesSource(item.source) == false) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination,
                                                       message: String(localized: "The items have moved or been changed since."),
                                                       retryTarget: removeRetry))
                result.outcome = .partial
                return result
            }
            // The original may hold edits the copy lacks (that's why it was kept): never delete it then.
            if let change = changedSinceCopy(item.source, copy: item.destination) {
                let message = String(localized: "The original was kept because it changed during the move (\(change)). Move it again to copy the changes.")
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                result.outcome = .partial
                return result
            }
            if let message = removeSource(item.source, destination: item.destination, landed: result.landed,
                                          sourceParent: latestSourceParent, sourceIdentities: latestSourceIdentities) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message,
                                                       retryTarget: removeRetry))
                result.outcome = .partial
                return result
            }
            result.sourceRemoved = true
        }
        return result
    }

    /// A failed folder's retry includes its descendants. Retrying them separately could remove files the parent
    /// has just repaired, and descendants may not have had a destination parent to record on the first attempt.
    static func retryFailures(_ failures: [TransferFailure]) -> [TransferFailure] {
        let candidates = failures.filter { ($0.stage == .copy || $0.stage == .verify) && $0.destination != nil }
        let destinations = Dictionary(candidates.compactMap { failure in
            failure.destination.map { (failure.source.path, $0.path) }
        }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return candidates.filter { failure in
            guard let destination = failure.destination,
                  seen.insert(failure.source.path + "\0" + destination.path).inserted else { return false }
            var parent = failure.source.deletingLastPathComponent()
            while parent.path != failure.source.path {
                if let target = destinations[parent.path] {
                    let relative = String(failure.source.path.dropFirst(parent.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if (target as NSString).appendingPathComponent(relative) == destination.path { return false }
                }
                let next = parent.deletingLastPathComponent()
                if next.path == parent.path { break }
                parent = next
            }
            return true
        }
    }

    // MARK: - Scanning

    /// Files and bytes under `url` (one cheap walk, no xattrs), or nil when cancelled.
    static func scan(_ url: URL, control: TransferControl) -> FolderSize? {
        FolderSizer.measure(url.path) { control.isCancelled }
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_dev : nil
    }

    // MARK: - Copying

    struct EntryError: Sendable {
        let source: String
        let destination: String
        let message: String
        var identity: FileIdentity?
    }

    struct CopyOutcome: Sendable {
        var errors: [EntryError] = []
        var cancelled = false
        /// Nothing could be copied at all.
        var fatal: String?
        /// The copy was refused because something already sits at the destination: that item isn't ours to remove.
        var destinationExisted = false
        /// Made as one APFS clone of the whole item (no per-file progress was reported).
        var cloned = false
        var created: [String: FileIdentity] = [:]
        var sourceIdentities: [String: FileIdentity] = [:]
    }

    /// Recursive `copyfile(3)` with every piece of metadata, APFS clones where possible, per-file progress, and
    /// pause/cancel at block granularity. Files that fail are recorded and skipped; copyfile removes their partial data.
    static func copy(_ source: URL, to destination: URL, replacingOwned: [String: FileIdentity]? = nil,
                     clone: Bool, control: TransferControl, progress: TransferProgress) -> CopyOutcome {
        if let owned = replacingOwned {
            return copyfile(source, to: destination, replacingOwned: owned, clone: clone, control: control, progress: progress)
        }
        guard !exists(destination) else {
            // copyfile would copy *into* an existing folder; the planner guarantees this never happens.
            return CopyOutcome(fatal: describe(EEXIST), destinationExisted: true)
        }
        let start = progress.snapshot
        let first = copyfile(source, to: destination, clone: clone, control: control, progress: progress)
        // copyfile's per-file cloning keeps every ACL and xattr, but fails inside folders without write permission
        // (it clones a read-only folder before filling it). For a folder that hit errors, start over with one clone of
        // the whole tree, then with a plain copy, which both cope with that.
        var isDirectory: ObjCBool = false
        guard clone, !first.errors.isEmpty, !first.cancelled, first.fatal == nil,
              FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              canRestart(destination, created: first.created)
        else { return first }
        removeIfPresent(destination, in: destination, created: first.created)   // Ours: COPYFILE_EXCL guaranteed nothing was there.
        guard !exists(destination) else { return first }
        progress.update {
            $0.files = start.files
            $0.bytes = start.bytes
        }
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW | CLONE_ACL)) == 0 {
            return CopyOutcome(cloned: true, created: snapshotIdentities(destination),
                               sourceIdentities: snapshotIdentities(source))
        }
        if errno == EEXIST { return CopyOutcome(fatal: describe(EEXIST), destinationExisted: true) }
        return copyfile(source, to: destination, clone: false, control: control, progress: progress)
    }

    private static func canRestart(_ destination: URL, created: [String: FileIdentity]) -> Bool {
        let current = snapshotIdentities(destination)
        guard !current.isEmpty else { return true }
        return current.allSatisfy { created[$0.key] == $0.value }
    }

    private static func canRepair(_ source: URL, into destination: URL, owned: [String: FileIdentity]) -> Bool {
        var srcRoot = stat(), dstRoot = stat()
        guard lstat(source.path, &srcRoot) == 0, srcRoot.st_mode & S_IFMT == S_IFDIR,
              lstat(destination.path, &dstRoot) == 0, dstRoot.st_mode & S_IFMT == S_IFDIR,
              let expectedRoot = owned[destination.path], FileIdentity.from(dstRoot) == expectedRoot else { return false }
        guard let cpath = strdup(source.path) else { return false }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { return false }
            let srcPath = String(cString: entry.pointee.fts_path)
            let relative = srcPath.count > source.path.count ? String(srcPath.dropFirst(source.path.count)) : ""
            let dstPath = destination.path + relative
            var dstInfo = stat()
            if lstat(dstPath, &dstInfo) == 0 {
                guard let expected = owned[dstPath], FileIdentity.from(dstInfo) == expected else { return false }
                let srcIsDir = info == FTS_D
                let dstIsDir = dstInfo.st_mode & S_IFMT == S_IFDIR
                if srcIsDir != dstIsDir { return false }
            }
        }
        return true
    }

    private static func snapshotIdentities(_ root: URL) -> [String: FileIdentity] {
        var result: [String: FileIdentity] = [:]
        guard let cpath = strdup(root.path) else { return result }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return result }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            if Int32(entry.pointee.fts_info) == FTS_DP { continue }
            let path = String(cString: entry.pointee.fts_path)
            if let id = FileIdentity.read(path) { result[path] = id }
        }
        return result
    }

    /// One recursive `copyfile` pass (see `copy`).
    private static func copyfile(_ source: URL, to destination: URL, replacingOwned: [String: FileIdentity]? = nil,
                                 clone: Bool, control: TransferControl, progress: TransferProgress) -> CopyOutcome {
        if let owned = replacingOwned {
            guard canRepair(source, into: destination, owned: owned) else {
                return CopyOutcome(fatal: String(localized: "The items have moved or been changed since."),
                                   destinationExisted: true)
            }
            var outcome = CopyOutcome()
            guard let cpath = strdup(source.path) else { return CopyOutcome(fatal: describe(ENOMEM)) }
            defer { free(cpath) }
            var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
                return CopyOutcome(fatal: describe(errno))
            }
            defer { fts_close(fts) }
            let hooks = hooks
            var directories: [String: CopySession.DirectoryDescriptor] = [:]
            while let entry = fts_read(fts) {
                guard control.checkpoint() else { outcome.cancelled = true; break }
                let info = Int32(entry.pointee.fts_info)
                let srcPath = String(cString: entry.pointee.fts_path)
                let relative = srcPath.count > source.path.count ? String(srcPath.dropFirst(source.path.count)) : ""
                let dstPath = destination.path + relative
                let srcURL = URL(fileURLWithPath: srcPath), dstURL = URL(fileURLWithPath: dstPath)
                switch info {
                case FTS_D:
                    if let id = FileIdentity.read(srcPath) { outcome.sourceIdentities[srcPath] = id }
                    if exists(dstURL) {
                        guard let expected = owned[dstPath], FileIdentity.read(dstPath) == expected,
                              let descriptor = CopySession.DirectoryDescriptor.openDirectory(dstPath),
                              descriptor.identity == expected else {
                            outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                             message: String(localized: "The items have moved or been changed since."),
                                                             identity: owned[dstPath]))
                            fts_set(fts, entry, FTS_SKIP)
                            continue
                        }
                        directories[dstPath] = descriptor
                        var dirInfo = stat()
                        if fstat(descriptor.fd, &dirInfo) == 0, (dirInfo.st_mode & S_IRWXU) != S_IRWXU {
                            _ = fchmod(descriptor.fd, (dirInfo.st_mode & 0o7777) | S_IRWXU)
                        }
                        outcome.created[dstPath] = expected
                    } else {
                        guard mkdir(dstPath, 0o700) == 0 else {
                            outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                             message: describe(errno), identity: nil))
                            fts_set(fts, entry, FTS_SKIP)
                            continue
                        }
                        let descriptor = CopySession.DirectoryDescriptor.openDirectory(dstPath)
                        directories[dstPath] = descriptor
                        if let id = descriptor?.identity ?? FileIdentity.read(dstPath) { outcome.created[dstPath] = id }
                    }
                case FTS_DP:
                    let descriptor = directories.removeValue(forKey: dstPath)
                    if let expected = descriptor?.identity, FileIdentity.read(dstPath) == expected {
                        _ = Darwin.copyfile(srcPath, dstPath, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
                    }
                    if let id = descriptor?.identity { outcome.created[dstPath] = id }
                    if let code = hooks.copyFailure?(dstURL) {
                        outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                         message: describe(code), identity: outcome.created[dstPath]))
                    }
                case FTS_F, FTS_SL, FTS_SLNONE:
                    if exists(dstURL) {
                        removeIfPresent(dstURL, in: destination, created: owned.merging(outcome.created) { _, new in new })
                        if exists(dstURL) {
                            outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                             message: String(localized: "The items have moved or been changed since."),
                                                             identity: owned[dstPath]))
                            continue
                        }
                    }
                    let single = copyfile(srcURL, to: dstURL, clone: clone, control: control, progress: progress)
                    for (path, id) in single.created { outcome.created[path] = id }
                    for (path, id) in single.sourceIdentities { outcome.sourceIdentities[path] = id }
                    outcome.errors += single.errors
                    if single.cancelled { outcome.cancelled = true; return outcome }
                    if let fatal = single.fatal {
                        outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                         message: fatal, identity: single.created[dstPath]))
                    }
                case FTS_DNR, FTS_ERR, FTS_NS:
                    outcome.errors.append(EntryError(source: srcPath, destination: dstPath,
                                                     message: describe(entry.pointee.fts_errno), identity: owned[dstPath]))
                default:
                    break
                }
            }
            return outcome
        }

        let hooks = hooks
        let session = CopySession(control: control, progress: progress, throttle: hooks.throttleBytesPerSecond,
                                  copyFailure: hooks.copyFailure)
        if let id = FileIdentity.read(source.path) { session.sourceIdentities[source.path] = id }
        guard let state = copyfile_state_alloc() else { return CopyOutcome(fatal: describe(ENOMEM)) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = copyCallback
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(session).toOpaque())
        var flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL
        if clone { flags |= COPYFILE_CLONE }
        let status = Darwin.copyfile(source.path, destination.path, state, copyfile_flags_t(flags))
        let code = errno
        withExtendedLifetime(session) {}

        var outcome = CopyOutcome(errors: session.errors, created: session.created,
                                  sourceIdentities: session.sourceIdentities)
        if session.quit || control.isCancelled {
            outcome.cancelled = true
        } else if status != 0, session.errors.isEmpty {
            outcome.fatal = describe(code)
            // Something appeared at the destination meanwhile (COPYFILE_EXCL refused): leave it alone.
            outcome.destinationExisted = code == EEXIST
        } else if !exists(destination), session.errors.contains(where: { $0.source == source.path }) {
            // The top-level item itself failed (unreadable file, folder that can't be listed…).
            outcome.fatal = session.errors.first { $0.source == source.path }?.message
            outcome.errors.removeAll { $0.source == source.path }
        }
        if !outcome.destinationExisted {
            let failedDestinations = Set(session.errors.map(\.destination))
            for (path, id) in snapshotIdentities(destination) where outcome.created[path] == nil && !failedDestinations.contains(path) {
                outcome.created[path] = id
            }
            for (path, id) in snapshotIdentities(source) where outcome.sourceIdentities[path] == nil {
                outcome.sourceIdentities[path] = id
            }
        }
        return outcome
    }

    private static let copyCallback: copyfile_callback_t = { what, stage, state, source, destination, context in
        let code = errno
        guard let context else { return Int32(COPYFILE_CONTINUE) }
        let session = Unmanaged<CopySession>.fromOpaque(context).takeUnretainedValue()
        return session.handle(what: what, stage: stage, state: state, source: source, destination: destination, code: code)
    }

    // MARK: - Verifying

    struct VerifyOutcome: Sendable {
        var mismatches: [EntryError] = []
        var cancelled = false
    }

    /// SHA-256 of every regular file under `source` against its counterpart under `destination`, streamed in 1 MB
    /// chunks; symlinks must point at the same place. Paths in `skipping` (already failed) are left out.
    static func verify(_ source: URL, against destination: URL, created: [String: FileIdentity] = [:],
                       skipping: Set<String> = [], control: TransferControl,
                       progress: TransferProgress) -> VerifyOutcome {
        progress.update { $0.isVerifying = true }
        defer { progress.update { $0.isVerifying = false } }
        var outcome = VerifyOutcome()
        let root = source.path
        guard let cpath = strdup(root) else { return outcome }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return outcome }
        defer { fts_close(fts) }
        let buffers = (UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16),
                       UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16))
        defer {
            buffers.0.deallocate()
            buffers.1.deallocate()
        }
        while let entry = fts_read(fts) {
            let path = String(cString: entry.pointee.fts_path)
            if skipping.contains(path) {
                if Int32(entry.pointee.fts_info) == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                continue
            }
            let relative = path.count > root.count ? String(path.dropFirst(root.count)) : ""
            let target = destination.path + relative
            let currentIdentity = FileIdentity.read(target)
            let expectedIdentity = created[target]
            let identity = expectedIdentity ?? currentIdentity
            if let expectedIdentity, currentIdentity != expectedIdentity {
                if Int32(entry.pointee.fts_info) == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                let message = currentIdentity == nil
                    ? String(localized: "The copy can’t be read back")
                    : String(localized: "The copy doesn’t match the original")
                outcome.mismatches.append(EntryError(source: path, destination: target, message: message, identity: identity))
                continue
            }
            switch Int32(entry.pointee.fts_info) {
            case FTS_F:
                progress.update { $0.currentName = (path as NSString).lastPathComponent }
                let original = sha256(path, buffer: buffers.0, control: control) { n in
                    progress.update { $0.verifiedBytes += Int64(n) }
                }
                if control.isCancelled { outcome.cancelled = true; return outcome }
                let copy = sha256(target, expected: expectedIdentity, buffer: buffers.1, control: control) { _ in }
                if control.isCancelled { outcome.cancelled = true; return outcome }
                if original == nil || copy == nil || original != copy {
                    let reason = copy == nil ? String(localized: "The copy can’t be read back")
                        : String(localized: "The copy doesn’t match the original")
                    outcome.mismatches.append(EntryError(source: path, destination: target,
                                                         message: original == nil ? String(localized: "The original can’t be read") : reason,
                                                         identity: identity))
                }
            case FTS_SL, FTS_SLNONE:
                if readLink(path) != readLink(target) || (expectedIdentity != nil && FileIdentity.read(target) != expectedIdentity) {
                    outcome.mismatches.append(EntryError(source: path, destination: target,
                                                         message: String(localized: "The copied alias points somewhere else"), identity: identity))
                }
            default:
                break
            }
        }
        return outcome
    }

    static func sha256(_ path: String, expected: FileIdentity? = nil, buffer: UnsafeMutableRawBufferPointer,
                       control: TransferControl, onRead: (Int) -> Void) -> SHA256.Digest? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if let expected {
            var info = stat()
            guard fstat(fd, &info) == 0, FileIdentity.from(info) == expected else { return nil }
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        while true {
            guard control.checkpoint() else { return nil }
            let n = read(fd, buffer.baseAddress, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            onRead(n)
        }
        return hasher.finalize()
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Small operations

    /// `rename(2)` that refuses to overwrite. Returns 0 or an errno.
    static func rename(_ source: URL, to destination: URL) -> Int32 {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { return code }
        // File systems without RENAME_EXCL: check, then rename.
        if exists(destination) { return EEXIST }
        return Darwin.rename(source.path, destination.path) == 0 ? 0 : errno
    }

    static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    static func removeIfPresent(_ url: URL, in root: URL? = nil, created: [String: FileIdentity]? = nil,
                                keepRootDirectory: Bool = false) {
        guard let created else {
            guard exists(url) else { return }
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard !created.isEmpty else { return }
        let base = root ?? url
        let baseParent = base.deletingLastPathComponent().path
        var dirFD = open(baseParent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { return }
        if url.path != base.path {
            let prefix = base.path == "/" ? "/" : base.path + "/"
            guard url.path.hasPrefix(prefix) else {
                close(dirFD)
                return
            }
            let relativeParent = String(url.deletingLastPathComponent().path.dropFirst(baseParent.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var currentPath = baseParent
            for component in relativeParent.split(separator: "/").map(String.init) {
                currentPath = (currentPath as NSString).appendingPathComponent(component)
                guard let expected = created[currentPath] else {
                    close(dirFD)
                    return
                }
                let nextFD = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                close(dirFD)
                guard nextFD >= 0 else { return }
                var info = stat()
                guard fstat(nextFD, &info) == 0, FileIdentity.from(info) == expected else {
                    close(nextFD)
                    return
                }
                dirFD = nextFD
            }
        }
        let targetName = url.lastPathComponent
        let targetPath = url.path
        guard let expectedTarget = created[targetPath] else {
            close(dirFD)
            return
        }
        var targetInfo = stat()
        guard fstatat(dirFD, targetName, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity.from(targetInfo) == expectedTarget else {
            close(dirFD)
            return
        }
        if targetInfo.st_mode & S_IFMT != S_IFDIR {
            if !keepRootDirectory { _ = unlinkat(dirFD, targetName, 0) }
            close(dirFD)
            return
        }
        let rootDirFD = openat(dirFD, targetName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDirFD >= 0 else {
            close(dirFD)
            return
        }
        var openedInfo = stat()
        guard fstat(rootDirFD, &openedInfo) == 0, FileIdentity.from(openedInfo) == expectedTarget else {
            close(rootDirFD)
            close(dirFD)
            return
        }
        var stack: [(parentFD: Int32, fd: Int32, name: String, path: String, expanded: Bool, keep: Bool)] = [
            (parentFD: dirFD, fd: rootDirFD, name: targetName, path: targetPath, expanded: false, keep: keepRootDirectory)
        ]
        while let frame = stack.popLast() {
            if !frame.expanded {
                let currentFD: Int32
                if frame.fd >= 0 {
                    currentFD = frame.fd
                } else {
                    let opened = openat(frame.parentFD, frame.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { continue }
                    var openedChild = stat()
                    guard let expectedChild = created[frame.path],
                          fstat(opened, &openedChild) == 0, FileIdentity.from(openedChild) == expectedChild else {
                        close(opened)
                        continue
                    }
                    currentFD = opened
                }
                var dirInfo = stat()
                if !frame.keep, fstat(currentFD, &dirInfo) == 0, (dirInfo.st_mode & S_IRWXU) != S_IRWXU {
                    _ = fchmod(currentFD, (dirInfo.st_mode & 0o7777) | S_IRWXU)
                }
                stack.append((parentFD: frame.parentFD, fd: currentFD, name: frame.name,
                              path: frame.path, expanded: true, keep: frame.keep))
                let frame = (parentFD: frame.parentFD, fd: currentFD, name: frame.name, path: frame.path, expanded: false, keep: frame.keep)
                for childName in Archiver.entries(frame.fd) {
                    let childPath = (frame.path as NSString).appendingPathComponent(childName)
                    guard let expectedChild = created[childPath] else { continue }
                    var childInfo = stat()
                    guard fstatat(frame.fd, childName, &childInfo, AT_SYMLINK_NOFOLLOW) == 0,
                          FileIdentity.from(childInfo) == expectedChild else { continue }
                    if childInfo.st_mode & S_IFMT == S_IFDIR {
                        stack.append((parentFD: frame.fd, fd: -1, name: childName,
                                      path: childPath, expanded: false, keep: false))
                    } else {
                        _ = unlinkat(frame.fd, childName, 0)
                    }
                }
            } else {
                close(frame.fd)
                if !frame.keep { _ = unlinkat(frame.parentFD, frame.name, AT_REMOVEDIR) }
                if frame.parentFD == dirFD { close(dirFD) }
            }
        }
    }

    /// The first difference between `source` and its copy (an item added, or a file whose size or modification date
    /// changed after it was copied), or nil when the copy has everything the original has.
    static func changedSinceCopy(_ source: URL, copy: URL) -> String? {
        let root = source.path
        let unchecked = String(localized: "it couldn’t be checked", comment: "Why a moved item’s original was kept, in parentheses")
        guard let cpath = strdup(root) else { return unchecked }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return unchecked }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { return unchecked }
            let path = String(cString: entry.pointee.fts_path)
            let relative = path.count > root.count ? String(path.dropFirst(root.count)) : ""
            let name = relative.isEmpty ? source.lastPathComponent : String(relative.dropFirst())
            var original = stat(), copied = stat()
            guard lstat(path, &original) == 0 else { continue }   // Removed meanwhile: nothing to lose.
            guard lstat(copy.path + relative, &copied) == 0,
                   original.st_mode & S_IFMT == copied.st_mode & S_IFMT else {
                return String(localized: "“\(name)” is new", comment: "Why a moved item’s original was kept, in parentheses")
            }
            // An edit after the copy makes the original newer. Some disks keep coarser dates (FAT: 2 seconds, nothing
            // before 1980), so only a clearly newer original, or a different size, counts.
            let (grace, overflow) = copied.st_mtimespec.tv_sec.addingReportingOverflow(2)
            if original.st_mode & S_IFMT == S_IFREG,
               original.st_size != copied.st_size || (!overflow && original.st_mtimespec.tv_sec > grace) {
                return String(localized: "“\(name)” was modified", comment: "Why a moved item’s original was kept, in parentheses")
            }
            if original.st_mode & S_IFMT == S_IFLNK, readLink(path) != readLink(copy.path + relative) {
                return String(localized: "“\(name)” was modified", comment: "Why a moved item’s original was kept, in parentheses")
            }
        }
        return nil
    }

    /// Removes the original after a cross-volume move. Returns an error message, or nil on success.
    private static func removeSource(_ url: URL, destination: URL? = nil, landed: FileIdentity? = nil,
                                     sourceParent: TransferRetryTarget.PathIdentity? = nil,
                                     sourceIdentities: [String: FileIdentity] = [:]) -> String? {
        if let destination, let landed, FileIdentity.read(destination.path) != landed {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        if let sourceParent, FileIdentity.read(sourceParent.path) != sourceParent.identity {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        let owned = sourceIdentities.isEmpty ? snapshotIdentities(url) : sourceIdentities
        guard let rootID = owned[url.path], FileIdentity.read(url.path) == rootID else {
            guard exists(url) else { return nil }
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        for (path, expected) in owned {
            if let current = FileIdentity.read(path), current != expected {
                let reason = describe(EACCES)
                return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
            }
        }
        removeIfPresent(url, in: url, created: owned)
        guard !exists(url) else {
            let reason = describe(EACCES)
            return String(localized: "Copied, but the original couldn’t be removed: \(reason)")
        }
        return nil
    }

    /// A folder that isn't a package (apps and bundles are replaced, never merged into).
    static func isPlainFolder(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    /// One copy a merge needs: `decision` is nil (new item), `.replace` (incoming is newer) or `.keepBoth` (a file
    /// meets a folder).
    struct MergeStep: Sendable {
        let source: URL
        let destination: URL
        let decision: ConflictDecision?
    }

    /// What merging folder `source` into folder `destination` copies: everything missing, subfolders merged in turn,
    /// and same-named items only where the incoming one is newer.
    static func mergePlan(_ source: URL, into destination: URL) -> [MergeStep] {
        var steps: [MergeStep] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []).sorted()
        for name in names where name != ".DS_Store" {
            let from = source.appending(path: name), to = destination.appending(path: name)
            var incoming = stat(), existing = stat()
            guard lstat(from.path, &incoming) == 0 else { continue }
            guard lstat(to.path, &existing) == 0 else {
                steps.append(MergeStep(source: from, destination: to, decision: nil))
                continue
            }
            let bothFolders = isPlainFolder(from) && isPlainFolder(to)
            if bothFolders {
                steps += mergePlan(from, into: to)
            } else if (incoming.st_mode & S_IFMT == S_IFDIR) != (existing.st_mode & S_IFMT == S_IFDIR) {
                steps.append(MergeStep(source: from, destination: to, decision: .keepBoth))
            } else if incoming.st_mtimespec.tv_sec > existing.st_mtimespec.tv_sec {
                steps.append(MergeStep(source: from, destination: to, decision: .replace))
            }
        }
        return steps
    }

    static func temporaryURL(for destination: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        // ".<name>.strata-XXXXXXXX" must stay within the 255-byte name limit.
        let name = fitting(destination.lastPathComponent, maxBytes: 255 - 17)
        return destination.deletingLastPathComponent().appending(path: ".\(name).strata-\(token)")
    }

    /// `name` cut (at a character boundary) to at most `maxBytes` of UTF-8.
    static func fitting(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var result = ""
        for character in name {
            guard result.utf8.count + String(character).utf8.count <= maxBytes else { break }
            result.append(character)
        }
        return result
    }

    static func describe(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: String(localized: "You don’t have permission")
        case ENOENT: String(localized: "The item couldn’t be found")
        case ENOSPC: String(localized: "The disk is full")
        case EEXIST: String(localized: "An item with the same name already exists")
        case EROFS: String(localized: "The disk is read-only")
        case ENAMETOOLONG: String(localized: "The name is too long")
        case EXDEV: String(localized: "It’s on a different disk")
        default: String(cString: strerror(code))
        }
    }

    private static func trashMessage(_ url: URL, _ error: Error) -> String {
        String(localized: "“\(url.lastPathComponent)” couldn’t be moved to the Trash, so it wasn’t replaced")
    }
}

/// State for one `copyfile` call, reached from the C callback through its context pointer.
nonisolated private final class CopySession: @unchecked Sendable {
    let control: TransferControl
    let progress: TransferProgress
    let throttle: Int64?
    var errors: [TransferEngine.EntryError] = []
    var created: [String: FileIdentity] = [:]
    var sourceIdentities: [String: FileIdentity] = [:]
    var quit = false
    private var fileSize: Int64 = 0
    private var fileReported: Int64 = 0
    private var failedPaths: Set<String> = []
    private var directories: [String: DirectoryDescriptor] = [:]
    private let copyFailure: (@Sendable (URL) -> Int32?)?

    init(control: TransferControl, progress: TransferProgress, throttle: Int64?, copyFailure: (@Sendable (URL) -> Int32?)?) {
        self.control = control
        self.progress = progress
        self.throttle = throttle
        self.copyFailure = copyFailure
    }

    func handle(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?,
                destination: UnsafePointer<CChar>?, code: Int32) -> Int32 {
        let quitCode = Int32(COPYFILE_QUIT)
        if quit { return quitCode }

        if let source, stage == COPYFILE_START {
            let src = String(cString: source)
            if sourceIdentities[src] == nil, let id = Self.sourceIdentity(state, path: src) {
                sourceIdentities[src] = id
            }
        }

        if stage == COPYFILE_ERR {
            if code == ECANCELED || control.isCancelled {
                quit = true
                return quitCode
            }
            // Extended attributes the destination won't take (protected or unsupported) don't fail the file.
            if what == COPYFILE_COPY_XATTR { return Int32(COPYFILE_CONTINUE) }
            recordError(what: what, state: state, source: source, destination: destination, code: code)
            if what == COPYFILE_RECURSE_FILE || what == COPYFILE_COPY_DATA {
                finishFile()
            }
            return Int32(COPYFILE_SKIP)
        }

        if what == COPYFILE_RECURSE_DIR && stage == COPYFILE_FINISH, let destination {
            let dst = String(cString: destination)
            let descriptor = DirectoryDescriptor(state)
            directories[dst] = descriptor
            if let id = descriptor?.identity ?? FileIdentity.read(dst) { created[dst] = id }
        }
        if what == COPYFILE_RECURSE_DIR_CLEANUP && stage == COPYFILE_FINISH, let destination {
            let dst = String(cString: destination)
            if let id = directories[dst]?.identity { created[dst] = id }
        }
        if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH, let destination {
            let dst = String(cString: destination)
            if let id = Self.destinationIdentity(state) ?? FileIdentity.read(dst) { created[dst] = id }
        }
        if stage == COPYFILE_FINISH && (what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR_CLEANUP),
           let destination, let code = copyFailure?(URL(fileURLWithPath: String(cString: destination))) {
            recordError(what: what, state: state, source: source, destination: destination, code: code)
        }
        if what == COPYFILE_RECURSE_DIR_CLEANUP && stage == COPYFILE_FINISH, let destination {
            directories.removeValue(forKey: String(cString: destination))
        }

        switch (what, stage) {
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            var info = stat()
            fileSize = source.map { lstat($0, &info) == 0 ? Int64(info.st_size) : 0 } ?? 0
            fileReported = 0
            if let source {
                let name = (String(cString: source) as NSString).lastPathComponent
                progress.update { $0.currentName = name }
            }
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            let delta = Int64(copied) - fileReported
            if delta > 0 {
                fileReported = Int64(copied)
                progress.update { $0.bytes += delta }
                if let throttle, throttle > 0 { usleep(useconds_t(min(Double(delta) / Double(throttle), 2) * 1_000_000)) }
            }
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            finishFile()
        default:
            break
        }
        // Block here while paused; stop at the next block once cancelled.
        if !control.checkpoint() {
            quit = true
            return quitCode
        }
        return Int32(COPYFILE_CONTINUE)
    }

    private func recordError(what: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?,
                             destination: UnsafePointer<CChar>?, code: Int32) {
        let src = source.map { String(cString: $0) } ?? ""
        let dst = destination.map { String(cString: $0) } ?? ""
        // Directory metadata cleanup reopens a pathname, so retain the identity from its exclusive creation instead.
        // The dictionary contains only directories still on copyfile's depth-first traversal stack.
        let identity = what == COPYFILE_RECURSE_DIR_CLEANUP ? directories.removeValue(forKey: dst)?.identity : Self.destinationIdentity(state)
        if let identity { created[dst] = identity }
        if failedPaths.insert(src).inserted {
            errors.append(.init(source: src, destination: dst, message: TransferEngine.describe(code), identity: identity))
        }
    }

    /// Keep the originally opened directory alive through metadata cleanup. copyfile changes its birth time there,
    /// so read the final identity from that descriptor, never from the cleanup pass's reopened pathname.
    final class DirectoryDescriptor {
        fileprivate let fd: Int32

        init?(_ state: copyfile_state_t?) {
            var original: Int32 = -1
            guard let state, copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &original) == 0,
                  original >= 0 else { return nil }
            let duplicate = fcntl(original, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { return nil }
            fd = duplicate
        }

        private init(fd: Int32) {
            self.fd = fd
        }

        static func openDirectory(_ path: String) -> DirectoryDescriptor? {
            let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { return nil }
            return DirectoryDescriptor(fd: opened)
        }

        deinit { close(fd) }

        var identity: FileIdentity? {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            return FileIdentity.from(info)
        }
    }

    private static func destinationIdentity(_ state: copyfile_state_t?) -> FileIdentity? {
        var fd: Int32 = -1, info = stat()
        guard let state, copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &fd) == 0,
              fd >= 0, fstat(fd, &info) == 0 else { return nil }
        return FileIdentity.from(info)
    }

    private static func sourceIdentity(_ state: copyfile_state_t?, path: String) -> FileIdentity? {
        var fd: Int32 = -1, info = stat()
        if let state, copyfile_state_get(state, UInt32(COPYFILE_STATE_SRC_FD), &fd) == 0,
           fd >= 0, fstat(fd, &info) == 0 {
            return FileIdentity.from(info)
        }
        return FileIdentity.read(path)
    }

    private func finishFile() {
        let rest = max(0, fileSize - fileReported)
        fileReported = fileSize
        progress.update {
            $0.bytes += rest
            $0.files += 1
        }
    }
}
