import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("停止的宿主生命周期", .serialized, .timeLimit(.minutes(1)))
struct AgentStopLifecycleTests {
    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let turnID: UUID
        func cleanup() {
            runtime.stopCleanupObservers.values.forEach { $0.cancel() }
            runtime.stopCleanupObservers.removeAll()
            app.agentJobRegistry.killAllAlive(forRuntime: runtime.id)
            app.dispatchDecisionResumptionTask?.cancel()
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Stop fixture cleanup: \(error)") }
        }
    }

    private func fixture() throws -> Fixture {
        let suite = "stop-lifecycle-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let runtime = AgentRuntime(session: .init())
        let turnID = UUID()
        runtime.activeTurnID = turnID
        runtime.isResponding = true
        runtime.activeTurnConfiguration = .init(providerID: "openai", baseURL: "https://stop-fixture.invalid/v1",
            model: "fixture", apiKey: "test-placeholder")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stop-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return .init(app: app, runtime: runtime, root: root, defaults: defaults, suite: suite, turnID: turnID)
    }

    @Test("真实 Stop 立即发信号、保留独立与旧轮次进程，旧回执不修改新目标")
    func stopUsesRegisteredOwnership() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let registry = f.app.agentJobRegistry
        var notices: [UUID] = []
        registry.onJobFinished = { notices.append($0.id) }
        func process(turn: UUID, independent: Bool = false, lifetime: AgentBackgroundJobLifetime = .turn) throws -> AgentBackgroundJob {
            try registry.start(command: "sleep 60", workingDirectory: f.root, runtimeID: f.runtime.id,
                turnID: turn, timeoutSeconds: nil, sandboxMode: .escalated,
                lifetime: lifetime, survivesTurnStop: independent)
        }
        let local = try process(turn: f.turnID)
        let inferredPersistent = try process(turn: f.turnID, lifetime: .persistent)
        let independent = try process(turn: f.turnID, independent: true, lifetime: .persistent)
        let older = try process(turn: UUID())
        let foreignRuntime = UUID()
        defer { registry.killAllAlive(forRuntime: foreignRuntime) }
        let managedCancelled = DispatchSemaphore(value: 0)
        let foreignCancelled = DispatchSemaphore(value: 0)
        _ = registry.registerManagedExecutor(executor: .codexCLI, displayCommand: "managed fixture",
            workingDirectory: f.root, runtimeID: f.runtime.id, turnID: f.turnID,
            timeoutSeconds: nil, publishesCompletion: true, cancellation: { managedCancelled.signal() })
        _ = registry.registerManagedExecutor(executor: .codexCLI, displayCommand: "foreign fixture",
            workingDirectory: f.root, runtimeID: foreignRuntime, turnID: f.turnID,
            timeoutSeconds: nil, publishesCompletion: false, cancellation: { foreignCancelled.signal() })

        f.app.stopAgentResponse(for: f.runtime)
        #expect(managedCancelled.wait(timeout: .now()) == .success)
        #expect(foreignCancelled.wait(timeout: .now()) == .timedOut)
        #expect(f.runtime.stopCleanupObservers[f.turnID] != nil)
        let event = try #require(f.runtime.messages.last)
        #expect(event.content == L10n.StopLifecycle.status(pendingLocal: 2, stoppedLocal: 0, managedRequested: 1, retained: 1))
        f.app.stopAgentResponse(for: f.runtime)
        #expect(f.runtime.messages.filter { $0.transcriptEvent == .responseStopped }.count == 1)
        #expect(managedCancelled.wait(timeout: .now()) == .timedOut)

        // A new response may begin while native TERM -> exit is still pending.
        f.runtime.activeTurnID = UUID()
        f.runtime.userStoppedTurnID = nil
        f.runtime.currentGoal = .init(statement: "Replacement", checklist: [.init(text: "Unfinished")])
        f.runtime.messages.append(.init(role: .assistant, content: "New response"))
        let deadline = Date().addingTimeInterval(45)
        while f.runtime.stopCleanupObservers[f.turnID] != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.runtime.stopCleanupObservers.isEmpty)
        #expect(registry.job(id: local.id)?.isAlive == false)
        #expect(registry.job(id: inferredPersistent.id)?.isAlive == false)
        #expect(registry.job(id: independent.id)?.isAlive == true)
        #expect(registry.job(id: older.id)?.isAlive == true)
        #expect(f.runtime.messages.first { $0.id == event.id }?.content
            == L10n.StopLifecycle.status(pendingLocal: 0, stoppedLocal: 2, managedRequested: 1, retained: 1))
        #expect(f.runtime.messages.last?.content == "New response")
        #expect(f.runtime.currentGoal?.statement == "Replacement")
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        #expect(f.runtime.isResponding)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
        #expect(registry.pendingCompletionCount(forRuntime: f.runtime.id) == 0)
        #expect(notices.isEmpty)
    }

    @Test("点击 Stop 后拒收正文、思考与工具增量，保留点击前已接收的内容")
    func stoppedStreamRejectsLateEvents() throws {
        let f = try fixture(); defer { f.cleanup() }
        let message = AgentMessage(role: .assistant, content: "已输出")
        f.runtime.messages.append(message)
        let buffer = AgentStreamingMessageBuffer(runtime: f.runtime, assistantID: message.id)
        buffer.appendTextDelta("，停止前")
        buffer.appendReasoningDelta("已接收的思考")
        #expect(f.runtime.acceptsResponseEvents(for: f.turnID))

        f.app.stopAgentResponse(for: f.runtime)

        #expect(f.runtime.isStoppingResponse)
        #expect(!f.runtime.acceptsResponseEvents(for: f.turnID))
        buffer.appendTextDelta("不应出现")
        buffer.appendReasoningDelta("不应继续思考")
        buffer.updateToolCalls([.init(externalID: "late", toolName: "run_command", argumentsJSON: "{}")])
        buffer.flushPending()
        let preserved = try #require(f.runtime.messages.first { $0.id == message.id })
        #expect(preserved.content == "已输出，停止前")
        #expect(preserved.reasoningContent == "已接收的思考")
        #expect(preserved.toolCalls.isEmpty)

        let nextTurn = UUID()
        f.runtime.activeTurnID = nextTurn
        f.runtime.userStoppedTurnID = nil
        #expect(f.runtime.acceptsResponseEvents(for: nextTurn))
        #expect(!f.runtime.acceptsResponseEvents(for: f.turnID))
        buffer.appendTextDelta("旧连接不能写入新轮次")
        buffer.flushPending()
        #expect(f.runtime.messages.first { $0.id == message.id }?.content == preserved.content)
    }

    @Test("没有排队消息时 Stop 也收回卡住的请求和 provider 槽位")
    func stopWithoutQueueReleasesStuckTurn() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let provider = "stop-fixture"
        #expect(f.app.acquireProviderSlotIfPossible(providerID: provider))
        _ = f.app.claimProviderSlot(for: f.runtime, providerID: provider)
        f.runtime.turnStartedAt = Date()
        f.runtime.requestTask = Task {}
        f.app.stopAgentResponse(for: f.runtime)
        #expect(!f.runtime.shouldConsumeQueueAfterStop)

        await f.app.scheduleQueuedMessageConsumptionAfterCancellation(
            for: f.runtime, fallbackPollAttempts: 1, fallbackPollIntervalNanoseconds: 0
        ).value

        #expect(!f.runtime.isResponding)
        #expect(f.runtime.requestTask == nil)
        #expect(f.runtime.activeTurnID == nil)
        #expect(f.runtime.turnStartedAt == nil)
        #expect(f.runtime.currentProviderSlotClaim == nil)
        #expect(f.app.inFlightCountByProvider[provider] == nil)
        #expect(f.runtime.messages.last?.transcriptEvent == .responseStopped)
    }

    @Test("主动停止包含未执行工具的回合不会被 watchdog 自动复活")
    func stoppedLoopCleanupDoesNotResumeDanglingTools() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let provider = "stop-fixture"
        #expect(f.app.acquireProviderSlotIfPossible(providerID: provider))
        let claim = f.app.claimProviderSlot(for: f.runtime, providerID: provider)
        f.runtime.messages.append(.init(role: .assistant, content: "",
            toolCalls: [.init(externalID: "unfinished", toolName: "run_command", argumentsJSON: "{}")]))
        f.app.stopAgentResponse(for: f.runtime)
        f.app.finishAgentLoopTurn(for: f.runtime, turnID: f.turnID,
            providerSlotClaimID: claim.id, providerID: provider, shouldResumePendingEvents: true)
        await Task.yield()
        #expect(f.runtime.turnInterruptionAutoResumeCount == 0)
        #expect(f.runtime.errorMessage == nil)
        #expect(!f.runtime.isResponding)
        #expect(f.runtime.requestTask == nil)
        #expect(f.runtime.currentProviderSlotClaim == nil)
        #expect(f.runtime.messages.last?.transcriptEvent == .responseStopped)
    }

    @Test("旧 Stop 的兜底与迟到收尾不能清理新轮次")
    func staleStopCleanupPreservesReplacementTurn() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let provider = "stop-fixture"
        #expect(f.app.acquireProviderSlotIfPossible(providerID: provider))
        let oldClaim = f.app.claimProviderSlot(for: f.runtime, providerID: provider)
        f.app.stopAgentResponse(for: f.runtime)
        let fallback = f.app.scheduleQueuedMessageConsumptionAfterCancellation(
            for: f.runtime, fallbackPollAttempts: 1, fallbackPollIntervalNanoseconds: 0)
        f.app.releaseProviderSlot(for: f.runtime, claimID: oldClaim.id, providerID: provider)
        #expect(f.app.acquireProviderSlotIfPossible(providerID: provider))
        let newClaim = f.app.claimProviderSlot(for: f.runtime, providerID: provider)
        let newTurn = UUID()
        f.runtime.activeTurnID = newTurn
        f.runtime.userStoppedTurnID = nil
        f.runtime.requestTask = Task {}
        await fallback.value
        f.app.finishAgentLoopTurn(for: f.runtime, turnID: f.turnID,
            providerSlotClaimID: oldClaim.id, providerID: provider, shouldResumePendingEvents: true)
        #expect(f.runtime.isResponding)
        #expect(f.runtime.activeTurnID == newTurn)
        #expect(f.runtime.requestTask != nil)
        #expect(f.runtime.currentProviderSlotClaim?.id == newClaim.id)
        #expect(f.app.inFlightCountByProvider[provider] == 1)
        f.app.releaseProviderSlot(for: f.runtime, claimID: newClaim.id, providerID: provider)
    }

    @Test("没有进程时 Stop 也撤销晚到的本轮启动，不创建文件或句柄")
    func stoppedTurnCannotLaunchLateWork() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.app.stopAgentResponse(for: f.runtime)
        let registry = f.app.agentJobRegistry
        let marker = f.root.appendingPathComponent("must-not-exist")
        let script = "File.write(ARGV.first, 'unexpected')"
        let context = AgentToolContext(rootDirectory: f.root, runtimeID: f.runtime.id,
            turnID: f.turnID, jobRegistry: registry, sandboxMode: .escalated)
        await #expect(throws: CancellationError.self) {
            _ = try await AgentToolRunner.run(name: "run_command",
                arguments: ["command": .string("/usr/bin/ruby -e \"\(script)\" \"\(marker.path)\""), "run_in_background": .bool(true)],
                context: context)
        }
        #expect(throws: CancellationError.self) {
            _ = try registry.startExecutor(specification: .init(executor: .codexCLI,
                executableURL: URL(fileURLWithPath: "/usr/bin/ruby"), arguments: ["-e", script, marker.path],
                workingDirectory: f.root, environment: ["PATH": "/usr/bin:/bin"], standardInput: Data(),
                sandboxMode: .escalated, displayCommand: "late fixture", decoder: CodexJSONLEventDecoder()),
                runtimeID: f.runtime.id, turnID: f.turnID, timeoutSeconds: nil)
        }
        let cancelled = DispatchSemaphore(value: 0)
        let rejected = registry.registerManagedExecutor(executor: .codexCLI, displayCommand: "late managed fixture",
            workingDirectory: f.root, runtimeID: f.runtime.id, turnID: f.turnID, timeoutSeconds: nil,
            publishesCompletion: false, cancellation: { cancelled.signal() })
        #expect(!rejected.isAlive)
        #expect(cancelled.wait(timeout: .now()) == .success)
        #expect(registry.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("撤销绑定 runtime 与轮次，不能影响其他会话或新的轮次")
    func revocationDoesNotLeakAcrossOwners() throws {
        let registry = AgentJobRegistry()
        let runtime = UUID(), turn = UUID(), other = UUID(), next = UUID()
        registry.revokeTurn(runtimeID: runtime, turnID: turn)
        #expect(throws: CancellationError.self) { try registry.checkTurnAdmission(runtimeID: runtime, turnID: turn) }
        try registry.checkTurnAdmission(runtimeID: other, turnID: turn)
        try registry.checkTurnAdmission(runtimeID: runtime, turnID: next)
        try registry.checkTurnAdmission(runtimeID: runtime, turnID: nil)
    }

    @Test("实际工具只有显式 persistent 才登记停止后保留", arguments: [false, true])
    func toolRegistersExplicitIndependence(_ persistent: Bool) async throws {
        let f = try fixture(); defer { f.cleanup() }
        var arguments: [String: AgentJSONValue] = ["command": .string("sleep 60"), "run_in_background": .bool(true)]
        if persistent { arguments["lifetime"] = .string("persistent") }
        _ = try await AgentToolRunner.run(name: "run_command", arguments: arguments,
            context: .init(rootDirectory: f.root, runtimeID: f.runtime.id, turnID: f.turnID,
                jobRegistry: f.app.agentJobRegistry, sandboxMode: .escalated))
        let job = try #require(f.app.agentJobRegistry.jobs.first)
        #expect(job.survivesTurnStop == persistent)
    }

    @Test("退出观察器记住已裁剪回执、只完成一次，取消后不回调", arguments: [false, true])
    func observerHandlesPruningAndCancellation(_ cancel: Bool) {
        let registry = AgentJobRegistry(), runtime = UUID()
        func job() -> AgentBackgroundJob {
            registry.registerManagedExecutor(executor: .codexCLI, displayCommand: "observer fixture",
                workingDirectory: FileManager.default.temporaryDirectory, runtimeID: runtime,
                timeoutSeconds: nil, publishesCompletion: false, cancellation: {})
        }
        let first = job(), second = job()
        var callbacks = 0
        let observer = AgentStopCleanupObserver(jobIDs: [first.id, second.id]) { callbacks += 1 }
        observer.start(registry: registry)
        registry.finishManagedExecutor(id: first.id, status: .completed, exitCode: 0)
        #expect(callbacks == 0)
        for _ in 0..<55 {
            let disposable = job()
            registry.finishManagedExecutor(id: disposable.id, status: .completed, exitCode: 0)
        }
        #expect(registry.job(id: first.id) == nil)
        if cancel { observer.cancel() }
        registry.finishManagedExecutor(id: second.id, status: .killed, exitCode: 15)
        registry.finishManagedExecutor(id: second.id, status: .killed, exitCode: 15)
        #expect(callbacks == (cancel ? 0 : 1))
        observer.cancel()
    }
}
