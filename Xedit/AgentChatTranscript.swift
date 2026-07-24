//
//  AgentChatTranscript.swift
//  WillDeep
//
//  Scrolling transcript view for the agent chat pane, split out of
//  AgentModeView.swift in rc42.
//
//  The transcript owns three orthogonal subsystems:
//   - History collapsing: a large recent window of messages is rendered
//     inline; only very long sessions fall behind a disclosure card that
//     opens the full transcript in a standalone reader window.
//   - Per-message truncation: messages longer than `messageContentRenderCap`
//     characters get a "view full content" affordance instead of inlining
//     a 24 KB body that would freeze SwiftUI's layout pass.
//   - Render split: historical messages bake into one NSTextView (the
//     `AgentChatHistoryTextView` from rc16), while the currently-streaming
//     assistant message stays a SwiftUI bubble so Markdown formatting and
//     the streaming cursor remain live. Tool call groups, queued messages,
//     thinking status, error / patch / worktree banners, and the bottom
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
import AppKit

struct AgentMessageContentPreview {
    let content: String
    let omittedCharacters: Int

    static func make(
        content: String,
        maxCharacters: Int,
        omissionText: (Int) -> String
    ) -> AgentMessageContentPreview {
        guard maxCharacters > 0 else {
            return AgentMessageContentPreview(content: "", omittedCharacters: content.count)
        }
        guard content.count > maxCharacters else {
            return AgentMessageContentPreview(content: content, omittedCharacters: 0)
        }
        guard maxCharacters >= 128 else {
            return AgentMessageContentPreview(
                content: String(content.prefix(maxCharacters)),
                omittedCharacters: max(0, content.count - maxCharacters)
            )
        }

        var omitted = max(0, content.count - maxCharacters)
        var marker = ""
        var headCount = 0
        var tailCount = 0

        for _ in 0..<4 {
            marker = "\n\n\(omissionText(omitted))\n\n"
            let available = max(2, maxCharacters - marker.count)
            headCount = available / 2
            tailCount = available - headCount
            let nextOmitted = max(0, content.count - headCount - tailCount)
            if nextOmitted == omitted { break }
            omitted = nextOmitted
        }

        marker = "\n\n\(omissionText(omitted))\n\n"
        let preview = String(content.prefix(headCount)) + marker + String(content.suffix(tailCount))
        return AgentMessageContentPreview(content: preview, omittedCharacters: omitted)
    }
}

struct AgentOlderHistoryPreview {
    let content: String
    let omittedCharacters: Int
    let totalCharacters: Int

    static func make(
        messages: [AgentMessage],
        maxCharacters: Int,
        roleLabel: (AgentRole) -> String,
        omissionText: (Int) -> String
    ) -> AgentOlderHistoryPreview {
        let totalCharacters = messages.reduce(0) { partial, message in
            partial + plainTextLength(for: message, roleLabel: roleLabel)
        }
        guard maxCharacters > 0 else {
            return AgentOlderHistoryPreview(
                content: "",
                omittedCharacters: totalCharacters,
                totalCharacters: totalCharacters
            )
        }

        var lines: [String] = []
        var used = 0
        var omitted = 0

        for message in messages {
            let text = plainText(for: message, roleLabel: roleLabel)
            guard !text.isEmpty else { continue }
            let separatorLength = lines.isEmpty ? 0 : 2
            let available = maxCharacters - used - separatorLength
            guard available > 0 else {
                omitted += separatorLength + text.count
                continue
            }
            if text.count <= available {
                lines.append(text)
                used += separatorLength + text.count
            } else {
                lines.append(String(text.prefix(available)))
                omitted += text.count - available
                used = maxCharacters
            }
        }

        if omitted > 0 {
            let marker = omissionText(omitted)
            if used + 2 + marker.count <= maxCharacters {
                lines.append(marker)
            }
        }

        return AgentOlderHistoryPreview(
            content: lines.joined(separator: "\n\n"),
            omittedCharacters: omitted,
            totalCharacters: totalCharacters
        )
    }

    private static func plainText(for message: AgentMessage, roleLabel: (AgentRole) -> String) -> String {
        let content = visiblePlainTextContent(for: message)
        guard !content.isEmpty else { return "" }
        return "\(roleLabel(message.role)):\n\(content)"
    }

