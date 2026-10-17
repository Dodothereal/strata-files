import Foundation
import Testing
@testable import Strata

/// Writing a container's folder into its copy on this Mac, from the tar stream the engine sends, which the container
/// decides. Nothing it holds may reach outside the copy: no `..`, nothing written through a link, no hard link to a file
/// elsewhere; and what the container no longer has is removed from the copy alone, never through a link.
extension ContainerTests {
    private static let id = String(repeating: "ab", count: 32)

    private static func archive(_ stream: [UInt8]) throws -> ContainerEngine {
        let body = stream + [UInt8](repeating: 0, count: 1024)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: \(body.count)\r\n\r\n"
        let server = try serve(Array(head.utf8) + body)
        return ContainerEngine(socket: server.path, name: "Docker", apiVersion: "1.41")
    }

    @Test func aContainersFolderIsWrittenOnlyIntoItsCopy() throws {
        // `root` is the container's copy (its `/`); `data` the folder being written; `outside` is beside the copy.
        let tree = try TestTree("outside/", "outside/secret.txt", "outside/keep/", "outside/keep/inner.txt",
                                "root/", "root/data/", "root/data/ok.txt", "root/data/stale.txt", "root/data/old link -> ../../outside")
        var stream = Self.tarHeader("data/", type: UInt8(ascii: "5"), mode: 0o755)
        stream += Self.tarFile("data/ok.txt", "fresh")
        // Out of the folder, or only named like it.
        stream += Self.tarFile("data/../escape.txt", "x")
        stream += Self.tarFile("data/sub/../../escape.txt", "x")
        stream += Self.tarFile("/etc/absolute.txt", "x")
        stream += Self.tarFile("data2/sibling.txt", "x")
        // A link leading out is kept inside the copy; a file "in" it goes into a real folder that takes its place.
        stream += Self.tarHeader("data/up", type: UInt8(ascii: "2"), link: "../../../../outside")
        stream += Self.tarFile("data/up/through.txt", "x")
        stream += Self.tarHeader("data/door", type: UInt8(ascii: "2"), link: "/")
        // Hard links: only to what's in the stream's own folder.
        stream += Self.tarHeader("data/hard", type: UInt8(ascii: "1"), link: "data/ok.txt")
        stream += Self.tarHeader("data/hard out", type: UInt8(ascii: "1"), link: "data/../../outside/secret.txt")
        stream += Self.tarHeader("data/hard etc", type: UInt8(ascii: "1"), link: "etc/passwd")
        try CopyWriter.writeTree(try Self.archive(stream), id: Self.id, containerPath: "/data", into: tree.url("root/data"),
                                 stop: StopFlag())
        let copy = tree.snapshot().filter { $0.hasPrefix("root/") }
        #expect(copy == ["root/", "root/data/", "root/data/door -> ..", "root/data/hard", "root/data/ok.txt",
                         "root/data/up/", "root/data/up/through.txt"])
        #expect(tree.text("root/data/ok.txt") == "fresh" && tree.text("root/data/hard") == "fresh")
        // Beside the copy, nothing changed.
        #expect(tree.snapshot().filter { !$0.hasPrefix("root/") } == ["outside/", "outside/keep/", "outside/keep/inner.txt", "outside/secret.txt"])
        #expect(tree.text("outside/secret.txt") == "outside/secret.txt")
    }

    @Test func aCopyThatIsALinkIsNotWrittenThrough() throws {
        let tree = try TestTree("outside/", "outside/secret.txt", "root/", "root/data -> ../outside")
        var stream = Self.tarHeader("data/", type: UInt8(ascii: "5"), mode: 0o755)
        stream += Self.tarFile("data/new.txt", "x")
        #expect(throws: (any Error).self) {
            try CopyWriter.writeTree(try Self.archive(stream), id: Self.id, containerPath: "/data", into: tree.url("root/data"),
                                     stop: StopFlag())
        }
        #expect(tree.snapshot() == ["outside/", "outside/secret.txt", "root/", "root/data -> ../outside"])
    }

    // MARK: - One file

    /// A file not fetched yet, as a listing leaves it: a regular file without permissions.
    private func placeholder(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0])
    }

    @Test func aFetchedFileTakesOnlyItsPlaceholdersPlace() throws {
        let tree = try TestTree("copy/", "copy/other.txt", "outside/", "outside/secret.txt")
        placeholder(tree.url("copy/hosts"))
        // Only the stream's first entry counts; nothing else in it is written anywhere.
        let stream = Self.tarFile("hosts", "127.0.0.1 localhost\n") + Self.tarFile("../escape.txt", "x") + Self.tarFile("other.txt", "x")
        try CopyWriter.fetchFile(try Self.archive(stream), id: Self.id, containerPath: "/etc/hosts", to: tree.url("copy/hosts"), stop: StopFlag())
        #expect(tree.text("copy/hosts") == "127.0.0.1 localhost\n" && tree.text("copy/other.txt") == "copy/other.txt")
        #expect(tree.snapshot() == ["copy/", "copy/hosts", "copy/other.txt", "outside/", "outside/secret.txt"])
    }

    @Test func aFetchThatIsntAFileOrFindsSomethingElseChangesNothing() throws {
        let tree = try TestTree("copy/", "copy/now a folder/", "copy/now a folder/inside.txt", "copy/now a link -> ../outside/secret.txt",
                                "outside/", "outside/secret.txt")
        placeholder(tree.url("copy/hosts"))
        // The container sends a link (or a folder) where a file was listed: nothing is written.
        let link = Self.tarHeader("hosts", type: UInt8(ascii: "2"), link: "/etc/passwd")
        #expect(throws: (any Error).self) {
            try CopyWriter.fetchFile(try Self.archive(link), id: Self.id, containerPath: "/etc/hosts", to: tree.url("copy/hosts"), stop: StopFlag())
        }
        // Listed again meanwhile, the placeholder is a folder now: the fetched file doesn't replace it.
        for name in ["now a folder", "now a link"] {
            try CopyWriter.fetchFile(try Self.archive(Self.tarFile(name, "x")), id: Self.id, containerPath: "/x",
                                     to: tree.url("copy/" + name), stop: StopFlag())
        }
        #expect(tree.snapshot() == ["copy/", "copy/hosts", "copy/now a folder/", "copy/now a folder/inside.txt",
                                    "copy/now a link -> ../outside/secret.txt", "outside/", "outside/secret.txt"])
        #expect(tree.text("outside/secret.txt") == "outside/secret.txt")
        #expect(TestTree.listing(of: tree.url("copy")).allSatisfy { !$0.hasPrefix(".strata-") })
    }

    // MARK: - Dragged out

    @Test func aDraggedOutItemNeverReplacesWhatsAtTheDrop() async throws {
        let tree = try TestTree("from/", "from/item/", "from/item/a.txt", "from/item/out -> /etc", "to/", "to/item/", "to/item/mine.txt")
        let item = ContainerDragItem(source: tree.url("from/item"))
        // The provider blocks until it's written, as on the drag's own queue: on a thread of its own here too.
        func write(to url: URL) async -> Error? {
            await withCheckedContinuation { done in
                DispatchQueue.global().async {
                    ContainerPromises.shared.filePromiseProvider(item, writePromiseTo: url) { done.resume(returning: $0) }
                }
            }
        }
        // Where the receiving app asked for it, something is already there: it stays as it was.
        #expect(await write(to: tree.url("to/item")) != nil)
        #expect(await write(to: tree.url("to/fresh")) == nil)
        // Written fresh, a link that would lead out of what was copied is dropped.
        #expect(tree.snapshot() == ["from/", "from/item/", "from/item/a.txt", "from/item/out -> /etc", "to/", "to/fresh/", "to/fresh/a.txt",
                                    "to/item/", "to/item/mine.txt"])
    }
}
