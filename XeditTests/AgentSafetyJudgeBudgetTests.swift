import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("安全裁判预算与审批停止", .serialized, .timeLimit(.minutes(1)))
struct AgentSafetyJudgeBudgetTests {
    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let ledger: AgentModelRequestLedger
        let defaults: UserDefaults
        let suite: String
        let token: String
        let session: URLSession
        var envelope: AgentToolExecutionBudget { .init(budget: .standard, requestLedger: ledger) }
        func cleanup() {
            session.invalidateAndCancel()
            GoalLoopURLProtocol.remove(token)
            app.dispatchDecisionResumptionTask?.cancel()
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            for suffix in ["", "-wal", "-shm"] {
                let path = ledger.databaseURL.path + suffix
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do { try FileManager.default.removeItem(atPath: path) }
                catch { Issue.record("Safety fixture cleanup: \(error)") }
            }
        }
    }

    private func fixture(limit: Int? = 1_000_000) throws -> Fixture {
        let suite = "safety-budget-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let runtime = AgentRuntime(session: .init(interactionMode: .goal,
            currentGoal: .init(statement: "Fixture task", checklist: [.init(text: "Evidence verified")])))
        app.agentSessions = [runtime.session]
        app.agentAlwaysAllowedCommands = [] // Instance-only, never change saved operator rules.
        runtime.currentPlan = .init(status: .executing)
        app.agentRuntimes = [runtime.id: runtime]
        app.activeAgentSessionID = runtime.id
        let ledger = try #require(app.modelRequestLedger(for: runtime))
        try ledger.setAdmissionLimit(limit, expectedRevision: 0)
        let token = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoalLoopURLProtocol.self]
        config.httpAdditionalHeaders = [GoalLoopURLProtocol.tokenHeader: token]
        return .init(app: app, runtime: runtime, ledger: ledger, defaults: defaults, suite: suite,
            token: token, session: URLSession(configuration: config))
    }

    private func configuration(_ kind: String) -> AgentConfiguration {
        let model: String
        switch kind {
        case "openai": model = "gpt-4.1"
        case "openai-responses": model = "o3"
        case "claude": model = "claude-sonnet-4"
        case "gemini": model = "gemini-2.5-flash"
        default: model = SomeIMManagedModel.securityGuard
        }
        return .init(providerID: kind, baseURL: "https://safety-budget.invalid/v1", model: model, apiKey: "test-placeholder")
    }

    private func reply(_ kind: String, verdict: String = "YES") throws -> Data {
        let text = "<verdict>\(verdict)</verdict>"
        let object: [String: Any]
        switch kind {
        case "openai":
            object = ["choices": [["message": ["content": text]]],
                "usage": ["prompt_tokens": 7, "completion_tokens": 11, "total_tokens": 18]]
        case "claude":
            object = ["content": [["type": "text", "text": text]], "usage": ["input_tokens": 7, "output_tokens": 11]]
        case "gemini":
            object = ["candidates": [["content": ["parts": [["text": text]]]]],
                "usageMetadata": ["promptTokenCount": 7, "candidatesTokenCount": 11, "totalTokenCount": 18]]
        default:
            object = ["output": [["type": "message", "content": [["type": "output_text", "text": text]]]],
                "usage": ["input_tokens": 7, "output_tokens": 11, "total_tokens": 18]]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("四协议实际请求记录用量且耗尽后不再发包", arguments: ["openai", "openai-responses", "claude", "gemini"])
    func actualTransport(_ kind: String) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let payload = try reply(kind)
        var count = 0, cap: Int?
        GoalLoopURLProtocol.install(f.token) { request in
            count += 1
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any]
            cap = (body?["max_completion_tokens"] ?? body?["max_tokens"] ?? body?["max_output_tokens"]
                ?? (body?["generationConfig"] as? [String: Any])?["maxOutputTokens"]) as? Int
            return payload
        }
        let client = AgentClient(configuration: configuration(kind), session: f.session)
        let result = try await client.budgetedSafetyJudge(command: "yarn test", executionBudget: f.envelope)
        guard case .allow = result else { Issue.record("Expected actual parsed allow, got \(result)"); return }
        #expect(cap == AgentInjectionDefense.judgeMaxOutputTokens)
        #expect(try f.ledger.summary() == .init(attempts: 1, unfinished: 0, unknownUsage: 0, reportedTokens: 18))
        try f.ledger.setAdmissionLimit(18, expectedRevision: 1)
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            _ = try await client.budgetedSafetyJudge(command: "yarn test", executionBudget: f.envelope)
        }
        #expect(count == 1)
    }

    @Test("网关隐藏安全策略不能假装为已知输入；无上限仍保存真实回执")
    func hiddenPolicyExposure() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let payload = try reply("some-im")
        var count = 0
        GoalLoopURLProtocol.install(f.token) { _ in count += 1; return payload }
        let client = AgentClient(configuration: configuration("some-im"), session: f.session)
        await #expect(throws: AgentModelRequestLedger.Failure.unknownExposure) {
            _ = try await client.budgetedSafetyJudge(command: "yarn test", executionBudget: f.envelope)
        }
        #expect(count == 0)
        try f.ledger.setAdmissionLimit(nil, expectedRevision: 1)
        _ = try await client.budgetedSafetyJudge(command: "yarn test", executionBudget: f.envelope)
        #expect(count == 1)
        #expect(try f.ledger.summary().reportedTokens == 18)
        #expect(try f.ledger.summary().unknownUsage == 0)
    }

    @Test("预算拒绝既不走候选替补，也不静默放行", arguments: [false, true])
    func noFallbackOrSilentAllow(_ silent: Bool) async throws {
        let f = try fixture(limit: 1); defer { f.cleanup() }
        f.app.safetyJudgeInferenceEnvironment = ([configuration("openai"), configuration("claude")], f.session)
        var count = 0
        GoalLoopURLProtocol.install(f.token) { _ in count += 1; return Data() }
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            _ = try await f.app.checkedSafetyJudgeApproval(toolName: "run_command", command: "yarn test",
                approvesWhenUnavailable: silent, taskRuntime: f.runtime)
        }
        #expect(count == 0)
        #expect(f.app.cachedJudgeAllowedVerdicts.isEmpty)
        #expect(f.runtime.toolCalls.isEmpty)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("普通裁判不可用仍允许既有候选替补")
    func ordinaryFallback() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.app.safetyJudgeInferenceEnvironment = ([configuration("openai"), configuration("claude")], f.session)
        let payload = try reply("claude")
        var count = 0
        GoalLoopURLProtocol.install(f.token) { _ in count += 1; return count == 1 ? Data("{}".utf8) : payload }
        let result = try await f.app.checkedSafetyJudgeApproval(toolName: "run_command", command: "yarn test",
            taskRuntime: f.runtime)
        #expect(result == .llmJudge)
        #expect(count == 2)
        #expect(try f.ledger.summary().attempts == 2)
        #expect(try f.ledger.summary().unknownUsage == 1)
    }

    @Test("旧授权代次的迟到裁判不审批、不缓存、不暂停新目标")
    func staleVerdict() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.app.safetyJudgeInferenceEnvironment = ([configuration("openai")], f.session)
        let payload = try reply("openai")
        GoalLoopURLProtocol.install(f.token) { _ in f.runtime.goalAuthorizationRevision = UUID(); return payload }
        await #expect(throws: CancellationError.self) {
            _ = try await f.app.checkedSafetyJudgeApproval(toolName: "run_command", command: "yarn test", taskRuntime: f.runtime)
        }
        #expect(f.app.cachedJudgeAllowedVerdicts.isEmpty)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused != true)
        #expect(try f.ledger.summary().reportedTokens == 18)
    }

    @Test("父预算停止时只读和写入子工具都不产生审批卡", arguments: [AgentToolRisk.read, .write])
    func workerEntry(_ risk: AgentToolRisk) async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.currentGoal?.continuationBudget = .init(wrapUpDispatched: true)
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
        _ = try await f.app.resolveSubagentToolApproval(toolName: "run_command",
            arguments: ["command": .string("yarn test")], risk: risk, workerName: "fixture",
            runtime: f.runtime, messageID: UUID(), rootDirectory: nil)
        }
        let delegated = await f.app.resolveDelegatedExecutorApproval(.init(id: UUID().uuidString,
            executor: .willDeep, kind: .command, command: "pwd", cwd: nil, reason: nil, filePaths: [],
            requestedPermissions: nil, allowsSessionApproval: false), runtime: f.runtime, messageID: UUID(), rootDirectory: nil)
        if case .cancel = delegated {} else { Issue.record("Host stop must cancel delegated approval") }
        #expect(f.runtime.toolCalls.isEmpty)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("原生子工具裁判预算不足直接宿主暂停，不落到人工")
    func workerJudgeRefusal() async throws {
        let f = try fixture(limit: 1); defer { f.cleanup() }
        f.app.safetyJudgeInferenceEnvironment = ([configuration("openai")], f.session)
        var count = 0
        GoalLoopURLProtocol.install(f.token) { _ in count += 1; return Data() }
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
        _ = try await f.app.resolveSubagentToolApproval(toolName: "run_command",
            arguments: ["command": .string("safety-fixture-\(UUID())")], risk: .write, workerName: "fixture",
            runtime: f.runtime, messageID: UUID(), rootDirectory: nil)
        }
        #expect(count == 0)
        #expect(f.runtime.toolCalls.isEmpty)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
    }

    @Test("待审重评在预算停止后释放真实等待，不写入用户授权")
    func pendingReevaluation() async throws {
        let f = try fixture(limit: 1); defer { f.cleanup() }
        f.app.safetyJudgeInferenceEnvironment = ([configuration("openai")], f.session)
        let call = AgentToolCall(messageID: UUID(), externalID: "subagent:fixture",
            toolName: "run_command", arguments: ["command": .string("safety-fixture-\(UUID())")], risk: .write, status: .pendingApproval)
        f.runtime.toolCalls = [call]
        let waiter = Task { @MainActor in await f.app.awaitToolDecision(for: f.runtime, forCallID: call.id) }
        defer { waiter.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while f.runtime.toolDecisionWaiters[call.id] == nil {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let reevaluate = try #require(f.app.reevaluatePendingAgentToolApprovals(for: f.runtime) { _ in true })
        await reevaluate.value
        let released = f.runtime.toolDecisionWaiters.isEmpty
        #expect(released)
        #expect(f.runtime.toolCalls.first?.status == .failed)
        #expect(f.runtime.toolCalls.first?.approvalSource == nil)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        guard released else { waiter.cancel(); _ = await waiter.value; return }
        if case .denied = await waiter.value {} else { Issue.record("Expected host-denied waiter") }
    }

    @Test("verifier 裁判拒绝准入时不删除验证器后继续启动子任务")
    func verifierCannotDowngradeOnBudgetStop() async throws {
        let f = try fixture(limit: 1); defer { f.cleanup() }
        f.app.safetyJudgeInferenceEnvironment = ([configuration("openai")], f.session)
        let call = AgentMessageToolCall(externalID: "fixture-verifier", toolName: "spawn_agent", argumentsJSON: "{}")
        let record = AgentToolCall(messageID: UUID(), externalID: call.externalID, toolName: call.toolName,
            arguments: [:], risk: .read, status: .running)
        f.runtime.toolCalls = [record]
        f.runtime.messages = [.init(id: record.messageID, role: .assistant, content: "", toolCalls: [call])]
        var count = 0
        GoalLoopURLProtocol.install(f.token) { _ in count += 1; return Data() }
        await f.app.executeSpawnAgentToolCall(call, recordID: record.id,
            arguments: ["prompt": .string("Read fixture only"), "profile": .string(AgentSubagentProfileCatalog.scoutID),
                "task": .object(["goal": .string("Verify fixture"), "verifier": .object(["command": .string("safety-fixture-\(UUID())")])])],
            runtime: f.runtime, configuration: configuration("openai"), workspaceURL: nil,
            runtimeDescriptor: nil, workspaceLocation: nil)
        #expect(count == 0)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(f.runtime.toolCalls.first?.status == .failed)
        #expect(f.runtime.toolCalls.first?.errorMessage == L10n.GoalAdmission.exhausted)
        #expect(OpenAIChatAdapter.providerReadyMessages(f.runtime.messages).contains { $0.toolCallID == call.externalID })
        #expect(f.app.agentSubagentRegistry.runs.isEmpty)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("取消在途安全裁判时不尝试替补或缓存允许")
    func cancelledTransport() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.app.safetyJudgeInferenceEnvironment = ([configuration("openai"), configuration("claude")], f.session)
        var count = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            count += 1
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let judge = Task { @MainActor in
            try await f.app.checkedSafetyJudgeApproval(toolName: "run_command", command: "yarn test", taskRuntime: f.runtime)
        }
        defer { judge.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        judge.cancel()
        await #expect(throws: CancellationError.self) { _ = try await judge.value }
        #expect(count == 1)
        #expect(f.app.cachedJudgeAllowedVerdicts.isEmpty)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused != true)
        #expect(try f.ledger.summary().unknownUsage == 1)
        #expect(try f.ledger.summary().unfinished == 0)
    }

    @Test("阶段一停止保持已有回执并补齐剩余工具调用")
    func stagedRoundSettlement() throws {
        let f = try fixture(); defer { f.cleanup() }
        let calls = (0..<3).map { AgentMessageToolCall(externalID: "fixture-\($0)", toolName: "run_command", argumentsJSON: "{}") }
        let assistant = AgentMessage(role: .assistant, content: "", toolCalls: calls)
        f.runtime.messages = [assistant, .init(role: .tool, content: "existing denial", toolCallID: calls[0].externalID)]
        f.runtime.toolCalls = calls.enumerated().map { index, call in
            AgentToolCall(messageID: assistant.id, externalID: call.externalID, toolName: call.toolName,
                arguments: index == 0 ? [:] : [AgentSerialToolApprovalQueue.argumentKey: .bool(true)], risk: .write,
                status: index == 0 ? .denied : .running)
        }
        f.app.stopApprovalToolRound(AgentModelRequestLedger.Failure.budgetExceeded, runtime: f.runtime, assistantID: assistant.id)
        #expect(f.runtime.toolCalls.map(\.status) == [.denied, .failed, .failed])
        #expect(f.runtime.messages.filter { $0.role == .tool }.map(\.toolCallID) == calls.map { Optional($0.externalID) })
        #expect(f.runtime.messages[1].content == "existing denial")
        #expect(f.runtime.messages.last?.origin == .hostGenerated)
        #expect(f.runtime.toolCalls.dropFirst().allSatisfy { !AgentSerialToolApprovalQueue.contains($0) })
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
