import Darwin
import CoreServices
import Foundation
import Synchronization

extension Notification.Name {
    /// A container copy's folder couldn't be brought up to date. `userInfo["folder"]`: URL, `["message"]`: String.
    static let containerCopyProblem = Notification.Name("StrataContainerCopyProblem")
    /// Files in a container copy were fetched (`object`: [URL]): their rows can show them now.
    static let containerFilesFetched = Notification.Name("StrataContainerFilesFetched")
}

/// One item of a folder in a container, as listed.
nonisolated struct ListedEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case file, directory, symlink, other
    }

    let name: String
    let kind: Kind
    let size: Int64
    /// Permission bits.
    let mode: UInt32
    let modified: Date?
    let linkTarget: String
    /// A link that leads to a folder (so the copy can show it as one).
    var targetIsDirectory = false

    /// A size as another machine reported it, kept within what a file can be (0 to 16 TB): a negative or absurd number
    /// from a container's `stat` or a server would otherwise overflow sums of sizes.
    static func saneSize(_ size: Int64) -> Int64 { min(max(size, 0), 1 << 44) }
}

/// A listing from the shell or archive reader, before it is applied to the local copy.
nonisolated struct ContainerListingResult: Sendable {
    let entries: [ListedEntry]
    let contents: [String: Data]
    let freshFor: TimeInterval
}

