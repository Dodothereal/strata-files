import Foundation

/// A named set of tabs, each with one or two pane folders, reopened as a window.
nonisolated struct Workspace: Codable, Equatable, Sendable {
    var name: String
    /// Each tab's pane folders: one, or two in dual pane.
    var tabs: [[String]]
    /// Each tab's panes' views (`BrowserViewMode` raw values). Missing in workspaces saved before views were kept.
    var modes: [[Int]]? = nil
    var saved: Date? = nil
    /// The network shares its folders are on: where each was mounted, and the address that mounts it again (never with
    /// a password). Opening the workspace connects to them again.
    var shares: [String: String]? = nil

    var isDualPane: Bool { tabs.contains { $0.count > 1 } }

    func mode(tab: Int, pane: Int) -> Int? {
        guard let modes, modes.indices.contains(tab), modes[tab].indices.contains(pane) else { return nil }
        return modes[tab][pane]
    }

    /// The share `path` is on (the innermost, if shares were mounted inside one another).
    func share(for path: String) -> (mountPoint: String, address: String)? {
        shares?.filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }
            .map { ($0.key, $0.value) }
    }

    /// Without the folders in `gone`: their panes go, and tabs left with none.
    func removing(_ gone: Set<String>) -> Workspace {
        var copy = self
        var tabs: [[String]] = []
        var modes: [[Int]] = []
        for (t, tab) in self.tabs.enumerated() {
            let kept = tab.indices.filter { !gone.contains(tab[$0]) }
            guard !kept.isEmpty else { continue }
            tabs.append(kept.map { tab[$0] })
            // -1 (no such view): that pane opens in the view it would anyway.
            modes.append(kept.map { mode(tab: t, pane: $0) ?? -1 })
        }
        copy.tabs = tabs
        copy.modes = self.modes == nil ? nil : modes
        let paths = Set(tabs.joined())
        let shares = self.shares?.filter { share in paths.contains { $0 == share.key || $0.hasPrefix(share.key + "/") } }
        copy.shares = shares?.isEmpty == false ? shares : nil
        return copy
    }
}

/// A folder a pane is kept for while it can't be shown: its share isn't connected yet, or its disk isn't. The pane shows
/// Home meanwhile, but saves (a workspace update, the session) keep this folder, its view and its share's address.
nonisolated struct WaitingFolder: Equatable, Sendable {
    var path: String
    var mode: Int?
    /// Where its share was mounted and the address that mounts it again; nil for a disk that isn't connected.
    var mountPoint: String?
    var address: String?
    /// A saved SFTP server's or bucket's ID, for a folder of its files (connected again, then listed down to it).
    var server: String? = nil
}

/// How a workspace opens, given what's on disk now: folders that are there, folders on a share to connect to first,
/// folders on a disk that isn't connected, and folders that are gone (their panes are left out, and tabs left with none).
nonisolated struct WorkspacePlan: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        var path: String
        var mode: Int?
        /// Set when the folder can't be shown yet: on a share to connect first, or on a disk that isn't connected.
        var waiting: WaitingFolder?
    }

    var tabs: [[Pane]] = []
    /// Folders that aren't there, in the order they were saved.
    var missing: [String] = []
    /// Folders on disks that aren't connected (not gone: they're kept).
    var offline: [String] = []
    /// Shares to connect to before their panes can be shown: mount point → address.
    var shares: [String: String] = [:]

    /// `server` says which saved server a path's files are of (a folder in Strata's copy of its files), if any.
    init(_ workspace: Workspace, exists: (String) -> Bool, server: (String) -> String? = { _ in nil }) {
        for (t, tab) in workspace.tabs.enumerated() {
            var panes: [Pane] = []
            for (p, path) in tab.enumerated().prefix(2) where !path.isEmpty {
                let mode = workspace.mode(tab: t, pane: p)
                if let id = server(path) {
                    // A server's files are read again each time: the pane waits for its server.
                    panes.append(Pane(path: path, mode: mode, waiting: WaitingFolder(path: path, mode: mode, server: id)))
                } else if exists(path) {
                    panes.append(Pane(path: path, mode: mode))
                } else if let share = workspace.share(for: path), !exists(share.mountPoint) {
                    panes.append(Pane(path: path, mode: mode,
                                      waiting: WaitingFolder(path: path, mode: mode, mountPoint: share.mountPoint, address: share.address)))
                    shares[share.mountPoint] = share.address
                } else if let volume = Self.volume(of: path), !exists(volume) {
                    panes.append(Pane(path: path, mode: mode, waiting: WaitingFolder(path: path, mode: mode)))
                    offline.append(path)
                } else {
                    missing.append(path)
                }
            }
            if !panes.isEmpty { tabs.append(panes) }
        }
    }

    /// The disk `path` is on when it's one under /Volumes ("/Volumes/Backup" for "/Volumes/Backup/2026").
    static func volume(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }

    /// Where a folder on a share is now that the share is mounted at `mountedAt` (macOS may pick another mount point,
    /// "/Volumes/Share-1", when the old one is taken).
    static func path(_ path: String, from mountPoint: String, to mountedAt: String) -> String {
        guard path == mountPoint || path.hasPrefix(mountPoint + "/") else { return path }
        let rest = path.dropFirst(mountPoint.count)
        let base = mountedAt.hasSuffix("/") ? String(mountedAt.dropLast()) : mountedAt
        return base + rest
    }
}
