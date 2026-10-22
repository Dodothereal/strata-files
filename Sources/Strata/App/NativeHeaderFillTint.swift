import AppKit

/// A deliberately narrow adapter for the titlebar material structure observed in macOS 26.
/// Unknown layer arrangements keep native drawing; never search arbitrary layers for a gray color.
package final class NativeHeaderFillTint {
    private weak var material: NSVisualEffectView?
    private weak var fill: CALayer?
    private var nativeColor: CGColor?
    private var observations: [NSKeyValueObservation] = []
    private var fillObservation: NSKeyValueObservation?
    private var layerObservation: NSKeyValueObservation?
    private weak var observedRoot: CALayer?
    private weak var observedContainer: CALayer?
    private var enabled = false
    private var applying = false
    private var pending = false

    package init(_ material: NSVisualEffectView) { self.material = material }

    package func apply(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { restore(); return }
        if layerObservation == nil, let material {
            layerObservation = material.observe(\.layer) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        guard enabled, !applying, let material else { return }
        let root = material.layer, container = root?.sublayers?.first
        if root !== observedRoot || container !== observedContainer {
            observations.removeAll()
            observedRoot = root
            observedContainer = container
            for layer in [root, container].compactMap({ $0 }) {
                observations.append(layer.observe(\.sublayers) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                })
            }
        }
        let candidate = Self.recognizedFill(in: material, previous: fill, originalColor: nativeColor)
        if candidate !== fill {
            restoreFill()
            if let candidate {
                fill = candidate
                nativeColor = candidate.backgroundColor
                fillObservation = candidate.observe(\.backgroundColor) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.applying else { return }
                        self.nativeColor = self.fill?.backgroundColor
                        self.refresh()
                    }
                }
            }
        }
        guard let fill else { return }
        material.effectiveAppearance.performAsCurrentDrawingAppearance {
            setColor(ThemeStyle.surface(.content).cgColor, on: fill)
        }
    }

    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pending = false
            refresh()
        }
    }

    package func restore() {
        enabled = false
        layerObservation = nil
        observations.removeAll()
        observedRoot = nil
        observedContainer = nil
        restoreFill()
    }

    private func restoreFill() {
        fillObservation = nil
        if let fill { setColor(nativeColor, on: fill) }
        fill = nil
        nativeColor = nil
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

    /// Match the whole active or inactive material signature, not an OS version. A later macOS can
    /// retain this structure; any changed structure falls back to native drawing without private calls.
    package static func recognizedFill(in material: NSVisualEffectView, previous: CALayer? = nil,
                                       originalColor: CGColor? = nil) -> CALayer? {
        guard material.material == .titlebar, material.blendingMode == .withinWindow,
              material.subviews.isEmpty, let root = material.layer, root.sublayers?.count == 1,
              let container = root.sublayers?.first, type(of: container) == CALayer.self,
              container.frame == root.bounds, container.opacity == 1, container.backgroundColor == nil,
              container.mask == nil, container.filters == nil, container.compositingFilter == nil,
              let children = container.sublayers, children.count == 2 || children.count == 3 else { return nil }
        let active = children.count == 3
        guard let adaptive = children.last else { return nil }
        let fill = children[active ? 1 : 0]
        guard type(of: fill) == CALayer.self, fill.frame == container.bounds,
              fill.opacity == (active ? 0.8 : 1), !fill.isHidden,
              fill.mask == nil, fill.contents == nil, fill.sublayers?.isEmpty != false,
              fill.filters == nil, fill.backgroundFilters == nil, fill.compositingFilter == nil,
              String(describing: type(of: adaptive)) == "CAChameleonLayer", adaptive.frame == container.bounds,
              adaptive.backgroundColor == nil, adaptive.opacity == 0.05 || (!active && adaptive.opacity == 0.1),
              let cgColor = fill === previous ? originalColor ?? fill.backgroundColor : fill.backgroundColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB),
              color.alphaComponent == 1, color.redComponent > 0,
              abs(color.redComponent - color.greenComponent) < 0.001,
              abs(color.greenComponent - color.blueComponent) < 0.001 else { return nil }
        if active {
            let blur = children[0]
            guard String(describing: type(of: blur)) == "CABackdropLayer", blur.frame == container.bounds,
                  blur.opacity == 1, blur.compositingFilter == nil,
                  blur.filters?.map({ String(describing: $0) }) == ["sdrNormalize", "gaussianBlur"] else { return nil }
        }
        return fill
    }
}
