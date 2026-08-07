//
//  AgentScheduledTaskCardView.swift
//  WillDeep
//
//  Transcript-inline card for a task scheduled via `schedule_task`. Shows the
//  task name / schedule / goal. While the backing routine still exists its
//  Open action reveals the task's detail (sidebar editor). Once the task
//  self-completes (complete_scheduled_task removed the routine) the card stays
//  in the transcript as a record but renders in a muted "done" state.
//

import SwiftUI

enum AgentScheduledTaskCardLayout {
    static let maximumWidth: CGFloat = 460
    static let minimumHeight: CGFloat = 64
    static let cornerRadius: CGFloat = 12
    static let iconTileSize: CGFloat = 36
    static let iconTileCornerRadius: CGFloat = 10
    static let openButtonCornerRadius: CGFloat = 8
}

enum AgentScheduledTaskCardNavigation {
    static func open(cardID: UUID, in appState: AppState) {
        appState.pendingRoutineDetailID = cardID
        appState.agentPrimaryDestination = .scheduledTasks
        appState.agentSidePanelKind = nil
        appState.agentSidePanelRequest = nil
    }
}

struct AgentScheduledTaskCardView: View {
    let card: AgentScheduledTaskCard
    @EnvironmentObject private var appState: AppState

    private var isActive: Bool {
        appState.agentRoutines.contains { $0.id == card.id }
    }

    private var helpText: String {
        guard let goal = card.goal, !goal.isEmpty else { return card.prompt }
        return goal
    }

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette

        return content
            .frame(
                maxWidth: AgentScheduledTaskCardLayout.maximumWidth,
                minHeight: AgentScheduledTaskCardLayout.minimumHeight,
                alignment: .leading
            )
            .background(
                RoundedRectangle(
                    cornerRadius: AgentScheduledTaskCardLayout.cornerRadius,
                    style: .continuous
                )
                .fill(palette.panelFill.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: AgentScheduledTaskCardLayout.cornerRadius,
                    style: .continuous
                )
                .stroke(palette.hairline.opacity(0.9), lineWidth: 1)
            )
            .opacity(isActive ? 1 : 0.7)
            .help(helpText)
    }

    private var content: some View {
        let palette = appState.editorSettings.interfaceSkin.palette

        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: AgentScheduledTaskCardLayout.iconTileCornerRadius,
                    style: .continuous
                )
                .fill(palette.hoverFill.opacity(isActive ? 0.85 : 0.48))

                Image(systemName: isActive ? "clock" : "checkmark.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(
                width: AgentScheduledTaskCardLayout.iconTileSize,
                height: AgentScheduledTaskCardLayout.iconTileSize
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(card.scheduleSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if isActive {
                Button(action: openTask) {
                    Text(L10n.ScheduledTaskCard.open)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(
                                cornerRadius: AgentScheduledTaskCardLayout.openButtonCornerRadius,
                                style: .continuous
                            )
                            .fill(palette.controlFill.opacity(0.55))
                        )
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: AgentScheduledTaskCardLayout.openButtonCornerRadius,
                                style: .continuous
                            )
                            .stroke(palette.hairline.opacity(0.9), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Text(L10n.ScheduledTaskCard.completed)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private func openTask() {
        AgentScheduledTaskCardNavigation.open(cardID: card.id, in: appState)
    }
}
