import AppKit
import UniformTypeIdentifiers

enum PreviewViewMode: Int { case list, icons }

/// Reuse the app's icon drawing and typography for real files and virtual archive members alike.
@MainActor final class PreviewGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PreviewGridItem")
    let itemView = GridItemView()
    private(set) var item: PreviewItem?
    private weak var requests: PreviewThumbnails?
    private var thumbnailBucket: CGFloat?
    private var thumbnailScale: CGFloat = 0

    isolated deinit { requests?.cancel(for: self) }

    override func loadView() { view = itemView; imageView = itemView.imageView }

    override var isSelected: Bool { didSet { updateState() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateState() } }

    override func prepareForReuse() {
        super.prepareForReuse()
        stop()
        item = nil
        itemView.setImage(nil, animated: false)
    }

    func stop() { requests?.cancel(for: self); thumbnailBucket = nil }

    func configure(_ item: PreviewItem, metrics: GridMetrics, preferences: Prefs, thumbnails: FileThumbnails,
                   requests: PreviewThumbnails, scale: CGFloat) {
        let entry = item.entry
        let canRequest = preferences.showIconPreviews && entry.map {
            PreviewFileView.isRegularFile($0.url) && thumbnails.canThumbnail($0)
        } == true
        let bucket = FileThumbnails.bucket(for: metrics.iconSize)
        let keep = self.item === item && self.requests === requests && thumbnailBucket == bucket && thumbnailScale == scale && canRequest
        if !keep { stop() }
        self.requests = requests
        self.item = item
        itemView.configure(name: item.name, matches: [], detail: item.size.map(Format.bytes), metrics: metrics)
        itemView.setAccessibilityHelp(item.kind)
        updateState()
        if keep { return }
        let icon = item.entry.map(thumbnails.icon)
            ?? IconCache.shared.icon(forType: item.isDirectory ? .folder : UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        itemView.setImage(icon, animated: false)
        guard canRequest, let entry else { return }
        thumbnailBucket = bucket
        thumbnailScale = scale
        if let cached = thumbnails.cached(entry, size: metrics.iconSize, scale: scale) {
            itemView.setImage(cached.image, animated: false, upscale: !cached.exact)
            if cached.exact { return }
        }
        requests.request(for: self, entry: entry, size: metrics.iconSize, scale: scale) { [weak self, weak item] image in
            guard let self, let item, self.item === item else { return }
            itemView.setImage(image, animated: true, upscale: false)
        }
    }

    func updateState() {
        var state = GridItemState()
        state.selected = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        state.emphasized = collectionView?.window?.isKeyWindow == true && collectionView?.window?.firstResponder === collectionView
        state.dimmed = item?.entry?.isHidden == true
        itemView.setState(state)
    }
}
