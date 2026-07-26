//
//  AgentDispatchInspectorView.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchInspectorView: View {
    let goal: AgentDispatchGoal
    let task: AgentDispatchTask
    let localExecutors: Set<AgentExecutionAgent>
    let runtimeDescriptors: [RuntimeDescriptor]
    let onExecutorChoice: (AgentDispatchExecutorChoice) -> Void
    let onWorkspaceBindingChoice: (String?) -> Void
    let onLaunch: () -> Void
    let onOpenConversation: () -> Void

    private var effectiveWorkspaceBinding: AgentDispatchWorkspaceBinding? {
        goal.resolvedWorkspaceBinding(for: task)
    }

    private var selectedWorkspaceBinding: AgentDispatchWorkspaceBinding? {
        goal.workspaceBinding(id: task.workspaceBindingID)
    }

    private var effectiveTarget: AgentDispatchTargetChoice? {
        effectiveWorkspaceBinding?.targetChoice
    }

    private var availableExecutors: Set<AgentExecutionAgent> {
        guard let effectiveTarget else { return [] }
        switch effectiveTarget {
        case .automatic, .local:
            return localExecutors
        case .remote(let id):
            return runtimeDescriptors.first(where: { $0.id == id })?
                .capabilities.availableExecutionAgents ?? [.willDeep]
        }
    }

    private var effectiveExecutorChoice: AgentDispatchExecutorChoice {
        task.executorChoice == .automatic ? goal.executorChoice : task.executorChoice
    }

    private var executorDecision: AgentDispatchExecutorDecision {
        AgentDispatchExecutorResolver.resolve(
            title: task.title,
            choice: effectiveExecutorChoice,
            availableExecutors: availableExecutors
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                sectionDivider
                executorSection
                sectionDivider
                environmentSection
                sectionDivider
                branchSection
                sectionDivider
                acceptanceSection
                sectionDivider
                activitySection
                actions
                    .padding(.top, 16)
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L10n.Dispatch.status)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(
                    L10n.Dispatch.state(task.state),
                    systemImage: taskStateSymbol
                )
                .foregroundStyle(AgentDispatchPresentation.taskStateColor(task.state))
            }
            .font(.system(size: 11, weight: .medium))
        }
    }

    private var executorSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(L10n.Dispatch.executor)
            Menu {
                ForEach(AgentDispatchExecutorChoice.allCases) { choice in
                    Button {
                        onExecutorChoice(choice)
                    } label: {
                        Label(
                            AgentDispatchPresentation.executorChoiceName(choice),
                            systemImage: choice == task.executorChoice ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                pickerSurface(
                    symbol: executorDecision.executor.symbol,
                    text: task.executorChoice == .automatic
                        ? L10n.Dispatch.automaticResolved(executorDecision.executor.displayName)
                        : executorDecision.executor.displayName,
                    locked: task.executorChoice != .automatic
                )
            }
            .menuStyle(.borderlessButton)
            Text(L10n.Dispatch.executorReason(executorDecision.reason))
                .font(.system(size: 10))
                .foregroundStyle(executorDecision.isAvailable ? .secondary : Color.red)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 84), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(
                    AgentExecutionAgent.allCases.filter(availableExecutors.contains),
                    id: \.self
                ) { executor in
                    compactBadge(executor.displayName, symbol: executor.symbol)
                }
            }
        }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(L10n.Dispatch.environment)
            Menu {
                Button {
                    onWorkspaceBindingChoice(nil)
                } label: {
                    Label(
                        L10n.Dispatch.automatic,
                        systemImage: task.workspaceBindingID == nil ? "checkmark" : "circle"
                    )
                }
                ForEach(goal.effectiveWorkspaceBindings) { binding in
                    Button {
                        onWorkspaceBindingChoice(binding.id)
                    } label: {
                        Label(
                            workspaceBindingLabel(binding),
                            systemImage: task.workspaceBindingID == binding.id
                                ? "checkmark"
                                : binding.targetChoice.isRemoteTarget
                                    ? "network"
                                    : "desktopcomputer"
                        )
                    }
                }
            } label: {
                pickerSurface(
                    symbol: effectiveTarget?.isRemoteTarget == true
                        ? "network"
                        : effectiveTarget == nil ? "folder.badge.questionmark" : "desktopcomputer",
                    text: selectedWorkspaceBinding
                        .map(workspaceBindingLabel)
                        ?? L10n.Dispatch.automatic,
                    locked: task.workspaceBindingID != nil
                )
            }
            .menuStyle(.borderlessButton)
            .disabled(!goal.isWorkspaceBound)
            if case .remote(let id)? = effectiveTarget,
               let runtime = runtimeDescriptors.first(where: { $0.id == id }) {
                Label(
                    runtime.lastProbeAt == nil ? L10n.Dispatch.notProbed : L10n.Dispatch.probed,
                    systemImage: runtime.lastProbeAt == nil ? "circle" : "checkmark.circle.fill"
                )
                .font(.system(size: 10))
                .foregroundStyle(runtime.lastProbeAt == nil ? .secondary : Color.green)
                Text(effectiveWorkspaceBinding?.location.path ?? runtime.defaultWorkspacePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var branchSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(L10n.Dispatch.branchAndWorkspace)
            labeledValue(L10n.Dispatch.branch, value: task.branchName)
            labeledValue(
                L10n.Dispatch.workspace,
                value: workspaceDisplayValue
            )
        }
    }

    private var acceptanceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                fieldLabel(L10n.Dispatch.acceptance)
                Spacer()
                Text("0/\(task.acceptanceCriteria.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(task.acceptanceCriteria.enumerated()), id: \.offset) { _, criterion in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(criterion)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(L10n.Dispatch.recentInstructions)
            if goal.commands.isEmpty {
                Text(L10n.Dispatch.noRecentInstructions)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                ForEach(goal.commands.prefix(3)) { command in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(command.text)
                            .font(.system(size: 10))
                            .lineLimit(2)
                        Text(AgentDispatchPresentation.commandStatus(command))
                            .font(.system(size: 9))
                            .foregroundStyle(command.status == .cancelled ? .secondary : Color.accentColor)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if task.runtimeSessionID != nil {
                Button(action: onOpenConversation) {
                    Label(L10n.Dispatch.openTaskConversation, systemImage: "bubble.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button(action: onLaunch) {
                Label(L10n.Dispatch.launchTask, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                goal.isPaused
                    || !goal.isWorkspaceBound
                    || effectiveTarget == nil
                    || task.state == .blocked
                    || task.state == .running
                    || !executorDecision.isAvailable
            )
        }
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 14)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func pickerSurface(symbol: String, text: String, locked: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
            Spacer()
            Image(systemName: locked ? "lock.fill" : "chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private func compactBadge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 19)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func labeledValue(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var workspaceDisplayValue: String {
        guard let effectiveWorkspaceBinding else {
            return L10n.Dispatch.workspaceRequiredShort
        }
        return effectiveWorkspaceBinding.location.path
    }

    private func workspaceBindingLabel(
        _ binding: AgentDispatchWorkspaceBinding
    ) -> String {
        switch binding.location {
        case .local(let path):
            return "\(L10n.Dispatch.localEnvironment) · \(path)"
        case .remote(let runtimeID, let path):
            let runtimeName = runtimeDescriptors.first { $0.id == runtimeID }?.displayName
                ?? L10n.Dispatch.environment
            return "\(runtimeName) · \(path)"
        }
    }

    private var taskStateSymbol: String {
        switch task.state {
        case .blocked: return "lock"
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .reviewing: return "checkmark.shield"
        case .accepted: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .merged: return "checkmark.circle.fill"
        }
    }
}

extension AgentDispatchTargetChoice {
    var isRemoteTarget: Bool {
        if case .remote = self { return true }
        return false
    }
}
