import AppKit
import UniformTypeIdentifiers
import ImageIO
import Quartz

/// Live preview and metadata for the selection, or for the current folder when nothing is selected.
final class InspectorViewController: NSViewController {
    private let previewBox = NSView()
    private let preview: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    /// The shown items' Finder tags, editable.
    private let tagField = TagField()
    private var shownURLs: [URL] = []
    private var previewWork: DispatchWorkItem?
    private let projectView = ProjectInspectorView()
    private let summary = SummaryView()
    private var projectFolder: URL?
    private var projectTask: Task<Void, Never>?
    /// A native preview for code, Markdown, JSON, CSV, SQLite and archives; Quick Look covers everything else.
    private var richPreview: NSView?
    private let richBackdrop = NSBox()
    private var previewHeight: NSLayoutConstraint?

    override func loadView() {
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 14
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.masksToBounds = true

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.shouldCloseWithWindow = true
        preview.autostarts = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        richBackdrop.boxType = .custom
        richBackdrop.fillColor = .textBackgroundColor
        richBackdrop.borderColor = .separatorColor
        richBackdrop.borderWidth = 1
        richBackdrop.cornerRadius = 14
        richBackdrop.isHidden = true
        richBackdrop.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(richBackdrop)
        previewBox.addSubview(preview)
        previewBox.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isSelectable = true
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail

        grid.rowSpacing = 7
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator

        projectView.isHidden = true
        projectView.onDidClean = { [weak self] _ in self?.reloadProject() }
        tagField.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged(_:)), name: .tagsChanged, object: nil)
        let stack = NSStackView(views: [previewBox, titleLabel, subtitleLabel, separator, grid, tagField, summary, projectView])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: previewBox)
        stack.setCustomSpacing(14, after: subtitleLabel)
        stack.setCustomSpacing(14, after: separator)
        stack.setCustomSpacing(12, after: grid)
        stack.setCustomSpacing(18, after: tagField)
        stack.setCustomSpacing(22, after: summary)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            previewBox.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18),
            previewBox.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18),
            richBackdrop.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            richBackdrop.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            richBackdrop.topAnchor.constraint(equalTo: previewBox.topAnchor),
            richBackdrop.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewBox.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 160),
            iconView.heightAnchor.constraint(equalToConstant: 160),
            titleLabel.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: previewBox.widthAnchor),
            separator.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            grid.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            tagField.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            projectView.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            summary.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
        ])
        previewHeight = previewBox.heightAnchor.constraint(equalToConstant: 230)
        previewHeight?.isActive = true
        view = scroll
    }

    @objc private func tagsChanged(_ notification: Notification) {
        guard tagField.currentEditor() == nil,
              let changed = notification.object as? [URL], changed.contains(where: shownURLs.contains) else { return }
        tagField.reload()
    }

    /// Shows `entries`, or `folder` when the selection is empty. Calling again with the same items only refreshes metadata.
    func show(entries: [FileEntry], folder: FileEntry?, folderSize: (URL) -> FolderSize?, canMeasure: (FileEntry) -> Bool) {
        let items = entries.isEmpty ? [folder].compactMap { $0 } : entries
        // The project section follows a single selected folder, or the current folder when nothing is selected.
        loadProject(items.count == 1 && items[0].isFolder ? items[0].url : nil)
        // Summaries for single documents; the card hides itself when there's no readable text.
        // Source code has its own preview; summaries are for prose (PDFs, Markdown, Word, text…).
        let isCode = items.first?.contentType.map { $0.conforms(to: .sourceCode) || $0.conforms(to: .json) || $0.conforms(to: .propertyList) } ?? false
        // Only for files with text to read (a video gets no empty Summary card).
        let document = items.count == 1 && !items[0].isDirectory && !isCode && Summarizer.canSummarize(items[0].url)
            ? items[0].url : nil
        if summary.url != document { summary.url = document }
        summary.isHidden = document == nil
        let urls = items.map(\.url)
        let sameItems = urls == shownURLs
        shownURLs = urls
        // Volumes, links and archives opened as folders don't take tags. A refresh while you type leaves your typing alone.
        tagField.isHidden = items.isEmpty || items.contains { $0.isVolume || !TagStore.canTag($0.url) }
        tagField.undo = view.window?.undoManager
        tagField.errorWindow = view.window
        if !sameItems {
            tagField.urls = urls
        } else if tagField.currentEditor() == nil {
            tagField.reload()
        }

        guard let first = items.first else {
            titleLabel.stringValue = ""
            subtitleLabel.stringValue = ""
            setRows([])
            removeRichPreview()
            preview.isHidden = true
            iconView.isHidden = true
            return
        }

        if items.count == 1 {
            let entry = first
            // Inside an archive opened as a folder, things are described where they appear: in the archive.
            let apparent = ArchiveCache.apparentURL(entry.url)
            titleLabel.stringValue = apparent?.lastPathComponent ?? entry.name
            let size = entry.isDirectory ? folderSize(entry.url).map { Format.bytes($0.bytes) } : entry.size.map(Format.bytes)
            subtitleLabel.stringValue = [entry.kind, size].compactMap { $0 }.joined(separator: " · ")
            var rows: [(String, String)] = []
            if entry.isDirectory {
                if let size = folderSize(entry.url) {
                    rows.append(("Size", "\(Format.bytes(size.bytes)) · \(Format.count(size.files, "file", "files"))"))
                } else if canMeasure(entry) {
                    rows.append(("Size", "Calculating…"))
                } else if entry.isVolume || entry.isSymlink {
                    rows.append(("Size", "—"))
                } else {
                    rows.append(("Size", "Needs Full Disk Access"))
                }
            } else if let bytes = entry.size {
                // The exact byte count only adds information once the size is rounded to KB or more.
                rows.append(("Size", bytes < 1000 ? Format.bytes(bytes) : "\(Format.bytes(bytes)) (\(bytes.formatted()) bytes)"))
            }
            if let dimensions = Self.imageDimensions(entry) { rows.append(("Dimensions", dimensions)) }
            rows.append(("Created", Format.longDate(entry.created)))
            rows.append(("Modified", Format.longDate(entry.modified)))
            if let added = entry.added { rows.append(("Added", Format.longDate(added))) }
            rows.append(("Where", Format.tildePath((apparent ?? entry.url).deletingLastPathComponent())))
            if let cloud = CloudStore.shared.status(for: entry.url) { rows.append(("Cloud", cloud.label)) }
            setRows(rows)
            if !sameItems { schedulePreview(entry) }
        } else {
            titleLabel.stringValue = Format.count(items.count, "item", "items")
            let known = items.compactMap { $0.isDirectory ? folderSize($0.url)?.bytes : $0.size }
            let total = known.reduce(0, +)
            // Symlinked folders, volumes and folders macOS guards aren't measured: their size never arrives, so they
            // mustn't leave the total "calculating" forever.
            let unmeasured = items.filter { item in
                item.isDirectory && folderSize(item.url) == nil
                    && (item.isSymlink || item.isVolume
                        || Privacy.measuringWouldPrompt(item.url, browsing: item.url.deletingLastPathComponent()))
            }.count
            let pending = known.count + unmeasured < items.count
            subtitleLabel.stringValue = Format.bytes(total) + (pending || unmeasured > 0 ? "+" : "")
            let folders = items.filter(\.isFolder).count
            let note = pending ? " (calculating…)" : unmeasured > 0 ? " (\(Format.count(unmeasured, "folder", "folders")) not measured)" : ""
            setRows([
                ("Folders", folders.formatted()),
                ("Files", (items.count - folders).formatted()),
                ("Total", Format.bytes(total) + note),
            ])
            if !sameItems {
                previewWork?.cancel()
                removeRichPreview()
                preview.previewItem = nil
                preview.isHidden = true
                iconView.isHidden = false
                iconView.image = Self.stackedIcons(items)
            }
        }
    }

    private func schedulePreview(_ entry: FileEntry) {
        previewWork?.cancel()
        removeRichPreview()
        iconView.image = IconCache.shared.icon(for: entry)
        iconView.isHidden = false
        preview.isHidden = true
        // Arrowing through a folder shouldn't render every file; wait for the selection to settle.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownURLs == [entry.url] else { return }
                if !entry.isDirectory, let rich = RichPreview.makeView(for: entry.url, contentType: entry.contentType, fallback: { [weak self] in
                    guard let self, self.shownURLs == [entry.url] else { return }
                    self.removeRichPreview()
                    self.showQuickLook(entry.url)
                }) {
                    self.showRich(rich)
                } else {
                    self.showQuickLook(entry.url)
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func showQuickLook(_ url: URL) {
        preview.previewItem = url as NSURL
        preview.isHidden = false
        iconView.isHidden = true
    }

    /// Code and tables need more room than a thumbnail.
    private func showRich(_ rich: NSView) {
        rich.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(rich, positioned: .above, relativeTo: richBackdrop)
        NSLayoutConstraint.activate([
            rich.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            rich.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            rich.topAnchor.constraint(equalTo: previewBox.topAnchor),
            rich.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
        ])
        richPreview = rich
        richBackdrop.isHidden = false
        previewHeight?.constant = 340
        preview.previewItem = nil
        preview.isHidden = true
        iconView.isHidden = true
    }

    /// Dropping the view also cancels its loading.
    private func removeRichPreview() {
        richPreview?.removeFromSuperview()
        richPreview = nil
        richBackdrop.isHidden = true
        previewHeight?.constant = 230
    }

    // MARK: - Project section

    /// Loads the project section for `url` (nil hides it). The same folder isn't reloaded unless `force`; a forced
    /// reload keeps the current section on screen until the new data arrives.
    private func loadProject(_ url: URL?, force: Bool = false) {
        let same = url?.standardizedFileURL.path == projectFolder?.standardizedFileURL.path
        guard !same || force else { return }
        projectFolder = url
        projectTask?.cancel()
        if !same { showProject(nil) }
        guard let url else { return }
        projectTask = Task { [weak self] in
            let info = await ProjectInfo.load(for: url) { partial in
                guard let self, self.projectFolder == url else { return }
                self.showProject(partial)
            }
            guard let self, !Task.isCancelled, self.projectFolder == url else { return }
            self.showProject(info)
        }
    }

    private func showProject(_ info: ProjectInfo?) {
        projectView.configure(info)
        projectView.isHidden = info == nil
    }

    private func reloadProject() {
        loadProject(projectFolder, force: true)
    }

    /// A repository's status changed: refresh the git part only (no rescans).
    func gitStatusChanged(_ notification: Notification) {
        guard let info = projectView.info, let root = notification.userInfo?["root"] as? URL else { return }
        let path = info.folder.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { return }
        projectView.configure(info.withCurrentGit())
    }

    private func setRows(_ rows: [(String, String)]) {
        // NSGridView.removeRow leaves the cell views behind, so remove them explicitly.
        while grid.numberOfRows > 0 {
            let row = grid.row(at: 0)
            for index in 0..<row.numberOfCells { row.cell(at: index).contentView?.removeFromSuperview() }
            grid.removeRow(at: 0)
        }
        for (name, value) in rows {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            // Values wrap in full, like Get Info, rather than lose their middle ("671.1 MB (671,088,640 bytes)", deep
            // paths). No preferred width: the field wraps at the column's real width, which follows the panel's.
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .systemFont(ofSize: 12)
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.isSelectable = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            grid.addRow(with: [label, field])
        }
        if grid.numberOfColumns == 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 74
            grid.column(at: 1).xPlacement = .leading
        }
    }

    private static func imageDimensions(_ entry: FileEntry) -> String? {
        guard entry.contentType?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }

    /// Up to three icons fanned out, like a stack of the selected files.
    private static func stackedIcons(_ items: [FileEntry]) -> NSImage {
        let icons = items.prefix(3).map { IconCache.shared.icon(for: $0) }
        let size = NSSize(width: 160, height: 160)
        return NSImage(size: size, flipped: false) { _ in
            let angles: [CGFloat] = icons.count == 1 ? [0] : icons.count == 2 ? [-7, 6] : [-10, 0, 9]
            for (icon, angle) in zip(icons, angles) {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: size.width / 2, yBy: size.height / 2)
                transform.rotate(byDegrees: angle)
                transform.concat()
                icon.draw(in: NSRect(x: -60, y: -60, width: 120, height: 120))
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
