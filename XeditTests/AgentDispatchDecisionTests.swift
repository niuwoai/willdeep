import Foundation
import Testing
@testable import WillDeep

@Suite("调度结构化决定", .serialized)
@MainActor
struct AgentDispatchDecisionTests {
    @MainActor private struct Fixture {
        let app: AppState
        let parent: AgentRuntime
        let first: AgentRuntime
        let second: AgentRuntime
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let firstID: UUID
        let secondID: UUID
        let downstreamID: UUID
        let independentID: UUID
        var coordinator: AgentDispatchCoordinator { app.agentDispatchCoordinator }
        var goal: AgentDispatchGoal { coordinator.goals.first(where: { $0.id == parent.id })! }
        func cleanup() {
            app.dispatchDecisionResumptionTask?.cancel()
            app.dispatchDecisionResumptionTask = nil
            app.invalidateDispatchMonitor(taskID: firstID)
            app.invalidateDispatchMonitor(taskID: secondID)
            for runtime in [parent, first, second] { AgentSessionStore.delete(id: runtime.id) }
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
        func capture(_ runtime: AgentRuntime, scope: String = "project", question: String = "本项目统一使用哪个接口版本？", options: [String] = ["v1", "v2"]) -> UUID? {
            let arguments: [String: AgentJSONValue] = ["question": .string(question), "decision_scope": .string(scope),
                                                       "options": .array(options.map(AgentJSONValue.string))]
            let text = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
            let call = AgentMessageToolCall(externalID: UUID().uuidString, toolName: "ask_user", argumentsJSON: text)
            guard app.captureDispatchDecisions(runtime: runtime, messageID: UUID(), calls: [call]) else { return nil }
            return goal.tasks.first(where: { $0.runtimeSessionID == runtime.id })?.pendingDecisionIDs?.last
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-decision-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "willdeep-dispatch-decisions-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let session = app.startDispatchGoalSession(inWorkspaceAt: root.path)
        let parent = try #require(app.runtime(for: session.id))
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        parent.currentGoal = .init(statement: "交付本地项目", checklist: [.init(text: "交付验证")], dispatchPlan: .init(nodes: [
            .init(id: a, key: "A", title: "实现 A", dependencyIDs: [], primaryProfileID: nil, fallbackProfileIDs: [], acceptanceCriteria: ["A 正确"]),
            .init(id: b, key: "B", title: "实现 B", dependencyIDs: [], primaryProfileID: nil, fallbackProfileIDs: [], acceptanceCriteria: ["B 正确"]),
            .init(id: c, key: "C", title: "消费 A", dependencyIDs: [a], primaryProfileID: nil, fallbackProfileIDs: [], acceptanceCriteria: ["消费 A"]),
            .init(id: d, key: "D", title: "独立任务", dependencyIDs: [], primaryProfileID: nil, fallbackProfileIDs: [], acceptanceCriteria: ["D 正确"])
        ]))
        app.persistAgentSession(runtime: parent)
        app.agentDispatchCoordinator.synchronize(with: app.agentSessions)
        func child(_ taskID: UUID) throws -> AgentRuntime {
            let session = app.startNewAgentSession(inWorkspaceAt: root.path)
            let runtime = try #require(app.runtime(for: session.id))
            runtime.session.dispatchParentProjectID = parent.id
            runtime.session.dispatchTaskID = taskID
            runtime.interactionMode = .goal
            runtime.currentGoal = .init(statement: "执行节点", checklist: [.init(text: "结果正确")])
            runtime.currentPlan = .init(status: .executing)
            app.agentDispatchCoordinator.markTaskStarted(goalID: parent.id, taskID: taskID, executor: .willDeep,
                                                       target: .local, runtimeSessionID: runtime.id)
            return runtime
        }
        return .init(app: app, parent: parent, first: try child(a), second: try child(b), root: root, defaults: defaults,
                     suite: suite, firstID: a, secondID: b, downstreamID: c, independentID: d)
    }

    @Test("项目级相同问题合并一次，任务级问题不跨节点")
    func exactProjectDeduplication() throws {
        let f = try fixture(); defer { f.cleanup() }
        let a = try #require(f.capture(f.first))
        let b = try #require(f.capture(f.second))
        #expect(a == b)
        #expect(f.goal.pendingDecisions.count == 1)
        #expect(f.goal.pendingDecisions.first?.participants.count == 2)
        let one = try #require(f.capture(f.first, scope: "task", question: "节点输出名称？"))
        let two = try #require(f.capture(f.second, scope: "task", question: "节点输出名称？"))
        #expect(one != two)
    }

    @Test("选项不同不合并，回答只落在匹配的决定上")
    func differentOptionsAndImmutableAnswer() throws {
        let f = try fixture(); defer { f.cleanup() }
        let a = try #require(f.capture(f.first))
        let b = try #require(f.capture(f.second, options: ["v2", "v3"]))
        #expect(a != b)
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: a, answer: "v2"))
        #expect(!f.coordinator.answerDecision(goalID: f.parent.id, decisionID: a, answer: "v1"))
        #expect(f.goal.decisions?.first(where: { $0.id == b })?.answer == nil)
    }

