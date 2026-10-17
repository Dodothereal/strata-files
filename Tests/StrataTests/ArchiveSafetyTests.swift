import Foundation
import Testing
@testable import Strata

/// Extract: an archive only ever adds its own items inside the folder it's extracted into. Links leading out of it,
/// entries named to climb out ("../"), special files and setuid bits never make it, and nothing there is replaced.
struct ArchiveSafetyTests {
    /// A tar of `folder`'s contents, entries renamed by bsdtar's `-s` substitutions (to craft hostile names).
    private func tar(_ tree: TestTree, _ folder: String, named name: String, rename: [String] = []) throws -> URL {
        let archive = tree.url(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", archive.path, "-C", tree.url(folder).path] + rename.flatMap { ["-s", $0] } + ["."]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return archive
    }

    private func extract(_ archive: URL, into folder: URL) async throws -> URL {
        let inspection = await Archiver.inspect(archive, kind: .tar)
        return try Archiver.extract(archive, kind: .tar, inspection: inspection, into: folder, control: Archiver.Control())
    }

    @Test func aLinkLeadingOutStopsTheWholeExtraction() async throws {
        for target in ["/etc", "../../outside", "./inner/../../../outside"] {
            let tree = try TestTree("outside/", "outside/precious.txt", "dest/", "payload/", "payload/ok.txt",
                                    "payload/inner/", "payload/inner/escape -> \(target)")
            let archive = try tar(tree, "payload", named: "evil.tar")
            await #expect(throws: (any Error).self, "\(target)") { _ = try await extract(archive, into: tree.url("dest")) }
            #expect(tree.snapshot().filter { $0.hasPrefix("dest/") || $0.hasPrefix("outside/") }
                == ["dest/", "outside/", "outside/precious.txt"], "\(target)")
        }
    }

    @Test func linksThatStayInsideAreKept() async throws {
        let tree = try TestTree("dest/", "payload/", "payload/a.txt", "payload/sub/", "payload/sub/to a -> ../a.txt")
        let archive = try tar(tree, "payload", named: "fine.tar")
        let placed = try await extract(archive, into: tree.url("dest"))
        #expect(placed.lastPathComponent == "fine")
        #expect(tree.snapshot().filter { $0.hasPrefix("dest/") }
            == ["dest/", "dest/fine/", "dest/fine/a.txt", "dest/fine/sub/", "dest/fine/sub/to a -> ../a.txt"])
    }

    @Test func entriesNamedToClimbOutNeverLandOutside() async throws {
        let tree = try TestTree("work/", "work/dest/", "payload/", "payload/escaped.txt", "payload/fine.txt")
        let archive = try tar(tree, "payload", named: "climb.tar", rename: [",^\\./escaped,../../escaped,"])
        _ = try? await extract(archive, into: tree.url("work/dest"))
        // However bsdtar takes the name, nothing appears outside the destination.
        #expect(tree.snapshot().filter { !$0.hasPrefix("work/dest/") || $0 == "work/dest/" }
            == ["climb.tar", "payload/", "payload/escaped.txt", "payload/fine.txt", "work/", "work/dest/"])
    }

    @Test func whatsAlreadyThereIsNeverReplaced() async throws {
        let tree = try TestTree("dest/", "dest/one.txt", "payload/", "payload/one.txt")
        let archive = try tar(tree, "payload", named: "one.tar")
        let placed = try await extract(archive, into: tree.url("dest"))
        #expect(placed.lastPathComponent == "one 2.txt")
        #expect(tree.text("dest/one.txt") == "dest/one.txt")
        #expect(tree.text("dest/one 2.txt") == "payload/one.txt")
    }

    @Test func browsingAnArchiveNeverReplacesAnExistingFolder() async throws {
        let tree = try TestTree("dest/", "dest/copy/", "dest/copy.txt", "dest/copy2/", "payload/", "payload/one.txt")
        let archive = try tar(tree, "payload", named: "one.tar")
        let before = tree.snapshot()
        let destination = tree.url("dest/copy")
        let identity = try #require(OperationLog.identity(destination.path))
        let inspection = await Archiver.inspect(archive, kind: .tar)
        // An empty folder matters too: plain rename would silently replace it with the extracted contents.
        #expect(throws: (any Error).self) {
            try Archiver.extractContents(archive, kind: .tar, inspection: inspection, to: destination,
                                         control: Archiver.Control())
        }
        #expect(OperationLog.identity(destination.path) == identity)
        #expect(tree.snapshot() == before)
    }

    @Test func specialFilesAndSetuidBitsAreDropped() throws {
        let tree = try TestTree("box/", "box/tool", "box/sub/")
        #expect(mkfifo(tree.url("box/sub/pipe").path, 0o644) == 0)
        #expect(chmod(tree.url("box/tool").path, 0o4755) == 0)
        try Archiver.check(tree.url("box"))
        #expect(tree.snapshot() == ["box/", "box/sub/", "box/tool"])
        var info = stat()
        #expect(lstat(tree.url("box/tool").path, &info) == 0 && info.st_mode & S_ISUID == 0)
    }
}