/// Reads containers' files into their copies (see `ContainerCopies`).
///
/// A folder is listed when it's shown: by a small script run in the container as the container's own user (fast, but
/// it needs the container running with a shell), else from the folder's archive stream (works on any container and any
/// folder, slower for big folders). World-readable small files are fetched right after the listing; anything else stays
/// a placeholder until it's opened, previewed or copied. Everything here reads; the only thing run in a container is the
/// listing script.
actor ContainerFiles {
    static let shared = ContainerFiles()

    /// Files up to this size are fetched with their folder's listing…
    static let eagerFileSize: Int64 = 1 << 20
    /// …up to this much per folder…
    static let eagerFolderBytes: Int64 = 64 << 20
    /// …and this many.
    static let eagerFolderCount = 2000
    /// A folder listed by the script this recently isn't listed again (several views load the same folder).
    static let freshFor: TimeInterval = 15
    /// A folder read from its archive stream (a stopped container, or one without a shell) stays current longer.
    static let archiveFreshFor: TimeInterval = 600
    /// Longest an archive-stream listing may take.
    static let archiveBudget: TimeInterval = 120

    private let removeCopy: @Sendable (URL) async -> Void
    private var removals: [String: Task<Void, Never>] = [:]
    private let readListing: @Sendable (ContainerSource, String) async throws -> ContainerListingResult
    private let readFile: @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void
    private let readTree: @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void

    init(readListing: @escaping @Sendable (ContainerSource, String) async throws -> ContainerListingResult = {
        try await ContainerFiles.loadListing($0, path: $1)
    }, readFile: @escaping @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void = { source, path, url, stop in
        try await blocking { try CopyWriter.fetchFile(source.engine, id: source.id, containerPath: path, to: url, stop: stop) }
    }, readTree: @escaping @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void = { source, path, url, stop in
        try await blocking { try CopyWriter.writeTree(source.engine, id: source.id, containerPath: path, into: url, stop: stop) }
    }, removeCopy: @escaping @Sendable (URL) async -> Void = { url in
        _ = try? await blocking { ContainerCopies.remove(url) }
    }) {
        self.removeCopy = removeCopy
        self.readListing = readListing
        self.readFile = readFile
        self.readTree = readTree
    }

    private var listings = CopyListings()
    private(set) var fetches = CopyFetches()
    /// Placeholders' permissions in the container, from their listing (a secret only its owner may read isn't fetched
    /// just because it's selected).
    private var modes: [String: UInt32] = [:]

    /// Background fetches of small files, by copy (top folder path).
    private var eager: [String: [UUID: Task<Void, Never>]] = [:]
    /// Copies being removed: nothing new starts in them.
    private(set) var closing: Set<String> = []

    /// Brings the copy's `folder` up to date with the container. Problems are reported with `.containerCopyProblem`;
    /// what's in the copy stays as it was.
    func refresh(_ folder: URL) async {
        // Links in a copy all point inside it, so the real folder is still in the same copy.
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        if let engine = ContainerCopies.engineFolder(real) { return await syncContainers(real, engine: engine) }
        if ContainerCopies.isStack(real), let engine = ContainerCopies.engineFolder(real.deletingLastPathComponent()) {
            return await syncContainers(real.deletingLastPathComponent(), engine: engine)
        }
        guard let (source, top) = ContainerCopies.copy(containing: real), let path = ContainerCopies.containerPath(of: real, top: top),
              !closing.contains(top.standardizedFileURL.path) else { return }
        let key = real.path
        while !closing.contains(top.standardizedFileURL.path), let request = listings.request(for: key, start: {
            Task { await self.list(real, path: path, source: source, top: top) }
        }) {
            let fresh = await request.task.value
            guard listings.finish(request, for: key, freshFor: fresh) else { return }
        }
    }

    /// The Containers folder: one folder per container, matching the engine's list. A container that's gone takes its
    /// folder with it; one made again under the same name starts over (its files aren't the old one's).
    private func syncContainers(_ folder: URL, engine: ContainerEngine) async {
        let key = folder.path
        while let request = listings.request(for: key, start: {
            Task<TimeInterval?, Never> {
                do {
                    let list = try await blocking { try ContainerAPI.containers(engine) }
                    let gone = try await blocking { try CopyWriter.syncContainers(list, engine: engine, in: folder) }
                    for top in gone { await self.discard(top) }
                    if !gone.isEmpty { _ = try await blocking { try CopyWriter.syncContainers(list, engine: engine, in: folder) } }
                    return 2
                } catch {
                    await Self.reportEngine(error, folder: folder, engine: engine)
                    return nil
                }
            }
        }) {
            let fresh = await request.task.value
            guard listings.finish(request, for: key, freshFor: fresh) else { return }
        }
    }

    /// The folder for `container` in its engine's Containers folder, ready to browse. One made again under the same
    /// name (`docker compose up`) starts over: the old one's files aren't its.
    func open(_ container: ContainerInfo, on engine: ContainerEngine) async throws -> URL {
        let parent = try ContainerCopies.stackFolder(for: container, in: ContainerCopies.prepare(engine))
        let fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let recorded = fd >= 0 ? ContainerCopies.recordedSource(container.name, in: fd) : nil
        if fd >= 0 { close(fd) }
        if let recorded, recorded.id != container.id {
            await discard(parent.appending(path: container.name, directoryHint: .isDirectory))
        }
        return try ContainerCopies.prepare(container, on: engine)
    }

    /// The next `refresh` of `folder`, and of any folder in it, lists it again (Reload: columns and folders expanded in
    /// the list too), even one already under way.
    func invalidate(_ folder: URL) {
        let key = folder.resolvingSymlinksInPath().standardizedFileURL.path
        listings.invalidate(under: key)
    }

    /// Makes `url`, a path in a container's files, exist in its copy by listing the folders on the way to it from `/`
    /// (a mount's path, say, before it's been browsed). False when it isn't in the container.
    func reveal(_ url: URL) async -> Bool {
        guard let (_, top) = ContainerCopies.copy(containing: url), let path = ContainerCopies.containerPath(of: url, top: top) else { return false }
        var current = top
        for part in ContainerCopies.normalized(path) {
            await refresh(current)
            current = current.appending(path: part)
            var info = stat()
            // Links in a copy lead inside it; following them is fine.
            guard stat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }

    /// Lists and applies one folder; how long the result stays current, or nil when it failed.
    private func list(_ folder: URL, path: String, source: ContainerSource, top: URL) async -> TimeInterval? {
        let topKey = top.standardizedFileURL.path
        do {
            let result = try await readListing(source, path)
            let entries = result.entries, contents = result.contents, fresh = result.freshFor
            guard !closing.contains(topKey) else { return nil }
            let listed = entries, files = contents
            let eager = try await blocking { try CopyWriter.apply(listed, contents: files, to: folder, containerPath: path, top: top) }
            if modes.count > 200_000 { modes.removeAll() }
            for entry in entries where entry.kind == .file {
                modes[folder.appending(path: entry.name).standardizedFileURL.path] = entry.mode
            }
            if !contents.isEmpty { await Self.announce(Array(contents.keys).map { folder.appending(path: $0) }) }
            if !eager.isEmpty, !closing.contains(topKey) {
                let task = UUID()
                self.eager[topKey, default: [:]][task] = Task {
                    await self.fetchEagerly(eager, source: source, top: top)
                    self.eager[topKey]?[task] = nil
                }
            }
            return fresh
        } catch {
            await Self.report(error, folder: folder, source: source)
            return nil
        }
    }

    /// Small files of a folder just listed, a few at a time.
    private func fetchEagerly(_ urls: [URL], source: ContainerSource, top: URL) async {
        var fetched: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            var queue = urls[...]
            func next() -> Bool {
                guard !Task.isCancelled, let url = queue.popFirst() else { return false }
                group.addTask { (try? await self.fetchOne(url, source: source, top: top)) == true ? url : nil }
                return true
            }
            for _ in 0..<6 { _ = next() }
            for await url in group {
                if let url { fetched.append(url) }
                if fetched.count >= 64 {
                    await Self.announce(fetched)
                    fetched.removeAll()
                }
                _ = next()
            }
        }
        if !fetched.isEmpty { await Self.announce(fetched) }
    }

    /// Stops everything reading into the copy at `top` (and keeps anything new from starting), then removes the copy.
    func discard(_ top: URL) async {
        let path = top.standardizedFileURL.path
        if let running = removals[path] { await running.value; return }
        closing.insert(path)
        let task = Task {
            await self.drainAndRemove(top)
            self.removals[path] = nil
            self.closing.remove(path)
        }
        removals[path] = task
        await task.value
    }

    private func drainAndRemove(_ top: URL) async {
        let path = top.standardizedFileURL.path
        let inside: (String) -> Bool = { $0 == path || $0.hasPrefix(path + "/") }
        let background = Array((eager.removeValue(forKey: path) ?? [:]).values)
        let fetching = fetches.tasks(under: path)
        background.forEach { $0.cancel() }
        fetching.forEach { $0.cancel() }
        let listing = listings.tasks(under: path)
        for task in background { await task.value }
        for task in fetching { _ = try? await task.value }
        for task in listing { _ = await task.value }
        fetches.forget(under: path)
        listings.forget(under: path)
        modes = modes.filter { !inside($0.key) }
        await removeCopy(top)
    }

    /// Makes everything at `urls` complete before it's copied out: placeholders fetched, and folders with all they hold
    /// (not just what's been browsed), matching the container. Throws the first problem.
    func prepareForCopying(_ urls: [URL]) async throws {
        for url in urls where ContainerCopies.contains(url) {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                try await fetchTree(url)
            } else {
                try await fetch([url])
            }
        }
    }

    /// A folder with everything in it, from one archive stream (once: a second request waits for the first).
    private func fetchTree(_ folder: URL) async throws {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let (source, top) = ContainerCopies.copy(containing: real), let path = ContainerCopies.containerPath(of: real, top: top),
              !closing.contains(top.standardizedFileURL.path) else { return }
        let key = real.path
        try Task.checkCancellation()
        if let running = fetches.join(key, kind: .tree) { return try await join(running) }
        let request = fetches.request(key, kind: .tree) {
            Task {
                let stop = StopFlag()
                try await withTaskCancellationHandler {
                    try await readTree(source, path, real, stop)
                } onCancel: {
                    stop.set()
                }
            }
        }
        try await join(request)
        listings.expire(under: key)
    }

    /// The selected files worth fetching right away: placeholders everyone may read in the container, up to `limit`
    /// bytes in all.
    func fetchSelection(_ urls: [URL], limit: Int64) async {
        var total: Int64 = 0
        var chosen: [URL] = []
        for url in urls where ContainerCopies.isPlaceholder(url) {
            let key = url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).standardizedFileURL.path
            guard let mode = modes[key], mode & 0o004 != 0 else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            guard total + size <= limit else { break }
            total += size
            chosen.append(url)
        }
        try? await fetch(chosen)
    }

    /// Fetches `urls` that are still placeholders (opening, previewing or copying them). Throws the first problem.
    func fetch(_ urls: [URL]) async throws {
        var fetched: [URL] = []
        for url in urls where ContainerCopies.isPlaceholder(url) {
            try Task.checkCancellation()
            guard let (source, top) = ContainerCopies.copy(containing: url) else { continue }
            if try await fetchOne(url, source: source, top: top) { fetched.append(url) }
        }
        if !fetched.isEmpty { await Self.announce(fetched) }
    }

    /// One placeholder, once (a second request waits for the first). True when it was fetched now.
    private func fetchOne(_ requested: URL, source: ContainerSource, top: URL) async throws -> Bool {
        // Through a linked folder (`/bin` → `usr/bin` on most images): the real folder, which is in the same copy.
        let url = requested.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: requested.lastPathComponent)
        guard ContainerCopies.copy(containing: url)?.top.standardizedFileURL == top.standardizedFileURL else { return false }
        let key = url.standardizedFileURL.path
        try Task.checkCancellation()
        if let running = fetches.join(key) {
            try await join(running)
            return false
        }
        guard !closing.contains(top.standardizedFileURL.path), ContainerCopies.isPlaceholder(url),
              let path = ContainerCopies.containerPath(of: url, top: top) else { return false }
        let request = fetches.request(key) {
            Task {
                let stop = StopFlag()
                try await withTaskCancellationHandler {
                    try await readFile(source, path, url, stop)
                } onCancel: {
                    stop.set()
                }
            }
        }
        try await join(request)
        return true
    }

    /// Keep cancellation with its own wait; another preview or copy may still need the same download.
    private func join(_ request: CopyFetches.Request) async throws {
        defer { fetches.finish(request) }
        try await withTaskCancellationHandler {
            try await request.task.value
        } onCancel: {
            Task { await self.cancel(request) }
        }
    }

    private func cancel(_ request: CopyFetches.Request) { fetches.cancel(request) }

    private nonisolated static func loadListing(_ source: ContainerSource, path: String) async throws -> ContainerListingResult {
        let engine = source.engine, id = source.id
        do {
            let entries = try await blocking { try ContainerListing.viaShell(engine, id: id, path: path) }
            return ContainerListingResult(entries: entries, contents: [:], freshFor: freshFor)
        } catch let error as ContainerAPIError where error != .notFound && !engineIsGone(error) {
            // A stopped container, a missing shell, or restricted folder can still be read from its archive stream.
            let result = try await blocking { try ContainerListing.viaArchive(engine, id: id, path: path) }
            return ContainerListingResult(entries: result.entries, contents: result.contents, freshFor: archiveFreshFor)
        }
    }

    private static func engineIsGone(_ error: ContainerAPIError) -> Bool {
        if case .transport(.connect) = error { return true }
        return false
    }

    @MainActor
    private static func announce(_ urls: [URL]) {
        NotificationCenter.default.post(name: .containerFilesFetched, object: urls)
    }

    @MainActor
    private static func report(_ error: Error, folder: URL, source: ContainerSource) {
        NotificationCenter.default.post(name: .containerCopyProblem, object: nil,
                                        userInfo: ["folder": folder, "message": message(for: error, source: source)])
    }

    @MainActor
    private static func reportEngine(_ error: Error, folder: URL, engine: ContainerEngine) {
        let message: String = switch error as? ContainerAPIError {
        case .transport(.connect)?: String(localized: "\(engine.name) isn’t running.", comment: "Container files: the engine (Docker Desktop, OrbStack…) can’t be reached")
        case .transport(.timeout)?: String(localized: "\(engine.name) didn’t answer in time.", comment: "Container files: the engine took too long")
        default: String(localized: "Strata couldn’t list the containers on \(engine.name).", comment: "Containers folder: the engine's list couldn't be read; placeholder: Docker Desktop, OrbStack…")
        }
        NotificationCenter.default.post(name: .containerCopyProblem, object: nil, userInfo: ["folder": folder, "message": message])
    }

    /// What went wrong, in words.
    nonisolated static func message(for error: Error, source: ContainerSource) -> String {
        switch error as? ContainerAPIError {
        case .transport(.connect)?:
            return String(localized: "\(source.engineName) isn’t running.", comment: "Container files: the engine (Docker Desktop, OrbStack…) can’t be reached")
        case .notFound?:
            return String(localized: "“\(source.name)” no longer exists, or this folder is gone from it.", comment: "Container files: the container or the folder was removed")
        case .transport(.timeout)?:
            return String(localized: "\(source.engineName) didn’t answer in time.", comment: "Container files: the engine took too long")
        default:
            return String(localized: "Strata couldn’t read this folder from “\(source.name)”.", comment: "Container files: listing a folder failed")
        }
    }
}

