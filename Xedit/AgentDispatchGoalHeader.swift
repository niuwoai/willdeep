//
//  AgentDispatchGoalHeader.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchGoalHeader: View {
    let goal: AgentDispatchGoal
    let runtimeCount: Int
    let onExecutorChoice: (AgentDispatchExecutorChoice) -> Void
    let onTargetChoice: (AgentDispatchTargetChoice) -> Void
    let onLaunch: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(goal.title)
                            .font(.system(size: 20, weight: .semibold))
                            .lineLimit(1)
                        if goal.isPaused {
                            Text(L10n.Dispatch.paused)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.11))
                                .clipShape(Capsule())
                        }
                    }
                    Text(goal.statement)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                executorMenu
                targetMenu
                Button(action: goal.isPaused ? onResume : onLaunch) {
                    Label(
                        goal.isPaused ? L10n.Dispatch.resumePlan : L10n.Dispatch.startPlan,
                        systemImage: goal.isPaused ? "play.fill" : "play"
                    )
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 8) {
                Text(L10n.Dispatch.taskCount(goal.tasks.count))
                Text("·")
                Text(L10n.Dispatch.activeCount(goal.activeTaskCount))
                Text("·")
                Text("\(Int(goal.progressFraction * 100))%")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var executorMenu: some View {
        Menu {
            ForEach(AgentDispatchExecutorChoice.allCases) { choice in
                Button {
                    onExecutorChoice(choice)
                } label: {
                    Label(
                        AgentDispatchPresentation.executorChoiceName(choice),
                        systemImage: choice == goal.executorChoice ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            policyPill(
                symbol: "cpu",
                text: AgentDispatchPresentation.executorChoiceName(goal.executorChoice)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var targetMenu: some View {
        Menu {
            Button {
                onTargetChoice(.automatic)
            } label: {
                Label(
                    L10n.Dispatch.automatic,
                    systemImage: goal.targetChoice == .automatic ? "checkmark" : "circle"
                )
            }
            Button {
                onTargetChoice(.local)
            } label: {
                Label(
                    L10n.Dispatch.currentMac,
                    systemImage: goal.targetChoice == .local ? "checkmark" : "desktopcomputer"
                )
            }
            ForEach(AgentRuntimeStore.loadDescriptors().filter { $0.transport == .ssh }) { runtime in
                Button {
                    onTargetChoice(.remote(runtime.id))
                } label: {
                    Label(
                        "\(runtime.displayName) · SSH",
                        systemImage: goal.targetChoice == .remote(runtime.id) ? "checkmark" : "network"
                    )
                }
            }
        } label: {
            policyPill(
                symbol: "network",
                text: AgentDispatchPresentation.targetChoiceName(
                    goal.targetChoice,
                    runtimes: AgentRuntimeStore.loadDescriptors(),
                    automaticSuffix: runtimeCount > 0
                        ? L10n.Dispatch.remoteRuntimeSuffix(runtimeCount)
                        : nil
                )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func policyPill(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
