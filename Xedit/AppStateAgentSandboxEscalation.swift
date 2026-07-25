//
//  AppStateAgentSandboxEscalation.swift
//  WillDeep
//
//  When a local sandboxed `run_command` is blocked by seatbelt, pause and ask
//  the user whether to re-run the same command outside the sandbox instead of
//  treating the denial as a dead-end tool failure.
//

import Foundation

enum AgentSandboxEscalationResolution: Equatable {
    /// Not a sandbox-denial case, or already escalated / remote — keep failing.
    case notApplicable
    /// User declined; surface as a denied tool call with this reason.
    case declined(reason: String)
    /// Re-run immediately with `.escalated`.
    case retryEscalated(approvalSource: AgentToolApprovalSource)
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
        if isAgentCommandSignatureAlwaysAllowed(toolName: toolName, arguments: arguments) {
            return .retryEscalated(approvalSource: .escalated)
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
            status: .pendingApproval
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
            return .retryEscalated(approvalSource: pinned ? .alwaysAllowList : .escalated)
        }
    }

    /// Signature pin check that does not require `.write` risk — sandbox
    /// denials also happen on otherwise read-tier shell commands.
    func isAgentCommandSignatureAlwaysAllowed(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
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
                case .retryEscalated(let approvalSource):
                    escalationAttempted = true
                    executionContext = context.withSandboxMode(.escalated)
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .running
                        // The retry literally leaves the sandbox — keep the
                        // audit badge honest even when Always Allow also pinned.
                        runtime.toolCalls[index].approvalSource = approvalSource == .alwaysAllowList
                            ? .escalated
                            : approvalSource
                        runtime.toolCalls[index].errorMessage = nil
                        runtime.toolCalls[index].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
                        runtime.toolCalls[index].arguments["_sandbox"] = .string(AgentSandboxMode.escalated.rawValue)
                        runtime.toolCalls[index].arguments["_approval_reason"] = .string(
                            L10n.ToolCard.sandboxEscalationApprovalReason
                        )
                    }
                    AgentSandboxAuditLog.append(
                        toolName: toolName,
                        arguments: displayArguments,
                        decision: AgentSandboxDecision(
                            mode: .escalated,
                            requiresUserApproval: true,
                            requiresTypedConfirmation: false,
                            reason: L10n.ToolCard.sandboxEscalationApprovalReason,
                            prefixRule: nil
                        ),
                        approvalSource: .escalated,
                        outcome: "sandbox_escalation_retry"
                    )
                    continue
                }
            }
        }
    }
}
