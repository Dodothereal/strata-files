import Foundation
import Testing
@testable import Strata

struct ArchivePreviewSafetyTests {
    private func listing(_ lines: [String]) throws -> ArchiveListing {
        try ArchiveLister.parse(ProcessRunner.Result(output: Data(lines.joined(separator: "\n").utf8), status: 0,
                                                     timedOut: false, truncated: false), kind: .tar)
    }

    private func row(_ name: String, size: Int64 = 1, date: String = "Oct 11 2026") -> String {
        "-rw-r--r--  0 user staff \(size) \(date) \(name)"
    }

    @Test func oversizedArchiveTotalsSaturateInsteadOfCrashing() throws {
        let result = try listing([row("folder/a", size: .max), row("folder/b", size: .max)])
        #expect(result.uncompressed == .max)
        #expect(result.root.value.size == .max)
        #expect(result.root.value.children.first?.size == .max)
        #expect(result.files == 2)
    }

    @Test func malformedDatesDoNotTrapIntegerConversions() throws {
        let result = try listing([row("old", date: "Oct 11 \(Int.min)"), row("future", date: "Oct 11 \(Int.max)"),
                                  row("hour", date: "Oct 11 \(Int.max):30"), row("normal")])
        for node in result.root.value.children {
            #expect((node.modified != nil) == (node.name == "normal"))
        }
    }

    @Test func negativeArchiveSizesDoNotReduceFolderTotals() throws {
        let result = try listing([row("bad", size: -10), row("normal", size: 12)])
        #expect(result.root.value.size == 12)
        #expect(result.uncompressed == 12)
        #expect(result.root.value.children.first?.size == 0)
    }

    @Test func excessivePathNestingIsSkippedAndReported() throws {
        let result = try listing([row(String(repeating: "deep/", count: 2000) + "file"), row("normal", size: 12)])
        #expect(result.note != nil)
        #expect(result.files == 1)
        #expect(result.root.value.children.map(\.name) == ["normal"])
        #expect(result.root.value.size == 12)
    }

    @Test func implicitArchiveFoldersHaveAnAggregateBudget() throws {
        let rows = (0..<1000).map { row("folder\($0)/" + String(repeating: "nested/", count: 126) + "file") }
        let result = try listing(rows)
        #expect(result.files + result.folders <= 100_000)
        #expect(result.note != nil)
        #expect(result.root.value.size == Int64(result.files))
    }

    @Test func ordinaryArchiveTreesKeepTheirContentsAndSizes() throws {
        let result = try listing([row("folder/b.txt", size: 20), row("folder/a.txt", size: 10), row("top", size: 5)])
        #expect(result.note == nil)
        #expect(result.files == 3 && result.folders == 1)
        #expect(result.root.value.children.map(\.name) == ["folder", "top"])
        #expect(result.root.value.children.first?.children.map(\.name) == ["a.txt", "b.txt"])
        #expect(result.root.value.size == 35)
    }
}
