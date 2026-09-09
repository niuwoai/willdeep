import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentWorkerStallRegressionTests {
    @Test("terminal screen survives the worker's old prefix cap")
    func terminalPayload() {
        let payload = "Host: remote\n" + String(repeating: "history\n", count: 3000)
            + "latest visible screen\nDEPLOYMENT READY 1/1\n"
        for tool in ["terminal_snapshot", "terminal_send_command"] {
            #expect(AgentSubagentRunner.clampedToolPayload(payload, limit: 4000, toolName: tool) == payload)
        }
        #expect(AgentSubagentProfileCatalog.workerPayloadCharacterLimit >= 32_000)
    }

    @Test("automatic serial ops inspections return control without changing explicit delegation")
    func convergence() {
        let id = AgentSubagentProfileCatalog.opsRunnerID
        #expect(AgentOpsConvergencePolicy.shouldReturnToParent(profileID: id, background: false,
            delegation: .automatic, completed: true))
        #expect(!AgentOpsConvergencePolicy.shouldReturnToParent(profileID: id, background: false,
            delegation: .required, completed: true))
        #expect(!AgentOpsConvergencePolicy.shouldReturnToParent(profileID: id, background: true,
            delegation: .automatic, completed: true))
        #expect(!AgentOpsConvergencePolicy.shouldReturnToParent(profileID: id, background: false,
            delegation: .automatic, completed: false))
        #expect(AgentOpsConvergencePolicy.shouldFinishSnapshotLoop(profileID: id,
            recentTools: ["terminal_send_command"] + Array(repeating: "terminal_snapshot", count: 3)))
        #expect(!AgentOpsConvergencePolicy.shouldFinishSnapshotLoop(profileID: id,
            recentTools: ["terminal_snapshot", "terminal_send_command", "terminal_snapshot"]))
    }

    @Test("live audit records progress and timings once without command or result content")
    func liveAudit() throws {
        let audit = AgentWorkerProgressAudit()
        let id = UUID()
        let tool = AgentSubagentTranscript.ToolCall(externalID: "call1", name: "terminal_snapshot",
            argumentsJSON: "PRIVATE_ARGUMENT", result: "PRIVATE_RESULT", resultWasTruncated: false,
            durationSeconds: 0.125)
        let round = AgentSubagentTranscript.Round(index: 1, content: "PRIVATE_CONTENT",
            reasoning: "PRIVATE_REASONING", toolCalls: [tool], usageTokens: 10,
            startedAt: Date(), finishedAt: Date())
        let progress = AgentSubagentProgressUpdate(round: 1, maximumRounds: 32,
            completedToolInvocations: 1, activity: .thinking, recordedRounds: [round])
        let entries = audit.entries(runID: id, progress: progress)
        #expect(entries.map(\.kind) == ["worker_progress", "worker_tool"])
        #expect(entries.last?.durationSeconds == 0.125)
        #expect(audit.entries(runID: id, progress: progress).isEmpty)
        let text = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        #expect(!text.contains("PRIVATE_"))
        #expect(entries.map(\.sequence) == [1, 2])
    }
}
