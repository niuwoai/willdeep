import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("Goal 规划请求共享预算", .serialized, .timeLimit(.minutes(1)))
struct AgentGoalPlanningBudgetTests {
    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let defaults: UserDefaults
        let suite: String

        func cleanup() {
            app.agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
            app.dispatchDecisionResumptionTask?.cancel()
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            if let ledger = app.modelRequestLedger(for: runtime) {
                for suffix in ["", "-wal", "-shm"] {
                    let file = URL(fileURLWithPath: ledger.databaseURL.path + suffix)
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    do { try FileManager.default.removeItem(at: file) }
                    catch { Issue.record("Planning ledger fixture cleanup: \(error)") }
                }
            }
        }
    }

    private func fixture() throws -> Fixture {
        let suite = "goal-planning-budget-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let session = AgentSession(interactionMode: .goal,
            currentGoal: .init(statement: "Verify a bounded plan", checklist: [.init(text: "Verified")]))
        let runtime = AgentRuntime(session: session)
        runtime.isResponding = true // Queue synthesis rather than launching the main model.
        runtime.currentTurnPlanningOnly = true
        app.agentSessions = [session]
        app.agentRuntimes = [session.id: runtime]
        app.activeAgentSessionID = session.id
        app.subscribeToActiveRuntime()
        return .init(app: app, runtime: runtime, defaults: defaults, suite: suite)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func memberReport() throws -> String {
        String(decoding: try JSONEncoder().encode(AgentGoalPlanningMemberPayload(
            conclusion: "Bounded plan", evidence: ["fixture"], evidenceGaps: [],
            risks: ["regression"], recommendations: ["test"])), as: UTF8.self)
    }

    @Test("规划不启动执行计时，但绑定调度父账本；普通聊天与草稿不虚构目标")
    func envelopeOwnership() throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.session.dispatchParentProjectID = UUID()
        let envelope = try #require(f.app.auxiliaryModelExecutionBudget(for: f.runtime))
        #expect(envelope.deadline == nil)
        #expect(envelope.requestLedger?.ownerID == f.runtime.session.dispatchParentProjectID)
        #expect(f.runtime.currentGoal?.continuationBudget?.segmentStartedAt == nil)
        #expect(f.app.toolExecutionBudget(for: f.runtime) == nil)
        f.runtime.interactionMode = .normal
        #expect(f.app.auxiliaryModelExecutionBudget(for: f.runtime) == nil)
        f.runtime.interactionMode = .goal
        f.runtime.currentGoal = nil
        #expect(f.app.auxiliaryModelExecutionBudget(for: f.runtime) == nil)
    }

    @Test("同步规划传递同一预算，过期时不进入执行操作")
    func synchronousBoundary() async throws {
        let registry = AgentSubagentRegistry()
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: 60, segmentStartedAt: Date()))
        var observed: [AgentToolExecutionBudget?] = []
        registry.runOperation = { _, _, _, _, _, _, _, _, _, context, _ in
            observed.append(context.executionBudget)
            return .init(report: "{}", usageTokens: 0, roundCount: 1, toolInvocationCount: 0)
        }
        _ = try await registry.runGoalPlanningSynchronously(prompt: "fixture", configuration: .default,
            workspaceURL: nil, runtimeDescriptor: nil, workspaceLocation: nil, someIMContext: nil,
            outputSchema: AgentGoalPlanningMemberPayload.outputSchema, executionBudget: envelope)
        let expired = AgentToolExecutionBudget(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast))
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            _ = try await registry.runGoalPlanningSynchronously(prompt: "must not run", configuration: .default,
                workspaceURL: nil, runtimeDescriptor: nil, workspaceLocation: nil, someIMContext: nil,
                outputSchema: AgentGoalPlanningMemberPayload.outputSchema, executionBudget: expired)
        }
        #expect(observed == [envelope])
    }

    @Test("成员预算/未知/账本故障保留类型，取消兄弟且不调用仲裁或交接模型",
          arguments: [AgentModelRequestLedger.Failure.budgetExceeded, .unknownExposure, .unsafeStorage])
    func memberAdmissionStopsCoordinator(_ failure: AgentModelRequestLedger.Failure) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let originalGoal = f.runtime.currentGoal
        var observed: [AgentToolExecutionBudget?] = []
        f.app.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _, _, context, _ in
            observed.append(context.executionBudget)
            throw failure
        }
        #expect(f.app.startAgentGoalPlanningIfNeeded(for: f.runtime))
        try await waitUntil { f.runtime.goalPlanningState?.phase == .blocked }
        #expect(observed.count == 1)
        let firstObservation = try #require(observed.first)
        let envelope = try #require(firstObservation)
        #expect(envelope.requestLedger?.ownerID == f.runtime.id)
        #expect(f.runtime.goalPlanningState?.members.contains { $0.status == .running } == false)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(f.runtime.currentGoal?.checklist == originalGoal?.checklist)
        #expect(f.runtime.currentGoal?.continuationBudget?.segmentStartedAt == nil)
        #expect(f.runtime.queuedMessages.isEmpty)
        #expect(f.app.agentSubagentRegistry.pendingReportCount(forParentRuntime: f.runtime.id) == 0)
        #expect(f.app.agentSubagentRegistry.runs.contains { $0.requestStop == .admission(failure) })
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(f.runtime.session))
        #expect(restored.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(!f.app.startAgentGoalPlanningIfNeeded(for: f.runtime, forceRestart: true))
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
    }

    @Test("仲裁额度不足不走结构降级或付费 blocker，显式重试不清空已用额度")
    func arbitrationStopsAndRetryPreservesSpend() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let ledger = try #require(f.app.modelRequestLedger(for: f.runtime))
        let existing = UUID()
        try ledger.begin(id: existing, providerID: "fixture", modelID: "fixture", reservedTokens: 17)
        let report = try memberReport()
        var calls = 0
        f.app.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _, _, context, _ in
            #expect(context.executionBudget?.requestLedger == ledger)
            calls += 1
            if calls > 3 { throw AgentModelRequestLedger.Failure.budgetExceeded }
            return .init(report: report, usageTokens: 0, roundCount: 1, toolInvocationCount: 0)
        }
        #expect(f.app.startAgentGoalPlanningIfNeeded(for: f.runtime))
        try await waitUntil { f.runtime.goalPlanningState?.phase == .blocked }
        #expect(calls == 4)
        #expect(f.runtime.goalPlanningState?.members.allSatisfy { $0.status == .completed } == true)
        #expect(f.runtime.queuedMessages.isEmpty)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        f.app.retryAgentGoalPlanning()
        try await waitUntil { calls == 5 && f.runtime.goalPlanningState?.phase == .blocked }
        #expect(calls == 5)
        #expect(try ledger.exposure().estimatedTokens == 17)
        #expect(try ledger.summary().attempts == 1)
        #expect(f.runtime.queuedMessages.isEmpty)
    }

    @Test("过期执行时段不启动成员，不要求用户扩大工具授权")
    func expiredPlanningStartsNoWorkers() throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 1, segmentStartedAt: .distantPast)
        #expect(!f.app.startAgentGoalPlanningIfNeeded(for: f.runtime))
        #expect(f.app.agentSubagentRegistry.runs.isEmpty)
        #expect(f.runtime.goalPlanningState?.phase == .blocked)
        #expect(f.runtime.goalPlanningState?.members.count == 3)
        #expect(f.runtime.goalPlanningState?.members.allSatisfy { $0.runID == nil && $0.status == .interrupted } == true)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
    }

    @Test("旧成员失败不能暂停新规划 generation")
    func staleFailureCannotPauseNewGeneration() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.app.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _, _, _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        #expect(f.app.startAgentGoalPlanningIfNeeded(for: f.runtime))
        var stale = try #require(f.app.agentSubagentRegistry.runs.first)
        #expect(f.app.startAgentGoalPlanningIfNeeded(for: f.runtime, forceRestart: true))
        let replacement = f.runtime.goalPlanningState
        stale.status = .failed
        stale.requestStop = .admission(.budgetExceeded)
        #expect(f.app.handleAgentGoalPlanningSubagentCompletion(stale))
        #expect(f.runtime.goalPlanningState == replacement)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused != true)
    }

    @Test("目标评估拒绝后不切换候选模型", arguments: [true, false])
    func assessmentDoesNotFallbackOnAdmissionFailure(_ hasGoal: Bool) async throws {
        let f = try fixture(); defer { f.cleanup() }
        if !hasGoal { f.runtime.currentGoal = nil }
        var calls = 0
        var observed: AgentToolExecutionBudget?
        f.app.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _, _, context, _ in
            calls += 1
            observed = context.executionBudget
            throw AgentModelRequestLedger.Failure.unknownExposure
        }
        await #expect(throws: AgentModelRequestLedger.Failure.unknownExposure) {
            _ = try await f.app.assessDispatchGoal(statement: "bounded assessment",
                planningProfileID: AgentExecutionProfile.recommendedPlannerID,
                planningFallbackProfileIDs: [AgentExecutionProfile.recommendedWorkerID])
        }
        #expect(calls == 1)
        #expect((observed != nil) == hasGoal)
    }
}
