import AppKit

/// The file list. Typing filters the folder instead of jumping to the first match; Return and Space follow Finder.
final class FileOutlineView: NSOutlineView {
    var onType: ((String) -> Void)?
    var onBackspace: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    /// Tab with no modifiers (switches panes in dual-pane mode); nil keeps the default key-view loop.
    /// Tab; return false to let it move focus to the next control as usual.
    var onTab: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.isDisjoint(with: [.command, .control])
        switch event.keyCode {
        case 36 where plain, 76 where plain: // Return, Enter
            onReturn?()
            return
        case 49 where plain: // Space
            onSpace?()
            return
        case 48 where mods.isEmpty: // Tab
            if onTab?() == true { return }
        case 53: // Escape
            if onEscape?() == true { return }
        case 51 where mods.isDisjoint(with: [.command, .control, .option]): // Delete
            if onBackspace?() == true { return }
        default:
            break
        }
        if plain, event.specialKey == nil, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            onType?(chars)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return contextMenu?()
    }
}
