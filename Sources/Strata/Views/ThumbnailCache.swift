import AppKit

/// Decoded thumbnails shared by the file views. Callers keep their visible images independently of this cache.
final class ThumbnailCache {
    private final class Entry {
        let key: String
        let image: NSImage
        let cost: Int
        weak var previous: Entry?
        var next: Entry?

        init(key: String, image: NSImage, cost: Int) {
            self.key = key
            self.image = image
            self.cost = cost
        }
    }

    private let costLimit: Int
    private let countLimit: Int
    private var entries: [String: Entry] = [:]
    private var first: Entry?
    private var last: Entry?
    private var cost = 0
    private let pressure: DispatchSourceMemoryPressure?

    init(costLimit: Int = 128 * 1024 * 1024, countLimit: Int = 1500, observesMemoryPressure: Bool = true) {
        precondition(costLimit >= 0 && countLimit > 0)
        self.costLimit = costLimit
        self.countLimit = countLimit
        pressure = observesMemoryPressure
            ? DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main) : nil
        pressure?.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.removeAll() }
        }
        pressure?.resume()
    }

    deinit { pressure?.cancel() }

    func image(forKey key: String) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        if entry !== last {
            detach(entry)
            append(entry)
        }
        return entry.image
    }

    func insert(_ image: NSImage, forKey key: String, cost: Int) {
        if let old = entries[key] { discard(old) }
        let cost = max(0, cost)
        // An image can still be shown by its caller when it is too large to keep in the shared cache.
        guard cost <= costLimit else { return }
        while let oldest = first, self.cost > costLimit - cost || entries.count >= countLimit { discard(oldest) }
        let entry = Entry(key: key, image: image, cost: cost)
        entries[key] = entry
        self.cost += cost
        append(entry)
    }

    func removeAll() {
        while let entry = first { discard(entry) }
    }

    func remove(forKey key: String) {
        if let entry = entries[key] { discard(entry) }
    }

    private func append(_ entry: Entry) {
        entry.previous = last
        last?.next = entry
        last = entry
        if first == nil { first = entry }
    }

    private func detach(_ entry: Entry) {
        if let previous = entry.previous { previous.next = entry.next } else { first = entry.next }
        if let next = entry.next { next.previous = entry.previous } else { last = entry.previous }
        entry.previous = nil
        entry.next = nil
    }

    private func discard(_ entry: Entry) {
        detach(entry)
        entries.removeValue(forKey: entry.key)
        cost -= entry.cost
    }
}
