import Foundation

/// Calls `onChange` (debounced) when entries are added to, removed from, or renamed inside a directory.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var debounce: DispatchWorkItem?

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule(onChange) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    private func schedule(_ onChange: @escaping () -> Void) {
        debounce?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
