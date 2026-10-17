import AppKit

extension Notification.Name {
    static let clipboardChanged = Notification.Name("StrataClipboardChanged")
}

/// File system changes with undo. Moves and copies run off the main thread; undo and redo are registered as the
/// inverse operation, which registers its own inverse in turn.
enum FileOps {
    typealias Move = (from: URL, to: URL)

    /// An archive opened as a folder is a temporary copy: nothing inside it is changed from Strata.
    static let insideArchiveError = CocoaError(.fileWriteNoPermission, userInfo: [
        NSLocalizedDescriptionKey: String(localized: "Items in a read-only copy (an archive opened as a folder, or a container’s files) can’t be changed. Copy them out first."),
    ])

    static func rename(_ url: URL, to name: String, undo: UndoManager?) async throws -> URL {
        guard !ReadOnlyCopies.contains(url) else { throw insideArchiveError }
        // A name, never a path: whatever is typed, the item stays in its folder.
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: name])
        }
        let destination = url.deletingLastPathComponent().appending(path: name)
        if TransferEngine.exists(destination), destination.path.lowercased() != url.path.lowercased() {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSFilePathErrorKey: destination.path,
                NSLocalizedDescriptionKey: String(localized: "The name “\(name)” is already taken. Please choose a different name."),
            ])
        }
        try await move([(from: url, to: destination)], actionName: "Rename", undo: undo)
        return destination
    }

    /// `record: false` for moves that are themselves an undo or redo (or part of a larger logged operation): History
    /// keeps one entry per operation and marks it undone instead of growing a row per ⌘Z.
    static func move(_ pairs: [Move], actionName: String, undo: UndoManager?, record: Bool = true) async throws {
        guard !pairs.contains(where: { ReadOnlyCopies.contains($0.from) || ReadOnlyCopies.contains($0.to) }) else {
            throw insideArchiveError
        }
        let landed = Landed()
        for pair in pairs { landed.expect(pair.from, at: pair.to) }
        let (done, error) = await moveAll(pairs)
        done.forEach { landed.arrived($0.to) }
        let entry = record ? OperationLog.shared.recordMove(actionName, done) : nil
        registerMoveUndo(done, actionName, undo, entry: entry, landed: landed)
        if let error { throw error }
    }

    /// Moves each pair in order, stopping at the first error, and returns what moved and the error that stopped it.
    /// Swaps and chains ("a → b" with "b → a", or "1 → 2, 2 → 3") are ordered so each item moves only once the one
    /// whose place it takes has left; a cycle parks one item under a hidden name that keeps its own. They succeed or
    /// fail as a whole: on an error everything moved goes back, and nothing is left under a hidden name.
    static func moveAll(_ pairs: [Move]) async -> (done: [Move], error: Error?) {
        guard isChain(pairs) else {
            var done: [Move] = []
            for pair in pairs {
                do { try await moveItem(pair.from, pair.to) } catch { return (done, error) }
                done.append(pair)
            }
            return (done, nil)
        }
        var executed: [(step: ChainStep, completes: Int?)] = []
        for step in chainSteps(pairs) {
            do {
                try await moveItem(step.from, step.to)
                executed.append((step, step.completes))
            } catch {
                let pair = pairs[step.pair]
                let named = NSError(domain: NSCocoaErrorDomain, code: (error as NSError).code, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "“\(pair.from.lastPathComponent)” couldn’t be renamed to “\(pair.to.lastPathComponent)”: \(error.localizedDescription)"),
                    NSUnderlyingErrorKey: error,
                ])
                // Back the way it came; whatever can't go back stays where it is, but never hidden.
                var kept: [Move] = []
                for item in executed.reversed() {
                    if (try? await moveItem(item.step.to, item.step.from)) != nil { continue }
                    if item.step.isParking {
                        try? await moveItem(item.step.to, available(item.step.from, copyStyle: false))
                    } else if let completed = item.completes {
                        kept.insert(pairs[completed], at: 0)
                    }
                }
                return (kept, named)
            }
        }
        return (executed.compactMap { $0.completes.map { pairs[$0] } }, nil)
    }

    /// One rename of a chain: `completes` is the pair it finishes (nil while an item is parked).
    struct ChainStep {
        let from: URL
        let to: URL
        /// The pair this step belongs to.
        let pair: Int
        let completes: Int?
        var isParking: Bool { completes == nil }
    }

    /// The order to run `pairs` in: each moves after the one whose place it takes (`blocker`); a cycle is broken by
    /// parking its first item and finishing it last.
    nonisolated static func chainSteps(_ pairs: [Move]) -> [ChainStep] {
        func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
        let bySource = Dictionary(pairs.enumerated().map { (key($0.element.from), $0.offset) }, uniquingKeysWith: { first, _ in first })
        var blocked = [Bool](repeating: false, count: pairs.count)
        // waiting[j]: the pair that goes where pair j is now.
        var waiting = [Int?](repeating: nil, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            let target = key(pair.to)
            if target != key(pair.from), let other = bySource[target], other != index {
                blocked[index] = true
                waiting[other] = index
            }
        }
        var steps: [ChainStep] = []
        var scheduled = [Bool](repeating: false, count: pairs.count)
        // Chains: start from the item whose new name is free, then the one that takes its old name, and so on.
        for start in pairs.indices where !blocked[start] {
            var next: Int? = start
            while let current = next, !scheduled[current] {
                scheduled[current] = true
                steps.append(ChainStep(from: pairs[current].from, to: pairs[current].to, pair: current, completes: current))
                next = waiting[current]
            }
        }
        // What's left are cycles.
        for start in pairs.indices where !scheduled[start] {
            let parked = parkingName(for: pairs[start].from)
            steps.append(ChainStep(from: pairs[start].from, to: parked, pair: start, completes: nil))
            scheduled[start] = true
            var next = waiting[start]
            while let current = next, !scheduled[current] {
                scheduled[current] = true
                steps.append(ChainStep(from: pairs[current].from, to: pairs[current].to, pair: current, completes: current))
                next = waiting[current]
            }
            steps.append(ChainStep(from: parked, to: pairs[start].to, pair: start, completes: start))
        }
        return steps
    }

    /// A hidden name beside `url` that still says what the item was called (".strata-1a2b3c4d-Photo.jpg"), so an
    /// interrupted swap leaves nothing anonymous.
    nonisolated static func parkingName(for url: URL) -> URL {
        let prefix = ".strata-" + UUID().uuidString.prefix(8).lowercased() + "-"
        var name = url.lastPathComponent
        while (prefix + name).utf8.count > 255 { name.removeLast() }
        return url.deletingLastPathComponent().appending(path: prefix + name)
    }

    /// Whether an item goes where another one is now (a swap or a chain of renames).
    nonisolated static func isChain(_ pairs: [Move]) -> Bool {
        func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
        let sources = Set(pairs.map { key($0.from) })
        return pairs.contains { key($0.to) != key($0.from) && sources.contains(key($0.to)) }
    }

    /// A translated piece of a file name ("untitled folder", " copy"), or the English one when the translation can't be
    /// part of a name: translations come from language files anyone can contribute, and a "/" or ".." in one must never
    /// place an item somewhere else (nor a leading "." hide it).
    nonisolated static func nameText(_ translated: String, english: String) -> String {
        let trimmed = translated.trimmingCharacters(in: .whitespaces)
        let unsafe = translated.contains("/") || translated.contains(":")
            || translated.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{0}" }
        // Nor "~…", which a plan would read as a path in your home folder.
        guard !unsafe, !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.hasPrefix("~"), translated.utf8.count <= 100 else { return english }
        return translated
    }

    static func newFolder(in directory: URL, undo: UndoManager?) throws -> URL {
        guard !ReadOnlyCopies.contains(directory) else { throw insideArchiveError }
        let name = nameText(String(localized: "untitled folder", comment: "Name of a new folder, as Finder names it"),
                            english: "untitled folder")
        let url = available(directory.appending(path: name), copyStyle: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let entry = OperationLog.shared.recordCreate("New Folder", [url])
        registerTrashUndo([url], "New Folder", undo, entry: entry)
        return url
    }

    /// File ▸ New File: an empty "untitled.txt" (`ext` is Settings' extension, "" for none), "untitled 2.txt" when that's
    /// taken. Never over anything: the name is claimed only while nothing is there, not even a link.
    static func newFile(in directory: URL, extension ext: String, undo: UndoManager?) throws -> URL {
        guard !ReadOnlyCopies.contains(directory) else { throw insideArchiveError }
        let name = newFileName(extension: ext)
        var url = available(directory.appending(path: name), copyStyle: false)
        for attempt in 0... {
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                break
            } catch CocoaError.fileWriteFileExists where attempt < 20 {
                // Something took the name meanwhile: the next free one.
                url = available(directory.appending(path: name), copyStyle: false)
            }
        }
        let entry = OperationLog.shared.recordCreate("New File", [url])
        registerTrashUndo([url], "New File", undo, entry: entry)
        return url
    }

    /// What New File calls a file: "untitled.txt", "untitled" with no extension. `stem` replaces "untitled" ("untitled 2").
    nonisolated static func newFileName(extension ext: String, stem: String? = nil) -> String {
        let base = stem ?? nameText(String(localized: "untitled", comment: "Name of a new empty file, before its extension: “untitled.txt”"),
                                    english: "untitled")
        return ext.isEmpty ? base : base + "." + ext
    }

    /// An extension for new files as typed in Settings ("txt", ".md", " TXT "), without its dot; nil when it can't be one.
    /// Letters, digits, "-", "_" and "+" only: no dots, slashes or spaces, so a new file is always one plain name.
    nonisolated static func newFileExtension(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(".") { text.removeFirst() }
        guard text.utf8.count <= 32,
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_+".unicodeScalars.contains($0) }) else { return nil }
        return text
    }

    /// With `record: false` the trashing is part of another operation (undoing a copy, say): its undo then marks
    /// History entry `entry` as `marksUndone` once it has worked. Returns where the items went.
    @discardableResult
    static func trash(_ urls: [URL], undo: UndoManager?, record: Bool = true, entry: UUID? = nil,
                      marksUndone: Bool = true) throws -> [Move] {
        var moved: [Move] = []
        defer {
            let logged = record ? OperationLog.shared.recordMove("Move to Trash", moved) : entry
            registerMoveUndo(moved, "Move to Trash", undo, entry: logged, marksUndone: record ? true : marksUndone)
        }
        for url in urls where !ReadOnlyCopies.contains(url) {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let result { moved.append((from: url, to: result as URL)) }
        }
        trashSound?.stop()
        trashSound?.play()
        return moved
    }

    /// Removes each folder only if it's empty (a Finder `.DS_Store` aside), innermost first. `rmdir` refuses a folder
    /// that isn't empty, so nothing put there in the meantime is ever deleted.
    nonisolated static func removeEmptyFolders(_ folders: [URL]) {
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            let store = folder.appending(path: ".DS_Store").path
            // Only once the folder holds nothing else: the records file alone doesn't keep it.
            if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path), names == [".DS_Store"] {
                unlink(store)
            }
            rmdir(folder.path)
        }
    }

    /// Items that couldn't go to the Trash because their disk has none (network shares, some external disks).
    struct NoTrash: Error {
        let urls: [URL]
    }

    /// Moves `urls` to the Trash off the main thread (a big selection or a slow disk would freeze the window), then
    /// records and registers undo like `trash`. Items on disks without a Trash come back in `NoTrash`.
    static func trashInBackground(_ urls: [URL], undo: UndoManager?) async throws {
        let (moved, identities, noTrash, failure) = await trashItems(urls)
        let entry = OperationLog.shared.recordMove("Move to Trash", moved)
        let landed = Landed()
        for (move, identity) in zip(moved, identities) { landed.set(identity, at: move.to) }
        registerMoveUndo(moved, "Move to Trash", undo, entry: entry, landed: landed)
        if !moved.isEmpty {
            trashSound?.stop()
            trashSound?.play()
        }
        if let failure { throw failure }
        if !noTrash.isEmpty { throw NoTrash(urls: noTrash) }
    }

    /// Whether Move to Trash may take `url`. Never a Trash itself, nor what's already in one (trashing it again would
    /// lose where it came from), however either's path is spelled; nor anything inside an archive opened as a folder
    /// (a temporary copy). A link to a Trash is only a link.
    nonisolated static func canTrash(_ url: URL) -> Bool {
        !Trash.isTrash(anySpelling: url) && !Trash.isInTrash(url) && !Trash.isInTrash(url.resolvingSymlinksInPath())
            && !ReadOnlyCopies.contains(url)
    }

    @concurrent
    private static func trashItems(_ urls: [URL]) async -> (moved: [Move], identities: [String?], noTrash: [URL], failure: Error?) {
        var moved: [Move] = []
        var identities: [String?] = []
        var noTrash: [URL] = []
        for url in urls where canTrash(url) {
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let result {
                    moved.append((from: url, to: result as URL))
                    identities.append(Landed.identity(result.path ?? ""))
                }
            } catch let error as CocoaError where error.code == .featureUnsupported {
                noTrash.append(url)
            } catch {
                return (moved, identities, noTrash, error)
            }
        }
        return (moved, identities, noTrash, nil)
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
            let suffix = !copyStyle ? " \(n + 1)"
                : n == 1 ? nameText(String(localized: " copy", comment: "Added to a duplicate’s name like Finder: “Report copy.pdf”. Keep the leading space."),
                                    english: " copy")
                // The number stays plain digits ("copy 2"), whatever the region: it's part of a name on disk.
                : nameText(String(localized: " copy \(String(n))", comment: "Added to a later duplicate’s name like Finder: “Report copy 2.pdf”. Keep the leading space."),
                           english: " copy \(n)")
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

    /// Where items landed and what they are there, so an operation's undo moves or trashes only those very items: never
    /// one put in an item's place since, however alike its name. Each is recorded as it lands (or, for a move on one
    /// disk, before it starts), never later, when something else may already be there. Kept for this run only, so an
    /// item is its disk, file number and birth time, read without following a link (History's `OperationLog.identity`
    /// also outlives a disk being plugged in again).
    final class Landed {
        private var identities: [String: String] = [:]

        /// What's at each of `urls` now: for items that have just landed there.
        init(_ urls: [URL] = []) { record(urls) }

        nonisolated static func identity(_ path: String) -> String? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec).\(info.st_birthtimespec.tv_nsec)"
        }

        func record(_ urls: [URL]) {
            for url in urls { identities[url.path] = Self.identity(url.path) }
        }

        /// `identity` (from `Landed.identity`), read when the item landed at `url`.
        func set(_ identity: String?, at url: URL) {
            identities[url.path] = identity
        }

        /// The item at `url` is about to move to `destination`: a move on one disk keeps what it is, so it's expected
        /// there already. Call `arrived` once it's moved.
        func expect(_ url: URL, at destination: URL) {
            identities[destination.path] = Self.identity(url.path)
        }

        /// An expected item has moved to `destination`. Moved across disks, it's a new file there, recorded now; on one
        /// disk the expectation stands, so a file swapped in meanwhile is never taken for it.
        func arrived(_ destination: URL) {
            guard let expected = identities[destination.path], let now = Self.identity(destination.path) else { return }
            if Self.disk(expected) != Self.disk(now) { identities[destination.path] = now }
        }

        func holds(_ url: URL) -> Bool {
            guard let identity = identities[url.path] else { return false }
            return Self.identity(url.path) == identity
        }

        private static func disk(_ identity: String) -> Substring {
            identity.prefix { $0 != ":" }
        }
    }

    /// Undo for something just made: it goes to the Trash; redoing brings it back. History follows both.
    private static func registerTrashUndo(_ created: [URL], _ actionName: String, _ undo: UndoManager?, entry: UUID?) {
        guard !created.isEmpty else { return }
        let landed = Landed(created)
        register(actionName, undo) { undo in
            do {
                let made = created.filter(landed.holds)
                guard !made.isEmpty else { return }
                try trash(made, undo: undo, record: false, entry: entry, marksUndone: false)
                if let entry { OperationLog.shared.setUndone(entry, true) }
            } catch {
                reportUndoFailure(actionName, error)
            }
        }
    }

    /// ⌘Z couldn't put things back (something now sits where an item would return, say): say so rather than fail
    /// silently.
    static func reportUndoFailure(_ actionName: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t undo “\(OperationLog.displayName(actionName))”")
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
        undo.setActionName(OperationLog.displayName(actionName))
    }

    /// ⌘Z and ⇧⌘Z work that moves items, done one step at a time in the order pressed, however quickly: each step
    /// finds the items where the one before left them (`undoWork` is the latest; tests wait for it).
    static var undoWork: Task<Void, Never>?

    /// Runs `work` after every undo and redo step before it.
    @discardableResult
    static func afterUndoWork(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = undoWork
        let task = Task {
            await previous?.value
            await work()
        }
        undoWork = task
        return task
    }

    /// Undo for completed moves: move the items back, those still where they went. The inverse is registered right
    /// away, inside the undo handler, so it lands on the redo stack (registering it later from a task would put it
    /// back on the undo stack); the moves run after the steps before (`undoWork`) and take only what's still where
    /// they left it (`landed`, recorded as each lands). History entry `entry` is marked `marksUndone` only once the
    /// moves have worked (the inverse flips it back); `folders` are recreated first if they've gone (the folders an AI
    /// plan made, removed by undoing it).
    static func registerMoveUndo(_ moves: [Move], _ actionName: String, _ undo: UndoManager?, entry: UUID? = nil,
                                 marksUndone: Bool = true, recreating folders: [URL] = [], landed: Landed? = nil) {
        guard !moves.isEmpty else { return }
        let landed = landed ?? Landed(moves.map(\.to))
        register(actionName, undo) { undo in
            let returned = Landed()
            afterUndoWork {
                let back = moves.filter { landed.holds($0.to) }.reversed().map { (from: $0.to, to: $0.from) }
                guard !back.isEmpty else { return }
                for pair in back { returned.expect(pair.from, at: pair.to) }
                do {
                    for folder in folders where !FileManager.default.fileExists(atPath: folder.path) {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    }
                    guard !back.contains(where: { ReadOnlyCopies.contains($0.from) || ReadOnlyCopies.contains($0.to) }) else {
                        throw insideArchiveError
                    }
                    let (done, error) = await moveAll(back)
                    done.forEach { returned.arrived($0.to) }
                    if let error { throw error }
                    if let entry { OperationLog.shared.setUndone(entry, marksUndone) }
                } catch {
                    reportUndoFailure(actionName, error)
                }
            }
            registerMoveUndo(moves.reversed().map { (from: $0.to, to: $0.from) }, actionName, undo, entry: entry,
                             marksUndone: !marksUndone, landed: returned)
        }
    }

    @concurrent
    private static func moveItem(_ from: URL, _ to: URL) async throws {
        try FileManager.default.moveItem(at: from, to: to)
    }
}

/// Finder-compatible file clipboard, plus cut: ⌘X marks the items and the next paste moves them.
enum Clipboard {
    /// The general pasteboard; tests use one of their own.
    static var pasteboard = NSPasteboard.general
    private static var cut: (urls: Set<URL>, changeCount: Int)?

    static func write(_ urls: [URL], cut isCut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cut = isCut ? (Set(urls), pasteboard.changeCount) : nil
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static func read() -> (urls: [URL], isCut: Bool) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, cut?.changeCount == pasteboard.changeCount)
    }

    static func isCut(_ url: URL) -> Bool {
        guard let cut, cut.changeCount == pasteboard.changeCount else { return false }
        return cut.urls.contains(url)
    }

    static func clearCut() {
        cut = nil
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}
