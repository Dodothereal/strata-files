import Foundation

/// Reading a folder is independent of the AppKit view that presents it. Production keeps the existing disk/remote
/// loader; tests can hold a read open and deliver success or failure in a chosen order.
nonisolated struct DirectoryReader: Sendable {
    let read: @Sendable (URL, Bool, ApplicationsFolders) async throws -> [FileEntry]

    static let live = DirectoryReader { folder, hidden, applications in
        try await DirectoryLoader.load(folder, showHidden: hidden, applications: applications)
    }

    func load(_ folder: URL, showHidden: Bool, applications: ApplicationsFolders) async throws -> [FileEntry] {
        try await read(folder, showHidden, applications)
    }
}

/// One presentation's current read. Replaced or detached presentations discard late successes and errors, even if
/// the underlying reader cannot stop its I/O when cancelled. The view owns presentation state and applying entries.
final class DirectoryReadSession {
    private let reader: DirectoryReader
    private(set) var generation = 0
    private(set) var task: Task<Void, Never>?

    init(reader: DirectoryReader = .live) { self.reader = reader }

    isolated deinit { task?.cancel() }

    func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
    }

    @discardableResult
    func load(_ folder: URL, showHidden: Bool, applications: ApplicationsFolders,
              receive: @escaping (Result<[FileEntry], Error>, Int) -> Void) -> Task<Void, Never> {
        invalidate()
        let generation = generation, reader = reader
        let work = Task { [weak self] in
            let result: Result<[FileEntry], Error>
            do { result = .success(try await reader.load(folder, showHidden: showHidden, applications: applications)) }
            catch { result = .failure(error) }
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            task = nil
            receive(result, generation)
        }
        task = work
        return work
    }
}
