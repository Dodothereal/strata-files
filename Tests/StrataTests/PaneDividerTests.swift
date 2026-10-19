import AppKit
import Testing
@testable import Strata

struct PaneDividerTests {
    @Test func dividerStaysBetweenTheToolbarAndSharedFooter() throws {
        let panes = PaneContainerViewController(first: PaneHostViewController(browser: BrowserViewController()))
        let split = panes.splitView
        split.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        // The toolbar, search bar and footer change these insets. Render the actual divider without an opaque
        // browser covering it, as Columns and Disk Usage leave the shared footer exposed.
        for (top, bottom) in [(66.0, 46.0), (96.0, 72.0), (0.0, 28.0), (0.0, 0.0)] {
            split.additionalSafeAreaInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            split.layoutSubtreeIfNeeded()
            let image = NSImage(size: split.bounds.size)
            image.lockFocusFlipped(true)
            NSColor.magenta.setFill()
            split.bounds.fill()
            split.drawDivider(in: NSRect(x: 300, y: 0, width: 1, height: 400))
            image.unlockFocus()
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let scale = CGFloat(bitmap.pixelsWide) / split.bounds.width
            func isBackground(at y: CGFloat) throws -> Bool {
                let color = try #require(bitmap.colorAt(x: Int(300.5 * scale), y: Int(y * scale))?
                    .usingColorSpace(.deviceRGB))
                let background = try #require(bitmap.colorAt(x: Int(298 * scale), y: Int(y * scale))?
                    .usingColorSpace(.deviceRGB))
                return abs(color.redComponent - background.redComponent) < 0.001
                    && abs(color.greenComponent - background.greenComponent) < 0.001
                    && abs(color.blueComponent - background.blueComponent) < 0.001
            }

            #expect(try !isBackground(at: split.safeAreaRect.midY))
            if top > 0 { #expect(try isBackground(at: top / 2)) }
            if bottom > 0 { #expect(try isBackground(at: split.bounds.height - bottom / 2)) }
        }
    }
}
