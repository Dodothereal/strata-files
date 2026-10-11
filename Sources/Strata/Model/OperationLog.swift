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
                        replaced: [(from: URL, to: URL)]) -> UUID? {
        guard !(created.isEmpty && moved.isEmpty) else { return nil }
        return append(Entry(name: name, kind: created.isEmpty ? .move : .create, pairs: Self.paths(moved),
                            created: created.map(\.path), replaced: Self.paths(replaced)))
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
        save()
    }

    private static func paths(_ pairs: [(from: URL, to: URL)]) -> [[String]] {
        pairs.map { [$0.from.path, $0.to.path] }
    }

    /// The file at `path` as "device:inode", or nil when nothing is there.
    nonisolated static func identity(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// `path` still holds the file the operation left there (entries from before identities were kept: it exists).
    private func holdsOriginal(_ entry: Entry, _ path: String) -> Bool {
        guard let current = Self.identity(path) else { return false }
        return entry.identities[path].map { $0 == current } ?? true
    }

    /// Whether undoing `entry` can still work: the very items the operation left are still where it left them, and
    /// nothing else occupies the places they'd go back to (a case-only rename's old spelling is the item itself).
    func canUndo(_ entry: Entry) -> Bool {
        guard !entry.undone else { return false }
        let movesBack = !entry.pairs.isEmpty && entry.pairs.allSatisfy { pair in
            holdsOriginal(entry, pair[1]) && (Self.identity(pair[0]) == nil || Self.identity(pair[0]) == Self.identity(pair[1]))
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
                NSLocalizedDescriptionKey: "“\(entry.name)” can’t be undone: its items have moved or changed since.",
            ])
        }
        let fm = FileManager.default
        let existing = entry.created.filter { holdsOriginal(entry, $0) }.map { URL(fileURLWithPath: $0) }
        if !existing.isEmpty { try FileOps.trash(existing, undo: undoManager, record: false) }
        let back = (entry.pairs.reversed() + entry.replaced.reversed().filter { holdsOriginal(entry, $0[1]) }).map {
            (from: URL(fileURLWithPath: $0[1]), to: URL(fileURLWithPath: $0[0]))
        }
        if !back.isEmpty { try await FileOps.move(back, actionName: "Undo \(entry.name)", undo: undoManager, record: false) }
        for folder in entry.containers.reversed() {
            // Only what is (still) empty: never remove something put there since.
            let contents = (try? fm.contentsOfDirectory(atPath: folder)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(atPath: folder) }
        }
        setUndone(entry.id, true)
        // ⌘Z right after puts the operation back, so the entry is live again.
        if let undoManager { FileOps.registerLogMark(entry.id, undone: false, undoManager) }
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
