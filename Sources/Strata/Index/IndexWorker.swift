import Foundation
import os

/// What to index. Changing exclusions only rescans the affected folders.
nonisolated struct IndexConfig: Sendable, Equatable {
    var roots: [String]
    var excluded: Set<String>
    var noise: Set<String>
    var file: URL
}

/// Owns the index on a private serial queue: loads or builds it, applies FSEvents changes, saves it.
nonisolated final class IndexWorker: @unchecked Sendable {
    private let log = Logger(subsystem: "dev.strata.app", category: "index")
    enum Phase: Sendable, Equatable {
        case loading
        case scanning(items: Int)
        case ready
    }

    private let queue = DispatchQueue(label: "dev.strata.index", qos: .utility)
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
    private var config: IndexConfig?
    private var store: IndexStore?
    private var lastEventID: UInt64 = 0
    private var dirty = false
    private var pending: [String: Bool] = [:] // folder path → deep
    private var rescanNeeded = false
    private var flushScheduled = false
    private var saveScheduled = false
    private let events = FSEventsStream()

    /// Called with each new store (after loading or a full rebuild) and every phase change.
    var onStore: (@Sendable (IndexStore) -> Void)?
    var onPhase: (@Sendable (Phase) -> Void)?
    /// Called after changes were applied (sizes or entries).
    var onChange: (@Sendable () -> Void)?

    init() {
        events.handler = { [weak self] events in self?.receive(events) }
    }

    deinit {
        readBuffer.deallocate()
    }

    func start(_ config: IndexConfig) {
        queue.async { self.boot(config) }
    }

    func update(_ config: IndexConfig) {
        queue.async { self.reconfigure(config) }
    }

    func rebuildNow() {
        queue.async { self.rebuild() }
    }

    /// Writes the index now (used at quit). Skipped while a full scan is still running.
    func saveNow() {
        queue.sync { self.save() }
    }

    // MARK: - Lifecycle (on `queue`)

    private func boot(_ config: IndexConfig) {
        self.config = config
        onPhase?(.loading)
        let loadResult = Result { try IndexPersistence.load(from: config.file) }
        if case .success(let (loaded, header)) = loadResult, header.roots.map(\.path) == config.roots {
            log.info("Loaded \(loaded.count) entries, replaying events since \(header.eventID)")
            store = loaded
            onStore?(loaded)
            onPhase?(.ready)
            lastEventID = header.eventID
            // Catch up on everything that changed since the save, then keep listening.
            events.start(paths: config.roots, since: header.eventID)
            if Set(header.excluded) != config.excluded {
                reconfigure(config, previous: Set(header.excluded))
            }
        } else {
            log.info("Full scan: \(String(describing: loadResult.map { $0.1.roots.map(\.path) }))")
            rebuild()
        }
    }

    private func rebuild() {
        guard let config else { return }
        events.stop()
        let startEventID = FSEventsStream.currentEventID
        let fresh = IndexStore()
        fresh.reserve(entries: IndexStore.estimatedEntries(under: config.roots))
        let scanner = IndexScanner(store: fresh, excluded: config.excluded, noiseFolders: config.noise)
        let roots = fresh.write { config.roots.map { (fresh.addRoot(path: $0, mtime: 0), $0) } }
        onPhase?(.scanning(items: 0))
        let progress = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        progress.schedule(deadline: .now() + 0.5, repeating: 0.5)
        progress.setEventHandler { [weak self] in self?.onPhase?(.scanning(items: scanner.scannedCount)) }
        progress.resume()
        scanner.scan(roots.map { (id: $0.0, path: $0.1) })
        progress.cancel()
        fresh.write { fresh.aggregate() }
        store = fresh
        lastEventID = startEventID
        rescanNeeded = false
        onStore?(fresh)
        onPhase?(.ready)
        save()
        // Replays whatever changed during the scan.
        events.start(paths: config.roots, since: startEventID)
    }

    private func reconfigure(_ config: IndexConfig, previous: Set<String>? = nil) {
        guard let old = previous ?? self.config?.excluded else { return }
        let rootsChanged = self.config.map { $0.roots != config.roots } ?? true
        self.config = config
        guard let store else { return }
        if rootsChanged {
            log.info("Roots changed, full scan")
            rebuild()
            return
        }
        // Newly allowed folders get scanned; newly excluded ones are emptied.
        for path in old.subtracting(config.excluded).sorted() {
            if let id = store.read({ store.lookup(path) }) { refreshFolder(id, path, deep: true) }
        }
        for path in config.excluded.subtracting(old).sorted() {
            store.write {
                guard let id = store.lookup(path) else { return }
                for child in store.children(of: id) { store.remove(child) }
            }
        }
        markChanged()
    }

    private func save() {
        guard let config, let store, dirty || !FileManager.default.fileExists(atPath: config.file.path) else { return }
        try? IndexPersistence.save(store, eventID: lastEventID, excluded: Array(config.excluded), to: config.file)
        dirty = false
    }

    // MARK: - Live updates

    private func receive(_ batch: [FSEventsStream.Event]) {
        queue.async {
            for event in batch {
                self.lastEventID = max(self.lastEventID, event.id)
                if event.isHistoryDone { continue }
                if event.invalidatesIndex {
                    self.log.info("Event invalidates index: \(event.path) flags \(event.flags)")
                    self.rescanNeeded = true
                    continue
                }
                var path = event.path
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                self.pending[path] = (self.pending[path] ?? false) || event.mustScanSubdirectories
            }
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) {
            self.flushScheduled = false
            self.flush()
        }
    }

    private func flush() {
        if rescanNeeded {
            pending.removeAll()
            rebuild()
            return
        }
        guard let config, let store, !pending.isEmpty else { return }
        let work = pending.sorted { $0.key < $1.key }
        pending.removeAll()
        var deepRoots: [String] = []
        for (path, deep) in work {
            // A deep refresh of a parent already covers this folder.
            if deepRoots.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            if isExcluded(path, config) { continue }
            if deep { deepRoots.append(path) }
            // The folder may be new: refresh the nearest ancestor we already know about.
            var target = path
            var id = store.read { store.lookup(target) }
            while id == nil, target.count > 1 {
                target = (target as NSString).deletingLastPathComponent
                id = store.read { store.lookup(target) }
            }
            guard let id, store.read({ store.isDirectory(id) }) else { continue }
            refreshFolder(id, target, deep: deep)
        }
        markChanged()
    }

    private func isExcluded(_ path: String, _ config: IndexConfig) -> Bool {
        config.excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func markChanged() {
        dirty = true
        onChange?()
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 120) {
            self.saveScheduled = false
            self.save()
        }
    }

    /// Re-reads one folder and applies the differences. New subfolders are scanned in full; with `deep`, existing
    /// subfolders are refreshed too (FSEvents asks for that when it coalesced too many changes).
    private func refreshFolder(_ id: Int32, _ path: String, deep: Bool) {
        guard let config, let store else { return }
        var items: [ScannedItem] = []
        var names: [UInt8] = []
        let error = BulkDirectoryReader.read(path, items: &items, names: &names, buffer: readBuffer)
        if error == ENOENT || error == ENOTDIR {
            store.write { store.remove(id) }
            return
        }
        guard error == 0 else { return }

        let prefix = path.hasSuffix("/") ? path : path + "/"
        let ownNoise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
        var newFolders: [(id: Int32, path: String)] = []
        var existingFolders: [(id: Int32, path: String)] = []
        let firstNew: Int32 = store.write {
            let firstNew = Int32(store.count)
            var existing: [String: Int32] = [:]
            for child in store.children(of: id) { existing[store.name(child)] = child }
            let inheritedNoise = store.flags[Int(id)] & IndexStore.Flag.noise != 0 || store.isOpaquePackage(id)
            var additions: [ScannedItem] = []
            var additionNoise: [Bool] = []
            for (index, item) in items.enumerated() {
                let name = String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
                guard let old = existing.removeValue(forKey: name) else {
                    additions.append(item)
                    additionNoise.append(ownNoise[index])
                    continue
                }
                let o = Int(old)
                // A folder whose noise status changed (a Cargo.toml or package.json appeared or went away next to
                // it) is re-added so its whole subtree picks up the new flag.
                let expectedNoise = item.isDirectory && (inheritedNoise || ownNoise[index] || config.noise.contains(prefix + name))
                let noiseChanged = item.isDirectory && expectedNoise != (store.flags[o] & IndexStore.Flag.noise != 0)
                if store.isDirectory(old) != item.isDirectory || noiseChanged {
                    store.remove(old)
                    additions.append(item)
                    additionNoise.append(ownNoise[index])
                } else if item.isDirectory {
                    store.mtime[o] = item.mtime
                    if deep, !item.isMountPoint, !isExcluded(prefix + name, config) { existingFolders.append((old, prefix + name)) }
                } else if store.size[o] != item.size || store.mtime[o] != item.mtime {
                    store.propagate(from: old, bytes: item.size - store.size[o], files: 0)
                    store.size[o] = item.size
                    store.mtime[o] = item.mtime
                }
            }
            for gone in existing.values { store.remove(gone) }
            guard !additions.isEmpty else { return firstNew }
            let ids = names.withUnsafeBytes { store.appendChildren(additions, nameBuffer: $0, of: id, ownNoise: additionNoise) }
            for (offset, item) in additions.enumerated() where item.isDirectory && !item.isMountPoint {
                let childPath = prefix + String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
                let childID = ids.lowerBound + Int32(offset)
                if config.noise.contains(childPath) { store.flags[Int(childID)] |= IndexStore.Flag.noise }
                if !isExcluded(childPath, config) { newFolders.append((childID, childPath)) }
            }
            return firstNew
        }
        if !newFolders.isEmpty {
            IndexScanner(store: store, excluded: config.excluded, noiseFolders: config.noise).scan(newFolders, threads: 4)
        }
        store.write { store.integrateNew(from: firstNew) }
        for folder in existingFolders { refreshFolder(folder.id, folder.path, deep: true) }
    }
}
