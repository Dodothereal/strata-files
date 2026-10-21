import Foundation

/// The destination left by a failed copy and the folder that contained it. A later Retry must not adopt a file
/// placed there meanwhile, or follow a parent folder that has been replaced or redirected.
nonisolated struct TransferRetryTarget: Sendable {
    private let parent: URL
    private let parentIdentity: FileIdentity
    private let identity: FileIdentity?

    init?(_ destination: URL, identity: FileIdentity?) {
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        self.parent = parent
        parentIdentity = FileIdentity.from(info)
        self.identity = identity
    }

    func matches(_ destination: URL) -> Bool {
        guard destination.deletingLastPathComponent().resolvingSymlinksInPath().path == parent.path,
              FileIdentity.read(parent.path) == parentIdentity else { return false }
        guard let current = FileIdentity.read(destination.path) else { return !TransferEngine.exists(destination) }
        return current == identity
    }
}
