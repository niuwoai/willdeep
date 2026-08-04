import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentDispatchPatchAutomationTests {
    @Test("调度台项目与执行节点均无人值守，普通会话不放宽")
    func dispatchIdentityIsUnattendedOnlyInsideDispatchBoard() {
        let ordinaryRuntime = AgentRuntime(session: AgentSession())

        var projectSession = AgentSession()
        projectSession.presentationScope = .dispatchBoard
        let projectRuntime = AgentRuntime(session: projectSession)

        var restoredTaskSession = AgentSession()
        restoredTaskSession.dispatchTaskID = UUID()
        let restoredTaskRuntime = AgentRuntime(session: restoredTaskSession)

        #expect(!ordinaryRuntime.isUnattendedDispatchTask)
        #expect(projectRuntime.isUnattendedDispatchTask)
        #expect(restoredTaskRuntime.isUnattendedDispatchTask)
    }

    @Test("调度台直接输出的 fenced diff 静默应用且不生成待审卡")
    func capturedDiffAutoAppliesWithoutReview() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_dispatch_captured_patch_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Dispatch.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.session.presentationScope = .dispatchBoard

        let message = AgentMessage(
            role: .assistant,
            content: """
            ```diff
            --- a/Dispatch.swift
            +++ b/Dispatch.swift
            @@ -1 +1 @@
            -let value = 1
            +let value = 2
            ```
            """
        )
        runtime.messages.append(message)

        appState.captureAgentPatchProposals(for: runtime, fromMessageID: message.id)

        #expect(runtime.patchProposals.count == 1)
        #expect(runtime.patchProposals[0].status == .applied)
        #expect(runtime.patchProposals[0].statusMessage == "Auto-applied by unattended dispatch task")
        #expect(!runtime.patchProposals.contains { $0.status == .pending })
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 2\n")
    }

    @Test("恢复调度会话时自动清理历史待审补丁")
    func runtimeLookupAutoAppliesPersistedPendingPatches() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_dispatch_pending_restore_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Restore.swift")
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.session.dispatchTaskID = UUID()
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Legacy pending patch",
                diff: """
                --- a/Restore.swift
                +++ b/Restore.swift
                @@ -1 +1 @@
                -let value = 1
                +let value = 2
                """
            )
        )

        _ = appState.runtime(for: session.id)

        #expect(runtime.patchProposals[0].status == .applied)
        #expect(runtime.patchProposals[0].statusMessage == "Auto-applied by unattended dispatch task")
        #expect(!runtime.patchProposals.contains { $0.status == .pending })
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let value = 2\n")
    }
}
