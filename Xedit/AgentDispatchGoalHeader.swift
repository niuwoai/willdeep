//
//  AgentDispatchGoalHeader.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchGoalHeader: View {
    let goal: AgentDispatchGoal
    let runtimeDescriptors: [RuntimeDescriptor]
    let profiles: [AgentExecutionProfile]
    let onTargetChoice: (AgentDispatchTargetChoice) -> Void
    let onPlanningProfiles: (String, [String]) -> Void
    let onWorkerProfiles: ([String]) -> Void
    let onManageProfiles: () -> Void
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
                    Label(
                        goal.projectDisplayText ?? L10n.Dispatch.workspaceRequiredShort,
                        systemImage: goal.isWorkspaceBound
                            ? "folder.fill"
                            : "folder.badge.questionmark"
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(goal.isWorkspaceBound ? .secondary : Color.orange)
                    .lineLimit(1)
                    .textSelection(.enabled)
                }
                Spacer(minLength: 10)
                workspaceMenu
                routingMenu
                workerMenu
                targetMenu
                Button(action: goal.isPaused ? onResume : onLaunch) {
                    Label(
                        launchButtonTitle,
                        systemImage: goal.isPaused ? "play.fill" : "play"
                    )
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canLaunchFromHeader)
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
            if let project = goal.logicalProject {
                Section(L10n.Dispatch.goalWorkspace) {
                    Label(
                        "\(project.displayName) · \(project.primaryWorkspacePath)",
                        systemImage: "folder.fill"
                    )
                }
            }
            Section(!goal.isWorkspaceBound
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
                            remoteWorkspaceLabel(runtime),
                            systemImage: remoteWorkspaceIsMapped(runtime.id)
                                ? "checkmark"
                                : "network"
                        )
                    }
                }
            }
            if goal.isWorkspaceBound {
                Text(L10n.Dispatch.workspaceMappingHelp)
            }
        } label: {
            policyPill(
                symbol: goal.isWorkspaceBound ? "folder.fill" : "folder.badge.questionmark",
                text: goal.logicalProject?.displayName ?? L10n.Dispatch.workspaceRequiredShort,
                tint: goal.isWorkspaceBound ? .secondary : .orange
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var routingMenu: some View {
        Menu {
            Section(L10n.Dispatch.planningProfile) {
                ForEach(profiles) { profile in
                    Button {
                        onPlanningProfiles(
                            profile.id,
                            goal.effectivePlanningFallbackProfileIDs.filter {
                                $0 != profile.id
                            }
                        )
                    } label: {
                        Label(
                            profile.name,
                            systemImage: profile.id == goal.effectivePlanningProfileID
                                ? "checkmark"
                                : profile.executor.symbol
                        )
                    }
                }
            }
            Menu(L10n.Dispatch.planningFallbacks) {
                ForEach(profiles.filter {
                    $0.id != goal.effectivePlanningProfileID
                }) { profile in
                    Button {
                        var fallbacks = goal.effectivePlanningFallbackProfileIDs
                        if let index = fallbacks.firstIndex(of: profile.id) {
                            fallbacks.remove(at: index)
                        } else {
                            fallbacks.append(profile.id)
                        }
                        onPlanningProfiles(
                            goal.effectivePlanningProfileID,
                            fallbacks
                        )
                    } label: {
                        Label(
                            profile.name,
                            systemImage: goal.effectivePlanningFallbackProfileIDs
                                .contains(profile.id)
                                ? "checkmark"
                                : profile.executor.symbol
                        )
                    }
                }
            }
            Divider()
            Button(action: onManageProfiles) {
                Label(L10n.Dispatch.manageProfiles, systemImage: "gearshape")
            }
        } label: {
            policyPill(
                symbol: "brain.head.profile",
                text: routingSummary
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.Dispatch.modelRoutingHelp)
    }

    private var routingSummary: String {
        profiles.first { $0.id == goal.effectivePlanningProfileID }?.name
            ?? L10n.Dispatch.planningProfile
    }

    private var workerMenu: some View {
        Menu {
            ForEach(profiles) { profile in
                Button {
                    var selected = goal.effectiveWorkerProfileIDs
                    if let index = selected.firstIndex(of: profile.id) {
                        guard selected.count > 1 else { return }
                        selected.remove(at: index)
                    } else {
                        selected.append(profile.id)
                    }
                    onWorkerProfiles(selected)
                } label: {
                    Label(
                        profile.name,
                        systemImage: goal.effectiveWorkerProfileIDs.contains(profile.id)
                            ? "checkmark.square.fill"
                            : profile.executor.symbol
                    )
                }
            }
            Divider()
            Text(L10n.Dispatch.workerPoolHelp)
            Button(action: onManageProfiles) {
                Label(L10n.Dispatch.manageProfiles, systemImage: "gearshape")
            }
        } label: {
            policyPill(
                symbol: "person.2.badge.gearshape",
                text: L10n.Dispatch.selectedWorkerCount(goal.effectiveWorkerProfileIDs.count)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var launchButtonTitle: String {
        guard goal.isWorkspaceBound else {
            return L10n.Dispatch.selectWorkspaceFirst
        }
        if goal.isPaused {
            return L10n.Dispatch.resumeExecution
        }
        if goal.isExecutionActive {
            return L10n.Dispatch.executionRunning
        }
        return goal.hasStartedExecution
            ? L10n.Dispatch.continueExecution
            : L10n.Dispatch.startExecution
    }

    private var canLaunchFromHeader: Bool {
        guard goal.isWorkspaceBound else { return false }
        if goal.isPaused {
            return true
        }
        return goal.activeTaskCount < max(1, goal.effectiveWorkerProfileIDs.count)
            && goal.hasReadyTask
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
        .disabled(!goal.isWorkspaceBound)
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

    private func remoteWorkspaceLabel(_ runtime: RuntimeDescriptor) -> String {
        guard let path = goal.workspaceLocation(for: .remote(runtime.id))?.path else {
            return "\(runtime.displayName) · \(L10n.Dispatch.chooseRemoteWorkspace)"
        }
        return "\(runtime.displayName) · \(path)"
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
