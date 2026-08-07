//
//  AgentDispatchGoalCommandComposer.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchGoalCommandComposer: View {
    let goal: AgentDispatchGoal
    @Binding var text: String
    let onSend: () -> Void
    let onAddTask: () -> Void
    let onAdjustPlan: () -> Void
    let onTogglePause: () -> Void

    private var hasWorkspace: Bool {
        goal.isWorkspaceBound
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(L10n.Dispatch.goalCommandTitle)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(L10n.Dispatch.queuedForSafePoint)
                Spacer()
                if let latest = goal.commands.first {
                    Label(
                        AgentDispatchPresentation.commandStatus(latest),
                        systemImage: statusSymbol(latest)
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(latest))
                    .lineLimit(1)
                }
            }
            ZStack(alignment: .bottomTrailing) {
                SubmitOnReturnTextView(
                    text: $text,
                    placeholder: hasWorkspace
                        ? L10n.Dispatch.goalCommandPlaceholder
                        : L10n.Dispatch.workspaceRequired,
                    fontSize: 12,
                    onSubmit: submit
                )
                .frame(height: 66)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.secondary.opacity(0.17), lineWidth: 1)
                )
                .disabled(!hasWorkspace)
                Button(action: submit) {
                    Label(L10n.Dispatch.send, systemImage: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    !hasWorkspace
                        || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .padding(8)
            }
            HStack(spacing: 8) {
                quickAction(
                    L10n.Dispatch.addTask,
                    symbol: "plus.circle",
                    action: onAddTask
                )
                quickAction(
                    L10n.Dispatch.adjustPlan,
                    symbol: "point.3.connected.trianglepath.dotted",
                    action: onAdjustPlan
                )
                quickAction(
                    goal.isPaused ? L10n.Dispatch.resumeAll : L10n.Dispatch.pauseAll,
                    symbol: goal.isPaused ? "play.circle" : "pause.circle",
                    tint: goal.isPaused ? .green : .orange,
                    action: onTogglePause
                )
                Spacer()
            }
            .disabled(!hasWorkspace)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
    }

    /// 回车与「发送」按钮走同一道闸：没有绑定工作区、或输入区为空时，
    /// 回车只是无事发生，不能绕过按钮上的 `disabled` 把空指令发出去。
    private func submit() {
        guard hasWorkspace,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        onSend()
    }

    private func quickAction(
        _ title: String,
        symbol: String,
        tint: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(tint.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func statusSymbol(_ command: AgentDispatchCommand) -> String {
        switch command.status {
        case .applied: return "checkmark.circle.fill"
        case .queued: return "clock.fill"
        case .pendingConfirmation: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func statusColor(_ command: AgentDispatchCommand) -> Color {
        switch command.status {
        case .applied: return .green
        case .queued: return .blue
        case .pendingConfirmation: return .orange
        case .cancelled: return .secondary
        }
    }
}
