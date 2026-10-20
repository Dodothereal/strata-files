import AppKit
import Synchronization

/// Attributed Git counts and script labels retain these colors, so recoloring never rebuilds their cards.
nonisolated enum InspectorColors {
    private static let state = Mutex((options: ColorThemeOptions(), tinted: false))
    static let primary = color(native: .labelColor, light: 0.92, dark: 1)
    static let secondary = color(native: .secondaryLabelColor, light: 0.75, dark: 0.98)
    static let tertiary = color(native: .tertiaryLabelColor, light: 0.68, dark: 0.95)
    static let error = semantic(.systemRed)
    static let warning = semantic(.systemOrange)
    static let success = semantic(.systemGreen)
    static let link = semantic(.linkColor)
    static let accent = semantic(.controlAccentColor)
    @MainActor static let conflict = semantic(GitColors.conflicted)

    static func update(options: ColorThemeOptions, tinted: Bool) {
        state.withLock { $0 = (options, tinted) }
    }

    private static func color(native: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            guard state.withLock({ $0.tinted }), !appearance.isHighContrast else { return native }
            return NSColor(white: appearance.isDark ? 1 : 0, alpha: appearance.isDark ? dark : light)
        }
    }

    /// Keep semantic hues, moving toward readable ink only as far as the panel's contrast requires.
    private static func semantic(_ native: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let state = state.withLock { $0 }
            guard state.tinted, !appearance.isHighContrast else { return native }
            var foreground: NSColor?
            appearance.performAsCurrentDrawingAppearance { foreground = native.usingColorSpace(.sRGB) }
            guard let foreground,
                  let background = state.options.seed.surface(.inspector, dark: appearance.isDark).usingColorSpace(.sRGB) else { return native }
            let base = luminance(background.redComponent, background.greenComponent, background.blueComponent)
            let target: CGFloat = appearance.isDark ? 1 : 0
            for step in 0...20 {
                let amount = CGFloat(step) / 20
                let red = foreground.redComponent * (1 - amount) + target * amount
                let green = foreground.greenComponent * (1 - amount) + target * amount
                let blue = foreground.blueComponent * (1 - amount) + target * amount
                let value = luminance(red, green, blue)
                // Leave contrast headroom for AppKit's color-space conversion when drawing dynamic colors.
                if (max(base, value) + 0.05) / (min(base, value) + 0.05) >= 6 {
                    return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
                }
            }
            return NSColor(white: target, alpha: 1)
        }
    }

    private static func luminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Double {
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