    @Test("刷新和依赖解锁不能把等待回答的节点重新排队")
    func waitingSurvivesProjectionAndDependencyUpdates() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try #require(f.capture(f.first))
        f.coordinator.synchronize(with: f.app.agentSessions)
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.secondID, state: .merged)
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.firstID, state: .queued)
        #expect(f.goal.tasks.first(where: { $0.id == f.firstID })?.state == .blocked)
        #expect(f.goal.tasks.first(where: { $0.id == f.downstreamID })?.state == .blocked)
        #expect(f.goal.pendingDecisions.count == 1)
    }

    @Test("整批问题先持久化，旁边的写工具不执行，协议结果不缺项")
    func interceptsWholeBatchBeforeEffects() throws {
        let f = try fixture(); defer { f.cleanup() }
        let ask = AgentMessageToolCall(externalID: "ask", toolName: "ask_user", argumentsJSON: #"{"question":"使用哪个版本？"}"#)
        let write = AgentMessageToolCall(externalID: "write", toolName: "create_file",
            argumentsJSON: #"{"path":"must-not-exist","content":"wrong"}"#)
        #expect(f.app.captureDispatchDecisions(runtime: f.first, messageID: UUID(), calls: [write, ask]))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("must-not-exist").path))
        #expect(f.first.toolCalls.map(\.externalID) == ["write", "ask"])
        #expect(f.first.messages.compactMap(\.toolCallID) == ["write", "ask"])
        #expect(f.first.toolCalls.first?.status == .denied)
        #expect(f.app.hasPendingDispatchDecisions(f.first))
        #expect(!f.app.goalOwnsAutomaticContinuation(for: f.first))
        let count = f.first.messages.count
        f.app.dispatchAgentMessage(for: f.first, text: "automatic retry", images: [], source: .hostInstruction)
        #expect(f.first.requestTask == nil)
        #expect(f.first.messages.count == count)
    }

    @Test("全部回答齐备才准备续跑，重放不重复插入，也不生成权限")
    func allAnswersRequiredAndIdempotentDelivery() throws {
        let f = try fixture(); defer { f.cleanup() }
        let a = try #require(f.capture(f.first))
        let b = try #require(f.capture(f.first, question: "输出格式？", options: ["json", "text"]))
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: a, answer: "v2"))
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID) == nil)
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: b, answer: "json"))
        let message = try #require(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID))
        let count = f.first.messages.count
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID)?.id == message.id)
        #expect(f.first.messages.count == count)
        #expect(message.content.contains("does not grant new tool permissions"))
        #expect(f.first.currentGoal?.taskAuthorizations == nil)
        #expect(f.first.toolCalls.allSatisfy { $0.approvalSource == nil })
    }

    @Test("暂停只保存回答；停止节点不会被回答复活")
    func pauseAndStopAreRespected() throws {
        let f = try fixture(); defer { f.cleanup() }
        let id = try #require(f.capture(f.first))
        _ = f.coordinator.setPaused(true, goalID: f.parent.id)
        f.app.answerDispatchDecision(goalID: f.parent.id, decisionID: id, answer: "v2")
        #expect(f.goal.decisions?.first?.answer == "v2")
        #expect(f.first.requestTask == nil)
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID) == nil)
        _ = f.coordinator.setPaused(false, goalID: f.parent.id)
        #expect(f.app.stopDispatchTask(goalID: f.parent.id, taskID: f.firstID))
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID) == nil)
        #expect(f.goal.tasks.first(where: { $0.id == f.firstID })?.state == .cancelled)
    }

    @Test("运行实例或工作区改变时旧回答不恢复执行")
    func staleRuntimeOrWorkspaceRejected() throws {
        let f = try fixture(); defer { f.cleanup() }
        let id = try #require(f.capture(f.first))
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: id, answer: "v2"))
        f.first.rebindWorkspace(to: f.root.appendingPathComponent("other").path)
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID) == nil)
        #expect(f.coordinator.answeredDecisions(goalID: f.parent.id, taskID: f.firstID, runtimeID: UUID()) == nil)
    }

    @Test("等待期间切换到外部执行器，不通过原生入口偷偷续跑")
    func changedExecutorDoesNotResumeNatively() throws {
        let f = try fixture(); defer { f.cleanup() }
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.secondID, state: .merged)
        let id = try #require(f.capture(f.first))
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: id, answer: "v2"))
        f.first.executionAgent = .codexCLI
        let count = f.first.messages.count
        #expect(!f.app.resumeAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID))
        #expect(f.first.messages.count == count)
        #expect(f.first.requestTask == nil)
        #expect(f.goal.tasks.first(where: { $0.id == f.firstID })?.state == .blocked)
        #expect(f.capture(f.first, question: "外部问题？") == nil)
        #expect(f.goal.decisions?.count == 1)
    }

    @Test("答案已保存但资源仍占用时不插入消息、不启动；释放后重新准入")
    func answeredTaskRechecksReservations() throws {
        let f = try fixture(); defer { f.cleanup() }
        let id = try #require(f.capture(f.first))
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: id, answer: "v2"))
        let count = f.first.messages.count
        #expect(!f.app.resumeAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID))
        #expect(f.first.messages.count == count)
        #expect(f.first.requestTask == nil)
        #expect(f.goal.decisions?.first?.answer == "v2")
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.secondID, state: .merged)
        #expect(f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.firstID))
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID) != nil)
        #expect(f.coordinator.resumeAnsweredTask(goalID: f.parent.id, taskID: f.firstID, runtimeID: f.first.id))
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.independentID))
    }

    @Test("手动启动不能跳过共享工作区准入或创建额外运行实例")
    func manualStartUsesAdmission() throws {
        let f = try fixture(); defer { f.cleanup() }
        let count = f.app.agentSessions.count
        let result = f.app.launchDispatchTask(goalID: f.parent.id, taskID: f.independentID)
        guard case .blocked = result else { Issue.record("A busy shared workspace must reject manual launch"); return }
        #expect(f.app.agentSessions.count == count)
        #expect(f.goal.tasks.first(where: { $0.id == f.independentID })?.runtimeSessionID == nil)
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.downstreamID))
    }

    @Test("取消状态不提前释放仍在退场的执行实例；目标本身也不能并行重启")
    func retiringRuntimeKeepsReservation() throws {
        let f = try fixture(); defer { f.cleanup() }
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.secondID, state: .merged)
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.firstID, state: .cancelled)
        f.first.isResponding = true
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.independentID))
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.firstID))
        f.first.isResponding = false
        #expect(f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.independentID))
    }

    @Test("同一运行可沿用自己的后台服务，替换运行必须等待服务退出")
    func ownBackgroundServiceDoesNotDeadlockContinuation() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try #require(f.capture(f.first))
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.secondID, state: .merged)
        let job = f.app.agentJobRegistry.registerManagedExecutor(executor: .willDeep, displayCommand: "owned test service",
            workingDirectory: f.root, runtimeID: f.first.id, timeoutSeconds: nil, publishesCompletion: false, cancellation: {})
        defer { f.app.agentJobRegistry.finishManagedExecutor(id: job.id, status: .completed, exitCode: 0) }
        #expect(f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.firstID, continuingRuntimeID: f.first.id))
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.firstID))
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.independentID))
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.firstID, continuingRuntimeID: UUID()))
    }

    @Test("关闭完成通知的后台执行器退出仍会触发资源检查")
    func suppressedCompletionStillSchedulesResourceCheck() async throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try #require(f.capture(f.first))
        let job = f.app.agentJobRegistry.registerManagedExecutor(executor: .willDeep, displayCommand: "silent test service",
            workingDirectory: f.root, runtimeID: f.second.id, timeoutSeconds: nil, publishesCompletion: false, cancellation: {})
        defer { f.app.agentJobRegistry.finishManagedExecutor(id: job.id, status: .completed, exitCode: 0) }
        for _ in 0..<100 where f.app.dispatchDecisionResumptionTask != nil { await Task.yield() }
        try #require(f.app.dispatchDecisionResumptionTask == nil)
        f.app.agentJobRegistry.finishManagedExecutor(id: job.id, status: .completed, exitCode: 0)
        #expect(f.app.dispatchDecisionResumptionTask != nil)
        #expect(f.app.agentJobRegistry.pendingCompletionCount(forRuntime: f.second.id) == 0)
        for _ in 0..<100 where f.app.dispatchDecisionResumptionTask != nil { await Task.yield() }
        #expect(f.app.dispatchDecisionResumptionTask == nil)
        #expect(f.first.requestTask == nil)
    }

    @Test("验收监控持有节点时不能手动再启动另一个运行")
    func verificationLeaseCannotBeReplacedByManualLaunch() throws {
        let f = try fixture(); defer { f.cleanup() }
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.secondID, state: .merged)
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.firstID, state: .reviewing)
        _ = f.app.beginDispatchMonitor(runtimeID: f.first.id, taskID: f.firstID)
        #expect(!f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.firstID))
        f.app.invalidateDispatchMonitor(taskID: f.firstID)
        #expect(f.app.dispatchAdmissionIsAvailable(goalID: f.parent.id, taskID: f.firstID))
    }

    @Test("节点指令将必要决定交给宿主，不要求用户代做验证")
    func promptUsesHostQuestionProtocol() throws {
        let f = try fixture(); defer { f.cleanup() }
        let task = try #require(f.goal.tasks.first(where: { $0.id == f.firstID }))
        let prompt = AppState.dispatchTaskPrompt(goal: f.goal, task: task, workspaceLocation: .local(path: f.root.path))
        #expect(prompt.contains("ask_user"))
        #expect(prompt.contains("decision_scope=project"))
        #expect(prompt.contains("Do not request routine execution confirmation"))
        #expect(prompt.contains("Do not request secrets"))
    }

    @Test("资源变化合并为一次事件检查，不能重复启动或轮询未回答节点")
    func resumptionEventsAreCoalescedAndQuiescent() async throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try #require(f.capture(f.first))
        for _ in 0..<20 { f.app.scheduleDispatchDecisionResumption() }
        #expect(f.app.dispatchDecisionResumptionTask != nil)
        for _ in 0..<100 where f.app.dispatchDecisionResumptionTask != nil { await Task.yield() }
        #expect(f.app.dispatchDecisionResumptionTask == nil)
        #expect(f.first.requestTask == nil)
        #expect(f.goal.tasks.first(where: { $0.id == f.firstID })?.state == .blocked)
        for _ in 0..<10 { await Task.yield() }
        #expect(f.app.dispatchDecisionResumptionTask == nil)
    }

    @Test("回答 outbox 可跨持久化恢复，即使会话中尚无回答也不丢失")
    func durableAnswerOutbox() throws {
        let f = try fixture(); defer { f.cleanup() }
        let id = try #require(f.capture(f.first))
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: id, answer: "v2"))
        #expect(f.coordinator.resumeAnsweredTask(goalID: f.parent.id, taskID: f.firstID, runtimeID: f.first.id))
        let restored = AgentDispatchCoordinator(store: AgentDispatchStore(defaults: f.defaults))
        #expect(restored.answeredDecisions(goalID: f.parent.id, taskID: f.firstID, runtimeID: f.first.id, includingResumed: true)?.first?.answer == "v2")
        let answer = try #require(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id,
                                                                      taskID: f.firstID, includingResumed: true))
        #expect(answer.content.contains("v2"))
        #expect(f.goal.tasks.first(where: { $0.id == f.firstID })?.pendingDecisionIDs == nil)
    }

    @Test("挂起节点的执行尚未退出时，继续持有共享工作区资源")
    func pendingNodeRetainsResourcesUntilExit() throws {
        let f = try fixture(); defer { f.cleanup() }
        _ = try #require(f.capture(f.first))
        f.coordinator.updateTaskState(goalID: f.parent.id, taskID: f.secondID, state: .merged)
        f.first.isResponding = true
        #expect(!f.app.readyDispatchTaskIDs(goalID: f.parent.id, capacity: 4).contains(f.independentID))
        f.first.isResponding = false
        #expect(f.app.readyDispatchTaskIDs(goalID: f.parent.id, capacity: 4).contains(f.independentID))
    }

    @Test("原始问题被完整保存，不截断后误合并，不接受空问题")
    func questionValidation() {
        #expect(AgentDispatchDecision.Question(arguments: ["question": .string("")]) == nil)
        #expect(AgentDispatchDecision.Question(arguments: ["question": .string(String(repeating: "x", count: 4_001))]) == nil)
        let question = AgentDispatchDecision.Question(arguments: ["question": .string("范围？"), "requested_information": .array([.string("文件范围")]),
            "default_assumptions": .array([.string("不发布")]), "multi_select": .bool(true)])
        #expect(question?.scope == .task)
        #expect(question?.requestedInformation == ["文件范围"])
        #expect(question?.defaultAssumptions == ["不发布"])
        #expect(question?.multiSelect == true)
    }

    @Test("同一个 provider 调用重放只保留一个参与者")
    func replayedCallIsIdempotent() throws {
        let f = try fixture(); defer { f.cleanup() }
        let question = try #require(AgentDispatchDecision.Question(arguments: ["question": .string("版本？")]))
        let a = f.coordinator.recordDecision(goalID: f.parent.id, taskID: f.firstID, runtimeID: f.first.id,
            externalCallID: "same-call", workspace: .local(path: f.root.path), question: question)
        let b = f.coordinator.recordDecision(goalID: f.parent.id, taskID: f.firstID, runtimeID: f.first.id,
            externalCallID: "same-call", workspace: .local(path: f.root.path), question: question)
        #expect(a != nil && a == b)
        #expect(f.goal.decisions?.first?.participants.count == 1)
    }

    @Test("目标改写使旧问题失效，不能用迟到答案启动旧任务")
    func rewrittenGoalInvalidatesWaitingContract() throws {
        let f = try fixture(); defer { f.cleanup() }
        let id = try #require(f.capture(f.first))
        f.parent.currentGoal?.statement = "另一个交付目标"
        f.app.persistAgentSession(runtime: f.parent)
        f.coordinator.synchronize(with: f.app.agentSessions)
        #expect(!f.coordinator.answerDecision(goalID: f.parent.id, decisionID: id, answer: "v2"))
        #expect(f.goal.tasks.first(where: { $0.id == f.firstID })?.state == .cancelled)
        #expect(f.app.dispatchContinuationIsSuspended(f.first))
    }

    @Test("子任务目标被改写或预算耗尽，回答不扩大或刷新执行权限")
    func childContractAndBudgetArePreserved() throws {
        let f = try fixture(); defer { f.cleanup() }
        let id = try #require(f.capture(f.first))
        #expect(f.coordinator.answerDecision(goalID: f.parent.id, decisionID: id, answer: "v2"))
        let original = f.first.currentGoal
        f.first.currentGoal?.statement = "扩大范围"
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID) == nil)
        f.first.currentGoal = original
        f.first.currentGoal?.continuationBudget = .init(wallClockLimit: 1, segmentStartedAt: .distantPast)
        #expect(f.app.prepareAnsweredDispatchDecision(runtime: f.first, goalID: f.parent.id, taskID: f.firstID) == nil)
        #expect(f.first.currentGoal?.continuationBudget?.segmentStartedAt == .distantPast)
    }
}
