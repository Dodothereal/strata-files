import AppKit

/// Restore AppKit’s original named color and material settings, not a custom color resolving to the same RGB values.
package final class ThemeWindowBinding: NSObject {
    private let background: NSColor
    private let transparent: Bool
    private let adjustsSafeArea: Bool?
    private var toolbarDetached = false

    package init(_ window: NSWindow) {
        background = window.backgroundColor
        transparent = window.titlebarAppearsTransparent
        let items = (window.contentViewController as? any ThemeSplitWindowContent)?.splitViewItems
        adjustsSafeArea = items.flatMap { $0.indices.contains(1) ? $0[1].automaticallyAdjustsSafeAreaInsets : nil }
        super.init()
    }

    package func apply(to window: NSWindow) {
        window.backgroundColor = ThemeStyle.colorsSurfaces ? ThemeStyle.surface(.content) : background
        updateTitlebar(in: window, detached: toolbarDetached)
        if let split = window.contentViewController as? any ThemeSplitWindowContent,
           split.splitViewItems.indices.contains(1), let adjustsSafeArea {
            let item = split.splitViewItems[1]
            let extend = ThemeStyle.colorsSurfaces || adjustsSafeArea
            if item.automaticallyAdjustsSafeAreaInsets != extend {
                // One canvas beneath the floating panels avoids a second, focus-dependent backdrop at their edges.
                item.automaticallyAdjustsSafeAreaInsets = extend
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }

    package func updateTitlebar(in window: NSWindow, detached: Bool) {
        toolbarDetached = detached
        // In full screen AppKit supplies the sidebar's rounded header in a separate titlebar section.
        // Hiding that background leaves the square sidebar content exposed at the top.
        let windowedTint = ThemeStyle.colorsSurfaces && !detached && !window.styleMask.contains(.fullScreen)
        let desired = windowedTint || transparent
        if window.titlebarAppearsTransparent != desired { window.titlebarAppearsTransparent = desired }
    }
}

/// Remembers each owned surface’s native drawing so System restores it exactly.
/// The map holds views weakly; an appearance change never retains a closed window or a discarded column.
package final class ThemeSurfaceBinding: NSObject {
    package let role: ThemeSurfaceRole
    private let background: NSColor?
    private let border: NSColor?
    private let drawsBackground: Bool?
    private let collectionBackgrounds: [NSColor]?
    private let backdrop: ThemeSurfaceView?
    private let fieldBezel: NSTextField.BezelStyle?
    private let fieldBezeled: Bool?
    private let fieldBordered: Bool?

    package init(view: NSView, role: ThemeSurfaceRole) {
        self.role = role
        fieldBezel = (view as? NSTextField)?.bezelStyle
        fieldBezeled = (view as? NSTextField)?.isBezeled
        fieldBordered = (view as? NSTextField)?.isBordered
        if let field = view as? NSTextField {
            background = field.backgroundColor
            drawsBackground = field.drawsBackground
        } else if let text = view as? NSTextView {
            background = text.backgroundColor
            drawsBackground = text.drawsBackground
        } else if let scroll = view as? NSScrollView {
            background = scroll.backgroundColor
            drawsBackground = scroll.drawsBackground
        } else if let table = view as? NSTableView {
            background = table.backgroundColor
            drawsBackground = nil
        } else if let box = view as? NSBox {
            background = box.fillColor
            drawsBackground = nil
        } else {
            background = nil
            drawsBackground = nil
        }
        collectionBackgrounds = (view as? NSCollectionView)?.backgroundColors
        border = (view as? NSBox)?.borderColor
        if view is NSScrollView || view is NSTableView || view is NSCollectionView || view is NSBox
            || view is NSTextField || view is NSTextView {
            backdrop = nil
        } else {
            let fill = ThemeSurfaceView(frame: view.bounds)
            fill.role = role
            fill.ignoresMouse = true
            fill.autoresizingMask = [.width, .height]
            view.addSubview(fill, positioned: .below, relativeTo: nil)
            backdrop = fill
        }
        super.init()
    }

    package func apply(to view: NSView) {
        let colored = ThemeStyle.colorsSurfaces
        if let field = view as? NSTextField {
            // The native bezel paints an opaque fill. AppKit's bordered style honors backgroundColor.
            // Search fields keep AppKit's rounded search bezel and built-in search/cancel buttons.
            if !(field is NSSearchField), let fieldBezel, let fieldBezeled, let fieldBordered {
                let bezel: NSTextField.BezelStyle = colored ? .squareBezel : fieldBezel
                let bezeled = !colored && fieldBezeled
                let bordered = colored ? fieldBordered || fieldBezeled : fieldBordered
                if field.bezelStyle != bezel { field.bezelStyle = bezel }
                if field.isBezeled != bezeled { field.isBezeled = bezeled }
                if field.isBordered != bordered { field.isBordered = bordered }
            }
            field.drawsBackground = colored || drawsBackground == true
            field.backgroundColor = colored ? ThemeStyle.surface(role) : background
        } else if let text = view as? NSTextView {
            text.backgroundColor = colored ? ThemeStyle.surface(role) : background ?? .textBackgroundColor
        } else if let scroll = view as? NSScrollView {
            scroll.drawsBackground = colored || drawsBackground == true
            scroll.backgroundColor = colored ? ThemeStyle.surface(role) : background ?? role.nativeColor
        } else if let table = view as? NSTableView {
            table.backgroundColor = colored ? ThemeStyle.surface(role) : background ?? role.nativeColor
        } else if let box = view as? NSBox {
            box.fillColor = colored ? ThemeStyle.surface(role) : background ?? role.nativeColor
            box.borderColor = colored ? ThemeStyle.border : border ?? .separatorColor
        } else if let collection = view as? NSCollectionView {
            collection.backgroundColors = colored ? [ThemeStyle.surface(role)] : collectionBackgrounds ?? [.clear]
        }
        backdrop?.isHidden = !colored
        backdrop?.needsDisplay = true
    }
}

/// A custom background is a surface, not vibrant foreground artwork. Keep the native header and its drawing.
package final class ThemeHeaderAppearanceBinding: NSObject {
    private let native: NSAppearance?

    package init(_ header: NSTableHeaderView) {
        native = header.appearance
        super.init()
    }

    package func apply(to header: NSTableHeaderView, in table: NSTableView) {
        let appearance = table.effectiveAppearance
        let colored = ThemeStyle.colorsSurfaces && !appearance.isHighContrast
        let chosen = colored ? NSAppearance(named: appearance.isDark ? .darkAqua : .aqua) : native
        if header.appearance !== chosen { header.appearance = chosen }
    }
}

package final class ThemeHeaderBinding: NSObject {
    private let native: NSTableHeaderCell
    private var colored: NSTableHeaderCell?

    package init(_ column: NSTableColumn) {
        native = column.headerCell
        super.init()
    }

    package func apply(to column: NSTableColumn) {
        let tint = ThemeStyle.colorsSurfaces && column.tableView?.effectiveAppearance.isHighContrast != true
        if tint && colored == nil { colored = ThemeHeaderCell.copying(native) }
        let cell = tint ? colored ?? native : native
        guard column.headerCell !== cell else { return }
        if cell.stringValue != column.title { cell.stringValue = column.title }
        column.headerCell = cell
        column.tableView?.headerView?.needsDisplay = true
    }
}

/// Tint only the background inside AppKit's complete header drawing pass, including sorting and tracking.
package final class ThemeHeaderCell: NSTableHeaderCell {
    package static func copying(_ original: NSTableHeaderCell) -> NSTableHeaderCell {
        // AppKit's factory cell carries header ink, truncation and other state that init(textCell:) doesn't.
        // These bytes come only from that cell, in memory; NSTableHeaderCell doesn't adopt NSSecureCoding.
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: false),
              let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return original }
        decoder.requiresSecureCoding = false
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(ThemeHeaderCell.self, forClassName: NSStringFromClass(Swift.type(of: original)))
        defer { decoder.finishDecoding() }
        return decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? ThemeHeaderCell ?? original
    }

    package override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if ThemeStyle.colorsSurfaces && !controlView.effectiveAppearance.isHighContrast {
            ThemeStyle.surface(.content).setFill()
            cellFrame.fill()
        }
        super.draw(withFrame: cellFrame, in: controlView)
    }
}
