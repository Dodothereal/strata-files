import AppKit
import UniformTypeIdentifiers

/// Finder icons, cached per file type for documents and per path for folders and packages (which can have their own).
package final class IconCache {
    package static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()

    private init() {
        byPath.countLimit = 4000
    }

    package func icon(forType type: UTType) -> NSImage {
        if let cached = byType[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        byType[type.identifier] = image
        return image
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
    package func markedIcon(_ symbol: String, _ mark: ContainerIconMark) -> NSImage {
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

    package func icon(forPath path: String) -> NSImage {
        if let cached = byPath.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        byPath.setObject(image, forKey: path as NSString)
        return image
    }
}

/// Whether a container or a Compose stack is drawn as running, in between, or stopped.
package enum ContainerIconMark: Equatable {
    case running, changing, stopped

    /// A filled box while it runs or is changing; an outline box while it's stopped.
    package var containerSymbol: String { self == .stopped ? "shippingbox" : "shippingbox.fill" }
    /// A filled stack while any of it runs or is changing; an outline stack while all of it is stopped.
    package var stackSymbol: String { self == .stopped ? "square.stack.3d.up" : "square.stack.3d.up.fill" }
}
