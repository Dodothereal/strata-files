import AppKit

/// Applies the enabled steps of a validated plan as one undoable action ("AI Rename").
///
/// Renames and moves go through `FileOps.move` one pair at a time (so a failure part-way still knows exactly what happened).
/// New folders and Trash are done here because `FileOps` has no named-folder API and `FileOps.trash` doesn't report where items
/// went; both are needed to undo the whole plan in one step. Undo puts everything back (Trash restored, moves reversed, the
/// folders the plan created removed if empty); redo applies it again.
enum PlanExecutor {
    struct Outcome {
        var applied = 0
        var failures: [String] = []
        /// Where the changed items are now (for selecting them afterwards).
        var results: [URL] = []
    }

    static func apply(_ plan: Plan, actionName: String, undo: UndoManager?) async -> Outcome {
        let transaction = PlanTransaction(plan: plan)
        let outcome = await transaction.perform()
        // One History entry for the whole plan, named like its undo action.
        let entry = transaction.hasChanges ? transaction.record(actionName) : nil
        if let undo, transaction.hasChanges {
            transaction.registerUndo(undo, actionName: actionName)
            if let entry { FileOps.registerLogMark(entry, undone: true, undo) }
        }
        return outcome
    }

    /// "AI Rename", "AI Move", "AI Organize", "AI Trash".
    static func actionName(for plan: Plan) -> String {
        let kinds = Set(plan.enabledSteps.map(\.kind)).subtracting([.createFolder])
        if kinds == [.rename] { return "AI Rename" }
        if kinds == [.trash] { return "AI Move to Trash" }
        if kinds == [.move] { return plan.enabledSteps.contains { $0.kind == .createFolder } ? "AI Organize" : "AI Move" }
        return "AI Changes"
    }
}

final class PlanTransaction {
    typealias Pair = (from: URL, to: URL)

    private let folders: [URL]
    private let moves: [Pair]
    private let trashItems: [URL]
    private var created: [URL] = []
    private var done: [Pair] = []
    private var trashed: [Pair] = []
    private var queue: Task<Void, Never>?

    init(plan: Plan) {
        let enabled = plan.enabledSteps
        let moves = enabled.compactMap { step -> Pair? in
            guard step.kind == .rename || step.kind == .move, let from = step.source, let to = step.destination else { return nil }
            return (from, to)
        }
        // Only the folders an enabled move needs (or that were asked for explicitly), outermost first.
        let needed = Set(moves.map { PlanValidator.key($0.to.deletingLastPathComponent()) })
        folders = enabled.filter { $0.kind == .createFolder }.compactMap(\.destination).filter { folder in
            needed.contains { $0 == PlanValidator.key(folder) || $0.hasPrefix(PlanValidator.key(folder) + "/") }
        }
        self.moves = moves
        trashItems = enabled.filter { $0.kind == .trash }.compactMap(\.source)
    }

    var hasChanges: Bool { !created.isEmpty || !done.isEmpty || !trashed.isEmpty }

    func record(_ name: String) -> UUID? {
        OperationLog.shared.recordPlan(name, moved: (done + trashed).map { (from: $0.from, to: $0.to) }, containers: created)
    }

    func perform() async -> PlanExecutor.Outcome {
        var outcome = PlanExecutor.Outcome()
        created = []
        done = []
        trashed = []
        let fm = FileManager.default
        for folder in folders where !fm.fileExists(atPath: folder.path) {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                created.append(folder)
            } catch {
                outcome.failures.append("Couldn’t create “\(folder.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        // Trash first: a plan may rename something into a name it frees ("trash X, rename Y to X").
        for url in trashItems {
            do {
                var result: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &result)
                if let result { trashed.append((url, result as URL)) }
            } catch {
                outcome.failures.append("“\(url.lastPathComponent)” couldn’t be moved to the Trash: \(error.localizedDescription)")
            }
        }
        for pair in moves {
            do {
                try await Self.move(pair)
                done.append(pair)
                outcome.results.append(pair.to)
            } catch {
                outcome.failures.append("“\(pair.from.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        outcome.applied = done.count + trashed.count
        return outcome
    }

    func revert() async {
        // The reverse of `perform`: moves back first (freeing names), then the Trash.
        for pair in done.reversed() { try? await Self.move((pair.to, pair.from)) }
        for pair in trashed.reversed() { try? await Self.move((pair.to, pair.from)) }
        let fm = FileManager.default
        for folder in created.reversed() {
            // Only remove what is (still) empty: never delete something the user put there meanwhile.
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: folder) }
        }
    }

    /// Case-only renames ("photo.jpg" → "Photo.jpg") go through a temporary name on case-insensitive volumes.
    private static func move(_ pair: Pair) async throws {
        if pair.from.path != pair.to.path, pair.from.path.lowercased() == pair.to.path.lowercased() {
            let temporary = pair.from.deletingLastPathComponent().appending(path: ".strata-rename-\(UUID().uuidString)")
            try await FileOps.move([(from: pair.from, to: temporary)], actionName: "", undo: nil, record: false)
            do {
                try await FileOps.move([(from: temporary, to: pair.to)], actionName: "", undo: nil, record: false)
            } catch {
                // Never leave the item under its hidden temporary name.
                try? await FileOps.move([(from: temporary, to: pair.from)], actionName: "", undo: nil, record: false)
                throw error
            }
        } else {
            try await FileOps.move([pair], actionName: "", undo: nil, record: false)
        }
    }

    // MARK: - Undo

    /// One undo step for the whole plan. Each handler registers its opposite synchronously, so redo works too.
    /// The undo manager is the target (it doesn't retain targets); the closure keeps the transaction alive.
    func registerUndo(_ undo: UndoManager, actionName: String) {
        undo.registerUndo(withTarget: undo) { [self] undo in
            MainActor.assumeIsolated {
                registerRedo(undo, actionName: actionName)
                enqueue { await self.revert() }
            }
        }
        undo.setActionName(actionName)
    }

    private func registerRedo(_ undo: UndoManager, actionName: String) {
        undo.registerUndo(withTarget: undo) { [self] undo in
            MainActor.assumeIsolated {
                registerUndo(undo, actionName: actionName)
                enqueue { _ = await self.perform() }
            }
        }
        undo.setActionName(actionName)
    }

    /// Runs file work in order even if the user presses ⌘Z ⇧⌘Z quickly.
    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
            NotificationCenter.default.post(name: .planTransactionDidFinish, object: self)
        }
    }

    /// Waits for queued undo/redo work (for tests).
    func waitForIdle() async {
        await queue?.value
    }
}

extension Notification.Name {
    /// Posted after an undo or redo of an AI plan has finished moving files.
    static let planTransactionDidFinish = Notification.Name("StrataPlanTransactionDidFinish")
}
