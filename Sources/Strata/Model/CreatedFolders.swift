import Foundation

/// Folders made to hold an operation's items. Capture them when created, before a transfer or alert can suspend;
/// an empty replacement at the same path does not belong to the operation. Redo records any folders it makes again.
final class CreatedFolders {
    private(set) var urls: [URL] = []
    private var paths: Set<String> = []
    private var identities: [String: FileIdentity] = [:]
    private(set) var historyIdentities: [String: String] = [:]

    init(_ urls: [URL] = []) { record(urls) }

    /// Old History may lack folder identities. Restore its files, but leave unidentifiable folders alone.
    init(paths: [String], recorded: [String: String]) {
        for path in paths where self.paths.insert(path).inserted { urls.append(URL(fileURLWithPath: path)) }
        for url in urls {
            guard let saved = recorded[url.path], let identity = FileIdentity.read(url.path),
                  FileIdentity.matchesHistory(saved, at: url.path), FileIdentity.read(url.path) == identity else { continue }
            identities[url.path] = identity
            historyIdentities[url.path] = saved
        }
    }

    func record(_ made: [URL]) {
        for url in made {
            if paths.insert(url.path).inserted { urls.append(url) }
            let identity = FileIdentity.read(url.path)
            let saved = FileIdentity.historyKey(at: url.path)
            // A replacement during metadata lookup must not acquire either live or persistent ownership.
            let unchanged = identity != nil && FileIdentity.read(url.path) == identity
            identities[url.path] = unchanged ? identity : nil
            historyIdentities[url.path] = unchanged ? saved : nil
        }
    }

    func makeMissing(continueAfterFailure: Bool = false) throws {
        var firstError: Error?
        for url in urls.sorted(by: { $0.path.count < $1.path.count }) where !TransferEngine.exists(url) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                record([url])
            } catch {
                if !continueAfterFailure { throw error }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    func removeEmpty() { FileOps.removeEmptyFolders(urls, identities: identities) }

    /// Kept by both sides of an Undo/Redo pair, so folders recreated by Redo have fresh ownership before Undo runs.
    enum Change {
        case none
        case make(CreatedFolders)
        case remove(CreatedFolders)

        var inverse: Change {
            switch self {
            case .none: .none
            case .make(let folders): .remove(folders)
            case .remove(let folders): .make(folders)
            }
        }

        func prepare(continueAfterFailure: Bool = false) throws {
            if case .make(let folders) = self { try folders.makeMissing(continueAfterFailure: continueAfterFailure) }
        }
        func finish() { if case .remove(let folders) = self { folders.removeEmpty() } }

        var historyIdentities: [String: String] {
            if case .make(let folders) = self { folders.historyIdentities } else { [:] }
        }
    }
}
