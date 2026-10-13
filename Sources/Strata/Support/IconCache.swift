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
        // A container: a folder with a box, green while it runs.
        if entry.isDirectory, let (source, top) = ContainerCopies.copy(containing: entry.url),
           top.standardizedFileURL == entry.url.standardizedFileURL {
            let store = ContainerStore.shared
            let state = store.container(id: source.id)?.state
            // Orange while it's being started, stopped… or is paused; green while it runs.
            let badge: BadgeColor = store.busy[source.id] != nil || state == .paused || state == .restarting ? .orange
                : state == .running ? .green : .grey
            return containerIcon(badge)
        }
        if !entry.isDirectory, !entry.isSymlink, let type = entry.contentType {
            if let cached = byType[type.identifier] { return cached }
            let image = NSWorkspace.shared.icon(for: type)
            byType[type.identifier] = image
            return image
        }
        return icon(forPath: entry.url.path)
    }

    private enum BadgeColor {
        case green, orange, grey

        var color: NSColor {
            switch self {
            case .green: .systemGreen
            case .orange: .systemOrange
            case .grey: .systemGray
            }
        }
    }

    private var containerIcons: [BadgeColor: NSImage] = [:]

    /// The folder icon with a badge: a box in a circle, green for a running container, orange for a paused one or one
    /// being started or stopped, grey for a stopped one.
    private func containerIcon(_ badgeColor: BadgeColor) -> NSImage {
        if let cached = containerIcons[badgeColor] { return cached }
        let folder = NSWorkspace.shared.icon(for: .folder)
        let box = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .semibold).applying(.init(paletteColors: [.white])))
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            folder.draw(in: rect)
            let badge = NSRect(x: rect.maxX - 118, y: rect.minY + 22, width: 104, height: 104)
            badgeColor.color.setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 6
            ring.stroke()
            if let box {
                let size = box.size
                let scale = min(56 / size.width, 56 / size.height)
                let drawn = NSSize(width: size.width * scale, height: size.height * scale)
                box.draw(in: NSRect(x: badge.midX - drawn.width / 2, y: badge.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            }
            return true
        }
        containerIcons[badgeColor] = image
        return image
    }

    func icon(forPath path: String) -> NSImage {
        if let cached = byPath.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        byPath.setObject(image, forKey: path as NSString)
        return image
    }
}
