import AppKit
import SwiftUI

/// A native editable field whose bezel, focus ring and editor stay AppKit's while its fill follows the palette.
struct ThemeTextField: NSViewRepresentable {
    let title: String
    let search: Bool
    @Binding var text: String
    @ObservedObject private var theme = ThemeAppearance.shared

    init(_ title: String, text: Binding<String>, search: Bool = false) {
        self.title = title
        _text = text
        self.search = search
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = Self.makeField(search: search)
        field.delegate = context.coordinator
        ThemeStyle.bind(field, to: .preview)
        return field
    }

    static func makeField(search: Bool) -> NSTextField {
        let field: NSTextField = search ? NSSearchField() : NSTextField()
        if let search = field as? NSSearchField {
            search.sendsSearchStringImmediately = true
            search.sendsWholeSearchString = false
        } else {
            field.bezelStyle = .roundedBezel
        }
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        Self.updateValue(text, in: field)
        // Reading the observed state also refreshes cached Settings panes when the palette changes.
        let _ = theme.options
        let _ = theme.highContrast
        ThemeStyle.bind(field, to: .preview)
    }

    static func updateValue(_ value: String, in field: NSTextField) {
        // A palette update must not commit or replace text being composed with an input method.
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != value { field.stringValue = value }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
