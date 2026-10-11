import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Quick Look thumbnails for the icon grid and column preview, generated on demand and cached by path,
/// modification date and size bucket. Requests for the same thumbnail are coalesced; cancelling the last
/// interested caller cancels the generation.
final class FileThumbnails {
    static let shared = FileThumbnails()

    /// Point sizes thumbnails are generated at; a request uses the smallest bucket that covers it.
    private static let buckets: [CGFloat] = [32, 64, 128, 256, 512]

    final class Ticket {
        fileprivate let key: String
        fileprivate let id: Int
        fileprivate init(key: String, id: Int) {
            self.key = key
            self.id = id
        }
    }

    private struct Pending {
        var request: QLThumbnailGenerator.Request
        var generation: Int
        var callbacks: [Int: (NSImage) -> Void]
    }

    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: Pending] = [:]
    /// Keys Quick Look had nothing for, so they aren't asked for again.
    private var failed: Set<String> = []
    private var nextID = 0

    private init() {
        cache.countLimit = 1500
        cache.totalCostLimit = 400 * 1024 * 1024
    }

    /// Images, PDFs, movies and documents get thumbnails; folders, apps and opaque files keep their icon.
    static func canThumbnail(_ entry: FileEntry) -> Bool {
        guard !entry.isFolder, let type = entry.contentType else { return false }
        if entry.isPackage {
            return type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent)
        }
        if type.conforms(to: .application) || type.conforms(to: .archive) || type.conforms(to: .diskImage)
            || type.conforms(to: .unixExecutable) || type.conforms(to: .aliasFile) { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .compositeContent) || type.conforms(to: .font) || type.conforms(to: .threeDContent)
            || type.conforms(to: .epub)
    }

    static func bucket(for size: CGFloat) -> CGFloat {
        buckets.first(where: { $0 >= size }) ?? buckets.last!
    }

    private func key(_ entry: FileEntry, _ bucket: CGFloat, _ scale: CGFloat) -> String {
        let stamp = entry.modified?.timeIntervalSinceReferenceDate ?? 0
        return "\(entry.url.path)|\(stamp)|\(entry.size ?? -1)|\(Int(bucket * scale))"
    }

    /// The best thumbnail already in memory for `size`: an exact or larger bucket, else a smaller one.
    /// `exact` tells whether it's sharp enough or a better one should still be requested.
    func cached(_ entry: FileEntry, size: CGFloat, scale: CGFloat) -> (image: NSImage, exact: Bool)? {
        let wanted = Self.bucket(for: size)
        for b in Self.buckets where b >= wanted {
            if let image = cache.object(forKey: key(entry, b, scale) as NSString) { return (image, true) }
        }
        for b in Self.buckets.reversed() where b < wanted {
            if let image = cache.object(forKey: key(entry, b, scale) as NSString) { return (image, false) }
        }
        return nil
    }

    /// Whether Quick Look already said it has no thumbnail for this file.
    func hasFailed(_ entry: FileEntry, size: CGFloat, scale: CGFloat) -> Bool {
        failed.contains(key(entry, Self.bucket(for: size), scale))
    }

    /// Generates a thumbnail; `completion` runs on the main actor, only on success and only if not cancelled.
    @discardableResult
    func request(_ entry: FileEntry, size: CGFloat, scale: CGFloat, completion: @escaping (NSImage) -> Void) -> Ticket? {
        guard Self.canThumbnail(entry) else { return nil }
        let bucket = Self.bucket(for: size)
        let key = key(entry, bucket, scale)
        if failed.contains(key) { return nil }
        if let image = cache.object(forKey: key as NSString) {
            completion(image)
            return nil
        }
        nextID += 1
        let ticket = Ticket(key: key, id: nextID)
        if pending[key] != nil {
            pending[key]!.callbacks[ticket.id] = completion
            return ticket
        }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: bucket, height: bucket),
                                                   scale: scale, representationTypes: .thumbnail)
        request.iconMode = true
        let generation = ticket.id
        pending[key] = Pending(request: request, generation: generation, callbacks: [ticket.id: completion])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            // Icon-mode thumbnails sit on a square transparent canvas; trim it so wide images can bottom-align.
            let image = representation.map { FileThumbnails.trimmed($0.cgImage) }
            let cancelled = (error as? CocoaError)?.code == .userCancelled || (error as NSError?)?.code == NSUserCancelledError
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    FileThumbnails.shared.finish(key, generation: generation, image, cancelled: cancelled, bucket: bucket)
                }
            }
        }
        return ticket
    }

    func cancel(_ ticket: Ticket?) {
        guard let ticket, var entry = pending[ticket.key] else { return }
        entry.callbacks[ticket.id] = nil
        if entry.callbacks.isEmpty {
            pending[ticket.key] = nil
            QLThumbnailGenerator.shared.cancel(entry.request)
        } else {
            pending[ticket.key] = entry
        }
    }

    /// Crops the transparent canvas around the thumbnail's opaque body, keeping a margin wide enough for the soft
    /// drop shadow to fade out (no hard edge). Runs on Quick Look's callback thread.
    nonisolated static func trimmed(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard width > 2, height > 2, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast,
              image.alphaInfo != .noneSkipFirst else { return image }
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        let threshold: UInt8 = 128
        var top = height, bottom = -1, left = width, right = -1
        for y in 0..<height {
            let row = y * width
            var rowHasInk = false
            for x in 0..<width where alpha[row + x] > threshold {
                rowHasInk = true
                if x < left { left = x }
                break
            }
            guard rowHasInk else { continue }
            var x = width - 1
            while x > right, alpha[row + x] <= threshold { x -= 1 }
            if x > right { right = x }
            if y < top { top = y }
            bottom = y
        }
        guard bottom >= top, right >= left else { return image }
        // The shadow falls downward, so leave more room below than around.
        let side = Double(max(width, height))
        let margin = max(2, Int((side * 0.035).rounded()))
        let below = max(3, Int((side * 0.075).rounded()))
        let rect = CGRect(x: left - margin, y: top - margin, width: right - left + 1 + margin * 2,
                          height: bottom - top + 1 + margin + below)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width < CGFloat(width) - 2 || rect.height < CGFloat(height) - 2 else { return image }
        return image.cropping(to: rect) ?? image
    }

    private func finish(_ key: String, generation: Int, _ cgImage: CGImage?, cancelled: Bool, bucket: CGFloat) {
        // A cancelled request can still complete after a new one for the same key started; ignore it.
        guard let entry = pending[key], entry.generation == generation else { return }
        pending[key] = nil
        guard let cgImage else {
            if !cancelled { failed.insert(key) }
            return
        }
        // Point size: the pixel size at the request's scale (the canvas was bucket × scale pixels).
        let scale = max(CGFloat(entry.request.scale), 1)
        let factor = 1 / scale
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) * factor,
                                                           height: CGFloat(cgImage.height) * factor))
        cache.setObject(image, forKey: key as NSString, cost: cgImage.width * cgImage.height * 4)
        for callback in entry.callbacks.values { callback(image) }
    }
}

