//
//  AgentPlanGoalCards.swift
//  WillDeep
//
//  Pinned-above-transcript cards for Plan and Goal modes, split out of
//  AgentModeView.swift in rc42.
//
//   - `AgentPlanCard`: neutral card listing every plan step
//     with a status glyph the user can cycle (pending → in-progress →
//     done → skipped → pending). Plans execute without a separate approval
//     mode; the card remains editable progress UI.
//     A low-frequency Replan action lives in the header menu and expands a
//     one-line note field only when requested.
//   - `AgentPlanStepRow`: per-step row. Context menu for edit / insert
//     above / insert below / restart-from-here / remove, all driven
//     through the shared `AgentPlanStepSimpleSheet` (single-field
//     modal with one confirm button).
//   - `AgentGoalCard`: accent-tinted card showing only the user-authored
//     objective. AI-owned acceptance criteria stay out of editing UI.
//   - `AgentGoalEditorSheet`: objective field + Save/Cancel; reused from
//     the mode picker's Goal entry and the Goal card's edit affordance.
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
    static func shouldDisplay(_ plan: AgentPlan) -> Bool {
        plan.status != .done
    }

    /// Whether the floating card should yield to the composer progress pill.
    ///
    /// Both surfaces render the same checklist from the same
    /// `agentCurrentPlan`, and their visibility conditions used to be
    /// independent: the card showed for any non-`done` plan while the pill
    /// showed for any plan during a live turn. Every execution therefore
    /// displayed the checklist twice. An earlier pass stopped the card from
    /// auto-*expanding* on `.approved`, which made the duplicate smaller
    /// without removing it.
    ///
    /// The pill is the live-progress surface — it sits with the composer, it
    /// tracks the current step, and it is where the user is already looking
    /// while work runs. So the card steps aside for exactly as long as the
    /// pill is up, and comes back when the turn ends so the plan stays
    /// reviewable and actionable (revise, mark complete) between turns.
    static func shouldDisplayFloatingCard(
        _ plan: AgentPlan,
        isComposerProgressVisible: Bool
    ) -> Bool {
        shouldDisplay(plan) && !isComposerProgressVisible
    }

    static func allowsRevision(_ plan: AgentPlan) -> Bool {
        plan.status != .done
    }

    /// Only a plan that is still waiting on a decision opens itself. An
    /// `.approved` plan is already executing — normal mode approves the
    /// captured plan and keeps working in the same turn — and the composer
    /// progress pill is the live progress surface for that phase. `.approved`
    /// also persists until the first `progress` block parses, which with
    /// most models is the end of the turn: opening on it used to show the
    /// same checklist twice (floating card + composer pill) for the entire
    /// execution, and re-opened it on every re-mount of the overlay.
    /// Whether a status change should fold an already-open card back up.
    ///
    /// `initiallyExpanded` only ever opens the card; without this the
    /// expansion was a one-way latch. A plan that was `.proposed` when the
    /// overlay mounted stayed fully expanded for the rest of the run, so the
    /// moment execution started the user had a full open checklist floating
    /// over the transcript *and* the composer pill tracking the same steps.
    static func shouldCollapse(onStatusChangeTo status: AgentPlan.Status) -> Bool {
        !initiallyExpanded(for: status)
    }

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

    static func showsStatus(_ status: AgentPlan.Status, isInterrupted: Bool) -> Bool {
        isInterrupted || status != .approved
    }
}

