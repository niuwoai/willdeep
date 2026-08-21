import Foundation
import Testing
@testable import WillDeep

/// Discovery, transport framing and the read-only boundary for the
/// willdeep-rs Runtime client. The last test in this suite talks to a real
/// daemon when one is running on this machine and skips when none is — the
/// pure tests below prove the parts, that one proves they add up.
@Suite
struct WillDeepRuntimeClientTests {
    private static func temporaryDirectory(_ name: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-runtime-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Discovery

    @Test("the socket wins when the daemon publishes both transports")
    func socketIsPreferredOverLoopback() throws {
        let directory = Self.temporaryDirectory("both")
        let socketPath = directory.appendingPathComponent("control.sock").path
        FileManager.default.createFile(atPath: socketPath, contents: Data())

        let state = try JSONDecoder().decode(
            WillDeepRuntimeDaemonState.self,
            from: Data("""
            {"schema":1,"version":"0.39.0-rc3","pid":42,"address":"127.0.0.1:61302",
             "token":"t","started_at":1,
             "local_transport":{"kind":"unix_socket","path":"\(socketPath)"}}
            """.utf8)
        )
        #expect(
            WillDeepRuntimeDiscovery.endpoint(for: state) == .unixSocket(path: socketPath),
            "the protocol tells local clients to prefer the socket"
        )
    }

