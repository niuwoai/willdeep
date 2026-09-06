//
//  AppStateAgentSandboxEscalation.swift
//  WillDeep
//
//  When a local sandboxed `run_command` is blocked by seatbelt, either retry
//  automatically under Smart Approval or pause for the user's decision.
//

import Foundation

enum AgentSandboxEscalationResolution: Equatable {
    /// Not a sandbox-denial case, or already escalated / remote — keep failing.
    case notApplicable
    /// User declined; surface as a denied tool call with this reason.
    case declined(reason: String)
    /// Re-run immediately with `.escalated`. `requiresUserApproval` keeps the
    /// audit trail honest when Smart Approval performed the retry itself.
    case retryEscalated(
        approvalSource: AgentToolApprovalSource,
        requiresUserApproval: Bool
    )
}

enum AgentSandboxedCommandRunOutcome {
    case succeeded(AgentToolResult)
    /// User refused to leave the sandbox; keep the original denial detail for the model.
    case escalationDeclined(reason: String, denialDetail: String)
}

extension AppState {
    /// Offer (or auto-approve) a sandbox-escape retry for a failed local
    /// `run_command`. Returns `.notApplicable` when the failure should stay a
    /// normal tool error.
    func resolveSandboxEscalation(
        for error: Error,
        toolName: String,
        arguments: [String: AgentJSONValue],
        recordID: AgentToolCall.ID,
        runtime: AgentRuntime,
        currentSandboxMode: AgentSandboxMode,
        isRemoteWorkspace: Bool,
        alreadyAttempted: Bool
    ) async -> AgentSandboxEscalationResolution {
        guard !alreadyAttempted,
              !isRemoteWorkspace,
              toolName == "run_command",
              currentSandboxMode != .escalated,
              AgentSandboxPolicy.looksLikeSandboxDenial(
                error: error,
                sandboxMode: currentSandboxMode
              ) else {
            return .notApplicable
        }

        // A pinned Always Allow signature means the user already trusted this
        // command family — don't make them click through the same wall twice.
        if runtime.toolCalls.first(where: { $0.id == recordID })?.approvalSource == .taskGrant {
            return .notApplicable
        }
        if isAgentCommandSignatureAlwaysAllowed(toolName: toolName, arguments: arguments) {
            return .retryEscalated(
                approvalSource: .alwaysAllowList,
                requiresUserApproval: false
            )
        }

        // The exact command has already cleared the normal tool gate before
        // it can reach this failure path. Smart Approval therefore owns the
        // same-command retry as well; asking again would turn the mode into
        // Request Every Time by accident. Workspace Access stays manual here
        // because leaving seatbelt broadens access beyond the workspace that
        // mode explicitly grants.
        if Self.smartApprovalAutomaticallyRetriesSandboxDenial(
            approvalMode: runtime.approvalMode
        ) {
            let priorSource = runtime.toolCalls
                .first(where: { $0.id == recordID })?
                .approvalSource
                ?? .staticAllowlist
            return .retryEscalated(
                approvalSource: priorSource,
                requiresUserApproval: false
            )
        }

        let denialDetail = sandboxDenialDetail(from: error)
        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
            runtime.toolCalls[index].status = .pendingApproval
            runtime.toolCalls[index].errorMessage = nil
            runtime.toolCalls[index].result = nil
            runtime.toolCalls[index].approvalSource = nil
            runtime.toolCalls[index].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(true)
            runtime.toolCalls[index].arguments[AgentSandboxPolicy.sandboxDenialDetailArgumentKey] = .string(denialDetail)
            runtime.toolCalls[index].arguments["_sandbox"] = .string(AgentSandboxMode.escalated.rawValue)
            runtime.toolCalls[index].arguments["_approval_reason"] = .string(
                L10n.ToolCard.sandboxEscalationApprovalReason
            )
        }

        AgentToolApprovalNotifier.notifyIfBackgrounded(
            toolName: toolName,
            arguments: arguments,
            status: .pendingApproval,
            runtimeID: runtime.id,
            sessionTitle: runtime.session.title
        )

        let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
        if Task.isCancelled {
            return .declined(reason: "Cancelled")
        }

