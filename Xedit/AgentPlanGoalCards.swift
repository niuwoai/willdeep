//
//  AgentPlanGoalCards.swift
//  WillDeep
//
//  Pinned-above-transcript cards for Plan and Goal modes, split out of
//  AgentModeView.swift in rc42.
//
//   - `AgentPlanCard`: orange-tinted card listing every plan step
//     with a status glyph the user can cycle (pending → in-progress →
//     done → skipped → pending). While `.proposed`, the card surfaces
//     Approve / Reject buttons; once approved, it offers Mark Complete.
//     `AgentPlanRevisionRow` sits at the bottom — collapsed Replan
//     button that expands into a one-line note field for mid-execution
//     guidance.
//   - `AgentPlanStepRow`: per-step row. Context menu for edit / insert
//     above / insert below / restart-from-here / remove, all driven
//     through the shared `AgentPlanStepSimpleSheet` (single-field
//     modal with one confirm button).
//   - `AgentGoalCard`: accent-tinted card showing the active goal
//     statement plus its checklist. Pencil glyph in the header opens
//     `AgentGoalEditorSheet` for re-editing.
//   - `AgentGoalEditorSheet`: statement field + newline-separated
//     checklist text editor + Save/Cancel; reused from the mode
//     picker's Goal entry and the Goal card's edit affordance.
//
//  Previously a mix of `private struct` (revision row / step row /
//  simple sheet) and `struct` (card + editor sheet) inside the main
//  file; the privates land here as internal so the cards can compose
//  them across the file boundary.
//

import SwiftUI

enum AgentPlanStepLayoutMetrics {
    /// Keeps `10.` and larger indexes on one line while preserving a stable
    /// text column across every row in the plan.
    static let indexColumnWidth: CGFloat = 30
}

nonisolated enum AgentPlanCardExpansionPolicy {
    static func initiallyExpanded(for status: AgentPlan.Status) -> Bool {
        status == .proposed
    }

    static func shouldCollapseForAssistantRound(
        previousMessageID: AgentMessage.ID?,
        currentMessageID: AgentMessage.ID?
    ) -> Bool {
        guard let currentMessageID else { return false }
        return currentMessageID != previousMessageID
    }
}

// MARK: - Plan card

struct AgentPlanCard: View {
    @EnvironmentObject var appState: AppState
    let plan: AgentPlan
    @Binding var isExpanded: Bool
    /// When floating in the conversation activity overlay, drop the orange
    /// tinted surface for the shared `.regularMaterial` card chrome so the plan
    /// card matches the artifact / media / dev-server cards stacked beside it.
    /// The transcript-inline and side-panel mounts keep the orange surface.
    var floating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.number")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(L10n.PlanCard.header)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    PlanStatusPill(status: plan.status)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? L10n.PlanCard.collapseHelp : L10n.PlanCard.expandHelp)
            .accessibilityLabel(L10n.PlanCard.header)
            .accessibilityValue(isExpanded ? L10n.PlanCard.expanded : L10n.PlanCard.collapsed)

