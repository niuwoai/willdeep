//
//  AgentDispatchBoardPage.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchBoardPage: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        AgentDispatchBoardContent(
            coordinator: appState.agentDispatchCoordinator
        )
        .environmentObject(appState)
    }
}

private struct AgentDispatchBoardContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var coordinator: AgentDispatchCoordinator
    @State private var commandText = ""
    @State private var alertTarget: AlertTarget?
    @State private var localExecutors = AgentDispatchExecutorResolver.localAvailableExecutors()

    private enum AlertTarget: Identifiable {
        case interrupt(goalID: UUID, command: AgentDispatchCommand)
        case message(title: String, message: String)

        var id: String {
            switch self {
            case .interrupt(_, let command): return command.id.uuidString
            case .message(let title, let message): return title + message
            }
        }
    }

    var body: some View {
        Group {
            if let goal = coordinator.selectedGoal {
                goalContent(goal)
            } else {
                emptyState
            }
        }
        .onAppear {
            coordinator.synchronize(with: appState.agentSessions)
            localExecutors = AgentDispatchExecutorResolver.localAvailableExecutors()
        }
        .onReceive(appState.$agentSessions) { sessions in
            coordinator.synchronize(with: sessions)
        }
        .alert(item: $alertTarget) { target in
            switch target {
            case .interrupt(let goalID, let command):
                return Alert(
                    title: Text(L10n.Dispatch.interruptTitle),
                    message: Text(L10n.Dispatch.interruptMessage),
                    primaryButton: .destructive(Text(L10n.Dispatch.interruptNow)) {
                        appState.confirmDispatchGoalInterrupt(
                            goalID: goalID,
                            commandID: command.id,
                            text: command.text
                        )
                    },
                    secondaryButton: .cancel(Text(L10n.Dispatch.keepRunning)) {
                        coordinator.resolveCommand(
                            goalID: goalID,
                            commandID: command.id,
                            interrupted: false
                        )
                    }
                )
            case .message(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text(L10n.CloseTab.ok))
                )
            }
        }
    }

    private func goalContent(_ goal: AgentDispatchGoal) -> some View {
        let runtimeDescriptors = AgentRuntimeStore.loadDescriptors()
        return VStack(spacing: 0) {
            AgentDispatchGoalHeader(
                goal: goal,
                runtimeDescriptors: runtimeDescriptors,
                onExecutorChoice: { coordinator.updateGoalExecutorChoice($0, goalID: goal.id) },
                onTargetChoice: { coordinator.updateGoalTargetChoice($0, goalID: goal.id) },
                onChooseLocalWorkspace: {
                    appState.chooseLocalWorkspaceForDispatchGoal(goalID: goal.id) { error in
                        if let error {
                            alertTarget = .message(
                                title: L10n.Dispatch.workspaceBindingFailed,
                                message: error
                            )
                        }
                    }
                },
                onBindRemoteWorkspace: { runtime in
                    appState.chooseRemoteWorkspaceForDispatchGoal(
                        goalID: goal.id,
                        runtime: runtime
                    ) { error in
                        if let error {
                            alertTarget = .message(
                                title: L10n.Dispatch.workspaceBindingFailed,
                                message: error
                            )
                        }
                    }
                },
                onLaunch: { launchFirstReadyTask(in: goal) },
                onResume: { togglePaused(goal) }
            )
            Divider().opacity(0.55)
            HStack(spacing: 0) {
                AgentDispatchGraphView(
                    goal: goal,
                    selectedTaskID: coordinator.selectedTaskID,
                    runtimeDescriptors: runtimeDescriptors,
                    onSelectTask: coordinator.selectTask
                )
                Divider().opacity(0.55)
                if let task = coordinator.selectedTask {
                    AgentDispatchInspectorView(
                        goal: goal,
                        task: task,
                        localExecutors: localExecutors,
                        runtimeDescriptors: runtimeDescriptors,
                        onExecutorChoice: {
                            coordinator.updateTaskExecutorChoice(
                                $0,
                                goalID: goal.id,
                                taskID: task.id
                            )
                        },
                        onWorkspaceBindingChoice: {
                            coordinator.updateTaskWorkspaceBinding(
                                $0,
                                goalID: goal.id,
                                taskID: task.id
                            )
                        },
                        onLaunch: { launchTask(goalID: goal.id, taskID: task.id) },
                        onOpenConversation: {
                            guard let runtimeID = task.runtimeSessionID else { return }
                            appState.openDispatchTaskConversation(runtimeSessionID: runtimeID)
                        }
                    )
                    .frame(width: 315)
                }
            }
            .frame(minHeight: 310, maxHeight: .infinity)
            Divider().opacity(0.55)
            AgentDispatchGoalCommandComposer(
                goal: goal,
                text: $commandText,
                onSend: submitCommand,
                onAddTask: {
                    commandText = commandText.isEmpty ? "\(L10n.Dispatch.addTask)： " : commandText
                },
                onAdjustPlan: {
                    commandText = commandText.isEmpty ? "\(L10n.Dispatch.adjustPlan)： " : commandText
                },
                onTogglePause: {
                    togglePaused(goal)
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.Dispatch.emptyTitle)
                .font(.system(size: 22, weight: .semibold))
            Text(L10n.Dispatch.emptyMessage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button {
                appState.startGoalConversationInLocalWorkspace()
            } label: {
                Label(L10n.Dispatch.chooseWorkspaceAndStart, systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func submitCommand() {
        guard let goal = coordinator.selectedGoal else { return }
        guard goal.isWorkspaceBound else {
            alertTarget = .message(
                title: L10n.Dispatch.workspaceRequiredShort,
                message: L10n.Dispatch.workspaceRequired
            )
            return
        }
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commandText = ""

        let sourceRuntime = appState.runtime(for: goal.sessionID)
        let isRunning = sourceRuntime?.isResponding == true
        let effect = AgentDispatchCommandClassifier.effect(
            for: text,
            isGoalRunning: isRunning
        )
        let command = coordinator.recordCommand(
            goalID: goal.id,
            text: text,
            effect: effect
        )

        if let title = AgentDispatchCommandClassifier.appendedTaskTitle(from: text) {
            _ = coordinator.appendTask(title: title, goalID: goal.id)
            return
        }
        if text.hasPrefix("暂停全部") || text.lowercased().hasPrefix("pause all") {
            coordinator.setPaused(true, goalID: goal.id)
            return
        }
        if text.hasPrefix("恢复全部") || text.lowercased().hasPrefix("resume all") {
            coordinator.setPaused(false, goalID: goal.id)
            return
        }

        if effect == .requiresInterruptConfirmation {
            alertTarget = .interrupt(goalID: goal.id, command: command)
        } else {
            appState.submitDispatchGoalInstruction(
                goalID: goal.id,
                commandID: command.id,
                text: text,
                effect: effect
            )
        }
    }

    private func togglePaused(_ goal: AgentDispatchGoal) {
        let paused = !goal.isPaused
        let text = paused ? L10n.Dispatch.pauseAll : L10n.Dispatch.resumeAll
        _ = coordinator.recordCommand(
            goalID: goal.id,
            text: text,
            effect: .appliedImmediately
        )
        coordinator.setPaused(paused, goalID: goal.id)
    }

    private func launchFirstReadyTask(in goal: AgentDispatchGoal) {
        guard let task = goal.tasks.first(where: { $0.state == .queued })
            ?? coordinator.selectedTask else {
            alertTarget = .message(
                title: L10n.Dispatch.launchFailed,
                message: L10n.Dispatch.waitingForDependencies
            )
            return
        }
        launchTask(goalID: goal.id, taskID: task.id)
    }

    private func launchTask(goalID: UUID, taskID: UUID) {
        switch appState.launchDispatchTask(goalID: goalID, taskID: taskID) {
        case .started:
            break
        case .blocked(let message):
            alertTarget = .message(title: L10n.Dispatch.launchFailed, message: message)
        }
    }
}
