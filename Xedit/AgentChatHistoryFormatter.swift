//
//  AgentChatHistoryFormatter.swift
//  WillDeep
//
//  TextKit renderer that bakes the chat transcript into a single
//  NSAttributedString, split out of
//  AgentChatHistoryTextView.swift in rc42:
//
//   - `AgentChatHistoryRenderer`: the TextKit baker. Builds role
//     avatars, applies bubble chrome via the `agentChatHistoryBubbleKind`
//     attribute the layout manager reads, attaches footer chrome from
//     `AgentChatHistoryFooterChrome`, and stamps copy buttons over fenced
//     code blocks. Cached by (messages-hash, isDark, expanded tool group
//     ids, hovered user message id) — repeated scroll updates re-use the
//     prior attributed string instead of re-rendering.
//
//  Markdown normalization lives in AgentMarkdownNormalizer.swift; tool-call
//  collapsed/expanded text lives in AgentChatToolSummaryFormatter.swift.
//
//  This file depends on three internal hooks still living in
//  AgentChatHistoryTextView.swift: the NSAttributedString.Key extension
//  (`agentChatHistoryBubbleKind` and siblings), the `AgentChatHistoryBubbleKind`
//  enum, and `AgentChatHistoryLayoutMetrics` for the user-bubble indent
//  constants. Those were flipped from `private` to internal in the same
//  refactor so they can land here.
//

import AppKit

// `AgentMarkdownTableFormatter` lives in its own file
// (AgentMarkdownTableFormatter.swift) since rc38 — both this renderer
// and `AgentAssistantMarkdownRenderer` in AgentModeView.swift call it,
// and pulling it out makes it discoverable + testable.

// MARK: - Renderer

/// Turns a list of `AgentMessage` into a single NSAttributedString
/// suitable for the chat-pane history NSTextView. Role headers are
/// rendered as small bold accent-colored labels; bodies use the
/// render Markdown for non-tool bodies, with tool outputs in monospace. Tool outputs
/// over 8 KB are truncated with a marker line so a 24 KB git-diff
/// dump doesn't bloat the visible transcript (users can still see
/// the full body via the per-message reader window).
enum AgentChatHistoryRenderer {
    enum MarkdownSpacing {
        static let headerToBody: CGFloat = 10
        static let bodyLine = AgentChatHistoryLayoutMetrics.bodyLineSpacing
        // Paragraph boundaries should keep the same reading rhythm as a
        // naturally wrapped body line. Extra paragraph spacing looked like
        // an empty row and made prose after a code block appear compressed.
        static let assistantParagraph: CGFloat = 0
        static let userParagraph: CGFloat = 7
        static let tableLine: CGFloat = 2
        /// Inline table 的"下 margin"——段落结束后到下一块的间距。
        static let tableParagraph: CGFloat = 10
        /// 用户反馈：表格紧贴前后正文段落不好读。给表格上下都撑开。
        /// `paragraphSpacingBefore` 是 macOS NSParagraphStyle 支持的字段，
        /// 在段落起始处插入额外空间，等价于 CSS 的 margin-top。
        static let tableParagraphBefore: CGFloat = 10
        /// 标题块的上下气垫。同一个段落同时设置 before / spacing，让
        /// `## 段标题` 像正经标题那样和上下文拉开距离，而不是黏在前一
        /// 行尾巴上。两个值刻意区分：标题"前"的空气比"后"略多一点，
        /// 视觉上重心向标题倾斜。
        static let headingParagraphBefore: CGFloat = 12
        static let headingParagraph: CGFloat = 6
        /// 代码块的上下 margin。用户反馈代码区贴正文太近。注意不能像
        /// 表格那样把 before/spacing 设在整个 range 上——代码行之间是
        /// 字面 \n（每行独立段落），整段设置会把行距也撑开；所以只对
        /// 首段设 before、末段设 spacing，见 applyCodeBlockVerticalMargins。
        static let codeBlockBefore: CGFloat = 10
        static let codeBlockAfter: CGFloat = 10
        static let toolLine: CGFloat = 1.5
    }

