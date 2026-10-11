import AppKit

/// Geometry of one icon-grid cell, derived from the icon size so the whole grid scales with the slider.
struct GridMetrics: Equatable {
    static let minIconSize: CGFloat = 32
    static let maxIconSize: CGFloat = 256

    let iconSize: CGFloat
    /// Padding between the icon and its selection box.
    let iconPad: CGFloat
    let topPad: CGFloat = 6
    let nameGap: CGFloat = 4
    let lineHeight: CGFloat
    let detailHeight: CGFloat
    let bottomPad: CGFloat = 6

    init(iconSize: CGFloat) {
        self.iconSize = min(max(iconSize.rounded(), Self.minIconSize), Self.maxIconSize)
        iconPad = (self.iconSize * 0.07).rounded().clamped(3, 10)
        let font = FileViewStyle.nameFont
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let detail = FileViewStyle.detailFont
        detailHeight = ceil(detail.ascender - detail.descender) + 2
    }

    /// Width available to the name: a little wider than the icon, never narrower than two short words.
    var labelWidth: CGFloat { max(iconSize + 34, 94) }
    var minCellWidth: CGFloat { labelWidth + 16 }
    var iconBoxSide: CGFloat { iconSize + iconPad * 2 }
    var itemHeight: CGFloat {
        topPad + iconBoxSide + nameGap + lineHeight * 2 + 2 + detailHeight + bottomPad
    }
}

fileprivate extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat { Swift.min(Swift.max(self, low), high) }
}

/// A justified grid: as many equal columns as fit, items centered in each, rows of uniform height. Layout is O(visible)
/// so huge folders scroll smoothly. Points between items propose a background drop (gap before the end) instead of
/// an insertion point, since a file grid has no manual ordering.
final class GridLayout: NSCollectionViewLayout {
    var metrics = GridMetrics(iconSize: 64)
    var itemCount = 0
    var insets = NSEdgeInsets(top: 10, left: 14, bottom: 18, right: 14)
    var rowSpacing: CGFloat = 2

    private(set) var columns = 1
    private(set) var cellWidth: CGFloat = 100
    private var lastWidth: CGFloat = 0

    private var width: CGFloat {
        collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width ?? 0
    }

    override func prepare() {
        super.prepare()
        itemCount = collectionView.map { $0.numberOfSections > 0 ? $0.numberOfItems(inSection: 0) : 0 } ?? 0
        let available = max(width - insets.left - insets.right, metrics.minCellWidth)
        columns = max(1, Int(available / metrics.minCellWidth))
        cellWidth = floor(available / CGFloat(columns))
        lastWidth = width
    }

    var rows: Int { itemCount == 0 ? 0 : (itemCount + columns - 1) / columns }
    var rowHeight: CGFloat { metrics.itemHeight }

    override var collectionViewContentSize: NSSize {
        let height = insets.top + CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing + insets.bottom
        return NSSize(width: width, height: height)
    }

    func frame(for index: Int) -> NSRect {
        let row = index / columns, column = index % columns
        let available = width - insets.left - insets.right
        // Distribute leftover pixels from flooring evenly so the grid stays centered.
        let slack = max(available - cellWidth * CGFloat(columns), 0)
        let x = insets.left + (slack / 2).rounded(.down) + CGFloat(column) * cellWidth
        let y = insets.top + CGFloat(row) * (rowHeight + rowSpacing)
        return NSRect(x: x, y: y, width: cellWidth, height: rowHeight)
    }

    func index(at point: NSPoint) -> Int? {
        guard itemCount > 0 else { return nil }
        let available = width - insets.left - insets.right
        let slack = max(available - cellWidth * CGFloat(columns), 0)
        let column = Int(floor((point.x - insets.left - (slack / 2).rounded(.down)) / cellWidth))
        let row = Int(floor((point.y - insets.top) / (rowHeight + rowSpacing)))
        guard column >= 0, column < columns, row >= 0 else { return nil }
        let index = row * columns + column
        guard index < itemCount, frame(for: index).contains(point) else { return nil }
        return index
    }

    /// Items whose rows intersect `rect`.
    func indexes(in rect: NSRect) -> Range<Int> {
        guard itemCount > 0 else { return 0..<0 }
        let pitch = rowHeight + rowSpacing
        let first = max(Int(floor((rect.minY - insets.top) / pitch)), 0)
        let last = max(Int(floor((rect.maxY - insets.top) / pitch)), first)
        let lower = min(first * columns, itemCount)
        let upper = min((last + 1) * columns, itemCount)
        return lower..<upper
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        indexes(in: rect).map { attributes(for: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < itemCount else { return nil }
        return attributes(for: indexPath.item)
    }

    private func attributes(for index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frame(for: index)
        return attributes
    }

    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        if let index = index(at: pointInCollectionView) { return attributes(for: index) }
        let gap = NSCollectionViewLayoutAttributes(forInterItemGapBefore: IndexPath(item: itemCount, section: 0))
        gap.frame = .zero
        return gap
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - lastWidth) > 0.5
    }
}