/// Produces the full-fidelity document shown in the Plan side panel. The
/// floating card intentionally keeps every step to one line; this Markdown
/// representation is the escape hatch where long step descriptions can wrap
/// naturally and remain selectable.
nonisolated enum AgentPlanMarkdownFormatter {
    static func markdown(from plan: AgentPlan) -> String {
        var sections = ["# \(L10n.PlanCard.header)"]

        let summary = plan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            sections.append(summary)
        }

        let steps = plan.steps.enumerated().map { index, step in
            "- \(statusGlyph(for: step.status)) **\(index + 1).** \(step.text)"
        }
        if !steps.isEmpty {
            sections.append(steps.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    private static func statusGlyph(for status: AgentPlan.StepStatus) -> String {
        switch status {
        case .pending: return "○"
        case .inProgress: return "◉"
        case .done: return "✓"
        case .skipped: return "–"
        case .failed: return "!"
        }
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
    /// Opens the complete, wrapping Markdown representation in the side panel.
    /// Nil for mounts that do not have a side-panel host.
    var onOpenDetails: (() -> Void)? = nil
    @State private var isRevisionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    planHeaderLabel
                }
                .buttonStyle(.plain)
                .help(isExpanded ? L10n.PlanCard.collapseHelp : L10n.PlanCard.expandHelp)
                .accessibilityLabel(L10n.PlanCard.header)
                .accessibilityValue(isExpanded ? L10n.PlanCard.expanded : L10n.PlanCard.collapsed)

                Menu {
                    if let onOpenDetails {
                        Button(L10n.PlanCard.openDetails) {
                            onOpenDetails()
                        }
                    }
                    if AgentPlanCardExpansionPolicy.allowsRevision(plan) {
                        Button(L10n.PlanRevision.replanButton) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isExpanded = true
                                isRevisionExpanded = true
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .agentQuietMenuChrome()
                .fixedSize()
                .help(L10n.PlanRevision.replanTooltip)
            }

            if isExpanded {
                // Where the previous phase left off: the host-written (and
                // possibly model-refined) three-line receipt. Shown only while
                // a later phase is active, so a first phase never wears a
                // receipt for nothing.
                if let receipt = lastPhaseReceipt {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.GoalRoadmap.lastReceipt)
                            .font(.system(size: 10, weight: .medium))
                            .textCase(.uppercase)
                            .foregroundStyle(.tertiary)
                        ForEach(receipt.lines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("plan-card-phase-receipt")
                }
                if !plan.summary.isEmpty {
                    planDetailsButton {
                        Text(plan.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        AgentPlanStepRow(
                            index: index + 1,
                            step: step,
                            interactive: plan.status != .rejected,
                            onOpenDetails: onOpenDetails,
                            onCycle: { next in
                                appState.setAgentPlanStepStatus(id: step.id, status: next)
                            }
                        )
                    }
                }

                if plan.status == .proposed
                    || plan.status == .approved
                    || plan.status == .executing {
                    Button(L10n.PlanCard.markCompleteButton) { appState.completeAgentPlan() }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if isRevisionExpanded {
                    AgentPlanRevisionRow(isExpanded: $isRevisionExpanded)
                }
            }
        }
        .padding(12)
        .background(planCardBackground)
        .overlay(planCardBorder)
        .shadow(color: floating ? Color.black.opacity(0.055) : .clear, radius: floating ? 7 : 0, x: 0, y: floating ? 2 : 0)
    }

    /// The floating card is intentionally narrow. Fit the complete header as
    /// one unit so SwiftUI cannot preserve the secondary phase label by
    /// compressing either the title or status pill into multiple lines.
    @ViewBuilder
    private var planHeaderLabel: some View {
        if let phaseText, showsStatus {
            ViewThatFits(in: .horizontal) {
                planHeaderContent(phaseText: phaseText, showsStatus: true)
                planHeaderContent(phaseText: nil, showsStatus: true)
            }
        } else if let phaseText {
            planHeaderContent(phaseText: phaseText, showsStatus: false)
        } else {
            planHeaderContent(phaseText: nil, showsStatus: showsStatus)
        }
    }

    private func planHeaderContent(
        phaseText: String?,
        showsStatus: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "list.number")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(L10n.PlanCard.header)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let phaseText {
                phaseLabel(phaseText)
            }
            if showsStatus {
                statusPill
            }
            Spacer(minLength: 0)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .contentShape(Rectangle())
    }

    /// The last closed phase's receipt, only once a later phase is active.
    private var lastPhaseReceipt: AgentPhaseReceipt? {
        guard let roadmap = appState.agentGoalRoadmap,
              roadmap.activePhaseIndex > 0 else { return nil }
        return roadmap.lastCompletedReceipt
    }

    private var phaseText: String? {
        guard let roadmap = appState.agentGoalRoadmap,
              !roadmap.phases.isEmpty else { return nil }
        return L10n.GoalRoadmap.phase(
            roadmap.activePhaseIndex + 1,
            roadmap.phases.count
        )
    }

    private var showsStatus: Bool {
        AgentPlanCardExpansionPolicy.showsStatus(
            plan.status,
            isInterrupted: plan.isInterrupted
        )
    }

    private func phaseLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var statusPill: some View {
        PlanStatusPill(status: plan.status, isInterrupted: plan.isInterrupted)
    }

    @ViewBuilder
    private func planDetailsButton<Label: View>(
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let onOpenDetails {
            Button(action: onOpenDetails, label: label)
                .buttonStyle(.plain)
                .help(L10n.PlanCard.openDetailsHelp)
                .cursor(.pointingHand)
        } else {
            label()
        }
    }

    @ViewBuilder
    private var planCardBackground: some View {
        if floating {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        }
    }

    @ViewBuilder
    private var planCardBorder: some View {
        if floating {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 1)
        }
    }
}

/// One-line revision editor revealed from the plan card's header menu.
struct AgentPlanRevisionRow: View {
    @EnvironmentObject var appState: AppState
    @Binding var isExpanded: Bool
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .opacity(0.4)
            HStack(spacing: 6) {
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
                    isExpanded = false
                    note = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.PlanRevision.cancelButtonHelp)
                Spacer(minLength: 0)
                if appState.isAgentResponding {
                    Text(L10n.PlanRevision.queueNotice)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async { noteFocused = true }
        }
    }

    private func send() {
        appState.requestPlanRevision(note: note)
        isExpanded = false
        note = ""
    }
}