    /// Cache by (messages hash, isDark) so repeated SwiftUI updates
    /// during scroll (which don't change the message list) re-use
    /// the prior render. In production we're called from MainActor
    /// (SwiftUI re-renders, transcript reader window), but Swift
    /// Testing parallelizes `@Test` cases across worker threads and
    /// even though `render` itself is nominally MainActor-isolated
    /// under the module's default-isolation flag, Swift `enum`s with
    /// static stored properties don't actually inherit it (no `self`
    /// = no isolation context). Two concurrent test cases racing
    /// `cache[key] = …` corrupt the dictionary's storage and the
    /// next read sends `objectForKey:` to a tagged NSNumber via the
    /// Foundation bridge, crashing the host app and tripping the
    /// "** TEST FAILED **" tail even though every individual case
    /// passed. Wrap every cache touch in a recursive-safe lock so
    /// that concurrent access serializes without changing the
    /// observable API for any call site.
    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: NSAttributedString] = [:]
    private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 32

    private struct CacheKey: Hashable {
        let countAndHash: Int
        let isDark: Bool
        let baseFontSize: CGFloat
        let fontID: String
        let lineHeightMultiple: CGFloat
        let layoutWidth: CGFloat
    }

    /// Full per-message hash used to build the render cache key. We
    /// tried adding a (id, count, count, count) fingerprint short-cut
    /// in rc39 to avoid re-hashing big content strings on every render,
    /// but two assistant messages with the same id and same content
    /// length (the streaming "# One" → "# Two" edit-in-place case)
    /// collided and the cache returned the stale render. Swift's
    /// `String.hashValue` is randomized + already fast, so we just
    /// hash everything fresh — the cost is dominated by content bytes,
    /// which the render cache itself (one big NSAttributedString
    /// keyed by the full hash) prevents us from re-rendering anyway.
    private static func messageHash(_ m: AgentMessage) -> Int {
        var hasher = Hasher()
        hasher.combine(m.id)
        hasher.combine(m.role.rawValue)
        hasher.combine(m.content)
        // The transcript-event kind drives the rendered icon (e.g. Plan
        // notice vs model-change), so two same-content notices with
        // different events must not collide onto one cached render.
        hasher.combine(m.transcriptEvent?.rawValue)
        hasher.combine(m.images.count)
        for image in m.images {
            hasher.combine(image.id)
            hasher.combine(image.mimeType)
            // byteCount, never dataBase64: for file-backed images the
            // latter is a full disk read + base64 encode per call.
            hasher.combine(image.byteCount ?? -1)
            hasher.combine(image.source?.rawValue)
            hasher.combine(image.filePath)
            hasher.combine(image.model)
            hasher.combine(image.prompt)
            hasher.combine(image.createdAt)
        }
        hasher.combine(m.textAttachments.count)
        for attachment in m.textAttachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.filename)
            hasher.combine(attachment.content)
        }
        hasher.combine(m.toolCallID)
        // Both drive the delegation marker line above the user bubble; the
        // "unhonored" verdict lands after the turn ends, so a stale cached
        // render would otherwise keep showing the pre-verdict marker.
        hasher.combine(m.delegationPolicy?.rawValue)
        hasher.combine(m.delegationPolicyUnhonored)
        hasher.combine(m.createdAt)
        hasher.combine(m.reasoningContent)
        hasher.combine(m.usageTokens)
        hasher.combine(m.promptTokens)
        hasher.combine(m.completionTokens)
        hasher.combine(m.cachedPromptTokens)
        hasher.combine(m.cacheWritePromptTokens)
        hasher.combine(m.reasoningTokens)
        hasher.combine(m.elapsedSeconds)
        hasher.combine(m.managedRoute?.selectedModel)
        hasher.combine(m.managedRoute?.tier.rawValue)
        hasher.combine(m.managedRoute?.didEscalate)
        hasher.combine(m.managedRoute?.didFallback)
        hasher.combine(m.toolCalls.count)
        for call in m.toolCalls {
            hasher.combine(call.externalID)
            hasher.combine(call.toolName)
            hasher.combine(call.argumentsJSON)
        }
        // Tool outcome receipts are a render-time projection, not part of
        // toolCalls above. Without them in the key, a call resolving
        // running → succeeded/failed keeps the stale (badge-less) cached
        // render, so the outcome receipt never appears.
        if let receipts = m.settledToolReceipts {
            for (callID, status) in receipts.sorted(by: { $0.key < $1.key }) {
                hasher.combine(callID)
                hasher.combine(status.rawValue)
            }
        }
        // Workflow 卡片消息的 content 恒为空,全部展示数据挂在
        // workflowReport 上。不进 hash 的话 engine mutate report
        // (running → done、summary 填入)后 cache 直接命中旧渲染,
        // 卡片永远停在初始状态。
        if let report = m.workflowReport {
            hasher.combine(report.id)
            hasher.combine(report.status.rawValue)
            hasher.combine(report.displayTitle)
            hasher.combine(report.args)
            hasher.combine(report.summary)
            hasher.combine(report.totalUsageTokens)
            hasher.combine(report.finishedAt)
            hasher.combine(report.subAgents.count)
            for sub in report.subAgents {
                hasher.combine(sub.status.rawValue)
                hasher.combine(sub.label)
            }
        }
        return hasher.finalize()
    }

    private static func hashAssistantTurnContext(
        _ messages: [AgentMessage],
        includesCopyContent: Bool,
        into hasher: inout Hasher
    ) {
        for message in messages where message.role == .user || message.role == .assistant {
            hasher.combine(message.id)
            hasher.combine(message.role.rawValue)
            hasher.combine(message.createdAt)
            hasher.combine(message.usageTokens)
            hasher.combine(message.promptTokens)
            hasher.combine(message.completionTokens)
            hasher.combine(message.cachedPromptTokens)
            hasher.combine(message.cacheWritePromptTokens)
            hasher.combine(message.reasoningTokens)
            hasher.combine(message.elapsedSeconds)
            hasher.combine(message.managedRoute?.selectedModel)
            hasher.combine(message.managedRoute?.tier.rawValue)
            hasher.combine(message.managedRoute?.didEscalate)
            hasher.combine(message.managedRoute?.didFallback)
            if includesCopyContent, message.role == .assistant {
                hasher.combine(message.copyableContent)
            }
        }
    }

    static func render(
        messages: [AgentMessage],
        isDark: Bool,
        assistantTurnContextMessages: [AgentMessage]? = nil,
        isAssistantTurnActive: Bool = false,
        expandedToolGroupIDs: Set<String> = [],
        expandedProgressBlockIDs: Set<String> = [],
        hoveredUserMessageID: UUID? = nil,
        baseFontSize: CGFloat = NSFont.systemFontSize,
        fontID: String = AgentSettingsStore.chatFontIDDefault,
        lineHeightMultiple: CGFloat = AgentSettingsStore.chatLineHeightMultipleDefault,
        layoutWidth: CGFloat = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth,
        progressPlan: AgentPlan? = nil,
        latestTurnReportToolCount: Int? = nil
    ) -> NSAttributedString {
        let clampedSize = AgentSettingsStore.clampChatBaseFontSize(baseFontSize)
        let resolvedLayoutWidth = AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(layoutWidth)
        let turnContextMessages = assistantTurnContextMessages ?? messages
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(isAssistantTurnActive)
        hasher.combine(expandedToolGroupIDs.sorted())
        hasher.combine(expandedProgressBlockIDs.sorted())
        hasher.combine(hoveredUserMessageID)
        hasher.combine(latestTurnReportToolCount ?? -1)
        for m in messages {
            hasher.combine(messageHash(m))
        }
        hashAssistantTurnContext(
            turnContextMessages,
            includesCopyContent: !isAssistantTurnActive,
            into: &hasher
        )
        if let progressPlan {
            hasher.combine(progressPlan.status.rawValue)
            for step in progressPlan.steps {
                hasher.combine(step.id)
                hasher.combine(step.text)
                hasher.combine(step.status.rawValue)
            }
        }
        let key = CacheKey(
            countAndHash: hasher.finalize(),
            isDark: isDark,
            baseFontSize: clampedSize,
            fontID: fontID,
            lineHeightMultiple: lineHeightMultiple,
            layoutWidth: resolvedLayoutWidth
        )
        // Critical section #1: lookup. Lock has to cover the read
        // because Swift Dictionary's internal `_Variant.lookup(_:)`
        // can race against a concurrent insertion mid-resize on the
        // other goroutine.
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return hit }

        // Rendering itself is pure-functional from `messages` — no
        // shared state — so do it outside the lock to keep the
        // critical section short.
        let result = makeAttributedString(
            messages: messages,
            isDark: isDark,
            assistantTurnContextMessages: turnContextMessages,
            isAssistantTurnActive: isAssistantTurnActive,
            expandedToolGroupIDs: expandedToolGroupIDs,
            expandedProgressBlockIDs: expandedProgressBlockIDs,
            hoveredUserMessageID: hoveredUserMessageID,
            baseFontSize: clampedSize,
            fontID: fontID,
            lineHeightMultiple: lineHeightMultiple,
            layoutWidth: resolvedLayoutWidth,
            progressPlan: progressPlan,
            latestTurnReportToolCount: latestTurnReportToolCount
        )

        // Critical section #2: insertion + LRU eviction. If a parallel
        // call has already stored the same key, our second write is a
        // harmless overwrite with an identical value; the LRU order
        // just gains one redundant entry that the next eviction will
        // sweep. Not worth a separate compare-and-swap path.
        cacheLock.lock()
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        cacheLock.unlock()

        return result
    }

    private static func makeAttributedString(
        messages: [AgentMessage],
        isDark: Bool,
        assistantTurnContextMessages: [AgentMessage],
        isAssistantTurnActive: Bool,
        expandedToolGroupIDs: Set<String>,
        expandedProgressBlockIDs: Set<String>,
        hoveredUserMessageID: UUID?,
        baseFontSize: CGFloat,
        fontID: String,
        lineHeightMultiple: CGFloat,
        layoutWidth: CGFloat,
        progressPlan: AgentPlan?,
        latestTurnReportToolCount: Int?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Only the newest assistant/system message keeps its turn-progress
        // card. Every earlier turn used to keep rendering its own, so a long
        // session stacked up a column of near-identical "turn progress" boxes
        // whose counts were all stale. The progress block is still stripped
        // from every message's body below — dropping the card must not let the
        // raw protocol text back into the transcript.
        //
        // Deliberately not part of `render`'s cache key: which message is
        // newest is a pure function of `messages`, which the key already
        // covers via count plus per-message hash.
        let latestProgressCardMessageID = messages.last(where: {
            $0.role == .assistant || $0.role == .system
        })?.id
        // `bodyFont` / `monoFont` follow the user's chat-base size
        // knob (Q1=A) — they're used for message prose, plain tool
        // outputs, fenced code blocks, and inline-Markdown spans.
        // Message prose follows the user's body-size setting. Tool summaries
        // and section labels keep their compact AppKit scale so metadata does
        // not visually compete with the conversation itself.
        let fontChoice = AgentChatFontChoice.byID(fontID) ?? .system
        let bodyFont = fontChoice.nsFont(size: baseFontSize)
        let bodyLineSpacing = AgentChatTypography.lineSpacing(
            fontSize: baseFontSize,
            lineHeightMultiple: AgentSettingsStore.clampChatLineHeightMultiple(lineHeightMultiple)
        )
        let supportingFontSize = AgentDesign.chatSupportingFontSize(baseFontSize: baseFontSize)
        let supportingFont = fontChoice.nsFont(size: supportingFontSize)
        let supportingLineSpacing = AgentChatTypography.lineSpacing(
            fontSize: supportingFontSize,
            lineHeightMultiple: AgentSettingsStore.clampChatLineHeightMultiple(lineHeightMultiple)
        )
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
        let chromeMonoFont = NSFont.monospacedSystemFont(ofSize: supportingFontSize, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        // Status, tool activity, and footer statistics remain compact chrome.
        // Process prose itself follows the user's body-size setting exactly;
        // the half-line transition gap carries its hierarchy.
        let assistantStatusFont = supportingFont
        let bodyColor = NSColor.labelColor
        let assistantStatusColor = NSColor.secondaryLabelColor
        let assistantStatusDividerColor = AgentChatHistoryLayoutMetrics.assistantStatusDividerColor(
            isDark: isDark
        )
        let secondaryColor = NSColor.secondaryLabelColor
        let codeBackgroundColor = NSColor.controlBackgroundColor

        // Cap tool bodies on the visible transcript to keep TextKit's
        // layout work bounded. The reader window shows the full body.
        let toolBodyLimit = 8_000
        let latestAssistantMessageID = messages.reversed().first {
            $0.role == .assistant && ($0.hasRenderableTextContent || !$0.images.isEmpty)
        }?.id
        let latestAssistantTerminalSummaryMessageID = messages.reversed().first {
            $0.role == .assistant && (!$0.content.isEmpty || !$0.toolCalls.isEmpty)
        }?.id
        let assistantTurnPresentations = AgentAssistantTurnGrouping.presentations(
            in: assistantTurnContextMessages,
            visibleAssistantMessageIDs: Set(
                messages.lazy
                    .filter { $0.role == .assistant }
                    .map(\.id)
            )
        )
        let processToAnswerMessageIDs = processToAnswerMessageIDs(
            in: assistantTurnContextMessages,
            visibleMessages: messages
        )
        let settledMessageToolGrouping = assistantMessageToolCallGrouping(
            messages: messages,
            latestAssistantTerminalSummaryMessageID: latestAssistantTerminalSummaryMessageID
        )
        let activeUserMessageID = isAssistantTurnActive
            ? assistantTurnContextMessages.reversed().first(where: { $0.role == .user })?.id
            : nil

        var index = 0
        while index < messages.count {
            let message = messages[index]
            if let event = message.transcriptEvent {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n\n"))
                }
                appendTranscriptEventNotice(
                    event,
                    content: message.content,
                    to: result,
                    font: bodyFont,
                    color: secondaryColor
                )
                index += 1
                continue
            }
            // Skip empty assistant placeholders (the loop emits them
            // while a turn is waiting on tool calls).
            if message.role == .assistant
                && !message.hasRenderableTextContent
                && message.images.isEmpty
                && message.toolCalls.isEmpty {
                index += 1
                continue
            }

            if isToolCallOnly(message) {
                // Consecutive tool-only messages immediately after prose
                // belong to that prose goal and are rendered with it.
                if settledMessageToolGrouping.absorbedToolOnlyMessageIDs.contains(message.id) {
                    index += 1
                    continue
                }
                var groupMessages: [AgentMessage] = []
                while index < messages.count, isToolCallOnly(messages[index]) {
                    groupMessages.append(messages[index])
                    index += 1
                }
                let keepTerminalCalls = groupMessages.contains {
                    $0.id == latestAssistantTerminalSummaryMessageID
                }
                let group = ToolCallHistoryGroup(
                    messages: groupMessages,
                    calls: visibleToolCalls(
                        groupMessages.flatMap(\.toolCalls),
                        keepTerminalCalls: keepTerminalCalls
                    )
                )
                if group.calls.isEmpty {
                    continue
                }
                if result.length > 0 {
                    result.append(NSAttributedString(
                        string: "\n\n",
                        attributes: [
                            .font: bodyFont,
                            .paragraphStyle: bodyParagraphStyle(
                                for: .assistant,
                                layoutWidth: layoutWidth,
                                lineSpacing: bodyLineSpacing
                            ),
                        ]
                    ))
                }
                appendToolCallGroup(
                    group,
                    isExpanded: expandedToolGroupIDs.contains(group.id),
                    to: result,
                    bodyFont: bodyFont,
                    monoFont: chromeMonoFont,
                    lineSpacing: bodyLineSpacing,
                    secondaryColor: secondaryColor
                )
                continue
            }

            let turnPresentation = assistantTurnPresentations[message.id]
            if result.length > 0 {
                let separatorStart = result.length
                let previousMessage = index > 0 ? messages[index - 1] : nil
                let previousTurnPresentation = previousMessage.flatMap {
                    assistantTurnPresentations[$0.id]
                }
                let continuesSameAssistantTurn = message.role == .assistant
                    && previousMessage?.role == .assistant
                    && turnPresentation?.firstVisibleAssistantMessageID
                        == previousTurnPresentation?.firstVisibleAssistantMessageID
                let beginsFinalAssistantAnswer = continuesSameAssistantTurn
                    && turnPresentation?.isLastVisibleMessage(message) == true
                    && processToAnswerMessageIDs.contains(message.id)
                    && previousMessage.map {
                        previousTurnPresentation?.isLastVisibleMessage($0) == false
                    } == true
                // Providers often split one assistant turn into many short
                // progress messages around tool calls. They form one visual
                // activity timeline, so use a normal line break instead of
                // reserving a blank paragraph between every status update.
                result.append(NSAttributedString(
                    string: continuesSameAssistantTurn ? "\n" : "\n\n"
                ))
                if beginsFinalAssistantAnswer {
                    appendAssistantProcessToAnswerGap(
                        to: result,
                        bodyFont: bodyFont,
                        layoutWidth: layoutWidth,
                        lineHeightMultiple: lineHeightMultiple
                    )
                }
                if message.role == .user {
                    let style = NSMutableParagraphStyle()
                    style.paragraphSpacing = AgentChatHistoryLayoutMetrics.userTurnTopSpacing
                    result.addAttributes(
                        [
                            .font: bodyFont,
                            .paragraphStyle: style,
                        ],
                        range: NSRange(location: separatorStart + 1, length: 1)
                    )
                }
            }

            // Role header.
            let isToolCallOnly = message.role == .assistant
                && !message.hasRenderableTextContent
                && !message.toolCalls.isEmpty
            let isActiveAssistantTurn = message.role == .assistant
                && isAssistantTurnActive
                && turnPresentation?.userMessageID == activeUserMessageID
            if message.role != .assistant
                || turnPresentation == nil
                || turnPresentation?.isFirstVisibleMessage(message) == true {
                appendHeader(
                    for: turnPresentation?.summaryMessage ?? message,
                    isToolCallOnly: isToolCallOnly,
                    isStreamingAssistantTurn: isActiveAssistantTurn,
                    to: result,
                    headerFont: headerFont,
                    assistantStatusFont: assistantStatusFont,
                    assistantStatusColor: assistantStatusColor,
                    assistantStatusDividerColor: assistantStatusDividerColor,
                    secondaryColor: secondaryColor
                )
            }

            // Body.
            let userMessageContentStart = result.length
            let isHoveredUserMessage = message.role == .user && message.id == hoveredUserMessageID
            let useMono = (message.role == .tool)
            // User 消息如果是 composeAttachedPrompt 拼出来的 prelude(skill /
            // 文件 / workspace 注入),只在 UI 渲染时折叠成短 tag。原始
            // content 仍然完整保存在 message.content 里发给模型。
            let displaySourceContent: String = {
                guard message.role == .user else { return message.content }
                let display = AgentAttachedPromptDisplay.transform(message.content)
                let source = display.isSplicedPrelude ? display.visibleContent : message.content
                return AgentUserContentSplitter.split(source).visible
            }()
            let body: String
            var progressPresentation: AgentTurnProgressPresentation? = nil
            var handoffRelayPrompt: String? = nil
            if message.role == .workflowReport, let report = message.workflowReport {
                // Workflow 消息的 content 恒为空,状态/摘要都在 report 字段
                // 上。运行中的卡片由 AgentChatTranscript 的 SwiftUI 工作态
                // 表面渲染(不会进这里);进历史的已结束卡片烘焙成
                // 状态行 + 最终报告 markdown。1.155.0-rc9 前这里走通用
                // 空 body 分支,workflow 在 TextKit 历史里只剩一个光秃秃
                // 的 WFL 头像行 —— 研究报告/失败原因整体不可见。
                body = Self.workflowHistoryBody(for: report)
            } else if useMono, message.content.count > toolBodyLimit {
                let head = String(message.content.prefix(toolBodyLimit))
                let omitted = message.content.count - toolBodyLimit
                body = head + "\n\n…[truncated \(omitted) characters from this tool output — open the message reader for the full body]"
            } else if message.role == .assistant || message.role == .system {
                let extraction = AgentTurnProgressPresentation.extract(
                    from: displaySourceContent,
                    plan: progressPlan
                )
                // 上下文跑道交接里的 `NEXT PROMPT:` 段是给宿主看的接力
                // 指令,不是给人读的段落 —— 宿主本来就会压缩后自动拿它
                // 续跑。正文里去掉,改成 footer 上两个接力图标。
                let handoff = AgentContextRunwayHandoffDisplay.extract(from: extraction.visibleContent)
                body = handoff.visibleContent
                handoffRelayPrompt = handoff.relayPrompt
                progressPresentation = message.id == latestProgressCardMessageID
                    ? extraction.presentation
                    : nil
            } else {
                body = displaySourceContent
            }
            let activityHeadline = message.role == .assistant
                ? AgentActivityHeadlinePresentation.make(from: body)
                : nil
            let messageBodyFont = bodyFont
            let messageMonoFont = monoFont
            // 助手正文一律用正文黑：过程叙述和最终答案都是「模型说的话」。
            // 层次交给工具活动行的灰(secondaryLabelColor)和过程→答案之间
            // 的半行间距承担 —— 过程文字本身刷成灰会让整段回复看起来
            // 通篇发灰，反而分不出哪里是纯 chrome。
            let messageBodyColor = bodyColor
            let messageLineSpacing = bodyLineSpacing
            let messageParagraphStyle = bodyParagraphStyle(
                for: message.role,
                layoutWidth: layoutWidth,
                lineSpacing: messageLineSpacing
            )

            let hasUserTextBubbleContent = message.role == .user
                && (!message.textAttachments.isEmpty || !body.isEmpty)
            // `/subagent` / `/no-subagent` audit marker, above the bubble so a
            // reopened session still shows which directive the turn ran under.
            if message.role == .user, let delegationMarker = message.delegationMarkerTitle {
                result.append(NSAttributedString(
                    string: delegationMarker + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: max(9, baseFontSize - 3)),
                        .foregroundColor: secondaryColor,
                        .paragraphStyle: bodyParagraphStyle(for: message.role, layoutWidth: layoutWidth, lineSpacing: bodyLineSpacing),
                        .agentChatHistoryUserMessageID: message.id.uuidString,
                    ]
                ))
            }
            if message.role == .user, !message.images.isEmpty {
                let imageStyle = userImageParagraphStyle(layoutWidth: layoutWidth)
                let imageStart = result.length
                appendImageAttachments(
                    message.images,
                    to: result,
                    font: bodyFont,
                    secondaryColor: secondaryColor
                )
                let imageRange = NSRange(location: imageStart, length: result.length - imageStart)
                result.addAttributes(
                    [
                        .paragraphStyle: imageStyle,
                        .agentChatHistoryUserMessageID: message.id.uuidString,
                    ],
                    range: imageRange
                )
                if hasUserTextBubbleContent {
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: bodyFont,
                            .paragraphStyle: imageStyle,
                            .agentChatHistoryUserMessageID: message.id.uuidString,
                        ]
                    ))
                }
            }

            let messageBubbleStart = result.length
            var hasMessageBubbleContent = false

            if message.role == .user, !message.textAttachments.isEmpty {
                let attachmentStart = result.length
                appendTextAttachments(
                    message.textAttachments,
                    to: result,
                    font: bodyFont,
                    secondaryColor: secondaryColor
                )
                let attachmentRange = NSRange(location: attachmentStart, length: result.length - attachmentStart)
                applyBubbleChrome(
                    kind: bubbleKind(for: message.role),
                    to: result,
                    range: attachmentRange,
                    paragraphStyle: bodyParagraphStyle(for: message.role, layoutWidth: layoutWidth, lineSpacing: bodyLineSpacing),
                    userMessageID: message.id,
                    foregroundColor: nil
                )
                hasMessageBubbleContent = true
            }

            if !body.isEmpty || progressPresentation != nil {
                if hasMessageBubbleContent {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                }
                let bodyStart = result.length
                if !body.isEmpty {
                    if useMono {
                        appendPlainBody(body, to: result, font: messageMonoFont, color: messageBodyColor)
                    } else if message.role == .user {
                        appendPlainBody(
                            AgentLongTokenBreaker.inject(into: body),
                            to: result,
                            font: bodyFont,
                            color: bodyColor
                        )
                    } else if let activityHeadline {
                        appendActivityHeadline(
                            activityHeadline,
                            to: result,
                            font: messageBodyFont,
                            color: secondaryColor
                        )
                    } else {
                        appendMarkdownBody(
                            body,
                            to: result,
                            role: message.role,
                            bodyFont: messageBodyFont,
                            monoFont: messageMonoFont,
                            bodyColor: messageBodyColor,
                            secondaryColor: secondaryColor,
                            codeBackgroundColor: codeBackgroundColor,
                            isDark: isDark,
                            layoutWidth: layoutWidth
                        )
                    }
                }
                if let progressPresentation {
                    if result.length > bodyStart {
                        result.append(NSAttributedString(
                            string: "\n",
                            attributes: [
                                .font: NSFont.systemFont(
                                    ofSize: AgentTurnProgressLayoutMetrics.contentSpacing
                                ),
                            ]
                        ))
                    }
                    let progressID = message.id.uuidString
                    result.append(AgentTurnProgressHistoryRenderer.attributedString(
                        progressPresentation,
                        id: progressID,
                        isExpanded: expandedProgressBlockIDs.contains(progressID),
                        showsPlanAction: progressPlan != nil,
                        baseFontSize: baseFontSize
                    ))
                }
                let bodyRange = NSRange(location: bodyStart, length: result.length - bodyStart)
                applyBubbleChrome(
                    kind: bubbleKind(for: message.role),
                    to: result,
                    range: bodyRange,
                    paragraphStyle: messageParagraphStyle,
                    userMessageID: message.role == .user ? message.id : nil,
                    foregroundColor: nil
                )
                hasMessageBubbleContent = true
            }

            if message.role == .assistant, !message.images.isEmpty {
                if hasMessageBubbleContent {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                }
                let imageStart = result.length
                appendImageAttachments(
                    message.images,
                    to: result,
                    font: bodyFont,
                    secondaryColor: secondaryColor,
                    presentation: .content(layoutWidth: layoutWidth)
                )
                let imageRange = NSRange(location: imageStart, length: result.length - imageStart)
                applyBubbleChrome(
                    kind: bubbleKind(for: message.role),
                    to: result,
                    range: imageRange,
                    paragraphStyle: bodyParagraphStyle(for: message.role, layoutWidth: layoutWidth, lineSpacing: bodyLineSpacing),
                    foregroundColor: nil
                )
                hasMessageBubbleContent = true
            }

            // Keep settled activity beside the prose that initiated it. A
            // provider may emit many prose→tool→prose cycles in one turn; if
            // all tool rows are moved behind the final prose, the transcript
            // reads as “goal, goal, goal, every result”. Preserving each
            // message-local group gives the chronological “goal, result,
            // goal, result” rhythm users actually followed while it ran.
            let inlineGroup = message.role == .assistant
                ? settledMessageToolGrouping.groupsByAnchorMessageID[message.id]
                : nil
            let inlineToolCalls = inlineGroup?.calls ?? []
            if let inlineGroup, !inlineToolCalls.isEmpty {
                if hasMessageBubbleContent {
                    // 工具活动行和发起它的那段正文之间只用一个普通换行,
                    // 与活动行下方到下一段正文的间距对称(同回合的后续
                    // assistant 消息同样只隔一个 "\n")。此前这里插 0.7×
                    // 字号的 metadata spacer,上大下小,活动行看起来被推
                    // 离了发起它的那句话。统计 footer 仍保留那道 spacer:
                    // 它是回合末尾的元数据,和正文拉开是对的。
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: bodyFont,
                            .paragraphStyle: bodyParagraphStyle(
                                for: .assistant,
                                layoutWidth: layoutWidth,
                                lineSpacing: bodyLineSpacing
                            ),
                        ]
                    ))
                }
                appendToolCallGroup(
                    inlineGroup,
                    isExpanded: expandedToolGroupIDs.contains(inlineGroup.id),
                    to: result,
                    bodyFont: bodyFont,
                    monoFont: chromeMonoFont,
                    lineSpacing: bodyLineSpacing,
                    secondaryColor: secondaryColor
                )
            }

            let footerMessage = message
            let isAssistantTurnFooter = message.role != .assistant
                || turnPresentation == nil
                || turnPresentation?.isLastVisibleMessage(footerMessage) == true
            if isAssistantTurnFooter,
               !isActiveAssistantTurn,
               activityHeadline == nil,
                shouldShowFooter(for: message, body: body) {
                let messageBodyEnd = result.length
                let assistantMetadataSpacerRange: NSRange?
                if message.role == .assistant,
                   hasMessageBubbleContent,
                   inlineToolCalls.isEmpty {
                    assistantMetadataSpacerRange = appendAssistantMetadataGroupSeparator(
                        to: result,
                        bodyFont: bodyFont,
                        layoutWidth: layoutWidth,
                        lineSpacing: bodyLineSpacing
                    )
                } else {
                    assistantMetadataSpacerRange = nil
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: bodyFont,
                            .paragraphStyle: bodyParagraphStyle(
                                for: message.role,
                                layoutWidth: layoutWidth,
                                lineSpacing: bodyLineSpacing
                            ),
                        ]
                    ))
                }
                let footerStart = result.length
                appendMessageFooter(
                    for: turnPresentation?.summaryMessage ?? message,
                    isLatestAssistant: message.id == latestAssistantMessageID,
                    isVisible: message.role != .user || isHoveredUserMessage,
                    turnReportToolCount: latestTurnReportToolCount,
                    // 回合还在跑的时候不给接力按钮:宿主此刻多半正在压缩
                    // 后自动续跑,这两个图标一闪而过只会让人以为要自己动手。
                    handoffRelayPrompt: isAssistantTurnActive ? nil : handoffRelayPrompt,
                    layoutWidth: layoutWidth,
                    baseFontSize: baseFontSize,
                    lineSpacing: supportingLineSpacing,
                    to: result
                )
                if hasMessageBubbleContent && inlineToolCalls.isEmpty {
                    let bubbleEnd = message.role == .user ? messageBodyEnd : result.length
                    let messageRange = NSRange(location: messageBubbleStart, length: bubbleEnd - messageBubbleStart)
                    // Codex-style user input keeps the faint rounded surface
                    // around the input itself. The reserved metadata/action
                    // row lives underneath it and only changes opacity on
                    // hover, so neither the bubble nor surrounding messages
                    // jump when the footer appears.
                    applyBubbleChrome(
                        kind: bubbleKind(for: message.role),
                        to: result,
                        range: messageRange,
                        paragraphStyle: bodyParagraphStyle(for: message.role, layoutWidth: layoutWidth, lineSpacing: bodyLineSpacing),
                        userMessageID: message.role == .user ? message.id : nil,
                        foregroundColor: nil
                    )
                    if let assistantMetadataSpacerRange {
                        applyAssistantMetadataSpacerStyle(
                            to: result,
                            range: assistantMetadataSpacerRange,
                            bodyFont: bodyFont,
                            layoutWidth: layoutWidth,
                            lineSpacing: bodyLineSpacing
                        )
                    }
                    let footerRange = NSRange(location: footerStart, length: result.length - footerStart)
                    result.addAttribute(
                        .paragraphStyle,
                        value: footerParagraphStyle(
                            for: message.role,
                            layoutWidth: layoutWidth,
                            lineSpacing: supportingLineSpacing
                        ),
                        range: footerRange
                    )
                }
                if message.role == .user {
                    result.addAttribute(
                        .agentChatHistoryUserMessageID,
                        value: message.id.uuidString,
                        range: NSRange(
                            location: userMessageContentStart,
                            length: result.length - userMessageContentStart
                        )
                    )
                }
            }

            index += 1
        }

        stripSwiftUIRuntimeAttributes(from: result)
        return result
    }

    /// `AttributedString(markdown:)` 桥接出来的 run 上残留着 Markdown
    /// presentation intent(行内代码的 `.code` 等)和 `SwiftUI.Font` 一类
    /// SwiftUI 作用域属性。macOS 26 起,字符串进入 `NSTextStorage` 时的
    /// `fixAttributes` 会按这些残留属性**重新解析字体**——`.code` intent
    /// 解析成 userFixedPitchFont(Menlo),把我们精心钉好的 SF Mono +
    /// PingFang CJK fallback 整体覆盖;Menlo 没有中文字形,于是
    /// `SSO-产品架构设计.key` 在 transcript 里塌成 `SSO-.key`(2026-09-01
    /// 用户截图,同款塌字第四次复发的真凶;前三次修复都停留在 NSFont 层,
    /// 在 macOS 26 上被 fixAttributes 这条新通道整体旁路)。渲染管线各
    /// pass 在此之前已消费完 intent(`isInlineCode`),TextKit 绘制只认
    /// NSFont/NSColor,所以渲染收尾把这些"会被 fixAttributes 重新解释"
    /// 的属性整串剥掉,改写便无从发生。
    private static let markdownParseLeftoverKeys: [NSAttributedString.Key] = [
        NSAttributedString.Key("NSInlinePresentationIntent"),
        NSAttributedString.Key("NSPresentationIntent"),
    ]

    private static func stripSwiftUIRuntimeAttributes(from attributed: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }
        var keys: Set<NSAttributedString.Key> = Set(markdownParseLeftoverKeys)
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, _, _ in
            for key in attributes.keys where key.rawValue.hasPrefix("SwiftUI.") {
                keys.insert(key)
            }
        }
        for key in keys {
            attributed.removeAttribute(key, range: fullRange)
        }
    }

    private static func appendAssistantProcessToAnswerGap(
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        layoutWidth: CGFloat,
        lineHeightMultiple: CGFloat
    ) {
        let gapHeight = AgentChatTypography.processToAnswerGap(
            fontSize: bodyFont.pointSize,
            lineHeightMultiple: AgentSettingsStore.clampChatLineHeightMultiple(lineHeightMultiple)
        )
        let style = bodyParagraphStyle(
            for: .assistant,
            layoutWidth: layoutWidth,
            lineSpacing: 0
        ).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.minimumLineHeight = gapHeight
        style.maximumLineHeight = gapHeight
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        let spacerFont = NSFont(
            descriptor: bodyFont.fontDescriptor,
            size: max(1, gapHeight)
        ) ?? NSFont.systemFont(ofSize: max(1, gapHeight))
        result.append(NSAttributedString(
            string: "\n",
            attributes: [
                .font: spacerFont,
                .foregroundColor: NSColor.clear,
                .paragraphStyle: style,
            ]
        ))
    }

    /// A final answer gets extra breathing room only when it follows a real
    /// tool-driven process. Consecutive prose updates without tool activity
    /// are still one compact process list and keep their ordinary line break.
    private static func processToAnswerMessageIDs(
        in contextMessages: [AgentMessage],
        visibleMessages: [AgentMessage]
    ) -> Set<AgentMessage.ID> {
        let visibleIDs = Set(visibleMessages.lazy.map(\.id))
        var result: Set<AgentMessage.ID> = []
        var visibleAssistantIDs: [AgentMessage.ID] = []
        var hasToolActivity = false

        func finishTurn() {
            if hasToolActivity, visibleAssistantIDs.count > 1,
               let finalVisibleID = visibleAssistantIDs.last {
                result.insert(finalVisibleID)
            }
            visibleAssistantIDs.removeAll(keepingCapacity: true)
            hasToolActivity = false
        }

        for message in contextMessages {
            if message.role == .user {
                finishTurn()
                continue
            }
            guard message.role == .assistant else { continue }
            hasToolActivity = hasToolActivity || !message.toolCalls.isEmpty
            if visibleIDs.contains(message.id),
               message.hasRenderableTextContent || !message.images.isEmpty {
                visibleAssistantIDs.append(message.id)
            }
        }
        finishTurn()
        return result
    }

    private static func appendAssistantMetadataGroupSeparator(
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        layoutWidth: CGFloat,
        lineSpacing: CGFloat
    ) -> NSRange {
        let bodyStyle = bodyParagraphStyle(
            for: .assistant,
            layoutWidth: layoutWidth,
            lineSpacing: lineSpacing
        )
        result.append(NSAttributedString(
            string: "\n",
            attributes: [
                .font: bodyFont,
                .paragraphStyle: bodyStyle,
            ]
        ))

        let spacerRange = NSRange(location: result.length, length: 1)
        result.append(NSAttributedString(string: "\n"))
        applyAssistantMetadataSpacerStyle(
            to: result,
            range: spacerRange,
            bodyFont: bodyFont,
            layoutWidth: layoutWidth,
            lineSpacing: lineSpacing
        )
        return spacerRange
    }

    private static func applyAssistantMetadataSpacerStyle(
        to result: NSMutableAttributedString,
        range: NSRange,
        bodyFont: NSFont,
        layoutWidth: CGFloat,
        lineSpacing: CGFloat
    ) {
        let spacerHeight = AgentDesign.assistantMetadataTopSpacing(
            baseFontSize: bodyFont.pointSize
        )
        let spacerStyle = bodyParagraphStyle(
            for: .assistant,
            layoutWidth: layoutWidth,
            lineSpacing: lineSpacing
        ).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        spacerStyle.minimumLineHeight = spacerHeight
        spacerStyle.maximumLineHeight = spacerHeight
        spacerStyle.lineSpacing = 0
        spacerStyle.paragraphSpacing = 0
        let spacerFont = NSFont(
            descriptor: bodyFont.fontDescriptor,
            size: max(1, spacerHeight)
        ) ?? NSFont.systemFont(ofSize: max(1, spacerHeight))
        result.addAttributes(
            [
                .font: spacerFont,
                .paragraphStyle: spacerStyle,
            ],
            range: range
        )
    }

    struct ToolCallHistoryGroup {
        let id: String
        let calls: [AgentMessageToolCall]
        /// Terminal receipts (externalID → 成/败/拒) harvested from the
        /// sibling `.tool` result messages upstream. Empty for legacy
        /// sessions or in-flight groups; drives the compact outcome suffix.
        let receipts: [String: AgentToolCallStatus]

        init(
            messages: [AgentMessage],
            calls: [AgentMessageToolCall]? = nil
        ) {
            id = messages.map { $0.id.uuidString }.joined(separator: ":")
            self.calls = calls ?? messages.flatMap(\.toolCalls)
            self.receipts = Self.mergedReceipts(from: messages)
        }

        /// Tool calls that came in *alongside* an assistant message's
        /// prose (not as a separate tool-call-only assistant turn).
        /// Keyed by the host message id so expand/collapse state is
        /// stable across re-renders of the same conversation.
        init(
            inlineMessageIDs: [UUID],
            calls: [AgentMessageToolCall],
            receipts: [String: AgentToolCallStatus] = [:]
        ) {
            id = "inline:" + inlineMessageIDs.map(\.uuidString).joined(separator: ":")
            self.calls = calls
            self.receipts = receipts
        }

        private static func mergedReceipts(
            from messages: [AgentMessage]
        ) -> [String: AgentToolCallStatus] {
            var merged: [String: AgentToolCallStatus] = [:]
            for message in messages {
                guard let receipts = message.settledToolReceipts else { continue }
                merged.merge(receipts) { _, new in new }
            }
            return merged
        }

        /// One-line exceptional outcome for the whole group. Successful work
        /// already reads naturally as “修改了1个文件”等动作摘要，追加“完成”
        /// both repeats the same fact and appears inconsistently in legacy
        /// turns that do not carry receipts. Failures and denials remain as
        /// parenthesized counts without an alarm-like cross glyph.
        var outcomeBadge: String? {
            guard !receipts.isEmpty else { return nil }
            let statuses = receipts.values
            let failed = statuses.filter { $0 == .failed }.count
            let denied = statuses.filter { $0 == .denied }.count
            if failed > 0 { return "(\(failed)条失败)" }
            if denied > 0 { return "(\(denied)条已拒绝)" }
            return nil
        }
    }

    /// 已结束 workflow 卡片的 TextKit 历史正文:一行状态摘要(标题·状态·
    /// agent 数·token),空一段接用户 args,再接 engine synthesize 出的
    /// 最终报告 markdown。internal 而非 private —— 单测直接验证渲染内容。
    static func workflowHistoryBody(for report: WorkflowReport) -> String {
        var statusParts: [String] = ["**\(report.displayTitle)**", workflowStatusLabel(report.status)]
        if !report.subAgents.isEmpty {
            statusParts.append(
                L10n.WorkflowCard.agentsLabel(done: report.completedAgentCount, total: report.subAgents.count)
            )
        }
        if report.totalUsageTokens > 0 {
            statusParts.append(L10n.WorkflowCard.totalTokens(report.totalUsageTokens))
        }
        var blocks: [String] = [statusParts.joined(separator: " · ")]
        let args = report.args.trimmingCharacters(in: .whitespacesAndNewlines)
        if !args.isEmpty {
            blocks.append(args)
        }
        let summary = report.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            blocks.append(summary)
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func workflowStatusLabel(_ status: WorkflowReport.Status) -> String {
        switch status {
        case .planning: return L10n.WorkflowCard.statusPlanning
        case .running: return L10n.WorkflowCard.statusRunning
        case .done: return L10n.WorkflowCard.statusDone
        case .failed: return L10n.WorkflowCard.statusFailed
        case .cancelled: return L10n.WorkflowCard.statusCancelled
        }
    }

    private static func isToolCallOnly(_ message: AgentMessage) -> Bool {
        message.role == .assistant
            && !message.hasRenderableTextContent
            && !message.toolCalls.isEmpty
    }

    private static func visibleToolCalls(
        _ calls: [AgentMessageToolCall],
        keepTerminalCalls: Bool
    ) -> [AgentMessageToolCall] {
        guard !keepTerminalCalls else { return calls }
        return calls.filter { !AgentTerminalToolNames.isVisibleTerminalOperation($0.toolName) }
    }

    private struct AssistantMessageToolCallGrouping {
        var groupsByAnchorMessageID: [AgentMessage.ID: ToolCallHistoryGroup] = [:]
        var absorbedToolOnlyMessageIDs: Set<AgentMessage.ID> = []
    }

    /// Build one settled activity group for each prose goal. A provider may
    /// put some calls on the prose message and the rest in immediately
    /// following tool-only messages, so those adjacent records stay together.
    /// The next prose message starts a new goal/result segment.
    private static func assistantMessageToolCallGrouping(
        messages: [AgentMessage],
        latestAssistantTerminalSummaryMessageID: AgentMessage.ID?
    ) -> AssistantMessageToolCallGrouping {
        var result = AssistantMessageToolCallGrouping()
        for index in messages.indices {
            let message = messages[index]
            guard message.role == .assistant,
                  message.hasRenderableTextContent || !message.images.isEmpty else {
                continue
            }

            var toolMessages = message.toolCalls.isEmpty ? [] : [message]
            var nextIndex = messages.index(after: index)
            while nextIndex < messages.endIndex, isToolCallOnly(messages[nextIndex]) {
                toolMessages.append(messages[nextIndex])
                result.absorbedToolOnlyMessageIDs.insert(messages[nextIndex].id)
                nextIndex = messages.index(after: nextIndex)
            }
            guard !toolMessages.isEmpty else { continue }

            let calls = toolMessages.flatMap { toolMessage in
                visibleToolCalls(
                    toolMessage.toolCalls,
                    keepTerminalCalls: toolMessage.id == latestAssistantTerminalSummaryMessageID
                )
            }
            guard !calls.isEmpty else { continue }

            let receipts = toolMessages.reduce(
                into: [String: AgentToolCallStatus]()
            ) { accumulated, toolMessage in
                guard let settled = toolMessage.settledToolReceipts else { return }
                accumulated.merge(settled) { _, new in new }
            }
            result.groupsByAnchorMessageID[message.id] = ToolCallHistoryGroup(
                inlineMessageIDs: toolMessages.map(\.id),
                calls: calls,
                receipts: receipts
            )
        }
        return result
    }

    private static func appendPlainBody(
        _ body: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor
    ) {
        result.append(NSAttributedString(
            string: body,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        ))
    }

    private static func highlightedCodeBlock(
        _ text: String,
        languageHint: String?,
        monoFont: NSFont,
        bodyColor: NSColor,
        codeBackgroundColor: NSColor,
        isDark: Bool
    ) -> NSAttributedString {
        let highlighted: NSMutableAttributedString
        if let language = codeLanguage(for: languageHint) {
            highlighted = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlightSync(
                text,
                language: language,
                theme: isDark ? .graphite : .paper,
                font: monoFont
            ))
        } else {
            highlighted = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: monoFont,
                    .foregroundColor: bodyColor,
                ]
            )
        }
        let fullRange = NSRange(location: 0, length: highlighted.length)
        if fullRange.length > 0 {
            highlighted.addAttributes([
                .font: monoFont,
            ], range: fullRange)
        }
        _ = codeBackgroundColor
        return highlighted
    }

    private static func codeLanguage(for hint: String?) -> Language? {
        guard let hint else { return nil }
        let token = hint
            .split { $0.isWhitespace }
            .first
            .map(String.init)?
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "`:;,.()[]{}"))
        guard let token, !token.isEmpty else { return nil }
        switch token {
        case "swift": return .swift
        case "py", "python": return .python
        case "rb", "ruby": return .ruby
        case "php": return .php
        case "java": return .java
        case "js", "jsx", "javascript": return .javascript
        case "ts", "tsx", "typescript": return .typescript
        case "kt", "kts", "kotlin": return .kotlin
        case "scala", "sc": return .scala
        case "dart": return .dart
        case "go", "golang": return .go
        case "html": return .html
        case "css": return .css
        case "vue": return .vue
        case "svelte": return .svelte
        case "astro": return .astro
        case "json", "jsonc", "jsonl": return .json
        case "md", "markdown": return .markdown
        case "sh", "shell", "bash", "zsh": return .shell
        case "ps1", "powershell", "pwsh": return .powershell
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "xml": return .xml
        case "sql": return .sql
        case "dockerfile": return .dockerfile
        case "make", "makefile": return .makefile
        case "cmake": return .cmake
        case "ini", "conf": return .ini
        case "env", "dotenv": return .env
        case "rs", "rust": return .rust
        case "c": return .c
        case "cc", "cpp", "cxx", "c++": return .cpp
        case "m", "objc", "objective-c": return .objectiveC
        case "mm", "objcpp", "objective-c++": return .objectiveCpp
        case "cs", "csharp", "c#": return .csharp
        case "fs", "fsi", "fsx", "fsharp", "f#": return .fsharp
        case "vb", "visualbasic": return .visualBasic
        case "lua": return .lua
        case "pl", "pm", "perl": return .perl
        case "r": return .r
        case "jl", "julia": return .julia
        case "ex", "exs", "elixir", "heex": return .elixir
        case "erl", "erlang": return .erlang
        case "hs", "haskell": return .haskell
        case "clj", "cljs", "clojure", "edn": return .clojure
        case "tf", "tfvars", "hcl", "terraform": return .terraform
        case "gql", "graphql": return .graphql
        case "proto", "protobuf": return .protobuf
        case "nginx": return .nginx
        case "apache", "htaccess": return .apache
        case "nix": return .nix
        case "sol", "solidity": return .solidity
        case "zig": return .zig
        case "nim": return .nim
        case "d": return .dlang
        case "matlab": return .matlab
        case "f90", "fortran": return .fortran
        case "pas", "pascal": return .pascal
        case "asm", "assembly": return .assembly
        case "diff", "patch", "udiff": return .diff
        default: return nil
        }
    }

    private static func appendMarkdownBody(
        _ source: String,
        to result: NSMutableAttributedString,
        role: AgentRole,
        bodyFont: NSFont,
        monoFont: NSFont,
        bodyColor: NSColor,
        secondaryColor: NSColor,
        codeBackgroundColor: NSColor,
        isDark: Bool,
        layoutWidth: CGFloat
    ) {
        let normalized = AgentMarkdownNormalizer.normalizedForChatRendering(source)
        let safe = AgentLongTokenBreaker.inject(into: normalized)
        let blocks = MarkdownPreviewParser.blocks(from: safe)
        guard !blocks.isEmpty else {
            result.append(inlineMarkdownAttributedString(safe, baseFont: bodyFont, color: bodyColor))
            return
        }

        var didAppendBlock = false
        var tableBlockIndex = 0
        func appendBlockSeparator() {
            if didAppendBlock {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: bodyColor,
                    ]
                ))
            }
            didAppendBlock = true
        }

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                appendBlockSeparator()
                let headingStart = result.length
                result.append(inlineMarkdownAttributedString(
                    block.text,
                    baseFont: headingFont(level: level, baseFont: bodyFont),
                    color: bodyColor
                ))
                // Tag the heading range so `applyBubbleChrome` can
                // promote its paragraph style to one with extra top /
                // bottom spacing — see `headingParagraphStyle`.
                if role != .user {
                    result.addAttribute(
                        .agentChatHistoryHeadingLevel,
                        value: NSNumber(value: level),
                        range: NSRange(location: headingStart, length: result.length - headingStart)
                    )
                }

            case .paragraph:
                appendBlockSeparator()
                result.append(inlineMarkdownAttributedString(
                    block.text,
                    baseFont: bodyFont,
                    color: bodyColor
                ))

            case .quote:
                appendBlockSeparator()
                result.append(NSAttributedString(
                    string: "> ",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
                result.append(inlineMarkdownAttributedString(
                    block.text,
                    baseFont: bodyFont,
                    color: secondaryColor
                ))

            case .unorderedList:
                appendBlockSeparator()
                let listStart = result.length
                result.append(NSAttributedString(
                    string: "\(bulletGlyph(for: block.indent)) ",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
                result.append(inlineMarkdownAttributedString(
                    block.text,
                    baseFont: bodyFont,
                    color: bodyColor
                ))
                result.addAttribute(
                    .agentChatHistoryListDepth,
                    value: NSNumber(value: block.indent),
                    range: NSRange(location: listStart, length: result.length - listStart)
                )

            case .orderedList:
                appendBlockSeparator()
                let listStart = result.length
                result.append(NSAttributedString(
                    string: "\(block.orderedListNumber ?? 1). ",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
                result.append(inlineMarkdownAttributedString(
                    block.text,
                    baseFont: bodyFont,
                    color: bodyColor
                ))
                result.addAttribute(
                    .agentChatHistoryListDepth,
                    value: NSNumber(value: block.indent),
                    range: NSRange(location: listStart, length: result.length - listStart)
                )

            case .code:
                let hadPreviousBlock = didAppendBlock
                appendBlockSeparator()
                // user 气泡不打 codeBlockID 标签（applyChrome 只给非 user
                // 角色加段落级 margin），保留旧的小 spacer 行兜底；助手/
                // 系统气泡的上下气垫由 applyCodeBlockVerticalMargins 的
                // paragraphSpacingBefore/After 承担，不再叠 spacer。
                if hadPreviousBlock && role == .user {
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 4),
                            .foregroundColor: bodyColor,
                        ]
                    ))
                }
                let codeBlockStart = result.length
                let codeBlockID = codeBlockStart
                let language = block.info?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayLanguage = (language?.isEmpty == false) ? language! : "code"
                let codeHeaderFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
                result.append(NSAttributedString(
                    string: "\(displayLanguage)  ",
                    attributes: [
                        .font: codeHeaderFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
                // block.text 是从**已经插过零宽断点**的 `safe` 里解析出来
                // 的(见 appendMarkdownBody),直接当复制载荷会把 U+200B 一起
                // 送进剪贴板——粘到终端或编译器里就是一串查无此因的报错。
                // 渲染仍用带断点的 block.text,只有复制走净化版。
                result.append(AgentChatHistoryCodeCopyChrome.button(
                    copied: false,
                    code: AgentCopyTextSanitizer.sanitize(block.text),
                    font: codeHeaderFont,
                    color: secondaryColor
                ))
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: codeHeaderFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
                let codeBodyStart = result.length
                result.append(highlightedCodeBlock(
                    block.text,
                    languageHint: block.info,
                    monoFont: monoFont,
                    bodyColor: bodyColor,
                    codeBackgroundColor: codeBackgroundColor,
                    isDark: isDark
                ))
                if role != .user {
                    result.addAttribute(
                        .agentChatHistoryCodeBlockID,
                        value: NSNumber(value: codeBlockID),
                        range: NSRange(location: codeBlockStart, length: result.length - codeBlockStart)
                    )
                    result.addAttribute(
                        .agentChatHistoryCodeBlockBodyID,
                        value: NSNumber(value: codeBlockID),
                        range: NSRange(location: codeBodyStart, length: result.length - codeBodyStart)
                    )
                }

            case .divider:
                appendBlockSeparator()
                result.append(NSAttributedString(
                    string: "────────────────────────",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))

            case .image:
                appendBlockSeparator()
                appendMarkdownImageBlock(
                    alt: block.text,
                    source: block.imageSource ?? "",
                    to: result,
                    bodyFont: bodyFont,
                    secondaryColor: secondaryColor,
                    layoutWidth: layoutWidth
                )

            case .table:
                appendBlockSeparator()
                if let headers = block.tableHeaders, let rows = block.tableRows {
                    let layout = AgentMarkdownTableFormatter.formattedWithSpans(
                        headers: headers,
                        rows: rows
                    )
                    let table = layout.text
                    if !table.isEmpty {
                        let tableBlockStart = result.length
                        let tableBlockID = tableBlockIndex
                        tableBlockIndex += 1
                        result.append(NSAttributedString(
                            string: table,
                            attributes: [
                                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                .foregroundColor: bodyColor,
                            ]
                        ))
                        // Bake the cells' inline Markdown into the aligned
                        // monospaced layout. Spans are Character offsets into
                        // `table`; convert to UTF-16 NSRanges shifted by the
                        // table's start offset in `result`.
                        for span in layout.spans {
                            guard let charLower = table.index(
                                table.startIndex,
                                offsetBy: span.range.lowerBound,
                                limitedBy: table.endIndex
                            ), let charUpper = table.index(
                                table.startIndex,
                                offsetBy: span.range.upperBound,
                                limitedBy: table.endIndex
                            ) else { continue }
                            let local = NSRange(charLower..<charUpper, in: table)
                            let range = NSRange(
                                location: tableBlockStart + local.location,
                                length: local.length
                            )
                            switch span.style {
                            case .bold:
                                result.addAttribute(
                                    .font,
                                    value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                                    range: range
                                )
                            case .italic:
                                let italic = NSFontManager.shared.convert(
                                    NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                    toHaveTrait: .italicFontMask
                                )
                                result.addAttribute(.font, value: italic, range: range)
                            case .code:
                                result.addAttribute(
                                    .backgroundColor,
                                    value: NSColor.labelColor.withAlphaComponent(0.08),
                                    range: range
                                )
                            }
                        }
                        if role != .user {
                            let tableRange = NSRange(location: tableBlockStart, length: result.length - tableBlockStart)
                            result.addAttribute(
                                .agentChatHistoryTableBlockID,
                                value: NSNumber(value: tableBlockID),
                                range: tableRange
                            )
                            result.addAttribute(
                                .agentChatHistoryTablePayload,
                                value: AgentMarkdownTablePayload(headers: headers, rows: rows),
                                range: tableRange
                            )
                            result.addAttribute(
                                .link,
                                value: AgentChatHistoryTableLink.value,
                                range: tableRange
                            )
                            // A small "open in standalone window" icon at the
                            // table's bottom-right, instead of a text link.
                            // Same tap target + payload as before; the leading
                            // newline keeps it on its own line under the table.
                            let linkStart = result.length
                            result.append(NSAttributedString(string: "\n", attributes: [
                                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                            ]))
                            result.append(AgentChatHistoryTableChrome.openInWindowIcon(
                                pointSize: 12,
                                color: NSColor.secondaryLabelColor
                            ))
                            let linkRange = NSRange(location: linkStart, length: result.length - linkStart)
                            result.addAttributes(
                                [
                                    .link: AgentChatHistoryTableLink.value,
                                    .cursor: NSCursor.arrow,
                                    .agentChatHistoryTablePayload: AgentMarkdownTablePayload(headers: headers, rows: rows),
                                    .toolTip: String(
                                        localized: "agent.markdown-table.open-link",
                                        defaultValue: "Open table in standalone window"
                                    ),
                                ],
                                range: linkRange
                            )
                        }
                    }
                }
            }
        }
    }

    private static func inlineMarkdownAttributedString(
        _ raw: String,
        baseFont: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let parsed = MarkdownInline.attributedString(from: raw)
        let converted = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        applyMissingBaseAttributes(to: converted, baseFont: baseFont, color: color)
        applyInlineCodeChipAttributes(to: converted, baseFont: baseFont)
        applyHexSwatchAttributes(to: converted, baseFont: baseFont)
        applyAttachmentCitationAttributes(to: converted, baseFont: baseFont)
        applyPathChipAttributes(to: converted, baseFont: baseFont, color: color)
        return converted
    }

    private static let inlinePresentationIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
    private static let swiftUIBackgroundColorKey = NSAttributedString.Key("SwiftUI.BackgroundColor")

    private static func applyInlineCodeChipAttributes(to attributed: NSMutableAttributedString, baseFont: NSFont) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }
        var codeRanges: [NSRange] = []
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            guard range.length > 0, isInlineCode(attributes[inlinePresentationIntentKey]) else { return }
            codeRanges.append(range)
            attributed.addAttributes([
                .font: inlineMonospacedFont(for: baseFont, weight: .regular),
                .baselineOffset: NSNumber(value: Double(MarkdownInline.inlineCodeBaselineOffset)),
                .agentChatHistoryInlineCodeChipColor: NSColor.labelColor.withAlphaComponent(0.08),
            ], range: range)
            attributed.removeAttribute(.backgroundColor, range: range)
            attributed.removeAttribute(swiftUIBackgroundColorKey, range: range)
        }
        // 与路径 chip 同一个 TextKit 故障:显式钉上的 SF Mono run 在部分
        // macOS 上不合成 CJK fallback,字符还在 attributed string 里但拿到
        // 缺失/零宽字形——`runtime/枪机日志.log` 就塌成 `runtime/ .log`。
        // 路径 chip 修过(见 applyPathChipAttributes),但 `.log` 这类不在
        // 后缀白名单里的行内代码只走本函数,得在这里同样补上 fallback。
        for range in codeRanges {
            SyntaxHighlighter.applyEditorCJKFallbackFonts(
                to: attributed,
                source: attributed.string,
                defaultFont: baseFont,
                range: range
            )
        }
    }

    private static func inlineMonospacedFont(for baseFont: NSFont, weight: NSFont.Weight) -> NSFont {
        // SF Mono's bounding box is taller than the proportional body font at
        // the same point size. Keeping inline tokens one point smaller avoids
        // TextKit giving code-bearing prose lines a different fragment height.
        NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1), weight: weight)
    }

    private static func isInlineCode(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.intValue & 4 == 4
        }
        return false
    }

    private static func applyHexSwatchAttributes(to attributed: NSMutableAttributedString, baseFont: NSFont) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }
        let string = attributed.string as NSString
        var searchStart = 0
        while searchStart < string.length {
            let found = string.range(of: "■", options: [], range: NSRange(location: searchStart, length: string.length - searchStart))
            guard found.location != NSNotFound else { break }
            let prefixLocation = max(0, found.location - 10)
            let prefixLength = found.location - prefixLocation
            let prefix = string.substring(with: NSRange(location: prefixLocation, length: prefixLength))
            if let literal = prefix.split(separator: " ").last,
               let color = MarkdownInlineSemanticEnhancer.nsColor(fromHexLiteral: String(literal)) {
                attributed.addAttributes([
                    .font: NSFont.systemFont(ofSize: max(10, baseFont.pointSize - 1), weight: .semibold),
                    .foregroundColor: color,
                ], range: found)
                attributed.removeAttribute(NSAttributedString.Key("SwiftUI.ForegroundColor"), range: found)
            }
            searchStart = NSMaxRange(found)
        }
    }

    private static let attachmentCitationRegex = try? NSRegularExpression(
        pattern: #"\[Source:\s*([^;\]\n]+);\s*([^\]\n]+)\]"#,
        options: [.caseInsensitive]
    )

    private static func applyAttachmentCitationAttributes(
        to attributed: NSMutableAttributedString,
        baseFont: NSFont
    ) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0, let regex = attachmentCitationRegex else { return }
        let string = attributed.string as NSString
        regex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
            guard let match,
                  match.numberOfRanges == 3,
                  match.range.length > 0 else { return }
            let relativePath = string.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceReference = string.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty, !sourceReference.isEmpty else { return }

            let tint = NSColor.systemIndigo
            attributed.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1), weight: .medium),
                .foregroundColor: tint,
                .backgroundColor: tint.withAlphaComponent(0.09),
                .underlineColor: tint.withAlphaComponent(0.40),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: AgentChatHistoryAttachmentCitationLink.value,
                .agentChatHistoryAttachmentCitation: AgentAttachmentCitationPayload(
                    relativePath: relativePath,
                    sourceReference: sourceReference
                ),
            ], range: match.range)
            // 引用里的相对路径可以是中文文件名,显式 SF Mono run 同样
            // 会丢 CJK 字形(同 applyInlineCodeChipAttributes 的修法)。
            SyntaxHighlighter.applyEditorCJKFallbackFonts(
                to: attributed,
                source: attributed.string,
                defaultFont: baseFont,
                range: match.range
            )
        }
    }

    // 文件引用识别正则。**关键约束**:带斜杠的普通词(`GB/T`、`TCP/IP`、
    // `I/O`、`和/或`、日期 `01/02`、分数 `1/2`)不能被误判成路径。旧正则
    // 「只要有斜杠就算路径」太宽,会把 `GB/T` 这种标准号染成可点文件链接
    // (用户反馈)。收紧为只认两类:
    //   ① 带路径锚点的:以 `/`、`./`、`../`、`~/` 开头(绝对/相对/家目录路径,
    //      如 `/usr/bin/ssh`、`~/.willdeep/skills`、`./scripts/x`);
    //   ② 以已知文件后缀结尾的(可带任意层目录前缀,如 `README.md`、
    //      `src/main.ts`、`docs/中文文件名.md`、`Xedit/AppState.swift`)。
    // 两类都可带 `:行[:列]` 后缀,并要求后面不能继续跟域名 / 路径
    // 字符,避免把 `hub-beta.tsingfly.com` 中的 `hub-beta.ts` 当文件名。
    // `GB/T` 既无锚点又无后缀 → 不再命中。
    // 新规则严格比旧的窄,只会去掉误链接,不会凭空多出。
    // static let:每渲染一个文本块就编译一次正则曾是纯浪费——pattern
    // 是常量,编译一次终生复用。
    private static let pathChipRegex = try? NSRegularExpression(
        pattern: #"(?<![\w@/])(?:(?:\.{1,2}/|~/|/)[\p{L}\p{N}_.$@+~()-]+(?:/[\p{L}\p{N}_.$@+~()-]+)*|(?:[\p{L}\p{N}_.$@+~()-]+/)*[\p{L}\p{N}_.$@+~()-]+\.(?:swift|go|ts|tsx|js|jsx|vue|md|markdown|json|yaml|yml|toml|rb|py|java|kt|rs|html|css|scss|sql|sh|zsh|txt))(?:\:\d+(?:\:\d+)?)?(?![\p{L}\p{N}_./:-])"#
    )
    private static let pathLinkCharacterSpacing: CGFloat = 0.12
    private static let pathLinkTrailingSpacing: CGFloat = 1.5

    private static func applyPathChipAttributes(
        to attributed: NSMutableAttributedString,
        baseFont: NSFont,
        color: NSColor
    ) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0, let regex = Self.pathChipRegex else {
            return
        }
        let string = attributed.string as NSString
        regex.enumerateMatches(in: attributed.string, range: fullRange) { match, _, _ in
            guard let range = match?.range, range.length > 0 else { return }
            if attributed.attribute(.link, at: range.location, effectiveRange: nil) != nil { return }
            let rawPath = string.substring(with: range)
            // 本地路径属于正文中的次要操作,不应该借系统链接蓝色和
            // 胶囊底抢走阅读焦点。路径即使来自 Markdown 行内代码,
            // 也移除两套背景属性,改用正文色 + 中等字重 + 细下划线。
            // 末字符额外增加一点字偶距,连续出现多个路径时保留清楚
            // 的视觉缝隙,但不向可复制的正文中插入空格。
            attributed.addAttributes([
                .font: inlineMonospacedFont(for: baseFont, weight: .medium),
                .foregroundColor: color,
                .underlineColor: color.withAlphaComponent(0.38),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .kern: NSNumber(value: Double(Self.pathLinkCharacterSpacing)),
                .link: AgentChatHistoryFilePathLink.value,
                .agentChatHistoryFilePath: rawPath,
            ], range: range)
            attributed.addAttribute(
                .kern,
                value: NSNumber(value: Double(Self.pathLinkTrailingSpacing)),
                range: NSRange(location: NSMaxRange(range) - 1, length: 1)
            )
            attributed.removeAttribute(.backgroundColor, range: range)
            attributed.removeAttribute(swiftUIBackgroundColorKey, range: range)
            attributed.removeAttribute(.agentChatHistoryInlineCodeChipColor, range: range)

            // TextKit on older supported macOS releases does not always
            // synthesize a CJK fallback for an explicitly assigned SF Mono
            // run. The characters remain in the attributed string but can
            // receive missing/zero-width glyphs, which visually collapses
            // `docs/中文文件名.md` to `docs/.md`. Give only the CJK
            // scalars inside the detected path an explicit fallback font;
            // ASCII path characters keep the monospaced link treatment.
            SyntaxHighlighter.applyEditorCJKFallbackFonts(
                to: attributed,
                source: attributed.string,
                defaultFont: baseFont,
                range: range
            )
        }
    }

    private static func applyMissingBaseAttributes(
        to attributed: NSMutableAttributedString,
        baseFont: NSFont,
        color: NSColor
    ) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            if attributes[.font] == nil {
                attributed.addAttribute(.font, value: baseFont, range: range)
            }
            // Real Markdown links (parsed by AttributedString(markdown:))
            // carry a URL value in `.link`; internal chrome links (copy
            // code / retry / table) use String sentinel values. Tint only
            // the real web links so the chrome affordances keep their own
            // styling. The text view's `linkTextAttributes` sets no color,
            // so this per-range color is what shows through.
            if attributes[.link] is URL || attributes[.link] is NSURL {
                attributed.addAttribute(.foregroundColor, value: Self.webLinkColor(base: color), range: range)
            } else if attributes[.foregroundColor] == nil, attributes[.link] == nil {
                attributed.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    /// Chat links belong to the same quiet chrome as retry/copy actions.
    /// Keep them grayscale so adjacent actions do not mix a blue link with
    /// neutral controls; a slightly darker gray still signals interactivity.
    private static func webLinkColor(base: NSColor) -> NSColor {
        NSColor.secondaryLabelColor.blended(withFraction: 0.24, of: base)
            ?? NSColor.secondaryLabelColor
    }

    private static func headingFont(level: Int, baseFont: NSFont) -> NSFont {
        let size = AgentChatTypography.headingFontSize(
            level: level,
            baseFontSize: baseFont.pointSize
        )
        let resized = NSFont(descriptor: baseFont.fontDescriptor, size: size)
            ?? NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(resized, toHaveTrait: .boldFontMask)
    }

    private static func bulletGlyph(for indent: Int) -> String {
        switch indent {
        case 0:
            return "-"
        case 1:
            return "*"
        default:
            return "+"
        }
    }
}
