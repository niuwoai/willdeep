//
//  AgentDispatchTakeoverDrawer.swift
//  WillDeep
//
//  Context-preserving human intervention for a running dispatch node.
//

import SwiftUI

nonisolated enum AgentDispatchTakeoverActivityStatus: Equatable {
    case hidden
    case waitingForProvider
    case active

    static func resolve(
        isResponding: Bool,
        isAwaitingProviderSlot: Bool
    ) -> Self {
        if isAwaitingProviderSlot {
            return .waitingForProvider
        }
        return isResponding ? .active : .hidden
    }
}

struct AgentDispatchTakeoverDrawer: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    let goal: AgentDispatchGoal
    let task: AgentDispatchTask
    let profiles: [AgentExecutionProfile]
    /// 由调度台按可用宽度算好后传进来（见 `AgentDispatchBoardLayout`）。
    /// 抽屉自己定宽会在窄窗口下把任务图挤没。
    var width: CGFloat = 420
    let onModelProfile: (String) -> Void
    let onClose: () -> Void
    let onOpenFullConversation: () -> Void

    @State private var selectedPanel: AgentSidePanelKind?
    @State private var selectedFile: URL?
    @State private var isConfirmingManualCompletion = false

    private var drawerWidth: CGFloat { width }

    private var assignedProfile: AgentExecutionProfile? {
        let assignedID = task.activeProfileID ?? task.primaryProfileID
        return profiles.first { $0.id == assignedID }
    }

    private var modelPresentation: AgentDispatchTaskModelPresentation {
        if runtime.executionAgent != .willDeep {
            return AgentDispatchTaskModelPresentation.resolve(
                activeTurnModelID: nil,
                configuredModelID: assignedProfile?.modelID,
                persistedModelID: nil
            )
        }
        return AgentDispatchTaskModelPresentation.resolve(
            activeTurnModelID: runtime.activeTurnConfiguration?.model,
            configuredModelID: runtime.sessionModelOverride,
            persistedModelID: runtime.session.modelID
        )
    }

    private var switchableModelProfiles: [AgentExecutionProfile] {
        guard runtime.executionAgent == .willDeep else { return [] }
        return profiles.filter { profile in
            profile.executor == .willDeep && profile.modelID != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            metricsStrip
            Divider().opacity(0.5)

            if selectedPanel != nil {
                AgentSidePanelHost(
                    kind: $selectedPanel,
                    selectedFile: $selectedFile,
                    width: drawerWidth,
                    contentWidth: drawerWidth
                )
            } else {
                AgentChatTranscript()
                Divider().opacity(0.5)
                takeoverComposer
            }

            Divider().opacity(0.5)
            taskToolStrip
        }
        .frame(width: drawerWidth)
        .background(drawerBackground)
        .onAppear {
            _ = appState.prepareDispatchTaskTakeover(runtimeSessionID: runtime.id)
        }
        .alert(
            L10n.Dispatch.markSuccessfulConfirmationTitle,
            isPresented: $isConfirmingManualCompletion
        ) {
            Button(L10n.Dispatch.cancel, role: .cancel) {}
            Button(L10n.Dispatch.markSuccessfulAndContinue) {
                appState.markDispatchTaskSuccessfulAndContinue(
                    goalID: goal.id,
                    taskID: task.id
                )
            }
        } message: {
            Text(L10n.Dispatch.markSuccessfulConfirmationMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    onClose()
                } label: {
                    Label(
                        L10n.Dispatch.taskConversationProjectBreadcrumb(goal.statement),
                        systemImage: "chevron.left"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
                .help(L10n.Dispatch.returnToDispatchBoard)

                Spacer(minLength: 8)

                Button(action: onOpenFullConversation) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .help(L10n.Dispatch.openFullTaskConversation)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(L10n.AgentSidePanel.close)
            }

            Text(task.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(AgentDispatchPresentation.taskStateColor(task.state))
                    .frame(width: 7, height: 7)
                Text(L10n.Dispatch.state(task.state))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AgentDispatchPresentation.taskStateColor(task.state))
                Divider().frame(height: 12)
                Text(runtime.executionAgent.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                modelMenu
            }

            if modelPresentation.switchAppliesNextTurn,
               let nextModelID = modelPresentation.nextModelID {
                Label(
                    L10n.Dispatch.modelSwitchAppliesNextTurn(nextModelID),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(drawerBackground.opacity(0.96))
    }

    @ViewBuilder
    private var modelMenu: some View {
        if let currentModelID = modelPresentation.currentModelID {
            Menu {
                if switchableModelProfiles.isEmpty {
                    Text(L10n.Dispatch.modelSwitchUnavailableForExecutor)
                } else {
                    ForEach(switchableModelProfiles) { profile in
                        Button {
                            onModelProfile(profile.id)
                        } label: {
                            Label(
                                profileMenuTitle(profile),
                                systemImage: profile.modelID == modelPresentation.nextModelID
                                    ? "checkmark"
                                    : "cpu"
                            )
                        }
                    }
                    Divider()
                    Text(L10n.Dispatch.modelSwitchSafePointHelp)
                }
            } label: {
                Label(currentModelID, systemImage: "cpu")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.Dispatch.currentExecutionModel)
            .accessibilityLabel(L10n.Dispatch.currentExecutionModel)
            .accessibilityValue(currentModelID)
        } else {
            Label(L10n.Dispatch.modelUnknown, systemImage: "cpu")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func profileMenuTitle(_ profile: AgentExecutionProfile) -> String {
        guard let modelID = profile.modelID else { return profile.name }
        return "\(profile.name) · \(modelID)"
    }

    private var metricsStrip: some View {
        AgentDispatchTaskMetricsView(
            runtime: runtime,
            task: task,
            presentation: .detailed
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(
            appState.editorSettings.interfaceSkin.palette.hoverFill.opacity(0.28)
        )
    }

    private var takeoverComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            takeoverActivityStatus

            SubmitOnReturnTextView(
                text: inputBinding,
                placeholder: L10n.Dispatch.takeoverInstructionPlaceholder,
                fontSize: 12,
                onSubmit: sendInstruction
            )
            .frame(height: 82)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(appState.editorSettings.interfaceSkin.palette.panelFill.opacity(0.66))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        appState.editorSettings.interfaceSkin.palette.hairline.opacity(0.72),
                        lineWidth: 1
                    )
            )

            HStack {
                Text(
                    runtime.isResponding
                        ? L10n.Dispatch.takeoverQueuesAtSafePoint
                        : L10n.Dispatch.takeoverStartsNextTurn
                )
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer()

                if isNodeRunning {
                    Button(role: .destructive) {
                        appState.stopDispatchTask(goalID: goal.id, taskID: task.id)
                    } label: {
                        Label(L10n.Dispatch.stopTask, systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.Dispatch.stopTaskHelp)
                    .accessibilityIdentifier("dispatch-takeover-stop-task")
                }

                if canMarkSuccessfulAndContinue {
                    Button {
                        isConfirmingManualCompletion = true
                    } label: {
                        Label(
                            L10n.Dispatch.markSuccessfulAndContinue,
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.Dispatch.markSuccessfulAndContinueHelp)
                    .accessibilityIdentifier("dispatch-takeover-mark-successful")
                }

                Button {
                    sendInstruction()
                } label: {
                    Label(L10n.Dispatch.sendTakeoverInstruction, systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .controlSize(.small)
                .disabled(runtime.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(drawerBackground.opacity(0.94))
    }

    @ViewBuilder
    private var takeoverActivityStatus: some View {
        switch AgentDispatchTakeoverActivityStatus.resolve(
            isResponding: runtime.isResponding,
            isAwaitingProviderSlot: runtime.isAwaitingProviderSlot
        ) {
        case .hidden:
            EmptyView()
        case .waitingForProvider:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.AgentPanel.queueWaiting)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .accessibilityIdentifier("dispatch-takeover-provider-waiting")
        case .active:
            AgentSemanticActivityStatusLine(style: .composer)
                .accessibilityIdentifier("dispatch-takeover-activity-status")
        }
    }

    private var taskToolStrip: some View {
        HStack(spacing: 4) {
            ForEach(primaryPanelKinds) { kind in
                Button {
                    selectedPanel = selectedPanel == kind ? nil : kind
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(.system(size: 9, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(selectedPanel == kind ? appState.editorSettings.interfaceSkin.palette.accent : nil)
            }

            Menu {
                Button(action: onOpenFullConversation) {
                    Label(L10n.Dispatch.openFullTaskConversation, systemImage: "arrow.up.right.square")
                }
                if !overflowPanelKinds.isEmpty {
                    Divider()
                    ForEach(overflowPanelKinds) { kind in
                        Button {
                            selectedPanel = kind
                        } label: {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24)
            }
            .menuStyle(.borderlessButton)
            .agentQuietMenuChrome()
            .help(L10n.Dispatch.moreTaskTools)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(drawerBackground.opacity(0.96))
    }

    private var primaryPanelKinds: [AgentSidePanelKind] {
        AgentDispatchTaskToolPolicy.primaryKinds(
            hasPlan: runtime.currentPlan != nil,
            activeExperts: runtime.activeExperts
        )
    }

    private var overflowPanelKinds: [AgentSidePanelKind] {
        AgentDispatchTaskToolPolicy.overflowKinds(
            activeExperts: runtime.activeExperts
        )
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { runtime.input },
            set: { runtime.input = $0 }
        )
    }

    private var drawerBackground: Color {
        let settings = appState.editorSettings
        let opacity = settings.hasConfiguredAgentWallpaper
            ? settings.agentWallpaperSurfaceOpacity
            : 1
        return settings.interfaceSkin.palette.panelFill.opacity(opacity)
    }

    /// 节点是否还在跑。`isResponding` 之外还要看 `isAwaitingProviderSlot`：
    /// 抢不到并发槽的回合同样已经排进队列，操作员要能在它真正开跑前叫停。
    private var isNodeRunning: Bool {
        runtime.isResponding
            || runtime.isAwaitingProviderSlot
            || task.state == .running
    }

    private var canMarkSuccessfulAndContinue: Bool {
        !runtime.isResponding
            && !runtime.isAwaitingProviderSlot
            && (task.state == .failed || task.state == .cancelled || task.state == .accepted)
    }

    private func sendInstruction() {
        guard !runtime.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        appState.sendDispatchTaskTakeoverInstruction(
            goalID: goal.id,
            taskID: task.id,
            runtimeSessionID: runtime.id
        )
    }
}
