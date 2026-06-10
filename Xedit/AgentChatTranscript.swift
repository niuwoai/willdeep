//
//  AgentChatTranscript.swift
//  VeilWriter
//
//  Scrolling transcript view for the agent chat pane, split out of
//  AgentModeView.swift in rc42.
//
//  The transcript owns three orthogonal subsystems:
//   - History collapsing: the bottom `renderedMessageCap` messages are
//     rendered live; anything older falls behind a disclosure card that
//     opens the full transcript in a standalone reader window.
//   - Per-message truncation: messages longer than `messageContentRenderCap`
//     characters get a "view full content" affordance instead of inlining
//     a 24 KB body that would freeze SwiftUI's layout pass.
//   - Render split: historical messages bake into one NSTextView (the
//     `AgentChatHistoryTextView` from rc16), while the currently-streaming
//     assistant message stays a SwiftUI bubble so Markdown formatting and
//     the streaming cursor remain live. Tool call groups, queued messages,
//     thinking divider, error / patch / worktree banners, and the bottom
//     scroll sentinel all live above and below those two surfaces in the
//     same non-lazy VStack.
//
//  `onChange` only watches counts (`agentMessages.count`,
//  `agentToolCalls.count`) rather than the full message arrays — diffing
//  the array on every streaming-token delta is what pinned the main
//  thread inside SwiftUI's layout before the rc16 split.
//
//  Previously `private struct` inside AgentModeView.swift; now internal
//  so the parent view can mount it across file boundaries.
//

import SwiftUI

