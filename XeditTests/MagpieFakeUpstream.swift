import Foundation
import Darwin

/// Deterministic loopback HTTP fixture; no account, environment, or paid API.
nonisolated final class MagpieFakeUpstream: @unchecked Sendable {
    private let descriptor: Int32
    private let captured: Capture
    private let task: Task<Void, Never>
    let baseURL: String

    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var values: [Data] = []
        func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; values.append(data) }
        func snapshot() -> [Data] { lock.lock(); defer { lock.unlock() }; return values }
    }
    var requests: [Data] { captured.snapshot() }

    init(responses: [String]) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else { close(listener); throw POSIXError(.EIO) }
        descriptor = listener
        baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/v1"
        let capture = Capture()
        captured = capture
        task = Task.detached(priority: .utility) {
            for response in responses {
                guard !Task.isCancelled else { return }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSignal: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while request.count < 1_048_576 {
                    let received = Darwin.read(client, &buffer, buffer.count)
                    if received <= 0 { break }
                    request.append(contentsOf: buffer.prefix(received))
                    if let boundary = request.range(of: Data("\r\n\r\n".utf8)) {
                        let header = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
                        let contentLength = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                        if request.count >= boundary.upperBound + contentLength { break }
                    }
                }
                capture.append(request)
                let bytes = Data(response.utf8)
                var sent = 0
                while sent < bytes.count {
                    let count = bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress!.advanced(by: sent), $0.count - sent) }
                    if count <= 0 { break }
                    sent += count
                }
                close(client)
            }
        }
    }

    func stop() {
        task.cancel()
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    static func response(_ body: String, contentType: String = "application/json") -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}
