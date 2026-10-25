import Foundation
import Testing
@testable import WillDeep

@Suite("人工等待让出与恢复")
@MainActor
struct AgentHumanWaitTests {
    @Test("超时边界与关闭配置")
    func timeoutBoundary() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(!AgentHumanWaitPolicy.shouldYield(presentedAt: start, now: start.addingTimeInterval(299), seconds: 300, hasQueue: true))
        #expect(AgentHumanWaitPolicy.shouldYield(presentedAt: start, now: start.addingTimeInterval(300), seconds: 300, hasQueue: true))
        #expect(!AgentHumanWaitPolicy.shouldYield(presentedAt: start, now: start.addingTimeInterval(600), seconds: 0, hasQueue: true))
        #expect(!AgentHumanWaitPolicy.shouldYield(presentedAt: start, now: start.addingTimeInterval(600), seconds: 300, hasQueue: false))
    }

    @Test("只接受严格且无阻塞项的独立判定")
    func conservativeDependencyParsing() {
        #expect(AgentHumanWaitPolicy.isIndependent(#"{"decision":"independent","blocking_ids":[]}"#))
        for output in ["yes", #"{"decision":"unknown","blocking_ids":[]}"#, #"{"decision":"independent","blocking_ids":["gate"]}"#, #"{"decision":"independent","blocking_ids":[],"approve":true}"#] {
            #expect(!AgentHumanWaitPolicy.isIndependent(output))
        }
    }

    @Test("队列及独立任务引用可以持久化，并兼容旧会话")
    func queueRoundTrip() throws {
        var session = AgentSession()
        session.pendingMessages = [AgentQueuedMessage(text: "保留的消息", textAttachments: [.init(filename: "note", content: "context")])]
        session.deferredTaskSessionIDs = [UUID()]
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.pendingMessages == session.pendingMessages)
        #expect(decoded.deferredTaskSessionIDs == session.deferredTaskSessionIDs)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        legacy.removeValue(forKey: "pendingMessages")
        legacy.removeValue(forKey: "deferredTaskSessionIDs")
        let old = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.pendingMessages.isEmpty)
        #expect(old.deferredTaskSessionIDs.isEmpty)
    }

    @Test("人工等待释放并发名额，恢复时重新获取且只释放一次")
    func providerSlotAccounting() throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        let runtime = try #require(app.agentRuntimes[session.id])
        defer { AgentSessionStore.delete(id: session.id) }
        let provider = "deferred-test-provider"
        #expect(app.acquireProviderSlotIfPossible(providerID: provider))
        let claim = app.claimProviderSlot(for: runtime, providerID: provider)
        app.suspendProviderSlotForHumanWait(runtime)
        app.suspendProviderSlotForHumanWait(runtime)
        #expect((app.inFlightCountByProvider[provider] ?? 0) == 0)
        #expect(app.prepareDeferredHumanDecision(runtime: runtime, callID: UUID(), decision: .answered("answer")))
        #expect(app.inFlightCountByProvider[provider] == 1)
        app.releaseProviderSlot(for: runtime, claimID: claim.id, providerID: provider)
        #expect((app.inFlightCountByProvider[provider] ?? 0) == 0)
    }

    @Test("分类器拒绝截断输出与没有完成标记的输出")
    func rejectsIncompleteClassification() async {
        let collector = AgentHumanWaitClassifierOutput()
        await collector.consume(.textDelta(#"{"decision":"independent","blocking_ids":[]}"#))
        #expect(await collector.value == nil)
        await collector.consume(.finishedTurn("length"))
        #expect(await collector.value == nil)
        let complete = AgentHumanWaitClassifierOutput()
        await complete.consume(.textDelta(#"{"decision":"independent","blocking_ids":[]}"#))
        await complete.consume(.finishedTurn("stop"))
        #expect(await complete.value != nil)
    }

    @Test("切换多条会话不会逐出仍有独立任务的原会话")
    func activeGroupSurvivesRuntimeEviction() throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        let root = try #require(app.agentRuntimes[session.id])
        let child = AgentRuntime(session: AgentSession(presentationScope: .deferredTask))
        child.isResponding = true
        child.deferredParentRuntimeID = root.id
        root.deferredChildren = [child]
        app.agentRuntimes[child.id] = child
        var ids = [root.id, child.id]
        defer { child.isResponding = false; ids.forEach { AgentSessionStore.delete(id: $0) } }
        for _ in 0..<8 { ids.append(app.startNewAgentSession().id) }
        app.evictInactiveAgentRuntimesIfNeeded()
        #expect(app.agentRuntimes[root.id] != nil)
        #expect(app.agentRuntimes[child.id] != nil)
    }

    @Test("依赖不明确时保留队列并收起原卡片，不自动重新打开或作答")
    func unknownDependencyKeepsTheCardParked() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        let root = try #require(app.agentRuntimes[session.id])
        defer { root.deferredGateMonitor?.cancel(); root.cancelToolDecisions(reason: "Test cleanup"); AgentSessionStore.delete(id: session.id) }
        let call = AgentToolCall(messageID: UUID(), externalID: "retained", toolName: "ask_user", arguments: [:], risk: .userInput, status: .awaitingUserAnswer)
        root.toolCalls = [call]
        root.isResponding = true
        let waiter = Task { await app.awaitToolDecision(for: root, forCallID: call.id) }
        while root.toolDecisionWaiters[call.id] == nil { await Task.yield() }
        let message = AgentQueuedMessage(text: "needs attachment context", textAttachments: [.init(content: "context")])
        root.queuedMessages = [message]
        root.expeditedIndependentMessages.insert(message.id)
        for _ in 0..<2 { await app.serviceDeferredHumanGates(root: root, now: Date()) }
        #expect(root.parkedGateIDs.contains(call.id))
        #expect(root.toolDecisionWaiters[call.id] != nil)
        #expect(root.queuedMessages.map(\.id) == [message.id])
        #expect(root.deferredChildren.isEmpty)
        root.cancelToolDecisions(reason: "Test cleanup")
        _ = await waiter.value
        root.isResponding = false
    }

    @Test("独立消息先持久保存正文和附件，再离开原队列；并发排队不重复正文")
    func independentInputIsDurableBeforeProviderAdmission() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        let root = try #require(app.agentRuntimes[session.id])
        let providerID = app.configurationForCurrentTurn(for: root).providerID
        let slots = app.perProviderConcurrencyLimit
        for _ in 0..<slots { #expect(app.acquireProviderSlotIfPossible(providerID: providerID)) }
        defer {
            root.deferredGateMonitor?.cancel()
            app.stopDeferredHumanGateWork(for: root)
            root.cancelToolDecisions(reason: "Test cleanup")
            for _ in 0..<slots { app.abandonProviderSlotReservation(providerID: providerID) }
            ([root] + root.deferredChildren).forEach { AgentSessionStore.delete(id: $0.id) }
        }
        let call = AgentToolCall(messageID: UUID(), externalID: "original", toolName: "ask_user", arguments: [:], risk: .userInput, status: .awaitingUserAnswer)
        root.toolCalls = [call]
        root.isResponding = true
        let waiter = Task { await app.awaitToolDecision(for: root, forCallID: call.id) }
        while root.toolDecisionWaiters[call.id] == nil { await Task.yield() }
        let attachment = AgentTextAttachment(filename: "context.txt", content: "retained attachment", createdAt: Date(timeIntervalSince1970: 1000))
        var message = AgentQueuedMessage(text: "independent input", textAttachments: [attachment])
        message.independentOfHumanWait = true
        root.queuedMessages = [message]
        root.expeditedIndependentMessages.insert(message.id)
        await app.serviceDeferredHumanGates(root: root, now: Date())
        let child = try #require(root.deferredChildren.first)
        let saved = try #require(AgentSessionStore.load(id: child.id))
        #expect(root.queuedMessages.isEmpty)
        #expect(saved.messages.filter(\.isOperatorInput).map(\.content) == [message.text])
        #expect(saved.messages.first(where: \.isOperatorInput)?.textAttachments == [attachment])
        #expect(child.messages.filter(\.isOperatorInput).count == 1)
        root.cancelToolDecisions(reason: "Test cleanup")
        _ = await waiter.value
        root.isResponding = false
    }

    @Test("共享配置读取与负值校验")
    func sharedConfiguration() {
        #expect(AgentSharedRuntimeConfig.parse("[agent]\nhuman_wait_yield_seconds = 0\n").humanWaitYieldSeconds == 0)
        #expect(AgentSharedRuntimeConfig.parse("[agent]\nhuman_wait_yield_seconds = -1\n").runtimeParameterErrors.contains("human_wait_yield_seconds"))
        #expect(AgentSharedRuntimeConfig.parse("[agent]\nhuman_wait_yield_seconds = 1.5\n").runtimeParameterErrors.contains("human_wait_yield_seconds"))
    }

    @Test("新任务运行中提交旧回答，不提前恢复，也不串到新任务")
    func bufferedAnswerResumesAtSafeBoundary() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        let root = try #require(app.agentRuntimes[session.id])
        let childSession = AgentSession(presentationScope: .deferredTask)
        let child = AgentRuntime(session: childSession)
        child.deferredParentRuntimeID = root.id
        app.agentRuntimes[child.id] = child
        root.deferredChildren = [child]
        defer {
            root.deferredGateMonitor?.cancel()
            root.cancelToolDecisions(reason: "test cleanup")
            AgentSessionStore.delete(id: session.id)
            AgentSessionStore.delete(id: child.id)
        }
        let call = AgentToolCall(messageID: UUID(), externalID: "original-question", toolName: "ask_user", arguments: [:], risk: .userInput, status: .awaitingUserAnswer)
        root.toolCalls = [call]
        root.isResponding = true
        child.isResponding = true
        let waiter = Task { @MainActor in await app.awaitToolDecision(for: root, forCallID: call.id) }
        while root.toolDecisionWaiters[call.id] == nil { await Task.yield() }
        app.resolveAgentToolCallDecision(id: call.id, decision: .answered("原问题的答案"))
        #expect(root.toolDecisionWaiters[call.id] != nil)
        #expect(root.pendingToolDecisions[call.id] != nil)
        #expect(child.pendingToolDecisions.isEmpty)
        child.isResponding = false
        await app.serviceDeferredHumanGates(root: root, now: Date())
        let result = await waiter.value
        if case .answered(let answer) = result { #expect(answer == "原问题的答案") }
        else { Issue.record("原始回答未恢复") }
        root.isResponding = false
    }
}
