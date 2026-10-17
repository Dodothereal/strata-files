import Foundation

/// A disk of its own for a test (a small disk image, attached without showing in Finder and detached when the test is
/// done), for moves that cross disks: a copy and then the original removed, so the item is a new file where it lands.
/// Made and ejected on a thread of their own (`make`, `eject`): `hdiutil` takes seconds, and other tests' work waits on
/// the main thread and on Swift's shared threads.
nonisolated final class ScratchVolume: @unchecked Sendable {
    /// The disk's top folder.
    let root: URL
    private let folder: URL
    private var ejected = false

    static func make() async throws -> ScratchVolume {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async { done.resume(with: Result { try ScratchVolume() }) }
        }
    }

    func eject() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = try? Self.hdiutil(["detach", self.root.path, "-force", "-quiet"])
                try? FileManager.default.removeItem(at: self.folder)
                self.ejected = true
                done.resume()
            }
        }
    }

    private init() throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appending(path: "strata-volume-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appending(path: "disk")
        _ = try Self.hdiutil(["create", "-size", "16m", "-fs", "APFS", "-volname", "StrataTest", "-type", "SPARSE", image.path, "-quiet"])
        let plist = try Self.hdiutil(["attach", image.path + ".sparseimage", "-nobrowse", "-mountrandom", folder.path, "-plist"])
        let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        let entities = info?["system-entities"] as? [[String: Any]] ?? []
        guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first, let real = realpath(mount, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
    }

    /// A test that stopped early still leaves no disk attached.
    deinit {
        guard !ejected else { return }
        _ = try? Self.hdiutil(["detach", root.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: folder)
    }

    /// A path on the disk.
    func url(_ path: String) -> URL { root.appending(path: path) }

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
