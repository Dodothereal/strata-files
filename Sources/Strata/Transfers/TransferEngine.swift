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
    /// The original is gone (move finished).
    var sourceRemoved = false
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
    }

    nonisolated(unsafe) static var hooks = Hooks()

    // MARK: - Items

    /// Carries out one planned item: rename, or copy (+ verify) (+ remove the original), with "replace" done
    /// safely by copying under a temporary name and only then swapping the old item into the Trash.
    static func perform(_ index: Int, _ item: TransferItem, options: Options, control: TransferControl,
                        progress: TransferProgress) -> TransferItemResult {
        let replacing = item.decision == .replace
        var result = TransferItemResult(outcome: .failed, destination: item.destination)
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
                do { trashed = try trash(item.destination) } catch { return fail(trashMessage(item.destination, error)) }
            }
            let code = rename(item.source, to: item.destination)
            if code == 0 {
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
        let target = replacing ? temporaryURL(for: item.destination) : item.destination
        let copy = copy(item.source, to: target, clone: options.clone, control: control, progress: progress)
        if copy.cancelled {
            removeIfPresent(target)
            result.outcome = .cancelled
            return result
        }
        if let fatal = copy.fatal {
            removeIfPresent(target)
            return fail(fatal)
        }
        var failures = copy.errors.map { error in
            TransferFailure(item: index, stage: .copy, source: URL(fileURLWithPath: error.source),
                            destination: replacing ? nil : URL(fileURLWithPath: error.destination), message: error.message)
        }

        if options.verify {
            hooks.beforeVerify?(target)
            let skip = Set(copy.errors.map(\.source))
            let check = verify(item.source, against: target, skipping: skip, control: control, progress: progress)
            if check.cancelled {
                removeIfPresent(target)
                result.outcome = .cancelled
                return result
            }
            for mismatch in check.mismatches {
                // A bad copy is worse than none: drop it so a retry starts clean.
                removeIfPresent(URL(fileURLWithPath: mismatch.destination))
                failures.append(TransferFailure(item: index, stage: .verify, source: URL(fileURLWithPath: mismatch.source),
                                                destination: replacing ? nil : URL(fileURLWithPath: mismatch.destination),
                                                message: mismatch.message))
            }
        }

        if replacing {
            // Never swap a complete existing item for an incomplete one.
            guard failures.isEmpty else {
                removeIfPresent(target)
                result.failures = failures.map {
                    TransferFailure(item: index, stage: .item, source: item.source, destination: item.destination,
                                    message: "\($0.displayName): \($0.message)")
                }
                return result
            }
            let trashed: URL
            do { trashed = try trash(item.destination) } catch {
                removeIfPresent(target)
                return fail(trashMessage(item.destination, error))
            }
            let code = rename(target, to: item.destination)
            guard code == 0 else {
                _ = rename(trashed, to: item.destination)
                removeIfPresent(target)
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
            if let message = removeSource(item.source) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message))
                result.outcome = .partial
                return result
            }
            result.sourceRemoved = true
        }
        result.outcome = .done
        return result
    }

    /// Second attempt at the parts of an item that failed: individual files and folders, or removing the original.
    static func retry(_ index: Int, _ item: TransferItem, failures: [TransferFailure], options: Options,
                      control: TransferControl, progress: TransferProgress) -> TransferItemResult {
        var result = TransferItemResult(outcome: .done, destination: item.destination)
        for failure in failures where failure.stage == .copy || failure.stage == .verify {
            guard control.checkpoint() else { result.outcome = .cancelled; return result }
            guard let destination = failure.destination else { continue }
            progress.update { $0.currentName = failure.source.lastPathComponent }
            removeIfPresent(destination)
            let copy = copy(failure.source, to: destination, clone: options.clone, control: control, progress: progress)
            if copy.cancelled {
                removeIfPresent(destination)
                result.outcome = .cancelled
                return result
            }
            if let fatal = copy.fatal {
                result.failures.append(TransferFailure(item: index, stage: .copy, source: failure.source,
                                                       destination: destination, message: fatal))
                continue
            }
            result.failures += copy.errors.map {
                TransferFailure(item: index, stage: .copy, source: URL(fileURLWithPath: $0.source),
                                destination: URL(fileURLWithPath: $0.destination), message: $0.message)
            }
            if options.verify {
                hooks.beforeVerify?(destination)
                let check = verify(failure.source, against: destination, skipping: Set(copy.errors.map(\.source)),
                                   control: control, progress: progress)
                if check.cancelled { result.outcome = .cancelled; return result }
                for mismatch in check.mismatches {
                    removeIfPresent(URL(fileURLWithPath: mismatch.destination))
                    result.failures.append(TransferFailure(item: index, stage: .verify,
                                                           source: URL(fileURLWithPath: mismatch.source),
                                                           destination: URL(fileURLWithPath: mismatch.destination),
                                                           message: mismatch.message))
                }
            }
        }
        guard result.failures.isEmpty else { result.outcome = .partial; return result }
        if item.operation != .copy {
            if let message = removeSource(item.source) {
                result.failures.append(TransferFailure(item: index, stage: .removeSource, source: item.source,
                                                       destination: item.destination, message: message))
                result.outcome = .partial
                return result
            }
            result.sourceRemoved = true
        }
        return result
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
    }

    struct CopyOutcome: Sendable {
        var errors: [EntryError] = []
        var cancelled = false
        /// Nothing could be copied at all.
        var fatal: String?
    }

    /// Recursive `copyfile(3)` with every piece of metadata, APFS clones where possible, per-file progress, and
    /// pause/cancel at block granularity. Files that fail are recorded and skipped; copyfile removes their partial data.
    static func copy(_ source: URL, to destination: URL, clone: Bool, control: TransferControl,
                     progress: TransferProgress) -> CopyOutcome {
        guard !exists(destination) else {
            // copyfile would copy *into* an existing folder; the planner guarantees this never happens.
            return CopyOutcome(fatal: describe(EEXIST))
        }
        let session = CopySession(control: control, progress: progress, throttle: hooks.throttleBytesPerSecond)
        guard let state = copyfile_state_alloc() else { return CopyOutcome(fatal: describe(ENOMEM)) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = copyCallback
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(session).toOpaque())
        var flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL
        if clone { flags |= COPYFILE_CLONE }
        let status = copyfile(source.path, destination.path, state, copyfile_flags_t(flags))
        let code = errno
        withExtendedLifetime(session) {}

        var outcome = CopyOutcome(errors: session.errors)
        if session.quit || control.isCancelled {
            outcome.cancelled = true
        } else if status != 0, session.errors.isEmpty {
            outcome.fatal = describe(code)
        } else if !exists(destination), session.errors.contains(where: { $0.source == source.path }) {
            // The top-level item itself failed (unreadable file, folder that can't be listed…).
            outcome.fatal = session.errors.first { $0.source == source.path }?.message
            outcome.errors.removeAll { $0.source == source.path }
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
    static func verify(_ source: URL, against destination: URL, skipping: Set<String> = [], control: TransferControl,
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
            switch Int32(entry.pointee.fts_info) {
            case FTS_F:
                progress.update { $0.currentName = (path as NSString).lastPathComponent }
                let original = sha256(path, buffer: buffers.0, control: control) { n in
                    progress.update { $0.verifiedBytes += Int64(n) }
                }
                if control.isCancelled { outcome.cancelled = true; return outcome }
                let copy = sha256(target, buffer: buffers.1, control: control) { _ in }
                if control.isCancelled { outcome.cancelled = true; return outcome }
                if original == nil || copy == nil || original != copy {
                    let reason = copy == nil ? "The copy can’t be read back" : "The copy doesn’t match the original"
                    outcome.mismatches.append(EntryError(source: path, destination: target,
                                                         message: original == nil ? "The original can’t be read" : reason))
                }
            case FTS_SL, FTS_SLNONE:
                if readLink(path) != readLink(target) {
                    outcome.mismatches.append(EntryError(source: path, destination: target,
                                                         message: "The copied alias points somewhere else"))
                }
            default:
                break
            }
        }
        return outcome
    }

    static func sha256(_ path: String, buffer: UnsafeMutableRawBufferPointer, control: TransferControl,
                       onRead: (Int) -> Void) -> SHA256.Digest? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
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

    static func removeIfPresent(_ url: URL) {
        guard exists(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the original after a cross-volume move. Returns an error message, or nil on success.
    private static func removeSource(_ url: URL) -> String? {
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
            return "Copied, but the original couldn’t be removed: \(reason)"
        }
    }

    static func temporaryURL(for destination: URL) -> URL {
        let token = UUID().uuidString.prefix(8)
        return destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).strata-\(token)")
    }

    static func describe(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: "You don’t have permission"
        case ENOENT: "The item couldn’t be found"
        case ENOSPC: "The disk is full"
        case EEXIST: "An item with the same name already exists"
        case EROFS: "The disk is read-only"
        case ENAMETOOLONG: "The name is too long"
        case EXDEV: "It’s on a different disk"
        default: String(cString: strerror(code))
        }
    }

    private static func trashMessage(_ url: URL, _ error: Error) -> String {
        "“\(url.lastPathComponent)” couldn’t be moved to the Trash, so it wasn’t replaced"
    }
}