        switch decision {
        case .denied(let reason):
            return .declined(reason: reason)
        case .answered:
            // ask_user answers shouldn't appear here; treat as decline.
            return .declined(reason: "User denied")
        case .approved:
            let pinned = isAgentCommandSignatureAlwaysAllowed(
                toolName: toolName,
                arguments: arguments
            )
            return .retryEscalated(
                approvalSource: pinned ? .alwaysAllowList : .escalated,
                requiresUserApproval: true
            )
        }
    }

    /// 完全访问和智能审核一样自动重跑：一条命令能走到"被 seatbelt 拒绝"
    /// 这一步，说明它已经过了本档位的放行判定。此时再弹一张"允许无沙箱
    /// 重跑吗"的卡，等于把刚刚放行的决定推翻重问一遍。
    nonisolated static func smartApprovalAutomaticallyRetriesSandboxDenial(
        approvalMode: AgentApprovalMode
    ) -> Bool {
        approvalMode == .smart || approvalMode == .fullAccess
    }

    /// Background commands finish after their originating tool call has
    /// returned, so they cannot reuse the foreground approval waiter. Carry a
    /// host-derived one-shot retry grant only when the session policy already
    /// permits it. Request Every Time and Workspace Access deliberately return
    /// nil unless the exact command has an Always Allow grant.
    nonisolated static func automaticBackgroundSandboxRetryApprovalSource(
        approvalMode: AgentApprovalMode,
        existingApprovalSource: AgentToolApprovalSource?,
        isUnattendedDispatchTask: Bool
    ) -> AgentToolApprovalSource? {
        guard existingApprovalSource != .taskGrant else { return nil }
        if isUnattendedDispatchTask {
            return .dispatchTask
        }
        if existingApprovalSource == .alwaysAllowList {
            return .alwaysAllowList
        }
        guard smartApprovalAutomaticallyRetriesSandboxDenial(
            approvalMode: approvalMode
        ) else {
            return nil
        }
        return existingApprovalSource ?? .staticAllowlist
    }

    /// Signature pin check that does not require `.write` risk — sandbox
    /// denials also happen on otherwise read-tier shell commands.
    func isAgentCommandSignatureAlwaysAllowed(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        guard !toolName.hasPrefix("computer_use_") else {
            return false
        }
        guard !agentAlwaysAllowedCommands.isEmpty else { return false }
        let signatures = Set(
            AgentToolAuthorization.matchingSignatures(toolName: toolName, arguments: arguments)
        )
        guard !signatures.isEmpty else { return false }
        return agentAlwaysAllowedCommands.contains { signatures.contains($0.commandSignature) }
    }

    private func sandboxDenialDetail(from error: Error) -> String {
        let raw: String
        if let toolError = error as? AgentToolError,
           case let .commandFailed(_, output) = toolError {
            raw = output
        } else {
            raw = error.localizedDescription
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 280 { return trimmed }
        return String(trimmed.suffix(280))
    }

    /// Runs a local tool once, and if seatbelt blocks it, asks to retry
    /// escalated. Throws on ordinary failures / cancellation so the caller
    /// can keep its existing catch paths.
    func runToolHandlingSandboxEscalation(
        toolName: String,
        arguments: [String: AgentJSONValue],
        displayArguments: [String: AgentJSONValue],
        recordID: AgentToolCall.ID,
        runtime: AgentRuntime,
        context: AgentToolContext,
        workspaceLocation: WorkspaceLocation?
    ) async throws -> AgentSandboxedCommandRunOutcome {
        var executionContext = context
        var escalationAttempted = false
        let isRemoteWorkspace: Bool = {
            if case .remote = workspaceLocation { return true }
            return false
        }()

        while true {
            do {
                let result = try await AgentToolRunner.run(
                    name: toolName,
                    arguments: arguments,
                    context: executionContext
                )
                return .succeeded(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let resolution = await resolveSandboxEscalation(
                    for: error,
                    toolName: toolName,
                    arguments: displayArguments,
                    recordID: recordID,
                    runtime: runtime,
                    currentSandboxMode: executionContext.sandboxMode,
                    isRemoteWorkspace: isRemoteWorkspace,
                    alreadyAttempted: escalationAttempted
                )
                switch resolution {
                case .notApplicable:
                    throw error
                case .declined(let reason):
                    return .escalationDeclined(
                        reason: reason,
                        denialDetail: sandboxDenialDetail(from: error)
                    )
                case .retryEscalated(let approvalSource, let requiresUserApproval):
                    escalationAttempted = true
                    executionContext = context.withSandboxMode(.escalated)
                    let effectiveApprovalSource: AgentToolApprovalSource = requiresUserApproval
                        ? .escalated
                        : approvalSource
                    let approvalReason = requiresUserApproval
                        ? L10n.ToolCard.sandboxEscalationApprovalReason
                        : L10n.ToolCard.sandboxEscalationAutomaticApprovalReason
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .running
                        runtime.toolCalls[index].approvalSource = effectiveApprovalSource
                        runtime.toolCalls[index].errorMessage = nil
                        runtime.toolCalls[index].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
                        runtime.toolCalls[index].arguments["_sandbox"] = .string(AgentSandboxMode.escalated.rawValue)
                        runtime.toolCalls[index].arguments["_approval_reason"] = .string(approvalReason)
                    }
                    AgentSandboxAuditLog.append(
                        toolName: toolName,
                        arguments: displayArguments,
                        decision: AgentSandboxDecision(
                            mode: .escalated,
                            requiresUserApproval: requiresUserApproval,
                            requiresTypedConfirmation: false,
                            reason: approvalReason,
                            prefixRule: nil
                        ),
                        approvalSource: effectiveApprovalSource,
                        outcome: "sandbox_escalation_retry"
                    )
                    continue
                }
            }
        }
    }
}
