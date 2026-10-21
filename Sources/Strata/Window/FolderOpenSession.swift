import Foundation

/// A pane owns one asynchronous folder opening. Leaving the pane's destination, closing it or starting another
/// opening discards late results even when the underlying I/O cannot stop immediately.
final class FolderOpenSession {
    final class Request {}
    struct Notice {
        let symbol: String
        let text: String
    }

    private(set) var request: Request?
    private(set) var notice: Notice?
    private var task: Task<Void, Never>?

    isolated deinit { cancel() }

    @discardableResult
    func open(notice: Notice? = nil, operation: @escaping @Sendable () async throws -> URL,
              receive: @escaping (Result<URL, Error>) -> Void) -> Task<Void, Never> {
        cancel()
        let request = Request()
        self.request = request
        self.notice = notice
        let work = Task { [weak self] in
            let result: Result<URL, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await operation())
            } catch { result = .failure(error) }
            guard let self, self.request === request else { return }
            self.request = nil
            self.notice = nil
            task = nil
            guard !Task.isCancelled else { return }
            receive(result)
        }
        task = work
        return work
    }

    /// A native Cancel button belongs to the request it displayed, never a later replacement.
    @discardableResult
    func cancel(_ request: Request) -> Bool {
        guard self.request === request else { return false }
        cancel()
        return true
    }

    func cancel() {
        request = nil
        notice = nil
        let work = task
        task = nil
        work?.cancel()
    }
}
