import AppKit

/// What a pane shows. Searches and Recents are places in the history like folders.
enum Destination: Equatable {
    case folder(URL)
    case search(String, scope: URL?)
    case recents
    case duplicates
}

/// One side of a window: a browser with its own place and back/forward history.
final class Pane {
    let browser = BrowserViewController()
    var destination: Destination
    /// The current folder, or the last one shown before a search or Recents.
    var location: URL
    var backStack: [Destination] = []
    /// The drag whose spring-loading last moved this pane: the rest of that dive adds no Back steps.
    var springDrag: Int?
    var forwardStack: [Destination] = []
    var folderEntry: FileEntry?
    /// In column view, the folder of the focused column (deeper than `location`).
    var columnLocation: URL?
    var searchGeneration = 0
    /// The search running in this pane, stopped when another starts or the pane goes elsewhere.
    var searchTask: Task<Void, Never>?
    var duplicateSearch: CancelFlag?
    /// The scan behind a search in a folder the index doesn't cover, kept while you keep searching that folder.
    var folderSearch: FolderSearch?
    /// The scope bar's line for this pane's search, kept so switching panes shows the right one.
    var searchSummary = ""
    let host: PaneHostViewController

    init(location: URL) {
        self.location = location.standardizedFileURL
        destination = .folder(self.location)
        host = PaneHostViewController(browser: browser)
    }

    /// Stops what the pane is doing in the background (duplicate hashing, a folder scan): its window or the pane is
    /// closing.
    func stopBackgroundWork() {
        duplicateSearch?.set()
        duplicateSearch = nil
        folderSearch?.cancel()
        folderSearch = nil
    }

    /// Short description for the pane header.
    var title: (text: String, symbol: String) {
        switch destination {
        case .folder(let url): (Places.displayName(url), Trash.isTrash(url) ? "trash" : "folder")
        case .search(let text, _): (BrowserWindowController.searchTitle(text), "magnifyingglass")
        case .recents: ("Recents", "clock")
        case .duplicates: ("Duplicates", "square.on.square")
        }
    }
}

/// A pane's browser plus, in dual-pane mode, a slim header that shows where it is and whether it has focus.
final class PaneHostViewController: NSViewController {
    let browser: BrowserViewController
    var onActivate: (() -> Void)?
    private let header = PaneHeaderView()
    private let status = NSTextField(labelWithString: "")
    private let statusBar = NSView()
    private var underRoot: NSLayoutConstraint?
    private var underHeader: NSLayoutConstraint?
    private var aboveBottom: NSLayoutConstraint?
    private var aboveStatus: NSLayoutConstraint?

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(browser)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isHidden = true
        header.onClick = { [weak self] in self?.onActivate?() }
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.isHidden = true
        statusBar.addSubview(hairline)
        statusBar.addSubview(status)
        root.addSubview(browser.view)
        root.addSubview(header)
        root.addSubview(statusBar)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            browser.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            hairline.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: statusBar.topAnchor),
            status.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
        ])
        aboveBottom = browser.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        aboveStatus = browser.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        aboveBottom?.isActive = true
        // Single pane: the list scrolls under the toolbar. Dual: it starts below the pane's header.
        underRoot = browser.view.topAnchor.constraint(equalTo: root.topAnchor)
        underHeader = browser.view.topAnchor.constraint(equalTo: header.bottomAnchor)
        underRoot?.isActive = true
        view = root
    }

    /// A per-pane status line (dual-pane mode), or nil to hide it.
    func setStatus(_ text: String?) {
        loadViewIfNeeded()
        status.stringValue = text ?? ""
        statusBar.isHidden = text == nil
        aboveBottom?.isActive = text == nil
        aboveStatus?.isActive = text != nil
    }

    func setHeader(visible: Bool, title: String, symbol: String, active: Bool) {
        loadViewIfNeeded()
        header.isHidden = !visible
        header.configure(title: title, symbol: symbol, active: active)
        underRoot?.isActive = !visible
        underHeader?.isActive = visible
    }
}

private final class PaneHeaderView: NSVisualEffectView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let underline = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .headerView
        blendingMode = .withinWindow
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        underline.wantsLayer = true
        for view in [icon, label, underline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, symbol: String, active: Bool) {
        label.stringValue = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(active ? "\(title), focused pane" : "\(title), pane")
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.textColor = active ? .labelColor : .secondaryLabelColor
        icon.contentTintColor = active ? .controlAccentColor : .tertiaryLabelColor
        isActive = active
        updateUnderline()
    }

    private var isActive = false

    private func updateUnderline() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            underline.layer?.backgroundColor = isActive ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        }
    }

    /// Light or dark changed: the line's color is worked out again (a layer keeps the old one).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateUnderline()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Holds one or two panes side by side.
final class PaneContainerViewController: NSSplitViewController {
    init(first: PaneHostViewController) {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        add(first)
    }

    required init?(coder: NSCoder) { fatalError() }

    func add(_ host: PaneHostViewController) {
        let item = NSSplitViewItem(viewController: host)
        item.minimumThickness = 300
        addSplitViewItem(item)
        // A new second pane starts as an even split, not squeezed to its minimum width.
        guard splitViewItems.count == 2 else { return }
        DispatchQueue.main.async { [weak self] in
            // The pane may have been closed again before this runs.
            guard let self, splitViewItems.count == 2 else { return }
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
        }
    }

    func remove(_ host: PaneHostViewController) {
        guard let item = splitViewItems.first(where: { $0.viewController === host }) else { return }
        removeSplitViewItem(item)
    }
}
