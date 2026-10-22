import Foundation
import Synchronization

/// A disk of its own for a test (a small disk image, attached without showing in Finder and detached when the test
/// process exits), for moves that cross disks: a copy and then the original removed, so the item is a new file where it
/// lands. Attached once on a serial queue and handed out as isolated folders (`make`, `eject`): `hdiutil` takes
/// seconds, and other tests' work waits on the main thread and on Swift's shared threads.
nonisolated final class ScratchVolume: @unchecked Sendable {
    private struct SharedDisk {
        let folder: URL
        let mount: URL
    }

    private static let queue = DispatchQueue(label: "strata.tests.scratch-volume")
    private static let shared = Mutex<SharedDisk?>(nil)
    private static let registeredCleanup: Void = {
        atexit(detachSharedScratchVolume)
    }()

    /// The disk's top folder for this test.
    let root: URL
    private let state = Mutex(false)

    static func make() async throws -> ScratchVolume {
        try await withCheckedThrowingContinuation { done in
            queue.async { done.resume(with: Result { try ScratchVolume() }) }
        }
    }

    func eject() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.queue.async {
                self.cleanup()
                done.resume()
            }
        }
    }

    private init() throws {
        _ = Self.registeredCleanup
        let disk = try Self.ensureSharedDisk()
        root = disk.mount.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A test that stopped early still leaves its folder cleaned up.
    deinit {
        cleanup()
    }

    private func cleanup() {
        let shouldRemove = state.withLock { ejected in
            guard !ejected else { return false }
            ejected = true
            return true
        }
        guard shouldRemove else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// A path on the disk.
    func url(_ path: String) -> URL { root.appending(path: path) }

    private static func ensureSharedDisk() throws -> SharedDisk {
        if let existing = shared.withLock({ $0 }), FileManager.default.fileExists(atPath: existing.mount.path) {
            return existing
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "strata-volume-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let image = folder.appending(path: "disk")
            _ = try hdiutil(["create", "-size", "64m", "-fs", "APFS", "-volname", "StrataTest", "-type", "SPARSE", image.path, "-quiet"])
            let plist = try hdiutil(["attach", image.path + ".sparseimage", "-nobrowse", "-mountrandom", folder.path, "-plist"])
            let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            let entities = info?["system-entities"] as? [[String: Any]] ?? []
            guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first, let real = realpath(mount, nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            defer { free(real) }
            let disk = SharedDisk(folder: folder, mount: URL(fileURLWithPath: String(cString: real), isDirectory: true))
            shared.withLock { $0 = disk }
            return disk
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    fileprivate static func detachShared() {
        guard let disk = shared.withLock({
            let current = $0
            $0 = nil
            return current
        }) else { return }
        _ = try? hdiutil(["detach", disk.mount.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: disk.folder)
    }

    @discardableResult
    private static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

private nonisolated func detachSharedScratchVolume() {
    ScratchVolume.detachShared()
}
