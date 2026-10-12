import Foundation

// MARK: - States

/// How a path shows up in the file list, ordered from least to most notable. A folder shows the most notable state
/// among the paths below it (ignored paths never bubble up).
nonisolated enum GitFileState: Int, Sendable, Comparable, CaseIterable {
    case clean
    case ignored
    case untracked
    case copied
    case added
    case renamed
    case deleted
    case modified
    case conflicted

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One side (index or work tree) of a porcelain `XY` status code.
nonisolated enum GitChange: Sendable, Equatable {
    case unmodified, modified, typeChanged, added, deleted, renamed, copied, unmerged

    init(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "M"): self = .modified
        case UInt8(ascii: "T"): self = .typeChanged
        case UInt8(ascii: "A"): self = .added
        case UInt8(ascii: "D"): self = .deleted
        case UInt8(ascii: "R"): self = .renamed
        case UInt8(ascii: "C"): self = .copied
        case UInt8(ascii: "U"): self = .unmerged
        default: self = .unmodified
        }
    }
}

/// Whether a tracked change is in the index, the work tree, or both.
nonisolated enum GitStaging: Sendable, Equatable {
    case staged, unstaged, partiallyStaged
}

/// One entry from `git status`: a changed, conflicted, untracked or ignored path.
nonisolated struct GitPathStatus: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case tracked, conflicted, untracked, ignored }

    /// Relative to the repository root, without a trailing slash.
    let path: String
    let kind: Kind
    /// Staged side (`X`).
    let index: GitChange
    /// Unstaged side (`Y`).
    let worktree: GitChange
    /// The source of a rename or copy.
    let originalPath: String?
    let isSubmodule: Bool
    /// Untracked or ignored folders are reported as a whole (`dir/`).
    let isDirectory: Bool

    var state: GitFileState {
        switch kind {
        case .conflicted: return .conflicted
        case .untracked: return .untracked
        case .ignored: return .ignored
        case .tracked:
            if index == .deleted || worktree == .deleted { return .deleted }
            if index == .renamed { return .renamed }
            if index == .copied { return .copied }
            if index == .added { return .added }
            return .modified
        }
    }

    var staging: GitStaging? {
        guard kind == .tracked else { return nil }
        switch (index != .unmodified, worktree != .unmodified) {
        case (true, true): return .partiallyStaged
        case (true, false): return .staged
        default: return .unstaged
        }
    }
}

// MARK: - Branch and repository state

nonisolated struct GitBranchInfo: Sendable, Equatable {
    /// Branch name, or nil when HEAD is detached.
    var head: String?
    /// Commit HEAD points at; nil before the first commit.
    var oid: String?
    var upstream: String?
    var ahead = 0
    var behind = 0

    var isDetached: Bool { head == nil }
    var shortOID: String? { oid.map { String($0.prefix(7)) } }
    /// Branch name, or the short commit when detached.
    var displayName: String { head ?? shortOID ?? "HEAD" }
}

/// A multi-step operation in progress, read from marker files in the git directory.
nonisolated enum GitOperation: Sendable, Equatable {
    case merging
    case rebasing(step: Int?, total: Int?)
    case cherryPicking
    case reverting
    case bisecting
    case applyingMailbox

    var title: String {
        switch self {
        case .merging: return String(localized: "Merging", comment: "Git operation in progress")
        case .rebasing(let step?, let total?):
            return String(localized: "Rebasing \(step)/\(total)", comment: "Git operation in progress: rebase step out of total steps")
        case .rebasing: return String(localized: "Rebasing", comment: "Git operation in progress")
        case .cherryPicking: return String(localized: "Cherry-picking", comment: "Git operation in progress")
        case .reverting: return String(localized: "Reverting", comment: "Git operation in progress")
        case .bisecting: return String(localized: "Bisecting", comment: "Git operation in progress")
        case .applyingMailbox: return String(localized: "Applying patches", comment: "Git operation in progress (git am)")
        }
    }
}

