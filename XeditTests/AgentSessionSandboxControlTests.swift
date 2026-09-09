import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentSessionSandboxControlTests {
    @Test("slash switches are reversible and persist only in their session")
    func switches() throws {
        let app = AppState()
        let commands = SlashCommand.builtIn(state: app)
        let disable = try #require(SlashCommand.invocation(in: "/no-sandbox", commands: commands))
        disable.command.action("")
        let runtime = try #require(app.activeRuntime)
        #expect(runtime.localSandboxDisabled)
        #expect(AgentRuntime(session: runtime.session).localSandboxDisabled)
        #expect(!AgentRuntime(session: AgentSession(workspaceRootPath: nil)).localSandboxDisabled)
        let enable = try #require(SlashCommand.invocation(in: "/sandbox", commands: commands))
        enable.command.action("")
        #expect(!runtime.localSandboxDisabled)
        #expect(!AgentRuntime(session: runtime.session).localSandboxDisabled)
    }

    @Test("composer preferences survive reload and explicit turn directives win")
    func composerPreferences() throws {
        var session = AgentSession(workspaceRootPath: nil)
        #expect(AgentRuntime(session: session).resolvedComposerDelegationPolicy == .automatic)
        session.prefersSubagents = false
        session.sandboxEnabled = false
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        let runtime = AgentRuntime(session: restored)
        #expect(runtime.localSandboxDisabled)
        #expect(runtime.resolvedComposerDelegationPolicy == .agentPreferred)
        #expect(AgentDelegationPolicy.agentPreferred.allowsTool(named: "spawn_agent"))
        #expect(AgentRequestRouter.routedDecision(for: "deploy kubernetes service", delegationPolicy: .agentPreferred) == nil)
        runtime.pendingDelegationPolicy = .required
        #expect(runtime.resolvedComposerDelegationPolicy == .required)
        runtime.pendingDelegationPolicy = .forbidden
        #expect(runtime.resolvedComposerDelegationPolicy == .forbidden)
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

    /// 项目仓库里的脚本按项目自己的代码对待：脱开 seatbelt 跑，并且照旧留在
    /// 静态免批名单里。仓库外的脚本、`-c` 载荷、符号链接出去的一个都不沾。
    @Test("workspace scripts run outside the sandbox without granting outside scripts access")
    func scripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let scripts = workspace.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = workspace.appendingPathComponent("build.sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // 解释器形态：`.rb` / `.py` / `.js` 不需要可执行位。
        for name in ["check.rb", "check.py", "check.js"] {
            try "\n".write(to: scripts.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let commands = [
            "./build.sh", "sh build.sh", "bash ./build.sh", "zsh ./build.sh", script.path,
            "ruby scripts/check.rb", "python3 scripts/check.py --verbose", "node scripts/check.js",
            "/opt/homebrew/bin/ruby scripts/check.rb",
        ]

        let defaults = try #require(UserDefaults(suiteName: "willdeep-workspace-trust-\(UUID().uuidString)"))
        AgentWorkspaceTrustStore._setTestDefaultsOverride(defaults)
        defer { AgentWorkspaceTrustStore._setTestDefaultsOverride(nil) }

        // 没确认过的目录：脚本照旧关在沙箱里，一条都不放。
        for command in commands {
            let decision = AgentSandboxPolicy.decision(toolName: "run_command",
                arguments: ["command": .string(command)], rootDirectory: workspace)
            #expect(!decision.workspaceScriptTrusted, "\(command)")
            #expect(decision.mode == .workspaceWriteNetworkCredentialed, "\(command)")
        }

        AgentWorkspaceTrustStore.record(true, for: workspace)
        for command in commands {
            let decision = AgentSandboxPolicy.decision(toolName: "run_command",
                arguments: ["command": .string(command)], rootDirectory: workspace)
            #expect(decision.mode == .escalated, "\(command)")
            #expect(decision.workspaceScriptTrusted, "\(command)")
            #expect(!decision.requiresTypedConfirmation, "\(command)")
            // 脱沙箱不等于多一道审批：静态免批照旧。
            #expect(AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
                command: command, rootDirectory: workspace), "\(command)")
            #expect(AgentSandboxPolicy.shouldRunWithoutSeatbelt(command: command, mode: decision.mode), "\(command)")
        }
        // 危险信号仍然先成立：本仓库脚本的名义不能给破坏性命令带路。
        let destructive = AgentSandboxPolicy.decision(toolName: "run_command",
            arguments: ["command": .string("bash build.sh && rm -rf /")], rootDirectory: workspace)
        #expect(destructive.mode == .escalated)
        #expect(!destructive.workspaceScriptTrusted)
        #expect(destructive.requiresTypedConfirmation)
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "bash build.sh && rm -rf /", rootDirectory: workspace))

        let outside = root.appendingPathComponent("outside.sh")
        try "exit 0\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link.sh"),
            withDestinationURL: outside)
        for tokens in [["sh", "../outside.sh"], ["sh", "link.sh"], ["sh", "-c", "echo hi"], ["./missing.sh"],
                       ["ruby", "-e", "puts 1"], ["python3", "-m", "http.server"], ["ruby", "../outside.rb"],
                       ["node", "$SCRIPT"], ["ruby", "~/evil.rb"]] {
            #expect(!AgentWorkspaceScriptPolicy.matches(tokens: tokens, workingDirectory: workspace, roots: [workspace]),
                    "\(tokens)")
        }
    }
}
