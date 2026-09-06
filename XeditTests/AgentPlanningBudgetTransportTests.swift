import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("规划实际 streaming 账本", .serialized, .timeLimit(.minutes(1)))
struct AgentPlanningBudgetTransportTests {
    @Test("结构化结果及无效结构重试都受真实请求账本限制", arguments: [true, false])
    func structuredRunnerUsesActualLedger(_ valid: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("planning-transport-\(UUID())")
        let ledger = AgentModelRequestLedger(directory: root, ownerID: UUID())
        try ledger.setAdmissionLimit(1_000_000, expectedRevision: 0)
        let token = UUID().uuidString
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PlanningBudgetURLProtocol.self]
        sessionConfiguration.httpAdditionalHeaders = [PlanningBudgetURLProtocol.tokenHeader: token]
        let session = URLSession(configuration: sessionConfiguration)
        defer {
            session.invalidateAndCancel()
            PlanningBudgetURLProtocol.remove(token)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Planning transport cleanup: \(error)") }
        }
        let configuration = AgentConfiguration(providerID: "openai", baseURL: "https://planning-budget.invalid/v1",
            model: "gpt-4.1", apiKey: "test-placeholder")
        let envelope = AgentToolExecutionBudget(budget: .standard, requestLedger: ledger)
        let schema = AgentStructuredSchema(type: .object,
            properties: ["ok": .init(type: .boolean)], required: ["ok"], additionalProperties: false)
        var requests = 0
        var outputCap: Int?
        PlanningBudgetURLProtocol.install(token) { request in
            requests += 1
            let body = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                return data
            } ?? Data()
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            outputCap = object?["max_completion_tokens"] as? Int ?? object?["max_tokens"] as? Int
            // A policy change while this request is in flight cannot erase
            // its receipt or let the structured-output repair buy another.
            try ledger.setAdmissionLimit(18, expectedRevision: 1)
            let chunk: [String: Any] = ["choices": [["delta": ["content": valid ? #"{"ok":true}"# : "invalid JSON"],
                "finish_reason": "stop"]], "usage": ["prompt_tokens": 7, "completion_tokens": 11, "total_tokens": 18]]
            return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
                + "\n\ndata: [DONE]\n\n").utf8)
        }
        if valid {
            let outcome = try await AgentSubagentRunner.run(prompt: "Return the fixture payload", configuration: configuration,
                workspaceURL: nil, outputSchema: schema, executionBudget: envelope, session: session)
            #expect(outcome.report == #"{"ok":true}"#)
            #expect(outcome.usageTokens == 18)
        } else {
            await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
                _ = try await AgentSubagentRunner.run(prompt: "Return the fixture payload", configuration: configuration,
                    workspaceURL: nil, outputSchema: schema, executionBudget: envelope, session: session)
            }
        }
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            _ = try await AgentSubagentRunner.run(prompt: "Must not send another request", configuration: configuration,
                workspaceURL: nil, outputSchema: schema, executionBudget: envelope, session: session)
        }
        #expect(requests == 1)
        #expect(try #require(outputCap) > 0)
        #expect(try ledger.summary() == .init(attempts: 1, unfinished: 0, unknownUsage: 0, reportedTokens: 18))
        #expect(try ledger.budgetSnapshot().remainingTokens == 0)
    }
}

nonisolated private final class PlanningBudgetURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (URLRequest) throws -> Data
    static let tokenHeader = "X-Planning-Budget-Fixture"
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private var work: Task<Void, Never>?
    private var stopped = false

    static func install(_ token: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; handlers[token] = handler
    }
    static func remove(_ token: String) {
        lock.lock(); defer { lock.unlock() }; handlers[token] = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = request.value(forHTTPHeaderField: Self.tokenHeader).flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let task = Task { @MainActor in
            do {
                let data = try handler(request)
                try Task.checkCancellation()
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]) else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        Self.lock.lock()
        if stopped { task.cancel() } else { work = task }
        Self.lock.unlock()
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        stopped = true
        work?.cancel()
        work = nil
    }
}