/// How many paths are in each state, for summaries like "3 modified · 1 untracked".
nonisolated struct GitStatusCounts: Sendable, Equatable {
    var modified = 0
    var added = 0
    var deleted = 0
    var renamed = 0
    var untracked = 0
    var conflicted = 0
    var staged = 0
    var unstaged = 0

    var changed: Int { modified + added + deleted + renamed + untracked + conflicted }
    var isClean: Bool { changed == 0 }

    mutating func add(_ status: GitPathStatus) {
        switch status.state {
        case .conflicted: conflicted += 1
        case .modified: modified += 1
        case .deleted: deleted += 1
        case .renamed, .copied: renamed += 1
        case .added: added += 1
        case .untracked: untracked += 1
        case .ignored, .clean: return
        }
        switch status.staging {
        case .staged: staged += 1
        case .unstaged: unstaged += 1
        case .partiallyStaged: staged += 1; unstaged += 1
        case nil: break
        }
    }

    /// "3 modified · 1 untracked", most important first.
    var summary: String {
        var parts: [String] = []
        if conflicted > 0 { parts.append(String(localized: "\(conflicted) conflicted", comment: "plural")) }
        if modified > 0 { parts.append(String(localized: "\(modified) modified", comment: "plural")) }
        if added > 0 { parts.append(String(localized: "\(added) added", comment: "plural")) }
        if deleted > 0 { parts.append(String(localized: "\(deleted) deleted", comment: "plural")) }
        if renamed > 0 { parts.append(String(localized: "\(renamed) renamed", comment: "plural")) }
        if untracked > 0 { parts.append(String(localized: "\(untracked) untracked", comment: "plural")) }
        return parts.isEmpty ? String(localized: "No changes", comment: "Git: no uncommitted changes") : parts.joined(separator: " · ")
    }
}

nonisolated enum GitIgnoredMode: String, Sendable {
    /// Lists paths that match an ignore pattern; doesn't descend into ignored folders. Fast on big trees.
    case matching
    /// Also lists folders whose contents are all ignored, which means walking every ignored folder. Can take
    /// seconds in repos with large `node_modules` or build output.
    case traditional
}

// MARK: - Snapshot

