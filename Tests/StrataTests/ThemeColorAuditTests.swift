import Foundation
import Testing

struct ThemeColorAuditTests {
    @Test func directSurfaceColorsHaveAReviewedReason() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let result: (Int32, String) = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["python3", root.appending(path: "scripts/audit-theme-colors.py").path]
                    process.currentDirectoryURL = root
                    process.standardInput = FileHandle.nullDevice
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    done.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch { done.resume(throwing: error) }
            }
        }
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
