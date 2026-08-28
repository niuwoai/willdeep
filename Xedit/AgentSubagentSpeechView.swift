//
//  AgentSubagentSpeechView.swift
//  WillDeep
//
//  A Worker talking, inside the delegation card that spawned it.
//
//  Placement is deliberate. The obvious alternative — give the child its own
//  message role and let its rounds land in the transcript as separate
//  bubbles — reads well with one Worker and falls apart with three: their
//  rounds interleave by arrival time, and the transcript stops being a record
//  of who said what to whom. Nesting the speech under the delegation keeps
//  every Worker's narration attached to the task it was given, and keeps the
//  parent's own turn readable.
//
//  What makes it legible as *someone else* speaking:
//   - a left rail and a tint assigned per public trade, stable across runs,
//     so the six built-in trades never wear the same colour as each other;
//   - the trade name and model on the header row, not just "subagent";
//   - round numbers on each utterance, matching the inspector's numbering.
//

import SwiftUI

/// Deterministic per-trade colour. Same trade, same colour, every session —
/// a Worker whose colour changed between runs would be worse than no colour.
///
/// Keyed on the *public* trade, not the raw profile id. The catalog carries
/// seventeen internal trades but shows six: `publicID(for:)` folds `scout`,
/// `log_inspector` and `git_detective` all into `reader`. Colouring the raw
/// id would paint two runs that both say "阅读者" in different colours, which
/// is worse than not colouring them at all.
///
/// The six are assigned by hand rather than hashed. Hashing is the wrong tool
/// for a domain of six known values: FNV-1a over the public ids happens to
/// collide `reader`, `tester` and `ops_runner` onto the same slot — half the
/// roster sharing one colour. A table cannot collide.
nonisolated enum AgentSubagentTradePalette {
    /// Fallback ramp for custom trades outside the built-in six. Hand-picked
    /// rather than hue-rotated: these all stay legible against both chat
    /// backgrounds, which an evenly spaced hue wheel does not.
    private static let fallbackColors: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown,
    ]

    private static let publicColors: [String: Color] = [
        AgentSubagentProfileCatalog.readerID: .blue,
        AgentSubagentProfileCatalog.implementerID: .purple,
        AgentSubagentProfileCatalog.testerID: .green,
        AgentSubagentProfileCatalog.opsRunnerID: .orange,
        AgentSubagentProfileCatalog.judgeID: .pink,
        AgentSubagentProfileCatalog.deepID: .teal,
    ]

    static func color(forProfileID id: String) -> Color {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .accentColor }
        let publicID = AgentSubagentProfileCatalog.publicID(for: trimmed)
        if let assigned = publicColors[publicID] { return assigned }
        // A user-defined trade still deserves a stable colour. FNV-1a rather
        // than `hashValue`, which is seeded per process and would repaint the
        // Worker on every relaunch.
        var hash: UInt32 = 2_166_136_261
        for byte in publicID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return fallbackColors[Int(hash % UInt32(fallbackColors.count))]
    }
}

struct AgentSubagentSpeechView: View {
    @EnvironmentObject var appState: AppState

    let activity: AgentSubagentLiveActivity
    let runID: UUID?
    /// Drives the header spinner and the round line. A finished Worker keeps
    /// its transcript on screen — that is the point — but stops claiming to
    /// still be working.
    let isRunning: Bool

    @State private var isInterventionExpanded: Bool
    @State private var interventionDraft = ""
    @State private var interventionError: String?
    @FocusState private var interventionFieldIsFocused: Bool

    init(
        activity: AgentSubagentLiveActivity,
        runID: UUID?,
        isRunning: Bool,
        initiallyShowsIntervention: Bool = false
    ) {
        self.activity = activity
        self.runID = runID
        self.isRunning = isRunning
        _isInterventionExpanded = State(initialValue: initiallyShowsIntervention)
    }

    private enum TimelineItem: Identifiable {
        case utterance(AgentSubagentLiveActivity.Utterance)
        case intervention(AgentSubagentLiveActivity.InterventionReceipt)

        var id: String {
            switch self {
            case .utterance(let utterance): return "round-\(utterance.round)"
            case .intervention(let receipt): return "intervention-\(receipt.id.uuidString)"
            }
        }

        var sortRound: Int {
            switch self {
            case .utterance(let utterance): return utterance.round * 2
            case .intervention(let receipt):
                let round: Int
                switch receipt.deliveryState {
                case .queued:
                    round = receipt.requestedRound
                case .applied(let effectiveRound):
                    round = effectiveRound
                }
                return round * 2 - 1
            }
        }

        var submittedAt: Date {
            switch self {
            case .utterance:
                return .distantPast
            case .intervention(let receipt):
                return receipt.submittedAt
            }
        }
    }

    private var tint: Color {
        AgentSubagentTradePalette.color(forProfileID: activity.profileID)
    }