struct AgentChatTranscript: View {
    @EnvironmentObject var appState: AppState
    private static let bottomScrollID = "agent-chat-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Keep this stack non-lazy. The visible transcript is
                // already capped and mostly rendered as one NSTextView;
                // LazyVStack's placement cache is the unstable part when
                // scrolling mixed SwiftUI/AppKit dynamic-height rows.
                VStack(alignment: .leading, spacing: AgentDesign.messageVerticalSpacing) {
                    // Plan + Goal banners — pinned above the transcript so
                    // the user always sees the current execution gate /
                    // long-term objective.
                    if appState.agentInteractionMode == .plan, let plan = appState.agentCurrentPlan {
                        AgentPlanCard(plan: plan)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }
                    if appState.agentInteractionMode == .goal, let goal = appState.agentCurrentGoal, !goal.isEmpty {
                        AgentGoalCard(goal: goal)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    if appState.agentMessages.isEmpty {
                        AgentChatEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        // rc16: chat pane history rendered as ONE
                        // NSTextView (`AgentChatHistoryTextView`)
                        // instead of one SwiftUI bubble per message.
                        // 15 rcs of bisection showed SwiftUI's
                        // LazyVStack + per-message bubble chrome
                        // (HStack + VStack + padding + background +
                        // overlay + frame) freezes the main thread
                        // on medium-rich content (1.5 KB message
                        // with a few tables / fenced code / HTML
                        // details — all common in real assistant
                        // replies), and no amount of bubble-internal
                        // optimization stopped it. TextKit handles
                        // the same content incrementally with no
                        // freeze regardless of length. Chat chrome
                        // now comes from TextKit-drawn bubble
                        // backgrounds and compact role avatars, so
                        // the history still reads like chat without
                        // reintroducing per-message SwiftUI views.
                        // Streaming assistant message is still
                        // rendered as a SwiftUI bubble so Markdown
                        // formatting + token-by-token updates +
                        // streaming cursor still feel live; once
                        // the turn ends it folds into the NSTextView
                        // on the next refresh.
                        let allVisible = visibleMessages
                        let rendered = renderedMessages(from: allVisible)
                        let omitted = allVisible.count - rendered.count
                        if omitted > 0 {
                            transcriptOlderHistoryCard(omittedCount: omitted)
                        }

                        let streamingMessageID = currentStreamingMessageID
                        let history = historyMessages(rendered: rendered, streamingID: streamingMessageID)
                        if !history.isEmpty {
                            AgentChatHistoryTextView(
                                messages: history,
                                baseFontSize: appState.agentChatBaseFontSize,
                                onRetryLastTurn: appState.retryLastAgentTurn
                            )
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                        }

                        // Render the active streaming message — and
                        // only it — through the SwiftUI bubble path
                        // so markdown formatting + the streaming
                        // cursor stay live during the turn.
                        if let streamingID = streamingMessageID,
                           let streamingMessage = rendered.first(where: { $0.id == streamingID }),
                           shouldShowMessageBubble(streamingMessage) {
                            AgentModeMessageView(
                                message: streamingMessage,
                                isStreamingThisMessage: true,
                                baseFontSize: appState.agentChatBaseFontSize
                            )
                                .id(streamingMessage.id)
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                        }

                        // Tool call groups: older calls are summarized
                        // inside the TextKit transcript; keep only the
                        // most recent group as a SwiftUI card so the
                        // user can still inspect exact arguments and
                        // output without reintroducing a long list of
                        // interactive views into the scroll path.
                        ForEach(toolCallGroupMessageIDs(in: rendered), id: \.self) { messageID in
                            let calls = toolCalls(for: messageID)
                            if !calls.isEmpty {
                                let segments = AgentToolCallGrouping.group(calls)
                                VStack(alignment: .leading, spacing: 8) {
                                    AgentTurnFileActivityCard(calls: calls)
                                    ForEach(segments) { segment in
                                        AgentToolCallGroup(
                                            calls: segment.calls,
                                            headline: segment.kind.groupTitle(segment.count),
                                            headlineIcon: segment.kind.groupIcon
                                        )
                                    }
                                }
                                .id(toolGroupScrollID(for: messageID))
                                // rc2: bumped from 16→28 because in the TextKit
                                // history path the assistant text view has no
                                // intrinsic bottom inset, so the tool card sat
                                // visually flush against the footer line
                                // ("◷ 1m 9s ↑ 13.5k ↓ out 495"). Plus the
                                // parent VStack's 18pt spacing the visible
                                // gap is ~46pt — comfortably separated.
                                .padding(.top, 28)
                                .padding(.bottom, 6)
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                            }
                        }
                    }

                    if appState.shouldShowAgentThinkingIndicator {
                        AgentThinkingDivider()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    // 底部活动指示，两档（参照 Claude Code）：
                    //  - 有任务在跑（前台工具阻塞 / 后台作业存活）→
                    //    「✳ N 个任务运行中」状态行；turn 结束后只要后台
                    //    作业还活着就继续挂着，解释"输出停了在等任务"。
                    //  - 否则 turn 还在跑 → 纯呼吸 icon（等首 token / 流式中）。
                    if !appState.isCompressingAgentContext {
                        let runningTasks = appState.agentRunningTaskCount
                        if runningTasks > 0 {
                            AgentRunningTasksRow(
                                count: runningTasks,
                                detail: appState.agentRunningTaskSummary
                            )
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                        } else if appState.isAgentResponding {
                            AgentBreathingIndicator()
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                        }
                    }

                    ForEach(appState.agentQueuedMessages) { queued in
                        QueuedMessageRow(
                            message: queued,
                            baseFontSize: appState.agentChatBaseFontSize
                        )
                    }

                    if appState.isCompressingAgentContext {
                        AgentContextCompressionDivider()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    if let error = appState.agentErrorMessage {
                        AgentErrorCard(message: error, details: appState.agentErrorDetails)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    ForEach(appState.agentPatchProposals) { proposal in
                        AgentPatchProposalCard(proposal: proposal)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    // Only show the worktree-change card once the Agent has
                    // actually applied a patch in this session — otherwise a
                    // brand-new chat opened inside a git repo with unrelated
                    // uncommitted changes would surface a misleading
                    // "正在编辑 / N 个文件已更改" banner.
                    if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                        AgentWorktreeChangeCard()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomScrollID)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // CRITICAL: only react to count, not the whole array.
            // Pre-fix this watched `appState.agentMessages` (the full
            // [AgentMessage]) — every streaming-token delta mutates
            // `messages[i].content`, Equatable on the array sees a
            // diff, and we'd kick a fresh `withAnimation` scroll on
            // every single token. Combined with the deeply-nested
            // chat-bubble layout (padding/HStack/VStack/ZStack 6+
            // levels), that pinned the main thread inside SwiftUI
            // layout — the symptom was the app freezing while a long
            // turn streamed, with a backtrace deep inside
            // `_FrameLayout.commonPlacement` / `_PaddingLayout.sizeThatFits`.
            // Scrolling on `.count` only fires when a brand-new
            // message is appended. The target is a stable bottom
            // sentinel because historical messages are folded into
            // one NSTextView and no longer expose per-message ids.
            .onChange(of: appState.agentMessages.count) { _, _ in
                proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
            }
            .onChange(of: appState.agentToolCalls.count) { _, _ in
                proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
            }
        }
    }

    private var visibleMessages: [AgentMessage] {
        appState.agentMessages.filter { message in
            // `.system` is reserved for host-injected notices (e.g.
            // background-task completion); the user reads those via the
            // right-side jobs drawer, not the transcript.
            message.role != .tool && message.role != .system && !isEmptyThinkingPlaceholder(message)
        }
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    private func isEmptyThinkingPlaceholder(_ message: AgentMessage) -> Bool {
        message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty
    }

    private func shouldShowMessageBubble(_ message: AgentMessage) -> Bool {
        !(message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty)
    }

    private func toolGroupScrollID(for messageID: AgentMessage.ID) -> String {
        "agent-tools-\(messageID.uuidString)"
    }

    /// The id of the assistant message that is currently being
    /// streamed, or nil if nothing is streaming. Resolved once per
    /// parent body pass and passed into each child bubble so that
    /// AgentModeMessageView itself doesn't need an environment
    /// reference to AppState — see the comment on that view for the
    /// AttributeGraph cost story.
    private var currentStreamingMessageID: AgentMessage.ID? {
        guard appState.isAgentResponding else { return nil }
        return appState.agentMessages.last(where: { $0.role == .assistant })?.id
    }

    /// How many messages the in-pane transcript renders at once.
    /// Anything older falls behind the "older history" disclosure
    /// and is reachable via the standalone reader window. Tuned to
    /// give plenty of context for a back-and-forth without exposing
    /// SwiftUI's LazyVStack to the long-list freeze.
    private static let renderedMessageCap = 20

    /// Per-message content size cap (in characters). Any message with
    /// content longer than this gets truncated in the chat bubble and
    /// the user gets a "view full content" affordance that opens the
    /// message in a standalone NSTextView window. This is the real
    /// freeze culprit: 13 rcs of bisection ruled out structural and
    /// dependency-graph issues; the remaining hot spot was SwiftUI's
    /// per-bubble layout choking on a single very long message body
    /// (e.g. a 24 KB tool output or an assistant reply that
    /// streamed to 19 KB). Trimming to ~3 KB keeps the bubble small
    /// enough for SwiftUI to handle without main-thread freezes.
    private static let messageContentRenderCap = 3_000

    /// Returns the message unchanged when its content fits, or a
    /// truncated copy when it doesn't.
    /// `(rendered, wasTruncated, originalLength)`.
    private func truncatedForBubble(_ message: AgentMessage) -> (rendered: AgentMessage, truncated: Bool, originalLength: Int) {
        let originalLength = message.content.count
        guard originalLength > Self.messageContentRenderCap else {
            return (message, false, originalLength)
        }
        var copy = message
        copy.content = String(message.content.prefix(Self.messageContentRenderCap))
        return (copy, true, originalLength)
    }

    /// Subset of `rendered` that should land in the NSTextView
    /// history view — everything except the currently-streaming
    /// assistant message (that one is rendered as its own SwiftUI
    /// bubble so markdown + streaming cursor stay live).
    private func historyMessages(rendered: [AgentMessage], streamingID: AgentMessage.ID?) -> [AgentMessage] {
        guard let streamingID else { return rendered }
        return rendered.filter { $0.id != streamingID }
    }

    /// Show detailed, expandable SwiftUI tool cards only for the most
    /// recent message with tool calls. Older calls are still visible in
    /// the TextKit history summary.
    private func toolCallGroupMessageIDs(in rendered: [AgentMessage]) -> [AgentMessage.ID] {
        guard let latest = rendered.reversed().first(where: { !toolCalls(for: $0.id).isEmpty }) else {
            return []
        }
        return [latest.id]
    }

    /// Slice the bottom `renderedMessageCap` messages out of the
    /// full visible list. If the list already fits, returns it
    /// untouched.
    private func renderedMessages(from all: [AgentMessage]) -> [AgentMessage] {
        guard all.count > Self.renderedMessageCap else { return all }
        return Array(all.suffix(Self.renderedMessageCap))
    }

    /// Inline disclosure shown right under a message whose content
    /// was truncated for the chat-pane render (see
    /// `messageContentRenderCap`). One tap opens the full message
    /// content in a standalone NSTextView window — same idea as the
    /// session-wide reader, but for one bubble at a time.
    @ViewBuilder
    private func longMessageTruncationCard(original: AgentMessage, originalLength: Int) -> some View {
        let omitted = originalLength - AgentChatTranscript.messageContentRenderCap
        Button {
            let sessionTitle = appState.agentSessions
                .first(where: { $0.id == appState.activeAgentSessionID })?.title ?? ""
            AgentTranscriptReader.openSingleMessage(original, sessionTitle: sessionTitle)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.Transcript.messageTruncatedText(String(AgentChatTranscript.messageContentRenderCap), String(omitted)))
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(L10n.Transcript.messageTruncatedHelp)
    }

    /// Banner shown at the top of the transcript when older messages
    /// have been hidden from the chat pane. One tap opens the full
    /// transcript in a standalone NSWindow.
    @ViewBuilder
    private func transcriptOlderHistoryCard(omittedCount: Int) -> some View {
        Button {
            guard let id = appState.activeAgentSessionID,
                  let session = appState.agentSessions.first(where: { $0.id == id }) else { return }
            AgentTranscriptReader.open(session: session)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.Transcript.olderHistoryText(String(omittedCount)))
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(L10n.Transcript.olderHistoryHelp)
    }
}
