import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentSessionSandboxControlTests {
    @Test("slash switches are reversible and isolated to the live session")
    func switches() throws {
        let app = AppState()
        let commands = SlashCommand.builtIn(state: app)
        let disable = try #require(SlashCommand.invocation(in: "/no-sandbox", commands: commands))
        disable.command.action("")
        let runtime = try #require(app.activeRuntime)
        #expect(runtime.localSandboxDisabled)
        #expect(!AgentRuntime(session: runtime.session).localSandboxDisabled)
        #expect(!AgentRuntime(session: AgentSession(workspaceRootPath: nil)).localSandboxDisabled)
        let enable = try #require(SlashCommand.invocation(in: "/sandbox", commands: commands))
        enable.command.action("")
        #expect(!runtime.localSandboxDisabled)
    }

    @Test("execution switch never widens a scoped task grant")
    func taskGrantBoundary() {
        let app = AppState()
        let decision = AgentSandboxDecision(mode: .workspaceWrite, requiresUserApproval: true,
            requiresTypedConfirmation: false, reason: "test", prefixRule: nil)
        #expect(app.sandboxModeForToolExecution(risk: .write, approvalSource: .user,
            sandboxDecision: decision, localSandboxDisabled: true) == .escalated)
        #expect(app.sandboxModeForToolExecution(risk: .write, approvalSource: .user,
            sandboxDecision: decision, localSandboxDisabled: false) == .workspaceWrite)
        #expect(app.sandboxModeForToolExecution(risk: .write, approvalSource: .taskGrant,
            sandboxDecision: decision, localSandboxDisabled: true) == .workspaceWrite)
        #expect(AgentSandboxPolicy.decision(toolName: "run_command",
            arguments: ["command": .string("sudo shutdown -h now")], rootDirectory: nil).requiresTypedConfirmation)
    }

    @Test("workspace scripts keep credentials without granting outside scripts access")
    func scripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let script = workspace.appendingPathComponent("build.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        for command in ["./build.sh", "sh build.sh", "bash ./build.sh", "zsh ./build.sh", script.path] {
            let decision = AgentSandboxPolicy.decision(toolName: "run_command",
                arguments: ["command": .string(command)], rootDirectory: workspace)
            #expect(decision.mode == .workspaceWriteNetworkCredentialed, "\(command)")
        }
        let outside = root.appendingPathComponent("outside.sh")
        try "exit 0\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link.sh"),
            withDestinationURL: outside)
        for tokens in [["sh", "../outside.sh"], ["sh", "link.sh"], ["sh", "-c", "echo hi"], ["./missing.sh"]] {
            #expect(!AgentWorkspaceScriptPolicy.matches(tokens: tokens, workingDirectory: workspace, roots: [workspace]))
        }
    }
}
