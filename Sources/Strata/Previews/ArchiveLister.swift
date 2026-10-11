import Foundation

/// How an archive is listed: Info-ZIP's `zipinfo` for the zip family (exact dates, compressed sizes),
/// libarchive's `bsdtar` for tarballs and the other formats it reads.
nonisolated enum ArchiveKind: Sendable {
    case zip
    case tar

    init?(fileName: String) {
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
nonisolated final class ArchiveNode {
    let name: String
    let isDirectory: Bool
    var size: Int64
    var modified: Date?
    var children: [ArchiveNode] = []
    /// Subfolders by name, only while the tree is being built.
    fileprivate var folders: [Substring: ArchiveNode] = [:]

    init(name: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) {
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

nonisolated struct ArchiveListing: Sendable {
    let root: Handoff<ArchiveNode>
    let files: Int
    let folders: Int
    let uncompressed: Int64
    let compressed: Int64?
    /// Why the listing is incomplete, if it is.
    let note: String?
}

nonisolated enum ArchiveLister {
    static let timeout: TimeInterval = 10
    static let entryLimit = 50_000

    @concurrent
    static func list(_ url: URL, kind: ArchiveKind) async throws -> ArchiveListing {
        let (executable, arguments) = switch kind {
        case .zip: ("/usr/bin/zipinfo", ["-l", "-T", url.path])
        case .tar: ("/usr/bin/tar", ["-tvf", url.path])
        }
        let run = try await ProcessRunner.run(executable, arguments, timeout: timeout)
        try Task.checkCancellation()
        let output = String(decoding: run.output, as: UTF8.self)

        var entries: [(path: String, isDirectory: Bool, size: Int64, date: Date?)] = []
        var compressed: Int64?
        var uncompressedTotal: Int64?
        var seen = 0
        let now = Date()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parsed = kind == .zip ? parseZipInfo(line) : parseTar(line, now: now)
            if let parsed {
                seen += 1
                if entries.count < entryLimit { entries.append(parsed) }
            } else if kind == .zip, line.contains(" uncompressed, ") {
                // `10 files, 2513932 bytes uncompressed, 760934 bytes compressed:  69.8%`
                let words = line.split(separator: " ")
                if words.count > 5 {
                    uncompressedTotal = Int64(words[2])
                    compressed = Int64(words[5])
                }
            }
        }
        if entries.isEmpty {
            if run.timedOut { throw PreviewError.message("Listing this archive took too long.", symbol: "clock") }
            if run.status != 0 { throw PreviewError.message("This archive couldn’t be read.", symbol: "archivebox") }
            throw PreviewError.message("This archive is empty.", symbol: "archivebox")
        }

        let root = ArchiveNode(name: "", isDirectory: true)
        var files = 0, folders = 0
        var bytes: Int64 = 0
        for entry in entries {
            let components = entry.path.split(separator: "/").filter { $0 != "." }
            guard let last = components.last else { continue }
            var parent = root
            for component in components.dropLast() { parent = parent.folder(component, created: &folders) }
            if entry.isDirectory {
                parent.folder(last, created: &folders).modified = entry.date
            } else {
                parent.children.append(ArchiveNode(name: String(last), isDirectory: false, size: entry.size, modified: entry.date))
                files += 1
                bytes += entry.size
            }
        }
        sortAndTotal(root)

        let note: String? = if run.timedOut {
            "Stopped after \(Int(timeout)) s"
        } else if run.truncated || seen > entries.count {
            "Showing first \(entries.count.formatted())"
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
        node.size = node.children.reduce(0) { $0 + sortAndTotal($1) }
        node.children.sort { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return node.size
    }

    // MARK: - Parsing

    /// `-rw-r--r--  3.0 unx     1053 tx      491 defN 20241011.193700 dir/file.txt`
    private static func parseZipInfo(_ line: Substring) -> (String, Bool, Int64, Date?)? {
        guard let (fields, name) = split(line, fields: 8), let size = Int64(fields[3]), Int64(fields[5]) != nil,
              fields[7].count == 15 else { return nil }
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
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
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
nonisolated enum ProcessRunner {
    struct Result: Sendable {
        var output: Data
        var status: Int32
        var timedOut: Bool
        var truncated: Bool
    }

    static let outputLimit = 64 << 20

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> Result {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try box.run(executable, arguments, timeout: timeout)
        } onCancel: {
            box.terminate()
        }
    }

    /// Owns the process so the cancellation handler and the timeout can stop it from other threads.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var timedOut = false

        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // A UTF-8 locale keeps non-ASCII names intact; English month names keep tar dates parseable.
            process.environment = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            lock.withLock { self.process = process }
            try Task.checkCancellation()
            try process.run()
            let deadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                lock.withLock { self.timedOut = true }
                terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }

            var output = Data()
            var truncated = false
            let reader = pipe.fileHandleForReading
            while let chunk = try? reader.read(upToCount: 1 << 16), !chunk.isEmpty {
                output.append(chunk)
                if output.count > ProcessRunner.outputLimit {
                    truncated = true
                    terminate()
                    break
                }
            }
            try? reader.close()
            process.waitUntilExit()
            try Task.checkCancellation()
            let didTimeOut = lock.withLock { timedOut }
            return Result(output: output, status: process.terminationStatus, timedOut: didTimeOut, truncated: truncated)
        }

        func terminate() {
            let process = lock.withLock { self.process }
            if let process, process.isRunning { process.terminate() }
        }
    }
}
