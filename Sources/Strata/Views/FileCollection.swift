import AppKit
import UniformTypeIdentifiers

// Shared contract for the browser's alternative presentations (icons, columns, disk usage). The browser stays the
// owner of loading, sorting, filtering, file operations and Quick Look; a view only shows what it is given and
// reports what the user asked for.

/// Keys every view hands back to the browser instead of handling itself, mirroring `FileOutlineView`.
enum FileViewKey: Equatable {
    /// Printable characters typed with no ⌘/⌃ (the browser turns them into the filter).
    case type(String)
    case backspace
    case escape
    case returnKey
    case space
    /// Plain Tab: switches panes in dual-pane mode; otherwise the usual move to the next control.
    case tab
}

protocol FileCollectionViewDelegate: AnyObject {
    /// Double-click or ⌘↓ / Return-to-open on items (files to open, folders to navigate into).
    func fileView(_ view: NSViewController, open entries: [FileEntry])
    func fileView(_ view: NSViewController, selectionDidChange urls: [URL])
    func fileView(_ view: NSViewController, menuFor entries: [FileEntry]) -> NSMenu?
    /// `folder` is nil for a drop on the background of the browser's current folder.
    func fileView(_ view: NSViewController, drop urls: [URL], onto folder: URL?, copy: Bool) -> Bool
    /// Return true when handled; unhandled keys fall through to the view's default behaviour.
    func fileView(_ view: NSViewController, handle key: FileViewKey) -> Bool
    /// Inline rename finished with a new, non-empty name that differs from the old one.
    func fileView(_ view: NSViewController, rename entry: FileEntry, to name: String)
    /// A drag rested on `folder` long enough to spring it open; `drag` is the drag's sequence number.
    func fileView(_ view: NSViewController, springLoad folder: URL, drag: Int)
    /// Whether `folder` may spring open (readable, no privacy prompt).
    func fileView(_ view: NSViewController, canSpringLoad folder: URL) -> Bool
}

extension FileCollectionViewDelegate {
    func fileView(_ view: NSViewController, handle key: FileViewKey) -> Bool { false }
    func fileView(_ view: NSViewController, rename entry: FileEntry, to name: String) {}
    func fileView(_ view: NSViewController, springLoad folder: URL, drag: Int) {}
    func fileView(_ view: NSViewController, canSpringLoad folder: URL) -> Bool { false }
}

/// What the browser needs from whichever presentation is active.
protocol FileCollectionController: NSViewController {
    var fileDelegate: FileCollectionViewDelegate? { get set }
    var selectedEntries: [FileEntry] { get }
    func select(_ urls: [URL], scroll: Bool)
    /// The view to make first responder when the browser takes focus.
    var focusView: NSView { get }
    /// Where `url` is drawn, in screen coordinates (Quick Look zooms from it). Nil when not visible.
    func screenRect(for url: URL) -> NSRect?
    /// Starts inline rename of `url`; false when the item isn't shown or the view can't rename.
    @discardableResult func beginRename(_ url: URL) -> Bool
}

extension FileCollectionController {
    var selectedURLs: [URL] { selectedEntries.map(\.url) }
}

extension URL {
    /// Identity for lookups: folder URLs from directory listings end in "/", ones built from paths don't.
    nonisolated var fileViewKey: String {
        var path = path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// The browser's presentations. Raw values are what Prefs stores (new ones go at the end); `ordered` is the toolbar and
/// ⌘1–⌘5 order, which matches Finder (⌘1 Icons, ⌘2 List, ⌘3 Columns, ⌘4 Gallery), then Disk Usage.
enum BrowserViewMode: Int, CaseIterable {
    case list, grid, columns, treemap, gallery

    static let ordered: [BrowserViewMode] = [.grid, .list, .columns, .gallery, .treemap]
    /// Index in `ordered` (toolbar segment, and ⌘ number minus one).
    var position: Int { Self.ordered.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .list: String(localized: "List", comment: "View mode: items in a list")
        case .grid: String(localized: "Icons", comment: "View mode: items as icons")
        case .columns: String(localized: "Columns", comment: "View mode: items in columns")
        case .gallery: String(localized: "Gallery", comment: "View mode: items in a gallery")
        case .treemap: String(localized: "Disk Usage", comment: "View mode: items as a map of how much space they take")
        }
    }

    /// The View menu's item: "as Icons" … "as Disk Usage".
    var menuTitle: String {
        switch self {
        case .list: String(localized: "as List", comment: "View menu command: show items in a list")
        case .grid: String(localized: "as Icons", comment: "View menu command: show items as icons")
        case .columns: String(localized: "as Columns", comment: "View menu command: show items in columns")
        case .gallery: String(localized: "as Gallery", comment: "View menu command: show items in a gallery")
        case .treemap: String(localized: "as Disk Usage", comment: "View menu command: show items as a map of how much space they take")
        }
    }

    var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        case .gallery: "squares.below.rectangle"
        case .treemap: "square.split.bottomrightquarter"
        }
    }

    var keyEquivalent: String { String(position + 1) }

    var image: NSImage {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: title) ?? NSImage()
    }

    /// A Finder-style segmented toolbar item; `action` receives the group, read `selectedIndex`.
    static func makeToolbarItem(_ identifier: NSToolbarItem.Identifier, target: AnyObject, action: Selector) -> NSToolbarItemGroup {
        let modes = ordered
        let group = NSToolbarItemGroup(itemIdentifier: identifier, images: modes.map(\.image), selectionMode: .selectOne,
                                       labels: modes.map(\.title), target: target, action: action)
        group.label = String(localized: "View", comment: "Toolbar item label: the view mode control")
        group.paletteLabel = String(localized: "View Mode", comment: "Toolbar customization palette label")
        group.toolTip = String(localized: "Change how items are shown (⌘1–⌘5)")
        group.controlRepresentation = .expanded
        for (item, mode) in zip(group.subitems, modes) { item.toolTip = "\(mode.menuTitle) (⌘\(mode.keyEquivalent))" }
        group.selectedIndex = 0
        return group
    }

    /// View menu items "as Icons" … "as Disk Usage" with ⌘1–⌘5; each item's tag is the mode's raw value.
    static func menuItems(action: Selector) -> [NSMenuItem] {
        ordered.map { mode in
            let item = NSMenuItem(title: mode.menuTitle, action: action, keyEquivalent: mode.keyEquivalent)
            item.keyEquivalentModifierMask = .command
            item.tag = mode.rawValue
            item.image = mode.image
            return item
        }
    }
}