/// Runs blocking work (sockets, files) off Swift's cooperative threads.
nonisolated func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Set once, read from anywhere: stops a blocking transfer.
nonisolated final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func set() { flag.store(true, ordering: .relaxed) }
    var isSet: Bool { flag.load(ordering: .relaxed) }
}

/// Listing a folder inside a container.
nonisolated enum ContainerListing {
    /// Lists the folder given as `$1`: for each item, its mode (hex), size, modification time and whether a link leads
    /// to a folder on one line, then its name and link target, each ending in NUL (names may hold anything but `/` and
    /// NUL). Exit 3: not a readable folder. Works with BusyBox and GNU tools.
    static let script = """
    cd -- "$1" || exit 3
    for f in * .[!.]* ..?*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      m=$(stat -c '%f %s %Y' -- "$f") || continue
      t=
      d=0
      if [ -L "$f" ]; then t=$(readlink -- "$f"); [ -d "$f" ] && d=1; fi
      printf '%s %s\\n%s\\0%s\\0' "$m" "$d" "$f" "$t"
    done
    """

    /// The most items a folder listing keeps.
    static let entryLimit = 100_000

    static func viaShell(_ engine: ContainerEngine, id: String, path: String) throws -> [ListedEntry] {
        let result = try ContainerAPI.exec(engine, id: id, command: ["/bin/sh", "-c", script, "sh", path])
        switch result.exitCode {
        case 0?: return parseShell(result.output)
        case 126?, 127?: throw ContainerAPIError.noShell
        default: throw ContainerAPIError.status(result.exitCode ?? -1, "")
        }
    }

    /// Parses the script's output; anything malformed ends the list there.
    static func parseShell(_ data: Data) -> [ListedEntry] {
        var entries: [ListedEntry] = []
        var index = data.startIndex
        while index < data.endIndex, entries.count < entryLimit {
            guard let newline = data[index...].firstIndex(of: 0x0A) else { break }
            let fields = String(decoding: data[index..<newline], as: UTF8.self).split(separator: " ")
            // Whole numbers only: a container's own `stat` could print anything.
            guard fields.count == 3 || fields.count == 4, let raw = UInt32(fields[0], radix: 16), let parsedSize = Int64(fields[1]),
                  let seconds = Int64(fields[2]) else { break }
            let size = ListedEntry.saneSize(parsedSize)
            let leadsToFolder = fields.count == 4 && fields[3] == "1"
            guard let nameEnd = data[(newline + 1)...].firstIndex(of: 0),
                  let targetEnd = data[(nameEnd + 1)...].firstIndex(of: 0) else { break }
            let name = String(decoding: data[(newline + 1)..<nameEnd], as: UTF8.self)
            let target = String(decoding: data[(nameEnd + 1)..<targetEnd], as: UTF8.self)
            index = targetEnd + 1
            let kind: ListedEntry.Kind = switch raw & UInt32(S_IFMT) {
            case UInt32(S_IFDIR): .directory
            case UInt32(S_IFREG): .file
            case UInt32(S_IFLNK): .symlink
            default: .other
            }
            entries.append(ListedEntry(name: name, kind: kind, size: kind == .file ? max(size, 0) : 0, mode: raw & 0o7777,
                                       modified: ContainerTime.date(Double(seconds)), linkTarget: kind == .symlink ? target : "",
                                       targetIsDirectory: kind == .symlink && leadsToFolder))
        }
        return entries
    }

    /// Lists the folder from its archive stream (the whole folder streams past; only its own items are kept), with the
    /// contents of its small world-readable files. Gives up after `ContainerFiles.archiveBudget`.
    static func viaArchive(_ engine: ContainerEngine, id: String, path: String) throws -> (entries: [ListedEntry], contents: [String: Data]) {
        var reader = TarReader()
        var root: String?
        var entries: [ListedEntry] = []
        var contents: [String: Data] = [:]
        var collecting: (name: String, data: Data)?
        var eagerBytes: Int64 = 0
        /// Files' sizes by their path in the stream, for hardlinks (which carry none).
        var sizes: [String: Int64] = [:]
        /// Folders in the stream (below its top), to tell which links lead to one.
        var folders = Set<String>()
        try ContainerAPI.archive(engine, id: id, path: path, total: ContainerFiles.archiveBudget) { chunk in
            try reader.feed(chunk) { event in
                switch event {
                case .begin(let entry):
                    collecting = nil
                    let name = CopyWriter.streamName(entry.path)
                    guard let base = root else {
                        // The first entry is the folder itself.
                        root = entry.kind == .directory ? name : "\u{0}"
                        return
                    }
                    if entry.kind == .file, sizes.count < 500_000 { sizes[name] = entry.size }
                    if entry.kind == .directory, folders.count < 500_000, let inner = CopyWriter.relative(name, to: base) { folders.insert(String(inner)) }
                    guard let rest = CopyWriter.relative(name, to: base), !rest.isEmpty, !rest.contains("/"),
                          entries.count < entryLimit else { return }
                    let kind: ListedEntry.Kind = switch entry.kind {
                    case .file, .hardlink: .file
                    case .directory: .directory
                    case .symlink: .symlink
                    case .other: .other
                    }
                    let size = entry.kind == .hardlink ? sizes[CopyWriter.streamName(entry.linkTarget)] ?? 0 : entry.size
                    entries.append(ListedEntry(name: String(rest), kind: kind, size: size, mode: entry.mode,
                                               modified: entry.modified, linkTarget: entry.kind == .symlink ? entry.linkTarget : ""))
                    if entry.kind == .file, CopyWriter.fetchesEagerly(size: entry.size, mode: entry.mode, bytes: eagerBytes, count: contents.count) {
                        eagerBytes += entry.size
                        collecting = (String(rest), Data())
                    }
                case .data(let data):
                    collecting?.data.append(data)
                case .end:
                    if let file = collecting { contents[file.name] = file.data }
                    collecting = nil
                }
            }
            return !reader.isFinished
        }
        // Links leading to a folder in what streamed past.
        let folder = ContainerCopies.normalized(path)
        entries = entries.map { entry in
            guard entry.kind == .symlink else { return entry }
            let target = ContainerCopies.normalized(entry.linkTarget, from: folder)
            guard target.count > folder.count, Array(target.prefix(folder.count)) == folder,
                  folders.contains(target.dropFirst(folder.count).joined(separator: "/")) else { return entry }
            var linked = entry
            linked.targetIsDirectory = true
            return linked
        }
        return (entries, contents)
    }
}

