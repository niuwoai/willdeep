//
//  WillDeepRuntimeTransport.swift
//  WillDeep
//
//  Discovery and transport for the willdeep-rs Runtime control API.
//
//  Phase 1 of the four-phase plan in willdeep-rs
//  `docs/CLI_TUI_RUNTIME_ROADMAP.md` §1.0: read-only observation of a running
//  Runtime. Decoding landed first (`WillDeepRuntimeProtocol.swift`); this file
//  adds the wire underneath it.
//
//  ## Why a hand-rolled HTTP client
//
//  The Runtime's preferred local transport is a `0600` Unix socket in its own
//  directory (rs `docs/RUNTIME_CONTROL_API.md` §2: "Unix 客户端优先连接
//  Runtime 目录内权限为 0600 的 Socket"), and `URLSession` cannot dial one.
//  Loopback TCP still works and is kept as a fallback, but preferring it would
//  mean this app is the one client that ignores the transport preference the
//  protocol states — and the socket's file permissions are a real access
//  boundary, not a stylistic one.
//
//  The request/response shapes are tiny and fixed (one POST, one JSON body,
//  `Content-Length` responses), so the HTTP written here is deliberately the
//  minimum that satisfies HTTP/1.1 rather than a general client. Anything the
//  Runtime would not send — chunked encoding, keep-alive reuse, redirects — is
//  unsupported on purpose and fails loudly instead of half-working.
//

import Foundation

// MARK: - Discovery

/// `~/.willdeep/runtime/daemon.json`, written by the Rust daemon at startup.
/// The file is `0600`; it carries the loopback address and the per-run token,
/// so possession of the file is the access boundary on both transports.
nonisolated struct WillDeepRuntimeDaemonState: Decodable {
    let version: String
    let pid: Int
    let address: String?
    let token: String
    let localTransport: LocalTransport?

    nonisolated struct LocalTransport: Decodable {
        let kind: String
        let path: String
    }

    enum CodingKeys: String, CodingKey {
        case version, pid, address, token
        case localTransport = "local_transport"
    }
}

nonisolated enum WillDeepRuntimeEndpoint: Equatable {
    case unixSocket(path: String)
    case loopback(host: String, port: Int)
}

nonisolated struct WillDeepRuntimeConnection: Equatable {
    let endpoint: WillDeepRuntimeEndpoint
    let token: String
    let serverVersion: String
    let pid: Int
}

nonisolated enum WillDeepRuntimeDiscovery {
    static func defaultStateURL() -> URL {
        runtimeDirectory().appendingPathComponent("daemon.json")
    }

    static func runtimeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["WILLDEEP_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("runtime", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
    }

    /// Resolve where to talk to the Runtime, or nil when no daemon has ever
    /// run here. A stale file (daemon exited without cleaning up) still
    /// resolves; the caller finds out when the connection is refused, which is
    /// the same way the Rust client finds out.
    static func connection(from url: URL = defaultStateURL()) -> WillDeepRuntimeConnection? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(WillDeepRuntimeDaemonState.self, from: data),
              !state.token.isEmpty else {
            return nil
        }
        guard let endpoint = endpoint(for: state) else { return nil }
        return WillDeepRuntimeConnection(
            endpoint: endpoint,
            token: state.token,
            serverVersion: state.version,
            pid: state.pid
        )
    }

    /// Socket first, loopback second. A daemon that publishes both means "use
    /// the socket"; loopback exists for older state files and for diagnosing
    /// the socket itself.
    static func endpoint(for state: WillDeepRuntimeDaemonState) -> WillDeepRuntimeEndpoint? {
        if let transport = state.localTransport,
           transport.kind == "unix_socket",
           !transport.path.isEmpty,
           FileManager.default.fileExists(atPath: transport.path) {
            return .unixSocket(path: transport.path)
        }
        guard let address = state.address,
              let separator = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: separator)...]),
              port > 0 else {
            return nil
        }
        let host = String(address[address.startIndex..<separator])
        // The daemon binds loopback only. Refusing anything else here means a
        // tampered state file cannot redirect this app's token to another host.
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return nil
        }
        return .loopback(host: host, port: port)
    }
}

// MARK: - Errors

nonisolated enum WillDeepRuntimeTransportError: Error, CustomStringConvertible, Equatable {
    case noRuntime
    case connectionFailed(String)
    case malformedResponse(String)
    case httpStatus(Int)
    case api(code: String, message: String)

    var description: String {
        switch self {
        case .noRuntime:
            return "No willdeep-rs Runtime is registered on this machine."
        case let .connectionFailed(detail):
            return "Could not reach the Runtime: \(detail)"
        case let .malformedResponse(detail):
            return "Runtime returned a response this client cannot read: \(detail)"
        case let .httpStatus(code):
            return "Runtime returned HTTP \(code)."
        case let .api(code, message):
            return "Runtime refused the request (\(code)): \(message)"
        }
    }
}

// MARK: - Transport

