import Foundation

/// Selection work owns one bounded preview lease and one explicit export. Detached completions only clean scratch.
@MainActor final class PreviewArchiveContent {
    private let previewRoot: URL
    private let clipboardRoot: URL
    private var previewID = UUID()
    private var commandID = UUID()
    private(set) var task: Task<Void, Never>?
    private(set) var commandTask: Task<Void, Never>?
    private(set) var lease: PreviewArchiveLease?
    private(set) var error: Error?
    private(set) var isLoading = false
    var onChange: (() -> Void)?
    var onReady: ((PreviewItem, PreviewArchiveLease) -> Void)?

    init(copies: CopyProviders) {
        clipboardRoot = copies.clipboardRoot
        previewRoot = copies.clipboardRoot.deletingLastPathComponent().appendingPathComponent("Previews.noindex", isDirectory: true)
    }

    isolated deinit { cancel() }

    func select(in session: PreviewSession) {
        cancel()
        lease = nil
        error = nil
        guard case .member(_, let path) = session.selected?.source, let item = session.selected,
              !item.isDirectory, let source = session.archiveAccess.source else { return }
        let id = previewID, generation = session.generation, access = session.archiveAccess, root = previewRoot
        isLoading = true
        task = Task { [weak self, weak session] in
            let result: Result<PreviewArchiveLease, Error>
            do {
                let records = try await access.read(member: path)
                result = .success(try await PreviewArchiveLease.materialize(records, member: path, in: root, source: source, preview: true))
            } catch { result = .failure(error) }
            guard let self, let session, !Task.isCancelled, previewID == id,
                  !session.isClosed, session.generation == generation, session.selected === item else { return }
            task = nil
            isLoading = false
            switch result {
            case .success(let lease): self.lease = lease; onReady?(item, lease)
            case .failure(let error): if !(error is CancellationError) { self.error = error }
            }
            onChange?()
        }
        onChange?()
    }

    func export(_ target: PreviewCommandTarget, session: PreviewSession, completion: @escaping (PreviewArchiveLease) -> Void) {
        guard target.matches(session), case .member(_, let path) = target.item?.source,
              let source = session.archiveAccess.source else { return }
        let previous = task
        cancel()
        let id = commandID, access = session.archiveAccess, root = clipboardRoot, directory = target.item?.isDirectory == true
        isLoading = true
        error = nil
        commandTask = Task { [weak self, weak session] in
            // A cancelled password sheet finishes before another request may present one.
            await previous?.value
            let result: Result<PreviewArchiveLease, Error>
            do {
                try Task.checkCancellation()
                let records = try await access.read(member: path, directory: directory)
                result = .success(try await PreviewArchiveLease.materialize(records, member: path, in: root, source: source, preview: false))
            } catch { result = .failure(error) }
            guard let self, let session, !Task.isCancelled, commandID == id, target.matches(session) else { return }
            commandTask = nil
            isLoading = false
            switch result {
            case .success(let lease):
                completion(lease)
                if commandID == id, target.matches(session), !directory, let item = target.item,
                   item.size.map({ $0 <= PreviewArchiveReader.previewLimit }) == true {
                    onReady?(item, lease)
                    self.lease = lease
                }
            case .failure(let error): if !(error is CancellationError) { self.error = error }
            }
            onChange?()
        }
        onChange?()
    }

    func cancel() {
        previewID = UUID()
        commandID = UUID()
        task?.cancel(); task = nil
        commandTask?.cancel(); commandTask = nil
        isLoading = false
        onChange?()
    }

    func close() {
        cancel()
        lease = nil
        error = nil
        onReady = nil
        onChange = nil
    }
}
