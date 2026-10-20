import AppKit

/// Borderless toolbar symbols otherwise use AppKit's adaptive glass ink, which can turn white on a pale canvas.
/// A public symbol palette supplies semantic label ink; AppKit still draws and disables the actual toolbar button.
final class NavigationItemTheme {
    private let original: NSImage?
    private let colored: NSImage?

    init(_ item: NSToolbarItem) {
        original = item.image
        colored = original?.withSymbolConfiguration(.init(paletteColors: [.labelColor]))
    }

    func apply(to item: NSToolbarItem) {
        let tinted = ThemeStyle.colorsSurfaces
        item.isBordered = !tinted
        let image = tinted ? colored ?? original : original
        if item.image !== image { item.image = image }
    }
}
