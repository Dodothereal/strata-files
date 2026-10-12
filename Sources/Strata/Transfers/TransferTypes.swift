import AppKit

nonisolated enum TransferMode: Sendable {
    case copy, move
}

nonisolated enum TransferState: Sendable {
    case queued, scanning, running, paused, finished, failed, cancelled

    /// Still has work ahead of it (or is waiting on the user).
    var isActive: Bool {
        switch self {
        case .queued, .scanning, .running, .paused: true
        case .finished, .failed, .cancelled: false
        }
    }
}

/// What to do with an item whose name is already taken at the destination.
nonisolated enum ConflictDecision: Sendable {
    /// Move the existing item to the Trash, then write the incoming one in its place.
    case replace
    /// Write the incoming item next to the existing one as `name 2.ext`.
    case keepBoth
    /// Leave the existing item alone and don't transfer this one.
    case skip
    /// Copying a folder onto a folder: add what's missing and merge subfolders; where both have an item of the same
    /// name, the newer one wins (the older goes to the Trash).
    case merge
    /// Cancel the whole job.
    case stop
}

nonisolated struct ConflictResolution: Sendable {
    var decision: ConflictDecision
    /// Use the same decision for every remaining conflict in this job without asking again.
    var applyToAll: Bool = false
}

nonisolated struct TransferConflict: Sendable {
    let mode: TransferMode
    /// The item being copied or moved.
    let source: URL
    /// The item already at the destination.
    let existing: URL
    /// Conflicts still to be decided in this job, this one included.
    let remaining: Int

    /// Merge is offered when copying a folder onto a folder (like Finder's Option-drag).
    var canMerge: Bool {
        mode == .copy && TransferEngine.isPlainFolder(source) && TransferEngine.isPlainFolder(existing)
    }
}

/// Answers conflicts for a job. Use `.sheet(for:)` in the UI; `.keepBoth` never asks.
struct ConflictResolver {
    let resolve: @MainActor (TransferConflict) async -> ConflictResolution

    init(_ resolve: @escaping @MainActor (TransferConflict) async -> ConflictResolution) {
        self.resolve = resolve
    }

    static let keepBoth = ConflictResolver { _ in ConflictResolution(decision: .keepBoth, applyToAll: true) }
    static let skip = ConflictResolver { _ in ConflictResolution(decision: .skip, applyToAll: true) }
    static let replace = ConflictResolver { _ in ConflictResolution(decision: .replace, applyToAll: true) }
}

/// One thing that went wrong. The job carries on with everything else and can retry these afterwards.
nonisolated struct TransferFailure: Sendable {
    enum Stage: Sendable {
        /// The whole item: missing source, can't trash the item it replaces, can't create the destination…
        case item
        /// One file or folder inside the item couldn't be copied.
        case copy
        /// The copy's contents differ from the original.
        case verify
        /// Everything was copied, but the original couldn't be removed afterwards (cross-volume moves).
        case removeSource
    }

    /// Index of the top-level item in the job.
    let item: Int
    let stage: Stage
    let source: URL
    let destination: URL?
    let message: String

    var displayName: String { source.lastPathComponent }
}

nonisolated struct TransferMove: Sendable, Equatable {
    var from: URL
    var to: URL

    var reversed: TransferMove { TransferMove(from: to, to: from) }
}
