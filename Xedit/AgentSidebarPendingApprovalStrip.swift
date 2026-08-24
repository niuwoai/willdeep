//
//  AgentSidebarPendingApprovalStrip.swift
//  WillDeep
//
//  Sits in the sidebar's pinned footer, right above the app-update banner:
//  the sessions that are blocked on the user, one click away. Same predicate
//  as the Dock badge, so a "3" on the Dock icon and this strip always tell
//  the same story.
//

import SwiftUI

struct AgentSidebarPendingApprovalStrip: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var coordinator = AgentDockBadgeCoordinator.shared

    var body: some View {
        let entries = coordinator.pendingEntries(for: appState)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                header(total: entries.count)
                ForEach(entries.prefix(AgentSessionApprovalBadgeLogic.quickJumpLimit)) { entry in
                    AgentSidebarPendingApprovalRow(entry: entry) {
                        appState.revealAgentSessionFromNotification(id: entry.sessionID)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.11))
            )
            .padding(.bottom, 6)
        }
    }

    private func header(total: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(L10n.Sidebar.pendingApprovalHeader)
                .font(.system(size: 10, weight: .semibold))
            Spacer(minLength: 0)
            Text("\(total)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 2)
    }
}

private struct AgentSidebarPendingApprovalRow: View {
    let entry: AgentPendingApprovalEntry
    let onSelect: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text(displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? appState.editorSettings.interfaceSkin.palette.hoverFill : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L10n.Sidebar.pendingApprovalRowTooltip)
        .accessibilityLabel(Text(displayTitle))
        .accessibilityHint(Text(L10n.Sidebar.pendingApprovalRowTooltip))
    }

    /// A session blocked before its first reply still carries the placeholder
    /// title. Showing "New Chat" three times over is useless, so fall back to
    /// the same wording the row badge uses.
    private var displayTitle: String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || AgentSessionStore.isPlaceholderTitle(trimmed) {
            return L10n.Sidebar.sessionRowWaitingApproval
        }
        return trimmed
    }
}
