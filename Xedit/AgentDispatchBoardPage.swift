//
//  AgentDispatchBoardPage.swift
//  WillDeep
//

import SwiftUI

/// 任务图与右侧面板（节点检查器 / 接管抽屉）的分宽规则。
///
/// 定宽侧栏在窄窗口下会把任务图整列吃掉，工作区就退化成一个孤零零的聊天
/// 面板。这里的取舍是：**两列都必须留在屏幕上**——先按理想宽度给面板，
/// 放不下就压缩到给任务图留够 `minimumGraphWidth`；窄到两者不可兼得时，
/// 以面板可读下限 `minimumPanelWidth` 为准，任务图挤一点也不整列消失。
nonisolated enum AgentDispatchBoardLayout {
    static let preferredTakeoverWidth: CGFloat = 420
    static let preferredInspectorWidth: CGFloat = 315
    /// 任务图低于这个宽度就只剩半张卡片，读不出依赖关系了。
    static let minimumGraphWidth: CGFloat = 210
    /// 面板低于这个宽度，转写正文与按钮排不下。
    static let minimumPanelWidth: CGFloat = 240

    static func sidePanelWidth(
        availableWidth: CGFloat,
        preferredWidth: CGFloat
    ) -> CGFloat {
        // 首帧 GeometryReader 还没量到尺寸（0），此时按理想宽度渲染，
        // 量到之后再收——反过来会先闪一帧 240 宽的窄面板。
        guard availableWidth.isFinite, availableWidth > 0 else {
            return preferredWidth
        }
        let fitted = min(preferredWidth, availableWidth - minimumGraphWidth)
        return min(availableWidth, max(minimumPanelWidth, fitted))
    }
}

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
    @State private var graphSelection: AgentDispatchGraphSelection?
    @State private var editorRequest: AgentDispatchEditorRequest?
    @State private var isCommandConsoleExpanded = false
    @State private var executionProfiles: [AgentExecutionProfile] = []
    @State private var takeoverSessionID: UUID?

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
            if appState.isPreparingDispatchGoal {
                goalSetupContent
            } else if let goal = coordinator.selectedGoal {
                goalContent(goal)
            } else {
                emptyState
            }
        }
        .onAppear {
            appState.synchronizeDispatchBoardInBackground()
            localExecutors = AgentDispatchExecutorResolver.localAvailableExecutors()
            reloadExecutionProfiles()
            resumeSelectedGoalAfterSynchronization()
        }
        // `onReceive` of a @Published fires with the CURRENT value at
        // subscription time. When the app launches straight onto the board,
        // that value is the pre-catalog empty array — the projection then
        // persisted an empty board and completed goals came back "not
        // started". The gated helper drops those early publishes; catalog
        // completion runs the catch-up projection.
        .onReceive(appState.$agentSessions) { _ in
            appState.synchronizeDispatchBoardInBackground()
            resumeSelectedGoalAfterSynchronization()
        }
        .onChange(of: coordinator.selectedGoalID) { _ in
            takeoverSessionID = nil
            graphSelection = coordinator.selectedTaskID.map(AgentDispatchGraphSelection.task)
            reloadExecutionProfiles()
            resumeSelectedGoalAfterSynchronization()
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
        .sheet(item: $editorRequest) { request in
            if let goal = coordinator.goals.first(where: { $0.id == request.goalID }) {
                AgentDispatchTaskEditorSheet(
                    goal: goal,
                    taskID: request.taskID,
                    onCancel: { editorRequest = nil },
                    onSave: { title, dependencyIDs, acceptanceCriteria in
                        saveTaskEditor(
                            request: request,
                            title: title,
                            dependencyIDs: dependencyIDs,
                            acceptanceCriteria: acceptanceCriteria
                        )
                    }
                )
            }
        }
    }

    private var goalSetupContent: some View {
        AgentDispatchGoalSetupView(
            workspaceLocation: appState.activeRuntime?.workspaceLocation,
            workspaceName: appState.activeRuntime?.session.workspaceName
                ?? L10n.Workspace.noWorkspace,
            profiles: executionProfiles,
            onChooseWorkspace: {
                appState.chooseLocalWorkspaceForDispatchDraft { error in
                    if let error {
                        alertTarget = .message(
                            title: L10n.Dispatch.workspaceBindingFailed,
                            message: error
                        )
                    }
                }
            },
            onManageProfiles: { openProfileSettings() },
            onCancel: { appState.cancelDispatchGoalDraft() },
            onAssess: { statement, planningProfileID, fallbackProfileIDs in
                try await appState.assessDispatchGoal(
                    statement: statement,
                    planningProfileID: planningProfileID,
                    planningFallbackProfileIDs: fallbackProfileIDs
                )
            }
        ) { statement, checklist, planningProfileID, fallbackProfileIDs, workerProfileIDs in
            appState.setAgentGoal(
                statement: statement,
                items: checklist,
                planningProfileID: planningProfileID,
                planningFallbackProfileIDs: fallbackProfileIDs,
                selectedWorkerProfileIDs: workerProfileIDs
            )
        }
    }

    private func goalContent(_ goal: AgentDispatchGoal) -> some View {
        let runtimeDescriptors = AgentRuntimeStore.loadDescriptors()
        let selectedWorkerSet = Set(goal.effectiveWorkerProfileIDs)
        let workerProfiles = executionProfiles.filter { selectedWorkerSet.contains($0.id) }
        return VStack(spacing: 0) {
            AgentDispatchGoalHeader(
                goal: goal,
                runtimeDescriptors: runtimeDescriptors,
                profiles: executionProfiles,
                parallelTaskLimit: appState.perProviderConcurrencyLimit,
                onTargetChoice: { coordinator.updateGoalTargetChoice($0, goalID: goal.id) },
                onPlanningProfiles: { primaryProfileID, fallbackProfileIDs in
                    appState.updateDispatchPlanningProfiles(
                        primaryProfileID: primaryProfileID,
                        fallbackProfileIDs: fallbackProfileIDs,
                        goalID: goal.id
                    )
                },
                onWorkerProfiles: {
                    appState.updateDispatchWorkerProfiles($0, goalID: goal.id)
                },
                onManageProfiles: { openProfileSettings() },
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
            // 侧栏宽度跟着可用宽度走。定宽 420 的接管抽屉在窄窗口下会把任务图
            // 整列挤没，只剩一个看起来像普通聊天的面板——那正是这块工作区最
            // 不该丢的东西。
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    AgentDispatchGraphView(
                        goal: goal,
                        selection: effectiveGraphSelection,
                        runtimeDescriptors: runtimeDescriptors,
                        onSelect: selectGraphNode,
                        onAddTask: {
                            editorRequest = AgentDispatchEditorRequest(
                                goalID: goal.id,
                                taskID: nil
                            )
                        },
                        onEditTask: {
                            editorRequest = AgentDispatchEditorRequest(
                                goalID: goal.id,
                                taskID: $0
                            )
                        },
                        onOpenConversation: {
                            openTaskTakeover(goalID: goal.id, taskID: $0)
                        },
                        onStopTask: {
                            appState.stopDispatchTask(goalID: goal.id, taskID: $0)
                        }
                    )
                    Divider().opacity(0.55)
                    sidePanel(
                        goal,
                        workerProfiles: workerProfiles,
                        runtimeDescriptors: runtimeDescriptors,
                        availableWidth: proxy.size.width
                    )
                }
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
            }
            .frame(minHeight: 310, maxHeight: .infinity)
            Divider().opacity(0.55)
            commandConsole(goal)
        }
    }

    @ViewBuilder
    private func sidePanel(
        _ goal: AgentDispatchGoal,
        workerProfiles: [AgentExecutionProfile],
        runtimeDescriptors: [RuntimeDescriptor],
        availableWidth: CGFloat
    ) -> some View {
        if let takeover = takeoverContext(in: goal) {
            AgentDispatchTakeoverDrawer(
                runtime: takeover.runtime,
                goal: goal,
                task: takeover.task,
                profiles: workerProfiles,
                width: AgentDispatchBoardLayout.sidePanelWidth(
                    availableWidth: availableWidth,
                    preferredWidth: AgentDispatchBoardLayout.preferredTakeoverWidth
                ),
                onModelProfile: { profileID in
                    appState.updateDispatchTaskProfiles(
                        primaryProfileID: profileID,
                        fallbackProfileIDs: (takeover.task.fallbackProfileIDs ?? [])
                            .filter { $0 != profileID },
                        goalID: goal.id,
                        taskID: takeover.task.id
                    )
                },
                onClose: { takeoverSessionID = nil },
                onOpenFullConversation: {
                    takeoverSessionID = nil
                    appState.openDispatchTaskConversation(
                        runtimeSessionID: takeover.runtime.id
                    )
                }
            )
        } else if effectiveGraphSelection == .acceptance {
            AgentDispatchAcceptanceInspectorView(
                goal: goal,
                onSelectTask: { selectGraphNode(.task($0)) }
            )
            .frame(width: inspectorWidth(availableWidth: availableWidth))
        } else if let task = coordinator.selectedTask {
            AgentDispatchInspectorView(
                goal: goal,
                task: task,
                localExecutors: localExecutors,
                runtimeDescriptors: runtimeDescriptors,
                profiles: workerProfiles,
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
                onProfiles: { primaryProfileID, fallbackProfileIDs in
                    appState.updateDispatchTaskProfiles(
                        primaryProfileID: primaryProfileID,
                        fallbackProfileIDs: fallbackProfileIDs,
                        goalID: goal.id,
                        taskID: task.id
                    )
                },
                onManageProfiles: { openProfileSettings() },
                onLaunch: { launchTask(goalID: goal.id, taskID: task.id) },
                onStop: {
                    appState.stopDispatchTask(goalID: goal.id, taskID: task.id)
                },
                onOpenConversation: {
                    openTaskTakeover(goalID: goal.id, taskID: task.id)
                },
                onEdit: {
                    editorRequest = AgentDispatchEditorRequest(
                        goalID: goal.id,
                        taskID: task.id
                    )
                }
            )
            .frame(width: inspectorWidth(availableWidth: availableWidth))
        }
    }

    private func inspectorWidth(availableWidth: CGFloat) -> CGFloat {
        AgentDispatchBoardLayout.sidePanelWidth(
            availableWidth: availableWidth,
            preferredWidth: AgentDispatchBoardLayout.preferredInspectorWidth
        )
    }

    private var effectiveGraphSelection: AgentDispatchGraphSelection? {
        graphSelection
            ?? coordinator.selectedTaskID.map(AgentDispatchGraphSelection.task)
            ?? (coordinator.selectedGoal?.tasks.isEmpty == false ? nil : .acceptance)
    }

    @ViewBuilder
    private func commandConsole(_ goal: AgentDispatchGoal) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Label(L10n.Dispatch.runtimeInstructions, systemImage: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                if let latest = goal.commands.first {
                    Text(AgentDispatchPresentation.commandStatus(latest))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    editorRequest = AgentDispatchEditorRequest(
                        goalID: goal.id,
                        taskID: nil
                    )
                } label: {
                    Label(L10n.Dispatch.addNode, systemImage: "plus")
                }
                Button {
                    if let selectedTaskID = coordinator.selectedTaskID {
                        editorRequest = AgentDispatchEditorRequest(
                            goalID: goal.id,
                            taskID: selectedTaskID
                        )
                    }
                } label: {
                    Label(L10n.Dispatch.humanOverride, systemImage: "slider.horizontal.3")
                }
                .disabled(coordinator.selectedTaskID == nil)
                Button {
                    togglePaused(goal)
                } label: {
                    Label(
                        goal.isPaused ? L10n.Dispatch.resumeAll : L10n.Dispatch.pauseAll,
                        systemImage: goal.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isCommandConsoleExpanded.toggle()
                    }
                } label: {
                    Label(
                        isCommandConsoleExpanded
                            ? L10n.Dispatch.hideInstructions
                            : L10n.Dispatch.showInstructions,
                        systemImage: isCommandConsoleExpanded
                            ? "chevron.down"
                            : "chevron.up"
                    )
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            if isCommandConsoleExpanded {
                Divider().opacity(0.45)
                AgentDispatchGoalCommandComposer(
                    goal: goal,
                    text: $commandText,
                    onSend: submitCommand,
                    onAddTask: {
                        editorRequest = AgentDispatchEditorRequest(
                            goalID: goal.id,
                            taskID: nil
                        )
                    },
                    onAdjustPlan: {
                        if let selectedTaskID = coordinator.selectedTaskID {
                            editorRequest = AgentDispatchEditorRequest(
                                goalID: goal.id,
                                taskID: selectedTaskID
                            )
                        }
                    },
                    onTogglePause: {
                        togglePaused(goal)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
                appState.startDispatchGoalInLocalWorkspace()
            } label: {
                Label(L10n.Dispatch.chooseWorkspaceAndStart, systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
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
            _ = coordinator.setPaused(true, goalID: goal.id)
            return
        }
        if text.hasPrefix("恢复全部") || text.lowercased().hasPrefix("resume all") {
            guard coordinator.setPaused(false, goalID: goal.id) else {
                alertTarget = .message(
                    title: L10n.Dispatch.launchFailed,
                    message: L10n.Dispatch.projectAlreadyRunning(
                        coordinator.conflictingActiveGoal(for: goal.id).map {
                            $0.statement.isEmpty ? $0.title : $0.statement
                        } ?? L10n.Dispatch.goalsHeader
                    )
                )
                return
            }
            _ = appState.launchReadyDispatchTasks(goalID: goal.id)
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
        guard coordinator.setPaused(paused, goalID: goal.id) else {
            alertTarget = .message(
                title: L10n.Dispatch.launchFailed,
                message: L10n.Dispatch.projectAlreadyRunning(
                    coordinator.conflictingActiveGoal(for: goal.id).map {
                        $0.statement.isEmpty ? $0.title : $0.statement
                    } ?? L10n.Dispatch.goalsHeader
                )
            )
            return
        }
        _ = coordinator.recordCommand(
            goalID: goal.id,
            text: text,
            effect: .appliedImmediately
        )
        if !paused {
            _ = appState.launchReadyDispatchTasks(goalID: goal.id)
        }
    }

    private func selectGraphNode(_ selection: AgentDispatchGraphSelection) {
        if case .task(let taskID) = selection,
           coordinator.selectedGoal?.tasks.first(where: { $0.id == taskID })?.runtimeSessionID
                != takeoverSessionID {
            takeoverSessionID = nil
        } else if selection == .acceptance {
            takeoverSessionID = nil
        }
        graphSelection = selection
        if case .task(let taskID) = selection {
            coordinator.selectTask(taskID)
        }
    }

    private func openTaskTakeover(goalID: UUID, taskID: UUID) {
        guard let goal = coordinator.goals.first(where: { $0.id == goalID }),
              let task = goal.tasks.first(where: { $0.id == taskID }),
              let runtimeSessionID = task.runtimeSessionID,
              appState.prepareDispatchTaskTakeover(runtimeSessionID: runtimeSessionID) else {
            return
        }
        coordinator.selectGoal(goalID)
        coordinator.selectTask(taskID)
        graphSelection = .task(taskID)
        takeoverSessionID = runtimeSessionID
    }

    private func takeoverContext(
        in goal: AgentDispatchGoal
    ) -> (task: AgentDispatchTask, runtime: AgentRuntime)? {
        guard let takeoverSessionID,
              let task = goal.tasks.first(where: { $0.runtimeSessionID == takeoverSessionID }),
              let runtime = appState.runtime(for: takeoverSessionID) else {
            return nil
        }
        return (task, runtime)
    }

    private func saveTaskEditor(
        request: AgentDispatchEditorRequest,
        title: String,
        dependencyIDs: [UUID],
        acceptanceCriteria: [String]
    ) {
        if let taskID = request.taskID {
            guard coordinator.updateTaskOutcome(
                goalID: request.goalID,
                taskID: taskID,
                title: title,
                acceptanceCriteria: acceptanceCriteria
            ) else {
                alertTarget = .message(
                    title: L10n.Dispatch.planUpdateFailed,
                    message: L10n.Dispatch.outcomeUpdateFailedMessage
                )
                return
            }
            selectGraphNode(.task(taskID))
        } else {
            guard let task = coordinator.appendTask(
                title: title,
                goalID: request.goalID,
                dependencyIDs: dependencyIDs,
                acceptanceCriteria: acceptanceCriteria
            ) else {
                alertTarget = .message(
                    title: L10n.Dispatch.planUpdateFailed,
                    message: L10n.Dispatch.planUpdateFailedMessage
                )
                return
            }
            selectGraphNode(.task(task.id))
        }
        editorRequest = nil
    }

    private func launchFirstReadyTask(in goal: AgentDispatchGoal) {
        let results = appState.launchReadyDispatchTasks(goalID: goal.id)
        guard !results.isEmpty else {
            alertTarget = .message(
                title: L10n.Dispatch.launchFailed,
                message: L10n.Dispatch.waitingForDependencies
            )
            return
        }
        if case .blocked(let message)? = results.first(where: {
            if case .blocked = $0 { return true }
            return false
        }) {
            alertTarget = .message(title: L10n.Dispatch.launchFailed, message: message)
        }
    }

    private func resumeSelectedGoalAfterSynchronization() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let goalID = coordinator.selectedGoalID else { return }
            appState.resumeDispatchGoal(goalID: goalID)
        }
    }

    private func dispatchModelIDs(for goal: AgentDispatchGoal) -> [String] {
        let routing = goal.effectiveModelRouting
        let candidates = [
            routing.planningModelID,
            routing.executionModelID,
            AgentDispatchModelRouting.recommendedPlanningModel,
            AgentDispatchModelRouting.recommendedExecutionModel,
        ].compactMap { $0 }
            + appState.agentRecentlyUsedModelIDs
            + appState.agentKnownModelIDs
        var seen: Set<String> = []
        return candidates.filter { modelID in
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && seen.insert(trimmed.lowercased()).inserted
        }
        .prefix(24)
        .map { $0 }
    }

    /// Profiles are edited in one place now — Settings → AI → Agent profiles.
    /// The dispatch board used to carry its own editor over the same records
    /// (agent-profile.v2); two editors over one dataset is exactly the drift
    /// this merge removed.
    ///
    /// `@Environment(\.openSettings)` is macOS 14+ and this app still ships
    /// 13.7, so the 13-compatible opener in `EditorSettingsNavigation`
    /// (showSettingsWindow: plus a fallback window controller) is used.
    private func openProfileSettings() {
        EditorSettingsNavigation.shared.selectedTab = .subagents
        EditorSettingsNavigation.shared.openWindow(appState: appState)
        reloadExecutionProfiles()
    }

    private func reloadExecutionProfiles() {
        executionProfiles = AgentExecutionProfileStore().availableProfiles(
            workspacePath: coordinator.selectedGoal?
                .logicalProject?.primaryWorkspacePath
                ?? appState.activeRuntime?.workspaceRootPath
        )
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

private struct AgentDispatchEditorRequest: Identifiable {
    let goalID: UUID
    let taskID: UUID?

    var id: String {
        "\(goalID.uuidString):\(taskID?.uuidString ?? "new")"
    }
}

private struct AgentDispatchTaskEditorSheet: View {
    let goal: AgentDispatchGoal
    let taskID: UUID?
    let onCancel: () -> Void
    let onSave: (String, [UUID], [String]) -> Void

    @State private var title: String
    @State private var dependencyIDs: Set<UUID>
    @State private var acceptanceCriteria: String

    init(
        goal: AgentDispatchGoal,
        taskID: UUID?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, [UUID], [String]) -> Void
    ) {
        self.goal = goal
        self.taskID = taskID
        self.onCancel = onCancel
        self.onSave = onSave
        let task = taskID.flatMap { id in goal.tasks.first(where: { $0.id == id }) }
        let defaultDependency = task == nil ? goal.tasks.last?.id : nil
        _title = State(initialValue: task?.title ?? "")
        _dependencyIDs = State(
            initialValue: Set(task?.dependencyIDs ?? defaultDependency.map { [$0] } ?? [])
        )
        _acceptanceCriteria = State(
            initialValue: (task?.acceptanceCriteria ?? [L10n.Dispatch.defaultAcceptanceCriterion])
                .joined(separator: "\n")
        )
    }

    private var isEditing: Bool {
        taskID != nil
    }

    private var availableDependencies: [AgentDispatchTask] {
        goal.tasks.filter { $0.id != taskID }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var criteria: [String] {
        acceptanceCriteria
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isEditing ? "slider.horizontal.3" : "plus.square.on.square")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? L10n.Dispatch.humanOverride : L10n.Dispatch.addNode)
                        .font(.system(size: 17, weight: .semibold))
                    Text(
                        isEditing
                            ? L10n.Dispatch.nodeOverrideMessage
                            : L10n.Dispatch.nodeEditorMessage
                    )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            Form {
                Section(isEditing ? L10n.Dispatch.nodeObjective : L10n.Dispatch.nodeTaskTitle) {
                    TextField(L10n.Dispatch.nodeTaskTitlePlaceholder, text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                if !isEditing {
                    Section {
                        if availableDependencies.isEmpty {
                            Text(L10n.Dispatch.noDependenciesAvailable)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(availableDependencies) { task in
                                Toggle(
                                    isOn: Binding(
                                        get: { dependencyIDs.contains(task.id) },
                                        set: { selected in
                                            if selected {
                                                dependencyIDs.insert(task.id)
                                            } else {
                                                dependencyIDs.remove(task.id)
                                            }
                                        }
                                    )
                                ) {
                                    HStack(spacing: 7) {
                                        Circle()
                                            .fill(AgentDispatchPresentation.taskStateColor(task.state))
                                            .frame(width: 7, height: 7)
                                        Text(task.title)
                                            .lineLimit(2)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    } header: {
                        Text(L10n.Dispatch.nodeDependencies)
                    } footer: {
                        Text(L10n.Dispatch.nodeDependenciesHelp)
                    }
                }

                Section {
                    TextEditor(text: $acceptanceCriteria)
                        .font(.system(size: 12))
                        .frame(minHeight: 82)
                } header: {
                    Text(L10n.Dispatch.acceptance)
                } footer: {
                    Text(L10n.Dispatch.nodeAcceptanceHelp)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(L10n.Dispatch.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? L10n.Dispatch.saveIntervention : L10n.Dispatch.saveNode) {
                    onSave(trimmedTitle, Array(dependencyIDs), criteria)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: isEditing ? 410 : 590)
    }
}
