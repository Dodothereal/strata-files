import Foundation

extension Notification.Name {
    static let operationLogChanged = Notification.Name("StrataOperationLogChanged")
}

/// A journal of file operations that survives restarts, so any of them can be undone later from the History window
/// (the Edit menu's Undo only covers the current session).
final class OperationLog {
    nonisolated struct Entry: Codable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// `pairs` moved from → to (moves, renames, trash).
            case move
            /// `created` were made (copies, duplicates, new folders).
            case create
        }

        var id = UUID()
        var date = Date()
        var name: String
        var kind: Kind
        /// Items moved, from → to.
        var pairs: [[String]] = []
        /// Items the operation made (copies, duplicates, new folders): undo moves them to the Trash.
        var created: [String] = []
        /// Items the operation replaced, from their place → the Trash: undo brings them back.
        var replaced: [[String]] = []
        /// Folders made to hold moved items: undo removes them once they're empty again.
        var containers: [String] = []
        /// Which file each recorded path held right after the operation ("device:inode"): undo only touches those
        /// same files, never something else that took their place since.
        var identities: [String: String] = [:]
        var undone = false
        /// When it was last undone or redone (nil: never since it was done, at `date`).
        var changed: Date?

        init(name: String, kind: Kind, pairs: [[String]] = [], created: [String] = [], replaced: [[String]] = [],
             containers: [String] = []) {
            self.name = name
            self.kind = kind
            self.pairs = pairs
            self.created = created
            self.replaced = replaced
            self.containers = containers
            for path in pairs.map({ $0[1] }) + created + replaced.map({ $0[1] }) {
                identities[path] = OperationLog.identity(path)
            }
        }

        // History saved by earlier versions lacks the newer fields.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            date = try c.decode(Date.self, forKey: .date)
            name = try c.decode(String.self, forKey: .name)
            kind = try c.decode(Kind.self, forKey: .kind)
            pairs = try c.decodeIfPresent([[String]].self, forKey: .pairs) ?? []
            created = try c.decodeIfPresent([String].self, forKey: .created) ?? []
            replaced = try c.decodeIfPresent([[String]].self, forKey: .replaced) ?? []
            containers = try c.decodeIfPresent([String].self, forKey: .containers) ?? []
            identities = try c.decodeIfPresent([String: String].self, forKey: .identities) ?? [:]
            undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
            changed = try c.decodeIfPresent(Date.self, forKey: .changed)
        }

        /// `name` as History shows it, in the app's language.
        var displayName: String { OperationLog.displayName(name) }
    }

    /// An operation's name as History and the Edit menu show it. Entries keep the English name they were recorded
    /// with (it's saved, and History picks its icon by it); the known ones are translated here, anything else is shown
    /// as recorded.
    nonisolated static func displayName(_ name: String) -> String {
        switch name {
        case "Copy": String(localized: "Copy", comment: "Undo and History action name: a copy")
        case "Move": String(localized: "Move", comment: "Undo and History action name: a move")
        case "Duplicate": String(localized: "Duplicate", comment: "Undo and History action name")
        case "Rename": String(localized: "Rename", comment: "Undo and History action name")
        case "Move to Trash": String(localized: "Move to Trash", comment: "Undo and History action name")
        case "New Folder": String(localized: "New Folder", comment: "Undo and History action name")
        case "Compress": String(localized: "Compress", comment: "Undo and History action name: making a zip")
        case "Extract": String(localized: "Extract", comment: "Undo and History action name: unpacking an archive")
        case "Put Back": String(localized: "Put Back", comment: "Undo and History action name: items taken out of the Trash")
        case "Sync": String(localized: "Sync", comment: "Undo and History action name: syncing two folders")
        case "AI Rename": String(localized: "AI Rename", comment: "Undo and History action name")
        case "AI Move": String(localized: "AI Move", comment: "Undo and History action name")
        case "AI Organize": String(localized: "AI Organize", comment: "Undo and History action name")
        case "AI Move to Trash": String(localized: "AI Move to Trash", comment: "Undo and History action name")
        case "AI Changes": String(localized: "AI Changes", comment: "Undo and History action name")
        default: name
        }
    }

    static let shared = OperationLog()

    private(set) var entries: [Entry] = []
    private let file: URL
    private let limit = 500

    private init() {
        file = SecureStorage.url("history.sealed")
        if let data = SecureStorage.read(file), let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
        // Never import a plain history file: anything running as you could plant one, and undoing its entries would
        // move files with Strata's access. One from an earlier build is simply removed.
        SecureStorage.removeLegacy(SecureStorage.url("history.json"))
    }

    @discardableResult
    func recordMove(_ name: String, _ pairs: [(from: URL, to: URL)]) -> UUID? {
        guard !pairs.isEmpty else { return nil }
        return append(Entry(name: name, kind: .move, pairs: Self.paths(pairs)))
    }

    @discardableResult
    func recordCreate(_ name: String, _ created: [URL]) -> UUID? {
        guard !created.isEmpty else { return nil }
        return append(Entry(name: name, kind: .create, created: created.map(\.path)))
    }

    /// One entry for a whole copy or move job, including what it replaced.
    @discardableResult
    func recordTransfer(_ name: String, created: [URL], moved: [(from: URL, to: URL)],
                        replaced: [(from: URL, to: URL)], containers: [URL] = []) -> UUID? {
        guard !(created.isEmpty && moved.isEmpty) else { return nil }
        return append(Entry(name: name, kind: created.isEmpty ? .move : .create, pairs: Self.paths(moved),
                            created: created.map(\.path), replaced: Self.paths(replaced), containers: containers.map(\.path)))
    }

    /// One entry for an applied Ask Strata plan: its moves (Trash included) and the folders it made for them.
    @discardableResult
    func recordPlan(_ name: String, moved: [(from: URL, to: URL)], containers: [URL]) -> UUID? {
        guard !moved.isEmpty else { return nil }
        return append(Entry(name: name, kind: .move, pairs: Self.paths(moved), containers: containers.map(\.path)))
    }

    /// Keeps an entry in step with ⌘Z and ⇧⌘Z (undoing marks it undone; redoing marks it done again).
    func setUndone(_ id: UUID, _ undone: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].undone != undone else { return }
        entries[index].undone = undone
        entries[index].changed = Date()
        save()
    }

    private static func paths(_ pairs: [(from: URL, to: URL)]) -> [[String]] {
        pairs.map { [$0.from.path, $0.to.path] }
    }

    /// The file at `path` as "device:inode", or nil when nothing is there.
    /// The file at `path` as "<volume UUID>/<inode>" (a disk's device number changes when it's plugged in again, its
    /// UUID doesn't), or nil when nothing is there.
    nonisolated static func identity(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let volume = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return "\(volume ?? String(info.st_dev))/\(info.st_ino)"
    }

    /// Identities recorded before volume UUIDs were used ("device:inode") compare by those two.
    private nonisolated static func sameIdentity(_ recorded: String, _ path: String) -> Bool {
        guard recorded.contains(":"), !recorded.contains("/") else { return identity(path) == recorded }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return recorded == "\(info.st_dev):\(info.st_ino)"
    }

    /// For each of `urls`: where it was before Strata last put it where it is, and when that happened. Two kinds of
    /// event put an item somewhere: an operation that moved it there (or its redo), and the undo of one that had moved
    /// it away (undoing a Put Back returns the item to the Trash). The latest wins, and only while the file there is
    /// still the one that was moved. Keyed by standardized path; one pass over History.
    func movedFrom(_ urls: [URL]) -> [String: (from: URL, date: Date)] {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var found: [String: (from: URL, date: Date)] = [:]
        for entry in entries {
            let when = entry.changed ?? entry.date
            for pair in entry.pairs where pair.count == 2 {
                let here = URL(fileURLWithPath: entry.undone ? pair[0] : pair[1]).standardizedFileURL.path
                guard wanted.contains(here), found[here].map({ $0.date <= when }) ?? true else { continue }
                // The identity was recorded where the operation left the file, at `pair[1]`.
                let same = entry.identities[pair[1]].map { Self.sameIdentity($0, here) } ?? TransferEngine.exists(URL(fileURLWithPath: here))
                guard same else { continue }
                found[here] = (URL(fileURLWithPath: entry.undone ? pair[1] : pair[0]), when)
            }
        }
        return found
    }

    /// `path` still holds the file the operation left there (entries from before identities were kept: it exists).
    private func holdsOriginal(_ entry: Entry, _ path: String) -> Bool {
        guard let recorded = entry.identities[path] else { return TransferEngine.exists(URL(fileURLWithPath: path)) }
        return Self.sameIdentity(recorded, path)
    }

    /// Whether undoing `entry` can still work: the very items the operation left are still where it left them, and
    /// nothing else occupies the places they'd go back to (a case-only rename's old spelling is the item itself).
    func canUndo(_ entry: Entry) -> Bool {
        guard !entry.undone else { return false }
        // A place counts as free when nothing is there, it's the item itself (a case-only rename), or another move in
        // the same entry will vacate it first ("trash X, rename Y to X").
        let destinations = Set(entry.pairs.map { $0[1] })
        let movesBack = !entry.pairs.isEmpty && entry.pairs.allSatisfy { pair in
            holdsOriginal(entry, pair[1])
                && (Self.identity(pair[0]) == nil || Self.identity(pair[0]) == Self.identity(pair[1]) || destinations.contains(pair[0]))
        }
        switch entry.kind {
        case .move:
            return movesBack
        case .create:
            return entry.created.contains { holdsOriginal(entry, $0) } || movesBack
        }
    }

    /// Reverses `entry`: created items go to the Trash, moves go back, replaced items come back out of the Trash, and
    /// folders made for moved items are removed if empty. The reversal is itself undoable with ⌘Z.
    func undo(_ entry: Entry, undoManager: UndoManager?) async throws {
        // Checked again now: the window may have been open a while.
        guard canUndo(entry) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "“\(entry.displayName)” can’t be undone: its items have moved or changed since."),
            ])
        }
        // Everything happens without registering undo piecemeal; one ⌘Z afterwards puts it all back (below).
        var done: [FileOps.Move] = []
        let existing = entry.created.filter { holdsOriginal(entry, $0) }.map { URL(fileURLWithPath: $0) }
        if !existing.isEmpty { done += try FileOps.trash(existing, undo: nil, record: false) }
        let back = (entry.pairs.reversed() + entry.replaced.reversed().filter { holdsOriginal(entry, $0[1]) }).map {
            (from: URL(fileURLWithPath: $0[1]), to: URL(fileURLWithPath: $0[0]))
        }
        if !back.isEmpty {
            do {
                try await FileOps.move(back, actionName: "Undo \(entry.name)", undo: nil, record: false)
                done += back
            } catch {
                // Part of it may have moved: keep ⌘Z able to put back what did.
                registerRedo(entry, done + back.filter { !TransferEngine.exists($0.from) && TransferEngine.exists($0.to) },
                             undoManager)
                throw error
            }
        }
        // Only what is (still) empty: never remove something put there since.
        FileOps.removeEmptyFolders(entry.containers.map { URL(fileURLWithPath: $0) })
        setUndone(entry.id, true)
        registerRedo(entry, done, undoManager)
    }

    /// ⌘Z right after a History undo redoes the whole operation in one step (recreating any folders it had made)
    /// and marks the entry live again once that has worked.
    private func registerRedo(_ entry: Entry, _ done: [FileOps.Move], _ undoManager: UndoManager?) {
        FileOps.registerMoveUndo(done, entry.name, undoManager, entry: entry.id, marksUndone: false,
                                 recreating: entry.containers.map { URL(fileURLWithPath: $0) })
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func append(_ entry: Entry) -> UUID {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        save()
        return entry.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? SecureStorage.write(data, to: file) }
        NotificationCenter.default.post(name: .operationLogChanged, object: self)
    }
}
