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
            VStack(alignment: .leading, spacing: AgentSidebarPendingApprovalStyle.contentSpacing) {
                header(total: entries.count)
                ForEach(entries.prefix(AgentSessionApprovalBadgeLogic.quickJumpLimit)) { entry in
                    AgentSidebarPendingApprovalRow(entry: entry) {
                        appState.revealAgentSessionFromNotification(id: entry.sessionID)
                    }
                }
            }
            .padding(.horizontal, AgentSidebarPendingApprovalStyle.horizontalPadding)
            .padding(.vertical, AgentSidebarPendingApprovalStyle.verticalPadding)
            .background(
                AgentSidebarPendingApprovalStyle.containerShape
                    .fill(AgentSidebarPendingApprovalStyle.containerFill)
            )
            .overlay(
                AgentSidebarPendingApprovalStyle.containerShape
                    .stroke(
                        AgentSidebarPendingApprovalStyle.containerStroke,
                        lineWidth: AgentSidebarPendingApprovalStyle.containerStrokeWidth
                    )
            )
            .padding(.bottom, 6)
        }
    }

    private func header(total: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.raised")
                .font(.system(size: 9, weight: .medium))
            Text(L10n.Sidebar.pendingApprovalHeader)
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 0)
            Text("\(total)")
                .font(.system(size: 10, weight: .regular))
                .monospacedDigit()
        }
        .foregroundStyle(AgentSidebarPendingApprovalStyle.headerForeground)
        .padding(.horizontal, 2)
    }
}

/// Waiting is an informational state, not success or danger. Keep this strip
/// monochrome so it sits behind the user's actual words instead of reading as
/// a large status alert. The dynamic system colors preserve the same grayscale
/// hierarchy in light and dark appearances.
private enum AgentSidebarPendingApprovalStyle {
    static let contentSpacing: CGFloat = 3
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 7
    static let containerCornerRadius: CGFloat = 9
    static let containerStrokeWidth: CGFloat = 0.5

    static var containerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
    }

    static var containerFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.66)
    }

    static var containerStroke: Color {
        Color.primary.opacity(0.08)
    }

    static var headerForeground: Color {
        Color.secondary.opacity(0.82)
    }

    static var rowForeground: Color {
        Color.primary.opacity(0.88)
    }

    static var markerForeground: Color {
        Color.secondary.opacity(0.68)
    }

    static var hoverFill: Color {
        Color.primary.opacity(0.055)
    }
}

private struct AgentSidebarPendingApprovalRow: View {
    let entry: AgentPendingApprovalEntry
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AgentSidebarPendingApprovalStyle.markerForeground)
                    .frame(width: 4, height: 4)
                Text(displayTitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AgentSidebarPendingApprovalStyle.rowForeground)
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
                    .fill(isHovered ? AgentSidebarPendingApprovalStyle.hoverFill : .clear)
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
