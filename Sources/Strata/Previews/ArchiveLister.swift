import Foundation

/// How an archive is listed: Info-ZIP's `zipinfo` for the zip family (exact dates, compressed sizes),
/// libarchive's `bsdtar` for tarballs and the other formats it reads.
nonisolated package enum ArchiveKind: Sendable {
    case zip
    case tar

    package init?(fileName: String) {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if Self.zipExtensions.contains(ext) {
            self = .zip
        } else if Self.tarExtensions.contains(ext) || Self.compressedTarSuffixes.contains(where: name.hasSuffix) {
            self = .tar
        } else {
            return nil
        }
    }

    private static let zipExtensions: Set<String> = ["zip", "jar", "war", "ear", "aar", "apk", "aab", "ipa", "nupkg", "vsix", "whl", "xpi"]
    private static let tarExtensions: Set<String> = ["tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "7z", "rar", "cpio", "xar", "iso"]
    private static let compressedTarSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"]
}

/// One file or folder inside an archive. Folders implied by deeper paths are created too.
nonisolated package final class ArchiveNode {
    package let name: String
    package let isDirectory: Bool
    package var size: Int64
    package var modified: Date?
    package var children: [ArchiveNode] = []
    /// Subfolders by name, only while the tree is being built.
    fileprivate var folders: [Substring: ArchiveNode] = [:]

    package init(name: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// The subfolder called `name`, created if needed.
    fileprivate func folder(_ name: Substring, created: inout Int) -> ArchiveNode {
        if let existing = folders[name] { return existing }
        let node = ArchiveNode(name: String(name), isDirectory: true)
        children.append(node)
        folders[name] = node
        created += 1
        return node
    }
}

nonisolated package struct ArchiveListing: Sendable {
    package let root: Handoff<ArchiveNode>
    package let files: Int
    package let folders: Int
    package let uncompressed: Int64
    package let compressed: Int64?
    /// Why the listing is incomplete, if it is.
    package let note: String?

    package init(root: Handoff<ArchiveNode>, files: Int, folders: Int, uncompressed: Int64, compressed: Int64?, note: String?) {
        self.root = root
        self.files = files
        self.folders = folders
        self.uncompressed = uncompressed
        self.compressed = compressed
        self.note = note
    }
}

nonisolated package enum ArchiveLister {
    package static let timeout: TimeInterval = 10
    package static let entryLimit = 50_000
    private static let pathDepthLimit = 128
    private static let nodeLimit = 100_000

    @concurrent
    package static func list(_ url: URL, kind: ArchiveKind) async throws -> ArchiveListing {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var info = stat()
        let isRegular = fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        close(fd)
        guard isRegular else { throw CocoaError(.fileReadCorruptFile) }
        let (executable, arguments) = switch kind {
        case .zip: ("/usr/bin/zipinfo", ["-l", "-T", url.path])
        case .tar: ("/usr/bin/tar", ["-tvf", url.path])
        }
        let run = try await ProcessRunner.run(executable, arguments, timeout: timeout)
        try Task.checkCancellation()
        return try parse(run, kind: kind)
    }

    package static func parse(_ run: ProcessRunner.Result, kind: ArchiveKind, now: Date = Date()) throws -> ArchiveListing {
        let output = String(decoding: run.output, as: UTF8.self)

        var entries: [(path: String, isDirectory: Bool, size: Int64, date: Date?)] = []
        var compressed: Int64?
        var uncompressedTotal: Int64?
        var seen = 0
        var remaining = output[...]
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let end = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            let line = remaining[..<end]
            remaining = end == remaining.endIndex ? "" : remaining[remaining.index(after: end)...]
            if entries.count >= entryLimit { seen += 1; break }
            let parsed = kind == .zip ? parseZipInfo(line) : parseTar(line, now: now)
            if let parsed {
                seen += 1
                if entries.count < entryLimit { entries.append(parsed) }
            } else if kind == .zip, line.contains(" uncompressed, ") {
                // `10 files, 2513932 bytes uncompressed, 760934 bytes compressed:  69.8%`
                let words = line.split(separator: " ")
                if words.count > 5, let filesCount = Int64(words[0]), filesCount >= 0,
                   words[1].hasPrefix("file"),
                   let uncomp = Int64(words[2]), uncomp >= 0,
                   let comp = Int64(words[5]), comp >= 0 {
                    uncompressedTotal = uncomp
                    compressed = comp
                }
            }
        }
        if entries.isEmpty {
            if run.timedOut { throw PreviewError.message(String(localized: "Listing this archive took too long."), symbol: "clock") }
            if run.status != 0 { throw PreviewError.message(String(localized: "This archive couldn’t be read."), symbol: "archivebox") }
            throw PreviewError.message(String(localized: "This archive is empty."), symbol: "archivebox")
        }

        let root = ArchiveNode(name: "", isDirectory: true)
        var files = 0, folders = 0, displayedEntries = 0
        var bytes: Int64 = 0
        for entry in entries {
            let path = entry.path.split(separator: "/", maxSplits: pathDepthLimit)
            guard path.count <= pathDepthLimit else { continue }
            let components = path.filter { $0 != "." }
            guard let last = components.last else { continue }
            // Explicit entries also create implicit folders. Bound both memory and recursive tree depth.
            guard files + folders + components.count <= nodeLimit else { break }
            displayedEntries += 1
            var parent = root
            for component in components.dropLast() { parent = parent.folder(component, created: &folders) }
            if entry.isDirectory {
                parent.folder(last, created: &folders).modified = entry.date
            } else {
                parent.children.append(ArchiveNode(name: String(last), isDirectory: false, size: max(0, entry.size), modified: entry.date))
                files += 1
                // A crafted listing can claim sizes that overflow.
                bytes = bytes.addingReportingOverflow(max(0, entry.size)).overflow ? .max : bytes + max(0, entry.size)
            }
        }
        sortAndTotal(root)

        let note: String? = if run.timedOut {
            String(localized: "Stopped after \(Int(timeout)) s", comment: "Archive listing stopped after this many seconds")
        } else if run.truncated || seen > displayedEntries {
            String(localized: "Showing first \(displayedEntries.formatted())", comment: "Preview footer note: only the first part is shown (a count or a size)")
        } else {
            nil
        }
        return ArchiveListing(root: Handoff(value: root), files: files, folders: folders,
                              uncompressed: uncompressedTotal ?? bytes, compressed: compressed, note: note)
    }

    /// Folders first, then names in Finder order; folder sizes are the sum of their contents.
    @discardableResult
    private static func sortAndTotal(_ node: ArchiveNode) -> Int64 {
        guard node.isDirectory else { return node.size }
        node.folders = [:]
        node.size = node.children.reduce(0) { total, child in
            let (sum, overflow) = total.addingReportingOverflow(sortAndTotal(child))
            return overflow ? .max : sum
        }
        node.children.sort { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return node.size
    }

    // MARK: - Parsing

    /// `-rw-r--r--  3.0 unx     1053 tx      491 defN 20241011.193700 dir/file.txt`
    private static func parseZipInfo(_ line: Substring) -> (String, Bool, Int64, Date?)? {
        guard let (fields, name) = split(line, fields: 8), let size = Int64(fields[3]), Int64(fields[5]) != nil,
              fields[7].utf8.count == 15,
              fields[7].utf8.enumerated().allSatisfy({ $0.offset == 8 ? $0.element == UInt8(ascii: ".") : (0x30...0x39).contains($0.element) })
        else { return nil }
        let path = String(name)
        let digits = fields[7].utf8.map { Int($0) - 48 }
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        let date = localDate(year: number(0..<4), month: number(4..<6), day: number(6..<8),
                             hour: number(9..<11), minute: number(11..<13), second: number(13..<15))
        return (path, fields[0].hasPrefix("d") || path.hasSuffix("/"), size, date)
    }

    /// `drwxr-xr-x  0 user  staff       0 Oct 11 19:54 dir/` (or a year in place of the time for older entries).
    private static func parseTar(_ line: Substring, now: Date) -> (String, Bool, Int64, Date?)? {
        guard let (fields, name) = split(line, fields: 8), fields[0].count >= 10, let type = fields[0].first,
              "-dlbcpsh".contains(type), let size = Int64(fields[4]) else { return nil }
        var path = String(name)
        if type == "l", let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
        if let link = path.range(of: " link to ") { path = String(path[..<link.lowerBound]) }
        var date: Date?
        if let month = months.firstIndex(of: String(fields[5])), let day = Int(fields[6]) {
            let timeOrYear = fields[7].split(separator: ":")
            if timeOrYear.count == 2, let hour = Int(timeOrYear[0]), let minute = Int(timeOrYear[1]) {
                let year = Calendar.current.component(.year, from: now)
                date = localDate(year: year, month: month + 1, day: day, hour: hour, minute: minute)
                // Entries without a year are from the last six months, so a future date means last year.
                if let parsed = date, parsed > now.addingTimeInterval(86_400) {
                    date = localDate(year: year - 1, month: month + 1, day: day, hour: hour, minute: minute)
                }
            } else if let year = Int(fields[7]) {
                date = localDate(year: year, month: month + 1, day: day)
            }
        }
        return (path, type == "d", size, date)
    }

    /// The first `count` space-separated fields, and the rest of the line after the single space that follows them
    /// (file names may contain spaces).
    private static func split(_ line: Substring, fields count: Int) -> ([Substring], Substring)? {
        let bytes = line.utf8
        var fields: [Substring] = []
        fields.reserveCapacity(count)
        var index = bytes.startIndex
        while fields.count < count {
            while index < bytes.endIndex, bytes[index] == 0x20 { index = bytes.index(after: index) }
            guard index < bytes.endIndex else { return nil }
            let start = index
            while index < bytes.endIndex, bytes[index] != 0x20 { index = bytes.index(after: index) }
            fields.append(line[start..<index])
        }
        guard index < bytes.endIndex else { return nil }
        let rest = line[bytes.index(after: index)...]
        return rest.isEmpty ? nil : (fields, rest)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Both tools print local wall-clock time. `mktime` is ~40× faster than DateFormatter, which matters at 50,000 entries.
    private static func localDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        var time = tm()
        time.tm_year = Int32(year - 1900)
        time.tm_mon = Int32(month - 1)
        time.tm_mday = Int32(day)
        time.tm_hour = Int32(hour)
        time.tm_min = Int32(minute)
        time.tm_sec = Int32(second)
        time.tm_isdst = -1
        let seconds = mktime(&time)
        return seconds == -1 ? nil : Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// Runs a command-line tool off the main thread, collecting its output, with a timeout and an output cap,
/// and terminating it if the calling task is cancelled.
nonisolated package enum ProcessRunner {
    package struct Result: Sendable {
        package var output: Data
        package var status: Int32
        package var timedOut: Bool
        package var truncated: Bool

        package init(output: Data, status: Int32, timedOut: Bool, truncated: Bool) {
            self.output = output
            self.status = status
            self.timedOut = timedOut
            self.truncated = truncated
        }
    }

    package static let outputLimit = 64 << 20

    /// Optional small stdin and one retained file descriptor are for the archive worker. Secrets stay off argv.
    /// The file is duplicated to descriptor 3 in the child; the caller retains it until this call returns.
    package static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                            input: Data? = nil, file: FileHandle? = nil) async throws -> Result {
        guard (input?.count ?? 0) <= 8192 else { throw CocoaError(.fileReadTooLarge) }
        let box = ProcessBox()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Swift.Result { try box.run(executable, arguments, timeout: timeout, input: input, file: file) })
                }
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return result
    }

    /// The child stays unreaped until the same lock that guards signaling clears its PID. Foundation's Process
    /// reaps independently, which cannot provide that guarantee for a delayed SIGKILL.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var timedOut = false
        private var cancelled = false

        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, input: Data?, file: FileHandle?) throws -> Result {
            let reader = try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                let child = try Self.launch(executable, arguments, hasInput: input != nil, file: file)
                pid = child.pid
                return child
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, lock.withLock({ () -> Bool in
                    guard pid != nil else { return false }
                    timedOut = true
                    return true
                }) else { return }
                terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }
            if let fd = reader.input {
                let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do { try writer.write(contentsOf: input ?? Data()) }
                catch { terminate() }
                try? writer.close()
            }
            let outputReader = FileHandle(fileDescriptor: reader.output, closeOnDealloc: true)
            var output = Data(), truncated = false
            do {
                while let chunk = try outputReader.read(upToCount: 1 << 16), !chunk.isEmpty {
                    let room = ProcessRunner.outputLimit - output.count
                    output.append(chunk.prefix(room))
                    if chunk.count > room { truncated = true; terminate(); break }
                }
            } catch {
                truncated = true
                terminate()
            }
            try? outputReader.close()
            var status: Int32 = 0
            while true {
                let finished = lock.withLock { () -> Bool in
                    guard let pid else { return true }
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid || (waited < 0 && errno != EINTR) {
                        if waited < 0 { status = -1 }
                        self.pid = nil
                        return true
                    }
                    return false
                }
                if finished { break }
                usleep(1000)
            }
            let code = status < 0 ? -1 : status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
            return Result(output: output, status: code, timedOut: lock.withLock { timedOut }, truncated: truncated)
        }

        func terminate() {
            let child = lock.withLock { () -> pid_t? in
                cancelled = true
                guard let pid else { return nil }
                _ = kill(-pid, SIGTERM)
                return pid
            }
            guard let child else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    guard self.pid == child else { return }
                    _ = kill(-child, SIGKILL)
                }
            }
        }

        /// A separate process group lets cancellation stop decompressors too. Only stdout, optional stdin and
        /// the supplied archive descriptor are inherited; stderr and unused stdin go to /dev/null.
        private static func launch(_ executable: String, _ arguments: [String], hasInput: Bool, file: FileHandle?) throws -> (pid: pid_t, output: Int32, input: Int32?) {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var succeeded = false
            defer {
                close(descriptors[1])
                if !succeeded { close(descriptors[0]) }
            }
            _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
            var incoming = [Int32](repeating: -1, count: 2)
            if hasInput {
                guard pipe(&incoming) == 0 else { throw POSIXError(.EIO) }
                _ = fcntl(incoming[0], F_SETFD, FD_CLOEXEC)
                _ = fcntl(incoming[1], F_SETFD, FD_CLOEXEC)
                guard fcntl(incoming[1], F_SETNOSIGPIPE, 1) == 0 else {
                    close(incoming[0]); close(incoming[1]); throw POSIXError(.EIO)
                }
            }
            defer {
                if incoming[0] >= 0 { close(incoming[0]) }
                if !succeeded, incoming[1] >= 0 { close(incoming[1]) }
            }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            func checked(_ code: Int32) throws {
                if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            }
            try checked(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try checked(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try checked(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO))
            if hasInput { try checked(posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO)) }
            else { try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)) }
            try checked(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
            // Darwin leaves FD_CLOEXEC set for dup2(fd, fd). Always use a distinct source descriptor.
            let archiveFD = file.map { fcntl($0.fileDescriptor, F_DUPFD_CLOEXEC, 4) }
            defer { if let archiveFD, archiveFD >= 0 { close(archiveFD) } }
            if let archiveFD {
                guard archiveFD >= 0 else { throw POSIXError(.EBADF) }
                try checked(posix_spawn_file_actions_adddup2(&actions, archiveFD, 3))
            }
            try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)))
            try checked(posix_spawnattr_setpgroup(&attributes, 0))
            var child: pid_t = 0
            try cStrings([executable] + arguments) { argv in
                try cStrings(["LC_ALL=en_US.UTF-8", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin"]) { environment in
                    try checked(posix_spawn(&child, executable, &actions, &attributes, argv, environment))
                }
            }
            succeeded = true
            return (child, descriptors[0], hasInput ? incoming[1] : nil)
        }

        private static func cStrings<T>(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
            var pointers: [UnsafeMutablePointer<CChar>?] = []
            defer { pointers.forEach { free($0) } }
            for value in values {
                guard !value.contains("\0") else { throw POSIXError(.EINVAL) }
                guard let pointer = strdup(value) else { throw POSIXError(.ENOMEM) }
                pointers.append(pointer)
            }
            pointers.append(nil)
            return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
        }
    }
}