    private var timelineItems: [TimelineItem] {
        let utterances = activity.utterances.map(TimelineItem.utterance)
        let interventions = activity.interventionReceipts.map(TimelineItem.intervention)
        return (utterances + interventions).sorted {
            if $0.sortRound == $1.sortRound {
                return $0.submittedAt < $1.submittedAt
            }
            return $0.sortRound < $1.sortRound
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 6) {
                header
                ForEach(timelineItems) { item in
                    switch item {
                    case .utterance(let utterance):
                        utteranceRow(utterance)
                    case .intervention(let receipt):
                        interventionReceipt(receipt)
                    }
                }
                if isRunning, runID != nil {
                    interventionControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 2)
        .padding(.vertical, 6)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onChange(of: isRunning) { running in
            if !running {
                isInterventionExpanded = false
                interventionFieldIsFocused = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(activity.workerName)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 10,
                    weight: .semibold
                ))
                .foregroundStyle(tint)
                .lineLimit(1)
            if !activity.model.isEmpty {
                Text(activity.model)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 9,
                        weight: .regular
                    ))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isRunning {
                Text(activity.detailLine)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 9,
                        weight: .regular
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
                    .frame(width: 11, height: 11)
            }
            Spacer(minLength: 0)
        }
    }

    private var interventionControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .opacity(0.55)
            HStack(spacing: 7) {
                Text(L10n.AgentDelegation.interventionCurrentStep(activity.activityText))
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 10,
                        weight: .medium
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isInterventionExpanded.toggle()
                    }
                    interventionError = nil
                    interventionFieldIsFocused = isInterventionExpanded
                } label: {
                    Label(
                        isInterventionExpanded
                            ? L10n.AgentDelegation.interventionCollapse
                            : L10n.AgentDelegation.interventionAction,
                        systemImage: isInterventionExpanded
                            ? "chevron.up"
                            : "wand.and.sparkles"
                    )
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 10,
                        weight: .semibold
                    ))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("subagent-intervention-toggle")
            }

            if isInterventionExpanded {
                interventionComposer
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 3)
    }

    private var interventionComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TextField(
                    L10n.AgentDelegation.interventionPlaceholder,
                    text: $interventionDraft
                )
                .textFieldStyle(.roundedBorder)
                .focused($interventionFieldIsFocused)
                .onSubmit {
                    sendIntervention(mode: .nextRound)
                }
                .accessibilityIdentifier("subagent-intervention-input")

                Button {
                    sendIntervention(mode: .nextRound)
                } label: {
                    Label(
                        L10n.AgentDelegation.interventionNextRound,
                        systemImage: "paperplane"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(interventionDraftTrimmed.isEmpty)
                .accessibilityIdentifier("subagent-intervention-next-round")

                Button {
                    sendIntervention(mode: .interruptCurrentStep)
                } label: {
                    Label(
                        L10n.AgentDelegation.interventionInterruptAndSend,
                        systemImage: "stop.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(interventionDraftTrimmed.isEmpty)
                .accessibilityIdentifier("subagent-intervention-interrupt")
            }
            Text(L10n.AgentDelegation.interventionHelp)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 9,
                    weight: .regular
                ))
                .foregroundStyle(.tertiary)
            if let interventionError {
                Text(interventionError)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 9,
                        weight: .medium
                    ))
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        }
    }

    private var interventionDraftTrimmed: String {
        interventionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendIntervention(mode: AgentSubagentInterventionMode) {
        guard let runID else { return }
        do {
            try appState.submitSubagentIntervention(
                runID: runID,
                text: interventionDraft,
                mode: mode
            )
            interventionDraft = ""
            interventionError = nil
            withAnimation(.easeInOut(duration: 0.16)) {
                isInterventionExpanded = false
            }
            interventionFieldIsFocused = false
        } catch {
            interventionError = error.localizedDescription
        }
    }

    private func interventionReceipt(
        _ receipt: AgentSubagentLiveActivity.InterventionReceipt
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(L10n.AgentDelegation.interventionYou)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize,
                            visualMinimum: 10,
                            weight: .semibold
                        ))
                        .foregroundStyle(Color.accentColor)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(L10n.AgentDelegation.interventionJustNow)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize,
                            visualMinimum: 9,
                            weight: .regular
                        ))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    interventionDeliveryLabel(receipt)
                }
                Text(receipt.text)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 10,
                        weight: .regular
                    ))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The selected variant intentionally gives “你 · 刚刚” breathing
        // room so it reads as a human correction, not another Worker line.
        .padding(7)
        .background(Color.accentColor.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 16)
    }

    private func interventionDeliveryLabel(
        _ receipt: AgentSubagentLiveActivity.InterventionReceipt
    ) -> some View {
        let text: String
        let systemImage: String
        switch receipt.deliveryState {
        case .queued:
            text = receipt.mode == .interruptCurrentStep
                ? L10n.AgentDelegation.interventionInterrupting
                : L10n.AgentDelegation.interventionWaitingForRound(receipt.requestedRound)
            systemImage = "clock"
        case .applied(let effectiveRound):
            text = L10n.AgentDelegation.interventionAppliedAtRound(effectiveRound)
            systemImage = "checkmark"
        }
        return Label(text, systemImage: systemImage)
            .font(AgentDesign.chatSupportingFont(
                baseFontSize: appState.agentChatBaseFontSize,
                visualMinimum: 9,
                weight: .medium
            ))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func utteranceRow(_ utterance: AgentSubagentLiveActivity.Utterance) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !utterance.text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L10n.AgentDelegation.speechRoundMarker(utterance.round))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint.opacity(0.7))
                        .monospacedDigit()
                    // Plain text on purpose. Rendering a Worker's markdown
                    // live is the shape that previously melted the main
                    // thread in SwiftUI layout; the full report still gets
                    // rich treatment once the run returns.
                    Text(utterance.text)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize,
                            visualMinimum: 10,
                            weight: .regular
                        ))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !utterance.toolNames.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(utterance.toolNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(tint.opacity(0.12))
                            .foregroundStyle(tint.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, utterance.text.isEmpty ? 0 : 18)
            }
        }
    }
}
