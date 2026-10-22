import AppKit

nonisolated package extension NSAppearance {
    /// Increase Contrast is on (System Settings ▸ Accessibility ▸ Display).
    var isHighContrast: Bool {
        let match = bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }

    var isDark: Bool {
        let match = bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }
}

nonisolated package extension NSColor {
    /// White in Dark Mode, black in Light Mode, at `alpha`, and fully opaque with Increase Contrast.
    static func ink(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let alpha = appearance.isHighContrast ? 1 : appearance.isDark ? dark : light
            return NSColor(white: appearance.isDark ? 1 : 0, alpha: alpha)
        }
    }
}