/// The parsed result of one `git status` run, with indexes for constant-time lookups from the file list.
nonisolated struct GitStatusSnapshot: Sendable {
    enum Outcome: Sendable, Equatable {
        case ok
        case timedOut
        case failed(String)
    }

    let repository: GitRepository
    let branch: GitBranchInfo
    let operation: GitOperation?
    let stashCount: Int
    /// Changed, conflicted and untracked paths (not ignored ones), keyed by root-relative path.
    let entries: [String: GitPathStatus]
    let ignoredFiles: Set<String>
    let ignoredDirectories: Set<String>
    let untrackedDirectories: Set<String>
    /// Most notable state below each folder that contains changes; `""` is the repository root.
    let directoryStates: [String: GitFileState]
    let counts: GitStatusCounts
    let outcome: Outcome
    let duration: TimeInterval
    let date: Date
    /// Hash of git's raw output, to skip redraws when a refresh finds nothing new.
    let fingerprint: Int

    var root: URL { repository.root }
    var isComplete: Bool { outcome == .ok }

    /// `url` relative to the repository root ("" for the root itself), or nil when it's outside the work tree.
    func relativePath(_ url: URL) -> String? {
        GitStatusSnapshot.relativePath(url.standardizedFileURL.path, root: repository.rootPath)
    }

    static func relativePath(_ path: String, root: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    func state(forRelativePath path: String, isDirectory: Bool) -> GitFileState {
        if isIgnored(relativePath: path) { return .ignored }
        if let entry = entries[path] {
            // A submodule is reported as one entry but is also a folder; show whichever is more notable.
            return isDirectory ? max(entry.state, directoryStates[path] ?? .clean) : entry.state
        }
        if hasAncestor(of: path, in: untrackedDirectories) { return .untracked }
        return isDirectory ? directoryStates[path] ?? .clean : .clean
    }

    func status(forRelativePath path: String) -> GitPathStatus? {
        entries[path]
    }

    /// True for ignored files and folders, and anything inside an ignored folder.
    func isIgnored(relativePath path: String) -> Bool {
        if ignoredFiles.contains(path) || ignoredDirectories.contains(path) { return true }
        return hasAncestor(of: path, in: ignoredDirectories)
    }

    /// Whether `path` lies in a folder git doesn't track (ignored or untracked), so deleting it loses nothing in git.
    func isUntrackedOrIgnored(relativePath path: String) -> Bool {
        if isIgnored(relativePath: path) || untrackedDirectories.contains(path) { return true }
        if let entry = entries[path], entry.kind == .untracked { return true }
        return hasAncestor(of: path, in: untrackedDirectories)
    }

    /// Counts for the paths inside `folder` (relative; "" for the whole repository).
    func counts(inside folder: String) -> GitStatusCounts {
        guard !folder.isEmpty else { return counts }
        let prefix = folder + "/"
        var result = GitStatusCounts()
        for (path, entry) in entries where path.hasPrefix(prefix) { result.add(entry) }
        return result
    }

    /// Walks up `path` one component at a time: O(depth) set lookups instead of scanning every ignored prefix.
    private func hasAncestor(of path: String, in set: Set<String>) -> Bool {
        guard !set.isEmpty else { return false }
        var end = path.endIndex
        while let slash = path[path.startIndex..<end].lastIndex(of: "/") {
            if set.contains(String(path[path.startIndex..<slash])) { return true }
            end = slash
        }
        return false
    }
}

// MARK: - Parser

/// Parses `git status --porcelain=v2 -z --branch [--show-stash]` output.
nonisolated enum GitStatusParser {
    struct Result: Sendable {
        var branch = GitBranchInfo()
        var stashCount = 0
        var entries: [String: GitPathStatus] = [:]
        var ignoredFiles: Set<String> = []
        var ignoredDirectories: Set<String> = []
        var untrackedDirectories: Set<String> = []
        var directoryStates: [String: GitFileState] = [:]
        var counts = GitStatusCounts()
    }

    static func parse(_ data: Data) -> Result {
        var result = Result()
        let bytes = [UInt8](data)
        var records = bytes.split(separator: 0, omittingEmptySubsequences: true)[...]
        while let record = records.popFirst() {
            guard let type = record.first else { continue }
            switch type {
            case UInt8(ascii: "#"):
                parseHeader(record, into: &result)
            case UInt8(ascii: "1"):
                // 1 XY sub mH mI mW hH hI path
                let fields = record.split(separator: 0x20, maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                add(tracked: fields[1], sub: fields[2], path: fields[8], original: nil, into: &result)
            case UInt8(ascii: "2"):
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let fields = record.split(separator: 0x20, maxSplits: 9, omittingEmptySubsequences: false)
                let original = records.popFirst().map(string)
                guard fields.count == 10 else { continue }
                add(tracked: fields[1], sub: fields[2], path: fields[9], original: original, into: &result)
            case UInt8(ascii: "u"):
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = record.split(separator: 0x20, maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                insert(GitPathStatus(path: string(fields[10]), kind: .conflicted, index: GitChange(xy[0]),
                                     worktree: GitChange(xy[1]), originalPath: nil, isSubmodule: fields[2].first == UInt8(ascii: "S"),
                                     isDirectory: false), into: &result)
            case UInt8(ascii: "?"), UInt8(ascii: "!"):
                guard record.count > 2 else { continue }
                var path = string(record.dropFirst(2))
                let isDirectory = path.hasSuffix("/")
                if isDirectory { path.removeLast() }
                if type == UInt8(ascii: "!") {
                    if isDirectory { result.ignoredDirectories.insert(path) } else { result.ignoredFiles.insert(path) }
                } else {
                    if isDirectory { result.untrackedDirectories.insert(path) }
                    insert(GitPathStatus(path: path, kind: .untracked, index: .unmodified, worktree: .unmodified,
                                         originalPath: nil, isSubmodule: false, isDirectory: isDirectory), into: &result)
                }
            default:
                continue
            }
        }
        return result
    }

    private static func add(tracked xyField: ArraySlice<UInt8>, sub: ArraySlice<UInt8>, path: ArraySlice<UInt8>,
                            original: String?, into result: inout Result) {
        guard xyField.count == 2 else { return }
        let xy = Array(xyField)
        insert(GitPathStatus(path: string(path), kind: .tracked, index: GitChange(xy[0]), worktree: GitChange(xy[1]),
                             originalPath: original, isSubmodule: sub.first == UInt8(ascii: "S"), isDirectory: false),
               into: &result)
    }

    private static func insert(_ status: GitPathStatus, into result: inout Result) {
        result.entries[status.path] = status
        result.counts.add(status)
        // Bubble the state up to every enclosing folder, keeping the most notable one.
        let state = status.state
        var path = Substring(status.path)
        while true {
            let parent: Substring
            if let slash = path.lastIndex(of: "/") { parent = path[..<slash] } else { parent = "" }
            let key = String(parent)
            if let existing = result.directoryStates[key], existing >= state {
                // Ancestors already hold something at least as notable.
                break
            }
            result.directoryStates[key] = state
            if parent.isEmpty { break }
            path = parent
        }
    }

    private static func parseHeader(_ record: ArraySlice<UInt8>, into result: inout Result) {
        let text = string(record)
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": result.branch.oid = value == "(initial)" ? nil : value
        case "branch.head": result.branch.head = value == "(detached)" ? nil : value
        case "branch.upstream": result.branch.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { result.branch.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { result.branch.behind = Int(token.dropFirst()) ?? 0 }
            }
        case "stash": result.stashCount = Int(value) ?? 0
        default: break
        }
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
