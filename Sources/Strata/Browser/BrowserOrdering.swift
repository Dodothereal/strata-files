import Foundation

enum SortKey: String, CaseIterable {
    case name, modified, created, added, size, kind, dimensions, width, height, duration
    case fileExtension = "extension"

    var isMedia: Bool {
        switch self {
        case .dimensions, .width, .height, .duration: true
        default: false
        }
    }
}

/// Owns the ordering policy independently of native headers and row animation. Results keep their supplied order
/// until a column is chosen; returning to a folder restores its own choice.
final class BrowserOrdering {
    struct Choice: Equatable {
        let key: SortKey
        let ascending: Bool
    }

    struct Metadata {
        let folderSize: (URL) -> Int64?
        let childFolderSizes: (URL) -> [String: Int64]
        let media: (FileEntry) -> MediaInfo?
        let requestMedia: (FileEntry) -> Void
    }

    @MainActor private final class Pass {
        var sizes: [String: Int64] = [:]
        var parents: Set<URL> = []
        var changedParents: [FileNode] = []
    }

    private var folderChoice: Choice
    private var resultChoice: Choice?
    private var remembersFolderChoice = true
    private(set) var isShowingResults = false
    private let foldersFirst: () -> Bool
    private let metadata: Metadata

    init(choice: Choice, foldersFirst: @escaping () -> Bool, metadata: Metadata) {
        folderChoice = choice
        self.foldersFirst = foldersFirst
        self.metadata = metadata
    }

    var choice: Choice? { isShowingResults ? resultChoice : folderChoice }

    func choose(_ choice: Choice, remember: Bool = true) {
        if isShowingResults { resultChoice = choice }
        else { folderChoice = choice; remembersFolderChoice = remember }
    }

    func enterResults() {
        guard !isShowingResults else { return }
        resultChoice = nil
        isShowingResults = true
    }

    /// Native folder headers used to restore the saved preference as well. A workspace's temporary choice must
    /// restore its own header without changing the default for other windows.
    @discardableResult
    func leaveResults() -> Choice? {
        isShowingResults = false
        resultChoice = nil
        return remembersFolderChoice ? folderChoice : nil
    }

    /// A pass snapshots the order and caches directory totals once per path, including unknown values. Its cache
    /// belongs to this pass, so nested sorts and later measurements cannot reuse stale totals. Returns parents whose
    /// loaded children moved, so the native outline can refresh them even when the root order stays the same.
    @discardableResult
    func sort(_ nodes: inout [FileNode]) -> [FileNode] {
        guard let choice else { return [] }
        let pass = Pass()
        let foldersFirst = foldersFirst()
        func size(_ entry: FileEntry) -> Int64 {
            guard entry.isDirectory else { return entry.size ?? 0 }
            let key = entry.url.standardizedFileURL.path
            if let cached = pass.sizes[key] { return cached }
            let bytes = metadata.folderSize(entry.url) ?? -1
            pass.sizes[key] = bytes
            return bytes
        }
        func visit(_ level: inout [FileNode]) {
            if choice.key.isMedia { for node in level { metadata.requestMedia(node.entry) } }
            if choice.key == .size {
                for node in level where node.entry.isDirectory {
                    let parent = node.url.deletingLastPathComponent()
                    if pass.parents.insert(parent).inserted {
                        for (path, bytes) in metadata.childFolderSizes(parent) { pass.sizes[path] = bytes }
                    }
                }
            }
            level.sort { ordered($0.entry, $1.entry, choice: choice, foldersFirst: foldersFirst, size: size) }
            for node in level {
                if var children = node.children {
                    let previous = children
                    visit(&children)
                    if !previous.elementsEqual(children, by: { $0 === $1 }) { pass.changedParents.append(node) }
                    node.children = children
                }
            }
        }
        visit(&nodes)
        return pass.changedParents
    }

    /// Columns use the same policy for their own entries. No disk reads are needed by this comparator: metadata
    /// sources return only cached values, and a later metadata completion applies the updated order.
    func ordered(_ a: FileEntry, _ b: FileEntry) -> Bool {
        ordered(a, b, choice: choice ?? folderChoice, foldersFirst: foldersFirst()) { entry in
            entry.isDirectory ? metadata.folderSize(entry.url) ?? -1 : entry.size ?? 0
        }
    }

    private func ordered(_ a: FileEntry, _ b: FileEntry, choice: Choice, foldersFirst: Bool,
                         size: (FileEntry) -> Int64) -> Bool {
        if foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
        let result: ComparisonResult
        switch choice.key {
        case .name: result = a.displayName.localizedStandardCompare(b.displayName)
        case .modified: result = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .created: result = compare(a.created ?? .distantPast, b.created ?? .distantPast)
        case .added: result = compare(a.added ?? .distantPast, b.added ?? .distantPast)
        case .size: result = compare(size(a), size(b))
        case .kind: result = a.kind.localizedStandardCompare(b.kind)
        case .fileExtension: result = a.url.pathExtension.localizedStandardCompare(b.url.pathExtension)
        case .dimensions: result = compare(metadata.media(a)?.pixels ?? -1, metadata.media(b)?.pixels ?? -1)
        case .width: result = compare(metadata.media(a)?.width ?? -1, metadata.media(b)?.width ?? -1)
        case .height: result = compare(metadata.media(a)?.height ?? -1, metadata.media(b)?.height ?? -1)
        case .duration: result = compare(metadata.media(a)?.duration ?? -1, metadata.media(b)?.duration ?? -1)
        }
        if result == .orderedSame {
            let names = a.displayName.localizedStandardCompare(b.displayName)
            return names == .orderedSame ? a.url.path < b.url.path : names == .orderedAscending
        }
        return choice.ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}
