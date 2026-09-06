import Foundation
import Testing
@testable import WillDeep

/// Only the HTTP provider is substituted. Dispatch, SSE decoding, real file
/// tools, round boundaries, provider slots and automatic queue draining run
/// through the same implementation as an interactive Goal.
@MainActor
@Suite("Goal 真实主循环轨迹", .serialized, .timeLimit(.minutes(3)))
struct AgentGoalMainLoopTests {
    /// URLProtocol callbacks do not inherit Swift Testing's task-local test.
    /// Collect observations there, but report assertions in the owning test.
    @MainActor private final class Trace {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
    }

    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let token: String
        let session: URLSession

        func cleanup() {
            app.stopAgentResponse(for: runtime)
            app.dispatchDecisionResumptionTask?.cancel()
            session.invalidateAndCancel()
            GoalLoopURLProtocol.remove(token)
            app.contextCompressionSummaryOperation = nil
            app.agentLoopInferenceEnvironment = nil
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Loop fixture cleanup failed: \(error)") }
        }

        func start() {
            app.dispatchAgentMessage(for: runtime, text: "Inspect the next numbered records.", images: [], source: .hostInstruction)
        }

        func waitForIdle() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while runtime.isResponding || runtime.isAwaitingProviderSlot || runtime.requestTask != nil || runtime.isCompressingContext {
                guard ContinuousClock.now < deadline else {
                    app.stopAgentResponse(for: runtime)
                    throw LoopFailure.timeout
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private enum LoopFailure: Error { case timeout, unexpectedRequest }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-main-loop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let records = (1...257).map { "record-\($0)" }.joined(separator: "\n") + "\n"
        try Data(records.utf8).write(to: root.appendingPathComponent("records.txt"))
        let suite = "goal-main-loop-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let created = app.startNewAgentSession(inWorkspaceAt: root.path)
        let runtime = try #require(app.runtime(for: created.id))
        runtime.session.titleIsUserSet = true
        runtime.interactionMode = .goal
        runtime.executionAgent = .willDeep
        runtime.managedRouting = nil
        runtime.currentGoal = .init(statement: "Inspect numbered records", checklist: [.init(text: "All records inspected")])
        runtime.currentPlan = .init(status: .executing, steps: [.init(text: "Inspect records", status: .inProgress)])
        runtime.messages = [.init(role: .user, content: "Inspect numbered records.", source: .operatorInput)]
        let token = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalLoopURLProtocol.self]
        configuration.httpAdditionalHeaders = [GoalLoopURLProtocol.tokenHeader: token]
        let session = URLSession(configuration: configuration)
        app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://goal-loop.invalid/v1",
                                                  model: "gpt-4.1", apiKey: "test-placeholder"), session)
        return .init(app: app, runtime: runtime, root: root, defaults: defaults, suite: suite, token: token, session: session)
    }

    private static func toolResponse(_ index: Int, content: String? = nil, promptTokens: Int? = nil,
                                     toolName: String = "read_file", customArguments: [String: Any]? = nil,
                                     externalID: String? = nil) throws -> Data {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject:
            customArguments ?? ["path": "records.txt", "offset": index, "limit": 1]), as: UTF8.self)
        let call: [String: Any] = ["index": 0, "id": externalID ?? "record-call-\(index)", "type": "function",
                                  "function": ["name": toolName, "arguments": arguments]]
        var delta: [String: Any] = ["tool_calls": [call]]
        if let content { delta["content"] = content }
        var chunk: [String: Any] = ["choices": [["delta": delta, "finish_reason": "tool_calls"]]]
        if let promptTokens {
            chunk["usage"] = ["prompt_tokens": promptTokens, "completion_tokens": 20, "total_tokens": promptTokens + 20]
        }
        return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
            + "\n\ndata: [DONE]\n\n").utf8)
    }

    @Test("256 次真实文件工具后自动执行第 257 次新读取，无需用户发送继续")
    func toolRoundBoundaryAutomaticallyDispatchesNextTurn() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let trace = Trace()
        var requests = 0
        var reachedContinuation = false
        var firstTurn: UUID?
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            if requests == 1 { firstTurn = f.runtime.activeTurnID }
            if requests <= 256 { return try Self.toolResponse(requests) }
            guard requests <= 258 else { throw LoopFailure.unexpectedRequest }
            reachedContinuation = true
            trace.check(f.runtime.activeTurnID != firstTurn, "Continuation reused the first turn ID")
            trace.check(f.runtime.currentGoal?.continuationBudget?.continuationsUsed == 1, "Continuation budget must advance once")
            trace.check(f.runtime.currentGoal?.checklist.first?.done == false, "Unverified Goal was marked done")
            trace.check(f.runtime.toolCalls.count == requests - 1, "Unexpected tool count at request \(requests)")
            trace.check(f.runtime.toolCalls.allSatisfy { $0.status == .succeeded }, "A file read failed")
            trace.check(Set(f.runtime.toolCalls.map(\.externalID)).count == requests - 1, "Tool IDs were reused")
            for (index, call) in f.runtime.toolCalls.enumerated() {
                let record = index + 1
                let lines = call.result?.payload.split(separator: "\n").filter { !$0.hasPrefix("...[truncated:") }
                trace.check(lines?.map(String.init) == [String(format: "%5d  record-%d", record, record)],
                            "Tool \(record) did not read exactly its one numbered line")
                trace.check(call.arguments["offset"]?.intValue() == record, "Tool \(record) lost its numeric offset")
                trace.check(call.arguments["limit"]?.intValue() == 1, "Tool \(record) lost its numeric limit")
            }
            trace.check(f.runtime.messages.contains { $0.source == .hostInstruction && $0.content.contains("bounded tool-call segment ended") }, "Missing host continuation notice")
            trace.check(f.runtime.messages.filter(\.isOperatorInput).count == 1, "Continuation became operator input")
            if requests == 257 { return try Self.toolResponse(257) }
            f.app.stopAgentResponse(for: f.runtime)
            throw CancellationError()
        }
        f.start()
        try await f.waitForIdle()
        #expect(trace.failures.isEmpty, "\(trace.failures.joined(separator: "\n"))")
        #expect(reachedContinuation)
        #expect(requests == 258)
        #expect(f.runtime.pendingToolDecisions.isEmpty)
        #expect(f.runtime.queuedMessages.isEmpty)
        print("goal_main_loop_trace requests=\(requests) succeeded_tools=\(f.runtime.toolCalls.filter { $0.status == .succeeded }.count) operator_inputs=1")
    }

    @Test("四次真实交接和压缩后自动继续工具执行，预算起点与原约束不丢失")
    func fourthCompactionAutomaticallyContinuesExecution() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let trace = Trace()
        var requests = 0
        var compressions = 0
        var budgetStart: Date?
        f.runtime.contextRunwayResumeCount = AgentContextRunwayPolicy.maximumAutomaticResumes
        f.app.contextCompressionSummaryOperation = { segments, _ in
            compressions += 1
            trace.check(!segments.isEmpty, "Compression received no history")
            return "Checked earlier records; continue only remaining records."
        }
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            if requests == 1 { budgetStart = f.runtime.currentGoal?.continuationBudget?.segmentStartedAt }
            if requests <= 8 {
                if requests.isMultiple(of: 2) {
                    let chunk: [String: Any] = ["choices": [["delta": ["content":
                        "PAUSE: context full. DONE: prior reads. ANCHORS: records.txt. REMAINING: remaining records. NEXT PROMPT: inspect next record."],
                        "finish_reason": "stop"]]]
                    return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
                        + "\n\ndata: [DONE]\n\n").utf8)
                }
                return try Self.toolResponse((requests + 1) / 2,
                    content: String(repeating: "fixture evidence details ", count: 2_000), promptTokens: 920_000)
            }
            guard requests <= 11 else { throw LoopFailure.unexpectedRequest }
            trace.check(compressions == 4, "Expected four real compactions")
            trace.check(f.runtime.currentGoal?.continuationBudget?.continuationsUsed == 4, "Compactions lost continuation count")
            trace.check(f.runtime.currentGoal?.continuationBudget?.segmentStartedAt == budgetStart, "Compaction reset budget start")
            trace.check(f.runtime.contextCheckpoint?.userInputs.first?.text == "Inspect numbered records.", "Checkpoint lost original user constraint")
            trace.check(f.runtime.currentGoal?.checklist.first?.done == false, "Compaction marked unverified Goal done")
            if requests == 9 {
                guard let originalID = f.runtime.messages.first(where: \.isOperatorInput)?.id else { throw LoopFailure.unexpectedRequest }
                return try Self.toolResponse(5, toolName: "read_context_message",
                    customArguments: ["message_id": originalID.uuidString], externalID: "context-read-original")
            }
            if requests == 10 {
                trace.check(f.runtime.toolCalls.last?.toolName == "read_context_message", "Historical reader was not dispatched")
                trace.check(f.runtime.toolCalls.last?.result?.payload.contains("Inspect numbered records.") == true,
                            "Original user constraint was not retrieved after compaction")
                trace.check(f.runtime.toolCalls.last?.result?.commandExitCode == nil, "Historical read became a fresh command receipt")
                return try Self.toolResponse(5)
            }
            trace.check(f.runtime.toolCalls.count == 6, "Fifth file read was not executed after historical retrieval")
            trace.check(f.runtime.toolCalls.allSatisfy { $0.status == .succeeded }, "A compaction-chain read failed")
            trace.check(f.runtime.toolCalls.last?.result?.payload.contains("record-5") == true, "Fifth file result missing")
            f.app.stopAgentResponse(for: f.runtime)
            throw CancellationError()
        }
        f.start()
        try await f.waitForIdle()
        #expect(trace.failures.isEmpty, "\(trace.failures.joined(separator: "\n"))")
        #expect(requests == 11)
        #expect(compressions == 4)
        #expect(budgetStart != nil)
        #expect(f.runtime.messages.filter(\.isOperatorInput).count == 1)
        #expect(f.runtime.pendingToolDecisions.isEmpty)
        #expect(f.runtime.queuedMessages.isEmpty)
        print("goal_compaction_trace requests=\(requests) compressions=\(compressions) succeeded_tools=\(f.runtime.toolCalls.filter { $0.status == .succeeded }.count)")
    }

    @Test("真实 Client 空响应退避共享截止时间，并保留已报告用量")
    func emptyRetryDeadlinePreservesReportedUsage() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            return Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3,\"total_tokens\":13}}\n\ndata: [DONE]\n\n".utf8)
        }
        let client = AgentClient(configuration: .init(providerID: "openai", baseURL: "https://goal-loop.invalid/v1",
            model: "gpt-4.1", apiKey: "test-placeholder"), session: f.session,
            requestLedger: .init(directory: f.root.appendingPathComponent("ledger"), ownerID: f.runtime.id))
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 2, segmentStartedAt: Date()))
        let usage = AgentAuxiliaryRequestMeasurement()
        await #expect(throws: AgentToolExecutionBudgetError.deadlineReached) {
            try await client.streamChat(messages: [.init(role: .user, content: "Fixture")], executionBudget: budget) {
                await usage.consume($0)
            }
        }
        #expect((1...2).contains(requests))
        let recorded = await usage.record(purpose: .contextCompression, providerID: "openai",
            modelID: "gpt-4.1", isLocal: false, succeeded: false)
        #expect(recorded.promptTokens == requests * 10)
        #expect(recorded.completionTokens == requests * 3)
        #expect(!recorded.succeeded)
        let ledger = AgentModelRequestLedger(directory: f.root.appendingPathComponent("ledger"), ownerID: f.runtime.id)
        #expect(try ledger.summary() == .init(attempts: requests, unfinished: 0, unknownUsage: 0, reportedTokens: requests * 13))
    }

    @Test("实际 HTTP 的零用量与缺失用量分别记账", arguments: [false, true])
    func clientDistinguishesZeroAndUnknownUsage(reportsZero: Bool) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let ledger = AgentModelRequestLedger(directory: f.root.appendingPathComponent("ledger"), ownerID: f.runtime.id)
        let trace = Trace()
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            trace.check(try ledger.summary().unfinished == 1, "Transport entered before durable registration")
            var chunk: [String: Any] = ["choices": [["delta": ["content": "Fixture answer"], "finish_reason": "stop"]]]
            if reportsZero { chunk["usage"] = ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0] }
            return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
                + "\n\ndata: [DONE]\n\n").utf8)
        }
        let client = AgentClient(configuration: .init(providerID: "openai", baseURL: "https://goal-loop.invalid/v1",
            model: "gpt-4.1", apiKey: "test-placeholder"), session: f.session, requestLedger: ledger)
        try await client.streamChat(messages: [.init(role: .user, content: "Fixture")]) { _ in }
        #expect(requests == 1)
        #expect(trace.failures.isEmpty)
        #expect(try ledger.summary() == .init(attempts: 1, unfinished: 0, unknownUsage: reportsZero ? 0 : 1, reportedTokens: 0))
    }

    @Test("实际 Chat HTTP 收到被额度裁剪的输出限制")
    func chatSendsAllocatedOutputCap() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let ledger = AgentModelRequestLedger(directory: f.root.appendingPathComponent("output-cap"), ownerID: f.runtime.id)
        try ledger.setAdmissionLimit(6_000, expectedRevision: 0)
        let trace = Trace()
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { request in
            requests += 1
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                    guard body.count < 100_000 else { throw LoopFailure.unexpectedRequest }
                }
            }
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let cap = object?["max_completion_tokens"] as? Int ?? 0
            trace.check(cap > 0 && cap < 2_000, "Actual HTTP body did not carry the allocated output limit")
            trace.check(object?["max_tokens"] == nil, "Native Chat retained conflicting legacy output cap")
            trace.check(try ledger.exposure().estimatedTokens <= 6_000, "Reservation exceeded policy")
            return Data("data: {\"choices\":[{\"delta\":{\"content\":\"Fixture answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
        }
        let adapter = OpenAIChatAdapter(configuration: .init(providerID: "openai", baseURL: "https://goal-loop.invalid/v1",
            model: "gpt-4.1", apiKey: "test-placeholder"), session: f.session)
        try await adapter.streamChat(messages: [.init(role: .user, content: "Fixture")], requestLedger: ledger) { _ in }
        #expect(requests == 1)
        #expect(trace.failures.isEmpty)
        #expect(try ledger.summary().unknownUsage == 1)
    }

    @Test("额度不足在真实循环中零请求暂停，宿主交接不冒充模型验收")
    func exhaustedAdmissionPausesWithoutInference() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let ledger = try #require(f.app.modelRequestLedger(for: f.runtime))
        try ledger.setAdmissionLimit(1, expectedRevision: 0)
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            throw LoopFailure.unexpectedRequest
        }
        f.start()
        try await f.waitForIdle()
        #expect(requests == 0)
        #expect(try ledger.summary().attempts == 0)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(f.app.dispatchContinuationIsSuspended(f.runtime))
        #expect(!f.app.shouldAutoCompressNow(for: f.runtime))
        #expect(f.runtime.currentGoal?.checklist.contains(where: { !$0.done }) == true)
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
        #expect(f.app.stopOnModelAdmissionFailure(AgentModelRequestLedger.Failure.budgetExceeded,
            runtime: f.runtime, assistantID: UUID()))
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
        let goal = try #require(f.runtime.currentGoal)
        let restored = try JSONDecoder().decode(AgentGoal.self, from: JSONEncoder().encode(goal))
        #expect(restored.continuationBudget?.modelAdmissionPaused == true)
        #expect(restored.continuationBudget?.restarted.modelAdmissionPaused != true)
        f.runtime.messages.append(.init(role: .assistant, content: "```goal-check\n1: done\n```", origin: .hostGenerated))
        #expect(!f.app.captureAgentGoalEvaluationFromLatestMessage(for: f.runtime))
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        var snapshot = f.runtime.session
        snapshot.messages = f.runtime.messages.filter { $0.origin == .hostGenerated }
        #expect(AgentUsageStats.modelUsage(for: [snapshot]).isEmpty)
    }

    @Test("托管路由预算不足时真实主循环零请求暂停，不使用路由降级继续发送")
    func managedRouteAdmissionStopsMainRequest() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.managedRouting = .init()
        f.app.someIMCodingPlanStatus = .init(hasActivePlan: false, checkedAt: Date())
        f.app.agentLoopInferenceEnvironment = (.init(providerID: AgentProviderPreset.someIMID,
            baseURL: "https://goal-loop.invalid/v1", model: SomeIMManagedModel.autoFlash, apiKey: "test-placeholder"), f.session)
        let ledger = try #require(f.app.modelRequestLedger(for: f.runtime))
        try ledger.setAdmissionLimit(1, expectedRevision: 0)
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in requests += 1; throw LoopFailure.unexpectedRequest }
        // Authentication is a separate production gate. Enter the real loop
        // with an owned provider-slot claim; never seed the user's Keychain
        // or weaken the login guard just to reach a budget assertion.
        let config = try #require(f.app.agentLoopInferenceEnvironment?.configuration)
        try #require(f.app.acquireProviderSlotIfPossible(providerID: config.providerID))
        let claim = f.app.claimProviderSlot(for: f.runtime, providerID: config.providerID)
        let turnID = UUID()
        f.runtime.activeTurnID = turnID
        f.runtime.activeTurnConfiguration = config
        f.runtime.isResponding = true
        f.runtime.turnStartedAt = Date()
        await f.app.runAgentLoop(for: f.runtime, configuration: config, providerSlotClaimID: claim.id, turnID: turnID)
        #expect(!f.runtime.isResponding)
        #expect(requests == 0)
        #expect(try ledger.summary().attempts == 0)
        #expect(f.runtime.currentGoal?.continuationBudget?.segmentStartedAt != nil)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
        #expect(f.runtime.toolCalls.isEmpty)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("主响应耗尽额度后安全裁判不发包、不创建审批卡且补齐工具回执")
    func safetyAdmissionStopsToolStage() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let ledger = try #require(f.app.modelRequestLedger(for: f.runtime))
        let config = try #require(f.app.agentLoopInferenceEnvironment?.configuration)
        f.app.safetyJudgeInferenceEnvironment = ([config], f.session)
        f.app.agentAlwaysAllowedCommands = []
        f.runtime.approvalMode = .smart
        let command = "FIXTURE_WORK_DIR=/private/tmp/safety-budget-\(UUID()) safety-budget-nonexistent-command"
        #expect(SafeCommand.classify(command: command) == .needsJudgment)
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(command: command, rootDirectory: f.root))
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            guard requests == 1 else { throw LoopFailure.unexpectedRequest }
            try ledger.setAdmissionLimit(80, expectedRevision: 0)
            return try Self.toolResponse(1, promptTokens: 60, toolName: "run_command",
                customArguments: ["command": command], externalID: "safety-stopped-call")
        }
        f.start()
        try await f.waitForIdle()
        #expect(requests == 1)
        #expect(try ledger.summary().attempts == 1)
        #expect(f.runtime.toolCalls.isEmpty) // Refused in stage one, not at the next model round.
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
        #expect(f.runtime.toolCalls.allSatisfy { !$0.status.isBlockingForUserDecision && $0.status != .running })
        #expect(f.runtime.messages.filter { $0.toolCallID == "safety-stopped-call" }.count == 1)
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("真实主循环待审重评耗尽预算，不把宿主失败记成用户拒绝")
    func hostStoppedPendingApprovalDoesNotBlameUser() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let ledger = try #require(f.app.modelRequestLedger(for: f.runtime))
        let config = try #require(f.app.agentLoopInferenceEnvironment?.configuration)
        f.app.safetyJudgeInferenceEnvironment = ([config], f.session)
        f.app.agentAlwaysAllowedCommands = []
        f.runtime.approvalMode = .smart
        let command = "FIXTURE_WORK_DIR=/private/tmp/safety-budget-\(UUID()) safety-budget-nonexistent-command"
        #expect(SafeCommand.classify(command: command) == .needsJudgment)
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(command: command, rootDirectory: f.root))
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            if requests == 1 {
                try ledger.setAdmissionLimit(1_000_000, expectedRevision: 0)
                return try Self.toolResponse(1, promptTokens: 60, toolName: "run_command",
                    customArguments: ["command": command], externalID: "safety-pending-call")
            }
            guard requests == 2 else { throw LoopFailure.unexpectedRequest }
            return Data(#"{"choices":[{"message":{"content":"<verdict>NO</verdict>"}}],"usage":{"prompt_tokens":7,"completion_tokens":11,"total_tokens":18}}"#.utf8)
        }
        f.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while f.runtime.toolDecisionWaiters.isEmpty {
            guard ContinuousClock.now < deadline else { throw LoopFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        try ledger.setAdmissionLimit(98, expectedRevision: 1)
        let reevaluation = try #require(f.app.reevaluatePendingAgentToolApprovals(for: f.runtime) { _ in true })
        await reevaluation.value
        guard f.runtime.toolDecisionWaiters.isEmpty else {
            Issue.record("Host stop did not release approval"); f.app.stopAgentResponse(for: f.runtime); return
        }
        try await f.waitForIdle()
        #expect(requests == 2)
        #expect(try ledger.summary().reportedTokens == 98)
        #expect(f.runtime.toolCalls.first?.status == .failed)
        #expect(f.runtime.toolCalls.first?.approvalSource == nil)
        #expect(f.runtime.messages.filter { $0.toolCallID == "safety-pending-call" }.count == 1)
        let replay = OpenAIChatAdapter.providerReadyMessages(f.runtime.messages)
        #expect(replay.contains { $0.toolCallID == "safety-pending-call" })
        #expect(replay.contains { $0.toolCalls.contains { $0.externalID == "safety-pending-call" } })
        #expect(!f.runtime.messages.contains { $0.content.contains("Tool call denied by the user.") })
        #expect(f.runtime.messages.filter { $0.origin == .hostGenerated }.count == 1)
        #expect(f.runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true)
    }

    @Test("实际 Gemini HTTP 发送前预留，未知回执占满额度后不再发送")
    func providerReservationPrecedesHTTPAndBlocksNextAttempt() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let ledger = AgentModelRequestLedger(directory: f.root.appendingPathComponent("admission"), ownerID: f.runtime.id)
        try ledger.setAdmissionLimit(200_000, expectedRevision: 0)
        let trace = Trace()
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            trace.check(try ledger.exposure().estimatedTokens > 8_192, "Provider entered without input/output reservation")
            let chunk: [String: Any] = ["candidates": [["content": ["parts": [["text": "Fixture answer"]]], "finishReason": "STOP"]]]
            let payload = try JSONSerialization.data(withJSONObject: chunk)
            return Data("data: \(String(decoding: payload, as: UTF8.self))\n\n".utf8)
        }
        let adapter = GeminiAdapter(configuration: .init(providerID: "gemini", baseURL: "https://goal-loop.invalid/v1beta",
            model: "gemini-2.5-flash", apiKey: "test-placeholder"), session: f.session)
        try await adapter.streamChat(messages: [.init(role: .user, content: "Fixture prompt")], requestLedger: ledger) { _ in }
        let reserved = try ledger.exposure().estimatedTokens
        #expect(reserved > 0)
        try ledger.setAdmissionLimit(reserved, expectedRevision: 1)
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            try await adapter.streamChat(messages: [.init(role: .user, content: "Fixture prompt")], requestLedger: ledger) { _ in }
        }
        #expect(requests == 1)
        #expect(trace.failures.isEmpty)
        #expect(try ledger.summary().attempts == 1)
    }

    @Test("真实 HTTP 请求挂起时截止取消，并自动生成一次交接回复")
    func hungProviderIsCancelledAtDeadline() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 10, segmentStartedAt: Date())
        var requests = 0
        var firstRequestCancelled = false
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            if requests == 1 {
                do { try await Task.sleep(for: .seconds(60)) }
                catch is CancellationError { firstRequestCancelled = true; throw CancellationError() }
                throw LoopFailure.unexpectedRequest
            }
            guard requests == 2 else { throw LoopFailure.unexpectedRequest }
            return Data("data: {\"choices\":[{\"delta\":{\"content\":\"STATE: unchanged. DONE: none. REMAINING: inspect records. BLOCKERS: deadline. NEXT: resume with budget.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
        }
        f.start()
        try await f.waitForIdle()
        #expect(requests == 2)
        #expect(firstRequestCancelled)
        #expect(f.runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true)
        #expect(f.runtime.messages.contains { $0.role == .assistant && $0.content.contains("REMAINING: inspect records") })
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        #expect(f.runtime.toolCalls.isEmpty)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
        #expect(f.runtime.queuedMessages.isEmpty)
    }

    @Test("模型请求期间预算到期，真实循环拒绝工具并自动进入一次收尾")
    func budgetExpirationRefusesToolsBeforeApproval() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let trace = Trace()
        var requests = 0
        GoalLoopURLProtocol.install(f.token) { _ in
            requests += 1
            if requests == 1 {
                f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 1, segmentStartedAt: .distantPast)
                return try Self.toolResponse(1)
            }
            guard requests == 2 else { throw LoopFailure.unexpectedRequest }
            trace.check(f.runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true, "Expired budget did not dispatch wrap-up")
            trace.check(f.runtime.toolCalls.isEmpty, "Expired budget allowed a tool")
            trace.check(f.runtime.pendingToolDecisions.isEmpty, "Expired budget requested approval")
            f.app.stopAgentResponse(for: f.runtime)
            throw CancellationError()
        }
        f.start()
        try await f.waitForIdle()
        #expect(trace.failures.isEmpty, "\(trace.failures.joined(separator: "\n"))")
        #expect(requests == 2)
        #expect(f.runtime.toolCalls.isEmpty)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        #expect(f.runtime.queuedMessages.isEmpty)
    }
}

/// A per-session registry, not a process-global single handler. Unregistered
/// requests fail closed rather than falling through to the real network.
nonisolated final class GoalLoopURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (URLRequest) async throws -> Data
    static let tokenHeader = "X-Goal-Loop-Fixture"
    static let statusHeader = "X-Goal-Loop-Fixture-Status"
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private var work: Task<Void, Never>?
    private var stopped = false

    static func install(_ token: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[token] = handler
    }
    static func remove(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[token] = nil
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
                let data = try await handler(request)
                try Task.checkCancellation()
                let status = request.value(forHTTPHeaderField: Self.statusHeader).flatMap(Int.init) ?? 200
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
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
