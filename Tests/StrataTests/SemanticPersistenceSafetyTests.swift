import Foundation
import Testing
@testable import Strata

struct SemanticPersistenceSafetyTests {
    @Test(arguments: ["counts", "partialTerm", "partialPage", "offset", "length", "partialVector", "nonfiniteVector"])
    func malformedPassagesAreSkippedBeforeSearch(_ damage: String) async throws {
        let tree = try TestTree("state/")
        var fixture = SemanticFixture.make(passages: 2, sentences: false, root: tree.root)
        switch damage {
        case "counts": fixture.files[0].chunks[0].counts = Data()
        case "partialTerm": fixture.files[0].chunks[0].terms.append(0)
        case "partialPage": fixture.files[0].chunks[0].pages = Data([0])
        case "offset": fixture.files[0].chunks[0].start = -1
        case "length": fixture.files[0].chunks[0].length = .max
        case "partialVector": fixture.files[0].chunks[0].word.removeLast()
        default:
            fixture.files[0].chunks[0].word.replaceSubrange(0..<2, with: [0, 0x7c])
        }
        try SemanticFixture.write(fixture, to: tree.url("state"))
        let before = try Data(contentsOf: tree.url("state/index.sealed"))
        var configuration = SemanticIndex.Configuration(roots: [])
        configuration.storeDirectory = tree.url("state")
        let index = SemanticIndex(configuration: configuration)
        _ = await index.search("")
        #expect(await index.indexedFileCount == 1)
        // The valid document must remain usable after the malformed document is skipped.
        #expect(await index.search("stratamemoryprobe", limit: 1).first?.url.lastPathComponent == "document-1.txt")
        #expect(try Data(contentsOf: tree.url("state/index.sealed")) == before)
        #expect(tree.snapshot() == ["state/", "state/index.sealed"])
    }
}
