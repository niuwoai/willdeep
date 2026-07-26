//
//  AgentDispatchSidebarSections.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchSidebarSections: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var coordinator: AgentDispatchCoordinator

    private var runtimes: [RuntimeDescriptor] {
        AgentRuntimeStore.loadDescriptors().filter { $0.transport == .ssh }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            goalsSection
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            environmentsSection
        }
        .onAppear {
            coordinator.synchronize(with: appState.agentSessions)
        }
    }

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader(L10n.Dispatch.goalsHeader, trailingSymbol: "plus") {
                appState.startGoalConversationInLocalWorkspace()
            }
            if coordinator.goals.isEmpty {
                Text(L10n.Dispatch.emptyTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                ForEach(coordinator.goals) { goal in
                    goalRow(goal)
                }
            }
        }
    }

    private var environmentsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader(L10n.Dispatch.environmentsHeader)
            environmentRow(
                symbol: "desktopcomputer",
                title: L10n.Dispatch.localEnvironment,
                subtitle: L10n.Dispatch.ready,
                isReady: true
            )
            ForEach(runtimes) { runtime in
                environmentRow(
                    symbol: "network",
                    title: "\(runtime.displayName) · SSH",
                    subtitle: runtime.lastProbeAt == nil
                        ? L10n.Dispatch.notProbed
                        : L10n.Dispatch.probed,
                    isReady: runtime.lastProbeAt != nil
                )
            }
            Button {
                EditorSettingsNavigation.shared.open(.remoteRuntimes, appState: appState)
            } label: {
                Label(L10n.Dispatch.addSSH, systemImage: "plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionHeader(
        _ title: String,
        trailingSymbol: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Text(title)
                .font(AgentDesign.sidebarSectionFont)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailingSymbol, let action {
                Button(action: action) {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
    }

    private func goalRow(_ goal: AgentDispatchGoal) -> some View {
        let isSelected = coordinator.selectedGoalID == goal.id
        let palette = appState.editorSettings.interfaceSkin.palette
        return Button {
            coordinator.selectGoal(goal.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: goal.isPaused ? "pause.circle" : "scope")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? palette.accent : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(goalRowSubtitle(goal))
                        .font(.system(size: 10))
                        .foregroundStyle(goal.isWorkspaceBound ? .secondary : Color.orange)
                }
                Spacer(minLength: 4)
                progressRing(goal.progressFraction, isPaused: goal.isPaused)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AgentDesign.sidebarSelectionCornerRadius)
                    .fill(isSelected ? palette.selectionFill : Color.clear)
                    .padding(.horizontal, AgentDesign.sidebarSelectionHorizontalInset)
            )
        }
        .buttonStyle(.plain)
    }

    private func goalRowSubtitle(_ goal: AgentDispatchGoal) -> String {
        guard goal.isWorkspaceBound, let project = goal.logicalProject else {
            return L10n.Dispatch.workspaceRequiredShort
        }
        let progress = goal.isPaused
            ? L10n.Dispatch.paused
            : "\(Int(goal.progressFraction * 100))%"
        return "\(project.displayName) · \(progress)"
    }

    private func environmentRow(
        symbol: String,
        title: String,
        subtitle: String,
        isReady: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isReady ? Color.green : Color.secondary)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(isReady ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private func progressRing(_ progress: Double, isPaused: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(
                    isPaused ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
    }
}
