import Foundation
import Testing
@testable import Strata

struct ProcessPipeSafetyTests {
    @Test func closedOutputPipesReportFailureInsteadOfRaisingAnException() throws {
        let collector = PipeCollector()
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        collector.receive(pipe.fileHandleForReading)
        #expect(collector.readError != nil)
        #expect(collector.data.isEmpty)
    }

    @Test func normalOutputAndEOFRemainDistinctFromReadFailure() throws {
        let collector = PipeCollector()
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("output".utf8))
        try pipe.fileHandleForWriting.close()
        collector.receive(pipe.fileHandleForReading)
        collector.receive(pipe.fileHandleForReading)
        #expect(collector.data == Data("output".utf8))
        #expect(collector.readError == nil)
    }
}
