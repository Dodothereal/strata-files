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
        if FileManager.default.fileExists(atPath: destination.path),
           destination.path.lowercased() != url.path.lowercased() {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try await move([(from: url, to: destination)], actionName: "Rename", undo: undo)
        return destination
    }

    static func move(_ pairs: [Move], actionName: String, undo: UndoManager?) async throws {
        var done: [Move] = []
        defer {
            OperationLog.shared.recordMove(actionName, done)
            registerMoveUndo(done, actionName, undo)
        }
        for pair in pairs {
            try await moveItem(pair.from, pair.to)
            done.append(pair)
        }
    }

    static func newFolder(in directory: URL, undo: UndoManager?) throws -> URL {
        let url = available(directory.appending(path: "untitled folder"), copyStyle: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        OperationLog.shared.recordCreate("New Folder", [url])
        registerTrashUndo([url], "New Folder", undo)
        return url
    }

    static func trash(_ urls: [URL], undo: UndoManager?) throws {
        var moved: [Move] = []
        defer {
            OperationLog.shared.recordMove("Move to Trash", moved)
            registerMoveUndo(moved, "Move to Trash", undo)
        }
        for url in urls {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let result { moved.append((from: url, to: result as URL)) }
        }
        trashSound?.stop()
        trashSound?.play()
    }

    /// `name 2.txt`, `name 3.txt`… or Finder's `name copy.txt`, `name copy 2.txt`… for copies next to the original.
    static func available(_ url: URL, copyStyle: Bool) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPlainFolder = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
        let ext = isPlainFolder ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let suffix = copyStyle ? (n == 1 ? " copy" : " copy \(n)") : " \(n + 1)"
            let candidate = directory.appending(path: base + suffix + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
        byReference: true)

    private static func registerTrashUndo(_ created: [URL], _ actionName: String, _ undo: UndoManager?) {
        guard !created.isEmpty else { return }
        register(actionName, undo) { undo in try? trash(created, undo: undo) }
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
            Task { try? await move(back, actionName: actionName, undo: nil) }
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
