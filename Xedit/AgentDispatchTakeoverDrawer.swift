//
//  AgentDispatchTakeoverDrawer.swift
//  WillDeep
//
//  Context-preserving human intervention for a running dispatch node.
//

import SwiftUI

struct AgentDispatchTakeoverDrawer: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    let goal: AgentDispatchGoal
    let task: AgentDispatchTask
    let onClose: () -> Void
    let onOpenFullConversation: () -> Void

    @State private var selectedPanel: AgentSidePanelKind?
    @State private var selectedFile: URL?

    private let drawerWidth: CGFloat = 420

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
                Text(runtime.session.executionAgent.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(drawerBackground.opacity(0.96))
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
            ZStack(alignment: .topLeading) {
                TextEditor(text: inputBinding)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(minHeight: 76, maxHeight: 112)

                if runtime.input.isEmpty {
                    Text(L10n.Dispatch.takeoverInstructionPlaceholder)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
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

                Button {
                    sendInstruction()
                } label: {
                    Label(L10n.Dispatch.sendTakeoverInstruction, systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(runtime.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(drawerBackground.opacity(0.94))
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

    private func sendInstruction() {
        guard appState.prepareDispatchTaskTakeover(runtimeSessionID: runtime.id) else { return }
        appState.sendAgentMessage()
    }
}
