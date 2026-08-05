import Foundation
import Testing
@testable import WillDeep

struct AgentApprovalModePolicyTests {
    @Test("Smart review applies workspace files without git; Strict mode waits")
    @MainActor
    func workspacePatchBoundary() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_approval_workspace_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])

        let smartCreation = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Smart creation",
            diff: AgentToolRunner.makeCreationDiff(
                path: "Policy.swift",
                content: "let policy = 1\n"
            )
        )
        #expect(smartCreation.status == .applied)
        #expect(smartCreation.statusMessage == "Auto-applied by Smart review")

        runtime.approvalMode = .requestEveryTime
        let strictEdit = try appState.enqueueAgentPatchProposal(
            for: runtime,
            messageID: UUID(),
            title: "Strict edit",
            diff: """
            --- a/Policy.swift
            +++ b/Policy.swift
            @@ -1 +1 @@
            -let policy = 1
            +let policy = 2
            """,
            applyImmediately: true
        )
        #expect(strictEdit.status == .pending)
        #expect(
            try String(
                contentsOf: workspace.appendingPathComponent("Policy.swift"),
                encoding: .utf8
            ) == "let policy = 1\n"
        )
    }

    @Test("Smart review resolves legacy pending workspace patches")
    @MainActor
    func smartReviewResolvesPendingPatch() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_approval_pending_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("Pending.swift")
        try "let pending = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: workspace)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.patchProposals.append(
            AgentPatchProposal(
                messageID: UUID(),
                title: "Legacy pending",
                diff: """
                --- a/Pending.swift
                +++ b/Pending.swift
                @@ -1 +1 @@
                -let pending = 1
                +let pending = 2
                """
            )
        )

        #expect(appState.resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime) == 1)
        #expect(runtime.patchProposals.last?.status == .applied)
        #expect(runtime.patchProposals.last?.statusMessage == "Auto-applied by Smart review")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let pending = 2\n")
    }

    @Test("Smart review auto-approves contained commands without git")
    @MainActor
    func smartReviewContainedCommandPolicy() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_approval_command_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()

        let smartBuild = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("go build -o bin/app .")],
            risk: .write,
            rootDirectory: workspace,
            approvalMode: .smart
        )
        #expect(smartBuild == .staticAllowlist)

        let smartTerminalInspection = await appState.autoApprovalSource(
            toolName: "terminal_send_command",
            arguments: ["command": .string("git status --short --branch")],
            risk: .write,
            rootDirectory: workspace,
            approvalMode: .smart
        )
        #expect(smartTerminalInspection == .staticAllowlist)

        let smartKubernetesInspection = await appState.autoApprovalSource(
            toolName: "terminal_send_command",
            arguments: ["command": .string("kubectl -n tokenhub get pods")],
            risk: .write,
            rootDirectory: workspace,
            approvalMode: .smart
        )
        #expect(smartKubernetesInspection == .staticAllowlist)

        let smartDelegatedAgent = await appState.autoApprovalSource(
            toolName: "codex_cli",
            arguments: ["prompt": .string("update the workspace")],
            risk: .write,
            rootDirectory: workspace,
            approvalMode: .smart
        )
        #expect(smartDelegatedAgent == .staticAllowlist)

        let strictBuild = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("go build -o bin/app .")],
            risk: .write,
            rootDirectory: workspace,
            approvalMode: .requestEveryTime
        )
        #expect(strictBuild == nil)

        let strictTerminalInspection = await appState.autoApprovalSource(
            toolName: "terminal_send_command",
            arguments: ["command": .string("git status --short --branch")],
            risk: .write,
            rootDirectory: workspace,
            approvalMode: .requestEveryTime
        )
        #expect(strictTerminalInspection == nil)
    }

    @Test("Approval picker orders Strict mode last")
    func pickerOrder() {
        #expect(AgentApprovalMode.allCases == [
            .smart,
            .workspaceAccess,
            .requestEveryTime,
        ])
    }
}
