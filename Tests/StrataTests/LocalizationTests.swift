import Foundation
import Testing

struct LocalizationTests {
    @Test func everySupportedLanguageHasCompleteTranslations() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let result: (status: Int32, output: String) = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["python3", root.appending(path: "scripts/localize.py").path,
                                         "check", "--all", "--complete"]
                    process.currentDirectoryURL = root
                    process.standardInput = FileHandle.nullDevice
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    done.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
        #expect(result.status == 0, Comment(rawValue: result.output))
    }
}
