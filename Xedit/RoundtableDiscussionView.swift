//
//  RoundtableDiscussionView.swift
//  WillDeep
//
//  专家圆桌讨论工作台：发言流、专家发言预告、引用输入与实时态势看板。
//

import SwiftUI
import AppKit

struct RoundtableDiscussionView: View {
    @EnvironmentObject var appState: AppState
    @Binding var route: RoundtableRoute
    let runtimeID: UUID
    let reportID: UUID
    /// 仅供测试/设计验收注入稳定的真实态数据；产品运行仍从 AppState 取报告。
    var previewReport: AgentRoundtableReport?
    @State private var hostInput = ""
    @State private var quoteDraft: RoundtableQuoteReference?

    private var report: AgentRoundtableReport? {
        previewReport ?? appState.workflowReport(id: reportID, runtimeID: runtimeID)?.roundtable
    }

    init(
        route: Binding<RoundtableRoute>,
        runtimeID: UUID,
        reportID: UUID,
        previewReport: AgentRoundtableReport? = nil
    ) {
        _route = route
        self.runtimeID = runtimeID
        self.reportID = reportID
        self.previewReport = previewReport
    }

    private var phase: AgentRoundtableReport.Phase? { report?.phase }
    private var isAwaiting: Bool { phase == .awaitingUser }
    private var isTerminal: Bool {
        phase == .completed || phase == .failed || phase == .cancelled
    }

