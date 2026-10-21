import Foundation

/// The read capabilities of a browsable copy. Providers keep their own listing format, permissions, fetching policy
/// and error messages. Server writes and container archives remain separate from this interface.
nonisolated protocol CopyProvider: Sendable {
    func contains(_ url: URL) -> Bool
    func isPlaceholder(_ url: URL) -> Bool
    func refresh(_ folder: URL) async
    func invalidate(_ folder: URL) async
    func reveal(_ url: URL) async -> Bool
    func fetch(_ urls: [URL]) async throws
    func fetchSelection(_ urls: [URL], limit: Int64) async
    func prepareForCopying(_ urls: [URL]) async throws
    func message(for error: Error, about url: URL) -> String
    func displayPath(_ url: URL) -> String?
    func sourceName(_ url: URL) -> String?
}

/// Routes each URL to its owner. The order is stable: explicit reads finish one provider before starting the next,
/// and the first owner of a path handles it exactly once. Independent environments can supply their own providers.
nonisolated struct CopyProviders: Sendable {
    static let live = CopyProviders(servers: .shared, containers: .shared)
    private let providers: [any CopyProvider]

    init(_ providers: [any CopyProvider]) { self.providers = providers }

    init(servers: RemoteFiles, containers: ContainerFiles) {
        self.init([ServerCopyProvider(files: servers), ContainerCopyProvider(files: containers)])
    }

    private func provider(for url: URL) -> (any CopyProvider)? { providers.first { $0.contains(url) } }

    func contains(_ url: URL) -> Bool { provider(for: url) != nil }
    func isPlaceholder(_ url: URL) -> Bool { provider(for: url)?.isPlaceholder(url) ?? false }
    func refresh(_ folder: URL) async { await provider(for: folder)?.refresh(folder) }
    func invalidate(_ folder: URL) async { await provider(for: folder)?.invalidate(folder) }
    func reveal(_ url: URL) async -> Bool { await provider(for: url)?.reveal(url) ?? false }
    func displayPath(_ url: URL) -> String? { provider(for: url)?.displayPath(url) }
    func sourceName(_ url: URL) -> String? { provider(for: url)?.sourceName(url) }
    func message(for error: Error, about url: URL) -> String {
        provider(for: url)?.message(for: error, about: url) ?? error.localizedDescription
    }

    func fetch(_ urls: [URL]) async throws {
        for (provider, items) in groups(urls) { try await provider.fetch(items) }
    }

    func prepareForCopying(_ urls: [URL]) async throws {
        for (provider, items) in groups(urls) { try await provider.prepareForCopying(items) }
    }

    /// Selection prefetch is optional and bounded. Preserve the existing policy: only the first selected provider
    /// spends this budget; explicit opening or copying fetches every provider's items.
    func fetchSelection(_ urls: [URL], limit: Int64) async {
        if let (provider, items) = groups(urls).first { await provider.fetchSelection(items, limit: limit) }
    }

    private func groups(_ urls: [URL]) -> [(any CopyProvider, [URL])] {
        var items = Array(repeating: [URL](), count: providers.count)
        for url in urls {
            if let index = providers.firstIndex(where: { $0.contains(url) }) { items[index].append(url) }
        }
        return providers.indices.compactMap { items[$0].isEmpty ? nil : (providers[$0], items[$0]) }
    }
}

private nonisolated struct ServerCopyProvider: CopyProvider {
    let files: RemoteFiles
    func contains(_ url: URL) -> Bool { files.copies.contains(url) }
    func isPlaceholder(_ url: URL) -> Bool { files.copies.isPlaceholder(url) }
    func refresh(_ folder: URL) async { await files.refresh(folder) }
    func invalidate(_ folder: URL) async { await files.invalidate(folder) }
    func reveal(_ url: URL) async -> Bool { await files.reveal(url) }
    func fetch(_ urls: [URL]) async throws { try await files.fetch(urls) }
    func fetchSelection(_ urls: [URL], limit: Int64) async { await files.fetchSelection(urls, limit: limit) }
    func prepareForCopying(_ urls: [URL]) async throws { try await files.prepareForCopying(urls) }
    func message(for error: Error, about url: URL) -> String { RemoteFiles.message(for: error) }
    func displayPath(_ url: URL) -> String? { files.copies.displayPath(url) }
    func sourceName(_ url: URL) -> String? { files.copies.server(containing: url)?.server.name }
}

private nonisolated struct ContainerCopyProvider: CopyProvider {
    let files: ContainerFiles
    func contains(_ url: URL) -> Bool { ContainerCopies.contains(url) }
    func isPlaceholder(_ url: URL) -> Bool { ContainerCopies.isPlaceholder(url) }
    func refresh(_ folder: URL) async { await files.refresh(folder) }
    func invalidate(_ folder: URL) async { await files.invalidate(folder) }
    func reveal(_ url: URL) async -> Bool { await files.reveal(url) }
    func fetch(_ urls: [URL]) async throws { try await files.fetch(urls) }
    func fetchSelection(_ urls: [URL], limit: Int64) async { await files.fetchSelection(urls, limit: limit) }
    func prepareForCopying(_ urls: [URL]) async throws { try await files.prepareForCopying(urls) }
    func message(for error: Error, about url: URL) -> String {
        guard let source = ContainerCopies.copy(containing: url)?.source else { return error.localizedDescription }
        return ContainerFiles.message(for: error, source: source)
    }
    func displayPath(_ url: URL) -> String? { ContainerCopies.apparentPath(url) }
    func sourceName(_ url: URL) -> String? { ContainerCopies.copy(containing: url)?.source.name }
}