/// State for one `copyfile` call, reached from the C callback through its context pointer.
nonisolated private final class CopySession: @unchecked Sendable {
    let control: TransferControl
    let progress: TransferProgress
    let throttle: Int64?
    var errors: [TransferEngine.EntryError] = []
    var quit = false
    private var fileSize: Int64 = 0
    private var fileReported: Int64 = 0
    private var failedPaths: Set<String> = []

    init(control: TransferControl, progress: TransferProgress, throttle: Int64?) {
        self.control = control
        self.progress = progress
        self.throttle = throttle
    }

    func handle(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?,
                destination: UnsafePointer<CChar>?, code: Int32) -> Int32 {
        let quitCode = Int32(COPYFILE_QUIT)
        if quit { return quitCode }

        if stage == COPYFILE_ERR {
            if code == ECANCELED || control.isCancelled {
                quit = true
                return quitCode
            }
            // Extended attributes the destination won't take (protected or unsupported) don't fail the file.
            if what == COPYFILE_COPY_XATTR { return Int32(COPYFILE_CONTINUE) }
            let src = source.map { String(cString: $0) } ?? ""
            let dst = destination.map { String(cString: $0) } ?? ""
            if failedPaths.insert(src).inserted {
                errors.append(.init(source: src, destination: dst, message: TransferEngine.describe(code)))
            }
            if what == COPYFILE_RECURSE_FILE || what == COPYFILE_COPY_DATA {
                finishFile()
            }
            return Int32(COPYFILE_SKIP)
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

    private func finishFile() {
        let rest = max(0, fileSize - fileReported)
        fileReported = fileSize
        progress.update {
            $0.bytes += rest
            $0.files += 1
        }
    }
}
