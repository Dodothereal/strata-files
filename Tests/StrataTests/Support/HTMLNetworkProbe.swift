import Foundation

/// A loopback-only HTTP fixture. A forbidden request is observable without contacting any external service.
nonisolated final class HTMLNetworkProbe: @unchecked Sendable {
    let url: URL
    private let listener: Int32
    private let source: any DispatchSourceRead
    private let lock = NSLock()
    private var accepted = 0
    private var requests: [String] = []
    var requestLines: [String] { lock.withLock { requests } }
    var connections: Int { lock.withLock { accepted } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard found == 0 else { close(fd); throw POSIXError(.EIO) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/probe")!
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.answer() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    deinit { source.cancel() }

    private func answer() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            lock.withLock { accepted += 1 }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1, timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request = Data()
            while request.count < 16 << 10, !request.contains(Data("\r\n\r\n".utf8)) {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                request.append(contentsOf: buffer.prefix(count))
            }
            guard request.contains(Data("\r\n\r\n".utf8)) else { close(client); continue }
            lock.withLock { requests.append(String(decoding: request, as: UTF8.self)) }
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
            response.withUnsafeBytes { _ = send(client, $0.baseAddress, $0.count, 0) }
            close(client)
        }
    }
}
