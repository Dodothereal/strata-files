import AppKit

/// Icon + file name, with fuzzy-match characters highlighted while filtering.
final class NameCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let gitBadge = GitStatusBadge()
    private let tagDots = TagDotsView()
    private let cloudBadge = CloudBadge()
    private var name = ""
    private var matches: [Int] = []
    private var dimmed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        gitBadge.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The name hugs its text so tag dots follow it, like Finder.
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        cloudBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        addSubview(tagDots)
        addSubview(cloudBadge)
        addSubview(gitBadge)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            tagDots.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            tagDots.trailingAnchor.constraint(lessThanOrEqualTo: cloudBadge.leadingAnchor, constant: -2),
            cloudBadge.trailingAnchor.constraint(equalTo: gitBadge.leadingAnchor),
            cloudBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagDots.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            gitBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, icon image: NSImage, matches: [Int], dimmed: Bool, git: GitBadge? = nil,
                   tags: [FinderTag] = [], cloud: CloudStatus? = nil) {
        self.name = name
        self.matches = matches
        self.dimmed = dimmed
        gitBadge.badge = git
        cloudBadge.status = cloud
        tagDots.tags = tags
        tagDots.alphaValue = dimmed ? 0.45 : 1
        icon.image = image
        icon.alphaValue = dimmed ? 0.45 : 1
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            gitBadge.backgroundStyle = backgroundStyle
            tagDots.backgroundStyle = backgroundStyle
            cloudBadge.backgroundStyle = backgroundStyle
            render()
        }
    }

    private func render() {
        let selected = backgroundStyle == .emphasized
        var color: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        if dimmed { color = color.withAlphaComponent(0.5) }
        let font = FileViewStyle.nameFont
        // The field's own font too: renaming edits at the size the name is shown.
        label.font = font
        // Attributed strings ignore the field's line break mode; without this, long names wrap onto clipped lines.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        if !matches.isEmpty {
            let bold = FileViewStyle.nameBoldFont
            let highlight: NSColor = selected ? color : .controlAccentColor
            let characters = Array(name)
            var utf16Offset = 0
            var offsets: [Int] = []
            for c in characters {
                offsets.append(utf16Offset)
                utf16Offset += c.utf16.count
            }
            for i in matches where i < characters.count {
                let range = NSRange(location: offsets[i], length: characters[i].utf16.count)
                text.addAttributes([.font: bold, .foregroundColor: highlight], range: range)
            }
        }
        label.attributedStringValue = text
    }
}

/// Secondary-colored text for the metadata columns.
final class TextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var dimmed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, alignment: NSTextAlignment, dimmed: Bool = false) {
        label.stringValue = text
        label.alignment = alignment
        self.dimmed = dimmed
        updateColor()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        let selected = backgroundStyle == .emphasized
        let base: NSColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        label.textColor = dimmed ? base.withAlphaComponent(0.5) : base
    }
}

/// A header row above a group of files: icon, a bold title and a secondary detail.
final class GroupHeaderCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, detail info: String, icon image: NSImage) {
        title.stringValue = text
        detail.stringValue = info
        icon.image = image
    }
}
