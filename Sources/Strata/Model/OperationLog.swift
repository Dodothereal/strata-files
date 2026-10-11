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
        var pairs: [[String]] = []
        var created: [String] = []
        var undone = false
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

    func recordMove(_ name: String, _ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        append(Entry(name: name, kind: .move, pairs: pairs.map { [$0.from.path, $0.to.path] }))
    }

    func recordCreate(_ name: String, _ created: [URL]) {
        guard !created.isEmpty else { return }
        append(Entry(name: name, kind: .create, created: created.map(\.path)))
    }

    /// Whether undoing `entry` can still work: the items are where the operation left them and nothing occupies
    /// the places they'd go back to.
    func canUndo(_ entry: Entry) -> Bool {
        guard !entry.undone else { return false }
        let fm = FileManager.default
        switch entry.kind {
        case .move:
            return entry.pairs.allSatisfy { fm.fileExists(atPath: $0[1]) && !fm.fileExists(atPath: $0[0]) }
        case .create:
            return entry.created.contains { fm.fileExists(atPath: $0) }
        }
    }

    /// Reverses `entry`: moves go back, created items go to the Trash. The reversal is itself undoable with ⌘Z.
    func undo(_ entry: Entry, undoManager: UndoManager?) async throws {
        switch entry.kind {
        case .move:
            let back = entry.pairs.reversed().map { (from: URL(fileURLWithPath: $0[1]), to: URL(fileURLWithPath: $0[0])) }
            try await FileOps.move(back, actionName: "Undo \(entry.name)", undo: undoManager)
        case .create:
            let existing = entry.created.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            try FileOps.trash(existing, undo: undoManager)
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].undone = true
            save()
        }
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? SecureStorage.write(data, to: file) }
        NotificationCenter.default.post(name: .operationLogChanged, object: self)
    }
}