    private static func plainTextLength(for message: AgentMessage, roleLabel: (AgentRole) -> String) -> Int {
        let content = visiblePlainTextContent(for: message)
        guard !content.isEmpty else { return 0 }
        return roleLabel(message.role).count + 2 + content.count
    }

    private static func visiblePlainTextContent(for message: AgentMessage) -> String {
        guard message.role == .user else {
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let display = AgentAttachedPromptDisplay.transform(message.content)
        let source = display.isSplicedPrelude ? display.visibleContent : message.content
        var parts: [String] = []
        let visible = AgentUserContentSplitter.split(source)
            .visible
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty {
            parts.append(visible)
        }
        if !message.images.isEmpty {
            parts.append("[Image attachment ×\(message.images.count)]")
        }
        return parts.joined(separator: "\n")
    }
}

/// Resolves the assistant message owned by the currently active provider turn.
///
/// `isResponding` becomes true before `runAgentLoop` appends its first
/// assistant placeholder. During that short window, blindly selecting the
/// conversation's last assistant message pulls the previous completed answer
/// out of TextKit history and re-renders it as live plain text. Besides exposing
/// Markdown fences, that also places the newly appended user message above the
/// old answer, making the send look lost. The turn start timestamp is the
/// boundary that distinguishes a new live message from settled history.
nonisolated enum AgentStreamingMessageSelection {
    static func currentAssistantID(
        in messages: [AgentMessage],
        isResponding: Bool,
        turnStartedAt: Date?
    ) -> AgentMessage.ID? {
        guard isResponding, let turnStartedAt else { return nil }
        return messages.last(where: {
            $0.role == .assistant && $0.createdAt >= turnStartedAt
        })?.id
    }
}

struct AgentChatTranscript: View {
    @EnvironmentObject var appState: AppState
    private static let bottomScrollID = "agent-chat-transcript-bottom"

    /// 1.103.0-rc11: TextKit footer 里 doc.text 图标点开后呈现
    /// AgentTurnReportCard 的 SwiftUI popover 开关。Anchor 挂在
    /// AgentChatHistoryTextView wrapper 上即可。
    @State private var showTurnReportPopover = false
    /// Left-edge user-input minimap → history NSTextView scroll trigger. The
    /// token bumps on each tick click so re-selecting the same turn re-scrolls.
    @State private var minimapScrollToken = 0
    @State private var minimapScrollUserMessageID: UUID?
    @State private var isOlderHistoryPreviewExpanded = false
    @State private var isConversationSearchPresented = false
    @State private var conversationSearchQuery = ""
    @State private var conversationSearchMatchCount = 0
    @State private var conversationSearchActiveIndex = 0
    @State private var isFollowingTranscriptBottom = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                    if appState.agentInteractionMode == .goal, let goal = appState.agentCurrentGoal, !goal.isEmpty {
                        AgentGoalCard(goal: goal)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }
                    if appState.agentInteractionMode == .goal,
                       let planningState = appState.activeRuntime?.goalPlanningState,
                       appState.agentCurrentPlan == nil {
                        AgentGoalPlanningCard(state: planningState)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }
                    // Plan card no longer sits inline here — it floats in the
                    // conversation activity overlay (top-trailing), collapsed by
                    // default, alongside the artifact / media / dev-server cards.
                    // See AgentConversationActivityOverlay.

                    if appState.agentMessages.isEmpty && localConfirmationPreviewCalls.isEmpty {
                        AgentChatEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 44)
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
                        let searchingConversation = isConversationSearchActive
                        let rendered = searchingConversation ? allVisible : renderedMessages(from: allVisible)
                        let activeToolPresentation = AgentActiveTurnToolCallPresentation.make(
                            messages: appState.agentMessages,
                            toolCalls: appState.agentToolCalls,
                            isResponding: appState.isAgentResponding
                        )
                        let omitted = searchingConversation ? 0 : allVisible.count - rendered.count
                        if omitted > 0 {
                            transcriptOlderHistoryCard(
                                omittedCount: omitted,
                                omittedMessages: olderMessages(from: allVisible)
                            )
                        }

