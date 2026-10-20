import AppKit

/// Archives being opened as folders, by their copy's folder: a second open of the same archive (a double double-click,
/// the other pane) waits for the first instead of starting over and deleting what it's making.
private enum OpeningArchives {
    static var waiters: [String: [(URL) -> Void]] = [:]
}

/// Archives open like folders, the way Windows Explorer shows a zip: browse in, Quick Look, copy things out. The archive
/// is extracted once, safely, into Strata's caches (see `ArchiveCache`), and nothing inside is changed from Strata.
extension BrowserViewController {
    /// Unpacking more than this asks first.
    private static let largeArchive: Int64 = 2 << 30

    /// Whether this pane shows (or the selection is) inside a read-only copy (an archive opened as a folder, or a
    /// container's files): changing things there is off.
    var isInsideArchive: Bool {
        targetDirectory.map(ReadOnlyCopies.contains) == true || selectedURLs.contains(where: ReadOnlyCopies.contains)
    }

    /// Whether opening `entry` shows its contents (zip, tar, 7z, rar, unless turned off in Settings). Disk images,
    /// packages and installers keep opening in their own apps.
    func opensAsFolder(_ entry: FileEntry) -> Bool {
        preferences.openArchivesAsFolders && !entry.isFolder && Self.browsableByDefault(entry.name)
    }

    static func browsableByDefault(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["zip", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "7z", "rar"].contains(ext) { return true }
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"].contains(where: lower.hasSuffix)
    }

    /// Shows what's in `archive` like a folder: right away when it was opened before (and hasn't changed), otherwise once
    /// it's extracted. Big ones ask first.
    func browseArchive(_ archive: URL) {
        let window = view.window
        if let folder = ArchiveCache.existing(for: archive) {
            ArchiveCache.touch(folder)
            delegate?.browser(self, showArchiveCopy: folder)
            return
        }
        guard let folder = ArchiveCache.folder(for: archive), let kind = ArchiveKind(fileName: archive.lastPathComponent) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(archive.lastPathComponent)” couldn’t be opened.")
            alert.informativeText = String(localized: "It can’t be read.")
            return Self.present(alert, in: window) { _ in }
        }
        let key = folder.path
        let startedIn = directory
        let show: (URL) -> Void = { [weak self] copy in
            // Only if you're still where you opened it: a slow archive mustn't pull you away from elsewhere.
            guard let self, directory == startedIn else { return }
            delegate?.browser(self, showArchiveCopy: copy)
        }
        if OpeningArchives.waiters[key] != nil {
            OpeningArchives.waiters[key]?.append(show)
            return
        }
        OpeningArchives.waiters[key] = [show]
        delegate?.browser(self, openingArchive: archive, stop: nil)
        Task { [weak self] in
            let inspection = await Archiver.inspect(archive, kind: kind)
            if inspection.complete, inspection.bytes > Self.largeArchive {
                let size = ByteCountFormatter.string(fromByteCount: inspection.bytes, countStyle: .file)
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(archive.lastPathComponent)” holds \(size).", comment: "An archive, then its unpacked size (“5 GB”)")
                alert.informativeText = String(localized: "Opening it as a folder unpacks all of it into Strata’s caches first. Extract puts it next to the archive instead.")
                alert.addButton(withTitle: String(localized: "Open", comment: "Alert button: open the archive as a folder"))
                alert.addButton(withTitle: String(localized: "Extract", comment: "Alert button: unpack the archive next to it"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                let response = await withCheckedContinuation { continuation in
                    Self.present(alert, in: window) { continuation.resume(returning: $0) }
                }
                guard response == .alertFirstButtonReturn else {
                    OpeningArchives.waiters[key] = nil
                    if let self {
                        delegate?.browser(self, openingArchive: nil, stop: nil)
                        if response == .alertSecondButtonReturn { extractArchive(archive) }
                    }
                    return
                }
            }
            guard let self else {
                OpeningArchives.waiters[key] = nil
                return
            }
            unpackForBrowsing(archive, into: folder, key: key)
        }
    }

    private func unpackForBrowsing(_ archive: URL, into folder: URL, key: String) {
        let fm = FileManager.default
        let entry = folder.deletingLastPathComponent()
        let window = view.window
        // Nothing else is making this copy (it would be in `waiters`): what's there is left from an earlier attempt.
        if fm.fileExists(atPath: entry.path) { ArchiveCache.remove(entry) }
        do {
            try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        } catch {
            OpeningArchives.waiters[key] = nil
            delegate?.browser(self, openingArchive: nil, stop: nil)
            return Self.report([(archive, error)], .open, in: window)
        }
        let job = ArchiveJob(.browse(archive, at: folder), undo: nil)
        delegate?.browser(self, openingArchive: archive) { job.cancel() }
        job.onFinish = { [weak self] job in
            let waiters = OpeningArchives.waiters.removeValue(forKey: key) ?? []
            if let self { delegate?.browser(self, openingArchive: nil, stop: nil) }
            guard job.state == .finished, (try? ArchiveCache.finish(folder, from: archive)) != nil else {
                // Only this job's own copy goes: nothing else was making it.
                ArchiveCache.remove(entry)
                if job.state == .failed, let message = job.errorMessage {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "“\(archive.lastPathComponent)” couldn’t be opened.")
                    alert.informativeText = message
                    Self.present(alert, in: window) { _ in }
                }
                return
            }
            waiters.forEach { $0(folder) }
            // Keeps the cache in check while Strata stays open (launch isn't the only time).
            let keep = Set(OpeningArchives.waiters.keys).union(BrowserWindowController.archiveCopiesShown())
            DispatchQueue.global(qos: .utility).async { ArchiveCache.prune(keeping: keep) }
        }
        services.transfers.add(job)
    }

    /// Context menu, when archives don't open as folders by default (or for kinds that open in their own apps).
    @objc func openArchiveAsFolder(_ sender: Any?) {
        guard let url = selectedURLs.first else { return }
        // An archive in a container's files is read from the container first.
        afterFetching([url]) { [weak self] in self?.browseArchive(url) }
    }

    /// Shows the archive (not Strata's copy of it) in Finder.
    @objc func showArchiveInFinder(_ sender: Any?) {
        guard let (archive, _) = (targetDirectory ?? directory).flatMap(ArchiveCache.archive(containing:)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([archive])
    }

    /// Unpacks `archive` next to it (the notice bar's Extract All), or into Downloads when its folder can't take it (a
    /// read-only disk, the Trash, another archive's copy), then shows the result.
    func extractArchive(_ archive: URL) {
        let folder = archive.deletingLastPathComponent()
        let usable = access(folder.path, W_OK) == 0 && !ReadOnlyCopies.contains(folder) && !Trash.isInTrash(archive)
        let destination = usable ? folder : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
        let job = ArchiveJob(.extract(archive, into: destination), undo: undoManager)
        job.onFinish = { [weak self] job in
            guard let self, job.state == .finished, let result = job.result else { return }
            delegate?.browser(self, reveal: result)
        }
        services.transfers.add(job)
    }
}
