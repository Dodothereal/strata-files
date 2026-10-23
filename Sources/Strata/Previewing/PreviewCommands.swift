import AppKit

enum PreviewAction: CaseIterable {
    case open, showInStrata, copy, copyPath

    var title: String {
        switch self {
        case .open: String(localized: "Open")
        case .showInStrata: String(localized: "Show in Strata", comment: "Preview action: reveal the chosen item in its originating Strata pane")
        case .copy: String(localized: "Copy")
        case .copyPath: String(localized: "Copy Path")
        }
    }
}

/// A menu keeps the item it was built for. A replacement root, selection or on-disk item refuses that old command.
@MainActor final class PreviewCommandTarget {
    let generation: Int
    let root: FileEntry
    let item: PreviewItem?
    let entry: FileEntry?
    private weak var owner: PreviewSession?
    private let chosen: ChosenFile?
    private let rootIdentity: FileIdentity?

    init?(session: PreviewSession) {
        guard !session.isClosed, let root = session.root else { return nil }
        generation = session.generation
        owner = session
        self.root = root
        item = session.selected
        entry = item?.entry ?? (item == nil ? root : nil)
        chosen = entry.flatMap { try? ChosenFile($0.url) }
        rootIdentity = session.rootIdentity
    }

    func isActive(in session: PreviewSession) -> Bool {
        owner === session && !session.isClosed && session.generation == generation
            && session.selected === item && session.root?.url == root.url
    }

    func matches(_ session: PreviewSession) -> Bool {
        guard isActive(in: session), let rootIdentity, FileIdentity.read(root.url.path) == rootIdentity else { return false }
        guard let entry else { return true }
        if entry.url.path == "/" { return true }
        return (try? chosen?.withParent { _, _, _ in true }) == true
    }

    func permits(_ action: PreviewAction, copies: CopyProviders) -> Bool {
        switch action {
        case .copyPath: return path(copies: copies) != nil
        case .showInStrata: return entry != nil
        case .copy: return entry.map { !copies.contains($0.url) } ?? false
        case .open: return entry.map { !copies.isPlaceholder($0.url) } ?? false
        }
    }

    func path(copies: CopyProviders) -> String? {
        if let entry { return copies.clipboardPath(entry.url) }
        guard case .member(_, let path) = item?.source, let base = copies.clipboardPath(root.url) else { return nil }
        return base + "!/" + path.joined(separator: "/")
    }
}