                        let streamingMessageID = searchingConversation ? nil : currentStreamingMessageID
                        let history = historyMessages(
                            rendered: rendered,
                            streamingID: streamingMessageID,
                            activeToolPresentation: activeToolPresentation
                        )
                        if !history.isEmpty {
                            AgentChatHistoryTextView(
                                messages: history,
                                assistantTurnContextMessages: appState.agentMessages,
                                isAssistantTurnActive: appState.isAgentResponding,
                                baseFontSize: appState.agentChatBaseFontSize,
                                onRetryLastTurn: appState.retryLastAgentTurn,
                                latestTurnReportToolCount: appState.agentLatestTurnReport?.toolSummary.total,
                                onShowTurnReport: { showTurnReportPopover = true },
                                onReferenceGeneratedImage: appState.appendGeneratedImageReferenceToAgentInput,
                                onAddSelectionToTask: appState.addAgentChatSelectionToTask,
                                onOpenFilePath: { rawPath in
                                    // Agent mode 里点击 transcript 中的路径
                                    // chip:workspace 内的目录 → 右侧 Files
                                    // 展开到该目录;workspace 外(含 `~/…`)
                                    // → Finder 定位;文件 → Preview。
                                    appState.revealAgentReferencedPath(rawPath)
                                },
                                onOpenAttachmentCitation: appState.openAgentAttachmentCitation,
                                progressPlan: appState.agentCurrentPlan,
                                onShowPlan: {
                                    // Plan card floats in the activity overlay now;
                                    // bump the token so the overlay expands it.
                                    appState.agentPlanOverlayExpandRequestToken += 1
                                },
                                searchQuery: conversationSearchQuery,
                                activeSearchMatchIndex: conversationSearchActiveIndex,
                                onSearchResultCountChange: updateConversationSearchMatchCount,
                                scrollToUserMessageToken: minimapScrollToken,
                                scrollToUserMessageID: minimapScrollUserMessageID
                            )
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                                .popover(isPresented: $showTurnReportPopover, arrowEdge: .top) {
                                    // 1.103.0-rc11:复用 AgentTurnPostStrip 里
                                    // 同款 ScrollView + 固定 width/maxHeight
                                    // 包裹,长报告也不会撑出屏幕。
                                    if let report = appState.agentLatestTurnReport {
                                        ScrollView {
                                            AgentTurnReportCard(report: report, initiallyExpanded: true)
                                                .padding(12)
                                                .frame(width: 520, alignment: .leading)
                                        }
                                        .frame(width: 520)
                                        .frame(maxHeight: 560)
                                    }
                                }
                        }

                        // 运行中(planning/running)的 workflow 卡片走 SwiftUI
                        // —— 进度条/子 agent 状态要随 report mutate 实时刷新,
                        // 与 tool call group 同款「工作态表面」。结束后这条
                        // 消息折回上面的 TextKit 历史,由 formatter 烘焙
                        // 状态行 + 最终报告(见 AgentChatHistoryFormatter 的
                        // workflowReport 分支)。1.155.0-rc9 之前这里没有任何
                        // 挂载点:rc16 历史折进 NSTextView 后,AgentModeMessageView
                        // 的 .workflowReport 分支只剩流式 assistant 一个入口,
                        // workflow 卡片(进度、失败原因、研究报告)整体不可见。
                        ForEach(activeWorkflowMessages(in: rendered)) { message in
                            AgentModeMessageView(
                                message: message,
                                isStreamingThisMessage: false,
                                baseFontSize: appState.agentChatBaseFontSize
                            )
                                .id(message.id)
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                        }

                        // Render the active streaming message — and
                        // only it — through the SwiftUI bubble path
                        // so markdown formatting + the streaming
                        // cursor stay live during the turn.
                        if let streamingID = streamingMessageID,
                           let streamingMessage = rendered.first(where: { $0.id == streamingID }),
                           shouldShowMessageBubble(streamingMessage) {
                            let display = truncatedForBubble(streamingMessage)
                            let turnPresentation = currentAssistantTurnPresentation(for: streamingID)
                            AgentModeMessageView(
                                message: display.rendered,
                                isStreamingThisMessage: true,
                                assistantTurnPresentation: turnPresentation,
                                baseFontSize: appState.agentChatBaseFontSize,
                                onReferenceGeneratedImage: appState.appendGeneratedImageReferenceToAgentInput,
                                progressPlan: appState.agentCurrentPlan,
                                onShowPlan: {
                                    // Plan card floats in the activity overlay now;
                                    // bump the token so the overlay expands it.
                                    appState.agentPlanOverlayExpandRequestToken += 1
                                },
                                suppressesActivityHeadline: activeToolPresentation?.calls.isEmpty == false
                            )
                                .id(streamingMessage.id)
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                            if display.truncated {
                                longMessageTruncationCard(
                                    original: streamingMessage,
                                    omittedLength: display.omittedLength
                                )
                            }
                        }

