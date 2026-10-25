import Foundation

/// Shared by covers, page grids and chapters; cancellation drains the actual worker before returning its slot.
package actor ArchiveReadAllowance {
    package static let shared = ArchiveReadAllowance()
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    package func enter(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
    }
    package func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    package func leave() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume() }
    }
}
