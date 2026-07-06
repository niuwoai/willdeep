//
//  AppStateAgentToolDecisions.swift
//  WillDeep
//
//  Tool-call approval, always-allow rules, and auto-approval policy for
//  Agent mode. Kept separate from AppStateAgentLoop.swift so the loop file
//  can stay focused on turn execution and streaming.
//

import AppKit
import Foundation

extension AppState {
    func approveAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func alwaysAllowAgentToolCall(id: AgentToolCall.ID) {
        guard let call = agentToolCalls.first(where: { $0.id == id }) else { return }
        if let rule = alwaysAllowedCommand(for: call) {
            addAgentAlwaysAllowedCommand(rule)
        }
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func denyAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .denied(reason: "User denied"))
    }

    func confirmAgentToolCall(id: AgentToolCall.ID, typedConfirmation: String) -> Bool {
        let expected = "confirm"
        guard typedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected else {
            return false
        }
        resolveAgentToolCallDecision(id: id, decision: .approved)
        return true
    }

    /// Resolve an `ask_user` call with the user's typed answer. Empty
    /// strings still resume the loop so the model can react to "no answer
    /// provided"; use `denyAgentToolCall` to skip outright.
    func answerAgentToolCall(id: AgentToolCall.ID, answer: String) {
        resolveAgentToolCallDecision(id: id, decision: .answered(answer))
    }

    func fillTerminalShortcutProtectedInputs(
        shortcutID: UUID,
        valuesByEventIndex: [Int: String]
    ) -> Bool {
        do {
            _ = try agentTerminalController.fillProtectedInputs(
                shortcutID: shortcutID,
                valuesByEventIndex: valuesByEventIndex
            )
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    func removeAgentAlwaysAllowedCommand(id: AgentAlwaysAllowedCommand.ID) {
        agentAlwaysAllowedCommands.removeAll { $0.id == id }
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    func clearAgentAlwaysAllowedCommands() {
        agentAlwaysAllowedCommands = []
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    func addAgentAlwaysAllowedCommand(_ command: AgentAlwaysAllowedCommand) {
        guard !agentAlwaysAllowedCommands.contains(where: { $0.commandSignature == command.commandSignature }) else {
            return
        }
        agentAlwaysAllowedCommands.append(command)
        agentAlwaysAllowedCommands.sort { $0.commandSignature < $1.commandSignature }
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    func alwaysAllowedCommand(for call: AgentToolCall) -> AgentAlwaysAllowedCommand? {
        guard let signature = AgentToolAuthorization.signature(for: call) else {
            return nil
        }
        return AgentAlwaysAllowedCommand(commandSignature: signature)
    }

    func isAgentToolCallAlwaysAllowed(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk
    ) -> Bool {
        guard risk == .write,
              let signature = AgentToolAuthorization.signature(toolName: toolName, arguments: arguments) else {
            return false
        }
        return agentAlwaysAllowedCommands.contains { $0.commandSignature == signature }
    }

    /// Resolve auto-approval for a write-tier tool call. Returns the
    /// source that approved it, or `nil` to mean "user must decide".
    /// Cheap paths (user allowlist, static SafeCommand) run inline; the
    /// LLM judge round-trips only when nothing cheaper matched.
    func autoApprovalSource(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        rootDirectory: URL?,
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart
    ) async -> AgentToolApprovalSource? {
        guard risk == .write else { return nil }

        let sandboxDecision = AgentSandboxPolicy.decision(
            toolName: toolName,
            arguments: arguments,
            rootDirectory: rootDirectory
        )
        // Goal mode is intended to run without babysitting. Danger-tier
        // calls never reach this function, and untrusted MCP servers still
        // fall back to the per-call gate.
        if interactionMode == .goal,
           sandboxDecision.mode != .escalated || goalModeCanAutoApproveEscalated(
               toolName: toolName,
               arguments: arguments
           ) {
            if toolName == "call_mcp_tool" {
                if let server = arguments["server"]?.stringValue(),
                   AgentMCPSettingsStore.isServerTrusted(name: server) {
                    return .goalMode
                }
            } else {
                return .goalMode
            }
        }

        if approvalMode == .requestEveryTime {
            return nil
        }

        if sandboxDecision.requiresTypedConfirmation {
            return nil
        }

        if sandboxDecision.mode == .escalated,
           isAgentToolCallAlwaysAllowed(toolName: toolName, arguments: arguments, risk: risk) {
            return .alwaysAllowList
        }

        if !Self.canSendToSafetyJudge(toolName: toolName, sandboxDecision: sandboxDecision) {
            if isAgentToolCallAlwaysAllowed(toolName: toolName, arguments: arguments, risk: risk) {
                return .alwaysAllowList
            }
            return nil
        }

        if approvalMode == .workspaceAccess,
           workspaceAccessCanAutoApprove(toolName: toolName, arguments: arguments) {
            return .workspaceAccess
        }

        // User-pinned signatures are honored unless an MCP server was
        // later demoted to untrusted.
        if isAgentToolCallAlwaysAllowed(toolName: toolName, arguments: arguments, risk: risk) {
            if toolName == "call_mcp_tool",
               let server = arguments["server"]?.stringValue(),
               !AgentMCPSettingsStore.isServerTrusted(name: server) {
                // Fall through to the MCP trust check below.
            } else {
                return .alwaysAllowList
            }
        }

        // MCP calls use the same two-tier policy as shell commands:
        // read-looking names pass statically, everything else can go to
        // the safety judge when the master auto-approve toggle is enabled.
        if toolName == "call_mcp_tool" {
            guard let server = arguments["server"]?.stringValue(),
                  let tool = arguments["tool"]?.stringValue() else {
                return nil
            }
            switch AgentMCPSettingsStore.trustLevel(name: server) {
            case .untrusted:
                return nil
            case .fullyTrusted:
                return .trustedServer
            case .standard:
                guard autoApproveSafeCommands else { return nil }
                if AgentToolAuthorization.mcpToolNameLooksReadOnly(tool) {
                    return .staticAllowlist
                }
                let pseudoCommand = AgentToolAuthorization.mcpJudgePseudoCommand(
                    server: server,
                    tool: tool,
                    argumentsJSON: arguments["arguments_json"]?.stringValue() ?? "{}"
                )
                return await safetyJudgeApproval(toolName: toolName, command: pseudoCommand)
            }
        }

        // Terminal side-panel commands ARE shell commands, just delivered to
        // the user's watched terminal — classify them the same way as
        // run_command (static allowlist first, then the LLM judge). Before
        // this, every `terminal_send_command` fell straight through to a
        // manual prompt; it was the single biggest source of hand approvals.
        if toolName == "terminal_send_command" {
            guard autoApproveSafeCommands,
                  let command = arguments["command"]?.stringValue(),
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            switch SafeCommand.classify(command: command) {
            case .alwaysSafe:
                return .staticAllowlist
            case .alwaysDangerous:
                return nil
            case .needsJudgment:
                break
            }
            return await safetyJudgeApproval(toolName: toolName, command: command)
        }

        if toolName == "terminal_send_control" {
            guard autoApproveSafeCommands,
                  let control = arguments["control"]?.stringValue()?
                      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  ["ctrl_c", "enter", "escape"].contains(control) else {
                return nil
            }
            let pseudo = AgentToolAuthorization.terminalControlJudgePseudoCommand(control: control)
            return await safetyJudgeApproval(toolName: toolName, command: pseudo)
        }

        guard toolName == "run_command" else { return nil }
        guard autoApproveSafeCommands,
              let command = arguments["command"]?.stringValue() else {
            return nil
        }

        if AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: command,
            rootDirectory: rootDirectory
        ) {
            return .staticAllowlist
        }

        switch SafeCommand.classify(command: command) {
        case .alwaysSafe:
            return .staticAllowlist
        case .alwaysDangerous:
            return nil
        case .needsJudgment:
            break
        }

        return await safetyJudgeApproval(toolName: toolName, command: command)
    }

    // MARK: - Safety judge (LLM) with cached operator history

    /// TTL for the cached few-shot history block fed to the safety judge.
    /// The block is rebuilt at most once per this interval — NOT per call —
    /// so (a) we don't re-read the audit log on every tool decision, and
    /// (b) the judge request prefix stays byte-identical between rebuilds,
    /// keeping the provider's prompt cache hot. 30 min balances "new
    /// approve-this habits show up quickly" against cache thrash.
    private static let safetyJudgeHistoryTTL: TimeInterval = 30 * 60

    /// Cached operator-decision context appended to the judge system prompt.
    /// Bounded and deduped by `AgentSandboxAuditLog.judgeHistorySamples` +
    /// `AgentInjectionDefense.judgeHistoryContext`; rebuilt lazily behind
    /// `safetyJudgeHistoryTTL`.
    func safetyJudgeHistoryContext() -> String {
        if let builtAt = cachedJudgeHistoryBuiltAt,
           Date().timeIntervalSince(builtAt) < Self.safetyJudgeHistoryTTL {
            return cachedJudgeHistoryContext
        }
        let samples = AgentSandboxAuditLog.judgeHistorySamples()
        let context = AgentInjectionDefense.judgeHistoryContext(
            approved: samples.approved,
            rejected: samples.rejected
        )
        cachedJudgeHistoryContext = context
        cachedJudgeHistoryBuiltAt = Date()
        return context
    }

    /// Run the auto-approve safety judge for a command-shaped candidate,
    /// threading the operator's cached decision history in as few-shot
    /// context and logging the outcome to judge.jsonl. Returns `.llmJudge`
    /// on a clean YES; `nil` for deny / unavailable (both fall back to the
    /// user). The single choke point every judge path (run_command, MCP,
    /// terminal) routes through.
    func safetyJudgeApproval(
        toolName: String,
        command: String
    ) async -> AgentToolApprovalSource? {
        let configuration = configurationForSafetyJudge()
        let client = AgentClient(configuration: configuration)
        let result = await client.judgeCommandSafety(
            command: command,
            historyContext: safetyJudgeHistoryContext()
        )
        let verdict: String
        let detail: String
        switch result {
        case .allow:
            verdict = "allow"
            detail = ""
        case .deny:
            verdict = "deny"
            detail = ""
        case .unavailable(let reason):
            verdict = "unavailable"
            detail = reason
        }
        AgentSandboxAuditLog.recordJudge(
            toolName: toolName,
            command: command,
            model: configuration.model,
            verdict: verdict,
            detail: detail
        )
        return result == .allow ? .llmJudge : nil
    }

    nonisolated static func canSendToSafetyJudge(
        toolName: String,
        sandboxDecision: AgentSandboxDecision
    ) -> Bool {
        guard !sandboxDecision.requiresTypedConfirmation else { return false }
        if sandboxDecision.mode == .escalated {
            return toolName == "run_command"
        }
        return true
    }

    func sandboxModeForToolExecution(
        risk: AgentToolRisk,
        approvalSource: AgentToolApprovalSource?,
        sandboxDecision: AgentSandboxDecision
    ) -> AgentSandboxMode {
        if sandboxDecision.mode == .escalated {
            return .escalated
        }
        if risk == .read {
            return .readOnly
        }
        switch approvalSource {
        case .workspaceAccess, .goalMode, .alwaysAllowList, .trustedServer, .user:
            return sandboxDecision.mode == .workspaceWriteNetwork ? .workspaceWriteNetwork : .workspaceWrite
        case .escalated:
            return .escalated
        case .staticAllowlist, .llmJudge, .none:
            return sandboxDecision.mode
        }
    }

    /// Configuration used for the auto-approval safety judge. Always
    /// resolves to the active library entry's Flash model regardless of
    /// what tier the current turn is using.
    func configurationForSafetyJudge() -> AgentConfiguration {
        var configuration = agentConfiguration.normalized.resolved(for: .interactive)
        let flash = configuration.flashModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flash.isEmpty {
            configuration.model = flash
        }
        return configuration.normalized
    }

    func resolveAgentToolCallDecision(id: AgentToolCall.ID, decision: AgentToolDecision) {
        guard let index = agentToolCalls.firstIndex(where: { $0.id == id }) else { return }
        guard agentToolCalls[index].status == .pendingApproval
            || agentToolCalls[index].status == .awaitingConfirm
            || agentToolCalls[index].status == .awaitingUserAnswer else {
            return
        }
        if case .denied(let reason) = decision {
            agentToolCalls[index].status = .denied
            agentToolCalls[index].errorMessage = reason
        }
        agentToolDecisionWaiter?.resume(returning: decision)
        agentToolDecisionWaiter = nil
    }

    private func goalModeCanAutoApproveEscalated(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        switch toolName {
        case "web_fetch":
            return arguments["url"]?.stringValue().flatMap(AgentWebTools.validatedPublicURL(_:)) != nil
        default:
            return false
        }
    }

    private func workspaceAccessCanAutoApprove(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        switch toolName {
        case "run_command", "kill_job", "claude_code", "codex_cli", "cursor_agent", "cline_cli", "lark_cli", "web_fetch",
             "add_memory", "create_user_skill", "update_user_skill", "suggest_mcp_server", "configure_mcp_server":
            return true
        case "call_mcp_tool":
            guard let server = arguments["server"]?.stringValue() else {
                return false
            }
            return AgentMCPSettingsStore.trustLevel(name: server) == .fullyTrusted
        default:
            return false
        }
    }
}