            if isExpanded {
                if !plan.summary.isEmpty {
                    Text(plan.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        AgentPlanStepRow(
                            index: index + 1,
                            step: step,
                            interactive: plan.status != .proposed && plan.status != .rejected,
                            onCycle: { next in
                                appState.setAgentPlanStepStatus(id: step.id, status: next)
                            }
                        )
                    }
                }

                if plan.status == .proposed {
                    // rc16:Reject 在左、Approve 在右(borderedProminent),对齐
                    // macOS「拒绝远离主操作位」防误触习惯。
                    HStack(spacing: 8) {
                        Button(L10n.PlanCard.rejectButton) { appState.rejectAgentPlan() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button(L10n.PlanCard.approveButton) { appState.approveAgentPlan() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Spacer(minLength: 0)
                        Text(L10n.PlanCard.infoText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if plan.status == .approved || plan.status == .executing {
                    Button(L10n.PlanCard.markCompleteButton) { appState.completeAgentPlan() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                // Always offer a way to revise mid-execution — useful when
                // the agent's plan diverged from what the user actually
                // wanted, or when a constraint emerges partway through.
                AgentPlanRevisionRow()
            }
        }
        .padding(12)
        .background(planCardBackground)
        .overlay(planCardBorder)
        .shadow(color: floating ? Color.black.opacity(0.055) : .clear, radius: floating ? 7 : 0, x: 0, y: floating ? 2 : 0)
    }

    @ViewBuilder
    private var planCardBackground: some View {
        if floating {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        }
    }

    @ViewBuilder
    private var planCardBorder: some View {
        if floating {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }
}

/// "Replan" action collapsed by default; expands into a one-line note
/// field + Send button so the user can either re-ask cold ("revise the
/// plan") or pass guidance ("use sed instead of patches"). Sits at the
/// bottom of every plan card.
struct AgentPlanRevisionRow: View {
    @EnvironmentObject var appState: AppState
    @State private var expanded = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .opacity(0.4)
            HStack(spacing: 6) {
                if expanded {
                    TextField(L10n.PlanRevision.placeholder, text: $note)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .focused($noteFocused)
                        .onSubmit { send() }
                    Button(L10n.PlanRevision.sendButton) { send() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.isAgentResponding && appState.agentQueuedMessages.count > 8)
                    Button {
                        expanded = false
                        note = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.PlanRevision.cancelButtonHelp)
                } else {
                    Button {
                        expanded = true
                        // Defer focus so the TextField has mounted first.
                        DispatchQueue.main.async { noteFocused = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .semibold))
                            Text(L10n.PlanRevision.replanButton)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.orange)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(L10n.PlanRevision.replanTooltip)
                    Spacer(minLength: 0)
                    if appState.isAgentResponding {
                        Text(L10n.PlanRevision.queueNotice)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func send() {
        appState.requestPlanRevision(note: note)
        expanded = false
        note = ""
    }
}

/// A single-line label that scrolls its overflow to the left while the
/// pointer hovers, so a long plan step stays one row tall yet stays fully
/// readable on demand. When the text already fits, it renders as a plain
/// static line and never animates. macOS 13 compatible — measures widths
/// with a classic `GeometryReader` + `PreferenceKey` (no `onGeometryChange`).
struct MarqueeOnHoverText: View {
    let attributed: AttributedString
    var font: Font = .system(size: 12)
    var color: Color = .primary
    var strikethrough: Bool = false
    /// Full text surfaced as a native tooltip, so the whole step is
    /// reachable even without waiting out the scroll.
    var tooltip: String? = nil

    /// Pixels-per-second the overflow slides at; keeps long and short
    /// steps feeling like the same gesture.
    private let velocity: CGFloat = 26

    @State private var textSize: CGSize = .init(width: 0, height: 16)
    @State private var containerWidth: CGFloat = 0
    @State private var hovering = false

    private var overflow: CGFloat { max(0, textSize.width - containerWidth) }
    private var scrollable: Bool { overflow > 0.5 }

    private var line: some View {
        Text(attributed)
            .font(font)
            .strikethrough(strikethrough, color: .secondary)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var marqueeAnimation: Animation {
        guard hovering, scrollable else { return .easeOut(duration: 0.22) }
        let duration = max(0.6, Double(overflow) / Double(velocity))
        return .linear(duration: duration).delay(0.35).repeatForever(autoreverses: true)
    }

    var body: some View {
        GeometryReader { geo in
            line
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: MarqueeSizeKey.self, value: inner.size)
                    }
                )
                .offset(x: hovering && scrollable ? -overflow : 0)
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
                .animation(marqueeAnimation, value: hovering)
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { containerWidth = $0 }
        }
        .frame(height: textSize.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onPreferenceChange(MarqueeSizeKey.self) { textSize = $0 }
        .onHover { inside in
            // Only arm the scroll when there is actually hidden overflow;
            // a fitting step should never twitch on hover.
            hovering = inside && scrollable
        }
        .help(tooltip ?? "")
    }
}

private struct MarqueeSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// One row of the plan card. The status glyph doubles as a button that
/// cycles pending → in_progress → done → skipped → pending, so the
/// user can override whatever the agent reported. While the plan is
/// still .proposed (awaiting approval), the glyph is shown but not
/// interactive — checking off steps before approval doesn't make sense.
struct AgentPlanStepRow: View {
    @EnvironmentObject var appState: AppState
    let index: Int
    let step: AgentPlan.Step
    let interactive: Bool
    let onCycle: (AgentPlan.StepStatus) -> Void

    @State private var sheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case edit
        case insertAbove
        case insertBelow
        case restart

        var id: String {
            switch self {
            case .edit: return "edit"
            case .insertAbove: return "above"
            case .insertBelow: return "below"
            case .restart: return "restart"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                guard interactive else { return }
                onCycle(nextStatus(after: step.status))
            } label: {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!interactive)
            .help(interactive ? "Cycle status (was \(step.status.rawValue))" : L10n.PlanStep.cycleStatusHelp)

            Text("\(index).")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: AgentPlanStepLayoutMetrics.indexColumnWidth, alignment: .trailing)
            MarqueeOnHoverText(
                attributed: MarkdownInline.attributedString(from: step.text),
                color: textColor,
                strikethrough: step.status == .done || step.status == .skipped,
                tooltip: step.text
            )
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(L10n.PlanStep.menuEdit) { sheet = .edit }
            Button(L10n.PlanStep.menuInsertAbove) { sheet = .insertAbove }
            Button(L10n.PlanStep.menuInsertBelow) { sheet = .insertBelow }
            if interactive {
                Divider()
                Button(L10n.PlanStep.menuRestart) { sheet = .restart }
                    .disabled(
                        appState.agentInteractionMode != .plan
                            && appState.agentInteractionMode != .goal
                    )
            }
            Divider()
            Button(L10n.PlanStep.menuRemove, role: .destructive) {
                appState.removeAgentPlanStep(id: step.id)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .edit:
                AgentPlanStepSimpleSheet(
                    title: "Edit step \(index)",
                    initialText: step.text,
                    placeholder: L10n.PlanStepSheet.placeholder,
                    confirmTitle: "Save",
                    onConfirm: { text in
                        appState.editAgentPlanStepText(id: step.id, newText: text)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            case .insertAbove:
                AgentPlanStepSimpleSheet(
                    title: "Insert step above \(index)",
                    initialText: "",
                    placeholder: L10n.PlanStepSheet.insertAbovePlaceholder,
                    confirmTitle: "Insert",
                    onConfirm: { text in
                        appState.insertAgentPlanStep(text: text, relativeToID: step.id, before: true)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            case .insertBelow:
                AgentPlanStepSimpleSheet(
                    title: "Insert step below \(index)",
                    initialText: "",
                    placeholder: L10n.PlanStepSheet.insertBelowPlaceholder,
                    confirmTitle: "Insert",
                    onConfirm: { text in
                        appState.insertAgentPlanStep(text: text, relativeToID: step.id, before: false)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            case .restart:
                AgentPlanStepSimpleSheet(
                    title: "Restart from step \(index)",
                    initialText: "",
                    placeholder: L10n.PlanStepSheet.restartPlaceholder,
                    confirmTitle: "Restart",
                    onConfirm: { note in
                        appState.restartAgentPlanFromStep(id: step.id, note: note)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            }
        }
    }

    private var glyph: String {
        switch step.status {
        case .pending: return "circle"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var glyphColor: Color {
        switch step.status {
        case .pending: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }

    private var textColor: Color {
        switch step.status {
        case .done, .skipped: return .secondary
        case .failed: return .red
        default: return .primary
        }
    }

    private func nextStatus(after current: AgentPlan.StepStatus) -> AgentPlan.StepStatus {
        switch current {
        case .pending: return .inProgress
        case .inProgress: return .done
        case .done: return .skipped
        case .skipped: return .pending
        case .failed: return .pending
        }
    }
}

/// Reused single-field sheet for all four plan-step actions
/// (edit / insert above / insert below / restart). One field, one
/// confirm button — keeps the modal weight low.
struct AgentPlanStepSimpleSheet: View {
    let title: String
    @State private var text: String
    let placeholder: String
    let confirmTitle: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    init(title: String, initialText: String, placeholder: String, confirmTitle: String,
         onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        _text = State(initialValue: initialText)
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm(text) }
            HStack {
                Spacer()
                Button(L10n.PlanStepSheet.cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onConfirm(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Goal planning card

struct AgentGoalPlanningCard: View {
    @EnvironmentObject var appState: AppState
    let state: AgentGoalPlanningState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: state.phase == .blocked ? "exclamationmark.triangle.fill" : "person.3.sequence.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.phase == .blocked ? Color.red : Color.accentColor)
                Text(L10n.GoalPlanning.header)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(phaseLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(state.phase == .blocked ? Color.red : Color.secondary)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.members) { member in
                    planningRow(
                        icon: memberIcon(member.status),
                        title: member.displayName,
                        status: memberStatusLabel(member.status),
                        detail: member.errorMessage
                    )
                }
                if state.arbitration.status != .pending || state.phase == .arbitrating {
                    planningRow(
                        icon: arbitrationIcon,
                        title: L10n.GoalPlanning.arbitration,
                        status: arbitrationStatusLabel,
                        detail: state.arbitration.errorMessage
                    )
                }
            }

            if state.phase == .blocked {
                Button(L10n.GoalPlanning.retry) {
                    appState.retryAgentGoalPlanning()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    state.phase == .blocked ? Color.red.opacity(0.4) : Color.accentColor.opacity(0.3),
                    lineWidth: 1
                )
        )
    }

    private func planningRow(
        icon: String,
        title: String,
        status: String,
        detail: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var phaseLabel: String {
        switch state.phase {
        case .collecting: return L10n.GoalPlanning.phaseCollecting
        case .arbitrating: return L10n.GoalPlanning.phaseArbitrating
        case .readyForProposal: return L10n.GoalPlanning.phaseSynthesizing
        case .awaitingApproval: return L10n.GoalPlanning.phaseAwaitingApproval
        case .executing: return L10n.GoalPlanning.phaseExecuting
        case .blocked: return L10n.GoalPlanning.phaseBlocked
        case .completed: return L10n.GoalPlanning.phaseCompleted
        }
    }

    private func memberStatusLabel(_ status: AgentGoalPlanningState.Member.Status) -> String {
        switch status {
        case .pending: return L10n.GoalPlanning.statusPending
        case .running: return L10n.GoalPlanning.statusRunning
        case .completed: return L10n.GoalPlanning.statusCompleted
        case .failed: return L10n.GoalPlanning.statusFailed
        case .interrupted: return L10n.GoalPlanning.statusInterrupted
        }
    }

    private func memberIcon(_ status: AgentGoalPlanningState.Member.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .interrupted: return "pause.circle.fill"
        }
    }

    private var arbitrationStatusLabel: String {
        switch state.arbitration.status {
        case .pending: return L10n.GoalPlanning.statusPending
        case .running: return L10n.GoalPlanning.statusRunning
        case .completed: return L10n.GoalPlanning.statusCompleted
        case .failed: return L10n.GoalPlanning.statusFailed
        case .interrupted: return L10n.GoalPlanning.statusInterrupted
        }
    }

    private var arbitrationIcon: String {
        switch state.arbitration.status {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        case .interrupted: return "pause.circle.fill"
        }
    }
}

// MARK: - Goal card

struct AgentGoalCard: View {
    @EnvironmentObject var appState: AppState
    let goal: AgentGoal
    @State private var showingEditor = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "target")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(L10n.GoalCard.header)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.GoalCard.editButtonHelp)
                }

                if !goal.statement.isEmpty {
                    Text(goal.statement)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !goal.checklist.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(goal.checklist) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    appState.toggleAgentGoalItem(item.id)
                                } label: {
                                    Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 12))
                                        .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                Text(item.text)
                                    .font(.system(size: 12))
                                    .strikethrough(item.done, color: .secondary)
                                    .foregroundStyle(item.done ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .sheet(isPresented: $showingEditor) {
            AgentGoalEditorSheet(
                initialStatement: goal.statement,
                initialItems: goal.checklist.map(\.text),
                onSave: { statement, items in
                    appState.setAgentGoal(statement: statement, items: items)
                    showingEditor = false
                },
                onCancel: { showingEditor = false }
            )
        }
    }
}

// MARK: - Goal editor sheet

struct AgentGoalEditorSheet: View {
    @State private var statement: String
    @State private var itemsText: String
    let onSave: (String, [String]) -> Void
    let onCancel: () -> Void

    init(initialStatement: String = "", initialItems: [String] = [], onSave: @escaping (String, [String]) -> Void, onCancel: @escaping () -> Void) {
        _statement = State(initialValue: initialStatement)
        _itemsText = State(initialValue: initialItems.joined(separator: "\n"))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.GoalEditorSheet.title)
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.GoalEditorSheet.statementLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.GoalEditorSheet.statementPlaceholder, text: $statement, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.GoalEditorSheet.checklistLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $itemsText)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button(L10n.GoalEditorSheet.cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.GoalEditorSheet.save) {
                    let items = itemsText.components(separatedBy: .newlines)
                    onSave(statement, items)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
