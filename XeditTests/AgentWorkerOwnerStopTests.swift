import Foundation
import Testing
@testable import WillDeep

/// 首轮联系时限在这两个 suite 里要拉开。桩的响应在 MainActor 上交付，而全量
/// 并行跑时 MainActor 是全局瓶颈（这几个 suite 全是 @MainActor），产品口径的
/// 20 秒会在桩还没被调度时先到点，断言于是拿到 firstContactTimeout 而不是它
/// 要验的那个错误。拉开的是测试的证据窗口，产品默认值一个字没动。
/// 45 秒仍在 suite 的 .timeLimit 之内，也仍低于 workerRequestTimeout。
///
/// suite 时限从 1 分钟放到 3 分钟：`workerPropagatesRealApprovalFailure` 在满载
/// 时先等首轮联系（最长 45 秒），再等一轮同样要 MainActor 调度的裁判请求，两段
/// 叠起来会越过 1 分钟——2026-09-21 在 Xcode 27 上的发版全量里连红两次，单跑
/// 1.5 秒全过。时限只是防挂死的兜底，断言验的是抛出哪种错误，放宽不削弱判据。
private let testFirstContactTimeout: TimeInterval = 45

@MainActor
@Suite("Worker 宿主停止传播", .serialized, .timeLimit(.minutes(3)))
struct AgentWorkerOwnerStopTests {
    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let ledger: AgentModelRequestLedger
        let root: URL
        let token: String
        let session: URLSession
        let defaults: UserDefaults
        let suite: String
        let configuration = AgentConfiguration(providerID: "openai", baseURL: "https://worker-stop.invalid/v1",
            model: "gpt-4.1", apiKey: "test-placeholder")
        var budget: AgentToolExecutionBudget { app.auxiliaryModelExecutionBudget(for: runtime)! }
        func cleanup() {
            session.invalidateAndCancel(); GoalLoopURLProtocol.remove(token)
            app.agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
            app.dispatchDecisionResumptionTask?.cancel()
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            do {
                try FileManager.default.removeItem(at: root)
                for suffix in ["", "-wal", "-shm"] {
                    let path = ledger.databaseURL.path + suffix
                    if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                }
            } catch { Issue.record("Worker stop fixture cleanup: \(error)") }
        }
    }

    private func fixture(status: Int = 200) throws -> Fixture {
        let suite = "worker-owner-stop-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        app.agentAlwaysAllowedCommands = []
        let runtime = AgentRuntime(session: .init(interactionMode: .goal,
            currentGoal: .init(statement: "Fixture", checklist: [.init(text: "Verified")], continuationBudget: .standard)))
        runtime.currentPlan = .init(status: .executing)
        let ledger = try #require(app.modelRequestLedger(for: runtime))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-owner-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoalLoopURLProtocol.self]
        config.httpAdditionalHeaders = [GoalLoopURLProtocol.tokenHeader: token, GoalLoopURLProtocol.statusHeader: "\(status)"]
        return .init(app: app, runtime: runtime, ledger: ledger, root: root, token: token,
            session: URLSession(configuration: config), defaults: defaults, suite: suite)
    }

    private func response(tool: Bool = false, empty: Bool = false) throws -> Data {
        let delta: [String: Any] = tool
            ? ["tool_calls": [["index": 0, "id": "worker-fixture-call", "type": "function",
                "function": ["name": "run_command", "arguments": "{\"command\":\"worker-fixture-noop\"}"]]]]
            : ["content": empty ? "" : "Fixture report"]
        let body: [String: Any] = ["choices": [["delta": delta, "finish_reason": tool ? "tool_calls" : "stop"]],
            "usage": ["prompt_tokens": 7, "completion_tokens": 11, "total_tokens": 18]]
        let data = try JSONSerialization.data(withJSONObject: body)
        return Data("data: \(String(decoding: data, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
    }

    @Test("真实 Worker 的父裁判预算拒绝直接抛出，不再买报告或请求用户审批")
    func workerPropagatesRealApprovalFailure() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.approvalMode = .smart
        f.app.safetyJudgeInferenceEnvironment = ([f.configuration], f.session)
        let payload = try response(tool: true)
        var requests = 0, reviews = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            try f.ledger.setAdmissionLimit(18, expectedRevision: 0)
            return payload
        }
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            _ = try await AgentSubagentRunner.run(prompt: "Fixture", configuration: f.configuration, workspaceURL: nil,
                profile: AgentSubagentProfileCatalog.generalist,
                commandReviewer: { name, command in
                    reviews += 1
                    return try await f.app.resolveSubagentToolApproval(toolName: name, arguments: ["command": .string(command)],
                        risk: .write, workerName: "fixture", runtime: f.runtime, messageID: UUID(), rootDirectory: nil)
                }, executionBudget: f.budget, session: f.session,
                    firstContactTimeout: testFirstContactTimeout)
        }
        #expect(requests == 1 && reviews == 1)
        #expect(try f.ledger.summary().reportedTokens == 18)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(f.runtime.toolCalls.isEmpty && f.runtime.toolDecisionWaiters.isEmpty)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("审批返回后重查宿主：暂停或换代不能变成普通拒绝报告", arguments: ["pause", "resume", "revision", "owner", "deny"])
    func liveStateAfterReview(_ transition: String) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let budget = f.budget, tool = try response(tool: true), final = try response()
        var requests = 0, reviews = 0
        GoalLoopURLProtocol.install(f.token) { _ in requests += 1; return requests == 1 ? tool : final }
        let operation = {
            try await AgentSubagentRunner.run(prompt: "Fixture", configuration: f.configuration, workspaceURL: nil,
                profile: AgentSubagentProfileCatalog.generalist,
                commandReviewer: { _, _ in
                    reviews += 1
                    switch transition {
                    case "pause": f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused = true
                    case "resume":
                        f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused = true
                        f.runtime.currentGoal?.continuationBudget = .standard
                    case "revision": f.runtime.goalAuthorizationRevision = UUID()
                    case "owner": f.runtime.session.dispatchParentProjectID = UUID()
                    default: break
                    }
                    return false
                }, executionBudget: budget, session: f.session,
                firstContactTimeout: testFirstContactTimeout)
        }
        if transition == "deny" {
            let outcome = try await operation()
            #expect(outcome.report.contains("Fixture report"))
        } else if transition == "pause" {
            await #expect(throws: AgentToolExecutionBudgetError.exhausted) { _ = try await operation() }
        } else {
            await #expect(throws: CancellationError.self) { _ = try await operation() }
        }
        #expect(reviews == 1)
        #expect(requests == (transition == "deny" ? 2 : 1))
        #expect(f.runtime.toolCalls.isEmpty)
    }

    @Test("已捕获预算在授权检查让出后被暂停，真实文件工具不落盘")
    func toolRechecksAfterAuthorizationYield() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let context = AgentToolContext(rootDirectory: f.root, isGoalMode: true, executionBudget: f.budget,
            taskAuthorizationCheck: { _, _, _ in
                await Task.yield()
                f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused = true
            })
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            _ = try await AgentToolRunner.run(name: "create_file", arguments: ["path": .string("must-not-exist"), "content": .string("fixture")], context: context)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("must-not-exist").path))
    }

    @Test("空响应重试前重新核对 owner，不能靠重试绕过暂停")
    func emptyRetryChecksLiveOwner() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let payload = try response(empty: true), budget = f.budget
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused = true
            return payload
        }
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            try await AgentClient(configuration: f.configuration, session: f.session, requestLedger: f.ledger)
                .streamChat(messages: [.init(role: .user, content: "Fixture")], executionBudget: budget) { _ in }
        }
        #expect(requests == 1)
        #expect(try f.ledger.summary().attempts == 1)
        #expect(try f.ledger.summary().reportedTokens == 18)
    }

    @Test("旧预算已过期时裁判仍优先拒绝失效 owner，不发送请求", arguments: [false, true])
    func staleExpiredJudgeNeverPausesReplacement(_ safety: Bool) async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 1, segmentStartedAt: .distantPast)
        let budget = f.budget
        f.runtime.goalAuthorizationRevision = UUID()
        f.runtime.currentGoal?.continuationBudget = .standard
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in requests += 1; throw URLError(.networkConnectionLost) }
        let client = AgentClient(configuration: f.configuration, session: f.session, requestLedger: f.ledger)
        await #expect(throws: CancellationError.self) {
            if safety {
                _ = try await client.budgetedSafetyJudge(command: "worker-fixture-noop", executionBudget: budget)
            } else {
                _ = try await client.budgetedRouteJudge(model: "gpt-4.1", systemPrompt: "Fixture",
                    userPayload: "Fixture", maxTokens: 32, executionBudget: budget)
            }
        }
        #expect(requests == 0)
        #expect(try f.ledger.summary().attempts == 0)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused != true)
    }

    @Test("旧任务网络失败不能覆盖换代取消", arguments: [false, true])
    func staleOwnerWinsTransportFailure(_ hasDeadline: Bool) async throws {
        let f = try fixture(); defer { f.cleanup() }
        if hasDeadline {
            f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 3_600, segmentStartedAt: Date())
        }
        let budget = f.budget
        #expect((budget.deadline != nil) == hasDeadline)
        await #expect(throws: CancellationError.self) {
            try await budget.runModelRequest {
                f.runtime.goalAuthorizationRevision = UUID()
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused != true)
    }

    @Test("真实路由请求换代后网络失败，不能走普通 fallback 或暂停新 Goal")
    func staleRouteDoesNotFallback() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            f.runtime.goalAuthorizationRevision = UUID()
            throw URLError(.networkConnectionLost)
        }
        let judge = AgentGoalRouteJudge(client: .init(configuration: f.configuration, session: f.session,
            requestLedger: f.ledger), executionBudget: f.budget)
        #expect(await judge.text(model: "gpt-4.1", system: "Fixture", user: "Fixture", maxTokens: 32) == nil)
        #expect(judge.ownerCancelled)
        #expect(judge.requestStop == nil)
        #expect(f.app.stopAfterRouteJudge(judge, runtime: f.runtime))
        #expect(await judge.text(model: "gpt-4.1", system: "Fixture", user: "Fixture", maxTokens: 32) == nil)
        #expect(requests == 1)
        #expect(try f.ledger.summary().attempts == 1)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused != true)
        #expect(f.runtime.messages.isEmpty && f.runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("Responses 内部兼容重试也检查实时 owner")
    func responsesCompatibilityRetryChecksOwner() async throws {
        let f = try fixture(status: 503); defer { f.cleanup() }
        let config = AgentConfiguration(providerID: AgentProviderPreset.someIMID, baseURL: "https://worker-stop.invalid/v1",
            model: "deepseek-v4-pro", apiKey: "test-placeholder")
        #expect(config.usesWillDeepGatewayResponsesState)
        let budget = f.budget
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused = true
            return Data("{\"error\":{\"code\":\"state_backend_unavailable\"}}".utf8)
        }
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            try await AgentClient(configuration: config, session: f.session, requestLedger: f.ledger)
                .streamChat(messages: [.init(role: .user, content: "Fixture")], executionBudget: budget) { _ in }
        }
        #expect(requests == 1)
        #expect(try f.ledger.summary().attempts == 1)
        #expect(try f.ledger.summary().unknownUsage == 1)
    }
}
