//
//  AgentComposerSecondaryPickers.swift
//  WillDeep
//
//  Secondary composer controls split from AgentComposerPickers.swift so each
//  source file stays reviewable and below the repository size limit.
//

import SwiftUI

// MARK: - Execution picker (built-in / external coding agents)

struct AgentExecutionPickerPill: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedAgent: AgentExecutionAgent = .willDeep

    var body: some View {
        Menu {
            ForEach(AgentExecutionAgent.allCases) { agent in
                Button {
                    selectedAgent = agent
                    appState.setAgentExecutionAgent(agent)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: agent.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName)
                            Text(agent.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if selectedAgent == agent {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedAgent.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(selectedAgent.displayName)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 11,
                        weight: .medium
                    ))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help(L10n.ExecutionAgent.pickerHelp)
        .onAppear(perform: syncSelectedAgent)
        .onReceive(appState.$activeAgentSessionID) { _ in
            syncSelectedAgent()
        }
    }

    private var pillForeground: Color {
        selectedAgent == .willDeep ? Color.secondary : Color.white
    }

    private var pillBackground: Color {
        switch selectedAgent {
        case .willDeep: return Color.secondary.opacity(0.10)
        case .claudeCode: return Color.purple
        case .codexCLI: return Color.accentColor
        case .cursorAgent: return Color.green
        case .clineCLI: return Color.orange
        }
    }

    private var pillBorder: Color {
        selectedAgent == .willDeep
            ? Color.secondary.opacity(0.25)
            : Color.clear
    }

    private func syncSelectedAgent() {
        selectedAgent = appState.agentExecutionAgent
    }
}

// MARK: - Mode picker (Normal / Plan / Goal)

struct AgentModePickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            ForEach(AgentInteractionMode.allCases) { mode in
                Button {
                    appState.setAgentInteractionMode(mode)
                } label: {
                    Label(mode.displayName, systemImage: mode.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.agentInteractionMode.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.agentInteractionMode.displayName)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 11,
                        weight: .medium
                    ))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help("Conversation mode — Plan locks writes until you approve; Goal pins an objective to every reply.")
    }

    private var pillForeground: Color {
        appState.agentInteractionMode == .normal ? Color.secondary : Color.white
    }

    private var pillBackground: Color {
        switch appState.agentInteractionMode {
        case .normal: return Color.secondary.opacity(0.10)
        case .plan: return Color.orange
        case .goal: return Color.accentColor
        }
    }

    private var pillBorder: Color {
        appState.agentInteractionMode == .normal ? Color.secondary.opacity(0.25) : Color.clear
    }
}

/// Overflow control for composer actions that do not currently fit inline.
struct ComposerOverflowPill: View {
    @EnvironmentObject var appState: AppState
    let controls: [ComposerOverflowControl]
    @State private var isPresented = false

    init(controls: [ComposerOverflowControl] = [.executor, .plugins, .experts]) {
        self.controls = controls
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .help(L10n.Composer.overflowHelp)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.Composer.overflowTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if controls.contains(.approval) {
                    overflowRow(L10n.Composer.overflowApproval) { AgentApprovalModePickerPill() }
                }
                if controls.contains(.executor) {
                    overflowRow(L10n.Composer.overflowExecutor) { AgentExecutionPickerPill() }
                }
                if controls.contains(.plugins) {
                    overflowRow(L10n.Composer.overflowPlugins) { AgentPluginPickerPill() }
                }
                if controls.contains(.experts) {
                    AgentExpertActivationList()
                        .focusable(false)
                }
            }
            .padding(14)
            .frame(width: controls.contains(.experts) ? 340 : 300, alignment: .leading)
            .focusable(false)
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func overflowRow<Pill: View>(
        _ title: String,
        @ViewBuilder pill: () -> Pill
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
            Spacer(minLength: 0)
            pill()
                .focusable(false)
        }
        .focusable(false)
    }
}
