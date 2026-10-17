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
}
