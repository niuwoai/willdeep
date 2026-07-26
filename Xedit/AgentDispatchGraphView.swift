//
//  AgentDispatchGraphView.swift
//  WillDeep
//

import SwiftUI

enum AgentDispatchPresentation {
    static func executorChoiceName(_ choice: AgentDispatchExecutorChoice) -> String {
        choice.pinnedExecutor?.displayName ?? L10n.Dispatch.automatic
    }

    static func targetChoiceName(
        _ choice: AgentDispatchTargetChoice,
        runtimes: [RuntimeDescriptor],
        automaticSuffix: String? = nil
    ) -> String {
        switch choice {
        case .automatic:
            return automaticSuffix.map { L10n.Dispatch.automatic + $0 }
                ?? L10n.Dispatch.automatic
        case .local:
            return L10n.Dispatch.currentMac
        case .remote(let id):
            guard let runtime = runtimes.first(where: { $0.id == id }) else {
                return L10n.Dispatch.notProbed
            }
            return "\(runtime.displayName) · SSH"
        }
    }

    static func taskStateColor(_ state: AgentDispatchTaskState) -> Color {
        switch state {
        case .blocked: return .secondary
        case .queued: return .indigo
        case .running: return .blue
        case .reviewing: return .orange
        case .accepted: return .mint
        case .failed: return .red
        case .cancelled: return .secondary
        case .merged: return .green
        }
    }

    static func commandStatus(_ command: AgentDispatchCommand) -> String {
        switch command.status {
        case .applied: return L10n.Dispatch.appliedImmediately
        case .queued: return L10n.Dispatch.queuedForSafePoint
        case .pendingConfirmation: return L10n.Dispatch.interruptRequired
        case .cancelled: return L10n.Dispatch.cancelled
        }
    }
}

struct AgentDispatchGraphView: View {
    let goal: AgentDispatchGoal
    let selectedTaskID: UUID?
    let runtimeDescriptors: [RuntimeDescriptor]
    let onSelectTask: (UUID) -> Void

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .center, spacing: 13) {
                ForEach(Array(goal.tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 {
                        connector(for: task)
                    }
                    taskCard(task)
                }
                if !goal.tasks.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    acceptanceGate
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
            .frame(minWidth: 720, minHeight: 320, alignment: .center)
        }
        .background(Color.primary.opacity(0.012))
    }

    private func connector(for task: AgentDispatchTask) -> some View {
        VStack(spacing: 3) {
            Image(systemName: task.dependencyIDs.isEmpty ? "arrow.right" : "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
            if task.dependencyIDs.count > 1 {
                Text("\(task.dependencyIDs.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func taskCard(_ task: AgentDispatchTask) -> some View {
        let selected = task.id == selectedTaskID
        let stateColor = AgentDispatchPresentation.taskStateColor(task.state)
        return Button {
            onSelectTask(task.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: task.resolvedExecutor?.symbol ?? "cpu")
                        .font(.system(size: 11, weight: .medium))
                    Text(
                        task.resolvedExecutor?.displayName
                            ?? AgentDispatchPresentation.executorChoiceName(task.executorChoice)
                    )
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                }
                .foregroundStyle(.secondary)

                Text(task.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)

                Text(L10n.Dispatch.state(task.state))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stateColor)

                Text(task.branchName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    badge(
                        task.resolvedExecutor?.displayName
                            ?? AgentDispatchPresentation.executorChoiceName(task.executorChoice),
                        symbol: "cpu"
                    )
                    badge(
                        AgentDispatchPresentation.targetChoiceName(
                            task.resolvedTarget ?? task.targetChoice,
                            runtimes: runtimeDescriptors
                        ),
                        symbol: (task.resolvedTarget ?? task.targetChoice).isRemoteTarget
                            ? "network"
                            : "desktopcomputer"
                    )
                }
            }
            .padding(13)
            .frame(width: 190, height: 190, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        selected ? Color.accentColor : Color.secondary.opacity(0.19),
                        lineWidth: selected ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: selected ? Color.accentColor.opacity(0.08) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }

    private var acceptanceGate: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.Dispatch.acceptanceGate)
                .font(.system(size: 11, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("\(goal.tasks.filter { $0.state == .accepted || $0.state == .merged }.count)/\(goal.tasks.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 96, height: 96)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func badge(_ text: String, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .frame(height: 19)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
