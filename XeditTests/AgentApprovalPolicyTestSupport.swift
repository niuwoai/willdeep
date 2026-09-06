import Foundation
import Testing
@testable import WillDeep

/// Preserve the pre-budget policy assertions without a production API that
/// conflates a thrown host stop with "ask the user". Unexpected errors still
/// fail these existing tests; new budget tests call the throwing API directly.
@MainActor
extension AppState {
    func autoApprovalSource(
        toolName: String, arguments: [String: AgentJSONValue], risk: AgentToolRisk, rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = [], interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart, conversationAllowedToolSignatures: Set<String> = [],
        environmentTrustDeclarations: [AgentEnvironmentTrustDeclaration] = [], computerUseOwner: AgentComputerUseOwner? = nil,
        latestUserMessage: String = "", taskRuntime: AgentRuntime? = nil
    ) async -> AgentToolApprovalSource? {
        do {
            return try await checkedAutoApprovalSource(toolName: toolName, arguments: arguments, risk: risk,
                rootDirectory: rootDirectory, additionalWorkspaceRoots: additionalWorkspaceRoots,
                interactionMode: interactionMode, approvalMode: approvalMode,
                conversationAllowedToolSignatures: conversationAllowedToolSignatures,
                environmentTrustDeclarations: environmentTrustDeclarations, computerUseOwner: computerUseOwner,
                latestUserMessage: latestUserMessage, taskRuntime: taskRuntime)
        } catch {
            Issue.record("Unexpected error in approval policy fixture: \(error)")
            return nil
        }
    }
}

@MainActor
extension AgentClient {
    func judgeCommandSafety(command: String, historyContext: String = "", toolName: String = "run_command",
                            taskContext: String = "", environmentTrust: String = "",
                            kind: AgentSafetyJudgeKind = .developerOperations) async -> AgentSafetyJudgeResult {
        do {
            return try await budgetedSafetyJudge(command: command, historyContext: historyContext, toolName: toolName,
                taskContext: taskContext, environmentTrust: environmentTrust, kind: kind)
        } catch {
            Issue.record("Unexpected error in safety transport fixture: \(error)")
            return .unavailable("fixture error")
        }
    }
}
