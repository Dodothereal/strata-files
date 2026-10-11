import AppKit
import UniformTypeIdentifiers

/// Finder icons, cached per file type for documents and per path for folders and packages (which can have their own).
final class IconCache {
    static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()

    private init() {
        byPath.countLimit = 4000
    }

    func icon(for entry: FileEntry) -> NSImage {
        if !entry.isDirectory, !entry.isSymlink, let type = entry.contentType {
            if let cached = byType[type.identifier] { return cached }
            let image = NSWorkspace.shared.icon(for: type)
            byType[type.identifier] = image
            return image
        }
        return icon(forPath: entry.url.path)
    }

    func icon(forPath path: String) -> NSImage {
        if let cached = byPath.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        byPath.setObject(image, forKey: path as NSString)
        return image
    }
}
