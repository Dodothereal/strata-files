import AppKit

/// Finder's click to rename: clicking the name of the item that's already the only one selected (a second, slower
/// click, not a double click) starts renaming it once the double-click time has passed.
///
/// A view decides from `mouseDown`, before handing the click on, whether it may rename (`armed`), and calls `clicked`
/// once the click is over (lists and grids track the mouse until it's released). Another click, a key, a context menu
/// or a drag calls it off; `rename` checks that the item is still the one selected when the wait is over.
@MainActor
final class ClickToRename {
    private var timer: Timer?

    func clicked(_ event: NSEvent, armed: Bool, in view: NSView, rename: @escaping @MainActor () -> Void) {
        cancel()
        guard armed, let window = view.window else { return }
        // The pointer moved while the button was down: that was a drag.
        let now = window.mouseLocationOutsideOfEventStream
        guard hypot(now.x - event.locationInWindow.x, now.y - event.locationInWindow.y) < 4 else { return }
        let timer = Timer(timeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                rename()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// A plain click in a view that already had the focus: only such a click on a selected name renames.
    static func isPlainClickInFocus(_ event: NSEvent, on view: NSView) -> Bool {
        guard event.clickCount == 1, let window = view.window, window.isKeyWindow, window.firstResponder === view else {
            return false
        }
        return event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
    }

    /// The row whose name `event` hit in `table`'s `column`, when that row is the only one selected and the click
    /// would rename it (see `isPlainClickInFocus`); nil otherwise. The name is the cell's text field, which hugs the
    /// text, so a click beside it selects without renaming, like Finder.
    static func nameRow(in table: NSTableView, column: Int, for event: NSEvent) -> Int? {
        guard isPlainClickInFocus(event, on: table) else { return nil }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard row >= 0, table.column(at: point) == column, table.selectedRowIndexes == IndexSet(integer: row),
              let field = (table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField
        else { return nil }
        let x = field.convert(event.locationInWindow, from: nil).x
        return x >= 0 && x <= field.bounds.width ? row : nil
    }
}
