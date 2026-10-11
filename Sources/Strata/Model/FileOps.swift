import AppKit

extension Notification.Name {
    static let clipboardChanged = Notification.Name("StrataClipboardChanged")
}

/// File system changes with undo. Moves and copies run off the main thread; undo and redo are registered as the
/// inverse operation, which registers its own inverse in turn.
enum FileOps {
    typealias Move = (from: URL, to: URL)

    static func rename(_ url: URL, to name: String, undo: UndoManager?) async throws -> URL {
        let destination = url.deletingLastPathComponent().appending(path: name)
        if TransferEngine.exists(destination), destination.path.lowercased() != url.path.lowercased() {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSFilePathErrorKey: destination.path,
                NSLocalizedDescriptionKey: "The name “\(name)” is already taken. Please choose a different name.",
            ])
        }
        try await move([(from: url, to: destination)], actionName: "Rename", undo: undo)
        return destination
    }

    /// `record: false` for moves that are themselves an undo or redo (or part of a larger logged operation): History
    /// keeps one entry per operation and marks it undone instead of growing a row per ⌘Z.
    static func move(_ pairs: [Move], actionName: String, undo: UndoManager?, record: Bool = true) async throws {
        var done: [Move] = []
        defer {
            let entry = record ? OperationLog.shared.recordMove(actionName, done) : nil
            registerMoveUndo(done, actionName, undo)
            if let entry, let undo { registerLogMark(entry, undone: true, undo) }
        }
        for pair in pairs {
            try await moveItem(pair.from, pair.to)
            done.append(pair)
        }
    }

    static func newFolder(in directory: URL, undo: UndoManager?) throws -> URL {
        let url = available(directory.appending(path: "untitled folder"), copyStyle: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let entry = OperationLog.shared.recordCreate("New Folder", [url])
        registerTrashUndo([url], "New Folder", undo)
        if let entry, let undo { registerLogMark(entry, undone: true, undo) }
        return url
    }

    static func trash(_ urls: [URL], undo: UndoManager?, record: Bool = true) throws {
        var moved: [Move] = []
        defer {
            let entry = record ? OperationLog.shared.recordMove("Move to Trash", moved) : nil
            registerMoveUndo(moved, "Move to Trash", undo)
            if let entry, let undo { registerLogMark(entry, undone: true, undo) }
        }
        for url in urls {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let result { moved.append((from: url, to: result as URL)) }
        }
        trashSound?.stop()
        trashSound?.play()
    }

    /// Items that couldn't go to the Trash because their disk has none (network shares, some external disks).
    struct NoTrash: Error {
        let urls: [URL]
    }

    /// Moves `urls` to the Trash off the main thread (a big selection or a slow disk would freeze the window), then
    /// records and registers undo like `trash`. Items on disks without a Trash come back in `NoTrash`.
    static func trashInBackground(_ urls: [URL], undo: UndoManager?) async throws {
        let (moved, noTrash, failure) = await trashItems(urls)
        let entry = OperationLog.shared.recordMove("Move to Trash", moved)
        registerMoveUndo(moved, "Move to Trash", undo)
        if let entry, let undo { registerLogMark(entry, undone: true, undo) }
        if !moved.isEmpty {
            trashSound?.stop()
            trashSound?.play()
        }
        if let failure { throw failure }
        if !noTrash.isEmpty { throw NoTrash(urls: noTrash) }
    }

    @concurrent
    private static func trashItems(_ urls: [URL]) async -> (moved: [Move], noTrash: [URL], failure: Error?) {
        var moved: [Move] = []
        var noTrash: [URL] = []
        for url in urls {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let result { moved.append((from: url, to: result as URL)) }
            } catch let error as CocoaError where error.code == .featureUnsupported {
                noTrash.append(url)
            } catch {
                return (moved, noTrash, error)
            }
        }
        return (moved, noTrash, nil)
    }

    /// Deletes for good, off the main thread. Only after the user confirmed (there's no undo).
    @concurrent
    static func deleteImmediately(_ urls: [URL]) async throws {
        for url in urls { try FileManager.default.removeItem(at: url) }
    }

    /// `name 2.txt`, `name 3.txt`… or Finder's `name copy.txt`, `name copy 2.txt`… for copies next to the original.
    static func available(_ url: URL, copyStyle: Bool) -> URL {
        let fm = FileManager.default
        // lstat-based: a dangling symlink still takes the name.
        guard TransferEngine.exists(url) else { return url }
        let directory = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPlainFolder = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
        let ext = isPlainFolder ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let suffix = copyStyle ? (n == 1 ? " copy" : " copy \(n)") : " \(n + 1)"
            let tail = suffix + (ext.isEmpty ? "" : "." + ext)
            // Shorten the base so the new name still fits the 255-byte limit.
            let fitted = TransferEngine.fitting(base, maxBytes: max(1, 255 - tail.utf8.count))
            let candidate = directory.appending(path: fitted + tail)
            if !TransferEngine.exists(candidate) { return candidate }
            n += 1
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true)

    private static func registerTrashUndo(_ created: [URL], _ actionName: String, _ undo: UndoManager?) {
        guard !created.isEmpty else { return }
        register(actionName, undo) { undo in try? trash(created, undo: undo, record: false) }
    }

    /// ⌘Z couldn't put things back (something now sits where an item would return, say): say so rather than fail
    /// silently.
    static func reportUndoFailure(_ actionName: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t undo “\(actionName)”"
        alert.informativeText = error.localizedDescription
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Registers, in the current undo group, flipping History entry `id` to `undone` (and back on redo), so the
    /// History window agrees with ⌘Z and ⇧⌘Z.
    static func registerLogMark(_ id: UUID, undone: Bool, _ undo: UndoManager) {
        undo.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated {
                OperationLog.shared.setUndone(id, undone)
                registerLogMark(id, undone: !undone, undo)
            }
        }
    }

    private static func register(_ actionName: String, _ undo: UndoManager?, _ handler: @escaping (UndoManager) -> Void) {
        guard let undo else { return }
        undo.registerUndo(withTarget: undo) { target in
            MainActor.assumeIsolated { handler(target) }
        }
        undo.setActionName(actionName)
    }

    /// Undo for completed moves: move everything back. The inverse is registered right away, inside the undo
    /// handler, so it lands on the redo stack (registering it later from a task would put it back on the undo stack).
    private static func registerMoveUndo(_ moves: [Move], _ actionName: String, _ undo: UndoManager?) {
        guard !moves.isEmpty else { return }
        register(actionName, undo) { undo in
            let back = moves.reversed().map { (from: $0.to, to: $0.from) }
            registerMoveUndo(back, actionName, undo)
            Task {
                do {
                    try await move(back, actionName: actionName, undo: nil, record: false)
                } catch {
                    reportUndoFailure(actionName, error)
                }
            }
        }
    }

    @concurrent
    private static func moveItem(_ from: URL, _ to: URL) async throws {
        try FileManager.default.moveItem(at: from, to: to)
    }
}

/// Finder-compatible file clipboard, plus cut: ⌘X marks the items and the next paste moves them.
enum Clipboard {
    private static var cut: (urls: Set<URL>, changeCount: Int)?

    static func write(_ urls: [URL], cut isCut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cut = isCut ? (Set(urls), pasteboard.changeCount) : nil
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static func read() -> (urls: [URL], isCut: Bool) {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, cut?.changeCount == pasteboard.changeCount)
    }

    static func isCut(_ url: URL) -> Bool {
        guard let cut, cut.changeCount == NSPasteboard.general.changeCount else { return false }
        return cut.urls.contains(url)
    }

    static func clearCut() {
        cut = nil
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}
