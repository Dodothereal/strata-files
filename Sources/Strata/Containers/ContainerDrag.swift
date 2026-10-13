import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// A container's item dragged within Strata: its path in the copy (other apps get a file promise).
    nonisolated static let strataContainerItem = NSPasteboard.PasteboardType("dev.strata.container-item")
}

/// What dragging an item of a container's files puts on the pasteboard: a file promise, so the app it's dropped on
/// waits while Strata fetches all of it (a folder with everything in it), never a half-read copy. Strata's own views
/// read the item's path instead and copy it like any other file.
nonisolated final class ContainerDragItem: NSFilePromiseProvider {
    let source: URL

    init(source: URL) {
        self.source = source
        super.init()
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? .data
        fileType = type.identifier
        delegate = ContainerPromises.shared
    }

    /// An item of a container's files gets a promise; anything else drags as itself.
    @MainActor
    static func writer(for url: URL) -> NSPasteboardWriting {
        ContainerCopies.contains(url) ? ContainerDragItem(source: url) : url as NSURL
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.strataContainerItem]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .strataContainerItem ? source.path : super.pasteboardPropertyList(forType: type)
    }
}

/// Keeps file promises: fetches the item from its container, then copies it where it was dropped.
nonisolated final class ContainerPromises: NSObject, NSFilePromiseProviderDelegate, Sendable {
    static let shared = ContainerPromises()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? ContainerDragItem)?.source.lastPathComponent ?? "Item"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let source = (provider as? ContainerDragItem)?.source else { return completionHandler(CocoaError(.fileNoSuchFile)) }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        Task {
            do {
                try await ContainerFiles.shared.prepareForCopying([source])
                try FileManager.default.copyItem(at: source, to: url)
                ContainerCopies.finishCopyingOut(url)
            } catch {
                failure = error
            }
            done.signal()
        }
        done.wait()
        completionHandler(failure)
    }
}

extension FileDrop {
    /// Items of containers' files dragged within Strata (see `ContainerDragItem`).
    static func containerItems(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .strataContainerItem) }
            .map { URL(fileURLWithPath: $0) }.filter(ContainerCopies.contains)
    }
}
