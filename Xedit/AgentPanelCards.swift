//
//  AgentPanelCards.swift
//  WillDeep
//
//  Leaf cards used by the compact right-side Agent panel. Split from
//  AgentPanelView.swift so the panel shell can focus on layout and state.
//

import AppKit
import SwiftUI

struct AgentPatchProposalCard: View {
    @EnvironmentObject var appState: AppState
    let proposal: AgentPatchProposal
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? L10n.AgentPatch.hideDiff : L10n.AgentPatch.showDiff)
            }

            if isExpanded {
                // 之前只给 `.horizontal`,纵向被 maxHeight 卡死又滚不动,
                // 长 diff(几十行的剧本)直接被裁、看不全。改成双向滚动:
                // `fixedSize` 让 Text 报告完整尺寸(行不换、保 diff 对齐),
                // 横向看长行、纵向看多行;视口抬到 320 给足上下文,再长也
                // 在框内滚动查看全部(底层 diff 从不截断,apply 用的是整份)。
                ScrollView([.horizontal, .vertical]) {
                    Text(proposal.diff)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(8)
                }
                .frame(maxHeight: 320)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // rc16:Reject 放最左,Apply 放右,Spacer 留在右侧把它们顶到左边
            // 簇集 —— 仍然按「负 → 正」从左到右,误触概率低于「正 → 负」。
            HStack {
                Button {
                    appState.rejectAgentPatchProposal(id: proposal.id)
                } label: {
                    Label(L10n.AgentPatch.reject, systemImage: "xmark.circle")
                }
                .disabled(proposal.status != .pending)

                Button {
                    appState.applyAgentPatchProposal(id: proposal.id)
                } label: {
                    Label(L10n.AgentPatch.apply, systemImage: "checkmark.circle")
                }
                .disabled(proposal.status != .pending)

                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var iconName: String {
        switch proposal.status {
        case .pending:
            return "doc.text.magnifyingglass"
        case .applied:
            return "checkmark.circle.fill"
        case .rejected:
            return "xmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch proposal.status {
        case .pending:
            return .secondary
        case .applied:
            return .green
        case .rejected:
            return .secondary
        case .failed:
            return .orange
        }
    }

    private var statusText: String {
        proposal.statusMessage ?? proposal.status.rawValue.capitalized
    }
}

/// Collapsed card that bundles several patch proposals produced in the same
/// turn (same `messageID`). One header + one set of Apply All / Reject All
/// buttons replaces N stacked cards, so a turn that emits many patches
/// ("第1集剧本", "第2集剧本", …) no longer floods the transcript. Expanding
/// reveals the individual `AgentPatchProposalCard`s, each still operable on
/// its own.
struct AgentPatchProposalGroup: View {
    @EnvironmentObject var appState: AppState
    let proposals: [AgentPatchProposal]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.AgentPatch.groupTitle(proposals.count))
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? L10n.AgentPatch.hideAll : L10n.AgentPatch.showAll)
            }

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(proposals) { proposal in
                        AgentPatchProposalCard(proposal: proposal)
                    }
                }
            }

            if pendingCount > 0 {
                HStack {
                    Button {
                        appState.rejectAgentPatchProposals(forMessageID: messageID)
                    } label: {
                        Label(L10n.AgentPatch.rejectAll, systemImage: "xmark.circle")
                    }
                    Button {
                        appState.applyAgentPatchProposals(forMessageID: messageID)
                    } label: {
                        Label(L10n.AgentPatch.applyAll, systemImage: "checkmark.circle")
                    }
                    Spacer(minLength: 0)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var messageID: AgentMessage.ID {
        proposals.first?.messageID ?? UUID()
    }

    private var pendingCount: Int { count(of: .pending) }

    private func count(of status: AgentPatchStatus) -> Int {
        proposals.filter { $0.status == status }.count
    }

    /// Per-status tally joined with "·", skipping zero buckets — e.g.
    /// "2 pending · 1 applied". Keeps the collapsed header informative
    /// without opening it.
    private var statusSummary: String {
        var parts: [String] = []
        let pending = count(of: .pending)
        let applied = count(of: .applied)
        let rejected = count(of: .rejected)
        let failed = count(of: .failed)
        if pending > 0 { parts.append(L10n.AgentPatch.countPending(pending)) }
        if applied > 0 { parts.append(L10n.AgentPatch.countApplied(applied)) }
        if rejected > 0 { parts.append(L10n.AgentPatch.countRejected(rejected)) }
        if failed > 0 { parts.append(L10n.AgentPatch.countFailed(failed)) }
        return parts.joined(separator: " · ")
    }
}

/// Renders the runtime's patch proposals, auto-collapsing any turn that
/// produced two or more into a single `AgentPatchProposalGroup`. A turn with
/// just one proposal stays a plain `AgentPatchProposalCard`. Grouping key is
/// `messageID`; original ordering is preserved by first appearance.
struct AgentPatchProposalList: View {
    @EnvironmentObject var appState: AppState
    let proposals: [AgentPatchProposal]
    /// Transcript constrains card width; the compact side panel does not.
    var maxContentWidth: CGFloat? = nil

    var body: some View {
        // When pending patches are spread across 2+ independent cards
        // (one-patch-per-turn over several turns), a single card's "Apply
        // All" can't reach the others. Surface a transcript-level bar after
        // the card stack so the destructive / broad actions live at the end
        // of the review group rather than ahead of the individual choices.
        ForEach(groupedProposals, id: \.messageID) { group in
            constrained(
                Group {
                    if group.items.count >= 2 {
                        AgentPatchProposalGroup(proposals: group.items)
                    } else if let only = group.items.first {
                        AgentPatchProposalCard(proposal: only)
                    }
                }
            )
        }
        if showBulkBar {
            constrained(bulkBar)
        }
    }

    private var totalPendingCount: Int {
        proposals.filter { $0.status == .pending }.count
    }

    /// Only when pending patches span 2+ cards/groups — a lone group
    /// already carries its own Apply All, so a second bar would just
    /// duplicate it.
    private var showBulkBar: Bool {
        groupedProposals.count >= 2 && totalPendingCount >= 2
    }

    @ViewBuilder
    private var bulkBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
            Text(L10n.AgentPatch.allPendingTitle(totalPendingCount))
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                appState.rejectAllPendingAgentPatchProposals()
            } label: {
                Label(L10n.AgentPatch.rejectAll, systemImage: "xmark.circle")
            }
            Button {
                appState.applyAllPendingAgentPatchProposals()
            } label: {
                Label(L10n.AgentPatch.applyAll, systemImage: "checkmark.circle")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .padding(9)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func constrained(_ view: some View) -> some View {
        if let maxContentWidth {
            view.frame(maxWidth: maxContentWidth, alignment: .leading)
        } else {
            view
        }
    }

    private var groupedProposals: [(messageID: AgentMessage.ID, items: [AgentPatchProposal])] {
        var order: [AgentMessage.ID] = []
        var buckets: [AgentMessage.ID: [AgentPatchProposal]] = [:]
        // Only unresolved proposals stay interactive. Once the user clicks
        // Apply / Reject, the status change removes the card from the
        // transcript so it cannot be clicked again, even if apply records a
        // failure for diagnostics.
        for proposal in proposals where proposal.status == .pending {
            if buckets[proposal.messageID] == nil { order.append(proposal.messageID) }
            buckets[proposal.messageID, default: []].append(proposal)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

struct AgentPanelEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask about this project")
                .font(.system(size: 14, weight: .semibold))
            Text("The agent can read files, search, list directories, run commands (with approval), and check Git status.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
    }
}

struct AgentMessageBubble: View {
    let message: AgentMessage

    @State private var didJustCopy = false
    @State private var isHoveringUserMessage = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: AgentChatHistoryLayoutMetrics.userMessageElementSpacing
        ) {
            if message.role == .user, !message.images.isEmpty {
                AgentUserImageStrip(images: message.images)
                    .padding(
                        .bottom,
                        hasBubbleContent
                            ? AgentChatHistoryLayoutMetrics.userImageToBubbleSpacing
                                - AgentChatHistoryLayoutMetrics.userMessageElementSpacing
                            : 0
                    )
            }
            if hasBubbleContent {
                VStack(alignment: .leading, spacing: 4) {
                    if message.role != .user {
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !message.textAttachments.isEmpty {
                        AgentTextAttachmentBubbleStrip(attachments: message.textAttachments)
                    }
                    if !displayContent.isEmpty {
                        Text(displayContent)
                            .font(.system(size: 13))
                            .lineSpacing(AgentChatHistoryLayoutMetrics.bodyLineSpacing)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if message.role != .user, !message.images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(message.images) { image in
                                    AgentImageThumbnail(
                                        image: image,
                                        size: 96,
                                        allowsRemoval: false,
                                        onRemove: nil,
                                        onPreview: { AgentImagePreviewWindowRegistry.shared.open(image: image) }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(9)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
            }
            if shouldShowFooter {
                footer
                    .opacity(message.role == .user && !isHoveringUserMessage ? 0 : 1)
                    .allowsHitTesting(message.role != .user || isHoveringUserMessage)
                    .accessibilityHidden(message.role == .user && !isHoveringUserMessage)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHoveringUserMessage = $0 }
        .animation(.easeOut(duration: 0.12), value: isHoveringUserMessage)
    }

    private var hasBubbleContent: Bool {
        message.role != .user
            || !message.textAttachments.isEmpty
            || !displayContent.isEmpty
    }

    private var shouldShowFooter: Bool {
        switch message.role {
        case .system, .tool, .workflowReport, .widget, .scheduledTask: return false
        case .user, .assistant:
            return !message.content.isEmpty || !message.textAttachments.isEmpty || !message.images.isEmpty
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: copyToClipboard) {
                Image(systemName: didJustCopy ? "checkmark" : "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didJustCopy ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(didJustCopy ? "Copied" : "Copy message")

            if message.role == .assistant, let elapsed = message.elapsedSeconds, elapsed > 0 {
                Text(formatElapsed(elapsed))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if message.role == .assistant, let summary = tokenSummary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var tokenSummary: String? {
        if let prompt = message.promptTokens, let completion = message.completionTokens {
            return "\(formatTokens(prompt))/\(formatTokens(completion))"
        }
        if let total = message.usageTokens, total > 0 {
            return formatTokens(total)
        }
        return nil
    }

    private func formatElapsed(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000.0) : String(count)
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(message.copyableContent, forType: .string)
        didJustCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            didJustCopy = false
        }
    }

    private var displayContent: String {
        if message.content.isEmpty {
            if !message.toolCalls.isEmpty {
                return "Using tools…"
            }
            if !message.images.isEmpty {
                return ""
            }
            if !message.textAttachments.isEmpty {
                return ""
            }
            return "…"
        }
        if message.role == .user {
            let display = AgentAttachedPromptDisplay.transform(message.content)
            if display.isSplicedPrelude { return display.visibleContent }
        }
        return message.content
    }

    private var title: String {
        switch message.role {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Agent"
        case .tool: return "Tool"
        case .workflowReport: return "Workflow"
        case .widget: return "Widget"
        case .scheduledTask: return "Scheduled task"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .system:
            return Color(nsColor: .controlBackgroundColor).opacity(0.45)
        case .user:
            return Color.primary.opacity(AgentChatHistoryLayoutMetrics.userBubbleFillOpacity)
        case .assistant:
            return .clear
        case .tool, .workflowReport, .widget, .scheduledTask:
            return Color(nsColor: .controlBackgroundColor).opacity(0.4)
        }
    }

    private var bubbleCornerRadius: CGFloat {
        message.role == .user ? AgentChatHistoryLayoutMetrics.userBubbleCornerRadius : 7
    }
}
