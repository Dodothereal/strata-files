import Foundation
import Testing
@testable import Strata

struct HistoryDecodingSafetyTests {
    @Test(arguments: ["pairs", "replaced"], [0, 1, 3])
    func malformedHistoryPairsAreRejectedBeforeUndo(_ key: String, _ count: Int) throws {
        let tree = try TestTree("a", "b")
        let entry = OperationLog.Entry(name: "Move", kind: .move, pairs: [[tree.url("a").path, tree.url("b").path]])
        let encoded = try JSONEncoder().encode(entry)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = [Array(repeating: tree.url("a").path, count: count)]
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OperationLog.Entry.self, from: malformed) }
        #expect(tree.snapshot() == ["a", "b"])
    }

    @Test func validAndOlderHistoryRecordsKeepTheirPairs() throws {
        let tree = try TestTree("a", "b")
        let entry = OperationLog.Entry(name: "Move", kind: .move, pairs: [[tree.url("a").path, tree.url("b").path]])
        let encoded = try JSONEncoder().encode(entry)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["replaced", "containers", "identities", "changed", "undone"] { old[key] = nil }
        for data in [encoded, try JSONSerialization.data(withJSONObject: old)] {
            let decoded = try JSONDecoder().decode(OperationLog.Entry.self, from: data)
            #expect(decoded.pairs == entry.pairs)
            #expect(decoded.replaced.isEmpty)
            #expect(!decoded.undone)
        }
        #expect(tree.snapshot() == ["a", "b"])
    }
}
