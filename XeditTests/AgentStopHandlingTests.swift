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

    @Test("cancelling a foreground command terminates its process promptly")
    @MainActor
    func foregroundCommandStopsWithTurn() async throws {
        let startedAt = Date()
        let task = Task {
            try await AgentToolRunner.run(
                name: "run_command",
                arguments: [
                    "command": .string("sleep 30"),
                    "timeout_seconds": .number(35),
                ],
                context: AgentToolContext(rootDirectory: nil, sandboxMode: .escalated)
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Foreground command should throw CancellationError")
        } catch is CancellationError {
            // Expected: the process bridge sent TERM and the cancelled turn returned.
        }

        #expect(Date().timeIntervalSince(startedAt) < 3)
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
