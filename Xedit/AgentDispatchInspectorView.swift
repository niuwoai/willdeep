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
    let profiles: [AgentExecutionProfile]
    let onExecutorChoice: (AgentDispatchExecutorChoice) -> Void
    let onWorkspaceBindingChoice: (String?) -> Void
    let onProfiles: (String?, [String]) -> Void
    let onManageProfiles: () -> Void
    let onLaunch: () -> Void
    let onStop: () -> Void
    let onOpenConversation: () -> Void
    let onEdit: () -> Void

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
        if task.executorChoice == .automatic,
           let profile = selectedPrimaryProfile {
            return AgentDispatchExecutorDecision(
                executor: profile.executor,
                reason: .userPinned,
                isAvailable: availableExecutors.contains(profile.executor)
            )
        }
        return AgentDispatchExecutorResolver.resolve(
            title: task.title,
            choice: effectiveExecutorChoice,
            availableExecutors: availableExecutors
        )
    }

    private var selectedPrimaryProfile: AgentExecutionProfile? {
        profiles.first { $0.id == task.primaryProfileID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                sectionDivider
                profileSection
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

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(L10n.Dispatch.primaryProfile)
            Menu {
                Button {
                    onProfiles(nil, task.fallbackProfileIDs ?? [])
                } label: {
                    Label(
                        L10n.Dispatch.automatic,
                        systemImage: task.primaryProfileID == nil ? "checkmark" : "wand.and.stars"
                    )
                }
                ForEach(profiles) { profile in
                    Button {
                        onProfiles(
                            profile.id,
                            (task.fallbackProfileIDs ?? []).filter {
                                $0 != profile.id
                            }
                        )
                    } label: {
                        Label(
                            profile.name,
                            systemImage: profile.id == task.primaryProfileID
                                ? "checkmark"
                                : profile.executor.symbol
                        )
                    }
                }
                Divider()
                Button(action: onManageProfiles) {
                    Label(L10n.Dispatch.manageProfiles, systemImage: "gearshape")
                }
            } label: {
                pickerSurface(
                    symbol: selectedPrimaryProfile?.executor.symbol ?? "wand.and.stars",
                    text: selectedPrimaryProfile?.name ?? L10n.Dispatch.automatic,
                    locked: task.primaryProfileID != nil
                )
            }
            .menuStyle(.borderlessButton)

            Menu(L10n.Dispatch.fallbackProfiles) {
                ForEach(profiles.filter { $0.id != task.primaryProfileID }) { profile in
                    Button {
                        var fallbacks = task.fallbackProfileIDs ?? []
                        if let index = fallbacks.firstIndex(of: profile.id) {
                            fallbacks.remove(at: index)
                        } else {
                            fallbacks.append(profile.id)
                        }
                        onProfiles(task.primaryProfileID, fallbacks)
                    } label: {
                        Label(
                            profile.name,
                            systemImage: (task.fallbackProfileIDs ?? []).contains(profile.id)
                                ? "checkmark"
                                : profile.executor.symbol
                        )
                    }
                }
            }
            .menuStyle(.borderlessButton)

            if let selectedPrimaryProfile {
                Text(selectedPrimaryProfile.displayDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
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
            fieldLabel(L10n.Dispatch.humanOverride)
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
            Button(action: onEdit) {
                Label(L10n.Dispatch.humanOverride, systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(task.state == .running || task.state == .reviewing)
            if task.runtimeSessionID != nil {
                Button(action: onOpenConversation) {
                    Label(L10n.Dispatch.openTaskConversation, systemImage: "bubble.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if task.state == .running {
                Button(role: .destructive, action: onStop) {
                    Label(L10n.Dispatch.stopTask, systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help(L10n.Dispatch.stopTaskHelp)
                .accessibilityIdentifier("dispatch-inspector-stop-task")
            } else {
                Button(action: onLaunch) {
                    Label(L10n.Dispatch.launchTask, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .disabled(
                    goal.isPaused
                        || !goal.isWorkspaceBound
                        || effectiveTarget == nil
                        || task.state == .blocked
                        || !executorDecision.isAvailable
                )
            }
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

struct AgentDispatchAcceptanceInspectorView: View {
    let goal: AgentDispatchGoal
    let onSelectTask: (UUID) -> Void

    private var completedTasks: [AgentDispatchTask] {
        goal.tasks.filter { $0.state == .accepted || $0.state == .merged }
    }

    private var pendingTasks: [AgentDispatchTask] {
        goal.tasks.filter { $0.state != .accepted && $0.state != .merged }
    }

    private var totalCriteria: Int {
        goal.tasks.reduce(0) { $0 + $1.acceptanceCriteria.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                sectionDivider
                summary
                sectionDivider
                taskChecklist
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Dispatch.acceptanceGate)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(pendingTasks.isEmpty ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Dispatch.acceptanceGate)
                        .font(.system(size: 17, weight: .semibold))
                    Text(L10n.Dispatch.acceptanceInspectorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(
                value: Double(completedTasks.count),
                total: Double(max(goal.tasks.count, 1))
            )
            .tint(pendingTasks.isEmpty ? .green : .orange)
            Text(L10n.Dispatch.acceptanceProgress(completedTasks.count, goal.tasks.count))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L10n.Dispatch.graphSummaryTitle)
            HStack(spacing: 8) {
                summaryTile(
                    value: "\(goal.tasks.count)",
                    label: L10n.Dispatch.graphTasks,
                    color: .blue
                )
                summaryTile(
                    value: "\(pendingTasks.count)",
                    label: L10n.Dispatch.graphPending,
                    color: .orange
                )
                summaryTile(
                    value: "\(totalCriteria)",
                    label: L10n.Dispatch.graphCriteria,
                    color: .indigo
                )
            }
        }
    }

    private var taskChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L10n.Dispatch.acceptanceByTask)
            ForEach(goal.tasks) { task in
                Button {
                    onSelectTask(task.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(
                            systemName: task.state == .accepted || task.state == .merged
                                ? "checkmark.circle.fill"
                                : task.state == .failed
                                    ? "exclamationmark.triangle.fill"
                                    : "circle"
                        )
                        .foregroundStyle(
                            AgentDispatchPresentation.taskStateColor(task.state)
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(L10n.Dispatch.criteriaCount(task.acceptanceCriteria.count))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.58))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.13), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
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

    private func summaryTile(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension AgentDispatchTargetChoice {
    var isRemoteTarget: Bool {
        if case .remote = self { return true }
        return false
    }
}
