import Foundation

/// Only an explicit Calculate Size walks a folder. File metadata and completed walks stay with their selection.
@MainActor final class PreviewMeasurement {
    typealias Reader = @MainActor (FootprintSource, Bool) async throws -> FileFootprint
    private let copies: CopyProviders
    private let read: Reader
    private var isClosed = false
    private var request = UUID()
    private weak var session: PreviewSession?
    private var generation = -1
    private weak var item: PreviewItem?
    private var source: FootprintSource?
    private var logical: Int64?
    private(set) var result: FileFootprint?
    private(set) var error: Error?
    private(set) var isLoading = false
    private(set) var task: Task<Void, Never>?
    var onChange: (() -> Void)?

    init(copies: CopyProviders, read: @escaping Reader = { try await FootprintReader.read($0, recursive: $1) }) {
        self.copies = copies
        self.read = read
    }

    isolated deinit { task?.cancel() }

    var canCalculate: Bool { source?.isDirectory == true && !isLoading }
    var text: String? {
        if let result {
            let logical = Format.bytes(result.logical), allocated = Format.bytes(result.allocated)
            return result.isComplete ? String(localized: "\(logical) · \(allocated) on disk", comment: "Preview size: logical contents, then filesystem allocated space")
                : String(localized: "At least \(logical) · \(allocated) on disk", comment: "Partial folder measurement: lower bounds for logical and allocated bytes")
        }
        return logical.map(Format.bytes)
    }

    func update(_ session: PreviewSession) {
        guard !isClosed, !session.isClosed else { return }
        guard self.session !== session || generation != session.generation || item !== session.selected else { return }
        cancel()
        self.session = session
        generation = session.generation
        item = session.selected
        source = nil
        result = nil
        error = nil
        let entry = item?.entry ?? (item == nil ? session.root : nil)
        logical = item?.isDirectory == false ? item?.size : (item == nil && entry?.isDirectory == false ? entry?.size : nil)
        guard let entry, !entry.isSymlink, !copies.contains(entry.url), !copies.isPlaceholder(entry.url) else { onChange?(); return }
        do {
            let source = try FootprintSource(entry.url)
            if item == nil, source.identity != session.rootIdentity { throw POSIXError(.ESTALE) }
            self.source = source
            if !source.isDirectory { start(recursive: false) } else { onChange?() }
        } catch { self.error = error; onChange?() }
    }

    func calculate() { if canCalculate { start(recursive: true) } }

    private func start(recursive: Bool) {
        guard let source else { return }
        cancel()
        error = nil
        isLoading = true
        let id = request, read = read
        task = Task { [weak self] in
            let value: Result<FileFootprint, Error>
            do { value = .success(try await read(source, recursive)) }
            catch { value = .failure(error) }
            guard let self, request == id, !Task.isCancelled, session?.isClosed == false else { return }
            task = nil
            isLoading = false
            switch value {
            case .success(let result): self.result = result
            case .failure(let error): if !(error is CancellationError) { self.error = error }
            }
            onChange?()
        }
        onChange?()
    }

    func cancel() {
        request = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        onChange?()
    }

    func close() {
        isClosed = true
        cancel()
        source = nil
        result = nil
        logical = nil
        error = nil
        session = nil
        item = nil
        generation = -1
        onChange = nil
    }
}
