import Foundation

/// Copies filled in as you browse: containers' files (`ContainerCopies`) and servers' (`RemoteCopies`). What they have
/// in common (a folder is listed when it's shown, files are fetched before they're opened, previewed, dragged or
/// copied, placeholders stand in until then) goes through here, whichever kind a path is in.
nonisolated enum LazyCopies {
    static func contains(_ url: URL) -> Bool {
        ContainerCopies.contains(url) || RemoteCopies.contains(url)
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        ContainerCopies.isPlaceholder(url) || RemoteCopies.isPlaceholder(url)
    }

    /// Brings `folder` up to date with its container or server.
    static func refresh(_ folder: URL) async {
        if RemoteCopies.contains(folder) {
            await RemoteFiles.shared.refresh(folder)
        } else if ContainerCopies.contains(folder) {
            await ContainerFiles.shared.refresh(folder)
        }
    }

    /// The next `refresh` of `folder` lists it again.
    static func invalidate(_ folder: URL) async {
        if RemoteCopies.contains(folder) {
            await RemoteFiles.shared.invalidate(folder)
        } else if ContainerCopies.contains(folder) {
            await ContainerFiles.shared.invalidate(folder)
        }
    }

    /// Lists the folders on the way to `url` so it exists in the copy. False when it isn't there.
    static func reveal(_ url: URL) async -> Bool {
        if RemoteCopies.contains(url) { return await RemoteFiles.shared.reveal(url) }
        return await ContainerFiles.shared.reveal(url)
    }

    static func fetch(_ urls: [URL]) async throws {
        let remote = urls.filter(RemoteCopies.contains)
        if !remote.isEmpty { try await RemoteFiles.shared.fetch(remote) }
        let containers = urls.filter(ContainerCopies.contains)
        if !containers.isEmpty { try await ContainerFiles.shared.fetch(containers) }
    }

    static func fetchSelection(_ urls: [URL], limit: Int64) async {
        if urls.contains(where: RemoteCopies.contains) {
            await RemoteFiles.shared.fetchSelection(urls.filter(RemoteCopies.contains), limit: limit)
        } else {
            await ContainerFiles.shared.fetchSelection(urls, limit: limit)
        }
    }

    /// Placeholders fetched and folders complete, before they're copied out.
    static func prepareForCopying(_ urls: [URL]) async throws {
        let remote = urls.filter(RemoteCopies.contains)
        if !remote.isEmpty { try await RemoteFiles.shared.prepareForCopying(remote) }
        let containers = urls.filter(ContainerCopies.contains)
        if !containers.isEmpty { try await ContainerFiles.shared.prepareForCopying(containers) }
    }

    /// What went wrong reading `url` from where it lives, in a sentence.
    static func message(for error: Error, about url: URL) -> String {
        if RemoteCopies.contains(url) { return RemoteFiles.message(for: error) }
        if let source = ContainerCopies.copy(containing: url)?.source { return ContainerFiles.message(for: error, source: source) }
        return error.localizedDescription
    }

    /// Where an item really is: "web:/etc/hosts" (a container), "deploy@web-1:/srv/app" (a server).
    static func displayPath(_ url: URL) -> String? {
        RemoteCopies.displayPath(url) ?? ContainerCopies.apparentPath(url)
    }

    /// Where items copied to the clipboard from a copy are staged (see `stageForClipboard`), next to the copies.
    static let clipboardRoot: URL = RemoteCopies.root.deletingLastPathComponent()
        .appending(path: "Clipboard.noindex", directoryHint: .isDirectory)

    /// What goes on the clipboard for `urls`: items from a container's or a server's copy as a staged copy of their own
    /// (an APFS clone, so it's instant), finished like anything copied out (links that would lead outside dropped,
    /// writable, still marked as downloaded). Pasting them anywhere, Finder included, gets ordinary files. Anything else
    /// is itself; a link chosen on its own is left out (from wherever it's pasted it would lead into this Mac's own
    /// folders). Staged items are removed at the next launch.
    static func stageForClipboard(_ urls: [URL]) -> [URL] {
        guard urls.contains(where: contains) else { return urls }
        let fm = FileManager.default
        func newFolder() -> URL? {
            let folder = clipboardRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                return folder
            } catch {
                return nil
            }
        }
        guard var folder = newFolder() else { return urls.filter { !contains($0) } }
        return urls.compactMap { url in
            guard contains(url) else { return url }
            var info = stat()
            // Two chosen items with one name (from different folders) each get a folder of their own.
            if lstat(folder.appending(path: url.lastPathComponent).path, &info) == 0 {
                guard let another = newFolder() else { return nil }
                folder = another
            }
            let staged = folder.appending(path: url.lastPathComponent)
            guard (try? fm.copyItem(at: url, to: staged)) != nil else { return nil }
            ContainerCopies.finishCopyingOut(staged, from: url)
            return lstat(staged.path, &info) == 0 ? staged : nil
        }
    }

    /// Clipboard staging left from before (at launch).
    static func removeClipboardStaging() {
        guard FileManager.default.fileExists(atPath: clipboardRoot.path) else { return }
        Archiver.removeTree(clipboardRoot)
    }

    /// The container or server an item comes from, by name.
    static func sourceName(_ url: URL) -> String? {
        RemoteCopies.server(containing: url)?.server.name ?? ContainerCopies.copy(containing: url)?.source.name
    }
}
