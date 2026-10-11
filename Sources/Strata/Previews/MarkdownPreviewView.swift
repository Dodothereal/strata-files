import AppKit

/// Rendered Markdown: headings, lists, quotes, highlighted code blocks, tables and clickable links.
final class MarkdownPreviewView: PreviewView, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    // TextKit 1 draws NSTextBlock backgrounds and NSTextTable cells.
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let layoutManager = MarkdownLayoutManager()

    init(url: URL) {
        super.init(frame: .zero)
        configure()
        load({ try await MarkdownLoader.load(url) }) { [weak self] document in
            self?.show(document)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        textView.textContainer?.replaceLayoutManager(layoutManager)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        textView.delegate = self
        scrollView.documentView = textView
    }

    private func show(_ document: MarkdownDocument) {
        textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
        layoutManager.replaceTextStorage(document.storage.value)
        let words = document.wordCount == 1 ? "1 word" : "\(document.wordCount.formatted()) words"
        footer.show(["Markdown", words], note: document.isTruncated ? "Showing first \(TextFile.limitDescription)" : nil)
    }

    /// Markdown comes from untrusted files, so links never launch anything: web and mail links open, links to
    /// local files are revealed (not opened, so a link to a script can't run it), other schemes are ignored.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return true }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "file":
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        default:
            break
        }
        return true
    }
}

nonisolated struct MarkdownDocument: Sendable {
    let storage: Handoff<NSTextStorage>
    let wordCount: Int
    let isTruncated: Bool
}

nonisolated enum MarkdownLoader {
    @concurrent
    static func load(_ url: URL) async throws -> MarkdownDocument {
        let file = try TextFile.read(url)
        guard !file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PreviewError.empty }
        let blocks = MarkdownParser.parse(file.text)
        try Task.checkCancellation()
        let rendered = MarkdownRenderer(baseURL: url.deletingLastPathComponent()).render(blocks)
        try Task.checkCancellation()
        var words = 0
        rendered.string.enumerateSubstrings(in: rendered.string.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        return MarkdownDocument(storage: Handoff(value: NSTextStorage(attributedString: rendered)), wordCount: words,
                                isTruncated: file.isTruncated)
    }
}

/// Draws inline code backgrounds as small rounded capsules instead of full-line-height boxes.
nonisolated final class MarkdownLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard color === MarkdownColors.inlineCode else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        for rect in UnsafeBufferPointer(start: rectArray, count: rectCount) {
            let capsule = rect.insetBy(dx: -2, dy: max(1, (rect.height - 16) / 2))
            NSBezierPath(roundedRect: capsule, xRadius: 3.5, yRadius: 3.5).fill()
        }
    }
}
