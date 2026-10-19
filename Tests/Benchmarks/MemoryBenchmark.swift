import AppKit
import Darwin

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return info.phys_footprint
}

func thumbnail(seed: Int) -> NSImage {
    let side = 1024
    let backing = UnsafeMutableRawPointer.allocate(byteCount: side * side * 4, alignment: 16)
    let pixels = backing.bindMemory(to: UInt32.self, capacity: side * side)
    var value = UInt32(seed + 1)
    for pixel in 0..<(side * side) {
        value ^= value << 13
        value ^= value >> 17
        value ^= value << 5
        pixels[pixel] = value | 0xff00_0000
    }
    let provider = CGDataProvider(dataInfo: nil, data: backing, size: side * side * 4) { _, data, _ in
        UnsafeMutableRawPointer(mutating: data).deallocate()
    }!
    let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    return NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
}

@main struct MemoryBenchmark {
    static func main() async throws {
        precondition(SecureStorage.isTestRun, "Benchmarks must use DEBUG's throwaway storage and key.")
        let mode = CommandLine.arguments.dropFirst().first ?? "semantic"
        let passages = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? (mode.hasPrefix("thumbnails") ? 160 : 50_000)
        precondition((1...10_000_000).contains(passages))
        switch mode {
        case "semantic":
            let folder = SecureStorage.url("memory-benchmark", isDirectory: true)
            try autoreleasepool {
                try SemanticFixture.write(SemanticFixture.make(passages: passages, sentences: false, root: folder), to: folder)
            }
            // Clear the fixture builder's freed allocations before measuring the actual reader in this process.
            malloc_zone_pressure_relief(nil, 0)
            var configuration = SemanticIndex.Configuration(roots: [])
            configuration.storeDirectory = folder
            let index = SemanticIndex(configuration: configuration)
            let before = footprint()
            let start = ContinuousClock.now
            _ = await index.search("")
            let loadTime = start.duration(to: .now)
            let bytes = await index.vectorStorageBytes
            let loaded = footprint()
            let count = await index.indexedFileCount
            precondition(count == passages)
            let result = "semantic passages=\(count) before_bytes=\(before) loaded_bytes=\(loaded) delta_bytes=\(Int64(loaded) - Int64(before)) word_capacity_bytes=\(bytes.word) sentence_capacity_bytes=\(bytes.sentence) load_time=\(loadTime)\n"
            FileHandle.standardOutput.write(Data(result.utf8))
            let hits = await index.search("stratamemoryprobe", limit: 1)
            precondition(hits.first?.url.lastPathComponent == "document-\(passages / 2).txt")
            print("semantic functional_probe=passed")
        case "thumbnails", "thumbnails-baseline":
            let image: (String) -> NSImage?
            let insert: (NSImage, String, Int) -> Void
            if mode == "thumbnails-baseline" {
                let cache = ThumbnailCacheBaseline()
                image = cache.image(forKey:)
                insert = { cache.insert($0, forKey: $1, cost: $2) }
            } else {
                let cache = ThumbnailCache()
                image = cache.image(forKey:)
                insert = { cache.insert($0, forKey: $1, cost: $2) }
            }
            let before = footprint()
            let start = ContinuousClock.now
            for number in 0..<passages {
                autoreleasepool {
                    insert(thumbnail(seed: number), "thumbnail-\(number)", 1024 * 1024 * 4)
                }
            }
            let elapsed = start.duration(to: .now)
            let loaded = footprint()
            let retained = (0..<passages).filter { image("thumbnail-\($0)") != nil }.count
            precondition(image("thumbnail-\(passages - 1)")?.size == NSSize(width: 512, height: 512))
            print("\(mode) generated=\(passages) retained=\(retained) before_bytes=\(before) loaded_bytes=\(loaded) delta_bytes=\(Int64(loaded) - Int64(before)) fill_time=\(elapsed)")
            withExtendedLifetime((image, insert)) {}
        case "index-fixture":
            let file = URL(fileURLWithPath: CommandLine.arguments[3])
            try autoreleasepool {
                let store = IndexStore()
                store.reserve(entries: passages + 1)
                let root = store.addRoot(path: "/synthetic", mtime: 0)
                appendFiles(0..<passages, to: root, in: store)
                store.aggregate()
                try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
            }
            print("index fixture saved; reader processes start with a fresh allocator")
        case "index-growth", "index-growth-baseline":
            let file = URL(fileURLWithPath: CommandLine.arguments[3])
            let before = footprint()
            let loadStart = ContinuousClock.now
            let store = try (mode.hasSuffix("baseline") ? IndexPersistenceBaseline.load(from: file).0 : IndexPersistence.load(from: file).0)
            let loadTime = loadStart.duration(to: .now)
            let loaded = footprint()
            let start = ContinuousClock.now
            let first = Int32(store.count)
            appendFiles(passages..<(passages + 8192), to: 0, in: store)
            store.integrateNew(from: first)
            let updateTime = start.duration(to: .now)
            let updated = footprint()
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            precondition(store.fileCount[0] == passages + 8192 && store.size[0] == Int64(passages + 8192))
            precondition(store.name(Int32(store.count - 1)) == "file-\(passages + 8191).txt")
            print("\(mode) files=\(passages) loaded_delta_bytes=\(Int64(loaded) - Int64(before)) updated_delta_bytes=\(Int64(updated) - Int64(before)) burst_delta_bytes=\(Int64(updated) - Int64(loaded)) peak_rss_bytes=\(usage.ru_maxrss) load_time=\(loadTime) update_time=\(updateTime)")
            withExtendedLifetime(store) {}
        default:
            fatalError("Unknown memory benchmark: \(mode)")
        }
    }

    private static func appendFiles(_ range: Range<Int>, to parent: Int32, in store: IndexStore) {
        for base in stride(from: range.lowerBound, to: range.upperBound, by: 4096) {
            var names: [UInt8] = [], items: [ScannedItem] = []
            for index in base..<min(base + 4096, range.upperBound) {
                let bytes = Array("file-\(index).txt".utf8)
                items.append(ScannedItem(nameOffset: names.count, nameLength: bytes.count, isDirectory: false, isPackage: false,
                                         isSymlink: false, isHidden: false, isMountPoint: false, size: 1, mtime: 100))
                names.append(contentsOf: bytes)
            }
            names.withUnsafeBytes { _ = store.appendChildren(items, nameBuffer: $0, of: parent,
                                                            ownNoise: [Bool](repeating: false, count: items.count)) }
        }
    }
}