/// Writes listings and fetched files into a copy. Every step works relative to an open folder descriptor and never
/// follows a link, so nothing lands outside the copy whatever a container's names and links say.
nonisolated enum CopyWriter {
    private static let tempPrefix = ".strata-fetch-"

    /// Whether a listed file is fetched with its listing: small, world-readable (a secret only its owner may read waits
    /// until it's opened), and within the folder's budget.
    static func fetchesEagerly(size: Int64, mode: UInt32, bytes: Int64, count: Int) -> Bool {
        size <= ContainerFiles.eagerFileSize && mode & 0o004 != 0
            && bytes + size <= ContainerFiles.eagerFolderBytes && count < ContainerFiles.eagerFolderCount
    }

    /// A name in an archive stream without its leading `/`.
    static func streamName(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.drop { $0 == "/" }) : path
    }

    /// `name` below the stream's top folder `base` ("" for `/`); nil outside it.
    static func relative(_ name: String, to base: String) -> Substring? {
        if base.isEmpty { return Substring(name) }
        return name.hasPrefix(base + "/") ? name.dropFirst(base.count + 1) : nil
    }

    /// The copy's disk tells `Foo` from `foo`? (Linux does; a Mac's usually doesn't.)
    static let isCaseSensitive: Bool = {
        let probe = FileManager.default.fileExists(atPath: ContainerCopies.root.path) ? ContainerCopies.root
            : ContainerCopies.root.deletingLastPathComponent()
        return pathconf(probe.path, _PC_CASE_SENSITIVE) == 1
    }()

    /// How the copy's disk compares names: two names that fold the same are one item there.
    static func folded(_ name: String) -> String {
        isCaseSensitive ? name : name.decomposedStringWithCanonicalMapping.lowercased()
    }

    /// Makes the Containers `folder` match `containers`. A Compose project's containers go in a folder named after the
    /// project; the rest stay beside those. Returns the folders to discard: containers gone, and ones made again under
    /// the same name (made afresh after). A container that moved into its project keeps the files already fetched.
    static func syncContainers(_ containers: [ContainerInfo], engine: ContainerEngine, in folder: URL) throws -> [URL] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        let looseNames = Set(containers.compactMap { container -> String? in
            guard ContainerCopies.stackName(container) == nil, ContainerCopies.isContainerName(container.name) else { return nil }
            return folded(container.name)
        })
        // By the name as the disk sees it: projects whose names differ only in case share one folder (named the first
        // way seen) rather than one of them going missing.
        var byStack: [String: (project: String, members: [ContainerInfo])] = [:]
        var loose: [ContainerInfo] = []
        for container in containers where ContainerCopies.isContainerName(container.name) {
            if let project = ContainerCopies.stackName(container), !looseNames.contains(folded(project)) {
                byStack[folded(project), default: (project, [])].members.append(container)
            } else {
                loose.append(container)
            }
        }
        var keep = Set<String>()
        var gone: [URL] = []
        func place(_ container: ContainerInfo, in parent: Int32, at parentURL: URL, keeping: inout Set<String>) {
            guard keeping.insert(folded(container.name)).inserted else { return }
            if let recorded = ContainerCopies.recordedSource(container.name, in: parent), recorded.id != container.id {
                gone.append(parentURL.appending(path: container.name, directoryHint: .isDirectory))
                return
            }
            try? ContainerCopies.record(container, on: engine, in: parent, folder: parentURL)
        }
        for container in loose { place(container, in: fd, at: folder, keeping: &keep) }
        for (key, stack) in byStack {
            let (project, members) = stack
            guard keep.insert(key).inserted else { continue }
            // The project name is already a container folder. Move that container aside when it belongs inside the
            // project. Otherwise it's a container that's gone, renamed or now in another project (a container with
            // that name still on its own keeps it: see `looseNames`), so it's discarded and the next pass makes the
            // project's folder; until then its containers stay beside the stacks.
            var held: String?
            if let recorded = ContainerCopies.recordedSource(project, in: fd) {
                let movesIn = members.contains { $0.id == recorded.id && $0.name == project }
                guard movesIn else {
                    gone.append(folder.appending(path: project, directoryHint: .isDirectory))
                    for container in members where folded(container.name) != key {
                        place(container, in: fd, at: folder, keeping: &keep)
                    }
                    continue
                }
                let temp = ".hold-" + String(UUID().uuidString.prefix(8))
                if renameat(fd, project, fd, temp) == 0 {
                    held = temp
                    ContainerCopies.forget(folder.appending(path: project).standardizedFileURL.path)
                }
            }
            mkdirat(fd, project, 0o755)
            let child = openat(fd, project, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            defer { close(child) }
            let stack = folder.appending(path: project, directoryHint: .isDirectory)
            if let held {
                if renameat(fd, held, child, project) == 0 {
                    ContainerCopies.forget(folder.appending(path: held).standardizedFileURL.path)
                }
            }
            var keepChild = Set<String>()
            for container in members {
                bringDown(container, from: fd, to: child, stack: stack, engineFolder: folder)
                place(container, in: child, at: stack, keeping: &keepChild)
            }
            for name in names(in: child) where !keepChild.contains(folded(name)) {
                gone.append(stack.appending(path: name, directoryHint: .isDirectory))
            }
        }
        for name in names(in: fd) where !keep.contains(folded(name)) {
            gone.append(folder.appending(path: name, directoryHint: .isDirectory))
        }
        return gone
    }

    /// Moves a container's folder from the engine's folder into its project, when an older layout left it there.
    private static func bringDown(_ container: ContainerInfo, from engineFD: Int32, to stackFD: Int32, stack: URL, engineFolder: URL) {
        var info = stat()
        guard fstatat(stackFD, container.name, &info, AT_SYMLINK_NOFOLLOW) != 0 else { return }
        guard fstatat(engineFD, container.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { return }
        guard let recorded = ContainerCopies.recordedSource(container.name, in: engineFD), recorded.id == container.id else { return }
        guard renameat(engineFD, container.name, stackFD, container.name) == 0 else { return }
        ContainerCopies.forget(engineFolder.appending(path: container.name).standardizedFileURL.path)
    }

    /// Makes `folder` match `entries`: folders and links made, files as placeholders (or written, from `contents`),
    /// items no longer there removed. Names the copy's disk can't tell apart from an earlier one are left out. A link
    /// leading to a folder gets that folder made (empty, inside `top`) so it shows and opens as one. Returns
    /// placeholders to fetch right away.
    static func apply(_ entries: [ListedEntry], contents: [String: Data], to folder: URL, containerPath: String, top: URL? = nil) throws -> [URL] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer {
            // Writing in it changed its date; the container's comes back.
            restoreTimes(fd)
            close(fd)
        }
        let topFD = top.map { open($0.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        defer { if topFD >= 0 { close(topFD) } }
        let existing = names(in: fd)
        var listed = Set<String>()
        var eager: [URL] = []
        var eagerBytes: Int64 = 0
        let base = containerPath == "/" ? "" : containerPath
        for entry in entries where ContainerCopies.isSafeName(entry.name) && !entry.name.hasPrefix(tempPrefix) {
            let name = entry.name
            guard entry.kind != .other, listed.insert(folded(name)).inserted else { continue }
            var info = stat()
            var exists = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            let type = exists ? info.st_mode & S_IFMT : 0
            switch entry.kind {
            case .directory:
                if exists, type != S_IFDIR { removeAt(fd, name); exists = false }
                if !exists { mkdirat(fd, name, 0o755) }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 {
                    // A folder can be an app (`Foo.app`): marked like the files.
                    try? markDownloaded(child)
                    remember(entry.modified, onFolder: child)
                    close(child)
                }
            case .symlink:
                guard let target = ContainerCopies.copyLinkTarget(entry.linkTarget, at: base + "/" + name) else { continue }
                if entry.targetIsDirectory, topFD >= 0 {
                    makeFolders(topFD, ContainerCopies.normalized(entry.linkTarget, from: ContainerCopies.normalized(base)))
                }
                if exists, type == S_IFLNK, linkTarget(name, fd: fd) == target { continue }
                if exists { removeAt(fd, name) }
                symlinkat(target, fd, name)
                setLinkTimes(fd, name, entry.modified)
            case .file:
                let same = exists && type == S_IFREG && Int64(info.st_size) == entry.size
                    && Int(info.st_mtimespec.tv_sec) == ContainerTime.seconds(entry.modified)
                let placeholder = same && ContainerCopies.isPlaceholderMode(info.st_mode)
                // A placeholder follows the container's execute bits (`chmod +x` changes neither size nor date).
                if placeholder, info.st_mode & 0o111 != mode_t(entry.mode & 0o111) {
                    fchmodat(fd, name, mode_t(entry.mode & 0o111), AT_SYMLINK_NOFOLLOW)
                }
                if let data = contents[name] {
                    if same, !placeholder { continue }
                    if exists, type != S_IFREG { removeAt(fd, name) }
                    try write(data, as: name, fd: fd, mode: entry.mode, modified: entry.modified)
                    continue
                }
                if !same {
                    if exists { removeAt(fd, name) }
                    try makePlaceholder(name, fd: fd, size: entry.size, mode: entry.mode, modified: entry.modified)
                }
                if !same || placeholder, fetchesEagerly(size: entry.size, mode: entry.mode, bytes: eagerBytes, count: eager.count) {
                    eagerBytes += entry.size
                    eager.append(folder.appending(path: name))
                }
            case .other:
                continue
            }
        }
        for name in existing where !listed.contains(folded(name)) && !name.hasPrefix(tempPrefix) {
            removeAt(fd, name)
        }
        return eager
    }

    /// Streams the container's file at `containerPath` into the placeholder at `url`, replacing it when complete.
    static func fetchFile(_ engine: ContainerEngine, id: String, containerPath: String, to url: URL, stop: StopFlag) throws {
        let folder = url.deletingLastPathComponent()
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        try fetchFile(engine, id: id, containerPath: containerPath, into: fd, name: url.lastPathComponent, stop: stop)
    }

    /// The same, into the folder open at `fd`.
    private static func fetchFile(_ engine: ContainerEngine, id: String, containerPath: String, into fd: Int32, name: String, stop: StopFlag) throws {
        let temp = tempPrefix + UUID().uuidString
        var out: Int32 = -1
        var reader = TarReader()
        var entry: TarEntry?
        var done = false
        defer {
            if out >= 0 { close(out) }
            if !done { unlinkat(fd, temp, 0) }
        }
        try ContainerAPI.archive(engine, id: id, path: containerPath, shouldStop: { stop.isSet }) { chunk in
            try reader.feed(chunk) { event in
                switch event {
                case .begin(let first):
                    guard entry == nil else { return }
                    entry = first
                    if first.kind == .file {
                        out = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
                        try markDownloaded(out)
                    }
                case .data(let data):
                    // Only the first entry's: anything after it in the stream isn't this file.
                    guard out >= 0, !done else { return }
                    try writeAll(data, to: out)
                case .end:
                    done = entry != nil
                }
            }
            return !done
        }
        guard done, let entry, entry.kind == .file, out >= 0 else {
            done = false
            throw ContainerAPIError.notFound
        }
        fchmod(out, mode_t(readable(entry.mode)))
        setTimes(out, entry.modified)
        close(out)
        out = -1
        // Only over the placeholder: if the folder was listed again meanwhile and it's something else now, leave that.
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
              renameat(fd, temp, fd, name) == 0 else {
            done = false
            return
        }
        restoreTimes(fd)
    }

    /// A link's own date (not what it points to).
    private static func setLinkTimes(_ fd: Int32, _ name: String, _ date: Date?) {
        guard let date, let seconds = Optional(date.timeIntervalSince1970), seconds.isFinite, abs(seconds) < 1e11 else { return }
        let spec = timespec(tv_sec: Int(seconds.rounded(.down)), tv_nsec: 0)
        var times = [spec, spec]
        utimensat(fd, name, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// The extended attribute holding a copy folder's date in the container.
    private static let dateAttribute = "dev.strata.modified"

    /// Gives the folder open at `fd` its date in the container, and remembers it for after Strata writes into it.
    static func remember(_ date: Date?, onFolder fd: Int32) {
        guard let date, ContainerTime.date(date.timeIntervalSince1970) != nil else { return }
        let text = String(date.timeIntervalSince1970)
        _ = text.withCString { fsetxattr(fd, dateAttribute, $0, strlen($0), 0, 0) }
        setTimes(fd, date)
    }

    /// Sets the folder open at `fd` back to its date in the container (if it has one).
    static func restoreTimes(_ fd: Int32) {
        var buffer = [CChar](repeating: 0, count: 64)
        let count = fgetxattr(fd, dateAttribute, &buffer, 63, 0, 0)
        guard count > 0, let seconds = Double(String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)),
              let date = ContainerTime.date(seconds) else { return }
        setTimes(fd, date)
    }

    /// Makes the folders at `parts` below `fd` (a link's target), stopping at anything that isn't a folder or is a link.
    private static func makeFolders(_ fd: Int32, _ parts: [String]) {
        guard !parts.isEmpty, parts.count <= 64, parts.allSatisfy({ ContainerCopies.isSafeName($0) && !$0.hasPrefix(tempPrefix) }) else { return }
        var current = fd
        defer { if current != fd { close(current) } }
        for part in parts {
            var info = stat()
            if fstatat(current, part, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard mkdirat(current, part, 0o755) == 0 else { return }
            } else if info.st_mode & S_IFMT != S_IFDIR {
                return
            }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if current != fd { close(current) }
            current = fd
            guard next >= 0 else { return }
            try? markDownloaded(next)
            current = next
        }
    }

    /// Writes the container's folder at `containerPath`, with everything in it, into `folder` (its copy), then removes
    /// what the container no longer has.
    static func writeTree(_ engine: ContainerEngine, id: String, containerPath: String, into folder: URL, stop: StopFlag) throws {
        let rootFD = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw CocoaError(.fileReadNoPermission) }
        /// The folders open along the current entry's path (a tar stream goes depth first).
        var stack: [(name: String, fd: Int32)] = []
        defer {
            stack.forEach { close($0.fd) }
            close(rootFD)
        }
        /// Every item written, by its folded path (see `folded`), with its spelling.
        var seen: [String: String] = [:]
        var hardlinks: [(parts: [String], target: String)] = []
        /// Folders' dates in the container, set once everything is written into them.
        var folderDates: [(parts: [String], date: Date?)] = []
        var reader = TarReader()
        var root: String?
        var file: (fd: Int32, parent: Int32, temp: String, name: String, entry: TarEntry)?
        let base = containerPath == "/" ? "" : containerPath

        /// The folder for `parts` (made if needed, never through a link), with the stack kept to that path.
        func folderFD(_ parts: ArraySlice<String>) throws -> Int32 {
            var common = 0
            while common < stack.count, common < parts.count, stack[common].name == parts[parts.startIndex + common] { common += 1 }
            while stack.count > common { close(stack.removeLast().fd) }
            for part in parts.dropFirst(common) {
                let parent = stack.last?.fd ?? rootFD
                var info = stat()
                if fstatat(parent, part, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT != S_IFDIR {
                    removeAt(parent, part)
                }
                mkdirat(parent, part, 0o755)
                let fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
                stack.append((part, fd))
                try markDownloaded(fd)
            }
            return stack.last?.fd ?? rootFD
        }

        defer {
            if let open = file {
                close(open.fd)
                unlinkat(open.parent, open.temp, 0)
            }
        }
        try ContainerAPI.archive(engine, id: id, path: containerPath, shouldStop: { stop.isSet }) { chunk in
            try reader.feed(chunk) { event in
                switch event {
                case .begin(let entry):
                    let name = streamName(entry.path)
                    guard let rootName = root else {
                        root = entry.kind == .directory ? name : "\u{0}"
                        return
                    }
                    guard let rest = relative(name, to: rootName) else { return }
                    let parts = rest.split(separator: "/").map(String.init)
                    guard !parts.isEmpty, entry.kind != .other,
                          parts.allSatisfy({ ContainerCopies.isSafeName($0) && !$0.hasPrefix(tempPrefix) }) else { return }
                    // Two names the copy's disk can't tell apart: the first one wins.
                    let path = parts.joined(separator: "/")
                    let key = parts.map(folded).joined(separator: "/")
                    if let spelling = seen[key], spelling != path { return }
                    guard parts.dropLast().indices.allSatisfy({ seen[parts[...$0].map(folded).joined(separator: "/")] == parts[...$0].joined(separator: "/")
                        || seen[parts[...$0].map(folded).joined(separator: "/")] == nil }) else { return }
                    seen[key] = path
                    let parent = try folderFD(parts.dropLast()[...])
                    let last = parts[parts.count - 1]
                    switch entry.kind {
                    case .directory:
                        _ = try folderFD(parts[...])
                        folderDates.append((parts, entry.modified))
                    case .symlink:
                        guard let target = ContainerCopies.copyLinkTarget(entry.linkTarget, at: base + "/" + path) else { return }
                        if linkTarget(last, fd: parent) == target { return }
                        removeAt(parent, last)
                        symlinkat(target, parent, last)
                        setLinkTimes(parent, last, entry.modified)
                    case .hardlink:
                        // Linked to its first name once the stream is through (hardlinks carry no data).
                        hardlinks.append((parts, streamName(entry.linkTarget)))
                    case .file:
                        var info = stat()
                        if fstatat(parent, last, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, !ContainerCopies.isPlaceholderMode(info.st_mode),
                           Int64(info.st_size) == entry.size, Int(info.st_mtimespec.tv_sec) == ContainerTime.seconds(entry.modified) {
                            return  // Already here.
                        }
                        let temp = tempPrefix + UUID().uuidString
                        let out = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
                        file = (out, parent, temp, last, entry)
                        try markDownloaded(out)
                    case .other:
                        return
                    }
                case .data(let data):
                    if let open = file { try writeAll(data, to: open.fd) }
                case .end:
                    guard let open = file else { return }
                    file = nil
                    fchmod(open.fd, mode_t(readable(open.entry.mode)))
                    setTimes(open.fd, open.entry.modified)
                    close(open.fd)
                    var info = stat()
                    if fstatat(open.parent, open.name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR {
                        removeAt(open.parent, open.name)
                    }
                    if renameat(open.parent, open.temp, open.parent, open.name) != 0 { unlinkat(open.parent, open.temp, 0) }
                }
            }
            return !reader.isFinished
        }
        guard let rootName = root, rootName != "\u{0}" else { throw ContainerAPIError.notFound }
        // A stream cut short says nothing about what's gone.
        guard reader.isFinished else { throw ContainerAPIError.transport(.closed) }
        stack.forEach { close($0.fd) }
        stack.removeAll()
        for link in hardlinks {
            guard let targetRest = relative(link.target, to: rootName) else { continue }
            let targetParts = targetRest.split(separator: "/").map(String.init)
            guard !targetParts.isEmpty, targetParts.allSatisfy(ContainerCopies.isSafeName) else { continue }
            let linkDir = try folderFD(link.parts.dropLast()[...])
            let name = link.parts[link.parts.count - 1]
            var linked = false
            if let targetDir = openPath(rootFD, targetParts.dropLast()[...]) {
                removeAt(linkDir, name)
                linked = linkat(targetDir, targetParts[targetParts.count - 1], linkDir, name, 0) == 0
                if targetDir != rootFD { close(targetDir) }
            }
            if !linked {
                // Its first name is outside this folder: fetch it on its own.
                removeAt(linkDir, name)
                let path = base + "/" + link.parts.joined(separator: "/")
                if (try? makePlaceholder(name, fd: linkDir, size: 0, mode: 0, modified: nil)) != nil {
                    try fetchFile(engine, id: id, containerPath: path, into: linkDir, name: name, stop: stop)
                }
            }
        }
        stack.forEach { close($0.fd) }
        stack.removeAll()
        sweep(rootFD, prefix: "", keeping: seen)
        for folder in folderDates.reversed() {
            guard let fd = openPath(rootFD, folder.parts[...]) else { continue }
            remember(folder.date, onFolder: fd)
            if fd != rootFD { close(fd) }
        }
        restoreTimes(rootFD)
    }

    /// Removes what's in the folder open at `fd` but not in `keeping` (folded paths), recursively and without following
    /// links.
    private static func sweep(_ fd: Int32, prefix: String, keeping: [String: String]) {
        for name in names(in: fd) where !name.hasPrefix(tempPrefix) {
            let key = prefix + folded(name)
            guard keeping[key] != nil else {
                removeAt(fd, name)
                continue
            }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            sweep(child, prefix: key + "/", keeping: keeping)
            close(child)
        }
    }

    /// The folder at `parts` below `fd`, opened without following links (nil if any part isn't a folder).
    private static func openPath(_ fd: Int32, _ parts: ArraySlice<String>) -> Int32? {
        var current = fd
        for part in parts {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if current != fd { close(current) }
            guard next >= 0 else { return nil }
            current = next
        }
        return current
    }

    private static func write(_ data: Data, as name: String, fd: Int32, mode: UInt32, modified: Date?) throws {
        let temp = tempPrefix + UUID().uuidString
        let out = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        do {
            try markDownloaded(out)
            try writeAll(data, to: out)
        } catch {
            close(out)
            unlinkat(fd, temp, 0)
            throw error
        }
        fchmod(out, mode_t(readable(mode)))
        setTimes(out, modified)
        close(out)
        if renameat(fd, temp, fd, name) != 0 {
            unlinkat(fd, temp, 0)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func makePlaceholder(_ name: String, fd: Int32, size: Int64, mode: UInt32, modified: Date?) throws {
        let out = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(out) }
        // Sparse: the right size, without taking the space.
        ftruncate(out, off_t(max(size, 0)))
        setTimes(out, modified)
        // Unreadable until fetched; a program keeps its execute bits, so it shows as one (its kind and icon).
        fchmod(out, mode_t(mode & 0o111))
    }

    /// Fetched files are readable by you whatever the container said, and read-only (an edit saved into a copy would
    /// be lost at the next listing); no set-ID bits.
    static func readable(_ mode: UInt32) -> UInt32 { (mode & 0o555) | 0o400 }

    /// A container's or a server's files come from another machine, so they're marked as downloaded: Gatekeeper checks
    /// an app, script or `.command` from one before it runs, and copies keep the mark, as Finder's do. The mark is the one
    /// macOS itself gives a download made by Strata (asked once, through its quarantine API), so it's always what this
    /// macOS expects; "0281;…;Strata;…" on macOS 26, and that as a fallback.
    static let quarantine: [UInt8] = systemQuarantine()
        ?? Array("0281;\(String(Int(Date().timeIntervalSince1970), radix: 16));Strata;\(UUID().uuidString)".utf8)

    /// The mark macOS writes for a download by this app, read back from a scratch file. Nil unless it's one that says
    /// "downloaded" and not "already approved".
    static func systemQuarantine() -> [UInt8]? {
        let probe = FileManager.default.temporaryDirectory.appending(path: "strata-quarantine-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        defer { unlink(probe.path) }
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Strata",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        var url = probe
        guard (try? url.setResourceValues(values)) != nil else { return nil }
        let size = getxattr(probe.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 5, size < 512 else { return nil }
        var mark = [UInt8](repeating: 0, count: size)
        guard getxattr(probe.path, "com.apple.quarantine", &mark, size, 0, XATTR_NOFOLLOW) == size,
              mark[4] == UInt8(ascii: ";"), let flags = UInt32(String(decoding: mark[0..<4], as: UTF8.self), radix: 16),
              flags & 0x0001 != 0, flags & 0x0040 == 0 else { return nil }
        // Flags; time; the app that downloaded it; the download's ID. The app is named when macOS left it out.
        var fields = String(decoding: mark, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { return nil }
        if fields[2].isEmpty { fields[2] = "Strata" }
        return Array(fields.joined(separator: ";").utf8)
    }

    /// Marks the file or folder open at `fd` as downloaded (see `quarantine`). Throws when it can't be, so nothing
    /// unmarked is placed; disks that can't keep the mark at all are the exception.
    static func markDownloaded(_ fd: Int32) throws {
        guard fsetxattr(fd, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) != 0, errno != ENOTSUP else { return }
        throw CocoaError(.fileWriteNoPermission)
    }

    private static func setTimes(_ fd: Int32, _ date: Date?) {
        guard let date, let seconds = Optional(date.timeIntervalSince1970), seconds.isFinite, abs(seconds) < 1e11 else { return }
        let whole = seconds.rounded(.down)
        let spec = timespec(tv_sec: Int(whole), tv_nsec: min(999_999_999, max(0, Int((seconds - whole) * 1e9))))
        var times = [spec, spec]
        futimens(fd, &times)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
                offset += written
            }
        }
    }

    private static func linkTarget(_ name: String, fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4097)
        let count = readlinkat(fd, name, &buffer, 4096)
        guard count >= 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The names in the folder open at `fd` (without `.` and `..`).
    static func names(in fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        // A copy of `fd` shares its place in the folder: from the start, whoever read it before.
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Removes an item of the folder open at `fd` (a folder with all it holds), never following a link.
    static func removeAt(_ fd: Int32, _ name: String) {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            fchmodat(fd, name, 0o755, 0)
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child >= 0 {
                for item in names(in: child) { removeAt(child, item) }
                close(child)
            }
            unlinkat(fd, name, AT_REMOVEDIR)
        } else {
            unlinkat(fd, name, 0)
        }
    }
}
