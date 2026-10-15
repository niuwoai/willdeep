import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized) @MainActor struct AgentRSIApprovedTrialTests {
    private var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    @Test func hostControlledNativeEntry() async throws {
        let path = repository.appendingPathComponent("build/rsi-approved-trial-input.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let config = try AgentRSIContract.raw(Data(contentsOf: path))
        let controlPath = try #require(config["control_path"].text)
        let attributes = try FileManager.default.attributesOfItem(atPath: controlPath)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw AgentRSIError.paidNotApproved }
        let input = try AgentRSIApprovedTrial.Input(data: Data(contentsOf: URL(fileURLWithPath: controlPath)))
        if config["mode"].text == "execute" {
            _ = try await AgentRSIApprovedTrial.run(input)
        } else {
            #expect(config["mode"].text == "preview")
            let bytes = try await AgentRSIApprovedTrial.preview(input)
            try bytes.write(to: repository.appendingPathComponent("build/rsi-approved-review-preview.json"), options: .atomic)
        }
    }
    @Test func brokerRejectsDirectOriginsBeforeAnyRequest() throws {
        for origin in ["https://some.im", "http://localhost:1", "http://127.0.0.1:1/elsewhere", "http://x@127.0.0.1:1", "http://127.0.0.1:1?x=1"] {
            #expect(throws: AgentRSIError.paidNotApproved) { try AgentRSIApprovedBroker(origin: origin, capability: "synthetic-capability", trialID: "synthetic") }
        }
    }
    @Test func realWorkerNonStreamingBrokerPathUsesToolsAndObservedUsageWithoutNetwork() async throws {
        ApprovedBrokerFixture.configure(mode: "good")
        let root = repository.appendingPathComponent("build/rsi-approved-free-tests/" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shared = URL(fileURLWithPath: "/private/tmp/willdeep-agent-registry/bench/agent-rsi/reviewer-original-24-v1/suite.json")
        // Host-only corpus remains outside the Worker's randomized workspace.
        let golden = try AgentRSIOfflineRunner.golden()["candidate"]
        let package = root.appendingPathComponent("baseline.json")
        try golden["baseline_package"].bytes.write(to: package)
        let suite = try AgentRSIContract.raw(Data(contentsOf: shared))
        let task = suite["tasks"].elements[0]
        let control = AgentCanonicalJSON.object(["schema": .string("willdeep.agent-rsi.native-trial-control.v1"),
            "proposal_sha256": .string(AgentRSIApprovedBroker.proposalSHA256), "experiment_id": .string("free-native-test"),
            "trial_id": .string("synthetic-trial"), "arm": .string("baseline"), "repetition": .integer(1), "attempt": .integer(1),
            "resume_of": .null, "agent_package": .string(package.path), "agent_revision": golden["baseline_package"]["sha256"],
            "suite": .string(shared.path), "suite_sha256": .string(AgentRSIApprovedTrial.suiteSHA256), "task_id": task["task_id"],
            "broker_origin": .string("http://127.0.0.1:1"), "capability": .string("synthetic-capability"),
            "output_directory": .string(root.appendingPathComponent("trial").path)])
        let input = try AgentRSIApprovedTrial.Input(data: control.bytes)
        let previewInput = try AgentRSIApprovedTrial.Input(data: control.replacing("output_directory", .string(root.appendingPathComponent("preview-loop-bound-bug").path)).bytes)
        let preview = try AgentRSIContract.raw(await AgentRSIApprovedTrial.preview(previewInput))
        #expect(preview["stream"] == .bool(false) && preview["temperature"] == .integer(0) && preview["max_tokens"] == .integer(4000))
        #expect(!preview.canonical.contains(task["task_id"].text!) && !preview.canonical.contains("expected_output"))
        try preview.bytes.write(to: root.appendingPathComponent("preview.json"))
        let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [ApprovedBrokerFixture.self]
        let session = URLSession(configuration: transport)
        let result = try await AgentRSIApprovedTrial.run(input, session: session)
        #expect(result["read_observed"] == .bool(true) && result["fixture_unchanged"] == .bool(true))
        #expect(result["input_tokens"] == .integer(200) && result["output_tokens"] == .integer(40))
        #expect(result["raw_model_content"].text?.contains("has_defect") == true)
        #expect(result["loaded_revision"] == golden["baseline_package"]["sha256"])
        #expect(result["events"].elements.filter { $0["kind"].text == "broker_receipt" }.count == 2)
        #expect(result["events"].elements.first { $0["kind"].text == "broker_receipt" }?["model"].text == "synthetic-opaque-upstream-id")
        #expect(result["events"].elements.first { $0["kind"].text == "provider_response" }?["model"].text == "synthetic-provider-model")
        #expect(result["grading"].text == "host_only_pending")
        #expect(result["request_receipts"].elements.count == 2 && result["request_receipts"].elements[0]["usage"]["total_tokens"] == .integer(120))
    }
    @Test func unknownUsageAndChangedRouteStopWithoutHiddenRetries() async throws {
        for mode in ["missing-usage", "wrong-approved-model", "missing-route"] {
            ApprovedBrokerFixture.configure(mode: mode)
            let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [ApprovedBrokerFixture.self]
            let broker = try AgentRSIApprovedBroker(origin: "http://127.0.0.1:1", capability: "synthetic", trialID: "synthetic", session: URLSession(configuration: transport))
            defer { broker.close() }
            let client = AgentClient(configuration: broker.configuration())
            await #expect(throws: AgentRSIError.missingEvidence) {
                try await AgentRSIApprovedBroker.$current.withValue(broker) {
                    try await client.streamChat(messages: [.init(role: .user, content: "Synthetic read fixture.")], tools: [], onEvent: { _ in })
                }
            }
            #expect(ApprovedBrokerFixture.requestCount == 1)
        }
        ApprovedBrokerFixture.configure(mode: "good")
    }
    @Test func fifthPhysicalRequestIsDeniedBeforeTransport() async throws {
        ApprovedBrokerFixture.configure(mode: "good")
        let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [ApprovedBrokerFixture.self]
        let broker = try AgentRSIApprovedBroker(origin: "http://127.0.0.1:1", capability: "synthetic", trialID: "synthetic", session: URLSession(configuration: transport))
        defer { broker.close() }
        for _ in 0..<4 {
            try await broker.run(configuration: broker.configuration(), messages: [], tools: [], ledger: nil, ownerGate: nil, onEvent: { _ in })
        }
        await #expect(throws: AgentRSIError.paidNotApproved) {
            try await broker.run(configuration: broker.configuration(), messages: [], tools: [], ledger: nil, ownerGate: nil, onEvent: { _ in })
        }
        #expect(ApprovedBrokerFixture.requestCount == 4)
    }
}

