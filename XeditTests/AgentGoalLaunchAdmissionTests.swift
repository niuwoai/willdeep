import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite(.serialized)
struct AgentGoalLaunchAdmissionTests {
    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let network: URLSession
        func cleanup() {
            app.goalLaunchRecoveryTask?.cancel()
            app.cancelPendingGoalLaunchRecovery(for: runtime)
            runtime.requestTask?.cancel()
            app.pendingDispatchQueue.removeAll()
            network.invalidateAndCancel()
            AgentSessionStore.delete(id: runtime.id)
        }
    }

    private func fixture(phase: Bool = false) throws -> Fixture {
        let goal = AgentGoal(statement: "Recover the existing task", checklist: [.init(text: "Verified")])
        let plan = AgentPlan(status: .executing, steps: [.init(text: "Existing work", status: .inProgress)], summary: "")
        var session = AgentSession(interactionMode: .goal, currentPlan: phase ? nil : plan,
            currentGoal: goal, goalTurnRecoveryCheckpoint: phase ? nil : AgentGoalTurnRecoveryCheckpoint())
        if phase {
            session.goalRoadmap = .init(phases: [.init(id: "phase", title: "Existing phase",
                acceptanceCriteria: ["Verified"], status: .planning)])
        }
        let app = AppState(runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            loadSessionCatalog: false)
        app.agentSessions = [session]
        app.markSessionCatalogLoadedForTesting()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalLoopURLProtocol.self]
        let network = URLSession(configuration: configuration)
        app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://launch-admission.invalid/v1",
            model: "fixture", apiKey: "test-placeholder"), network)
        // Recovery is accepted into the real dispatch queue, never a network
        // request. No user concurrency setting is changed by this fixture.
        app.inFlightCountByProvider["openai"] = app.perProviderConcurrencyLimit + 1
        let runtime = try #require(app.runtime(for: session.id))
        return .init(app: app, runtime: runtime, network: network)
    }

    @Test("忙碌不消耗启动恢复，资源事件后只入队一次", arguments: [false, true], ["responding", "slot", "compression", "request", "queued"])
    func busyRecoveryRetriesOnce(phase: Bool, busy: String) async throws {
        let f = try fixture(phase: phase); defer { f.cleanup() }
        switch busy {
        case "responding": f.runtime.isResponding = true
        case "slot": f.runtime.isAwaitingProviderSlot = true
        case "compression": f.runtime.isCompressingContext = true
        case "request": f.runtime.requestTask = Task {}
        default: f.runtime.queuedMessages = [.init(text: "Operator work", images: [], executionAgent: .willDeep, source: .operatorInput)]
        }
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch().isEmpty)
        #expect(AgentGoalLaunchRecoveryCoordinator.shared.isDeferred(f.runtime.id))
        #expect(f.app.pendingDispatchQueue.isEmpty)
        f.runtime.isResponding = false
        f.runtime.isAwaitingProviderSlot = false
        f.runtime.isCompressingContext = false
        f.runtime.requestTask?.cancel()
        f.runtime.requestTask = nil
        f.runtime.queuedMessages.removeAll()
        f.app.releaseProviderSlot(providerID: "openai")
        if busy == "compression" {
            await f.app.goalLaunchRecoveryTask?.value
            #expect(f.app.pendingDispatchQueue.isEmpty)
            f.app.completeLaunchRecoveryCompression(for: f.runtime, succeeded: true)
        }
        await f.app.goalLaunchRecoveryTask?.value
        #expect(f.runtime.isAwaitingProviderSlot && f.runtime.requestTask == nil)
        #expect(f.app.pendingDispatchQueue.filter { $0.runtimeID == f.runtime.id }.count == 1)
        #expect(!AgentGoalLaunchRecoveryCoordinator.shared.isDeferred(f.runtime.id))
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch().isEmpty)
        #expect(f.app.pendingDispatchQueue.count == 1)
    }

    @Test("Stop 取消延期恢复，槽位释放不能重启")
    func stopCancelsDeferredRecovery() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.isResponding = true
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch().isEmpty)
        f.app.stopAgentResponse(for: f.runtime)
        f.runtime.isResponding = false
        f.app.releaseProviderSlot(providerID: "openai")
        await f.app.goalLaunchRecoveryTask?.value
        #expect(f.runtime.goalTurnRecoveryCheckpoint == nil)
        #expect(!AgentGoalLaunchRecoveryCoordinator.shared.isDeferred(f.runtime.id))
        #expect(f.app.pendingDispatchQueue.isEmpty && f.runtime.requestTask == nil)
    }

    @Test("压缩失败不触发延期恢复，也不被其他槽位释放绕过")
    func failedCompressionRemainsDeferred() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.isCompressingContext = true
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch().isEmpty)
        f.runtime.isCompressingContext = false
        f.app.completeLaunchRecoveryCompression(for: f.runtime, succeeded: false)
        f.app.releaseProviderSlot(providerID: "openai")
        await f.app.goalLaunchRecoveryTask?.value
        #expect(f.app.pendingDispatchQueue.isEmpty && f.runtime.requestTask == nil)
        #expect(AgentGoalLaunchRecoveryCoordinator.shared.awaitsCompression(f.runtime.id))
    }

    @Test("预算拒绝不冒充已恢复，也不永久吞掉后续有效尝试")
    func rejectedDispatchDoesNotConsumeClaim() throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.currentGoal?.continuationBudget = .init(modelAdmissionPaused: true)
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch().isEmpty)
        #expect(f.app.pendingDispatchQueue.isEmpty)
        f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused = false
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch() == [f.runtime.id])
        #expect(f.app.pendingDispatchQueue.count == 1 && f.runtime.requestTask == nil)
    }

    @Test("删除会话清除延期登记，其他窗口不为空登记创建重试任务")
    func deletedAndForeignSessionsDoNotScheduleRetry() throws {
        let f = try fixture(); defer { f.cleanup() }
        let other = try fixture(); defer { other.cleanup() }
        f.runtime.isResponding = true
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch().isEmpty)
        #expect(other.app.scheduleDeferredGoalLaunchRecovery() == nil)
        #expect(f.app.deleteAgentSession(id: f.runtime.id, removeFromStore: false))
        #expect(!AgentGoalLaunchRecoveryCoordinator.shared.isDeferred(f.runtime.id))
        #expect(f.app.scheduleDeferredGoalLaunchRecovery() == nil)
    }
}
