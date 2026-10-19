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

@main struct MemoryBenchmark {
    static func main() async throws {
        precondition(SecureStorage.isTestRun, "Benchmarks must use DEBUG's throwaway storage and key.")
        let mode = CommandLine.arguments.dropFirst().first ?? "semantic"
        let passages = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 50_000
        precondition((1...200_000).contains(passages))
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
        default:
            fatalError("Unknown memory benchmark: \(mode)")
        }
    }
}
