import Foundation
import Testing
@testable import Strata

struct RemoteCopyOwnershipTests {
    private nonisolated final class Backend: RemoteBackend, @unchecked Sendable {
        let content: Data
        private let lock = NSLock()
        private var destinations: [URL] = []
        private var edits: [String] = []
        var downloads: [URL] { lock.withLock { destinations } }
        var changes: [String] { lock.withLock { edits } }
        init(_ text: String) { content = Data(text.utf8) }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] {
            [ListedEntry(name: "item.txt", kind: .file, size: Int64(content.count), mode: 0o600, modified: nil, linkTarget: "")]
        }
        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
            #expect(path == "/item.txt" && limit == content.count)
            lock.withLock { destinations.append(destination) }
            try content.write(to: destination)
        }
        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
            lock.withLock { edits.append("upload " + path) }
        }
        func makeFolder(_ path: String) async throws { lock.withLock { edits.append("mkdir " + path) } }
        func rename(_ path: String, to newPath: String) async throws { lock.withLock { edits.append("rename " + path + " " + newPath) } }
        func remove(_ path: String) async throws { lock.withLock { edits.append("remove " + path) } }
        func kind(of path: String) async throws -> RemoteItemKind? { .file }
        var isAlive: Bool { true }
        func close() {}
    }

    @Test func matchingServerIDsKeepListingsDownloadsAndCleanupInTheirOwnEnvironment() async throws {
        let tree = try TestTree("first/keep.txt", "second/keep.txt", "outside.txt")
        let id = UUID().uuidString
        let a = RemoteServer(id: id, kind: .sftp, name: "First", host: "first.invalid")
        let b = RemoteServer(id: id, kind: .sftp, name: "Second", host: "second.invalid")
        let first = RemoteCopyStore(root: tree.url("first"), server: { $0 == id ? a : nil })
        let second = RemoteCopyStore(root: tree.url("second"), server: { $0 == id ? b : nil })
        let ab = Backend("first bytes"), bb = Backend("second bytes")
        let ap = RemoteSessions(server: { $0 == id ? a : nil }, connect: { _ in ab }, changed: { _, _ in })
        let bp = RemoteSessions(server: { $0 == id ? b : nil }, connect: { _ in bb }, changed: { _, _ in })
        let af = RemoteFiles(sessions: ap, copies: first), bf = RemoteFiles(sessions: bp, copies: second)
        let ar = CopyProviders(servers: af, containers: ContainerFiles()), br = CopyProviders(servers: bf, containers: ContainerFiles())
        let at = first.top(of: id), bt = second.top(of: id)
        let au = at.appending(path: "item.txt"), bu = bt.appending(path: "item.txt")
        await ar.refresh(at)
        await br.refresh(bt)
        try #require(ar.isPlaceholder(au) && br.isPlaceholder(bu))
        #expect(ar.sourceName(au) == "First" && br.sourceName(bu) == "Second")
        #expect(ar.displayPath(au) == "first.invalid:/item.txt" && br.displayPath(bu) == "second.invalid:/item.txt")
        #expect(!ar.contains(bu) && !br.contains(au))
        try await ar.fetch([bu])
        #expect(ab.downloads.isEmpty && bb.downloads.isEmpty)
        try await ar.fetch([au]); try await br.fetch([bu])
        #expect(try Data(contentsOf: au) == ab.content)
        #expect(try Data(contentsOf: bu) == bb.content)
        #expect(ab.downloads.count == 1 && ab.downloads.allSatisfy { $0.deletingLastPathComponent().path == first.root.appending(path: ".fetching").path })
        #expect(bb.downloads.count == 1 && bb.downloads.allSatisfy { $0.deletingLastPathComponent().path == second.root.appending(path: ".fetching").path })
        let before = tree.snapshot()
        await #expect(throws: RemoteError.unknownServer) { try await af.delete([bu]) }
        #expect(ab.changes.isEmpty && bb.changes.isEmpty && tree.snapshot() == before)
        try await af.delete([au])
        #expect(ab.changes == ["remove /item.txt"] && bb.changes.isEmpty)
        await af.discard(id)
        #expect(!FileManager.default.fileExists(atPath: at.path))
        #expect(try Data(contentsOf: bu) == bb.content)
        await bf.discard(id)
        await ap.disconnect(id); await bp.disconnect(id)
        #expect(tree.snapshot() == ["first/", "first/.fetching/", "first/keep.txt", "outside.txt", "second/", "second/.fetching/", "second/keep.txt"])
    }

    @Test func batchWritesValidateEverySourceOwnerBeforeChangingAnything() async throws {
        let id = UUID().uuidString, otherID = UUID().uuidString
        let tree = try TestTree("cache/\(id)/chosen.txt", "cache/\(id)/destination/", "cache/\(otherID)/other.txt", "foreign/item.txt")
        let server = RemoteServer(id: id, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let other = RemoteServer(id: otherID, kind: .sftp, name: "Other", host: "other.invalid")
        let definitions = [id: server, otherID: other]
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { definitions[$0] })
        let selected = copies.top(of: id).appending(path: "chosen.txt")
        let destination = copies.top(of: id).appending(path: "destination")
        let before = tree.snapshot()
        for move in [false, true] {
            let invalid = [tree.url("foreign/item.txt")] + (move ? [copies.top(of: otherID).appending(path: "other.txt")] : [])
            for foreign in invalid {
                let backend = Backend("unchanged"), connections = Counter()
                let files = RemoteFiles(copies: copies, backends: { _ in connections.add(1); return backend })
                if move {
                    await #expect(throws: (any Error).self) { _ = try await files.move([selected, foreign], into: destination) }
                } else {
                    await #expect(throws: RemoteError.unknownServer) { try await files.delete([selected, foreign]) }
                }
                #expect(backend.changes.isEmpty && connections.value == 0)
                #expect(tree.snapshot() == before)
            }
        }
        #expect(tree.snapshot() == before)
    }

    @Test func copyLookupRespectsPathBoundariesAndRejectsMismatchedRegistryEntries() throws {
        let tree = try TestTree("cache/", "cache-other/", "outside.txt")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { $0 == server.id ? server : nil })
        let top = copies.top(of: server.id)
        #expect(copies.contains(top) && copies.contains(copies.root))
        #expect(copies.server(containing: top)?.server == server)
        #expect(copies.server(containing: top.appending(path: "sub/item"))?.top == top)
        #expect(!copies.contains(tree.url("cache-other/")))
        #expect(copies.server(containing: tree.url("cache-other/" + server.id)) == nil)
        #expect(copies.server(containing: copies.root) == nil)
        #expect(copies.server(containing: copies.root.appending(path: ".fetching/file")) == nil)
        #expect(copies.server(containing: copies.root.appending(path: UUID().uuidString)) == nil)
        let wrong = RemoteCopyStore(root: copies.root, server: { _ in server })
        #expect(wrong.server(containing: copies.root.appending(path: UUID().uuidString)) == nil)
        #expect(tree.snapshot() == ["cache-other/", "cache/", "outside.txt"])
    }

    @Test func preparingCopiesRefusesInvalidIDsAndReplacementLinks() throws {
        let tree = try TestTree("cache/", "outside/keep.txt")
        let id = UUID().uuidString
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { _ in nil })
        let before = tree.snapshot()
        for id in ["", ".", "..", "../outside", "not-a-uuid", "nested/child"] {
            let invalid = RemoteServer(id: id, kind: .sftp, name: "Fixture", host: "fixture.invalid")
            #expect(throws: RemoteError.unknownServer) { try copies.prepare(invalid) }
            #expect(tree.snapshot() == before)
        }
        let server = RemoteServer(id: id, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let folder = try copies.prepare(server)
        #expect(try copies.prepare(server) == folder)
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: tree.url("outside"))
        let withLink = tree.snapshot()
        #expect(throws: (any Error).self) { try copies.prepare(server) }
        #expect(tree.snapshot() == withLink)
        let redirected = RemoteCopyStore(root: tree.url("redirected"), server: { _ in nil })
        try FileManager.default.createSymbolicLink(at: redirected.root, withDestinationURL: tree.url("outside"))
        let redirectedBefore = tree.snapshot()
        #expect(throws: (any Error).self) { try redirected.prepare(server) }
        #expect(tree.text("outside/keep.txt") == "outside/keep.txt")
        #expect(tree.snapshot() == redirectedBefore)
    }

    @Test func removingCopiesNeverFollowsAReplacedRootOrAChildLink() throws {
        let chosen = UUID().uuidString, other = UUID().uuidString
        let tree = try TestTree("cache/\(chosen)/nested/file", "cache/\(chosen)/link -> ../../outside", "cache/\(other)/keep",
                                "outside/\(chosen)/keep", "outside/keep", "cache-old/keep", "cache/invalid/keep")
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { _ in nil })
        let before = tree.snapshot()
        for id in ["", ".", "..", "../outside", "invalid"] { copies.remove(id) }
        #expect(tree.snapshot() == before)
        copies.remove(chosen)
        #expect(tree.snapshot() == before.filter { !$0.hasPrefix("cache/" + chosen + "/") })
        let parked = tree.url("parked")
        try FileManager.default.moveItem(at: copies.root, to: parked)
        try FileManager.default.createSymbolicLink(at: copies.root, withDestinationURL: tree.url("outside"))
        let redirected = tree.snapshot()
        copies.remove(chosen)
        #expect(tree.snapshot() == redirected)
        try FileManager.default.removeItem(at: copies.root)
        try FileManager.default.moveItem(at: parked, to: copies.root)
        let linked = copies.top(of: chosen)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: tree.url("outside"))
        let final = tree.snapshot()
        copies.remove(chosen)
        #expect(tree.snapshot() == final.filter { !$0.hasPrefix("cache/" + chosen + " ->") })
        #expect(tree.text("outside/" + chosen + "/keep") == "outside/" + chosen + "/keep")
        #expect(tree.text("outside/keep") == "outside/keep")
        #expect(FileManager.default.fileExists(atPath: copies.top(of: other).appending(path: "keep").path))
    }

    @Test func descriptorCleanupStaysWithTheOpenedFolderAndRejectsEscapingNames() throws {
        let tree = try TestTree("cache/chosen/file", "outside/chosen/keep", "outside/keep")
        let parent = open(tree.url("cache").path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(parent >= 0)
        defer { close(parent) }
        let before = tree.snapshot()
        for name in ["", ".", "..", "../outside", "chosen/file", "nul\0name"] { Archiver.removeTree(name, in: parent) }
        #expect(tree.snapshot() == before)
        try FileManager.default.moveItem(at: tree.url("cache"), to: tree.url("parked"))
        try FileManager.default.createSymbolicLink(at: tree.url("cache"), withDestinationURL: tree.url("outside"))
        let redirected = tree.snapshot()
        Archiver.removeTree("chosen", in: parent)
        #expect(tree.snapshot() == redirected.filter { !$0.hasPrefix("parked/chosen/") })
        #expect(tree.text("outside/chosen/keep") == "outside/chosen/keep")
        #expect(tree.snapshot().contains("parked/"))
    }
}
