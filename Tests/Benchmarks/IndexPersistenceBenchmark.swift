import Foundation
import Darwin

// Run scripts/benchmark-index.sh. DEBUG isolates SecureStorage from the app’s index and keychain.

func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    var before = rusage(), after = rusage()
    getrusage(RUSAGE_SELF, &before)
    let start = Date()
    let result = try autoreleasepool(invoking: body)
    getrusage(RUSAGE_SELF, &after)
    func cpu(_ value: rusage) -> Double {
        Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    print("\(label): wall=\(Date().timeIntervalSince(start))s CPU=\(cpu(after)-cpu(before))s")
    return result
}

@main struct Benchmark {
    static func main() throws {
        precondition(SecureStorage.isTestRun, "The benchmark must use DEBUG's throwaway storage and key.")
        let folder = FileManager.default.temporaryDirectory.appending(path: "strata-synthetic-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "index.sealed"), legacy = folder.appending(path: "old.sealed")
        let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 6_900_000
        precondition((1...10_000_000).contains(count), "Use between 1 and 10 million entries.")
        let store = measure("Build synthetic \(count)-file catalog") {
            let store = IndexStore()
            store.reserve(entries: count + 1)
            store.write {
                let root = store.addRoot(path: "/synthetic/files", mtime: 0)
                for base in stride(from: 0, to: count, by: 5000) {
                    var names: [UInt8] = [], items: [ScannedItem] = []
                    for i in base..<min(base + 5000, count) {
                        let name = Array("private-file-\(i).dat".utf8)
                        items.append(ScannedItem(nameOffset: names.count, nameLength: name.count, isDirectory: false,
                                                 isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false,
                                                 size: Int64(i + 1), mtime: 100, fileKey: UInt32(i + 1)))
                        names.append(contentsOf: name)
                    }
                    names.withUnsafeBytes {
                        _ = store.appendChildren(items, nameBuffer: $0, of: root, ownNoise: [Bool](repeating: false, count: items.count))
                    }
                }
                store.aggregate()
            }
            return store
        }
        let initial = try measure("New full checkpoint") {
            try IndexPersistence.save(store, eventID: 1, excluded: [], to: file)
        }
        try measure("New snapshot-only startup") {
            let (loaded, _) = try IndexPersistence.load(from: file)
            precondition(loaded.count == count + 1 && loaded.size[10] == store.size[10])
        }
        store.write { store.size[10] += 1; store.mtime[10] += 1; store.propagate(from: 10, bytes: 1, files: 0) }
        try measure("Old full-save algorithm after small edit") {
            try store.read { try IndexPersistence.saveSnapshot(store, eventID: 2, excluded: [], to: legacy, generation: nil) }
        }
        try measure("Old snapshot startup") {
            let (loaded, _) = try IndexPersistence.loadSnapshot(from: legacy)
            precondition(loaded.count == count + 1 && loaded.size[10] == store.size[10])
        }
        let delta = try measure("New incremental save after small edit") {
            try IndexPersistence.save(store, eventID: 2, excluded: [], to: file)
        }
        try measure("New snapshot-plus-changes startup") {
            let (loaded, header) = try IndexPersistence.load(from: file)
            precondition(loaded.count == count + 1 && loaded.size[10] == store.size[10] && header.eventID == 2)
        }
        print("Snapshot bytes=\(initial.bytesWritten); change bytes=\(delta.bytesWritten); write reduction=\(Double(initial.bytesWritten)/Double(delta.bytesWritten))x")
    }
}
