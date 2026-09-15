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
import WillDeepCore

extension AppState {
    nonisolated static func unattendedDispatchApprovalSource(
        risk: AgentToolRisk,
        isUnattendedDispatchTask: Bool
    ) -> AgentToolApprovalSource? {
        guard isUnattendedDispatchTask else { return nil }
        switch risk {
        case .write:
            return .dispatchTask
        case .read, .danger, .userInput:
            return nil
        }
    }

    func resolveDelegatedExecutorApproval(
        _ request: AgentDelegatedApprovalRequest,
        runtime: AgentRuntime,
        messageID: UUID,
        rootDirectory: URL?
    ) async -> AgentDelegatedApprovalDecision {
        do { try checkApprovalExecutionBudget(runtime) }
        catch { _ = handleApprovalRequestStop(error, runtime: runtime); return .cancel }
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

        // Read-only work never needs an approval record. In particular, a
        // delegated executor configured with `on-request` may still ask the
        // host about a harmless inspection command; turning that callback
        // into a card makes Full Access (and every other mode) prompt for
        // `sed`, `grep`, and friends even though the parent runs them silently.
        if risk == .read {
            return request.allowsSessionApproval ? .acceptForSession : .accept
        }

        if runtime.isUnattendedDispatchTask {
            guard risk == .write,
                  request.kind != .permissions else {
                return .decline
            }
            let sandboxDecision = AgentSandboxPolicy.decision(
                toolName: toolName,
                arguments: arguments,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: Array(
                    agentWorkspaceRoots(for: runtime.session).dropFirst()
                )
            )
            guard !sandboxDecision.requiresTypedConfirmation else { return .decline }
            return request.allowsSessionApproval ? .acceptForSession : .accept
        }

        // Do not pre-filter to `.write`: Full Access is deliberately allowed
        // to authorize ordinary danger-tier commands too, while
        // `autoApprovalSource` itself preserves the malicious-command,
        // session-management, and environment-trust hard stops.
        let autoApproval: AgentToolApprovalSource?
        do { autoApproval = try await checkedAutoApprovalSource(
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
            environmentTrustDeclarations: runtime.environmentTrustDeclarations,
            latestUserMessage: runtime.messages.last(where: { $0.isOperatorInput })?.content ?? "",
            budgetRuntime: runtime
        ) } catch { _ = handleApprovalRequestStop(error, runtime: runtime); return .cancel }

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
            status: initialStatus,
            runtimeID: runtime.id,
            sessionTitle: runtime.session.title
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
            if runtime.toolCalls[index].status == .failed { return .cancel }
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

    /// Native Worker equivalent of delegated-executor approval. A Worker has
    /// no window of its own, so privileged terminal / Chrome / MCP calls are
    /// represented by an ordinary tool card in the parent runtime and wait on
    /// the same decision queue. Because the record is ordinary runtime state,
    /// the sidebar, mobile gateway, notifications and Dock badge all observe
    /// it without a parallel approval store.
    func resolveSubagentToolApproval(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        workerName: String,
        runtime: AgentRuntime,
        messageID: UUID,
        rootDirectory: URL?
    ) async throws -> Bool {
        let revision = runtime.goalAuthorizationRevision
        do { try checkApprovalExecutionBudget(runtime) }
        catch { _ = handleApprovalRequestStop(error, runtime: runtime); throw error }
        // Pure reads are already admitted by the Worker execution gate. They
        // must not enter the parent's approval queue or create a Dock badge.
        guard risk != .read else { return true }

        if runtime.isUnattendedDispatchTask {
            guard risk == .write,
                  !AgentSessionManagementTools.requiresConfirmation(
                    tool: toolName,
                    arguments: arguments
                  ),
                  !AgentEnvironmentTrust.neverAutoApprovedToolNames.contains(toolName) else {
                return false
            }
            let sandboxDecision = AgentSandboxPolicy.decision(
                toolName: toolName,
                arguments: arguments,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: Array(
                    agentWorkspaceRoots(for: runtime.session).dropFirst()
                )
            )
            guard !sandboxDecision.requiresTypedConfirmation else { return false }
            if toolName == "call_mcp_tool" {
                guard let server = arguments["server"]?.stringValue(),
                      AgentMCPSettingsStore.trustLevel(name: server) != .untrusted else {
                    return false
                }
            }
            return Self.unattendedDispatchApprovalSource(
                risk: risk,
                isUnattendedDispatchTask: true
            ) != nil
        }

        // Full Access also covers normal danger-tier Worker operations. The
        // shared resolver keeps the few explicit never-auto-approve cases.
        let autoApproval: AgentToolApprovalSource?
        do { autoApproval = try await checkedAutoApprovalSource(
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
            environmentTrustDeclarations: runtime.environmentTrustDeclarations,
            latestUserMessage: runtime.messages.last(where: { $0.isOperatorInput })?.content ?? "",
            budgetRuntime: runtime
        ) } catch { _ = handleApprovalRequestStop(error, runtime: runtime); throw error }

        let initialStatus: AgentToolCallStatus
        if autoApproval != nil {
            initialStatus = .running
        } else {
            initialStatus = risk == .danger ? .awaitingConfirm : .pendingApproval
        }
        let record = AgentToolCall(
            messageID: messageID,
            externalID: "subagent:\(UUID().uuidString)",
            toolName: toolName,
            arguments: arguments,
            risk: risk,
            status: initialStatus,
            approvalSource: autoApproval,
            subagentWorkerName: workerName
        )
        runtime.toolCalls.append(record)
        AgentToolApprovalNotifier.notifyIfBackgrounded(
            toolName: toolName,
            arguments: arguments,
            status: initialStatus,
            runtimeID: runtime.id,
            sessionTitle: runtime.session.title,
            executor: workerName
        )

        let approved: Bool
        if autoApproval != nil {
            approved = true
        } else {
            switch await awaitToolDecision(for: runtime, forCallID: record.id) {
            case .approved:
                approved = true
            case .denied, .answered:
                approved = false
            }
        }

        if let index = runtime.toolCalls.firstIndex(where: { $0.id == record.id }) {
            do {
                try Task.checkCancellation()
                guard runtime.goalAuthorizationRevision == revision else { throw CancellationError() }
                try checkApprovalExecutionBudget(runtime)
                if runtime.toolCalls[index].status == .failed { throw CancellationError() }
            } catch {
                let notice = handleApprovalRequestStop(error, runtime: runtime)
                settleHostStoppedApprovals([record.id], notice: notice, runtime: runtime, includeStaged: true)
                throw error
            }
            if approved {
                runtime.toolCalls[index].status = .succeeded
                runtime.toolCalls[index].result = AgentToolResult(
                    summary: L10n.AgentDelegation.workerToolRequestApproved,
                    payload: "\(workerName) · \(toolName)"
                )
            } else {
                runtime.toolCalls[index].status = .denied
                runtime.toolCalls[index].errorMessage = L10n.AgentDelegation.workerToolRequestDenied
            }
        }
        return approved
    }

    func approveAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func alwaysAllowAgentToolCall(id: AgentToolCall.ID) {
        guard let (runtime, index) = runtimeAndToolCallIndex(containing: id) else { return }
        if runtime.resolveLocalPanelPreview(id: id, decision: .approved) {
            return
        }
        let call = runtime.toolCalls[index]
        if let rule = alwaysAllowedCommand(for: call) {
            addAgentAlwaysAllowedCommand(rule)
        }
        publishSharedAlwaysAllowRule(for: call)
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
        if runtime.resolveLocalPanelPreview(id: id, decision: .approved) {
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

    func isLocalPanelPreviewCall(id: AgentToolCall.ID) -> Bool {
        runtimeAndToolCallIndex(containing: id)?.runtime.localPanelPreviewCallIDs.contains(id) == true
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

    /// Publish the *exact* command alongside the local family rule, so the
    /// willdeep-rs CLI stops asking for the one command the user just approved.
    /// Only `run_command` qualifies: the CLI's store speaks shell commands, and
    /// this app's other signature kinds (`shell_category:`, `terminal_command:`,
    /// tool-level pins) have no counterpart there. The store itself refuses
    /// credential-bearing commands and anything the CLI could not match.
    func publishSharedAlwaysAllowRule(for call: AgentToolCall) {
        guard call.toolName == "run_command",
              let command = call.arguments["command"]?.stringValue() else {
            return
        }
        AgentSharedAlwaysAllowStore.publish(command: command)
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
        guard risk == .write else { return false }
        // A rule the operator pinned in the CLI counts here too. It is an
        // exact command rather than a family, so honoring it never grants
        // more than the one command they already approved once.
        if toolName == "run_command",
           let command = arguments["command"]?.stringValue(),
           AgentSharedAlwaysAllowStore.allows(command: command) {
            return true
        }
        guard !agentAlwaysAllowedCommands.isEmpty else { return false }
        let signatures = Set(AgentToolAuthorization.matchingSignatures(toolName: toolName, arguments: arguments))
        guard !signatures.isEmpty else { return false }
        return agentAlwaysAllowedCommands.contains { signatures.contains($0.commandSignature) }
    }

    /// Resolve auto-approval for a write-tier tool call. Returns the
    /// source that approved it, or `nil` to mean "user must decide".
    /// Cheap paths (user allowlist, static SafeCommand) run inline; the
    /// LLM judge round-trips only when nothing cheaper matched.
    /// 这条终端命令会落在哪台机器上。
    ///
    /// 审批判据里最关键但一直缺席的一条。`terminal_send_command` 是把字符
    /// 写进一个已存在的 PTY，那个 PTY 可能早就 ssh 出去了；沙箱档位在这条
    /// 路上不施加任何执行约束（见 AgentSandboxPolicy.decision 里那句
    /// "The visible terminal is not a sandbox boundary"），却仍被当成审批
    /// 参数用。至少要让裁判和用户知道目标是哪台机器。
    func terminalHostContext(arguments: [String: AgentJSONValue]) -> (line: String, isRemote: Bool) {
        let requested = arguments["terminal_tab_id"]?.stringValue()
            .flatMap(UUID.init(uuidString:))
        let controller = agentTerminalController
        let tab = requested.flatMap { id in controller.tabs.first { $0.id == id } } ?? controller.activeTab
        guard let tab else { return ("no terminal tab is open yet", false) }
        if case .remote = tab.hostState { return (tab.hostLine, true) }
        return (tab.hostLine, false)
    }

    /// 明摆着的张冠李戴：目标在远端，命令里却写着本机工作区的绝对路径。
    /// 这种命令在远端要么找不到路径，要么更糟——碰到远端一个同名目录。
    /// 静态放行和裁判都不该处理它，直接交给人。
    func terminalCommandTargetsLocalPathOnRemoteHost(
        command: String,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL]
    ) -> Bool {
        var roots: [String] = []
        if let rootDirectory { roots.append(rootDirectory.standardizedFileURL.path) }
        roots.append(contentsOf: additionalWorkspaceRoots.map(\.standardizedFileURL.path))
        roots.append(FileManager.default.homeDirectoryForCurrentUser.path)
        return roots.contains { root in
            !root.isEmpty && root != "/" && command.contains(root)
        }
    }

    func checkedAutoApprovalSource(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = [],
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart,
        conversationAllowedToolSignatures: Set<String> = [],
        environmentTrustDeclarations: [AgentEnvironmentTrustDeclaration] = [],
        computerUseOwner: AgentComputerUseOwner? = nil,
        latestUserMessage: String = "",
        taskRuntime: AgentRuntime? = nil,
        budgetRuntime: AgentRuntime? = nil
    ) async throws -> AgentToolApprovalSource? {
        try Task.checkCancellation()
        // Budget ownership does not grant a child the parent's exact authorization.
        let judgeRuntime = budgetRuntime ?? taskRuntime
        try judgeRuntime.flatMap { auxiliaryModelExecutionBudget(for: $0) }?.check()
        // 环境信任声明本身永不自动通过——任何模式、任何 pin、Goal 免审都
        // 够不到它，完全访问也一样。一次人工点击 = 一次授权仪式：注入文本
        // 骗 Agent 调这个工具时，用户会在卡片上看到被逐字引用的"用户原话"，
        // 认出自己从未说过而拒绝。这是整个特性防注入自授权的关键闸门。
        //
        // 这一段提到 `guard risk == .write` 之前：完全访问要处理 danger 档，
        // 而那道 guard 会把 danger 档直接判成"要人工"。
        if AgentSessionManagementTools.requiresConfirmation(tool: toolName, arguments: arguments)
            || AgentEnvironmentTrust.neverAutoApprovedToolNames.contains(toolName) {
            return nil
        }

        if approvalMode == .fullAccess {
            return fullAccessApprovalSource(
                toolName: toolName,
                arguments: arguments,
                risk: risk
            )
        }

        guard risk == .write else { return nil }

        // Renaming the originating session is a bounded, reversible local
        // metadata write. Keep it write-tier for ordering and auditability,
        // but never interrupt the user for it — even Strict mode should be
        // reserved for actions with a meaningful security or data boundary.
        // Workspace rebinding can redirect every later tool and stays gated.
        if toolName == "rename_session" {
            return interactionMode == .goal ? .goalMode : .staticAllowlist
        }
        if toolName == "change_workspace" || AgentSessionManagementTools.requiresConfirmation(tool: toolName, arguments: arguments) {
            return nil
        }

        // Creating a built-in worker is internal scheduling, not a security
        // boundary. Even Strict mode should not stop to ask whether WillDeep
        // may split its own work. Writing workers remain write-tier for audit,
        // but their declared paths are still locked and checked on every edit.
        //
        // `ops_runner.target_command` is deliberately excluded: that field
        // grants one exact command permission to change repository or remote
        // state. If present, the confirmation is for the command, not for
        // spawning the worker that will execute it.
        if toolName == "spawn_agent",
           !Self.subagentHasExactCommandAuthorization(
               arguments: arguments,
               rootDirectory: rootDirectory,
               additionalWorkspaceRoots: additionalWorkspaceRoots
           ) {
            if interactionMode == .goal { return .goalMode }
            return approvalMode == .workspaceAccess ? .workspaceAccess : .staticAllowlist
        }

        let sandboxDecision = AgentSandboxPolicy.decision(
            toolName: toolName,
            arguments: arguments,
            rootDirectory: rootDirectory,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        )

        if let taskRuntime, await goalTaskAuthorizationMatches(runtime: taskRuntime, toolName: toolName,
                arguments: arguments, risk: risk, root: rootDirectory) {
            return .taskGrant
        }

        // A local commit only records the already-staged workspace state and
        // remains recoverable through Git history/reflog. Run it in the
        // workspace-write sandbox without interrupting the user, including in
        // Strict mode; push and every other Git mutation keep their existing
        // approval boundaries.
        if toolName == "run_command",
           let command = arguments["command"]?.stringValue(),
           SafeCommand.isLocalGitCommit(command: command),
           sandboxDecision.mode == .workspaceWrite,
           !sandboxDecision.requiresTypedConfirmation {
            return .staticAllowlist
        }

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
        // writes and local metadata changes) is fast-pathed here so the
        // agent isn't babysat; command-shaped calls (run_command, terminal_*,
        // call_mcp_tool) fall through to the same static-classify → LLM-judge
        // gate as smart mode. That way a judge-flagged-dangerous command, an
        // unavailable judge, or a destructive typed-confirmation op pauses
        // for the user instead of running blind. Danger-tier calls never
        // reach this function; untrusted MCP servers still hit the per-call
        // gate below.
        if interactionMode == .goal,
           !Self.subagentHasExactCommandAuthorization(
               arguments: arguments,
               rootDirectory: rootDirectory,
               additionalWorkspaceRoots: additionalWorkspaceRoots
           ),
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
                return try await checkedSafetyJudgeApproval(
                    toolName: toolName,
                    command: pseudoCommand,
                    taskContext: latestUserMessage, taskRuntime: judgeRuntime
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
            let trustDeclaration = AgentEnvironmentTrust.covers(
                toolName: toolName,
                command: command,
                declarations: environmentTrustDeclarations
            )
            // 凭据类命中永不因声明放宽——哪怕用户声明"整台机器都是一次性的"。
            // 凭据外读是注入攻击的终点站，这道门不接受来自模型侧的说服。
            let trusted = trustDeclaration != nil && !sandboxDecision.credentialSensitive
            let host = terminalHostContext(arguments: arguments)
            // 远端目标 + 本机路径 = 命令写错了机器。别让它静态放行，也别
            // 拿去问裁判——裁判看不出这个 tab 现在在哪，这是宿主才知道的事。
            if host.isRemote,
               terminalCommandTargetsLocalPathOnRemoteHost(
                   command: command,
                   rootDirectory: rootDirectory,
                   additionalWorkspaceRoots: additionalWorkspaceRoots
               ) {
                return nil
            }
            // 部署窗口在可见终端上同样直接放行。终端那点额外顾虑（不知道
            // 这个 tab 现在指向哪台机器）对部署而言恰恰是常态：发布本来就
            // 是冲着远端去的，而放行的依据是命令族本身，不是它落在哪。
            if trusted, trustDeclaration?.kind == .deploymentWindow {
                return .environmentTrust
            }
            switch SafeCommand.classify(command: command) {
            case .alwaysSafe:
                // Only context-independent reads are static in a visible
                // terminal. SafeCommand also certifies bounded workspace
                // builders/creators, but this terminal may currently point
                // at a remote host or directory, so those still need review.
                // 用户声明这个终端是一次性环境时，"不知道终端指向哪儿"这个
                // 顾虑正好被补上，静态放行不再要求只读沙箱档。
                if trusted
                    || sandboxDecision.mode == .readOnly
                    || sandboxDecision.mode == .readOnlyNetwork {
                    return .staticAllowlist
                }
            case .alwaysDangerous:
                // 声明只把"直接人工"降为"送裁判"，绝不直接放行：裁判仍可否决。
                guard trusted else { return nil }
            case .needsJudgment:
                break
            }
            // 主机拼进 taskContext 而不是另开参数：裁判判决缓存的键里本来
            // 就含它，于是换了机器旧判决自然不复用——同一条命令在本机批过，
            // 不等于在生产 master 上也批过。
            return try await checkedSafetyJudgeApproval(
                toolName: toolName,
                command: command,
                taskContext: "Target host: \(host.line)\n\(latestUserMessage)",
                trustDeclaration: trustDeclaration, taskRuntime: judgeRuntime
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
            return try await checkedSafetyJudgeApproval(
                toolName: toolName,
                command: pseudo,
                taskContext: latestUserMessage, taskRuntime: judgeRuntime
            )
        }

        guard toolName == "run_command" else { return nil }
        guard judgeAutoApprove,
              let command = arguments["command"]?.stringValue() else {
            return nil
        }

        if sandboxDecision.mode == .workspaceWrite
            || sandboxDecision.mode == .workspaceWriteNetwork
            || sandboxDecision.mode == .workspaceWriteNetworkCredentialed
            // 项目仓库脚本落在 `.escalated`（脱 seatbelt），成因是"这是本项目
            // 的代码"。静态免批照旧适用，下面那道命令链体检一步不少。
            || (sandboxDecision.mode == .escalated && sandboxDecision.workspaceScriptTrusted) {
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

        let trustDeclaration = AgentEnvironmentTrust.covers(
            toolName: toolName,
            command: command,
            declarations: environmentTrustDeclarations
        )
        let trusted = trustDeclaration != nil && !sandboxDecision.credentialSensitive
        // 部署窗口是这三类声明里唯一直接放行的：一段发布里跑什么，是一份
        // 列得出来的清单（AgentDeploymentWindow），宿主自己判得了；而
        // testDatabase 的「这库是测试库」只有读懂命令语义才判得了，所以那
        // 一类仍然只降级到送裁判。把部署命令也送裁判等于白声明——用户要的
        // 正是别再为每条 kubectl 停一次。凭据敏感仍然一票否决。
        if trusted, trustDeclaration?.kind == .deploymentWindow {
            return .environmentTrust
        }
        switch SafeCommand.classify(command: command) {
        case .alwaysSafe:
            return .staticAllowlist
        case .alwaysDangerous:
            // 测试库声明把 DROP/TRUNCATE 这类降为"送裁判"，而不是直接放行。
            guard trusted else { return nil }
        case .needsJudgment:
            break
        }

        return try await checkedSafetyJudgeApproval(
            toolName: toolName,
            command: command,
            taskContext: latestUserMessage,
            trustDeclaration: trustDeclaration, taskRuntime: judgeRuntime
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

    /// 完全访问的放行判定：**黑名单式**，与其他三档的白名单式相反。
    ///
    /// 用户选这一档表达的是「互联网、本机文件与凭据都不要再问」，所以这里
    /// 的默认答案是放行，需要理由的是**拦截**：
    ///
    ///  1. `AgentMaliciousCommandDenylist` —— 确定性、不依赖网络、裁判推翻
    ///     不了。抹根目录、格式化、反弹 shell、清历史、凭据外泄这几类，
    ///     命中即回落人工审批卡（该打字确认的照样打字）。
    /// 永不放行的仍然永不放行：`neverAutoApprovedToolNames`（调用方已先拦）、
    /// `change_workspace`、`ask_user` 这类要人回答的工具。
    func fullAccessApprovalSource(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk
    ) -> AgentToolApprovalSource? {
        // 读工具本就不过这道门，和其他档位一样返回 nil（"纯读，从不设卡"），
        // 而不是给它盖一个"完全访问放行"的戳——那会在回合报告里凭空多出
        // 一堆本来就不需要审批的记录。`userInput` 是"要用户回答"，不是
        // "要用户批准"，完全访问不该也不能替他回答。
        switch risk {
        case .read, .userInput:
            return nil
        case .write, .danger:
            break
        }
        // 工作区重绑会把后续所有工具指向别处，任何档位都不自动通过。
        if toolName == "change_workspace" || AgentSessionManagementTools.requiresConfirmation(tool: toolName, arguments: arguments) {
            return nil
        }
        // Saved Terminal recordings may contain protected input and a long
        // chain of side effects. Full Access automates the audited primitive
        // terminal tools, but never turns recording playback into an Agent
        // action; only the user-facing Run button may start it.
        if AgentTerminalAutomationPolicy.forbidsShortcutReplay(toolName: toolName) {
            return nil
        }
        if toolName == "rename_session" {
            return .staticAllowlist
        }
        // 用户在 MCP 设置里把某个服务器标成"不信任"，是一次明确的、针对
        // 具体对象的表态。完全访问表达的是"少问我"，不是"推翻我说过的话"。
        if toolName == "call_mcp_tool",
           let server = arguments["server"]?.stringValue(),
           AgentMCPSettingsStore.trustLevel(name: server) == .untrusted {
            return nil
        }

        guard let command = Self.fullAccessCommandPayload(toolName: toolName, arguments: arguments) else {
            // 非命令型写工具（改文件、本地元数据等）直接放行。
            return .fullAccess
        }
        if let match = AgentMaliciousCommandDenylist.match(command: command) {
            noteFullAccessDenylistHit(match, toolName: toolName)
            return nil
        }
        // 完全访问不再把凭据读取送回人工，也不再经过容易把正常运维误判成
        // 恶意的 AI 裁判。用户已经明确授予这一级权限；宿主只保留上面的
        // 确定性恶意命令黑名单作为最后一道硬地板。
        return .fullAccess
    }

    /// 完全访问要送进确定性黑名单的命令文本。命令型工具取真实命令；
    /// `call_mcp_tool` 复用既有的伪命令表示。
    nonisolated static func fullAccessCommandPayload(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> String? {
        if toolName == "call_mcp_tool" {
            guard let server = arguments["server"]?.stringValue(),
                  let tool = arguments["tool"]?.stringValue() else { return nil }
            return AgentToolAuthorization.mcpJudgePseudoCommand(
                server: server,
                tool: tool,
                argumentsJSON: arguments["arguments_json"]?.stringValue() ?? "{}"
            )
        }
        guard isCommandShapedTool(toolName) else { return nil }
        guard let command = arguments["command"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }
        return command
    }

    /// 黑名单命中要留痕：完全访问下用户几乎看不到审批卡，突然冒出来一张
    /// 必须能解释清楚"为什么偏偏是这条"。
    func noteFullAccessDenylistHit(
        _ match: AgentMaliciousCommandDenylist.Match,
        toolName: String
    ) {
        AgentSandboxAuditLog.recordJudge(
            toolName: toolName,
            command: match.segment,
            model: "full-access-denylist",
            verdict: "deny",
            detail: "\(match.ruleID): \(match.reason)"
        )
    }

    /// Run the auto-approve safety judge for a command-shaped candidate,
    /// threading the operator's cached decision history in as few-shot
    /// context and logging the outcome to judge.jsonl. Returns `.llmJudge`
    /// on a clean YES; `nil` for deny / unavailable (both fall back to the
    /// user). The single choke point every judge path (run_command, MCP,
    /// terminal) routes through.
    func checkedSafetyJudgeApproval(
        toolName: String,
        command: String,
        taskContext: String = "",
        trustDeclaration: AgentEnvironmentTrustDeclaration? = nil,
        kind: AgentSafetyJudgeKind = .developerOperations,
        approvedSource: AgentToolApprovalSource = .llmJudge,
        approvesWhenUnavailable: Bool = false,
        taskRuntime: AgentRuntime? = nil
    ) async throws -> AgentToolApprovalSource? {
        try Task.checkCancellation()
        let scope = taskRuntime?.goalAuthorizationRevision
        let budget = taskRuntime.flatMap { auxiliaryModelExecutionBudget(for: $0) }
        try budget?.check()
        let judgeTaskContext = AgentInjectionDefense.redactedTaskContextForSafetyJudge(taskContext)
        let trustFingerprint = trustDeclaration.map {
            AgentEnvironmentTrust.fingerprint([$0])
        } ?? ""
        // A recent YES for this tool + exact normalized command skips the network
        // round trip entirely. Only allows are cached (a deny still falls
        // through to the user each time), and the static danger gates run
        // BEFORE this point, so a changed argument or typed-confirmation
        // command can never ride an earlier verdict.
        let cacheKey = AgentToolAuthorization.judgeVerdictCacheKey(
            toolName: toolName,
            command: command,
            taskContext: judgeTaskContext,
            environmentTrustFingerprint: trustFingerprint,
            judgeKind: kind
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

        // 候选链依次尝试，直到拿到明确判决。修复审计里成批的「missing api
        // key」死局：主选落到会话自身 provider 而它没配钥匙时，旧逻辑仍然
        // 发起一次注定失败的请求，且唯一替补 some.im 安全卫士恰恰在未登录时
        // 也是 nil——裁判必然缺席，全部回落人工。现在没钥匙的候选不占跳数，
        // 替补链还包括 provider 库里其它当下真正可用的入口。
        // 声明文本逐字带上用户原话：裁判据此判断这条命令是否落在用户
        // 亲口描述的那个环境里，而不是仅凭一个类别标签放宽。
        let trustPayload = trustDeclaration.map { declaration in
            """
            kind: \(declaration.kind.rawValue)
            target: \(declaration.target.isEmpty ? "(unspecified)" : declaration.target)
            user statement: \(declaration.userStatement)
            """
        } ?? ""
        let candidates = safetyJudgeInferenceEnvironment?.configurations ?? safetyJudgeCandidateConfigurations()
        var effectiveConfiguration = candidates.first ?? configurationForSafetyJudge()
        var fallbackDetail = ""
        let judgeCommand = AgentInjectionDefense.redactedCommandForSafetyJudge(command)
        // An empty candidate list means no judge was ever contacted. Saying
        // `missing api key` here reads like a request that failed, and that
        // misdirected the audit for weeks — the requests were never sent.
        var result = AgentSafetyJudgeResult.unavailable(
            candidates.isEmpty ? Self.judgeUnconfiguredReason : "missing api key"
        )
        if candidates.isEmpty {
            // The user is about to be asked to approve something the judge was
            // supposed to settle. That is worth surfacing once per runtime
            // rather than silently degrading forever.
            noteSafetyJudgeUnconfigured()
        }
        for candidate in candidates {
            effectiveConfiguration = candidate
            do {
                result = try await AgentClient(configuration: candidate, session: safetyJudgeInferenceEnvironment?.session,
                    someIMContext: taskRuntime.flatMap { Self.goalPlanningSomeIMContext(configuration: candidate, runtime: $0) },
                    requestLedger: budget?.requestLedger).budgetedSafetyJudge(
                    command: judgeCommand,
                    historyContext: kind == .maliciousIntent ? "" : safetyJudgeHistoryContext(),
                    toolName: toolName,
                    taskContext: judgeTaskContext,
                    environmentTrust: trustPayload,
                    kind: kind, executionBudget: budget
                )
            } catch {
                try Task.checkCancellation()
                guard taskRuntime?.goalAuthorizationRevision == scope else { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
            guard taskRuntime?.goalAuthorizationRevision == scope else { throw CancellationError() }
            guard case .unavailable(let reason) = result else { break }
            if fallbackDetail.isEmpty {
                fallbackDetail = "fallback after \(reason)"
            }
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
        // 静默模式在裁判缺席时也放行——这是用户明确要的语义（"没发现恶意
        // 就放行"），但审计里必须看得出来是"没裁到"而不是"裁过并通过"，
        // 否则事后复盘会把两件事混成一件。
        let allowedWithoutVerdict = approvesWhenUnavailable && {
            if case .unavailable = result { return true }
            return false
        }()
        AgentSandboxAuditLog.recordJudge(
            toolName: toolName,
            command: command,
            model: effectiveConfiguration.model,
            verdict: verdict,
            detail: allowedWithoutVerdict
                ? (detail.isEmpty ? "silent mode: allowed without a verdict" : "\(detail); silent mode: allowed without a verdict")
                : detail
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
        // 只缓存真正的 allow：裁判缺席是瞬时状态，缓存它等于把一次网络
        // 抖动变成 30 分钟的免检期。
        return (result == .allow || allowedWithoutVerdict) ? approvedSource : nil
    }

    /// Tools whose side effects the workspace sandbox alone can't contain —
    /// they run shell commands or reach an MCP server, so even in goal mode
    /// they must clear the static-classify → LLM-judge gate rather than being
    /// blanket-approved. Non-command write tools (file edits within the
    /// sandbox root) are fast-pathed by goal
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
        "cline_cli",
        "opencode_cli"
    ]

    nonisolated static func isTrustedDelegatedAgentTool(_ toolName: String) -> Bool {
        trustedDelegatedAgentToolNames.contains(toolName)
    }

    nonisolated static func subagentHasExactCommandAuthorization(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL? = nil,
        additionalWorkspaceRoots: [URL] = []
    ) -> Bool {
        guard let command = arguments["target_command"]?.stringValue() else {
            return false
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return AgentSandboxPolicy.commandDecision(
            command: trimmed,
            rootDirectory: rootDirectory,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        ).risk != .read
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
        isUnattendedDispatchTask: Bool = false,
        localSandboxDisabled: Bool = false
    ) -> AgentSandboxMode {
        // A scoped grant cannot be widened by an unattended flag or retry.
        // The execution-time guard separately rejects a changed decision.
        if approvalSource == .taskGrant {
            return sandboxDecision.mode == .readOnly ? .readOnly : .workspaceWrite
        }
        if localSandboxDisabled { return .escalated }
        if sandboxDecision.mode == .escalated {
            return .escalated
        }
        // Scheduler-owned nodes must be able to install dependencies, bind
        // localhost ports, launch browser tests, and reach services even when
        // the command itself does not look like a conventional network tool.
        // They already run in isolated task worktrees and have no operator
        // available to approve a second attempt after a seatbelt denial.
        //
        // 光给网络不够：部署、`git push`、`scp` 走的都是用户的 SSH 钥匙，而
        // 除凭证档外的所有档位都会把 HOME 指到临时目录、断掉 ssh-agent。于是
        // 无人值守任务会卡在"网通了但没钥匙"，还没有 operator 能批准提权——
        // 表现就是它什么也干不成，并且因为 seatbelt 把网络拒绝伪装成域名解析
        // 失败，Agent 会一头扎进 DNS 里查半天。写入限制仍由 seatbelt 把守。
        if isUnattendedDispatchTask {
            return .workspaceWriteNetworkCredentialed
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
            switch sandboxDecision.mode {
            case .workspaceWriteNetworkCredentialed:
                return .workspaceWriteNetworkCredentialed
            case .workspaceWriteNetwork:
                return .workspaceWriteNetwork
            default:
                return .workspaceWrite
            }
        case .escalated:
            return .escalated
        // `.fullAccess` 与 `.llmJudge` 同组：按命令**实际需要**的档位跑，
        // 而不是像 workspaceAccess 那样统一抬到 workspace-write。放行理由
        // 宽松不等于沙箱要跟着放宽——真需要越界时，走下面的 seatbelt 拒绝
        // 重跑路径，那条路在完全访问下同样自动。
        // `.environmentTrust` 与 `.llmJudge` 同组，是刻意的等价：部署窗口
        // 放行的那条 kubectl，今天由裁判放行时跑在哪个沙箱档，声明之后就
        // 还跑在哪个档。省掉的是那次确认，不是那道边界。
        case .staticAllowlist, .llmJudge, .fullAccess, .taskGrant, .environmentTrust, .none:
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

    /// 裁判候选链，按“当下真正可用”排序、去重、封顶 3 家：
    /// 1. `configurationForSafetyJudge()` 的主选——但没配钥匙就不占第一跳
    ///    （requiresAPIKey 且 key 为空的候选必然 unavailable，发请求纯烧超时）；
    /// 2. some.im 安全卫士（已登录时通常就是主选，去重兜住）；
    /// 3. provider 库里其它有可用钥匙（或不需要钥匙）的入口，flash 档。
    /// 空数组意味着当前一台裁判都请不来，调用方按 unavailable 回落人工。
    func safetyJudgeCandidateConfigurations() -> [AgentConfiguration] {
        var candidates: [AgentConfiguration] = []
        func append(_ configuration: AgentConfiguration) {
            guard candidates.count < 3, !candidates.contains(configuration) else { return }
            candidates.append(configuration)
        }
        let primary = configurationForSafetyJudge()
        if !primary.requiresAPIKey || !primary.apiKey.isEmpty {
            append(primary)
        }
        if let managed = someIMSecurityGuardConfiguration() {
            append(managed)
        }
        for entry in agentProviderLibrary.entries {
            guard candidates.count < 3 else { break }
            // some.im 入口只走上面的安全卫士路径：普通 entry 的 per-entry
            // key 槽位与共享会话 key 不同，绕开卫士构造会拿到空钥匙配置。
            guard entry.providerID != AgentProviderPreset.someIMID else { continue }
            var configuration = entry.makeConfiguration(routingMode: .flash).normalized
            if configuration.requiresAPIKey, configuration.apiKey.isEmpty {
                let key = providerLibraryAPIKey(forProviderID: entry.providerID)
                guard !key.isEmpty else { continue }
                configuration.apiKey = key
            }
            append(configuration.normalized)
        }
        return candidates
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
        // Unattended variants on purpose: a Keychain read that does not land
        // is not a sign-out, and treating it as one is exactly how the judge
        // ended up falling through to a key-less provider and handing the
        // decision back to the user. See `apiKeyForUnattendedUse()`.
        guard SomeIMIntegrationStore.hasSessionForUnattendedUse() else {
            return nil
        }
        let key = SomeIMIntegrationStore.apiKeyForUnattendedUse()
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
        if runtime.resolveLocalPanelPreview(id: id, decision: decision) {
            return
        }
        guard runtime.toolCalls[index].status == .pendingApproval
            || runtime.toolCalls[index].status == .awaitingConfirm
            || runtime.toolCalls[index].status == .awaitingUserAnswer else {
            return
        }
        // Match the exact call, even when a delegated executor is also waiting.
        // Future serially queued calls still have no waiter and cannot accept input.
        guard let waiter = runtime.toolDecisionWaiters.removeValue(forKey: id) else {
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

        if case .approved = decision {
            runtime.toolCalls[index].status = .running
        } else if case .answered = decision {
            runtime.toolCalls[index].status = .running
        }
        waiter.continuation.resume(returning: decision)
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
                && !runtime.localPanelPreviewCallIDs.contains(call.id)
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

                let source: AgentToolApprovalSource?
                do { source = try await checkedAutoApprovalSource(
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
                    environmentTrustDeclarations: runtime.environmentTrustDeclarations,
                    computerUseOwner: runtime.computerUseOwner,
                    latestUserMessage: runtime.messages.last(where: { $0.isOperatorInput })?.content ?? "",
                    taskRuntime: call.externalID.hasPrefix("delegated:") || call.externalID.hasPrefix("subagent:") ? nil : runtime,
                    budgetRuntime: runtime
                ) } catch {
                    let notice = handleApprovalRequestStop(error, runtime: runtime)
                    settleHostStoppedApprovals(pendingCallIDs, notice: notice, runtime: runtime)
                    return
                }
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

    func runtimeAndToolCallIndex(containing id: AgentToolCall.ID) -> (runtime: AgentRuntime, index: Int)? {
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

    /// Audit reason recorded when no judge was contacted at all. Deliberately
    /// distinct from `missing api key`, which describes a request that was
    /// actually sent and rejected: telling those apart is the difference
    /// between "the provider refused us" and "we never had a judge".
    static let judgeUnconfiguredReason = "no judge configured"

    /// Tell the user once per conversation that manual approvals are a
    /// configuration gap, not the design.
    ///
    /// Without this the degradation is invisible: every command quietly turns
    /// into a confirmation dialog and the user concludes the product simply
    /// works that way. August 2026 audit data: 211 such approvals, none of
    /// which the user could have known were avoidable.
    private func noteSafetyJudgeUnconfigured() {
        guard let runtime = activeRuntime,
              !runtime.didNoticeSafetyJudgeUnconfigured else { return }
        runtime.didNoticeSafetyJudgeUnconfigured = true
        // Never displace a real error the user still needs to read.
        guard runtime.errorMessage == nil else { return }
        runtime.errorMessage = L10n.Approval.safetyJudgeUnconfigured
        runtime.errorDetails = nil
        runtime.errorSeverity = .notice
    }

    nonisolated static func goalPlanningCanAutoApprove(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        switch toolName {
        case "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli", "opencode_cli":
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
            // `workspaceWriteNetwork` is included because ordinary builds
            // (`go build`, `swift test`) now carry the registry grant. The
            // genuinely outward-reaching cases — curl/ssh/scp and explicit
            // dependency installs — are already rejected by
            // `commandUsesExternalAccess` above, so widening here restores
            // one-click builds without loosening that boundary.
            return sandboxDecision.mode == .readOnly
                || sandboxDecision.mode == .workspaceWrite
                || sandboxDecision.mode == .workspaceWriteNetwork
                || sandboxDecision.mode == .workspaceWriteNetworkCredentialed
        case "kill_job", "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli", "opencode_cli",
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
