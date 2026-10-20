import SwiftUI

enum AgentConversationEntryAttention {
    static func badgeCount(destination: AgentPrimaryDestination, pendingRequestCount: Int) -> Int {
        destination == .conversation ? 0 : max(0, pendingRequestCount)
    }
}

/// Observe attention changes only in this small navigation row, rather than
/// invalidating the entire sidebar and all of its session groups.
struct AgentConversationEntryRow: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var coordinator = AgentDockBadgeCoordinator.shared

    var body: some View {
        SidebarActionRow(
            icon: "bubble.left",
            title: appState.agentConversationEntryTitle,
            shortcut: nil,
            isSelected: appState.agentPrimaryDestination == .conversation,
            badgeCount: AgentConversationEntryAttention.badgeCount(
                destination: appState.agentPrimaryDestination,
                pendingRequestCount: coordinator.pendingRequestCount
            ),
            trailingIcon: "square.and.pencil",
            trailingHelp: L10n.Sidebar.newChatAction,
            trailingAction: {
                appState.startNewAgentSession()
                appState.agentComposerFocusRevision += 1
            }
        ) {
            appState.activateAgentConversationEntry()
        }
    }
}

struct AgentConversationAttentionBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.primary.opacity(0.10), in: Capsule())
            .fixedSize()
            .help(L10n.Dock.pendingApprovalHeader)
            .accessibilityLabel(Text(L10n.Sidebar.pendingApprovalHeader))
            .accessibilityValue(Text(count, format: .number))
    }
}