// MARK: - Drag and drop rules

/// Finder drop semantics shared by every presentation: move within a volume, copy across volumes, Option forces a
/// copy; never into itself or a descendant, and moving into the folder an item already lives in is a no-op.
enum FileDrop {
    /// Out of an archive opened as a folder, things are only copied: no move, no alias to a temporary copy, and no
    /// dropping on the Dock's Trash.
    static func sourceMask(_ mask: NSDragOperation, _ session: NSDraggingSession) -> NSDragOperation {
        let urls = urls(session.draggingPasteboard)
        return urls.contains(where: ReadOnlyCopies.contains) ? mask.intersection(.copy) : mask
    }

    static func urls(_ info: NSDraggingInfo) -> [URL] {
        urls(info.draggingPasteboard)
    }

    /// Dragged files, and items of containers' files dragged within Strata.
    static func urls(_ pasteboard: NSPasteboard) -> [URL] {
        ((pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
            + containerItems(pasteboard)
    }

    /// What file views accept dropped on them.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .strataContainerItem]

    /// Whether `target` is one of `urls` or inside one of them, however either is spelled (`/tmp` is `/private/tmp`).
    static func isInside(_ urls: [URL], _ target: URL) -> Bool {
        // Resolved once per drag update; items usually share a parent, so theirs are cached too.
        let resolvedTarget = TransferJob.realPath(target.standardizedFileURL.path)
        var parents: [String: String] = [:]
        return urls.contains { url in
            let parent = url.deletingLastPathComponent().path
            let real = parents[parent] ?? TransferJob.realPath(parent)
            parents[parent] = real
            let item = (real as NSString).appendingPathComponent(url.lastPathComponent)
            return resolvedTarget == item || resolvedTarget.hasPrefix(item == "/" ? "/" : item + "/")
        }
    }

    static func operation(_ urls: [URL], into target: URL, info: NSDraggingInfo) -> NSDragOperation {
        guard let first = urls.first else { return [] }
        let targetPath = target.standardizedFileURL.path
        if isInside(urls, target) { return [] }
        // An archive opened as a folder isn't changed; what's dragged out of one is copied.
        if ReadOnlyCopies.contains(target) { return [] }
        let mask = info.draggingSourceOperationMask
        let wantsCopy = NSEvent.modifierFlags.contains(.option) || !sameVolume(first, target) || urls.contains(where: ReadOnlyCopies.contains)
        let operation: NSDragOperation
        if wantsCopy || !mask.contains(.move) {
            operation = mask.contains(.copy) || mask.contains(.generic) ? .copy : []
        } else {
            operation = .move
        }
        if operation == .move, urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == targetPath }) {
            return []
        }
        return operation
    }

    private static var volumeCache: (a: URL, b: URL, same: Bool)?

    /// Called on every drag update, so the last answer is remembered.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        if let cached = volumeCache, cached.a == a, cached.b == b { return cached.same }
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let same = va != nil && vb != nil && va!.isEqual(vb!)
        volumeCache = (a, b, same)
        return same
    }
}

// MARK: - Kind groups

/// Coarse file categories for color coding (treemap tiles and legend).
enum FileKindGroup: Int, CaseIterable, Sendable {
    case folders, images, video, audio, code, archives, documents, apps, other