/// A stable single-line label that truncates overflowing content and exposes
/// the complete value through the native tooltip. It deliberately avoids
/// geometry feedback, hover state, and perpetual animation so list rows remain
/// inert while SwiftUI measures or reuses them.
struct TruncatedTooltipText: View {
    let attributed: AttributedString
    var font: Font = .system(size: 12)
    var color: Color = .primary
    var strikethrough: Bool = false
    /// Full text surfaced as a native tooltip.
    var tooltip: String? = nil
    /// When set, caps the container at the text's natural width so the
    /// label hugs its content —— sidebar 会话行这类「标题后面紧跟徽章」
    /// 的布局需要;不传保持原来的贪婪整行行为(计划卡步骤)。
    var hugWidth: CGFloat? = nil

    var body: some View {
        Text(attributed)
            .font(font)
            .strikethrough(strikethrough, color: .secondary)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: hugWidth ?? .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(tooltip ?? "")
    }
}

/// One row of the plan card. The status glyph doubles as a button that
/// cycles pending → in_progress → done → skipped → pending, so the
/// user can override whatever the agent reported. While the plan is
/// still active, the glyph can be adjusted by the user.
struct AgentPlanStepRow: View {
    @EnvironmentObject var appState: AppState
    let index: Int
    let step: AgentPlan.Step
    let interactive: Bool
    var onOpenDetails: (() -> Void)? = nil
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
            if let onOpenDetails {
                Button(action: onOpenDetails) {
                    stepText
                }
                .buttonStyle(.plain)
                .help(L10n.PlanCard.openDetailsHelp)
                .cursor(.pointingHand)
            } else {
                stepText
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(L10n.PlanStep.menuEdit) { sheet = .edit }
            Button(L10n.PlanStep.menuInsertAbove) { sheet = .insertAbove }
            Button(L10n.PlanStep.menuInsertBelow) { sheet = .insertBelow }
            if interactive {
                Divider()
                Button(L10n.PlanStep.menuRestart) { sheet = .restart }
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

    private var stepText: some View {
        VStack(alignment: .leading, spacing: 2) {
            TruncatedTooltipText(
                attributed: MarkdownInline.attributedString(from: step.text),
                color: textColor,
                strikethrough: step.status == .done || step.status == .skipped,
                tooltip: step.text
            )
            // Live Worker line under a delegated step ("侦察兵 · 第 3/8 轮 · …").
            // Host-written from heartbeats; absent once the Worker finishes.
            if let detail = step.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("plan-step-worker-detail")
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

    /// Layered gray instead of a green/red pair: red-green is exactly the
    /// axis a red-green colorblind reader cannot separate, and "done" is the
    /// normal outcome of a plan — it does not need to shout. The glyph shape
    /// already carries the state (filled check / outline circle / dash), so
    /// gray only has to place each row in the hierarchy: settled work sits
    /// at `.secondary`, work not started yet recedes further, and only the
    /// two states that actually want your eye keep a hue.
    static func glyphColor(for status: AgentPlan.StepStatus) -> Color {
        switch status {
        case .pending: return AgentComposerChrome.iconMuted
        case .inProgress: return .orange
        case .done: return AgentComposerChrome.iconSecondary
        case .skipped: return AgentComposerChrome.iconMuted
        case .failed: return .red
        }
    }

    private var glyphColor: Color {
        Self.glyphColor(for: step.status)
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
                    if let runtime = appState.activeRuntime {
                        AgentGoalBudgetButton(ownerID: runtime.session.dispatchParentProjectID ?? runtime.id)
                    }
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
                onSave: { statement in
                    appState.setAgentGoalStatement(statement)
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
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(
        initialStatement: String = "",
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _statement = State(initialValue: initialStatement)
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

            HStack {
                Spacer()
                Button(L10n.GoalEditorSheet.cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.GoalEditorSheet.save) {
                    onSave(statement)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