private nonisolated final class ApprovedBrokerFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var mode = "good"
    private nonisolated(unsafe) static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func configure(mode: String) { lock.lock(); defer { lock.unlock() }; self.mode = mode; count = 0 }
    private static func begin() -> String { lock.lock(); defer { lock.unlock() }; count += 1; return mode }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let mode = Self.begin()
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); guard n >= 0 else { throw AgentAssetError.server }; if n == 0 { break }; data.append(bytes, count: n) }
            }
            let body = try AgentRSIContract.raw(data)
            guard request.url?.host == "127.0.0.1", request.url?.path == "/v1/chat/completions",
                  body["stream"] == .bool(false), body["max_tokens"] == .integer(4000),
                  request.value(forHTTPHeaderField: "X-RSI-Proposal-Sha256") == AgentRSIApprovedBroker.proposalSHA256 else { throw AgentAssetError.server }
            let read = body["messages"].elements.contains { $0["role"].text == "tool" }
            let message: AgentCanonicalJSON = read
                ? .object(["role": .string("assistant"), "content": .string("{\"has_defect\":true,\"line\":4,\"reason\":\"Boundary exceeds valid indices.\"}")])
                : .object(["role": .string("assistant"), "content": .null, "tool_calls": .array([.object([
                    "id": .string("read-fixture"), "type": .string("function"), "function": .object([
                        "name": .string("read_file"), "arguments": .string("{\"path\":\"fixture.txt\"}")])])])])
            var value = AgentCanonicalJSON.object(["id": .string("synthetic-provider-response"), "model": .string("synthetic-provider-model"),
                "choices": .array([.object(["message": message, "finish_reason": .string(read ? "stop" : "tool_calls")])]),
                "usage": .object(["prompt_tokens": .integer(100), "completion_tokens": .integer(20), "total_tokens": .integer(120)])])
            if mode == "missing-usage" { value = value.replacing("usage", .null) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Routed-Model": mode == "missing-route" ? "" : "synthetic-opaque-upstream-id",
                    "X-RSI-Approved-Model": mode == "wrong-approved-model" ? "other-model" : "deepseek-v4-flash",
                    "X-Request-Id": "synthetic-request", "X-RSI-Receipt-Id": "synthetic-receipt"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: value.bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
