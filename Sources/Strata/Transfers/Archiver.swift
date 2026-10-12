import Foundation

/// Compress (zip, like Finder) and extract (like Archive Utility), with the care an archive from anywhere needs:
/// - Extraction happens in a private folder on the destination's disk, with tools that refuse to write outside it
///   (bsdtar's defaults: no absolute paths, no "..", nothing written through a symlink; zips go to ditto only when
///   their listing is fully understood and shows nothing but plain files and folders).
/// - The result is checked before it's moved into place: links must stay inside what's placed, special files are dropped,
///   setuid bits cleared, and anything that can't be checked stops the extraction.
/// - The disk's free space is checked first and watched while extracting, so an archive bomb can't fill it.
nonisolated enum Archiver {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What a listing says about an archive before it's extracted.
    struct Inspection: Sendable {
        var entries = 0
        /// Files outside `__MACOSX` (ditto reports one line per file it writes).
        var files = 0
        var bytes: Int64 = 0
        /// Anything but plain files and folders, absolute paths, "..", or a listing not fully understood: only bsdtar's
        /// secure extraction may unpack it.
        var needsSecureTool = false
        /// Password-protected entries.
        var encrypted = false
        /// The listing finished (no timeout, readable).
        var complete = false

        /// Entries the extraction will report, for progress.
        var progressTotal: Int { needsSecureTool ? entries : files }
    }

    /// Progress and cancellation, shared with the job that runs it.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var done = 0

        var isCancelled: Bool { lock.withLock { cancelled } }
        /// Entries written so far.
        var entriesDone: Int { lock.withLock { done } }

        func cancel() {
            let process = lock.withLock { () -> Process? in
                cancelled = true
                return self.process
            }
            if let process, process.isRunning { process.terminate() }
        }

        fileprivate func attach(_ process: Process?) { lock.withLock { self.process = process } }
        fileprivate func advance(_ count: Int) { lock.withLock { done += count } }
    }

    /// Kept free while extracting: a tenth of what's free, at most 1 GB, so small disks can still take small archives.
    static func reserve(free: Int64) -> Int64 {
        min(1 << 30, max(0, free) / 10)
    }

    /// Free space on `url`'s disk, read fresh each time (a URL caches what it was first told).
    static func availableSpace(onDiskOf url: URL) -> Int64? {
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: - Compress

    /// Zips `items` next to the first one: `Name.zip` for one item, `Archive.zip` for several (a taken name gets a
    /// number). Returns the zip.
    static func compress(_ items: [URL], control: Control) throws -> URL {
        guard let first = items.first else { throw Failure(message: "Nothing to compress.") }
        let fm = FileManager.default
        let folder = first.deletingLastPathComponent()
        try requireWritable(folder)
        let name = items.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { removeTree(work) }
        let zip = work.appending(path: name)
        if items.count == 1, !isSymlink(first) {
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "-V", first.path, zip.path],
                    control: control, counts: { $0.hasPrefix("copying file") })
        } else {
            // ditto takes one source (and would follow a lone link): gather the items in a folder first. On APFS these
            // copies are clones, instant and free; links stay links; the folder's own name isn't stored.
            let staging = work.appending(path: "Archive", directoryHint: .isDirectory)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for item in items {
                guard !control.isCancelled else { throw CancellationError() }
                try fm.copyItem(at: item, to: uniqueURL(staging.appending(path: item.lastPathComponent)))
            }
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "-V", staging.path, zip.path],
                    control: control, counts: { $0.hasPrefix("copying file") })
        }
        return try place(zip, in: folder, as: name)
    }

    // MARK: - Extract

    /// Lists `archive` to learn its size and whether it holds anything risky. Doesn't throw: an unreadable listing
    /// just comes back incomplete, and extraction then uses the secure tool. Runs off the main thread.
    @concurrent
    static func inspect(_ archive: URL, kind: ArchiveKind) async -> Inspection {
        let (tool, arguments) = switch kind {
        case .zip: ("/usr/bin/zipinfo", ["-s", archive.path])
        case .tar: ("/usr/bin/tar", ["-tvf", archive.path])
        }
        guard let run = try? await ProcessRunner.run(tool, arguments, timeout: 60) else { return Inspection() }
        var result = Inspection()
        // Fails closed: any line that isn't the header, the totals or a fully understood entry sends the archive to
        // bsdtar's secure extraction, and so does an entry count that differs from zipinfo's own totals.
        var unexplained = 0
        var reportedEntries: Int?
        var headerEntries: Int?
        for line in String(decoding: run.output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            if kind == .zip, line.hasPrefix("Archive:") { continue }
            // "Zip file size: 3923 bytes, number of entries: 20"
            if kind == .zip, line.hasPrefix("Zip file size:"), let count = line.split(separator: " ").last.flatMap({ Int($0) }) {
                headerEntries = count
                continue
            }
            if kind == .zip, let total = zipTotal(line) {
                reportedEntries = total
                continue
            }
            // zipinfo -s: attributes version os size type method date time name (attributes: "-rw-r--r--", or
            //             "-rw-a--" for zips made on Windows)
            // tar -tv:    perms links owner group size month day time name [-> target]
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, fields[0].count == 10 || (kind == .zip && fields[0].count == 7),
                  let size = Int64(fields[kind == .zip ? 3 : 4]) else {
                unexplained += 1
                continue
            }
            result.entries += 1
            result.bytes += size
            var name = fields[8]
            if kind == .tar, let arrow = name.range(of: " -> ") { name = name[..<arrow.lowerBound] }
            // Entries from MS-DOS and Windows zips have no Unix type ("?rw-------", os "fat"): they can't be links, so
            // they're plain files, or folders when the name ends in "/".
            var type = fields[0].first
            if kind == .zip, type == "?", fields[2] != "unx" { type = name.hasSuffix("/") ? "d" : "-" }
            if type == "-", !name.hasPrefix("__MACOSX/") { result.files += 1 }
            // zipinfo marks encrypted entries with a capital T or B ("TX", "Bx").
            if kind == .zip, let flag = fields[4].first, flag == "T" || flag == "B" { result.encrypted = true }
            if type != "-" && type != "d" || name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                result.needsSecureTool = true
            }
        }
        result.complete = run.status == 0 && !run.timedOut && !run.truncated && result.entries > 0
        if !result.complete || unexplained > 0
            || (kind == .zip && (reportedEntries != result.entries || headerEntries != result.entries)) {
            result.needsSecureTool = true
        }
        return result
    }

    /// zipinfo's closing line, "20 files, 1335 bytes uncompressed, 760 bytes compressed:  42.9%": the entry count.
    private static func zipTotal(_ line: Substring) -> Int? {
        let words = line.split(separator: " ", maxSplits: 2)
        guard words.count == 3, words[1] == "file," || words[1] == "files,", words[2].contains("uncompressed") else { return nil }
        return Int(words[0])
    }

    /// Extracts `archive` into `folder` like Archive Utility: one top-level item keeps its name; several go in a folder
    /// named after the archive. Taken names get a number. Returns what was created.
    static func extract(_ archive: URL, kind: ArchiveKind, inspection: Inspection, into folder: URL,
                        control: Control) throws -> URL {
        let fm = FileManager.default
        try requireWritable(folder)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { removeTree(work) }
        let root = work.appending(path: "contents", directoryHint: .isDirectory)
        try unpack(archive, kind: kind, inspection: inspection, into: root, control: control)
        let top = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard let only = top.first else { throw Failure(message: "“\(archive.lastPathComponent)” is empty.") }
        if top.count == 1 {
            // What's placed is that one item, so links inside it must stay inside it, and it can't be a link itself.
            guard !isSymlink(only) else {
                throw Failure(message: "“\(archive.lastPathComponent)” holds only a link, so it wasn’t extracted.")
            }
            try check(only, control: control)
            return try place(only, in: folder, as: only.lastPathComponent)
        }
        try check(root, control: control)
        return try place(root, in: folder, as: baseName(archive))
    }

    /// Extracts `archive`'s contents into the new folder `destination` (for browsing an archive as a folder).
    static func extractContents(_ archive: URL, kind: ArchiveKind, inspection: Inspection, to destination: URL,
                                control: Control) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
        defer { removeTree(work) }
        let root = work.appending(path: "contents", directoryHint: .isDirectory)
        try unpack(archive, kind: kind, inspection: inspection, into: root, control: control)
        try check(root, control: control)
        try fm.moveItem(at: root, to: destination)
    }

    /// The archive's name without its archive extensions ("Photos.tar.gz" → "Photos").
    static func baseName(_ archive: URL) -> String {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    private static func unpack(_ archive: URL, kind: ArchiveKind, inspection: Inspection, into root: URL,
                               control: Control) throws {
        let fm = FileManager.default
        if inspection.encrypted { throw passwordProtected(archive) }
        let disk = root.deletingLastPathComponent()
        if inspection.complete, let free = availableSpace(onDiskOf: disk), inspection.bytes > free - reserve(free: free) {
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            throw Failure(message: "There isn’t enough space to extract “\(archive.lastPathComponent)”: it needs "
                + "\(format(inspection.bytes)), and \(format(free)) is available.")
        }
        // `root`'s parent is a private folder; `root` itself becomes the extracted folder, so it gets usual permissions.
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            if kind == .zip, !inspection.needsSecureTool {
                // Archive Utility's own tool: puts back the resource forks and attributes zips keep in __MACOSX.
                try run("/usr/bin/ditto", ["-x", "-k", "-V", archive.path, root.path], control: control,
                        counts: { $0.hasPrefix("copying file") }, watching: disk)
            } else {
                // A passphrase is given so bsdtar never waits for one (there's no terminal to type it into); a protected
                // archive then fails at once.
                try run("/usr/bin/tar", ["-x", "-v", "--passphrase", "-", "-f", archive.path, "-C", root.path],
                        control: control, counts: { $0.hasPrefix("x ") }, watching: disk)
                // bsdtar leaves a zip's sequestered attributes as plain files.
                if kind == .zip { removeTree(root.appending(path: "__MACOSX")) }
            }
        } catch let failure as Failure where failure.message == passwordMarker {
            throw passwordProtected(archive)
        }
    }

    private static let passwordMarker = "\u{1}password"

    private static func passwordProtected(_ archive: URL) -> Failure {
        Failure(message: "“\(archive.lastPathComponent)” is password-protected. Open it with Archive Utility to enter the password.")
    }

    /// Everything in `boundary` must stay inside it: a link may only point within it. Special files (pipes, devices,
    /// sockets) are dropped and setuid/setgid bits cleared. Folders are made readable as they're walked, so none can
    /// hide anything; whatever can't be checked (an unreadable entry, a path too long) stops the extraction. Paths are
    /// compared in their real form (`realpath`), never through Foundation's shortened spellings of /private/….
    static func check(_ boundary: URL, control: Control? = nil) throws {
        let fm = FileManager.default
        guard let rootPath = realPath(boundary.path) else { throw Failure(message: "The extracted files couldn’t be checked.") }
        func inside(_ path: String) -> Bool { path == rootPath || path.hasPrefix(rootPath + "/") }
        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw Failure(message: "The extracted files couldn’t be checked.") }
        if info.st_mode & S_IFMT == S_IFDIR { chmod(rootPath, (info.st_mode & 0o7777) | S_IRWXU) }
        var walkError: Error?
        let base = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: [.producesRelativePathURLs],
                                         errorHandler: { _, error in
                                             walkError = error
                                             return false
                                         }) else { throw Failure(message: "The extracted files couldn’t be checked.") }
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen % 256 == 0, control?.isCancelled == true { throw CancellationError() }
            let relative = url.relativePath
            let path = rootPath + "/" + relative
            guard lstat(path, &info) == 0 else {
                throw Failure(message: "“\(relative)” in the archive couldn’t be checked, so nothing was extracted.")
            }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                let target = try fm.destinationOfSymbolicLink(atPath: path)
                let lexical = normalized((path as NSString).deletingLastPathComponent + "/" + target)
                // Where it really leads, through any links on the way; a dangling one by its deepest existing folder.
                let real = realPath(path) ?? realPath(lexical) ?? lexical
                guard !target.hasPrefix("/"), inside(lexical), inside(real) else {
                    throw Failure(message: "This archive contains a link that points outside it (“\(relative)”), so it wasn’t extracted.")
                }
            case S_IFDIR:
                // Readable and enterable, so the walk sees what's inside (and the folder can be removed later).
                chmod(path, (info.st_mode & 0o7777 & ~(S_ISUID | S_ISGID)) | S_IRWXU)
            case S_IFREG:
                if info.st_mode & (S_ISUID | S_ISGID) != 0 { chmod(path, info.st_mode & ~(S_ISUID | S_ISGID) & 0o7777) }
            default:
                try fm.removeItem(atPath: path)
            }
        }
        if let walkError {
            throw Failure(message: "The extracted files couldn’t all be checked (\(walkError.localizedDescription)), so nothing was extracted.")
        }
    }

    /// `path` as the system resolves it (links followed, real case, /private kept); for a path that doesn't exist, its
    /// deepest existing folder resolved and the rest appended.
    private static func realPath(_ path: String) -> String? {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, parent != "/", !parent.isEmpty, let resolvedParent = realPath(parent) else { return nil }
        return resolvedParent + "/" + (path as NSString).lastPathComponent
    }

    /// "." and ".." resolved by hand (Foundation's standardizing also rewrites /private/… spellings).
    private static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: - Placing results

    /// Moves `item` into `folder` as `name`, or `name 2`, `name 3`… when taken, claiming the name atomically (nothing
    /// that appears meanwhile is ever replaced).
    private static func place(_ item: URL, in folder: URL, as name: String) throws -> URL {
        let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && !isSymlink(item)
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 1...10_000 {
            let candidate = n == 1 ? name : ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let destination = folder.appending(path: candidate, directoryHint: isFolder ? .isDirectory : .notDirectory)
            if renamex_np(item.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw Failure(message: "No free name for “\(name)”.")
    }

    /// `url`, or `name 2.ext`, `name 3.ext`… when it's taken (a dangling link counts as taken). For staging only:
    /// final names are claimed by `place`.
    static func uniqueURL(_ url: URL) -> URL {
        func taken(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
        guard taken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let ext = url.hasDirectoryPath ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for n in 2... {
            let candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)",
                                             directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
            if !taken(candidate) { return candidate }
        }
        return url
    }

    private static func requireWritable(_ folder: URL) throws {
        guard access(folder.path, W_OK) == 0 else {
            throw Failure(message: "“\(FileManager.default.displayName(atPath: folder.path))” can’t be changed, so nothing can be made there.")
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// Removes `url` even when the archive left folders without write or read permission.
    static func removeTree(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            chmod(url.path, (info.st_mode & 0o7777) | S_IRWXU)
            if let walker = FileManager.default.enumerator(atPath: url.path) {
                while let relative = walker.nextObject() as? String {
                    let path = url.path + "/" + relative
                    if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { chmod(path, (info.st_mode & 0o7777) | S_IRWXU) }
                }
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Running the tools

    /// Runs `tool`, counting output lines that mark one entry done, until it exits or `control` cancels. With
    /// `watching`, stops when that disk runs low on space.
    private static func run(_ tool: String, _ arguments: [String], control: Control, counts: @escaping (Substring) -> Bool,
                            watching folder: URL? = nil) throws {
        guard !control.isCancelled else { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        control.attach(process)
        defer { control.attach(nil) }
        try process.run()
        // A Stop that came between attaching and starting would have found nothing to stop.
        if control.isCancelled { process.terminate() }

        let lowSpace = LockedFlag()
        var watchdog: DispatchSourceTimer?
        if let folder, let free = availableSpace(onDiskOf: folder) {
            let reserve = reserve(free: free)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler {
                if let free = availableSpace(onDiskOf: folder), free < reserve {
                    lowSpace.set()
                    process.terminate()
                }
            }
            timer.resume()
            watchdog = timer
        }
        defer { watchdog?.cancel() }

        var pending = Data()
        var tail: [Substring] = []
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 1 << 16), !chunk.isEmpty {
            pending.append(chunk)
            guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let text = String(decoding: pending[...last], as: UTF8.self)
            pending.removeSubrange(...last)
            var count = 0
            for line in text.split(separator: "\n") {
                if counts(line) { count += 1 }
                // Kept for the error message: the last lines that aren't progress.
                if !isProgress(line) {
                    tail.append(line.prefix(300))
                    if tail.count > 20 { tail.removeFirst() }
                }
            }
            control.advance(count)
        }
        process.waitUntilExit()
        if control.isCancelled { throw CancellationError() }
        if lowSpace.isSet {
            throw Failure(message: "Stopped: the disk was running out of space.")
        }
        guard process.terminationStatus == 0 else {
            if tail.contains(where: { $0.contains("passphrase") || $0.contains("password") }) {
                throw Failure(message: passwordMarker)
            }
            throw Failure(message: reason(tail) ?? "It stopped with an error (\(process.terminationStatus)).")
        }
    }

    /// Lines tools print for each entry as it goes ("copying file ./a ...", ">>> Copying a", "x a"), unless the entry's
    /// line reports a problem.
    private static func isProgress(_ line: Substring) -> Bool {
        if line.hasPrefix("copying file") || line.hasPrefix(">>> ") || line.contains(" bytes for ") { return true }
        return line.hasPrefix("x ") && !line.contains(": ")
    }

    /// The tool's last real error, in plain words. bsdtar reports refusals on the entry's own line
    /// ("x ../../a: Path contains '..'"); its closing "Error exit delayed" line says nothing.
    private static func reason(_ lines: [Substring]) -> String? {
        for line in lines.reversed() where !line.contains("Error exit delayed") {
            var text = line[...]
            for prefix in ["x ", "tar: ", "ditto: "] where text.hasPrefix(prefix) { text = text.dropFirst(prefix.count) }
            if text.contains("Path contains '..'") || text.contains("Cannot extract through symlink") || text.contains("Absolute path") {
                let entry = text.range(of: ": ").map { text[..<$0.lowerBound] } ?? text
                return "This archive tries to write outside its folder (“\(entry)”), so it wasn’t extracted."
            }
            // Drop errno noise: "…: Unknown error: -1", "…: Undefined error: 0".
            for noise in [": Unknown error", ": Undefined error"] {
                if let range = text.range(of: noise) { text = text[..<range.lowerBound] }
            }
            let message = text.trimmingCharacters(in: .whitespaces)
            if !message.isEmpty { return String(message.prefix(300)) }
        }
        return nil
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
