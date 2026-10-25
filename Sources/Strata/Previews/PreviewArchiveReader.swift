import Foundation
import StrataModel
import StrataSupport

nonisolated package enum PreviewArchiveError: Error, LocalizedError {
    case password, limit, unsafe, unreadable, encryption, needsExtraction
    package var errorDescription: String? {
        switch self {
        case .needsExtraction: String(localized: "Extract the archive first to preview or copy this item.")
        case .encryption: String(localized: "This archive’s encryption isn’t supported.")
        case .password: String(localized: "The archive password wasn’t accepted.")
        case .limit: String(localized: "This selection is too large to preview or copy here.")
        case .unsafe: String(localized: "This archive contains unsafe or ambiguous paths.")
        case .unreadable: String(localized: "This archive couldn’t be read.")
        }
    }
}

/// Pins the chosen archive before any password sheet or worker starts. Contents must stay unchanged too.
nonisolated package final class PreviewArchiveSource: Sendable {
    package let chosen: ChosenFile
    private let stamp: Stamp
    private struct Stamp: Equatable, Sendable {
        let identity: FileIdentity
        let size: Int64
        let modified: timespec
        let changed: timespec
        init(_ info: stat) {
            identity = .from(info); size = info.st_size; modified = info.st_mtimespec; changed = info.st_ctimespec
        }
        package static func == (a: Self, b: Self) -> Bool {
            a.identity == b.identity && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
                && a.modified.tv_nsec == b.modified.tv_nsec && a.changed.tv_sec == b.changed.tv_sec
                && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }
    package init(_ url: URL) throws {
        guard url.isFileURL else { throw PreviewArchiveError.unreadable }
        chosen = try ChosenFile(url)
        stamp = try chosen.withParent { _, _, info in
            guard info.st_mode & S_IFMT == S_IFREG else { throw PreviewArchiveError.unreadable }
            return Stamp(info)
        }
    }
    package func open() throws -> FileHandle {
        try chosen.withParent { parent, name, _ in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw PreviewArchiveError.unreadable }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Stamp(info) == stamp else {
                close(fd); throw POSIXError(.ESTALE)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }
    package func verify(_ file: FileHandle) throws {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, Stamp(info) == stamp else { throw POSIXError(.ESTALE) }
        try chosen.withParent { _, _, current in
            guard Stamp(current) == stamp else { throw POSIXError(.ESTALE) }
        }
    }
}

nonisolated package struct PreviewArchiveRecord: Sendable {
    package let path: [String]
    package let kind: UInt8
    package let size: Int64
    package let modified: Date
    package let body: Data?
    package init(path: [String], kind: UInt8, size: Int64, modified: Date, body: Data?) {
        self.path = path; self.kind = kind; self.size = size; self.modified = modified; self.body = body
    }
}

/// Parses only the worker's bounded, length-delimited protocol. Text command listings never authorize extraction.
nonisolated package enum PreviewArchiveReader {
    package static let previewLimit = 32 << 20
    package static let outputLimit = 60 << 20

    package static var executable: URL {
        let bundle = Bundle(for: PreviewArchiveBundle.self)
        if bundle.bundleURL.pathExtension == "app" {
            return bundle.bundleURL.appendingPathComponent("Contents/Helpers/StrataArchiveWorker")
        }
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("StrataArchiveWorker")
    }

    @concurrent package static func read(_ source: PreviewArchiveSource, member: [String]? = nil, directory: Bool = false,
                                password: String? = nil) async throws -> [PreviewArchiveRecord] {
        let allowance = ArchiveReadAllowance.shared, id = UUID()
        try await withTaskCancellationHandler {
            try await allowance.enter(id)
        } onCancel: { Task { await allowance.cancel(id) } }
        defer { Task { await allowance.leave() } }
        try Task.checkCancellation()
        let path = member?.joined(separator: "/") ?? ""
        guard path.utf8.count <= 4096, (password?.utf8.count ?? 0) <= 1024,
              !path.utf8.contains(0), !(password?.utf8.contains(0) ?? false) else { throw PreviewArchiveError.limit }
        let file = try source.open()
        defer { try? file.close() }
        var input = Data([member == nil ? 0 : 1, directory ? 1 : 0])
        for count in [path.utf8.count, password?.utf8.count ?? 0] {
            var length = UInt32(count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
        }
        input.append(contentsOf: path.utf8)
        if let password { input.append(contentsOf: password.utf8) }
        defer { input.resetBytes(in: 0..<input.count) }
        let run = try await ProcessRunner.run(executable.path, [], timeout: 20, input: input, file: file)
        try Task.checkCancellation()
        try source.verify(file)
        guard !run.timedOut, !run.truncated, run.output.count <= outputLimit else { throw PreviewArchiveError.limit }
        switch run.status {
        case 0: break
        case 40: throw PreviewArchiveError.password
        case 41: throw PreviewArchiveError.limit
        case 42: throw PreviewArchiveError.unsafe
        case 45: throw PreviewArchiveError.encryption
        case 46: throw PreviewArchiveError.needsExtraction
        default: throw PreviewArchiveError.unreadable
        }
        return try parse(run.output, member: member, directory: directory)
    }

    package static func parse(_ data: Data, member: [String]?, directory: Bool) throws -> [PreviewArchiveRecord] {
        guard data.count <= outputLimit, data.starts(with: Data("SAP1".utf8)) else { throw PreviewArchiveError.unreadable }
        var offset = 4, records: [PreviewArchiveRecord] = []
        var seen: Set<Data> = [], spellings: [String: Data] = [:], types: [String: UInt8] = [:]
        func number(_ count: Int) throws -> UInt64 {
            guard count <= data.count - offset else { throw PreviewArchiveError.unreadable }
            defer { offset += count }
            return data[offset..<(offset+count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        while offset < data.count {
            try Task.checkCancellation()
            let kind = try number(1)
            if kind == 0 {
                guard offset == data.count, member == nil || !records.isEmpty else { throw PreviewArchiveError.unreadable }
                return records
            }
            guard (1...3).contains(kind), records.count < 50_000 else { throw PreviewArchiveError.limit }
            let count = try number(4), size = try number(8), seconds = Int64(bitPattern: try number(8))
            guard (1...4096).contains(count), count <= data.count - offset, size <= Int64.max else { throw PreviewArchiveError.limit }
            guard (-62_135_596_800...253_402_300_799).contains(seconds) else { throw PreviewArchiveError.unreadable }
            let bytes = data.subdata(in: offset..<(offset+Int(count)))
            offset += Int(count)
            guard let path = String(data: bytes, encoding: .utf8), !path.hasPrefix("/"), !path.hasSuffix("/"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\\" }),
                  seen.insert(bytes).inserted else { throw PreviewArchiveError.unsafe }
            let parts = path.components(separatedBy: "/")
            guard parts.count <= 128, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
                throw PreviewArchiveError.unsafe
            }
            // Reject Unicode aliases and file/folder conflicts before any filesystem writes.
            for depth in 1...parts.count {
                let prefix = parts.prefix(depth).joined(separator: "/"), raw = Data(prefix.utf8)
                if let old = spellings[prefix], old != raw { throw PreviewArchiveError.unsafe }
                guard spellings.count < 100_000 || spellings[prefix] != nil else { throw PreviewArchiveError.limit }
                spellings[prefix] = raw
                let type: UInt8 = depth == parts.count ? UInt8(kind) : 2
                if let old = types[prefix], old != type { throw PreviewArchiveError.unsafe }
                types[prefix] = type
            }
            var body: Data?
            if let member {
                let chosen = parts.count >= member.count && zip(parts, member).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
                guard chosen, directory || parts.count == member.count, kind != 3,
                      size <= data.count - offset else { throw PreviewArchiveError.unsafe }
                if kind == 1 {
                    body = data.subdata(in: offset..<(offset+Int(size)))
                    offset += Int(size)
                }
            }
            records.append(PreviewArchiveRecord(path: parts, kind: UInt8(kind), size: Int64(size),
                                                modified: Date(timeIntervalSince1970: Double(seconds)), body: body))
        }
        throw PreviewArchiveError.unreadable
    }

    package static func listing(_ records: [PreviewArchiveRecord]) throws -> ArchiveListing {
        let root = ArchiveNode(name: "", isDirectory: true)
        var nodes: [String: ArchiveNode] = ["": root], files = 0, folders = 0
        var total: Int64 = 0
        for record in records {
            try Task.checkCancellation()
            var parent = root
            for depth in 1...record.path.count {
                let key = record.path.prefix(depth).joined(separator: "/")
                if let existing = nodes[key] { parent = existing; continue }
                guard nodes.count < 100_000 else { throw PreviewArchiveError.limit }
                let directory = depth < record.path.count || record.kind == 2
                let node = ArchiveNode(name: record.path[depth-1], isDirectory: directory,
                                       size: directory ? 0 : record.size, modified: record.modified)
                parent.children.append(node)
                nodes[key] = node
                parent = node
                if directory { folders += 1 } else {
                    files += 1
                    let (sum, overflow) = total.addingReportingOverflow(record.size)
                    total = overflow ? .max : sum
                }
            }
        }
        for node in nodes.values where node.isDirectory {
            node.children.sort { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return ArchiveListing(root: Handoff(value: root), files: files, folders: folders, uncompressed: total, compressed: nil, note: nil)
    }
}

/// Resolve beside this module in a test bundle, and inside Helpers in the shipping app.
nonisolated private final class PreviewArchiveBundle: NSObject {}
