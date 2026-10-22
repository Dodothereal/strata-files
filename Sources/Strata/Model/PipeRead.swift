import Foundation

/// One bounded pipe read. Foundation's read(upToCount:) can wait for the full count or EOF,
/// delaying short output from a process that keeps its pipe open.
nonisolated package enum PipeRead {
    package static func availableData(from descriptor: Int32) throws -> Data {
        var data = Data(count: 64 * 1024)
        while true {
            let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count >= 0 {
                data.count = count
                return data
            }
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
