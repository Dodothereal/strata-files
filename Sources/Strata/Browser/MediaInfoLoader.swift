import Foundation
import UniformTypeIdentifiers

/// Only requested columns read media. Limit concurrent readers, reuse snapshots, and discard work on navigation.
final class MediaInfoLoader {
    var onUpdate: ((FileEntry) -> Void)?
    private var cache: [FileEntry: MediaInfo] = [:]
    private var pending: [FileEntry] = []
    private var requested: Set<FileEntry> = []
    private var tasks: [FileEntry: Task<Void, Never>] = [:]
    private var generation = 0
    private let reader: @Sendable (FileEntry) async -> MediaInfo

    init(reader: @escaping @Sendable (FileEntry) async -> MediaInfo = {
        await MediaInfo.read($0.url, contentType: $0.contentType)
    }) {
        self.reader = reader
    }

    func cached(_ entry: FileEntry) -> MediaInfo? { cache[entry] }

    static func canRead(_ entry: FileEntry) -> Bool {
        !entry.isDirectory && !entry.isSymlink && !LazyCopies.isPlaceholder(entry.url)
            && (entry.contentType?.conforms(to: .image) == true || entry.contentType?.conforms(to: .audiovisualContent) == true)
    }

    func request(_ entry: FileEntry) {
        guard Self.canRead(entry), cache[entry] == nil, requested.insert(entry).inserted else { return }
        pending.append(entry)
        startNext()
    }

    func cancelPending() {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pending.removeAll()
        requested.removeAll()
        cache.removeAll()
    }

    private func startNext() {
        while tasks.count < 4, let entry = pending.popLast() {
            let gen = generation
            let reader = reader
            tasks[entry] = Task { [weak self] in
                let info = await reader(entry)
                guard let self, !Task.isCancelled, gen == generation else { return }
                tasks[entry] = nil
                cache[entry] = info
                requested.remove(entry)
                onUpdate?(entry)
                startNext()
            }
        }
    }
}
