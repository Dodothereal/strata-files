import SwiftUI

/// SwiftUI forms keep their state while an open Settings or View Options window changes palette.
final class ThemeAppearance: ObservableObject {
    static let shared = ThemeAppearance()
    @Published private(set) var options = ColorThemeOptions()
    @Published private(set) var highContrast = false
    var colorsSurfaces: Bool { options.palette != .system && options.tintsWindow && !highContrast }

    func update(_ options: ColorThemeOptions, highContrast: Bool) {
        if self.options != options { self.options = options }
        if self.highContrast != highContrast { self.highContrast = highContrast }
    }
}

struct ThemedFormBackground: ViewModifier {
    @ObservedObject private var theme = ThemeAppearance.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var colorsSurfaces: Bool { theme.colorsSurfaces && contrast != .increased }

    private var background: NSColor {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        return theme.options.surfaceColor(in: appearance, reduceTransparency: true,
                                          highContrast: theme.highContrast || contrast == .increased, role: .content)
    }

    private var accent: NSColor {
        theme.options.controlAccentColor(highContrast: theme.highContrast || contrast == .increased)
    }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(colorsSurfaces ? .hidden : .visible)
            .background {
                if colorsSurfaces { Color(nsColor: background) }
            }
            .tint(Color(nsColor: accent))
            .accentColor(Color(nsColor: accent))
    }
}
