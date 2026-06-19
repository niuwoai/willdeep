//
//  AgentSessionApprovalBadge.swift
//  WillDeep
//
//  Compact sidebar badge for sessions that are blocked on user input:
//  tool approval, danger confirmation, ask_user answers, patch approval,
//  or a proposed Plan.
//

import SwiftUI

enum AgentSessionApprovalBadgeLogic {
    static func needsUserApproval(
        session: AgentSession,
        toolCallStatuses: [AgentToolCallStatus] = [],
        patchStatuses: [AgentPatchStatus] = [],
        planStatus: AgentPlan.Status? = nil
    ) -> Bool {
        if toolCallStatuses.contains(where: toolCallNeedsUserApproval(_:)) {
            return true
        }
        if patchStatuses.contains(.pending) {
            return true
        }
        return (planStatus ?? session.currentPlan?.status) == .proposed
    }

    private static func toolCallNeedsUserApproval(_ status: AgentToolCallStatus) -> Bool {
        switch status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return true
        case .running, .succeeded, .failed, .denied:
            return false
        }
    }
}

struct AgentSessionApprovalBadge: View {
    let session: AgentSession
    let runtime: AgentRuntime?

    var body: some View {
        if let runtime {
            ObservedApprovalBadge(session: session, runtime: runtime)
        } else if AgentSessionApprovalBadgeLogic.needsUserApproval(session: session) {
            Badge()
        }
    }
}

private struct ObservedApprovalBadge: View {
    let session: AgentSession
    @ObservedObject var runtime: AgentRuntime

    var body: some View {
        if AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            toolCallStatuses: runtime.toolCalls.map(\.status),
            patchStatuses: runtime.patchProposals.map(\.status),
            planStatus: runtime.currentPlan?.status
        ) {
            Badge()
        }
    }
}

private struct Badge: View {
    var body: some View {
        Text(L10n.Sidebar.sessionRowWaitingApproval)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.green)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.14), in: Capsule())
            .help(L10n.Sidebar.sessionRowWaitingApprovalTooltip)
            .accessibilityLabel(Text(L10n.Sidebar.sessionRowWaitingApprovalTooltip))
    }
}
