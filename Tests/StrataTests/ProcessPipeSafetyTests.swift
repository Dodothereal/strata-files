import Foundation
import Testing
@testable import Strata

struct ProcessPipeSafetyTests {
    @Test func shortOutputIsCollectedWhileItsWriterStaysOpen() throws {
        let collector = PipeCollector()
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        try #require(flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        try pipe.fileHandleForWriting.write(contentsOf: Data("output".utf8))
        // A nonblocking pipe makes a reader that waits for a full buffer fail deterministically,
        // instead of leaving a test hung until the writer closes.
        collector.receive(descriptor)
        #expect(collector.data == Data("output".utf8))
        #expect(collector.readError == nil)
        try pipe.fileHandleForWriting.close()
    }

    @Test func invalidOutputDescriptorsReportFailureInsteadOfRaisingAnException() {
        let collector = PipeCollector()
        // A recently closed descriptor could be reused by another suite. -1 always means EBADF.
        collector.receive(-1)
        #expect(collector.readError != nil)
        #expect(collector.data.isEmpty)
    }

    @Test func normalOutputAndEOFRemainDistinctFromReadFailure() throws {
        let collector = PipeCollector()
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("output".utf8))
        try pipe.fileHandleForWriting.close()
        collector.receive(pipe.fileHandleForReading.fileDescriptor)
        collector.receive(pipe.fileHandleForReading.fileDescriptor)
        #expect(collector.data == Data("output".utf8))
        #expect(collector.readError == nil)
    }
}
