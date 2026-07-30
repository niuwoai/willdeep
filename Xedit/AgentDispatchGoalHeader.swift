//
//  AgentDispatchGoalHeader.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchGoalHeader: View {
    let goal: AgentDispatchGoal
    let runtimeDescriptors: [RuntimeDescriptor]
    let modelIDs: [String]
    let cliProfiles: [LocalAgentCLIProfile]
    let onExecutorChoice: (AgentDispatchExecutorChoice) -> Void
    let onTargetChoice: (AgentDispatchTargetChoice) -> Void
    let onModelRouting: (AgentDispatchModelRouting) -> Void
    let onCLIProfile: (AgentExecutionAgent, String?) -> Void
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
                executorMenu
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

    private var routingMenu: some View {
        Menu {
            Menu(L10n.Dispatch.planningModel) {
                modelButtons(role: .planning)
            }
            Menu(L10n.Dispatch.executionModel) {
                modelButtons(role: .execution)
            }
            let claudeProfiles = cliProfiles.filter { $0.executor == .claudeCode }
            let codexProfiles = cliProfiles.filter { $0.executor == .codexCLI }
            if !claudeProfiles.isEmpty {
                profileMenu(
                    title: AgentExecutionAgent.claudeCode.displayName,
                    executor: .claudeCode,
                    profiles: claudeProfiles
                )
            }
            if !codexProfiles.isEmpty {
                profileMenu(
                    title: AgentExecutionAgent.codexCLI.displayName,
                    executor: .codexCLI,
                    profiles: codexProfiles
                )
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

    @ViewBuilder
    private func modelButtons(role: ModelRole) -> some View {
        let selectedModel = role.modelID(in: goal.effectiveModelRouting)
        Button {
            updateModel(nil, role: role)
        } label: {
            Label(
                L10n.Dispatch.followCurrentModel,
                systemImage: selectedModel == nil ? "checkmark" : "circle"
            )
        }
        ForEach(modelIDs, id: \.self) { modelID in
            Button {
                updateModel(modelID, role: role)
            } label: {
                Label(
                    modelID,
                    systemImage: selectedModel == modelID ? "checkmark" : "circle"
                )
            }
        }
    }

    private func profileMenu(
        title: String,
        executor: AgentExecutionAgent,
        profiles: [LocalAgentCLIProfile]
    ) -> some View {
        Menu("\(title) · \(L10n.Dispatch.profile)") {
            let selectedProfileID = goal.selectedCLIProfileID(for: executor)
            Button {
                onCLIProfile(executor, nil)
            } label: {
                Label(
                    L10n.Dispatch.defaultProfile,
                    systemImage: selectedProfileID == nil ? "checkmark" : "circle"
                )
            }
            ForEach(profiles) { profile in
                Button {
                    onCLIProfile(executor, profile.id)
                } label: {
                    Label(
                        profile.displayName,
                        systemImage: selectedProfileID == profile.id ? "checkmark" : "circle"
                    )
                }
            }
        }
    }

    private enum ModelRole {
        case planning
        case execution

        func modelID(in routing: AgentDispatchModelRouting) -> String? {
            switch self {
            case .planning: return routing.planningModelID
            case .execution: return routing.executionModelID
            }
        }
    }

    private func updateModel(_ modelID: String?, role: ModelRole) {
        var routing = goal.effectiveModelRouting
        switch role {
        case .planning:
            routing.planningModelID = modelID
        case .execution:
            routing.executionModelID = modelID
        }
        onModelRouting(routing)
    }

    private var routingSummary: String {
        let routing = goal.effectiveModelRouting
        let planning = routing.planningModelID ?? L10n.Dispatch.automatic
        let execution = routing.executionModelID ?? L10n.Dispatch.automatic
        return "\(planning) → \(execution)"
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
        return !goal.isExecutionActive && goal.hasReadyTask
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