                        // Tool call groups are a working-state surface.
                        // While a turn is running, or while a tool is
                        // waiting for the user, keep the newest details
                        // interactive and inspectable. Once everything
                        // settles, fold them back into the TextKit
                        // history summary so the transcript reads like
                        // the final assistant result rather than a log
                        // dump of the execution path.
                        if let activeToolPresentation,
                           let messageID = activeToolPresentation.anchorMessageID,
                           !activeToolPresentation.calls.isEmpty {
                                AgentLiveActivityTimeline(calls: activeToolPresentation.calls)
                                .id(toolGroupScrollID(for: messageID))
                                // The parent transcript reserves 20 pt between
                                // separate messages. This activity belongs to
                                // the prose immediately above, so cancel that
                                // turn gap and restore a normal 6 pt line
                                // rhythm instead.
                                .padding(
                                    .top,
                                    AgentDesign.liveActivityTopSpacing
                                        - AgentDesign.messageVerticalSpacing
                                )
                                .padding(.bottom, 6)
                                .padding(.leading, AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
                                .padding(.trailing, AgentChatHistoryLayoutMetrics.assistantContentTailInset)
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                        }
                    }

                    if !localConfirmationPreviewCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(localConfirmationPreviewCalls) { call in
                                AgentToolCallCard(call: call)
                            }
                        }
                        .id("agent-local-confirmation-preview")
                        .accessibilityIdentifier("agent-local-confirmation-preview")
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .padding(.leading, AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
                        .padding(.trailing, AgentChatHistoryLayoutMetrics.assistantContentTailInset)
                        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    // 消息已发出、但还没抢到 provider 并发槽（同一 provider
                    // 已有 perProviderConcurrencyLimit 个 turn 在跑，比如多
                    // 会话/双开/routine 并发）时，dispatch 走排队分支、
                    // isResponding 仍为 false，下面的思考文字计时不会
                    // 亮。若这里不补一行，用户只看到自己的消息、界面像死了，
                    // 直到某个槽空出来 drain 才「又开始输出」。参照侧栏
                    // AgentPanelView 的同款提示。
                    if appState.activeRuntime?.isAwaitingProviderSlot == true {
                        AgentInlineStatusDivider(
                            text: L10n.AgentPanel.queueWaiting,
                            systemImage: "clock",
                            leadingInset: AgentChatHistoryLayoutMetrics.assistantContentHeadIndent,
                            trailingInset: AgentChatHistoryLayoutMetrics.assistantContentTailInset
                        )
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    if appState.isCompressingAgentContext {
                        AgentContextCompressionDivider(
                            leadingInset: AgentChatHistoryLayoutMetrics.assistantContentHeadIndent,
                            trailingInset: AgentChatHistoryLayoutMetrics.assistantContentTailInset
                        )
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    if let error = appState.agentErrorMessage {
                        AgentErrorCard(message: error, details: appState.agentErrorDetails)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    AgentPatchProposalList(
                        proposals: appState.agentPatchProposals,
                        maxContentWidth: AgentDesign.chatMaxContentWidth
                    )

                    // Only show the worktree-change card once the Agent has
                    // actually applied a patch in this session — otherwise a
                    // brand-new chat opened inside a git repo with unrelated
                    // uncommitted changes would surface a misleading
                    // "正在编辑 / N 个文件已更改" banner.
                    if appState.agentSessionDidEditFiles,
                       appState.isAgentWorktreeChangeCardExpanded,
                       !appState.agentWorktreeChanges.isEmpty {
                        AgentWorktreeChangeCard(onReview: {
                            // Agent 模式:审查 / 点文件 → 拉起右侧 diff 侧栏,
                            // 不再弹独立 sheet 窗口。
                            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .diff)
                        }, showsSummaryRow: false)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    // 1.85.0-rc13:原来这里挂两张大卡片(AgentTurnReportCard
                    // + AgentLearningEventsCard),每轮都吃半屏。改成一行
                    // 紧凑的图标条 + popover —— 详见 AgentTurnPostStrip。
                    AgentTurnPostStrip(
                        report: appState.agentLatestTurnReport,
                        learningEvents: appState.agentCurrentTurnLearningEvents,
                        onApproveMemory: { event in
                            appState.applyAgentMemoryDrafts(for: event)
                        }
                    )
                    .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)

                    // 排队消息钉在 transcript 最底部，紧贴 composer 的
                    // 当前动作/任务状态区域，避免被其它卡片隔开。
                    if !appState.agentQueuedMessages.isEmpty {
                        QueuedMessagesList(
                            messages: appState.agentQueuedMessages,
                            baseFontSize: appState.agentChatBaseFontSize,
                            onEdit: { queued in
                                appState.editQueuedAgentMessage(id: queued.id)
                            },
                            onSendNow: { queued in
                                appState.sendQueuedAgentMessageNow(id: queued.id)
                            },
                            onRemove: { queued in
                                appState.removeQueuedAgentMessage(id: queued.id)
                            },
                            onMove: { sourceID, targetID in
                                appState.moveQueuedAgentMessage(id: sourceID, to: targetID)
                            }
                        )
                        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomScrollID)
                }
                .padding(.horizontal, AgentDesign.chatHorizontalInset)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    AgentTranscriptScrollObserver(
                        isFollowingBottom: $isFollowingTranscriptBottom
                    )
                    .frame(width: 0, height: 0)
                }
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
                .onCompatibleChange(of: appState.agentMessages.count) { oldCount, newCount in
                    guard !isConversationSearchActive else { return }
                    let appendedMessage = newCount > oldCount ? appState.agentMessages.last : nil
                    guard AgentTranscriptScrollPolicy.shouldScrollAfterAppending(
                        appendedMessage,
                        isFollowingBottom: isFollowingTranscriptBottom
                    ) else { return }
                    if appendedMessage?.isOperatorInput == true {
                        isFollowingTranscriptBottom = true
                    }
                    scrollToBottom(using: proxy)
                }
                .onCompatibleChange(of: appState.agentToolCalls.count) { _, _ in
                    guard !isConversationSearchActive, isFollowingTranscriptBottom else { return }
                    scrollToBottom(using: proxy)
                }
                .onCompatibleChange(of: appState.agentLearningEvents.count) { _, _ in
                    guard !isConversationSearchActive, isFollowingTranscriptBottom else { return }
                    scrollToBottom(using: proxy)
                }
                .onCompatibleChange(of: appState.agentQueuedMessages.count) { _, _ in
                    guard !isConversationSearchActive, isFollowingTranscriptBottom else { return }
                    scrollToBottom(using: proxy)
                }
            // AppKit observer 会在操作人仍跟随底部时吸收流式内容增长，
            // 避免逐 token 触发 SwiftUI scrollTo。回合结束后仍补一次稳定
            // 锚点滚动，用于收敛 TextKit 历史折叠造成的最后一帧高度变化；
            // 操作人已上滚回看时则保持当前位置不动。
                .onCompatibleChange(of: appState.isAgentResponding) { _, nowResponding in
                    guard !nowResponding,
                          !isConversationSearchActive,
                          isFollowingTranscriptBottom else { return }
                    scrollToBottom(using: proxy)
                }
                .onCompatibleChange(of: currentStreamingMessageID) { previousID, currentID in
                    guard AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
                        previousMessageID: previousID,
                        currentMessageID: currentID
                    ) else { return }
                    // Plan card floats in the activity overlay now; fold it away
                    // when a new assistant round begins.
                    appState.agentPlanOverlayCollapseRequestToken += 1
                }

