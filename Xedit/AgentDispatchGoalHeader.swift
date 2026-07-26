//
//  AgentDispatchGoalHeader.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchGoalHeader: View {
    let goal: AgentDispatchGoal
    let runtimeDescriptors: [RuntimeDescriptor]
    let onExecutorChoice: (AgentDispatchExecutorChoice) -> Void
    let onTargetChoice: (AgentDispatchTargetChoice) -> Void
    let onChooseLocalWorkspace: () -> Void
    let onBindRemoteWorkspace: (RuntimeDescriptor) -> Void
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
                workspaceMenu
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
                .disabled(goal.workspaceLocation == nil)
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

    private var workspaceMenu: some View {
        Menu {
            if let workspace = goal.workspaceLocation {
                Section(L10n.Dispatch.goalWorkspace) {
                    Label(workspace.path, systemImage: "folder.fill")
                }
            }
            Section(goal.workspaceLocation == nil
                    ? L10n.Dispatch.bindWorkspace
                    : L10n.Dispatch.addWorkspaceMapping) {
                Button(action: onChooseLocalWorkspace) {
                    Label(
                        L10n.Dispatch.chooseLocalWorkspace,
                        systemImage: localWorkspaceIsMapped ? "checkmark" : "folder"
                    )
                }
                ForEach(runtimeDescriptors.filter { $0.transport == .ssh }) { runtime in
                    Button {
                        onBindRemoteWorkspace(runtime)
                    } label: {
                        Label(
                            "\(runtime.displayName): \(runtime.defaultWorkspacePath)",
                            systemImage: remoteWorkspaceIsMapped(runtime.id)
                                ? "checkmark"
                                : "network"
                        )
                    }
                }
            }
            if goal.workspaceLocation != nil {
                Text(L10n.Dispatch.workspaceMappingHelp)
            }
        } label: {
            policyPill(
                symbol: goal.workspaceLocation == nil ? "folder.badge.questionmark" : "folder.fill",
                text: goal.workspaceLocation?.displayName ?? L10n.Dispatch.workspaceRequiredShort,
                tint: goal.workspaceLocation == nil ? .orange : .secondary
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            ForEach(Array(goal.availableTargetChoices.enumerated()), id: \.offset) { _, target in
                targetButton(target)
            }
        } label: {
            policyPill(
                symbol: "network",
                text: AgentDispatchPresentation.targetChoiceName(
                    goal.targetChoice,
                    runtimes: runtimeDescriptors
                )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(goal.workspaceLocation == nil)
    }

    private func targetButton(_ target: AgentDispatchTargetChoice) -> some View {
        Button {
            onTargetChoice(target)
        } label: {
            Label(
                AgentDispatchPresentation.targetChoiceName(target, runtimes: runtimeDescriptors),
                systemImage: target == goal.targetChoice
                    ? "checkmark"
                    : target.isRemoteTarget ? "network" : "desktopcomputer"
            )
        }
    }

    private var localWorkspaceIsMapped: Bool {
        goal.workspaceLocation(for: .local) != nil
    }

    private func remoteWorkspaceIsMapped(_ runtimeID: UUID) -> Bool {
        goal.workspaceLocation(for: .remote(runtimeID)) != nil
    }

    private func policyPill(
        symbol: String,
        text: String,
        tint: Color = .secondary
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