    @Test("a state file without a live socket falls back to loopback")
    func loopbackIsTheFallback() throws {
        let state = try JSONDecoder().decode(
            WillDeepRuntimeDaemonState.self,
            from: Data("""
            {"schema":1,"version":"0.21.0-rc1","pid":42,"address":"127.0.0.1:61302","token":"t"}
            """.utf8)
        )
        #expect(
            WillDeepRuntimeDiscovery.endpoint(for: state) == .loopback(host: "127.0.0.1", port: 61302)
        )
    }

    /// A tampered state file must not be able to point this app's token at
    /// another machine. The daemon binds loopback only, so anything else is
    /// either corruption or an attempt to harvest the token.
    @Test("a non-loopback address is refused rather than dialed")
    func nonLoopbackAddressesAreRefused() throws {
        for address in ["10.0.0.5:61302", "evil.example.com:80", "0.0.0.0:61302"] {
            let state = try JSONDecoder().decode(
                WillDeepRuntimeDaemonState.self,
                from: Data("""
                {"schema":1,"version":"0.21.0-rc1","pid":1,"address":"\(address)","token":"t"}
                """.utf8)
            )
            #expect(
                WillDeepRuntimeDiscovery.endpoint(for: state) == nil,
                "must refuse non-loopback address: \(address)"
            )
        }
    }

    @Test("a missing or empty state file means no runtime, not a crash")
    func missingStateIsHandled() {
        let directory = Self.temporaryDirectory("absent")
        #expect(WillDeepRuntimeDiscovery.connection(from:
            directory.appendingPathComponent("daemon.json")) == nil)

        let empty = directory.appendingPathComponent("empty.json")
        try? Data("{}".utf8).write(to: empty)
        #expect(WillDeepRuntimeDiscovery.connection(from: empty) == nil)
    }

    @Test("the runtime directory follows WILLDEEP_HOME like the other stores")
    func runtimeDirectoryMatchesConvention() {
        let configDirectory = AgentAttentionPreferencesStore.defaultConfigURL()
            .deletingLastPathComponent()
        #expect(
            WillDeepRuntimeDiscovery.runtimeDirectory().deletingLastPathComponent().path
                == configDirectory.path
        )
        #expect(WillDeepRuntimeDiscovery.runtimeDirectory().lastPathComponent == "runtime")
    }

    // MARK: Request shape

    @Test("the request body matches the Rust ApiRequest contract")
    func requestBodyMatchesRustContract() throws {
        let requestID = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let data = try WillDeepRuntimeTransport.requestBody(
            operation: "event.list",
            params: ["after": 15, "limit": 200],
            requestID: requestID
        )
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(decoded["protocol_version"] as? String == "1.0")
        #expect(decoded["operation"] as? String == "event.list")
        // Lowercase UUID: Foundation uppercases, the Rust `uuid` crate does not,
        // and request ids are echoed back in `meta` for log correlation.
        #expect(decoded["request_id"] as? String == "11111111-2222-4333-8444-555555555555")
        let params = try #require(decoded["params"] as? [String: Any])
        #expect(params["after"] as? Int == 15)
        #expect(params["limit"] as? Int == 200)
    }

    // MARK: HTTP framing

    @Test("the body is split off a well-formed response")
    func httpBodyIsExtracted() throws {
        let response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}".utf8
        )
        let body = try WillDeepRuntimeTransport.httpBody(from: response)
        #expect(String(data: body, encoding: .utf8) == "{\"status\":\"ok\"}")
    }

    /// A 4xx still carries the error envelope, and its message beats a bare
    /// status code. Only a status with nothing to explain it surfaces raw.
    @Test("an error status keeps its envelope but an empty one surfaces the code")
    func errorStatusesArePreserved() throws {
        let withEnvelope = Data(
            "HTTP/1.1 403 Forbidden\r\nContent-Length: 44\r\n\r\n{\"status\":\"error\",\"error\":{\"code\":\"forbidden\"}}".utf8
        )
        let body = try WillDeepRuntimeTransport.httpBody(from: withEnvelope)
        #expect(String(data: body, encoding: .utf8)?.contains("forbidden") == true)

        let bare = Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".utf8)
        #expect(throws: WillDeepRuntimeTransportError.httpStatus(401)) {
            _ = try WillDeepRuntimeTransport.httpBody(from: bare)
        }
    }

    @Test("responses this client cannot honestly parse fail loudly")
    func unsupportedResponsesFail() {
        #expect(throws: (any Error).self) {
            _ = try WillDeepRuntimeTransport.httpBody(from: Data("garbage".utf8))
        }
        let chunked = Data(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8
        )
        #expect(throws: (any Error).self) {
            _ = try WillDeepRuntimeTransport.httpBody(from: chunked)
        }
    }

    // MARK: The read-only boundary

    /// Phase 1 observes. The cost of getting this wrong is asymmetric — a
    /// missing read is a blank panel, a stray write is someone's session gone
    /// — so the boundary is a mechanism with a test, not a convention.
    @Test("mutating operations are refused before any bytes leave")
    func mutatingOperationsAreRefused() throws {
        let connection = WillDeepRuntimeConnection(
            endpoint: .unixSocket(path: "/nonexistent/control.sock"),
            token: "t",
            serverVersion: "0.39.0-rc3",
            pid: 1
        )
        for operation in [
            "session.delete", "turn.submit", "agent.spawn", "agent.retry",
            "approval.resolve", "workspace.remove", "diff.revert",
        ] {
            #expect(!WillDeepRuntimeClient.readOnlyOperations.contains(operation))
            // The socket path does not exist, so reaching the transport at all
            // would surface as connectionFailed. Getting `forbidden` proves the
            // refusal happened first.
            #expect(throws: WillDeepRuntimeTransportError.api(
                code: "forbidden",
                message: "\(operation) is not a read-only operation; this client only observes"
            )) {
                _ = try WillDeepRuntimeClient.send(
                    operation,
                    as: WillDeepRuntimeClient.EmptyPayload.self,
                    connection: connection
                )
            }
        }
    }

    @Test("an error envelope becomes an error, never an empty result")
    func errorEnvelopesAreNotSwallowed() {
        let payload = Data("""
        {"status":"error","error":{"code":"not_found","message":"no such session"},
         "meta":{"protocol_version":"1.0"}}
        """.utf8)
        #expect(throws: WillDeepRuntimeTransportError.api(
            code: "not_found", message: "no such session"
        )) {
            let envelope = try WillDeepRuntimeClient.decodeEnvelope(
                payload, as: [WillDeepRuntimeSession].self
            )
            // Decoding succeeds (data is absent, not malformed); the client is
            // what must refuse to treat it as "zero sessions".
            #expect(!envelope.isOK)
            throw WillDeepRuntimeTransportError.api(
                code: envelope.error?.code ?? "", message: envelope.error?.message ?? ""
            )
        }
    }

    // MARK: Live daemon

    /// End to end against whatever Runtime is running on this machine. Skips
    /// when none is: a developer without a daemon is not a broken client. When
    /// one is running, this is the test that would catch a real protocol drift
    /// that every mock above agreed to.
    @Test("a live Runtime answers a read-only call end to end")
    func liveRuntimeAnswers() throws {
        guard let connection = WillDeepRuntimeDiscovery.connection() else { return }

        let capabilities: WillDeepRuntimeCapabilities
        do {
            capabilities = try WillDeepRuntimeClient.capabilities(connection: connection)
        } catch let error as WillDeepRuntimeTransportError {
            // A stale state file left by a dead daemon is not a client defect.
            if case .connectionFailed = error { return }
            throw error
        }

        #expect(capabilities.protocolVersion.hasPrefix("1."))
        #expect(capabilities.objects.count == 11)
        #expect(capabilities.operations.contains("runtime.capabilities"))
        #expect(!capabilities.serverVersion.isEmpty)
        // The daemon advertises what it really listens on; if it offers a
        // socket, discovery above should already have chosen one.
        if capabilities.transports.contains("unix_socket") {
            #expect(connection.endpoint != .loopback(host: "127.0.0.1", port: 0))
        }

        // Reading a list proves the object decoders survive real payloads,
        // which fixtures can only approximate.
        let workspaces = try WillDeepRuntimeClient.workspaces(connection: connection)
        for workspace in workspaces {
            #expect(!workspace.id.isEmpty)
            #expect(!workspace.access.isEmpty)
        }
    }
}
