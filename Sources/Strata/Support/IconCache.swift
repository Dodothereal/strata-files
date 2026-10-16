import AppKit
import UniformTypeIdentifiers

/// Finder icons, cached per file type for documents and per path for folders and packages (which can have their own).
final class IconCache {
    static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()

    private init() {
        byPath.countLimit = 4000
    }

    func icon(for entry: FileEntry) -> NSImage {
        // A container is a box, a Compose stack is a stack of boxes. Filled and green while it runs, an outline in
        // grey while it's stopped, orange while it's paused or only partly running.
        if entry.isDirectory, let (source, top) = ContainerCopies.copy(containing: entry.url),
           top.standardizedFileURL == entry.url.standardizedFileURL {
            let store = ContainerStore.shared
            let mark = ContainerIconMark.container(state: store.container(id: source.id)?.state, busy: store.busy[source.id] != nil)
            return markedIcon(mark.containerSymbol, mark)
        }
        if entry.isDirectory, ContainerCopies.isStack(entry.url) {
            let name = entry.url.lastPathComponent
            let store = ContainerStore.shared
            let members = store.containers.filter {
                $0.compose?.project.compare(name, options: [.caseInsensitive]) == .orderedSame
            }
            let mark = ContainerIconMark.stack(states: members.map(\.state), anyBusy: members.contains { store.busy[$0.id] != nil })
            return markedIcon(mark.stackSymbol, mark)
        }
        if !entry.isDirectory, !entry.isSymlink, let type = entry.contentType {
            if let cached = byType[type.identifier] { return cached }
            let image = NSWorkspace.shared.icon(for: type)
            byType[type.identifier] = image
            return image
        }
        return icon(forPath: entry.url.path)
    }

    private enum BadgeColor: Hashable {
        case green, orange, grey

        var color: NSColor {
            switch self {
            case .green: .systemGreen
            case .orange: .systemOrange
            case .grey: .systemGray
            }
        }
    }

    private var markedIcons: [String: NSImage] = [:]

    /// A box for a container, a stack of boxes for a Compose project. Filled and green while it runs, outline and grey
    /// while it's stopped, orange while it's paused or only partly running. The symbol is the whole icon: a badge on a
    /// folder shrinks to a dot at list size.
    private func markedIcon(_ symbol: String, _ mark: ContainerIconMark) -> NSImage {
        let badgeColor: BadgeColor = switch mark {
        case .running: .green
        case .changing: .orange
        case .stopped: .grey
        }
        let key = "\(symbol)|\(badgeColor)"
        if let cached = markedIcons[key] { return cached }
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 180, weight: .medium).applying(.init(paletteColors: [badgeColor.color])))
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            guard let glyph else { return false }
            let size = glyph.size
            let scale = min(rect.width / size.width, rect.height / size.height) * 0.82
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            glyph.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            return true
        }
        markedIcons[key] = image
        return image
    }

    func icon(forPath path: String) -> NSImage {
        if let cached = byPath.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        byPath.setObject(image, forKey: path as NSString)
        return image
    }
}

/// Whether a container or a Compose stack is drawn as running, in between, or stopped.
enum ContainerIconMark: Equatable {
    case running, changing, stopped

    /// A filled box while it runs or is changing; an outline box while it's stopped.
    var containerSymbol: String { self == .stopped ? "shippingbox" : "shippingbox.fill" }
    /// A filled stack while any of it runs or is changing; an outline stack while all of it is stopped.
    var stackSymbol: String { self == .stopped ? "square.stack.3d.up" : "square.stack.3d.up.fill" }

    static func container(state: ContainerInfo.State?, busy: Bool) -> ContainerIconMark {
        if busy || state == .paused || state == .restarting { return .changing }
        return state == .running ? .running : .stopped
    }

    /// Green only when every container is running and none is being changed. Grey when nothing is running.
    static func stack(states: [ContainerInfo.State], anyBusy: Bool) -> ContainerIconMark {
        let running = states.filter { $0 == .running }.count
        if running == states.count && running > 0 && !anyBusy { return .running }
        if running == 0 && !anyBusy && !states.contains(where: { $0 == .paused || $0 == .restarting }) { return .stopped }
        return .changing
    }
}
