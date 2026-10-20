import AppKit

/// Full-screen titlebar sections have opaque backing layers above the window's canvas.
/// Color those existing backings, leaving AppKit's material masks and control layout intact.
final class ToolbarBackdropTint {
    private let bindings = NSMapTable<NSView, ToolbarBackdropBinding>.weakToStrongObjects()

    /// Prepare hidden sections before AppKit can snapshot them for the full-screen transition.
    /// Prepare only the observed macOS 26 header sections, including ones whose material isn't built yet.
    func prepare(in window: NSWindow) {
        guard ThemeStyle.colorsSurfaces, !window.effectiveAppearance.isHighContrast,
              window.styleMask.contains(.fullSizeContentView), let root = window.contentView else { return }
        let top = root.convert(root.bounds, to: nil).maxY
        let headerHeight = top - window.contentLayoutRect.maxY
        guard headerHeight > 0 else { return }
        func visit(_ view: NSView) {
            guard !(view is NSControl), !(view is NSScrollView) else { return }
            let frame = view.convert(view.bounds, to: nil)
            guard frame.maxY >= top - headerHeight else { return }
            if String(describing: type(of: view)) == "NSTitlebarBackgroundView",
               abs(frame.maxY - top) < 1, frame.height > 1, frame.height <= headerHeight + 1 {
                bind(view)
                return
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
    }

    private func bind(_ view: NSView) {
        if let binding = bindings.object(forKey: view) {
            if binding.ownsCurrentLayer { binding.apply(); return }
            binding.restore()
            bindings.removeObject(forKey: view)
        }
        guard let layer = view.layer, let color = layer.backgroundColor,
              Self.isOpaqueNeutral(color), view.bounds.height > 1 else { return }
        let binding = ToolbarBackdropBinding(view: view, layer: layer)
        bindings.setObject(binding, forKey: view)
        binding.apply()
    }

    func apply(in window: NSWindow) {
        guard ThemeStyle.colorsSurfaces, !window.effectiveAppearance.isHighContrast else {
            restore()
            return
        }
        guard let root = window.contentView else { return }
        func visit(_ view: NSView) {
            guard !(view is NSControl) else { return }
            if view is NSVisualEffectView || view is NSGlassEffectView {
                var ancestor = view.superview
                while let candidate = ancestor, candidate !== root {
                    if candidate is NSVisualEffectView || candidate is NSGlassEffectView { break }
                    if let binding = bindings.object(forKey: candidate) {
                        if binding.ownsCurrentLayer {
                            binding.apply()
                            break
                        }
                        binding.restore()
                        bindings.removeObject(forKey: candidate)
                    }
                    if let layer = candidate.layer, let color = layer.backgroundColor {
                        if Self.isOpaqueNeutral(color), candidate.bounds.height > 1 {
                            bind(candidate)
                        }
                        break
                    }
                    ancestor = candidate.superview
                }
                // A material's internal masks, luminance adjustment and glass content belong to AppKit.
                return
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
    }

    func restore() {
        for binding in bindings.objectEnumerator()?.allObjects as? [ToolbarBackdropBinding] ?? [] { binding.restore() }
        bindings.removeAllObjects()
    }

    fileprivate static func isOpaqueNeutral(_ color: CGColor) -> Bool {
        guard let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return false }
        return rgb.alphaComponent == 1 && abs(rgb.redComponent - rgb.greenComponent) < 0.001
            && abs(rgb.greenComponent - rgb.blueComponent) < 0.001
    }
}

private final class ToolbarBackdropBinding: NSObject {
    private weak var view: NSView?
    private weak var layer: CALayer?
    private var native: CGColor?
    private var observation: NSKeyValueObservation?
    private var applying = false
    var ownsCurrentLayer: Bool { layer != nil && view?.layer === layer }

    init(view: NSView, layer: CALayer) {
        self.view = view
        self.layer = layer
        native = layer.backgroundColor
        super.init()
        observation = layer.observe(\.backgroundColor) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.applying else { return }
                // AppKit resets the backing during focus, appearance and full-screen layout changes.
                self.native = self.layer?.backgroundColor
                self.apply()
            }
        }
    }

    func apply() {
        guard let view, let layer, ownsCurrentLayer, let native, ToolbarBackdropTint.isOpaqueNeutral(native),
              ThemeStyle.colorsSurfaces, !view.effectiveAppearance.isHighContrast else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            setColor(ThemeStyle.surface(.content).cgColor, on: layer)
        }
    }

    func restore() {
        observation = nil
        if let layer { setColor(native, on: layer) }
    }

    private func setColor(_ color: CGColor?, on layer: CALayer) {
        guard layer.backgroundColor != color else { return }
        applying = true
        defer { applying = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        CATransaction.commit()
    }
}