nonisolated enum WillDeepRuntimeTransport {
    static let protocolVersion = "1.0"
    static let tokenHeader = "X-WillDeep-Token"
    static let requestIDHeader = "X-WillDeep-Request-Id"
    static let apiPath = "/v1/api"

    /// Body of `POST /v1/api`, mirroring the Rust `ApiRequest`. `request_id`
    /// is what the Runtime deduplicates mutating calls on; read-only calls
    /// send one anyway so the server can correlate its logs with ours.
    static func requestBody(
        operation: String,
        params: [String: Any],
        requestID: UUID
    ) throws -> Data {
        let payload: [String: Any] = [
            "protocol_version": protocolVersion,
            "request_id": requestID.uuidString.lowercased(),
            "operation": operation,
            "params": params,
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func send(
        operation: String,
        params: [String: Any] = [:],
        connection: WillDeepRuntimeConnection,
        timeout: TimeInterval = 10
    ) throws -> Data {
        let body = try requestBody(
            operation: operation, params: params, requestID: UUID()
        )
        switch connection.endpoint {
        case let .unixSocket(path):
            return try sendOverUnixSocket(
                path: path, token: connection.token, body: body, timeout: timeout
            )
        case let .loopback(host, port):
            return try sendOverLoopback(
                host: host, port: port, token: connection.token, body: body, timeout: timeout
            )
        }
    }

    // MARK: Unix socket

    private static func sendOverUnixSocket(
        path: String,
        token: String,
        body: Data,
        timeout: TimeInterval
    ) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw WillDeepRuntimeTransportError.connectionFailed("socket() failed")
        }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        // `sun_path` is a fixed 104-byte buffer; an over-long path would be
        // silently truncated into a connection to the wrong socket.
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw WillDeepRuntimeTransportError.connectionFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw WillDeepRuntimeTransportError.connectionFailed(
                "connect(\(path)) failed: \(String(cString: strerror(errno)))"
            )
        }
        applyTimeout(timeout, to: descriptor)

        var request = Data()
        request.append(Data("POST \(apiPath) HTTP/1.1\r\n".utf8))
        request.append(Data("Host: localhost\r\n".utf8))
        request.append(Data("\(tokenHeader): \(token)\r\n".utf8))
        request.append(Data("Content-Type: application/json\r\n".utf8))
        request.append(Data("Content-Length: \(body.count)\r\n".utf8))
        // One request per connection: no keep-alive bookkeeping to get wrong,
        // and the server closing the socket is a second, independent signal
        // that the body is complete.
        request.append(Data("Connection: close\r\n\r\n".utf8))
        request.append(body)

        try writeAll(request, to: descriptor)
        let response = try readAll(from: descriptor)
        return try httpBody(from: response)
    }

    private static func applyTimeout(_ timeout: TimeInterval, to descriptor: Int32) {
        var value = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let written = write(descriptor, base.advanced(by: sent), buffer.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                throw WillDeepRuntimeTransportError.connectionFailed(
                    "write failed: \(String(cString: strerror(errno)))"
                )
            }
        }
    }

    /// Read until EOF. Safe because the request asks for `Connection: close`,
    /// so the server closes once the body is out.
    private static func readAll(from descriptor: Int32) throws -> Data {
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                response.append(contentsOf: chunk[0..<count])
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw WillDeepRuntimeTransportError.connectionFailed(
                "read failed: \(String(cString: strerror(errno)))"
            )
        }
        return response
    }

    /// Split an HTTP/1.1 response into status line, headers and body. Only the
    /// shapes the Runtime actually produces are handled; anything else is an
    /// explicit error rather than a lenient guess.
    static func httpBody(from response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else {
            throw WillDeepRuntimeTransportError.malformedResponse("no header terminator")
        }
        let headerData = response[response.startIndex..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8),
              let statusLine = headerText.split(separator: "\r\n").first else {
            throw WillDeepRuntimeTransportError.malformedResponse("unreadable headers")
        }
        let statusFields = statusLine.split(separator: " ")
        guard statusFields.count >= 2, let status = Int(statusFields[1]) else {
            throw WillDeepRuntimeTransportError.malformedResponse("unreadable status line")
        }
        let body = response[range.upperBound...]
        // A non-2xx still carries the error envelope, and the envelope's
        // message is far more useful than the bare status. Surface the status
        // only when there is no body to explain it.
        guard (200..<300).contains(status) || !body.isEmpty else {
            throw WillDeepRuntimeTransportError.httpStatus(status)
        }
        if headerText.lowercased().contains("transfer-encoding: chunked") {
            throw WillDeepRuntimeTransportError.malformedResponse(
                "chunked responses are not supported on this path"
            )
        }
        return Data(body)
    }

    // MARK: Loopback fallback

    private static func sendOverLoopback(
        host: String,
        port: Int,
        token: String,
        body: Data,
        timeout: TimeInterval
    ) throws -> Data {
        guard let url = URL(string: "http://\(host):\(port)\(apiPath)") else {
            throw WillDeepRuntimeTransportError.connectionFailed("bad loopback address")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var result: Result<Data, Error> = .failure(
            WillDeepRuntimeTransportError.connectionFailed("no response")
        )
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                result = .failure(
                    WillDeepRuntimeTransportError.connectionFailed(error.localizedDescription)
                )
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, !data.isEmpty else {
                result = .failure(WillDeepRuntimeTransportError.httpStatus(status))
                return
            }
            result = .success(data)
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return try result.get()
    }
}
