//
//  AgentScheduledTaskCardView.swift
//  WillDeep
//
//  Transcript-inline card for a task scheduled via `schedule_task`. Shows the
//  task name / schedule / goal. While the backing routine still exists the
//  card is tappable → opens the task's detail (sidebar editor). Once the task
//  self-completes (complete_scheduled_task removed the routine) the card stays
//  in the transcript as a record but renders in a muted "done" state.
//

import SwiftUI

struct AgentScheduledTaskCardView: View {
    let card: AgentScheduledTaskCard
    @EnvironmentObject private var appState: AppState

    private var isActive: Bool {
        appState.agentRoutines.contains { $0.id == card.id }
    }

    var body: some View {
        Button {
            guard isActive else { return }
            appState.pendingRoutineDetailID = card.id
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "clock.badge" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(L10n.ScheduledTaskCard.badge)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if isActive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(card.scheduleSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !isActive {
                    Text("· " + L10n.ScheduledTaskCard.completed)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let goal = card.goal, !goal.isEmpty {
                Text(L10n.ScheduledTaskCard.goalPrefix + goal)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(isActive ? 0.35 : 0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isActive ? 1 : 0.7)
    }
}
