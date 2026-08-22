import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentStopHandlingTests {
    @Test("stop decision accepts only current-turn candidate ids")
    func processDecisionIsCandidateScoped() {
        let first = AgentStopJobCandidate(
            id: UUID(),
            displayHandle: "job_first",
            command: "yarn test"
        )
        let second = AgentStopJobCandidate(
            id: UUID(),
            displayHandle: "job_second",
            command: "yarn dev"
        )
        let unrelated = UUID()
        let raw = """
        ```json
        {"stop_job_ids":["\(first.id.uuidString)","\(unrelated.uuidString)"]}
        ```
        """

        let selected = AgentStopProcessDecision.selectedJobIDs(
            rawResponse: raw,
            candidates: [first, second]
        )

        #expect(selected == Set([first.id]))
    }

    @Test("valid empty stop decision keeps current-turn jobs")
    func emptyDecisionIsRespected() {
        let candidate = AgentStopJobCandidate(
            id: UUID(),
            displayHandle: "job_keep",
            command: "yarn dev"
        )
        let selected = AgentStopProcessDecision.selectedJobIDs(
            rawResponse: #"{"stop_job_ids":[]}"#,
            candidates: [candidate]
        )
        #expect(selected.isEmpty)
    }

    @Test("invalid stop decision fails closed within the current turn")
    func invalidDecisionStopsCurrentCandidatesOnly() {
        let candidates = [
            AgentStopJobCandidate(id: UUID(), displayHandle: "job_one", command: "build"),
            AgentStopJobCandidate(id: UUID(), displayHandle: "job_two", command: "test"),
        ]
        let selected = AgentStopProcessDecision.selectedJobIDs(
            rawResponse: "not-json",
            candidates: candidates
        )
        #expect(selected == Set(candidates.map(\.id)))
    }

    @Test("user-stopped URLSession cancellations are recognized across Error bridges")
    @MainActor
    func stoppedTurnCancellationIsRecognized() {
        let state = AppState()
        _ = state.startNewAgentSession()
        let runtime = state.activeRuntime!
        let turnID = UUID()
        runtime.userStoppedTurnID = turnID
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        #expect(AppState.isStoppedTurnCancellation(bridged, runtime: runtime, turnID: turnID))
        #expect(!AppState.isStoppedTurnCancellation(bridged, runtime: runtime, turnID: UUID()))
    }

    @Test("stop button clears cancellation errors and appends a transcript event")
    @MainActor
    func stopButtonCreatesEventInsteadOfError() {
        let state = AppState()
        _ = state.startNewAgentSession()
        let runtime = state.activeRuntime!
        let turnID = UUID()
        runtime.activeTurnID = turnID
        runtime.isResponding = true
        runtime.errorMessage = "请求被取消。"
        runtime.messages.append(AgentMessage(role: .assistant, content: "已经输出的内容"))
        runtime.requestTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        state.stopAgentResponse()

        #expect(runtime.errorMessage == nil)
        #expect(runtime.messages.contains(where: { $0.content == "已经输出的内容" }))
        #expect(runtime.messages.last?.transcriptEvent == .responseStopped)
        #expect(runtime.messages.last?.content == L10n.Composer.stopped)
        #expect(runtime.userStoppedTurnID == turnID)
    }

    @Test("stop button removes a provider-slot queued dispatch")
    @MainActor
    func stopButtonCancelsProviderQueuedDispatch() throws {
        let state = AppState()
        let session = state.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(state.activeRuntime)
        let userMessage = AgentMessage(role: .user, content: "等待 provider")
        runtime.messages.append(userMessage)
        runtime.isAwaitingProviderSlot = true
        state.pendingDispatchQueue = [
            AppState.PendingDispatch(
                runtimeID: runtime.id,
                userMessageID: userMessage.id,
                text: userMessage.content,
                images: [],
                textAttachments: [],
                attachedSkills: [],
                providerID: "test-provider",
                enqueuedAt: Date(),
                source: .operatorInput
            )
        ]

        state.stopAgentResponse(for: runtime)

        #expect(!runtime.isAwaitingProviderSlot)
        #expect(state.pendingDispatchQueue.isEmpty)
        #expect(runtime.messages.last?.transcriptEvent == .responseStopped)
    }

    @Test("cancelling a foreground command terminates its process promptly")
    @MainActor
    func foregroundCommandStopsWithTurn() async throws {
        // 睡眠时长要远大于判定上限,否则「取消生效」和「干等它跑完」在满载下
        // 无法区分。原本是 sleep 30 / 判 15s:实测满载抖动能到 29.5s,已经和
        // 「没取消」同量级,于是这条用例周期性变红。拉开信号而不是放宽容忍——
        // 120s 与 45s 之间留了 75s 间距,远超观测到的调度抖动。
        let task = Task {
            try await AgentToolRunner.run(
                name: "run_command",
                arguments: [
                    "command": .string("sleep 120"),
                    "timeout_seconds": .number(125),
                ],
                context: AgentToolContext(rootDirectory: nil, sandboxMode: .escalated)
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        // 只度量「取消 → 返回」这一段；进程 spawn 的耗时在全量并行的 fork
        // 风暴下不受本测试控制,不应计入 promptly 的判定。
        let cancelledAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Foreground command should throw CancellationError")
        } catch is CancellationError {
            // Expected: the process bridge sent TERM and the cancelled turn returned.
        }

        // TERM 生效实测 4.5-7s。45s 上限只用来证明「不是等 sleep 120 自然结束
        // 或 125s 超时」,不是性能断言——满载下的调度抖动不该判它失败。
        let elapsed = Date().timeIntervalSince(cancelledAt)
        #expect(elapsed < 45, "取消后应在 45s 内返回(实测 \(elapsed)s)")
    }

    @Test("interrupted assistant output is preserved, including reasoning-only output")
    @MainActor
    func interruptedOutputIsPreserved() {
        let state = AppState()
        _ = state.startNewAgentSession()
        let runtime = state.activeRuntime!
        let text = AgentMessage(role: .assistant, content: "已经完成一半")
        let reasoning = AgentMessage(
            role: .assistant,
            content: "",
            reasoningContent: "正在检查进程"
        )
        runtime.messages.append(contentsOf: [text, reasoning])

        state.finalizeInterruptedAssistantMessage(
            id: text.id,
            in: runtime,
            startedAt: Date().addingTimeInterval(-1)
        )
        state.finalizeInterruptedAssistantMessage(
            id: reasoning.id,
            in: runtime,
            startedAt: Date().addingTimeInterval(-1)
        )

        #expect(runtime.messages.contains(where: { $0.id == text.id && $0.content == "已经完成一半" }))
        #expect(runtime.messages.contains(where: {
            $0.id == reasoning.id && $0.reasoningContent == "正在检查进程"
        }))
        #expect(runtime.messages.first(where: { $0.id == text.id })?.elapsedSeconds != nil)
    }

    @Test("background job lookup is scoped to the originating turn")
    @MainActor
    func backgroundJobsAreTurnScoped() throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let olderTurnID = UUID()
        let newestTurnID = UUID()
        let older = try registry.start(
            command: "sleep 30",
            workingDirectory: nil,
            runtimeID: runtimeID,
            turnID: olderTurnID,
            timeoutSeconds: nil,
            sandboxMode: .escalated
        )
        let newest = try registry.start(
            command: "sleep 30",
            workingDirectory: nil,
            runtimeID: runtimeID,
            turnID: newestTurnID,
            timeoutSeconds: nil,
            sandboxMode: .escalated
        )
        defer {
            _ = registry.kill(id: older.id)
            _ = registry.kill(id: newest.id)
        }

        #expect(
            registry.aliveJobs(forRuntime: runtimeID, originatingTurnID: newestTurnID).map(\.id)
                == [newest.id]
        )
        #expect(registry.killForStoppedTurn(id: newest.id))
        #expect(registry.job(id: older.id)?.isAlive == true)
    }
}