    private var awaitingOptions: [String] {
        guard isAwaiting else { return [] }
        return report?.messages.last(where: { $0.pendingUserOptions?.isEmpty == false })?
            .pendingUserOptions ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            conversation
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 1)
            RoundtableLiveDashboard(report: report)
                .frame(width: 292)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: report?.activeExpert)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            if let activeExpert = report?.activeExpert {
                activeSpeakerBanner(activeExpert)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            separator
            transcript
            separator
            footer
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                route = .home
            } label: {
                Label(L10n.Roundtable.backAction, systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)

            Text(report?.displayTitle ?? "")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)

            if let experts = report?.experts, !experts.isEmpty {
                HStack(spacing: -7) {
                    ForEach(experts) { role in
                        RoundtableExpertAvatar(
                            role: role,
                            size: 25,
                            isActive: report?.activeExpert == role
                        )
                    }
                }
                .padding(.leading, 4)
            }

            Spacer(minLength: 0)
            if let round = report?.currentRound, round > 0 {
                Text(String(format: L10n.Roundtable.roundLabelFormat, round))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(report?.messages ?? [], id: \.id) { message in
                        RoundtableMessageBubble(message: message) { excerpt, isSelection in
                            prepareQuote(
                                message: message,
                                excerpt: excerpt,
                                isSelection: isSelection
                            )
                        }
                    }
                    if let role = report?.activeExpert,
                       let draft = report?.activeExpertDraft,
                       !draft.isEmpty {
                        RoundtableStreamingMessageBubble(
                            role: role,
                            draft: draft,
                            isComplete: report?.activeExpertDraftIsComplete == true
                        )
                            .id("roundtable-streaming-draft")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("roundtable-bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: report?.messages.count ?? 0) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("roundtable-bottom", anchor: .bottom)
                }
            }
            .onChange(of: report?.activeExpertDraft?.count ?? 0) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("roundtable-bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .completed:
                Button {
                    route = .document(runtimeID: runtimeID, reportID: reportID)
                } label: {
                    Label(L10n.Roundtable.viewDocumentAction, systemImage: "doc.text")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            case .failed:
                Label(L10n.Roundtable.failedNote, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            case .cancelled:
                Label(L10n.Roundtable.cancelledNote, systemImage: "stop.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            default:
                if isAwaiting, report?.converged == true {
                    // 收敛后停下,把「继续下一轮 / 结束并生成文档」的选择权交给主持人。
                    // 此态刻意不显示答复输入框:输入会触发 submitRoundtableUserReply→
                    // 续跑,而 converged=true 会直接 synthesize,等于误收尾。
                    convergedControls
                } else {
                    if isAwaiting {
                        awaitingBanner
                    }
                    inputArea
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 收敛暂停态的主持人控制区:两个按钮把续轮/收尾的决定权交给用户。
    private var convergedControls: some View {
        let atRoundCap = (report?.currentRound ?? 0) >= AgentRoundtableReport.maxRounds
        return VStack(alignment: .leading, spacing: 9) {
            Label(
                String(
                    localized: "roundtable.converged.banner",
                    defaultValue: "本轮讨论已收敛。你可以继续深入下一轮，或结束并生成会议文档。"
                ),
                systemImage: "checkmark.seal.fill"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.green)
            .fixedSize(horizontal: false, vertical: true)

            if atRoundCap {
                Text(
                    String(
                        localized: "roundtable.converged.roundCapReached",
                        defaultValue: "已达讨论轮数上限，请结束并生成文档。"
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                Button {
                    appState.continueRoundtableNextRound(runtimeID: runtimeID, reportID: reportID)
                } label: {
                    Label(
                        String(localized: "roundtable.converged.continueAction", defaultValue: "继续下一轮"),
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(atRoundCap)

                Button {
                    appState.finalizeRoundtable(runtimeID: runtimeID, reportID: reportID)
                } label: {
                    Label(
                        String(localized: "roundtable.converged.finalizeAction", defaultValue: "结束并生成文档"),
                        systemImage: "doc.text"
                    )
                    .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.07)))
    }

    private var awaitingBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.Roundtable.awaitingBanner, systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

            if !awaitingOptions.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(awaitingOptions.enumerated()), id: \.offset) { _, option in
                        Button {
                            send(option)
                        } label: {
                            Text(option)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.orange.opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.32), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.07)))
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let quoteDraft {
                quoteDraftCard(quoteDraft)
            }

            HStack(alignment: .bottom, spacing: 8) {
                RoundtableComposerTextView(
                    text: $hostInput,
                    placeholder: isAwaiting
                        ? L10n.Roundtable.answerPlaceholder
                        : L10n.Roundtable.hostPlaceholder,
                    onSubmit: { send(hostInput) }
                )
                .frame(height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )

                VStack(alignment: .trailing, spacing: 5) {
                    Text(L10n.Roundtable.submitShortcutHint)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Button {
                        send(hostInput)
                    } label: {
                        Label(L10n.Roundtable.sendAction, systemImage: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func quoteDraftCard(_ quote: RoundtableQuoteReference) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L10n.Roundtable.quotingFormat, quote.speakerName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(quote.excerpt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                quoteDraft = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.Roundtable.cancelQuote)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.08)))
    }

    private func activeSpeakerBanner(_ role: AgentRoundtableExpertRole) -> some View {
        let isSpeaking = !(report?.activeExpertDraft?.isEmpty ?? true)
        let isAnalyzing = report?.activeExpertDraftIsComplete == true
        return HStack(spacing: 10) {
            RoundtableExpertAvatar(role: role, size: 32, isActive: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isAnalyzing
                        ? L10n.RoundtableSetup.expertFinishedSpeaking(role.personalName)
                        : isSpeaking
                        ? L10n.RoundtableSetup.expertSpeaking(role.personalName)
                        : String(format: L10n.Roundtable.expertWillSpeakFormat, role.personalName)
                )
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RoundtableVisuals.accent(for: role))
                Text(
                    isAnalyzing
                        ? L10n.RoundtableSetup.analyzingStanceDetail
                        : isSpeaking
                        ? L10n.RoundtableSetup.expertSpeakingDetail
                        : L10n.Roundtable.expertThinkingDetail
                )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .tint(RoundtableVisuals.accent(for: role))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(RoundtableVisuals.accent(for: role).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(RoundtableVisuals.accent(for: role).opacity(0.28), lineWidth: 1)
        )
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 1)
    }

    private func send(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTerminal else { return }
        appState.submitRoundtableUserReply(
            runtimeID: runtimeID,
            reportID: reportID,
            content: trimmed,
            quote: quoteDraft
        )
        hostInput = ""
        quoteDraft = nil
    }

    private func prepareQuote(
        message: RoundtableMessage,
        excerpt: String,
        isSelection: Bool
    ) {
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        quoteDraft = RoundtableQuoteReference(
            messageID: message.id,
            speakerName: message.speakerName,
            excerpt: String(trimmed.prefix(1_200)),
            isSelection: isSelection
        )
    }
}

private struct RoundtableStreamingMessageBubble: View {
    let role: AgentRoundtableExpertRole
    let draft: String
    let isComplete: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundtableExpertAvatar(role: role, size: 34, isActive: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(role.personalName)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(role.roleTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Label(
                        isComplete
                            ? L10n.RoundtableSetup.analyzingStance
                            : L10n.RoundtableSetup.liveSpeaking,
                        systemImage: isComplete ? "sparkles" : "waveform"
                    )
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(RoundtableVisuals.accent(for: role))
                }

                // Render the live draft through the SAME width-authoritative
                // TextKit view the finalized bubble uses: it declares its size
                // as the proposed width via `sizeThatFits`, so it always claims
                // the bubble column instead of collapsing. A bare SwiftUI `Text`
                // here had no minimum-width floor, so during the first layout
                // pass — before the row's width resolved — the adjacent greedy
                // `Spacer` squeezed CJK content (which line-breaks between any
                // two glyphs) into a one-glyph-per-line column (逐字竖排) until
                // the message finalized. Reusing the finalized renderer also
                // makes the streaming→final transition seamless. Selection is a
                // no-op while the draft is still mutating every frame.
                RoundtableSelectableMessageText(
                    text: draft + (isComplete ? "" : " ▍"),
                    onSelectionChange: { _ in }
                )
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: 660, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(RoundtableVisuals.accent(for: role).opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(
                        RoundtableVisuals.accent(for: role).opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                    )
            )
            Spacer(minLength: 64)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(
            "\(role.personalName)，\(isComplete ? L10n.RoundtableSetup.analyzingStance : L10n.RoundtableSetup.liveSpeaking)"
        )
    }
}

private struct RoundtableMessageBubble: View {
    let message: RoundtableMessage
    let onQuote: (_ excerpt: String, _ isSelection: Bool) -> Void
    @State private var selectedExcerpt: String?
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.speaker == .user {
                Spacer(minLength: 64)
            } else {
                avatar
            }

            VStack(alignment: message.speaker == .user ? .trailing : .leading, spacing: 6) {
                speakerHeader
                bubbleContent
                if canQuote, isHovering, selectedExcerpt == nil {
                    Button {
                        onQuote(message.content, false)
                    } label: {
                        Label(L10n.Roundtable.quoteMessage, systemImage: "quote.opening")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }

            if message.speaker == .user {
                avatar
            } else {
                Spacer(minLength: 64)
            }
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovering = $0 }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quote = message.quote {
                quoteCard(quote)
            }
            if let osr = message.osr {
                HStack(spacing: 6) {
                    stancePill(osr.stance)
                    Text(osr.topic)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            RoundtableSelectableMessageText(
                text: message.content,
                onSelectionChange: { selectedExcerpt = $0 }
            )

            if let suggestion = message.osr?.suggestion,
               !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(avatarColor)
                    Text(suggestion)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if canQuote, let selectedExcerpt {
                Button {
                    onQuote(selectedExcerpt, true)
                } label: {
                    Label(L10n.Roundtable.quoteSelection, systemImage: "quote.opening")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: 660, alignment: .leading)
        .background(bubbleBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(borderColor, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if message.osr != nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(avatarColor)
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let role = message.role, message.speaker == .expert {
            RoundtableExpertAvatar(role: role, size: 38)
        } else if message.speaker == .user {
            // The human moderator ("你（主持人）") reuses the signed-in some.im
            // account avatar — the same one the sidebar footer shows — and
            // falls back to the app icon when the user has not set a some.im
            // avatar (or while the remote image is still loading / fails).
            moderatorAvatar
        } else {
            ZStack {
                Circle().fill(avatarColor.opacity(0.14))
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(avatarColor)
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(avatarColor.opacity(0.28), lineWidth: 1))
        }
    }

    private var moderatorAvatar: some View {
        Group {
            if let account = SomeIMIntegrationStore.loadAccount(),
               let url = moderatorAvatarURL(account.avatarURL) {
                CachedAvatarImage(url: url) { appLogoAvatar }
            } else {
                appLogoAvatar
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay(Circle().stroke(avatarColor.opacity(0.28), lineWidth: 1))
    }

    /// App-icon fallback avatar for the human moderator — used when the
    /// signed-in some.im account has no avatar set, or while/if the remote
    /// avatar fails to load.
    private var appLogoAvatar: some View {
        Image(nsImage: NSApp.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage())
            .resizable()
            .scaledToFill()
    }

    private func moderatorAvatarURL(_ value: String?) -> URL? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    private var speakerHeader: some View {
        HStack(spacing: 6) {
            if let role = message.role {
                Text(role.personalName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RoundtableVisuals.accent(for: role))
                Text(role.roleTitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                Text(message.speakerName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if canQuote {
                Image(systemName: "text.cursor")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(L10n.Roundtable.selectionQuoteHint)
            }
        }
    }

    private var avatarColor: Color {
        switch message.speaker {
        case .chair: return .accentColor
        case .user: return .secondary
        case .expert: return message.role.map { RoundtableVisuals.accent(for: $0) } ?? .purple
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(
                message.isError == true
                    ? Color.red.opacity(0.08)
                    : message.osr == nil
                        ? Color(nsColor: .textBackgroundColor)
                        : avatarColor.opacity(0.06)
            )
    }

    private var borderColor: Color {
        if message.isError == true { return Color.red.opacity(0.3) }
        // Expert cards carry the SPEAKER's identity color (matching the
        // color-coded 专家席), not the stance color — otherwise a room where
        // everyone opposes renders every card red. Stance is conveyed by the
        // thumbs-up/down pill instead.
        if message.osr != nil { return avatarColor.opacity(0.30) }
        return Color.secondary.opacity(0.15)
    }

    private var canQuote: Bool {
        message.speaker == .expert && message.isError != true
    }

    private func stancePill(_ stance: RoundtableOSR.Stance) -> some View {
        let color = RoundtableVisuals.color(for: stance)
        return Label(stance.displayName, systemImage: RoundtableVisuals.symbol(for: stance))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }

    private func quoteCard(_ quote: RoundtableQuoteReference) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.speakerName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(quote.excerpt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

private struct RoundtableLiveDashboard: View {
    let report: AgentRoundtableReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(L10n.Roundtable.dashboardTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                }
                progressCard
                spectrumCard
                expertsCard
                if !signals.isEmpty {
                    signalsCard
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseTitle)
                        .font(.system(size: 12, weight: .semibold))
                    Text(phaseDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(progressLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: speakingProgress)
                .tint(statusColor)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(statusColor.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(statusColor.opacity(0.22), lineWidth: 1))
    }

    private var spectrumCard: some View {
        dashboardCard(title: L10n.Roundtable.stanceSpectrum, symbol: "circle.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 10) {
                if latestStances.isEmpty {
                    Text(L10n.Roundtable.waitingForStances)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: 3) {
                            ForEach(stanceGroups, id: \.stance.rawValue) { group in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(RoundtableVisuals.color(for: group.stance))
                                    .frame(width: max(
                                        8,
                                        geometry.size.width
                                            * CGFloat(group.count)
                                            / CGFloat(latestStances.count)
                                    ))
                            }
                        }
                    }
                    .frame(height: 8)

                    HStack(spacing: 10) {
                        ForEach(stanceGroups, id: \.stance.rawValue) { group in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(RoundtableVisuals.color(for: group.stance))
                                    .frame(width: 6, height: 6)
                                Text("\(group.stance.displayName) \(group.count)")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                        }
                    }

                    // 立场是各专家针对「自己那一小节议题」的态度,不是对同一命题的
                    // 统一投票;所以下面专家席逐条标注了「谁·支持什么」。
                    Text(
                        String(
                            localized: "roundtable.stance.perExpertNote",
                            defaultValue: "按各专家自述立场统计，具体「谁支持什么」见下方专家席"
                        )
                    )
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var expertsCard: some View {
        dashboardCard(title: L10n.Roundtable.expertPanel, symbol: "person.3.fill") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(report?.experts ?? []) { role in
                    let entry = latestByRole[role]
                    HStack(spacing: 9) {
                        RoundtableExpertAvatar(
                            role: role,
                            size: 31,
                            isActive: report?.activeExpert == role
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(role.personalName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                            Text(role.roleTitle)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            // 「谁支持什么」:立场徽标 + 该专家自述的议题,让右侧「支持N」
                            // 不再是无锚点的抽象计数。仅在该专家已发言且非当前发言态时显示。
                            if report?.activeExpert != role, let osr = entry {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(RoundtableVisuals.color(for: osr.stance))
                                        .frame(width: 5, height: 5)
                                    Text(osr.stance.displayName)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(RoundtableVisuals.color(for: osr.stance))
                                    if !osr.topic.isEmpty {
                                        Text("· \(osr.topic)")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        if report?.activeExpert == role {
                            Text(
                                report?.activeExpertDraft?.isEmpty == false
                                    ? (
                                        report?.activeExpertDraftIsComplete == true
                                            ? L10n.RoundtableSetup.analyzingStance
                                            : L10n.RoundtableSetup.liveSpeaking
                                    )
                                    : L10n.Roundtable.thinking
                            )
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(RoundtableVisuals.accent(for: role))
                        } else if let stance = entry?.stance {
                            Image(systemName: RoundtableVisuals.symbol(for: stance))
                                .foregroundStyle(RoundtableVisuals.color(for: stance))
                                .help(stance.displayName)
                        } else {
                            Text(L10n.Roundtable.waiting)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var signalsCard: some View {
        dashboardCard(title: L10n.Roundtable.liveSignals, symbol: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(signals) { signal in
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(signal.color)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(signal.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                            Text(signal.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    private func dashboardCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.13), lineWidth: 1))
    }

    private struct StanceEntry {
        let role: AgentRoundtableExpertRole
        let stance: RoundtableOSR.Stance
    }

    private struct StanceGroup {
        let stance: RoundtableOSR.Stance
        let count: Int
    }

    private struct Signal: Identifiable {
        let id: UUID
        let title: String
        let detail: String
        let color: Color
    }

    private var latestByRole: [AgentRoundtableExpertRole: RoundtableOSR] {
        guard let messages = report?.messages else { return [:] }
        var latest: [AgentRoundtableExpertRole: RoundtableOSR] = [:]
        for message in messages {
            if message.speaker == .expert, let role = message.role, let osr = message.osr {
                latest[role] = osr
            }
        }
        return latest
    }

    private var latestStances: [StanceEntry] {
        (report?.experts ?? []).compactMap { role in
            latestByRole[role].map { StanceEntry(role: role, stance: $0.stance) }
        }
    }

    private var stanceGroups: [StanceGroup] {
        let order: [RoundtableOSR.Stance] = [.oppose, .support, .neutral, .undecided]
        return order.compactMap { stance in
            let count = latestStances.filter { $0.stance == stance }.count
            return count > 0 ? StanceGroup(stance: stance, count: count) : nil
        }
    }

    private var signals: [Signal] {
        guard let messages = report?.messages else { return [] }
        return messages.reversed().compactMap { message -> Signal? in
            guard let osr = message.osr else { return nil }
            let detail = osr.suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? osr.arguments.first ?? message.content
                : osr.suggestion
            return Signal(
                id: message.id,
                title: osr.topic,
                detail: detail,
                color: RoundtableVisuals.color(for: osr.stance)
            )
        }.prefix(3).map { $0 }
    }

    private var statusColor: Color {
        switch report?.phase {
        case .completed: return .green
        case .failed, .cancelled: return .red
        case .awaitingUser: return .orange
        default:
            return report?.activeExpert.map { RoundtableVisuals.accent(for: $0) } ?? .accentColor
        }
    }

    private var phaseTitle: String {
        switch report?.phase {
        case .clarifying: return L10n.RoundtableSetup.preparationTitle
        case .selectingExperts: return L10n.RoundtableSetup.selectionTitle
        case .recommending: return L10n.Roundtable.phaseRecommending
        case .opening: return L10n.Roundtable.phaseOpening
        case .discussing: return L10n.Roundtable.phaseDiscussing
        case .awaitingUser: return L10n.Roundtable.phaseAwaiting
        case .synthesizing: return L10n.Roundtable.phaseSynthesizing
        case .completed: return L10n.Roundtable.statusConverged
        case .failed: return L10n.Roundtable.statusFailed
        case .cancelled: return L10n.Roundtable.cancelledNote
        case nil: return L10n.Roundtable.statusRunning
        }
    }

    private var phaseDetail: String {
        if let role = report?.activeExpert {
            return String(format: L10n.Roundtable.expertWillSpeakFormat, role.personalName)
        }
        return String(format: L10n.Roundtable.roundLabelFormat, max(1, report?.currentRound ?? 1))
    }

    private var speakingProgress: Double {
        guard let report, !report.experts.isEmpty else { return 0 }
        let spoken = Set(report.messages.compactMap { message -> AgentRoundtableExpertRole? in
            guard message.round == report.currentRound, message.speaker == .expert else { return nil }
            return message.role
        }).count
        return min(1, Double(spoken) / Double(report.experts.count))
    }

    private var progressLabel: String {
        let total = report?.experts.count ?? 0
        let value = Int((speakingProgress * Double(total)).rounded())
        return String(format: L10n.Roundtable.progressFormat, value, total)
    }
}
