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
    nonisolated static func unattendedDispatchApprovalSource(
        risk: AgentToolRisk,
        isUnattendedDispatchTask: Bool
    ) -> AgentToolApprovalSource? {
        guard isUnattendedDispatchTask else { return nil }
        switch risk {
        case .write, .danger:
            return .dispatchTask
        case .read, .userInput:
            return nil
        }
    }

    func resolveDelegatedExecutorApproval(
        _ request: AgentDelegatedApprovalRequest,
        runtime: AgentRuntime,
        messageID: UUID,
        rootDirectory: URL?
    ) async -> AgentDelegatedApprovalDecision {
        if runtime.isUnattendedDispatchTask {
            return request.allowsSessionApproval ? .acceptForSession : .accept
        }
        let toolName: String
        var arguments: [String: AgentJSONValue] = [
            "_delegated_executor": .string(request.executor.rawValue),
            "_delegated_approval_kind": .string(request.kind.rawValue),
        ]
        if let command = request.command, !command.isEmpty {
            arguments["command"] = .string(command)
        }
        if let cwd = request.cwd, !cwd.isEmpty {
            arguments["_cwd"] = .string(cwd)
        }
        if let reason = request.reason, !reason.isEmpty {
            arguments["_approval_reason"] = .string(reason)
        }
        if !request.filePaths.isEmpty {
            arguments["path"] = .string(request.filePaths.joined(separator: ", "))
            arguments["_file_paths"] = .array(request.filePaths.map(AgentJSONValue.string))
        }
        if let permissions = request.requestedPermissions, !permissions.isEmpty {
            arguments["_requested_permissions"] = .string(permissions)
        }

        let risk: AgentToolRisk
        switch request.kind {
        case .command:
            toolName = "run_command"
            risk = AgentToolRegistry.risk(
                for: toolName,
                arguments: arguments,
                rootDirectory: rootDirectory
            )
        case .fileChange:
            toolName = "edit_file"
            risk = .write
        case .permissions:
            toolName = "run_command"
            risk = .danger
            if arguments["command"] == nil {
                arguments["command"] = .string("Request additional executor permissions")
            }
        }

        let autoApproval: AgentToolApprovalSource?
        if risk == .write {
            autoApproval = await autoApprovalSource(
                toolName: toolName,
                arguments: arguments,
                risk: risk,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: Array(
                    agentWorkspaceRoots(for: runtime.session).dropFirst()
                ),
                interactionMode: runtime.interactionMode,
                approvalMode: runtime.approvalMode,
                conversationAllowedToolSignatures: runtime.conversationAllowedToolSignatures,
                latestUserMessage: runtime.messages.last(where: { $0.isOperatorInput })?.content ?? ""
            )
        } else {
            autoApproval = nil
        }

        let initialStatus: AgentToolCallStatus
        if autoApproval != nil {
            initialStatus = .running
        } else {
            initialStatus = risk == .danger ? .awaitingConfirm : .pendingApproval
        }
        let record = AgentToolCall(
            messageID: messageID,
            externalID: "delegated:\(request.id)",
            toolName: toolName,
            arguments: arguments,
            risk: risk,
            status: initialStatus,
            approvalSource: autoApproval
        )
        runtime.toolCalls.append(record)
        AgentToolApprovalNotifier.notifyIfBackgrounded(
            toolName: record.toolName,
            arguments: record.arguments,
            status: initialStatus
        )

        let decision: AgentDelegatedApprovalDecision
        if autoApproval != nil {
            decision = autoApproval == .alwaysAllowList && request.allowsSessionApproval
                ? .acceptForSession
                : .accept
        } else {
            switch await awaitToolDecision(for: runtime, forCallID: record.id) {
            case .approved:
                decision = .accept
            case .denied:
                decision = .decline
            case .answered:
                decision = .decline
            }
        }

        if let index = runtime.toolCalls.firstIndex(where: { $0.id == record.id }) {
            switch decision {
            case .accept, .acceptForSession:
                runtime.toolCalls[index].status = .succeeded
                runtime.toolCalls[index].result = AgentToolResult(
                    summary: "Delegated executor request approved",
                    payload: request.reason ?? request.command ?? request.kind.rawValue
                )
            case .decline, .cancel:
                runtime.toolCalls[index].status = .denied
                runtime.toolCalls[index].errorMessage = "User denied delegated executor request"
            }
        }
        return decision
    }

    func approveAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func alwaysAllowAgentToolCall(id: AgentToolCall.ID) {
        guard let (runtime, index) = runtimeAndToolCallIndex(containing: id) else { return }
        if runtime.resolveLocalConfirmationPreview(id: id, decision: .approved) {
            return
        }
        let call = runtime.toolCalls[index]
        if let rule = alwaysAllowedCommand(for: call) {
            addAgentAlwaysAllowedCommand(rule)
        }
        approveQueuedSerialToolCalls(
            for: runtime,
            source: .alwaysAllowList
        ) { pending in
            isAgentToolCallAlwaysAllowed(
                toolName: pending.toolName,
                arguments: pending.arguments,
                risk: pending.risk
            )
        }
        resolveAgentToolCallDecision(id: id, decision: .approved)
        // Release queued siblings covered by the freshly pinned rule too.
        // Candidates are pre-filtered, so this never judges unrelated work.
        reevaluatePendingAgentToolApprovals(for: runtime) { pending in
            isAgentToolCallAlwaysAllowed(
                toolName: pending.toolName,
                arguments: pending.arguments,
                risk: pending.risk
            )
        }
    }

    func allowAgentToolFamilyForConversation(id: AgentToolCall.ID) {
        guard let (runtime, index) = runtimeAndToolCallIndex(containing: id) else { return }
        if runtime.resolveLocalConfirmationPreview(id: id, decision: .approved) {
            return
        }
        let call = runtime.toolCalls[index]
        guard let signature = AgentToolAuthorization.interactiveSurfaceSignature(
            toolName: call.toolName
        ) else { return }
        runtime.conversationAllowedToolSignatures.insert(signature)
        approveQueuedSerialToolCalls(for: runtime, source: .user) { pending in
            AgentToolAuthorization.interactiveSurfaceSignature(
                toolName: pending.toolName
            ) == signature
        }
        resolveAgentToolCallDecision(id: id, decision: .approved)
        // Same-surface queued calls unlock with the conversation grant.
        reevaluatePendingAgentToolApprovals(for: runtime) { pending in
            AgentToolAuthorization.interactiveSurfaceSignature(
                toolName: pending.toolName
            ) == signature
        }
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

    func isLocalConfirmationPreviewCall(id: AgentToolCall.ID) -> Bool {
        runtimeAndToolCallIndex(containing: id)?.runtime.localConfirmationPreviewCallIDs.contains(id) == true
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
        guard let signature = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: call.toolName,
            arguments: call.arguments
        ) else {
            return nil
        }
        return AgentAlwaysAllowedCommand(commandSignature: signature)
    }

    func isAgentToolCallAlwaysAllowed(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk
    ) -> Bool {
        // Legacy builds could persist the over-broad `computer_use:*`
        // signature. Never honor it: native app control must stay tied to the
        // current visible control lease and conversation.
        guard !toolName.hasPrefix("computer_use_") else {
            return false
        }
        guard risk == .write,
              !agentAlwaysAllowedCommands.isEmpty else {
            return false
        }
        let signatures = Set(AgentToolAuthorization.matchingSignatures(toolName: toolName, arguments: arguments))
        guard !signatures.isEmpty else { return false }
        return agentAlwaysAllowedCommands.contains { signatures.contains($0.commandSignature) }
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
        additionalWorkspaceRoots: [URL] = [],
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart,
        conversationAllowedToolSignatures: Set<String> = [],
        computerUseOwner: AgentComputerUseOwner? = nil,
        latestUserMessage: String = ""
    ) async -> AgentToolApprovalSource? {
        guard risk == .write else { return nil }

        // Renaming the originating session is a bounded, reversible local
        // metadata write. Keep it write-tier for ordering and auditability,
        // but never interrupt the user for it — even Strict mode should be
        // reserved for actions with a meaningful security or data boundary.
        // Workspace rebinding can redirect every later tool and stays gated.
        if toolName == "rename_session" {
            return interactionMode == .goal ? .goalMode : .staticAllowlist
        }
        if toolName == "change_workspace" {
            return nil
        }

        let sandboxDecision = AgentSandboxPolicy.decision(
            toolName: toolName,
            arguments: arguments,
            rootDirectory: rootDirectory,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        )

        // Computer Use never participates in the generic Goal, conversation,
        // durable, or workspace auto-approval paths below. A small reversible
        // action may run only while the same runtime and turn own a controlling
        // target-bound lease. Strict mode and a read-only observing lease both
        // require an explicit user decision.
        if toolName.hasPrefix("computer_use_") {
            guard approvalMode != .requestEveryTime,
                  let source = Self.computerUseLeaseApprovalSource(
                      toolName: toolName,
                      arguments: arguments,
                      interactionMode: interactionMode,
                      approvalMode: approvalMode,
                      owner: computerUseOwner,
                      controlState: AgentComputerUseCoordinator.shared.state
                  ) else {
                return nil
            }
            return source
        }

        if let signature = AgentToolAuthorization.interactiveSurfaceSignature(
            toolName: toolName
        ), conversationAllowedToolSignatures.contains(signature) {
            return .user
        }

        // Selecting Smart review is the user's approval policy choice; it
        // must not be silently weakened by a second global toggle. Smart and
        // Goal therefore both run command-shaped calls through the static
        // classifier and, when needed, the one-shot AI safety judge. Strict
        // mode returned above, while Workspace Access keeps its narrower
        // workspace-only boundary below.
        let judgeAutoApprove = approvalMode == .smart || interactionMode == .goal

        // Goal mode runs with high autonomy but no longer blanket-approves
        // every write-tier call. Sandbox-contained, non-command work (file
        // writes, validated public `web_fetch`) is fast-pathed here so the
        // agent isn't babysat; command-shaped calls (run_command, terminal_*,
        // call_mcp_tool) fall through to the same static-classify → LLM-judge
        // gate as smart mode. That way a judge-flagged-dangerous command, an
        // unavailable judge, or a destructive typed-confirmation op pauses
        // for the user instead of running blind. Danger-tier calls never
        // reach this function; untrusted MCP servers still hit the per-call
        // gate below.
        if interactionMode == .goal,
           !sandboxDecision.requiresTypedConfirmation,
           !Self.isCommandShapedTool(toolName),
           sandboxDecision.mode != .escalated || Self.goalPlanningCanAutoApprove(
               toolName: toolName,
               arguments: arguments
           ) {
            return .goalMode
        }

        if approvalMode == .requestEveryTime {
            return nil
        }

        // Delegated coding agents can modify many files in one call. Smart
        // review and Workspace Access both let workspace-scoped delegated
        // work pass WillDeep's outer gate; the delegated runner keeps its own
        // sandbox and review boundary. Strict mode returned above.
        if Self.isTrustedDelegatedAgentTool(toolName) {
            return .staticAllowlist
        }

        // Remote media-render jobs (some.im / Replicate submit·poll·cancel)
        // have no local side effects; auto-approve them so the agent isn't
        // gated on every submit and status poll. `requestEveryTime` above still
        // forces a manual prompt for users who opt into asking for everything.
        if Self.isAutoApprovedMediaTaskTool(toolName) {
            return .staticAllowlist
        }

        if sandboxDecision.requiresTypedConfirmation {
            return nil
        }

        // `write_file` is the sole host-native escape hatch for an exact file
        // outside the workspace. The user's current message can itself be the
        // one-shot authorization when it names that exact path and asks for a
        // write. Otherwise Smart/Goal may auto-create only a missing,
        // non-sensitive, bounded text document; overwrites fall back to a
        // visible approval card. No durable directory grant is created.
        if toolName == "write_file" {
            if AgentExternalFileWritePolicy.currentUserExplicitlyAuthorizes(
                arguments: arguments,
                rootDirectory: rootDirectory,
                latestUserMessage: latestUserMessage
            ) {
                return .user
            }
            if approvalMode == .smart || interactionMode == .goal,
               AgentExternalFileWritePolicy.canAutoApproveNewDocument(
                   arguments: arguments,
                   rootDirectory: rootDirectory
               ) {
                return interactionMode == .goal ? .goalMode : .staticAllowlist
            }
            return nil
        }

        // Workspace Access is resolved HERE — before the escalated /
        // safety-judge gates below. This mode authorizes workspace-scoped
        // writes, not arbitrary external effects: escalated network/remote
        // actions remain manual. Smart review is the mode that can ask the
        // safety judge to approve safe curl/web/remote operations.
        if approvalMode == .workspaceAccess {
            if workspaceAccessCanAutoApprove(
                toolName: toolName,
                arguments: arguments,
                sandboxDecision: sandboxDecision
            ) {
                return .workspaceAccess
            }
            // User-pinned always-allow signatures still count in Workspace
            // Access — the mode narrows AUTOMATIC approval to the workspace
            // whitelist, it does not revoke explicit user pins. Anything
            // else (including a pinned MCP tool whose server was later
            // demoted to untrusted) stays manual; the static-classifier /
            // LLM-judge chain below is intentionally unreachable here.
            let pinnedMCPDemoted = toolName == "call_mcp_tool"
                && (arguments["server"]?.stringValue()).map { !AgentMCPSettingsStore.isServerTrusted(name: $0) } == true
            if isAgentToolCallAlwaysAllowed(toolName: toolName, arguments: arguments, risk: risk),
               !pinnedMCPDemoted {
                return .alwaysAllowList
            }
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
        // the safety judge when Smart review (or Goal mode) is active.
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
                guard judgeAutoApprove else { return nil }
                if AgentToolAuthorization.mcpToolNameLooksReadOnly(tool) {
                    return .staticAllowlist
                }
                let pseudoCommand = AgentToolAuthorization.mcpJudgePseudoCommand(
                    server: server,
                    tool: tool,
                    argumentsJSON: arguments["arguments_json"]?.stringValue() ?? "{}"
                )
                return await safetyJudgeApproval(
                    toolName: toolName,
                    command: pseudoCommand,
                    taskContext: latestUserMessage
                )
            }
        }

        // Terminal side-panel commands ARE shell commands, just delivered to
        // the user's watched terminal — classify them the same way as
        // run_command (static allowlist first, then the LLM judge). Before
        // this, every `terminal_send_command` fell straight through to a
        // manual prompt; it was the single biggest source of hand approvals.
        if toolName == "terminal_send_command" {
            // A preselected ZMODEM path can read a local file or write a local
            // directory. Keep that choice visible to the user instead of
            // approving it from the shell command text alone.
            guard !AgentTerminalTools.hasZModemPathSelection(arguments) else {
                return nil
            }
            guard judgeAutoApprove,
                  let command = arguments["command"]?.stringValue(),
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            switch SafeCommand.classify(command: command) {
            case .alwaysSafe:
                // Only context-independent reads are static in a visible
                // terminal. SafeCommand also certifies bounded workspace
                // builders/creators, but this terminal may currently point
                // at a remote host or directory, so those still need review.
                if sandboxDecision.mode == .readOnly
                    || sandboxDecision.mode == .readOnlyNetwork {
                    return .staticAllowlist
                }
            case .alwaysDangerous:
                return nil
            case .needsJudgment:
                break
            }
            return await safetyJudgeApproval(
                toolName: toolName,
                command: command,
                taskContext: latestUserMessage
            )
        }

        if toolName == "terminal_send_control" {
            guard judgeAutoApprove,
                  let control = arguments["control"]?.stringValue()?
                      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  ["ctrl_c", "ctrl_d", "ctrl_right_bracket", "enter", "escape"].contains(control) else {
                return nil
            }
            let pseudo = AgentToolAuthorization.terminalControlJudgePseudoCommand(control: control)
            return await safetyJudgeApproval(
                toolName: toolName,
                command: pseudo,
                taskContext: latestUserMessage
            )
        }

        guard toolName == "run_command" else { return nil }
        guard judgeAutoApprove,
              let command = arguments["command"]?.stringValue() else {
            return nil
        }

        if sandboxDecision.mode == .workspaceWrite
            || sandboxDecision.mode == .workspaceWriteNetwork {
            // Smart review treats workspace containment as the local write
            // boundary. Git remains useful for recovery, but its absence must
            // not turn every in-workspace change into a user approval card.
            // External effects continue through the classifier/judge below.
            if AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
                command: command,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            ) {
                return .staticAllowlist
            }
        }

        switch SafeCommand.classify(command: command) {
        case .alwaysSafe:
            return .staticAllowlist
        case .alwaysDangerous:
            return nil
        case .needsJudgment:
            break
        }

        return await safetyJudgeApproval(
            toolName: toolName,
            command: command,
            taskContext: latestUserMessage
        )
    }

    nonisolated static func canAutoApproveComputerUse(
        toolName: String,
        arguments: [String: AgentJSONValue],
        interactionMode: AgentInteractionMode,
        approvalMode: AgentApprovalMode,
        owner: AgentComputerUseOwner?,
        controlState: AgentComputerUseControlState
    ) -> Bool {
        guard approvalMode != .requestEveryTime else {
            return false
        }
        return AgentComputerUsePolicy.canAutoApproveInOperationalLease(
            toolName: toolName,
            arguments: arguments,
            owner: owner,
            controlState: controlState
        )
    }

    nonisolated static func computerUseLeaseApprovalSource(
        toolName: String,
        arguments: [String: AgentJSONValue],
        interactionMode: AgentInteractionMode,
        approvalMode: AgentApprovalMode,
        owner: AgentComputerUseOwner?,
        controlState: AgentComputerUseControlState
    ) -> AgentToolApprovalSource? {
        guard canAutoApproveComputerUse(
            toolName: toolName,
            arguments: arguments,
            interactionMode: interactionMode,
            approvalMode: approvalMode,
            owner: owner,
            controlState: controlState
        ) else {
            return nil
        }
        return .controlLease
    }

    // MARK: - Safety judge (LLM) with cached operator history

    /// TTL for the cached few-shot history block fed to the safety judge.
    /// The block is rebuilt at most once per this interval — NOT per call —
    /// so (a) we don't re-read the audit log on every tool decision, and
    /// (b) the judge request prefix stays byte-identical between rebuilds,
    /// keeping the provider's prompt cache hot. 30 min balances "new
    /// approve-this habits show up quickly" against cache thrash.
    private static let safetyJudgeHistoryTTL: TimeInterval = 30 * 60

    /// How long a judge YES stays reusable for the same tool + exact command
    /// before the next occurrence pays a real judge round trip
    /// again. 30 min mirrors the few-shot history TTL: long enough to cover
    /// a work session's repeated `git commit` / `swift build` cadence,
    /// short enough that a stale allow doesn't outlive the session context
    /// it was judged in.
    private static let safetyJudgeVerdictCacheTTL: TimeInterval = 30 * 60

    /// Hard cap on cached verdict entries; beyond it, expired entries are
    /// pruned first and the cache is cleared as a last resort.
    private static let safetyJudgeVerdictCacheLimit = 256

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
        command: String,
        taskContext: String = ""
    ) async -> AgentToolApprovalSource? {
        let judgeTaskContext = AgentInjectionDefense.redactedTaskContextForSafetyJudge(taskContext)
        // A recent YES for this tool + exact normalized command skips the network
        // round trip entirely. Only allows are cached (a deny still falls
        // through to the user each time), and the static danger gates run
        // BEFORE this point, so a changed argument or typed-confirmation
        // command can never ride an earlier verdict.
        let cacheKey = AgentToolAuthorization.judgeVerdictCacheKey(
            toolName: toolName,
            command: command,
            taskContext: judgeTaskContext
        )
        if let grantedAt = cachedJudgeAllowedVerdicts[cacheKey],
           Date().timeIntervalSince(grantedAt) < Self.safetyJudgeVerdictCacheTTL {
            AgentSandboxAuditLog.recordJudge(
                toolName: toolName,
                command: command,
                model: "verdict-cache",
                verdict: "allow",
                detail: "cached exact tool action and task context"
            )
            return .llmJudge
        }

        let configuration = configurationForSafetyJudge()
        var effectiveConfiguration = configuration
        var fallbackDetail = ""
        let judgeCommand = AgentInjectionDefense.redactedCommandForSafetyJudge(command)
        var result = await AgentClient(configuration: configuration).judgeCommandSafety(
            command: judgeCommand,
            historyContext: safetyJudgeHistoryContext(),
            toolName: toolName,
            taskContext: judgeTaskContext
        )
        if case .unavailable(let primaryReason) = result,
           let fallback = someIMSecurityGuardConfiguration(),
           fallback != configuration {
            effectiveConfiguration = fallback
            fallbackDetail = "managed fallback after \(primaryReason)"
            result = await AgentClient(configuration: fallback).judgeCommandSafety(
                command: judgeCommand,
                historyContext: safetyJudgeHistoryContext(),
                toolName: toolName,
                taskContext: judgeTaskContext
            )
        }
        let verdict: String
        let detail: String
        switch result {
        case .allow:
            verdict = "allow"
            detail = fallbackDetail
        case .deny:
            verdict = "deny"
            detail = fallbackDetail
        case .unavailable(let reason):
            verdict = "unavailable"
            detail = fallbackDetail.isEmpty ? reason : "\(fallbackDetail); \(reason)"
        }
        AgentSandboxAuditLog.recordJudge(
            toolName: toolName,
            command: command,
            model: effectiveConfiguration.model,
            verdict: verdict,
            detail: detail
        )
        if result == .allow {
            if cachedJudgeAllowedVerdicts.count >= Self.safetyJudgeVerdictCacheLimit {
                let cutoff = Date().addingTimeInterval(-Self.safetyJudgeVerdictCacheTTL)
                cachedJudgeAllowedVerdicts = cachedJudgeAllowedVerdicts.filter { $0.value > cutoff }
                if cachedJudgeAllowedVerdicts.count >= Self.safetyJudgeVerdictCacheLimit {
                    cachedJudgeAllowedVerdicts.removeAll()
                }
            }
            cachedJudgeAllowedVerdicts[cacheKey] = Date()
        }
        return result == .allow ? .llmJudge : nil
    }

    /// Tools whose side effects the workspace sandbox alone can't contain —
    /// they run shell commands or reach an MCP server, so even in goal mode
    /// they must clear the static-classify → LLM-judge gate rather than being
    /// blanket-approved. Non-command write tools (file edits within the
    /// sandbox root, validated public `web_fetch`) are fast-pathed by goal
    /// mode instead. Keep in sync with the command branches in
    /// `autoApprovalSource`.
    nonisolated static let commandShapedToolNames: Set<String> = [
        "run_command",
        "terminal_send_command",
        "terminal_send_control",
        "call_mcp_tool"
    ]

    nonisolated static func isCommandShapedTool(_ toolName: String) -> Bool {
        commandShapedToolNames.contains(toolName)
    }

    /// Delegated coding-agent tools that ship their own approval + sandbox
    /// review (Claude Code, Codex CLI, Cursor Agent, Cline CLI). We trust
    /// their internal safety layer, so `autoApprovalSource` auto-approves them
    /// by default in every mode except `requestEveryTime`. Keep in sync with
    /// the same names in `workspaceAccessCanAutoApprove`.
    nonisolated static let trustedDelegatedAgentToolNames: Set<String> = [
        "claude_code",
        "codex_cli",
        "hermes_cli",
        "cursor_agent",
        "cline_cli"
    ]

    nonisolated static func isTrustedDelegatedAgentTool(_ toolName: String) -> Bool {
        trustedDelegatedAgentToolNames.contains(toolName)
    }

    /// Remote media-generation lifecycle tools (submit / poll / cancel an
    /// async some.im or Replicate render job). They carry `.write` risk in the
    /// registry because they do reach a remote service, but they have no local
    /// side effects and asking the user to Allow every submit — and then every
    /// poll of the same job — is pure friction. Auto-approve them by default in
    /// every mode except `requestEveryTime` (which still forces a manual
    /// prompt). `.staticAllowlist` keeps them under the sandbox mode the policy
    /// computed (read-only here), same as the delegated-agent tools above.
    nonisolated static let autoApprovedMediaTaskToolNames: Set<String> = [
        "some_im_create_media_task",
        "some_im_poll_media_task",
        "some_im_cancel_media_task",
        "replicate_create_prediction",
        "replicate_poll_prediction",
        "replicate_cancel_prediction"
    ]

    nonisolated static func isAutoApprovedMediaTaskTool(_ toolName: String) -> Bool {
        autoApprovedMediaTaskToolNames.contains(toolName)
    }

    nonisolated static func canSendToSafetyJudge(
        toolName: String,
        sandboxDecision: AgentSandboxDecision
    ) -> Bool {
        guard !sandboxDecision.requiresTypedConfirmation else { return false }
        if sandboxDecision.mode == .escalated {
            return toolName == "run_command" || toolName == "terminal_send_command"
        }
        return true
    }

    func sandboxModeForToolExecution(
        risk: AgentToolRisk,
        approvalSource: AgentToolApprovalSource?,
        sandboxDecision: AgentSandboxDecision,
        isUnattendedDispatchTask: Bool = false
    ) -> AgentSandboxMode {
        if sandboxDecision.mode == .escalated {
            return .escalated
        }
        // Scheduler-owned nodes must be able to install dependencies, bind
        // localhost ports, launch browser tests, and reach services even when
        // the command itself does not look like a conventional network tool.
        // They already run in isolated task worktrees and have no operator
        // available to approve a second attempt after a seatbelt denial.
        if isUnattendedDispatchTask {
            return .workspaceWriteNetwork
        }
        if risk == .read {
            return sandboxDecision.mode == .readOnlyNetwork ? .readOnlyNetwork : .readOnly
        }
        switch approvalSource {
        // Editor subagents patch one approved file inside the workspace and
        // never touch the network, so they sit with the other
        // already-approved workspace writers.
        case .workspaceAccess, .goalMode, .dispatchTask, .alwaysAllowList, .trustedServer,
             .user, .controlLease, .subagentEditor:
            return sandboxDecision.mode == .workspaceWriteNetwork ? .workspaceWriteNetwork : .workspaceWrite
        case .escalated:
            return .escalated
        case .staticAllowlist, .llmJudge, .none:
            return sandboxDecision.mode
        }
    }

    /// Configuration used for the auto-approval safety judge. A signed-in
    /// some.im account always uses the dedicated server-policy model. Without
    /// some.im authentication the current conversation's resolved model is
    /// reused, including its provider and protocol.
    func configurationForSafetyJudge() -> AgentConfiguration {
        if let managed = someIMSecurityGuardConfiguration() {
            return managed
        }

        var configuration = agentConfiguration.normalized.resolved(for: .interactive)
        // The judge reads the live `agentConfiguration`, whose apiKey can
        // briefly lag the provider library: the key is materialized from
        // Keychain lazily and `applyActiveProviderLibraryEntry()` can
        // early-return before flushing it into the configuration. When that
        // window overlaps a tool decision the judge sends an empty key and
        // silently falls back to a manual prompt — historically a large slice
        // of judge calls logged `unavailable / missing api key`. If the
        // resolved key is empty, hydrate it from the library entry that
        // matches the judge's OWN provider — not just whatever entry is
        // currently active. `agentConfiguration` and `agentProviderLibrary`
        // .activeID can disagree during bootstrap / provider switch, which is
        // what left direct-DeepSeek judge calls empty-keyed. Matching by
        // providerID also keeps this clear of the DeepSeek-key-copied-to-
        // OpenAI-entry footgun: only a same-provider entry can donate a key.
        if configuration.requiresAPIKey, configuration.apiKey.isEmpty {
            let hydrated = providerLibraryAPIKey(forProviderID: configuration.providerID)
            if !hydrated.isEmpty {
                configuration.apiKey = hydrated
            }
        }
        return configuration.normalized
    }

    /// The API key of the library entry whose provider matches `providerID`,
    /// read straight from Keychain via a throwaway library copy when the entry
    /// hasn't been materialized yet. Prefers the active entry when it is the
    /// same provider, then falls back to the first same-provider entry that
    /// yields a non-empty key. Never mutates published state, so it's safe on
    /// the synchronous tool-decision path without kicking the provider-library
    /// `didSet` cascade (and the DeepSeek-key-copied-to-OpenAI-entry class of
    /// bugs that machinery guards against). Only ever returns a key from a
    /// same-provider entry — a different provider's secret is never donated.
    private func providerLibraryAPIKey(forProviderID providerID: String) -> String {
        let library = agentProviderLibrary

        func materializedKey(for entry: AgentProviderEntry) -> String {
            if entry.apiKeyLoaded { return entry.apiKey }
            var copy = library
            guard AgentSettingsStore.materializeProviderLibraryAPIKey(in: &copy, id: entry.id) else {
                return entry.apiKey
            }
            return copy.entries.first(where: { $0.id == entry.id })?.apiKey ?? entry.apiKey
        }

        if let activeID = library.activeID,
           let active = library.entries.first(where: { $0.id == activeID }),
           active.providerID == providerID {
            let key = materializedKey(for: active)
            if !key.isEmpty { return key }
        }
        for entry in library.entries where entry.providerID == providerID {
            let key = materializedKey(for: entry)
            if !key.isEmpty { return key }
        }
        return ""
    }

    /// A some.im security-guard configuration, or `nil` when the user is not
    /// signed into some.im. Built from the some.im library entry when one
    /// exists (so base URL / models track the user's setup) and always carries
    /// the shared-session key — which lives in a different Keychain slot than
    /// any per-entry secret. Used as the judge's primary provider whenever
    /// some.im authentication exists. Under XCTest
    /// it activates only when a test explicitly installs a shared-session
    /// override, so a developer's real login never affects test behavior.
    private func someIMSecurityGuardConfiguration() -> AgentConfiguration? {
        guard SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults() else {
            return nil
        }
        let key = SomeIMIntegrationStore.loadAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        if let entry = agentProviderLibrary.entries.first(where: {
            $0.providerID == AgentProviderPreset.someIMID
        }) {
            var config = entry.makeConfiguration(
                flashOverride: SomeIMManagedModel.securityGuard,
                routingMode: .flash
            )
            config.model = SomeIMManagedModel.securityGuard
            config.apiKey = key
            return config.normalized
        }

        return AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: SomeIMIntegrationSettings.defaultBaseURL,
            model: SomeIMManagedModel.securityGuard,
            flashModel: SomeIMManagedModel.securityGuard,
            proModel: SomeIMManagedModel.autoPro,
            routingMode: .flash,
            apiKey: key
        ).normalized
    }

    func resolveAgentToolCallDecision(id: AgentToolCall.ID, decision: AgentToolDecision) {
        guard let (runtime, index) = runtimeAndToolCallIndex(containing: id) else { return }
        if runtime.resolveLocalConfirmationPreview(id: id, decision: decision) {
            return
        }
        guard runtime.toolCalls[index].status == .pendingApproval
            || runtime.toolCalls[index].status == .awaitingConfirm
            || runtime.toolCalls[index].status == .awaitingUserAnswer else {
            return
        }
        // Only the call that currently owns the continuation may accept UI
        // input. Future calls are marked as serially queued and have no
        // controls; rejecting an out-of-order delivery here is the final
        // safety net against the old "submitted, waiting for loop" deadlock.
        guard let waiter = runtime.toolDecisionWaiter,
              runtime.toolDecisionWaiterCallID == id else {
            return
        }

        // The safety judge consumes recent human decisions as bounded
        // few-shot context. Do not leave a fresh approval or rejection hidden
        // behind the normal 30-minute cache: the next command in this session
        // should benefit from the operator's feedback immediately.
        if runtime.toolCalls[index].toolName == "run_command"
            || runtime.toolCalls[index].toolName == "terminal_send_command"
            || runtime.toolCalls[index].toolName == "call_mcp_tool" {
            cachedJudgeHistoryBuiltAt = nil
        }

        if case .denied(let reason) = decision {
            runtime.toolCalls[index].status = .denied
            runtime.toolCalls[index].errorMessage = reason
        }

        runtime.toolDecisionWaiter = nil
        runtime.toolDecisionWaiterCallID = nil

        if case .approved = decision {
            runtime.toolCalls[index].status = .running
        } else if case .answered = decision {
            runtime.toolCalls[index].status = .running
        }
        waiter.resume(returning: decision)
    }

    /// Apply an explicit user-pinned grant to future calls that are still in
    /// the serial queue. This is not an early human decision: the queued calls
    /// become genuinely auto-approved and stage 2 observes the approval source
    /// when their execution slot arrives.
    private func approveQueuedSerialToolCalls(
        for runtime: AgentRuntime,
        source: AgentToolApprovalSource,
        matching predicate: (AgentToolCall) -> Bool
    ) {
        for index in runtime.toolCalls.indices {
            guard AgentSerialToolApprovalQueue.contains(runtime.toolCalls[index]),
                  predicate(runtime.toolCalls[index]) else {
                continue
            }
            runtime.toolCalls[index].approvalSource = source
            runtime.toolCalls[index].arguments.removeValue(
                forKey: AgentSerialToolApprovalQueue.argumentKey
            )
        }
    }

    /// Apply a newly selected Workspace-access posture to calls that are
    /// already waiting on the old posture. Tool dispatch normally evaluates
    /// approval immediately before appending the card; without this bridge,
    /// changing the composer picker while that card is visible only affects
    /// the *next* call and leaves the current turn suspended indefinitely.
    ///
    /// Reuse the normal policy instead of blanket-approving: danger-tier,
    /// active Plan-gate, session/workspace identity, and untrusted MCP calls
    /// keep their existing user gate.
    func reevaluatePendingToolCallsForWorkspaceAccess(for runtime: AgentRuntime) {
        reevaluatePendingAgentToolApprovals(
            for: runtime,
            requiringApprovalMode: .workspaceAccess
        ) { _ in true }
    }

    /// Re-run the auto-approval policy for the active `.pendingApproval` call
    /// and serially queued siblings, resolving the ones the policy now clears.
    ///
    /// `candidateFilter` narrows which pending calls are re-evaluated —
    /// rule-change callers pass a filter matching only the new rule, so a
    /// re-evaluation can never send an unrelated command back to the LLM
    /// judge (a second judge pass could approve something the first pass
    /// left manual). Sandbox-escalation retry cards and calls with an
    /// already-submitted decision are never re-evaluated.
    @discardableResult
    func reevaluatePendingAgentToolApprovals(
        for runtime: AgentRuntime,
        requiringApprovalMode: AgentApprovalMode? = nil,
        matching candidateFilter: (AgentToolCall) -> Bool
    ) -> Task<Void, Never>? {
        let pendingCallIDs = runtime.toolCalls.compactMap { call in
            (call.status == .pendingApproval || AgentSerialToolApprovalQueue.contains(call))
                && !runtime.localConfirmationPreviewCallIDs.contains(call.id)
                && candidateFilter(call)
                ? call.id : nil
        }
        guard !pendingCallIDs.isEmpty else { return nil }

        return Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            let rootDirectory = try? runtime.localWorkspaceURLForOptimisticUse()

            for callID in pendingCallIDs {
                if let requiringApprovalMode, runtime.approvalMode != requiringApprovalMode {
                    continue
                }
                guard let index = runtime.toolCalls.firstIndex(where: { $0.id == callID }),
                      runtime.toolCalls[index].status == .pendingApproval
                        || AgentSerialToolApprovalQueue.contains(runtime.toolCalls[index]) else {
                    continue
                }

                let call = runtime.toolCalls[index]
                guard !Self.goalPlanningGateBlocks(
                    toolName: call.toolName,
                    arguments: call.arguments,
                    risk: call.risk,
                    isActive: runtime.isPlanGateActive
                ) else {
                    continue
                }

                let source = await autoApprovalSource(
                    toolName: call.toolName,
                    arguments: call.arguments,
                    risk: call.risk,
                    rootDirectory: rootDirectory,
                    additionalWorkspaceRoots: Array(
                        self.agentWorkspaceRoots(for: runtime.session).dropFirst()
                    ),
                    interactionMode: runtime.interactionMode,
                    approvalMode: runtime.approvalMode,
                    conversationAllowedToolSignatures: runtime.conversationAllowedToolSignatures,
                    computerUseOwner: runtime.computerUseOwner,
                    latestUserMessage: runtime.messages.last(where: { $0.isOperatorInput })?.content ?? ""
                )
                guard let source,
                      requiringApprovalMode == nil || runtime.approvalMode == requiringApprovalMode,
                      let currentIndex = runtime.toolCalls.firstIndex(where: { $0.id == callID }),
                      runtime.toolCalls[currentIndex].status == .pendingApproval
                        || AgentSerialToolApprovalQueue.contains(runtime.toolCalls[currentIndex]) else {
                    continue
                }

                runtime.toolCalls[currentIndex].approvalSource = source
                if AgentSerialToolApprovalQueue.contains(runtime.toolCalls[currentIndex]) {
                    runtime.toolCalls[currentIndex].arguments.removeValue(
                        forKey: AgentSerialToolApprovalQueue.argumentKey
                    )
                } else {
                    resolveAgentToolCallDecision(id: callID, decision: .approved)
                }
            }
        }
    }

    private func runtimeAndToolCallIndex(containing id: AgentToolCall.ID) -> (runtime: AgentRuntime, index: Int)? {
        if let runtime = activeRuntime,
           let index = runtime.toolCalls.firstIndex(where: { $0.id == id }) {
            return (runtime, index)
        }
        for runtime in agentRuntimes.values {
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == id }) {
                return (runtime, index)
            }
        }
        return nil
    }

    nonisolated static func goalPlanningCanAutoApprove(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        switch toolName {
        case "web_fetch":
            return arguments["url"]?.stringValue().flatMap(AgentWebTools.validatedPublicURL(_:)) != nil
        case "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli":
            return arguments["permission_mode"]?.stringValue() == "plan"
        default:
            return false
        }
    }

    nonisolated static func goalPlanningGateBlocks(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        isActive: Bool
    ) -> Bool {
        guard isActive, risk != .read else { return false }
        // The narrow public-web research exception applies only to ordinary
        // write-tier classification. A danger-tier call can never use it to
        // bypass the Goal evidence gate.
        guard risk == .write else { return true }
        return !goalPlanningCanAutoApprove(toolName: toolName, arguments: arguments)
    }

    private func workspaceAccessCanAutoApprove(
        toolName: String,
        arguments: [String: AgentJSONValue],
        sandboxDecision: AgentSandboxDecision
    ) -> Bool {
        switch toolName {
        case "run_command":
            guard let command = arguments["command"]?.stringValue(),
                  !AgentSandboxPolicy.commandUsesExternalAccess(command) else {
                return false
            }
            return sandboxDecision.mode == .readOnly || sandboxDecision.mode == .workspaceWrite
        case "kill_job", "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli",
             "add_memory", "create_user_skill", "create_user_skills", "update_user_skill", "suggest_mcp_server", "configure_mcp_server":
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
