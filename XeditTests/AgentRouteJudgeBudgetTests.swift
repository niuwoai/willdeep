import Foundation
import SQLite3
import Testing
@testable import WillDeep

@MainActor
@Suite("非流式裁判预算", .serialized, .timeLimit(.minutes(1)))
struct AgentRouteJudgeBudgetTests {
    @MainActor private struct Fixture {
        let root: URL
        let token: String
        let session: URLSession
        let ledger: AgentModelRequestLedger
        var envelope: AgentToolExecutionBudget { .init(budget: .standard, requestLedger: ledger) }

        func cleanup() {
            session.invalidateAndCancel()
            GoalLoopURLProtocol.remove(token)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Route fixture cleanup: \(error)") }
        }
    }

    private func fixture(status: Int = 200) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-budget-\(UUID())")
        let token = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoalLoopURLProtocol.self]
        config.httpAdditionalHeaders = [GoalLoopURLProtocol.tokenHeader: token, GoalLoopURLProtocol.statusHeader: "\(status)"]
        let ledger = AgentModelRequestLedger(directory: root, ownerID: UUID())
        try ledger.setAdmissionLimit(1_000_000, expectedRevision: 0)
        return .init(root: root, token: token, session: URLSession(configuration: config), ledger: ledger)
    }

    private func configuration(responses: Bool) -> AgentConfiguration {
        .init(providerID: responses ? AgentProviderPreset.someIMID : "openai",
            baseURL: "https://route-budget.invalid/v1", model: responses ? SomeIMManagedModel.autoPro : "gpt-4.1",
            apiKey: "test-placeholder")
    }

    private func reply(responses: Bool, includeUsage: Bool = true) throws -> Data {
        var body: [String: Any] = responses
            ? ["output": [["type": "message", "content": [["type": "output_text", "text": "fixture verdict"]]]]]
            : ["choices": [["message": ["content": "fixture verdict"]]]]
        if includeUsage {
            body["usage"] = responses ? ["input_tokens": 7, "output_tokens": 11, "total_tokens": 18]
                : ["prompt_tokens": 7, "completion_tokens": 11, "total_tokens": 18]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func storedReceipt(_ ledger: AgentModelRequestLedger) throws -> AgentModelRequestLedger.Receipt {
        var db: OpaquePointer?, statement: OpaquePointer?
        #expect(sqlite3_open_v2(ledger.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        #expect(sqlite3_prepare_v2(db, "SELECT receipt_json FROM requests", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let text = try #require(sqlite3_column_text(statement, 0))
        return try JSONDecoder().decode(AgentModelRequestLedger.Receipt.self, from: Data(String(cString: text).utf8))
    }

    @Test("Chat 和 Responses 裁判使用实际输出限额与 owner 账本", arguments: [false, true])
    func requestsAreAccounted(_ responses: Bool) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let payload = try reply(responses: responses)
        let config = configuration(responses: responses)
        let model = responses ? SomeIMManagedModel.judge : "gpt-4.1"
        var requests = 0, cap: Int?
        var observedModel: String?
        GoalLoopURLProtocol.install(f.token) { request in
            requests += 1
            let object = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any]
            cap = object?[responses ? "max_output_tokens" : "max_completion_tokens"] as? Int
            observedModel = object?["model"] as? String
            try f.ledger.setAdmissionLimit(18, expectedRevision: 1)
            return payload
        }
        // Exercise inheritance from the envelope, not only an explicitly
        // ledger-configured client (callers must not silently lose its owner).
        let client = AgentClient(configuration: config, session: f.session)
        #expect(try await client.budgetedRouteJudge(model: model, systemPrompt: "fixture", userPayload: "fixture",
            maxTokens: 32, executionBudget: f.envelope) == "fixture verdict")
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            _ = try await client.budgetedRouteJudge(model: model, systemPrompt: "fixture", userPayload: "fixture",
                maxTokens: 32, executionBudget: f.envelope)
        }
        #expect(requests == 1)
        #expect(cap == 32)
        #expect(observedModel == model)
        #expect(try f.ledger.summary() == .init(attempts: 1, unfinished: 0, unknownUsage: 0, reportedTokens: 18))
        #expect(try storedReceipt(f.ledger).outcome == .succeeded)
    }

    @Test("HTTP 失败保留已报告用量，未知回执不退还预留", arguments: [false, true])
    func failedHTTPReceipt(_ known: Bool) async throws {
        let f = try fixture(status: 503); defer { f.cleanup() }
        let payload = try reply(responses: true, includeUsage: known)
        GoalLoopURLProtocol.install(f.token) { _ in payload }
        let client = AgentClient(configuration: configuration(responses: true), session: f.session)
        let answer = try await client.budgetedRouteJudge(model: SomeIMManagedModel.judge,
            systemPrompt: "fixture", userPayload: "fixture", maxTokens: 32, executionBudget: f.envelope)
        #expect(answer == nil) // Preserve ordinary HTTP fallback, not a budget bypass.
        let receipt = try storedReceipt(f.ledger)
        #expect(receipt.outcome == .failed)
        #expect(receipt.usage?.total == (known ? 18 : nil))
        let exposure = try f.ledger.exposure()
        #expect(exposure.accountedTokens == (known ? 18 : 0))
        #expect((exposure.estimatedTokens > 0) == !known)
    }

    @Test("预算拒绝不变成普通裁判缺席，不触发质量升级或丢弃原答复")
    func routeStopIsDistinctFromFallback() async throws {
        let f = try fixture(); defer { f.cleanup() }
        try f.ledger.setAdmissionLimit(1, expectedRevision: 1)
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in requests += 1; return Data() }
        let judge = AgentGoalRouteJudge(client: AgentClient(configuration: configuration(responses: true), session: f.session),
            executionBudget: f.envelope)
        let content = Array(repeating: "repetition fixture sentence", count: 6).joined(separator: "\n")
        let decision = await SomeIMManagedRouting.outputQuality(assistantText: content, reasoningText: nil,
            latestUserMessage: "fixture", model: SomeIMManagedModel.autoFlash, finishReason: "stop") { system, user, cap in
            await judge.text(model: SomeIMManagedModel.judge, system: system, user: user, maxTokens: cap)
        }
        #expect(decision.shouldRetry) // The legacy fallback WOULD retry this.
        #expect(judge.requestStop == .admission(.budgetExceeded))
        let app = AppState(loadSessionCatalog: false)
        let runtime = AgentRuntime(session: .init(interactionMode: .goal,
            currentGoal: .init(statement: "unfinished", checklist: [.init(text: "verified")])))
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.messages = [.init(role: .assistant, content: content)]
        #expect(app.stopAfterRouteJudge(judge, runtime: runtime))
        #expect(runtime.messages.first?.content == content)
        #expect(runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(runtime.currentGoal?.checklist.first?.done == false)
        #expect(runtime.queuedMessages.isEmpty)
        #expect(requests == 0)
    }

    @Test("非流式在途截止保留未知回执并停止裁判，不当成普通网络降级")
    func nonStreamingDeadlineStopsJudge() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var requests = 0, cancelled = false
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
            return Data()
        }
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 10, segmentStartedAt: Date()), requestLedger: f.ledger)
        let judge = AgentGoalRouteJudge(client: AgentClient(configuration: configuration(responses: true), session: f.session), executionBudget: budget)
        #expect(await judge.text(model: SomeIMManagedModel.judge, system: "fixture", user: "fixture", maxTokens: 32) == nil)
        #expect(requests == 1)
        #expect(cancelled)
        #expect(judge.requestStop == .executionBudget)
        #expect(try f.ledger.summary().unknownUsage == 1)
        #expect(try f.ledger.exposure().estimatedTokens > 0)
        #expect(try storedReceipt(f.ledger).outcome == .cancelled)
    }

    @Test("账本归属不一致时在发送前拒绝")
    func mismatchedOwnerIsRejected() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let other = AgentModelRequestLedger(directory: f.root, ownerID: UUID())
        let client = AgentClient(configuration: configuration(responses: false), session: f.session, requestLedger: other)
        await #expect(throws: AgentModelRequestLedger.Failure.ownerMismatch) {
            _ = try await client.budgetedRouteJudge(model: "gpt-4.1", systemPrompt: "fixture", userPayload: "fixture",
                maxTokens: 32, executionBudget: f.envelope)
        }
        #expect(try f.ledger.summary().attempts == 0)
    }

    @Test("协议用量字段归一化，缓存不重复计费且缺失总量不按零")
    func usageNormalization() throws {
        let examples: [(AgentModelRequestFormat, String, Int, Int)] = [
            (.openAIChat, #"{"usage":{"prompt_tokens":7,"completion_tokens":11,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":3}}}"#, 7, 18),
            (.responses, #"{"usage":{"total_tokens":18}}"#, 0, 18),
            (.anthropic, #"{"usage":{"input_tokens":7,"output_tokens":11,"cache_read_input_tokens":3,"cache_creation_input_tokens":5}}"#, 15, 26),
            (.gemini, #"{"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":11,"thoughtsTokenCount":4,"totalTokenCount":22}}"#, 7, 22)
        ]
        for (format, json, expectedPrompt, expectedTotal) in examples {
            let event = try #require(AgentNonStreamingModelRequest.usageEvent(data: Data(json.utf8), format: format))
            guard case .usageReported(let prompt, _, let total, _, _, _) = event else { Issue.record("Missing usage"); continue }
            #expect(prompt == expectedPrompt)
            #expect(total == expectedTotal)
        }
        for json in [#"{}"#, #"{"usage":{}}"#, #"{"usage":{"total_tokens":true}}"#,
                     #"{"usage":{"total_tokens":18,"prompt_tokens":-1}}"#,
                     #"{"usage":{"total_tokens":3,"prompt_tokens":7,"completion_tokens":11}}"#] {
            #expect(AgentNonStreamingModelRequest.usageEvent(data: Data(json.utf8), format: .openAIChat) == nil)
        }
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let size = stream.read(&buffer, maxLength: buffer.count)
            if size <= 0 { break }
            body.append(buffer, count: size)
        }
        return body
    }
}
