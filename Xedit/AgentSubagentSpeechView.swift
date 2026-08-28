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
//     so no two built-in trades wear the same colour as each other;
//   - the trade name and model on the header row, not just "subagent";
//   - round numbers on each utterance, matching the inspector's numbering.
//

import SwiftUI

/// Deterministic per-trade colour. Same trade, same colour, every session —
/// a Worker whose colour changed between runs would be worse than no colour.
///
/// Keyed on the *public* trade, not the raw profile id. The catalog carries
/// eighteen internal trades but shows seven: `publicID(for:)` folds `scout`,
/// `log_inspector` and `git_detective` all into `reader`. Colouring the raw
/// id would paint two runs that both say "阅读者" in different colours, which
/// is worse than not colouring them at all.
///
/// They are assigned by hand rather than hashed. Hashing is the wrong tool
/// for a domain of a handful of known values: FNV-1a over the public ids happens to
/// collide `reader`, `tester` and `ops_runner` onto the same slot — half the
/// roster sharing one colour. A table cannot collide.
nonisolated enum AgentSubagentTradePalette {
    /// Fallback ramp for custom trades outside the built-in roster. Hand-picked
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
        AgentSubagentProfileCatalog.generalistID: .indigo,
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

    /// Every row starts with the same round gutter so the card keeps one
    /// left edge. Previously a round with text indented its chips by 18pt
    /// and a silent round did not, which left the column visibly ragged.
    private static let roundGutterWidth: CGFloat = 42

    private var tint: Color {
        AgentSubagentTradePalette.color(forProfileID: activity.profileID)
    }

    private var speechRows: [AgentSubagentSpeechRow] {
        AgentSubagentSpeechTimeline.rows(for: activity)
    }

    /// 发言正文的字号。正文走 AppKit 文本视图，拿的是点数而不是 `Font`，
    /// 但口径必须和卡片里其余 supporting 文本完全一致。
    private var speechFontSize: CGFloat {
        AgentDesign.chatSupportingFontSize(
            baseFontSize: appState.agentChatBaseFontSize,
            visualMinimum: 10
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 6) {
                header
                ForEach(speechRows) { row in
                    speechRow(row)
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
            // No status text here. The header already ends in the same
            // `activityText` this row used to repeat, five lines above it —
            // one card saying “正在思考下一步” twice reads like a stutter.
            HStack(spacing: 7) {
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
                        // Not a wand. A wand means “let the model generate
                        // it for me”, which is the opposite of what this
                        // button does — the user is the one talking here.
                        systemImage: isInterventionExpanded
                            ? "chevron.up"
                            : "hand.raised"
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
            HStack(alignment: .bottom, spacing: 7) {
                interventionField

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
                // Return now inserts a newline — the field is two lines and
                // has to be typeable as two lines — so the keyboard path to
                // sending moves to ⌘↩ rather than disappearing.
                .keyboardShortcut(.return, modifiers: .command)
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

    /// Two lines, scrolling past that.
    ///
    /// A correction is rarely one clause — "别改编码，先确认脚本支不支持
    /// 直接传 UTF-8" already wraps at this width — and a single-line field
    /// hides everything but the tail while you type it. `TextEditor` keeps
    /// the box a fixed two lines high and scrolls the overflow instead of
    /// growing the card, which would push the Worker's own transcript
    /// around every time someone typed.
    private var interventionField: some View {
        let lineHeight = AgentDesign.chatSupportingFontSize(
            baseFontSize: appState.agentChatBaseFontSize,
            visualMinimum: 10
        ) * 1.45
        return ZStack(alignment: .topLeading) {
            TextEditor(text: $interventionDraft)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 10
                ))
                .scrollContentBackground(.hidden)
                .focused($interventionFieldIsFocused)
                .frame(height: lineHeight * 2)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .accessibilityIdentifier("subagent-intervention-input")

            // TextEditor has no placeholder of its own, and an empty box
            // with two buttons beside it does not say what to type.
            if interventionDraft.isEmpty {
                Text(L10n.AgentDelegation.interventionPlaceholder)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 10
                    ))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
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
    private func speechRow(_ row: AgentSubagentSpeechRow) -> some View {
        switch row {
        case .speech(let round, let text, let tools):
            gutteredRow(marker: L10n.AgentDelegation.speechRoundMarker(round)) {
                VStack(alignment: .leading, spacing: 3) {
                    // Markdown, baked into a single attributed string and
                    // handed to one read-only TextKit view. Two things had to
                    // survive being merged together here:
                    //
                    //  - the rendering (Workers report build tables, and raw
                    //    `|---|---|` rows were the least readable thing on
                    //    the card), and
                    //  - the selection: a Worker's words get the same
                    //    「添加到任务 / 收藏 / …」bubble the settled transcript
                    //    gets, which SwiftUI's `.textSelection` cannot give —
                    //    it hands back no way to read what was selected.
                    //
                    // One attributed string, one view: still not the
                    // per-block SwiftUI view tree that once pinned the main
                    // thread in layout.
                    AgentSubagentSpeechSelectableText(
                        text: text,
                        fontSize: speechFontSize,
                        onAddSelectionToTask: appState.addAgentChatSelectionToTask,
                        onSelectionPluginAction: { selected, pluginID, commandID, completion in
                            appState.runAgentChatSelectionPluginAction(
                                text: selected,
                                pluginID: pluginID,
                                commandID: commandID,
                                completion: completion
                            )
                        }
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !tools.isEmpty {
                        toolChipFlow(tools)
                    }
                }
            }
        case .tools(let firstRound, let lastRound, let mentions):
            gutteredRow(
                marker: firstRound == lastRound
                    ? L10n.AgentDelegation.speechRoundMarker(firstRound)
                    : L10n.AgentDelegation.speechRoundSpanMarker(firstRound, lastRound)
            ) {
                toolChipFlow(mentions)
            }
        case .intervention(let receipt):
            interventionReceipt(receipt)
        }
    }

    private func gutteredRow<Content: View>(
        marker: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: Self.roundGutterWidth, alignment: .leading)
                // Nudged onto the first line's optical baseline: `.top`
                // alignment is what keeps the gutter fixed when the content
                // wraps, and a 9pt marker sits high against 10pt body text.
                .padding(.top, 1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolChipFlow(_ mentions: [AgentSubagentToolMention]) -> some View {
        AgentSubagentChipFlowLayout(spacing: 4, lineSpacing: 3) {
            ForEach(Array(mentions.enumerated()), id: \.offset) { _, mention in
                toolChip(mention)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Verb plus object. The chip palette is deliberately neutral: the trade
    /// tint already carries identity on the rail and the Worker's name, and
    /// a third tinted surface at 12% opacity blurred into the 5.5% card
    /// behind it — a block of colour where a list of facts belongs.
    private func toolChip(_ mention: AgentSubagentToolMention) -> some View {
        HStack(spacing: 3) {
            Text(mention.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            if let object = mention.object, !object.isEmpty {
                Text(object)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Wraps tool chips at the width available instead of at whatever round
/// boundary the Worker happened to produce.
///
/// SwiftUI has no stock flow container, and the stack this replaces put one
/// row per utterance — so three consecutive rounds that each called a single
/// tool drew three lines holding one chip apiece, with the break points
/// decided by the data rather than by how much there was to read.
struct AgentSubagentChipFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let limit = proposal.width ?? .infinity
        var widest: CGFloat = 0
        var cursor: CGFloat = 0
        var lineHeight: CGFloat = 0
        var total: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor > 0, cursor + spacing + size.width > limit {
                widest = max(widest, cursor)
                total += lineHeight + lineSpacing
                cursor = 0
                lineHeight = 0
            }
            cursor += (cursor > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, cursor)
        total += lineHeight
        return CGSize(width: min(widest, limit), height: total)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            if x > bounds.minX { x += spacing }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