            // 切走 app 再切回来时,SwiftUI 会重新布局 ScrollView,默认
            // 把滚动位置重置到顶部 —— 用户反馈:本来在看最新消息,
            // 切回来却跳到了最顶上。这里在视图首次出现 + app 重新激活
            // 时把锚点拉回底部哨兵,保证「切回来还在最新处」。
                .onAppear {
                    // 等一帧让内容先完成布局,直接 scrollTo 在 onAppear 里
                    // 偶尔会落空(目标还没拿到最终高度)。
                    DispatchQueue.main.async {
                        guard !isConversationSearchActive else { return }
                        isFollowingTranscriptBottom = true
                        proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    DispatchQueue.main.async {
                        guard !isConversationSearchActive, isFollowingTranscriptBottom else { return }
                        proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
                    }
                }
            }
            if isConversationSearchPresented {
                AgentConversationSearchBar(
                    isPresented: $isConversationSearchPresented,
                    query: $conversationSearchQuery,
                    matchCount: conversationSearchMatchCount,
                    activeIndex: displayedConversationSearchActiveIndex,
                    onPrevious: selectPreviousConversationSearchMatch,
                    onNext: selectNextConversationSearchMatch,
                    onClose: closeConversationSearch
                )
                .padding(.top, 12)
                .padding(.trailing, 24)
                .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .overlay(alignment: .leading) {
            let turns = userInputMinimapTurns
            if turns.count >= AgentTranscriptUserMinimap.minimumVisibleTurnCount {
                AgentTranscriptUserMinimap(turns: turns) { userMessageID in
                    minimapScrollUserMessageID = userMessageID
                    minimapScrollToken += 1
                }
            }
        }
        .background(AgentConversationSearchKeyboardShortcutView(onFind: presentConversationSearch))
        .onCompatibleChange(of: conversationSearchQuery) { _, _ in
            conversationSearchActiveIndex = 0
        }
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            closeConversationSearch()
        }
    }

    /// Turns for the left-edge user-input minimap: one entry per user message
    /// in the currently-rendered window, with its reply + edited files folded in.
    private var userInputMinimapTurns: [AgentTranscriptTurnSummary] {
        let all = visibleMessages
        let rendered = isConversationSearchActive ? all : renderedMessages(from: all)
        return AgentTranscriptTurnSummary.build(from: rendered, toolCalls: appState.agentToolCalls)
    }

    private var isConversationSearchActive: Bool {
        isConversationSearchPresented && !AgentTranscriptSearch.normalizedQuery(conversationSearchQuery).isEmpty
    }

    private var displayedConversationSearchActiveIndex: Int {
        AgentTranscriptSearch.clampedActiveIndex(
            conversationSearchActiveIndex,
            count: conversationSearchMatchCount
        ) ?? 0
    }

    private func presentConversationSearch() {
        withAnimation(.easeOut(duration: 0.14)) {
            isConversationSearchPresented = true
        }
    }

    private func closeConversationSearch() {
        withAnimation(.easeOut(duration: 0.12)) {
            isConversationSearchPresented = false
        }
        conversationSearchQuery = ""
        conversationSearchMatchCount = 0
        conversationSearchActiveIndex = 0
    }

    private func updateConversationSearchMatchCount(_ count: Int) {
        DispatchQueue.main.async {
            conversationSearchMatchCount = count
            if count <= 0 {
                conversationSearchActiveIndex = 0
            } else if conversationSearchActiveIndex >= count {
                conversationSearchActiveIndex = count - 1
            }
        }
    }

    private func selectPreviousConversationSearchMatch() {
        guard conversationSearchMatchCount > 0 else { return }
        conversationSearchActiveIndex = (displayedConversationSearchActiveIndex - 1 + conversationSearchMatchCount) % conversationSearchMatchCount
    }

    private func selectNextConversationSearchMatch() {
        guard conversationSearchMatchCount > 0 else { return }
        conversationSearchActiveIndex = (displayedConversationSearchActiveIndex + 1) % conversationSearchMatchCount
    }

    private var visibleMessages: [AgentMessage] {
        let visible = appState.agentMessages.compactMap { message in
            // `.system` is reserved for host-injected notices (e.g.
            // background-task completion); the user reads those via the
            // right-side jobs drawer, not the transcript.
            // `.workflowReport` (1.81.0-rc1) is rendered as a custom card
            // — explicitly allowed through.
            if message.isLocalTranscriptEvent { return message }
            if message.role == .workflowReport { return message }
            if message.role == .widget { return message }
            if message.role == .scheduledTask { return message }
            guard message.role != .tool,
                  message.role != .system,
                  !message.isHostInstruction,
                  !isEmptyThinkingPlaceholder(message),
                  !isSettledToolCallOnlyMessage(message) else {
                return nil
            }
            return resultPresentationMessage(message)
        }
        guard appState.agentInteractionMode == .goal,
              !appState.isAgentResponding else {
            return visible
        }
        return AgentGoalTranscriptPresentation.settledMessages(from: visible)
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
        }
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    private var localConfirmationPreviewCalls: [AgentToolCall] {
        appState.activeRuntime?.localConfirmationPreviewCalls ?? []
    }

    private func isEmptyThinkingPlaceholder(_ message: AgentMessage) -> Bool {
        message.role == .assistant && message.content.isEmpty && message.images.isEmpty && message.toolCalls.isEmpty
    }

    private func shouldShowMessageBubble(_ message: AgentMessage) -> Bool {
        !(message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty)
    }

    private func isSettledToolCallOnlyMessage(_ message: AgentMessage) -> Bool {
        guard message.role == .assistant,
              message.content.isEmpty,
              !message.toolCalls.isEmpty,
              !appState.isAgentResponding else {
            return false
        }
        return !toolCalls(for: message.id).contains(where: isWorkingToolCall)
    }

    private func resultPresentationMessage(_ message: AgentMessage) -> AgentMessage {
        guard message.role == .assistant,
              !message.toolCalls.isEmpty,
              !appState.isAgentResponding,
              !toolCalls(for: message.id).contains(where: isWorkingToolCall) else {
            return message
        }
        var copy = message
        copy.toolCalls = []
        return copy
    }

    private func isWorkingToolCall(_ call: AgentToolCall) -> Bool {
        switch call.status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer, .running:
            return true
        case .succeeded, .failed, .denied:
            return false
        }
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
        AgentStreamingMessageSelection.currentAssistantID(
            in: appState.agentMessages,
            isResponding: appState.isAgentResponding,
            turnStartedAt: appState.agentTurnStartedAt
        )
    }

    private func currentAssistantTurnPresentation(
        for messageID: AgentMessage.ID
    ) -> AgentAssistantTurnPresentation? {
        let messages = appState.agentMessages
        let startIndex = messages.lastIndex(where: { $0.role == .user }) ?? messages.startIndex
        return AgentAssistantTurnGrouping.presentation(
            for: messageID,
            in: Array(messages[startIndex...]),
            aggregatesCopyContent: false
        )
    }

    /// How many messages the in-pane transcript renders at once.
    /// Anything older falls behind the "older history" disclosure
    /// and is reachable via the standalone reader window. Since the
    /// settled history is baked into a single incrementally-laid-out
    /// NSTextView (not a SwiftUI bubble per message), keep a Codex-like
    /// amount of recent conversation visible before archiving kicks in.
    static let renderedMessageCap = 240

    /// Per-message content size cap (in characters). Any message with
    /// content longer than this gets a start/end preview in the chat
    /// bubble and the user gets a "view full content" affordance that opens the
    /// message in a standalone NSTextView window. This is the real
    /// freeze culprit: 13 rcs of bisection ruled out structural and
    /// dependency-graph issues; the remaining hot spot was SwiftUI's
    /// per-bubble layout choking on a single very long message body
    /// (e.g. a 24 KB tool output or an assistant reply that
    /// streamed to 19 KB). Trimming to ~3 KB keeps the bubble small
    /// enough for SwiftUI to handle without main-thread freezes.
    private static let messageContentRenderCap = 3_000

    /// Character cap for the inline older-history text preview. Full
    /// history remains available through the standalone reader, but the
    /// default expansion should stay cheap for very long sessions.
    static let olderHistoryPreviewCharacterCap = 12_000

    /// Returns the message unchanged when its content fits, or a preview
    /// copy when it doesn't. Long previews preserve both the beginning
    /// and the end so the latest conclusion/error is still visible while
    /// SwiftUI avoids laying out the full streaming body.
    /// `(rendered, wasTruncated, omittedLength)`.
    private func truncatedForBubble(_ message: AgentMessage) -> (rendered: AgentMessage, truncated: Bool, omittedLength: Int) {
        let originalLength = message.content.count
        guard originalLength > Self.messageContentRenderCap else {
            return (message, false, 0)
        }
        var copy = message
        let preview = AgentMessageContentPreview.make(
            content: message.content,
            maxCharacters: Self.messageContentRenderCap,
            omissionText: { L10n.Transcript.messageMiddleOmittedText(String($0)) }
        )
        copy.content = preview.content
        return (copy, true, preview.omittedCharacters)
    }

    /// Subset of `rendered` that should land in the NSTextView
    /// history view — everything except the currently-streaming
    /// assistant message (that one is rendered as its own SwiftUI
    /// bubble so markdown + streaming cursor stay live).
    private func historyMessages(
        rendered: [AgentMessage],
        streamingID: AgentMessage.ID?,
        activeToolPresentation: AgentActiveTurnToolCallPresentation?
    ) -> [AgentMessage] {
        rendered.compactMap { message in
            if message.id == streamingID { return nil }
            // 运行中的 workflow 卡片由下方的 SwiftUI 工作态表面渲染,
            // 不进 TextKit 历史(避免同一条消息出现两次)。
            if isActiveWorkflowMessage(message) { return nil }
            return activeToolPresentation?.hidingToolCalls(in: message) ?? message
        }
    }

    /// planning/running 状态的 workflow 消息 —— 需要实时进度的那部分。
    /// done/failed/cancelled 走 TextKit 历史烘焙。
    private func isActiveWorkflowMessage(_ message: AgentMessage) -> Bool {
        guard message.role == .workflowReport,
              let status = message.workflowReport?.status else { return false }
        return status == .planning || status == .running
    }

    private func activeWorkflowMessages(in rendered: [AgentMessage]) -> [AgentMessage] {
        rendered.filter(isActiveWorkflowMessage)
    }

    /// Slice the bottom `renderedMessageCap` messages out of the
    /// full visible list. If the list already fits, returns it
    /// untouched.
    private func renderedMessages(from all: [AgentMessage]) -> [AgentMessage] {
        guard all.count > Self.renderedMessageCap else { return all }
        return Array(all.suffix(Self.renderedMessageCap))
    }

    private func olderMessages(from all: [AgentMessage]) -> [AgentMessage] {
        guard all.count > Self.renderedMessageCap else { return [] }
        return Array(all.prefix(all.count - Self.renderedMessageCap))
    }

    /// Inline disclosure shown right under a message whose content
    /// was truncated for the chat-pane render (see
    /// `messageContentRenderCap`). One tap opens the full message
    /// content in a standalone NSTextView window — same idea as the
    /// session-wide reader, but for one bubble at a time.
    @ViewBuilder
    private func longMessageTruncationCard(original: AgentMessage, omittedLength: Int) -> some View {
        Button {
            let sessionTitle = appState.agentSessions
                .first(where: { $0.id == appState.activeAgentSessionID })?.title ?? ""
            AgentTranscriptReader.openSingleMessage(original, sessionTitle: sessionTitle)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.Transcript.messageTruncatedText(String(AgentChatTranscript.messageContentRenderCap), String(omittedLength)))
                    .agentChatSupportingFont()
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
    /// have been hidden from the chat pane. The default expansion is a
    /// capped plain-text preview; opening the full rich transcript is a
    /// separate explicit action.
    @ViewBuilder
    private func transcriptOlderHistoryCard(omittedCount: Int, omittedMessages: [AgentMessage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isOlderHistoryPreviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L10n.Transcript.olderHistoryText(String(omittedCount)))
                        .agentChatSupportingFont()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(L10n.Transcript.olderHistoryPreviewLimit(String(Self.olderHistoryPreviewCharacterCap)))
                        .agentChatSupportingFont()
                        .foregroundStyle(.tertiary)
                    Image(systemName: isOlderHistoryPreviewExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.Transcript.olderHistoryPreviewHelp)

            if isOlderHistoryPreviewExpanded {
                let preview = AgentOlderHistoryPreview.make(
                    messages: omittedMessages,
                    maxCharacters: Self.olderHistoryPreviewCharacterCap,
                    roleLabel: olderHistoryRoleLabel,
                    omissionText: { L10n.Transcript.olderHistoryOmittedText(String($0)) }
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.content.isEmpty ? L10n.Transcript.olderHistoryNoText : preview.content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text(L10n.Transcript.olderHistoryPreviewSummary(
                            String(preview.content.count),
                            String(preview.totalCharacters),
                            String(preview.omittedCharacters)
                        ))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        Button {
                            guard let id = appState.activeAgentSessionID,
                                  let session = appState.agentSessions.first(where: { $0.id == id }) else { return }
                            AgentTranscriptReader.open(session: session)
                        } label: {
                            Label(L10n.Transcript.olderHistoryOpenFull, systemImage: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.Transcript.olderHistoryHelp)
                    }
                }
                .padding(.top, 2)
            }
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

    private func olderHistoryRoleLabel(_ role: AgentRole) -> String {
        switch role {
        case .system:
            return L10n.Transcript.olderHistoryRoleSystem
        case .user:
            return L10n.Transcript.olderHistoryRoleUser
        case .assistant:
            return L10n.Transcript.olderHistoryRoleAssistant
        case .tool:
            return L10n.Transcript.olderHistoryRoleTool
        case .workflowReport:
            return L10n.Transcript.olderHistoryRoleWorkflow
        case .widget:
            return L10n.Transcript.olderHistoryRoleWidget
        case .scheduledTask:
            return L10n.Transcript.olderHistoryRoleScheduledTask
        }
    }
}