/// Small facts shown under icons, read off the main thread: a folder's item count, an image's pixel size.
final class ItemInfoLoader {
    static let shared = ItemInfoLoader()

    private var cache: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [Int: (String) -> Void]] = [:]
    private var nextID = 0

    final class Ticket {
        fileprivate let key: String
        fileprivate let id: Int
        fileprivate init(key: String, id: Int) {
            self.key = key
            self.id = id
        }
    }

    /// The text to show right away: a file's size, or a cached count/dimension. Nil means "ask `request`".
    func immediate(_ entry: FileEntry, showHidden: Bool) -> String? {
        if let cached = cache[key(entry, showHidden)] { return cached }
        if needsLoading(entry) { return nil }
        if entry.isDirectory { return nil }
        return entry.size.map(Format.bytes)
    }

    func needsLoading(_ entry: FileEntry) -> Bool {
        if entry.isFolder { return !entry.isSymlink && !entry.isVolume }
        return entry.contentType?.conforms(to: .image) == true
    }

    private func key(_ entry: FileEntry, _ showHidden: Bool) -> String {
        "\(entry.url.path)|\(entry.modified?.timeIntervalSinceReferenceDate ?? 0)|\(showHidden)"
    }

    func request(_ entry: FileEntry, showHidden: Bool, completion: @escaping (String) -> Void) -> Ticket? {
        guard needsLoading(entry) else { return nil }
        let key = key(entry, showHidden)
        if let cached = cache[key] {
            completion(cached)
            return nil
        }
        nextID += 1
        let ticket = Ticket(key: key, id: nextID)
        waiters[key, default: [:]][ticket.id] = completion
        if tasks[key] == nil {
            let url = entry.url
            let isFolder = entry.isFolder
            let fallback = entry.size.map(Format.bytes)
            tasks[key] = Task { [weak self] in
                let text = await Self.load(url, isFolder: isFolder, showHidden: showHidden)
                guard !Task.isCancelled else { return }
                self?.finish(key, text ?? fallback ?? "")
            }
        }
        return ticket
    }

    func cancel(_ ticket: Ticket?) {
        guard let ticket else { return }
        waiters[ticket.key]?[ticket.id] = nil
        if waiters[ticket.key]?.isEmpty == true {
            waiters[ticket.key] = nil
            tasks.removeValue(forKey: ticket.key)?.cancel()
        }
    }

    private func finish(_ key: String, _ text: String) {
        tasks[key] = nil
        cache[key] = text
        if cache.count > 20000 { cache.removeAll(keepingCapacity: true) }
        for callback in (waiters.removeValue(forKey: key) ?? [:]).values { callback(text) }
    }

    @concurrent
    private nonisolated static func load(_ url: URL, isFolder: Bool, showHidden: Bool) async -> String? {
        if isFolder {
            guard let dir = opendir(url.path) else { return nil }
            defer { closedir(dir) }
            var count = 0
            while let entry = readdir(dir) {
                if Task.isCancelled { return nil }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                if !showHidden, name.hasPrefix(".") { continue }
                count += 1
            }
            return "\(count.formatted()) \(count == 1 ? "item" : "items")"
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }
}