    nonisolated static func of(isFolder: Bool, type: UTType?) -> FileKindGroup {
        if isFolder { return .folders }
        guard let type else { return .other }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .apps }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) || type.conforms(to: .zip) { return .archives }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .yaml) || type.conforms(to: .html)
            || type.conforms(to: .propertyList) || type.conforms(to: .unixExecutable) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) || type.conforms(to: .epub) {
            return .documents
        }
        if type.conforms(to: .audiovisualContent) { return .video }
        return .other
    }

    var title: String {
        switch self {
        case .folders: String(localized: "Folders", comment: "Kind of file, in the disk usage legend")
        case .images: String(localized: "Images", comment: "Kind of file, in the disk usage legend")
        case .video: String(localized: "Video", comment: "Kind of file, in the disk usage legend")
        case .audio: String(localized: "Audio", comment: "Kind of file, in the disk usage legend")
        case .code: String(localized: "Code", comment: "Kind of file, in the disk usage legend")
        case .archives: String(localized: "Archives", comment: "Kind of file, in the disk usage legend")
        case .documents: String(localized: "Documents", comment: "Kind of file, in the disk usage legend")
        case .apps: String(localized: "Apps", comment: "Kind of file, in the disk usage legend")
        case .other: String(localized: "Other", comment: "Kind of file, in the disk usage legend")
        }
    }

    /// System hues, so they track the appearance and accessibility contrast settings.
    var color: NSColor {
        switch self {
        case .folders: .systemBlue
        case .images: .systemPurple
        case .video: .systemOrange
        case .audio: .systemPink
        case .code: .systemGreen
        case .archives: .systemBrown
        case .documents: .systemTeal
        case .apps: .systemIndigo
        case .other: .systemGray
        }
    }
}

// MARK: - Shared drawing helpers

enum FileViewStyle {
    /// File names, at the size chosen in Settings ▸ Appearance.
    static var nameFont: NSFont { fonts.regular }
    static var nameBoldFont: NSFont { fonts.bold }
    static let detailFont = NSFont.systemFont(ofSize: 11)

    private static var cachedFonts: (size: Double, regular: NSFont, bold: NSFont)?
    private static var fonts: (regular: NSFont, bold: NSFont) {
        let size = Prefs.nameTextSize
        if let cached = cachedFonts, cached.size == size { return (cached.regular, cached.bold) }
        let made = (NSFont.systemFont(ofSize: size), NSFont.systemFont(ofSize: size, weight: .bold))
        cachedFonts = (size, made.0, made.1)
        return made
    }

    /// List rows: compact, regular or spacious, and taller for bigger names.
    static var listRowHeight: CGFloat {
        [22, 26, 32][min(max(Prefs.density, 0), 2)] + CGFloat(Prefs.nameTextSize - 13).rounded(.up)
    }

    /// Column rows, a little tighter than the list's.
    static var columnRowHeight: CGFloat {
        [20, 24, 30][min(max(Prefs.density, 0), 2)] + CGFloat(Prefs.nameTextSize - 13).rounded(.up)
    }

    /// Light, dark, or the system's (Settings ▸ Appearance).
    static func applyTheme() {
        switch Prefs.theme {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// `name` with the fuzzy-match characters at `matches` (Character offsets) bold and accent-colored, like the list.
    static func highlightedName(_ name: String, matches: [Int], font: NSFont = nameFont, boldFont: NSFont = nameBoldFont,
                                color: NSColor, highlight: NSColor, paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let paragraph { attributes[.paragraphStyle] = paragraph }
        let text = NSMutableAttributedString(string: name, attributes: attributes)
        guard !matches.isEmpty else { return text }
        var offsets: [Int] = []
        var utf16 = 0
        let characters = Array(name)
        for c in characters {
            offsets.append(utf16)
            utf16 += c.utf16.count
        }
        for i in matches where i >= 0 && i < characters.count {
            text.addAttributes([.font: boldFont, .foregroundColor: highlight],
                               range: NSRange(location: offsets[i], length: characters[i].utf16.count))
        }
        return text
    }

    /// Resolves a dynamic color for layer use in `appearance`.
    static func cgColor(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var result = color.cgColor
        appearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua,
                                    .accessibilityHighContrastAqua]).map { $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}

/// Lays out a rename field over a name, Finder-style; commits on Return or focus loss, Escape cancels.
final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onEnd: (() -> Void)?
    private var cancelled = false
    private var finished = false

    init(name: String, isFolder: Bool, centered: Bool) {
        super.init(frame: .zero)
        stringValue = name
        font = FileViewStyle.nameFont
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        focusRingType = .exterior
        alignment = centered ? .center : .natural
        usesSingleLineMode = !centered
        cell?.wraps = centered
        cell?.isScrollable = !centered
        lineBreakMode = centered ? .byCharWrapping : .byClipping
        maximumNumberOfLines = centered ? 0 : 1
        delegate = self
        let base = isFolder ? name as NSString : (name as NSString).deletingPathExtension as NSString
        baseLength = base.length
    }

    private var baseLength = 0

    required init?(coder: NSCoder) { fatalError() }

    func begin(in window: NSWindow?) {
        window?.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: 0, length: baseLength)
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            finish()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finish()
            return true
        }
        return false
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let name = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = onCommit
        let end = onEnd
        removeFromSuperview()
        end?()
        if !cancelled, !name.isEmpty, !name.contains("/") { commit?(name) }
    }
}
