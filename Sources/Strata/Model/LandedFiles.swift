import Foundation

/// Where items landed and what they are there, so an operation's undo moves or trashes only those very items: never
/// one put in an item's place since, however alike its name. Each is recorded as it lands (or, for a move on one
/// disk, before it starts), never later, when something else may already be there. Kept for this run only, so an
/// item is its disk, file number and birth time, read without following a link (History's `OperationLog.identity`
/// also outlives a disk being plugged in again).
final class LandedFiles {
    private var identities: [String: FileIdentity] = [:]

    /// What's at each of `urls` now: for items that have just landed there.
    init(_ urls: [URL] = []) { record(urls) }

    func record(_ urls: [URL]) {
        for url in urls { identities[url.path] = FileIdentity.read(url.path) }
    }

    /// `identity` (from `FileIdentity.read`), read when the item landed at `url`.
    func set(_ identity: FileIdentity?, at url: URL) {
        identities[url.path] = identity
    }

    /// The item at `url` is about to move to `destination`: a move on one disk keeps what it is, so it's expected
    /// there already. Call `arrived` once it's moved.
    func expect(_ url: URL, at destination: URL) {
        identities[destination.path] = FileIdentity.read(url.path)
    }

    /// An expected item has moved to `destination`. Moved across disks, it's a new file there, recorded now; on one
    /// disk the expectation stands, so a file swapped in meanwhile is never taken for it.
    func arrived(_ destination: URL) {
        guard let expected = identities[destination.path], let now = FileIdentity.read(destination.path) else { return }
        if expected.device != now.device { identities[destination.path] = now }
    }

    func holds(_ url: URL) -> Bool {
        guard let identity = identities[url.path] else { return false }
        return FileIdentity.read(url.path) == identity
    }
}

