import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("真实工具入口预算执行门禁")
struct AgentToolBudgetEnforcementTests {
    @Test("真实后台 spawn 把原父截止时间传给实际 Worker 操作", .timeLimit(.minutes(1)))
    func backgroundSpawnPreservesParentDeadline() async throws {
        let app = AppState(loadSessionCatalog: false)
        let runtime = AgentRuntime(session: AgentSession())
        defer { app.agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id) }
        let budget = AgentGoalContinuationBudget(wallClockLimit: 3_600, segmentStartedAt: Date())
        runtime.interactionMode = .goal
        runtime.currentPlan = .init(status: .executing)
        runtime.currentGoal = .init(statement: "Bounded worker", checklist: [.init(text: "Verified")], continuationBudget: budget)
        let expected = app.toolExecutionBudget(for: runtime)
        #expect(expected?.requestLedger?.ownerID == runtime.id)
        let (observations, sink) = AsyncStream<Bool>.makeStream()
        defer { sink.finish() }
        app.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _, _, context, _ in
            let received = try #require(context.executionBudget)
            try received.checkCurrentOwner()
            #expect(received.ownerGate != nil)
            sink.yield(received.deadline == expected?.deadline
                && received.wrapUpOnly == expected?.wrapUpOnly
                && received.requestLedger == expected?.requestLedger)
            runtime.goalAuthorizationRevision = UUID()
            #expect(throws: CancellationError.self) { try received.checkCurrentOwner() }
            sink.finish()
            return .init(report: "Fixture completion", usageTokens: 0, roundCount: 1, toolInvocationCount: 0)
        }
        let call = AgentMessageToolCall(externalID: UUID().uuidString, toolName: "spawn_agent", argumentsJSON: "{}")
        let record = AgentToolCall(messageID: UUID(), externalID: call.externalID,
            toolName: call.toolName, arguments: [:], risk: .read, status: .running)
        runtime.toolCalls = [record]
        await app.executeSpawnAgentToolCall(call, recordID: record.id,
            arguments: ["prompt": .string("Inspect a bounded fixture"), "profile": .string("scout"), "run_in_background": .bool(true)],
            runtime: runtime, configuration: .default, workspaceURL: nil,
            runtimeDescriptor: nil, workspaceLocation: nil)
        try #require(runtime.toolCalls.first?.status == .succeeded)
        var iterator = observations.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(runtime.currentGoal?.continuationBudget == budget)
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("实际 Worker 入口在请求模型之前拒绝过期父预算")
    func workerRejectsExpiredBudgetBeforeProviderValidation() async throws {
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast))
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            _ = try await AgentSubagentRunner.run(prompt: "Must not send a model request",
                configuration: .init(providerID: "openai", baseURL: "https://budget.invalid/v1", model: "test", apiKey: ""),
                workspaceURL: nil, executionBudget: budget)
        }
    }

    @Test("过期预算不创建后台 Worker、句柄或待决报告")
    func backgroundRegistryRejectsBeforeCreatingRun() throws {
        let registry = AgentSubagentRegistry()
        let owner = UUID()
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast))
        #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            _ = try registry.startBackground(prompt: "Must not start", label: "Budget fixture",
                configuration: .default, workspaceURL: nil, parentRuntimeID: owner,
                executionContext: .init(executionBudget: budget))
        }
        #expect(registry.activeCount(forParentRuntime: owner) == 0)
        #expect(registry.runs.isEmpty)
    }

    @Test("真实 spawn 派发在审批、文件锁及前后台启动前检查父预算", arguments: [false, true])
    func spawnRejectsExpiredBudgetBeforeDispatch(background: Bool) async throws {
        let app = AppState(loadSessionCatalog: false)
        let runtime = AgentRuntime(session: AgentSession())
        runtime.interactionMode = .goal
        runtime.currentPlan = .init(status: .executing)
        runtime.currentGoal = .init(statement: "Bounded execution", checklist: [.init(text: "Verified")],
            continuationBudget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast))
        let messageID = UUID()
        let call = AgentMessageToolCall(externalID: UUID().uuidString, toolName: "spawn_agent", argumentsJSON: "{}")
        let record = AgentToolCall(messageID: messageID, externalID: call.externalID,
            toolName: call.toolName, arguments: [:], risk: .read, status: .running)
        runtime.toolCalls = [record]
        await app.executeSpawnAgentToolCall(call, recordID: record.id,
            arguments: ["prompt": .string("Must not dispatch"), "run_in_background": .bool(background)],
            runtime: runtime, configuration: .default, workspaceURL: nil,
            runtimeDescriptor: nil, workspaceLocation: nil)
        #expect(runtime.toolCalls.first?.status == .failed)
        #expect(runtime.toolCalls.first?.errorMessage == AgentToolExecutionBudgetError.exhausted.localizedDescription)
        #expect(runtime.toolDecisionWaiters.isEmpty)
        #expect(app.agentSubagentRegistry.runs.isEmpty)
        #expect(runtime.messages.last?.toolCallID == call.externalID)
    }

    @Test("过期预算在工具执行前被拒绝，上下文复制不丢失限制")
    func toolRunnerRejectsExpiredExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-budget-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Budget fixture cleanup failed: \(error)") }
        }
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast))
        let original = AgentToolContext(rootDirectory: directory, isGoalMode: true, executionBudget: envelope)
        let copied = original.withAdditionalSecretRedactionValues([]).withSandboxMode(.readOnly)
        #expect(copied.executionBudget == envelope)
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            _ = try await AgentToolRunner.run(
                name: "create_file", arguments: ["path": .string("must-not-exist.txt"), "content": .string("unexpected")], context: copied
            )
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("must-not-exist.txt").path))
    }
}
