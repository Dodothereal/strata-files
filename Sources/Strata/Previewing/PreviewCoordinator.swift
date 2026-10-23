import AppKit
import Quartz

/// One preview per service environment, with a weak originating pane. Selection changes explicitly replace its root.
@MainActor final class PreviewCoordinator: NSObject, NSWindowDelegate {
    private let preferences: Prefs
    private let directories: DirectoryReader
    private let copies: CopyProviders
    private let thumbnails: FileThumbnails
    private let presentPanel: (NSPanel, NSView) -> Bool
    private weak var owner: BrowserViewController?
    private var ownerID: ObjectIdentifier?
    private var ownerRevision = 0
    private var rootKey: String?
    private(set) var panel: NSPanel?
    private(set) var content: PreviewBrowserController?

    var isOpen: Bool { content != nil }

    init(preferences: Prefs, directories: DirectoryReader, copies: CopyProviders, thumbnails: FileThumbnails,
         presentPanel: @escaping (NSPanel, NSView) -> Bool) {
        self.preferences = preferences
        self.directories = directories
        self.copies = copies
        self.thumbnails = thumbnails
        self.presentPanel = presentPanel
        super.init()
    }

    isolated deinit { close() }

    func show(_ entry: FileEntry, from browser: BrowserViewController, present: Bool = true) {
        let created = content == nil
        if content == nil {
            let session = PreviewSession(reader: directories)
            let content = PreviewBrowserController(session: session, preferences: preferences, thumbnails: thumbnails, copies: copies)
            let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.minSize = NSSize(width: 600, height: 360)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.contentViewController = content
            panel.delegate = self
            panel.onClose = { [weak self] in self?.close() }
            content.outline.onClose = { [weak self] in self?.close() }
            ThemeStyle.bind(panel)
            self.content = content
            self.panel = panel
        }
        owner = browser
        ownerID = ObjectIdentifier(browser)
        ownerRevision = browser.navigationRevision
        rootKey = BrowserListing.key(entry.url)
        content?.session.show(entry, showHidden: preferences.showHidden, applications: browser.applicationFolders)
        if present {
            if let panel {
                if created { panel.center() }
                guard presentPanel(panel, browser.focusView) else { return close() }
            }
            if panel?.isVisible == true, content?.session.isContainer == true { panel?.makeFirstResponder(content?.outline) }
        }
    }

    func selectionChanged(in browser: BrowserViewController) {
        guard isOpen, owner === browser else { return }
        let selected = browser.selectedEntries
        guard ownerRevision == browser.navigationRevision, selected.count == 1, let entry = selected.first else { return close() }
        guard BrowserListing.key(entry.url) != rootKey else { return }
        show(entry, from: browser, present: false)
    }

    func invalidate(owner browser: BrowserViewController) {
        guard ownerID == ObjectIdentifier(browser) else { return }
        close()
    }

    func close() {
        let browser = owner
        owner = nil
        ownerID = nil
        rootKey = nil
        content?.close()
        content = nil
        let window = panel
        panel = nil
        window?.delegate = nil
        window?.close()
        if browser?.viewIfLoaded?.window?.isKeyWindow == true { browser?.view.window?.makeFirstResponder(browser?.focusView) }
    }

    func windowWillClose(_ notification: Notification) { close() }
}

@MainActor private final class PreviewPanel: NSPanel {
    var onClose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }
}
