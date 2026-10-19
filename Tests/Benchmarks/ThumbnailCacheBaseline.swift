import AppKit

/// The NSCache policy from main 8cad325, kept so the thumbnail comparison can be repeated after the change.
final class ThumbnailCacheBaseline {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.totalCostLimit = 400 * 1024 * 1024
        cache.countLimit = 1500
    }

    func image(forKey key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func insert(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
