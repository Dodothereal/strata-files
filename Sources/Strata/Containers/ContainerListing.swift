import Darwin
import Foundation
import Synchronization

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

extension ContainerFiles {
    nonisolated static func loadListing(_ source: ContainerSource, path: String) async throws -> ContainerListingResult {
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

    private nonisolated static func engineIsGone(_ error: ContainerAPIError) -> Bool {
        if case .transport(.connect) = error { return true }
        return false
    }

    @MainActor
    static func announce(_ urls: [URL]) {
        NotificationCenter.default.post(name: .containerFilesFetched, object: urls)
    }

    @MainActor
    static func report(_ error: Error, folder: URL, source: ContainerSource, copyRoot: String) {
        NotificationCenter.default.post(name: .containerCopyProblem, object: nil,
                                        userInfo: ["folder": folder, "message": message(for: error, source: source), "copyRoot": copyRoot])
    }

    @MainActor
    static func reportEngine(_ error: Error, folder: URL, engine: ContainerEngine, copyRoot: String) {
        let message: String = switch error as? ContainerAPIError {
        case .transport(.connect)?: String(localized: "\(engine.name) isn’t running.", comment: "Container files: the engine (Docker Desktop, OrbStack…) can’t be reached")
        case .transport(.timeout)?: String(localized: "\(engine.name) didn’t answer in time.", comment: "Container files: the engine took too long")
        default: String(localized: "Strata couldn’t list the containers on \(engine.name).", comment: "Containers folder: the engine's list couldn't be read; placeholder: Docker Desktop, OrbStack…")
        }
        NotificationCenter.default.post(name: .containerCopyProblem, object: nil,
                                        userInfo: ["folder": folder, "message": message, "copyRoot": copyRoot])
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
