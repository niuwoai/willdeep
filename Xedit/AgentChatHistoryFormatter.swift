//
//  AgentChatHistoryFormatter.swift
//  VeilWriter
//
//  Markdown normalization + the big `AgentChatHistoryRenderer` that bakes
//  the chat transcript into a single NSAttributedString, split out of
//  AgentChatHistoryTextView.swift in rc42:
//
//   - `AgentMarkdownNormalizer`: pre-pass on the raw model output before
//     it hits MarkdownPreviewParser. Coalesces hr-style dividers
//     (`---`/`___`/`***`) and wraps a small allowlist of HTML block
//     elements (<details>, <summary>, <pre>, <table>, <div>, <section>,
//     <article>) inside a synthetic ```html fence so they pass through
//     intact instead of being chewed up by the markdown parser.
//   - `AgentChatHistoryRenderer`: the TextKit baker. Builds role
//     avatars, applies bubble chrome via the `agentChatHistoryBubbleKind`
//     attribute the layout manager reads, attaches footer chrome from
//     `AgentChatHistoryFooterChrome`, and stamps copy buttons over fenced
//     code blocks. Cached by (messages-hash, isDark, expanded tool group
//     ids, hovered user message id) — repeated scroll updates re-use the
//     prior attributed string instead of re-rendering.
//
//  This file depends on three internal hooks still living in
//  AgentChatHistoryTextView.swift: the NSAttributedString.Key extension
//  (`agentChatHistoryBubbleKind` and siblings), the `AgentChatHistoryBubbleKind`
//  enum, and `AgentChatHistoryLayoutMetrics` for the user-bubble indent
//  constants. Those were flipped from `private` to internal in the same
//  refactor so they can land here.
//

import AppKit

enum AgentMarkdownNormalizer {
    static func normalizedForChatRendering(_ source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        var output: [String] = []
        var index = 0
        var isInFence = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInFence.toggle()
                output.append(line)
                index += 1
                continue
            }

            if !isInFence, isDividerLine(trimmed) {
                output.append("---")
                index += 1
                continue
            }

            if !isInFence, let endMarker = htmlBlockEndMarker(for: trimmed) {
                output.append("```html")
                output.append(line)
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    output.append(next)
                    if next.range(of: endMarker, options: [.caseInsensitive]) != nil {
                        index += 1
                        break
                    }
                    index += 1
                }
                output.append("```")
                continue
            }

            output.append(line)
            index += 1
        }

        return output.joined(separator: "\n")
    }

    private static func isDividerLine(_ line: String) -> Bool {
        let collapsed = line.replacingOccurrences(of: " ", with: "")
        guard collapsed.count >= 3, let first = collapsed.first, "-_*".contains(first) else {
            return false
        }
        return collapsed.allSatisfy { $0 == first }
    }

    private static func htmlBlockEndMarker(for line: String) -> String? {
        let lower = line.lowercased()
        let pairs: [(String, String)] = [
            ("<details", "</details>"),
            ("<summary", "</summary>"),
            ("<pre", "</pre>"),
            ("<table", "</table>"),
            ("<div", "</div>"),
            ("<section", "</section>"),
            ("<article", "</article>"),
        ]
        for (prefix, suffix) in pairs where lower.hasPrefix(prefix) {
            return suffix
        }
        return nil
    }
}

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
    private enum MarkdownSpacing {
        static let headerToBody: CGFloat = 10
        static let bodyLine: CGFloat = 2.5
        static let assistantParagraph: CGFloat = 4
        static let userParagraph: CGFloat = 6
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
        /// Inline 工具调用摘要需要和上一段 assistant 正文明显分开；
        /// 这是 transcript 里“说完话，开始动手”的视觉边界。
        static let inlineToolGroupBefore: CGFloat = 22
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
        hasher.combine(m.textAttachments.count)
        for attachment in m.textAttachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.filename)
            hasher.combine(attachment.content)
        }
        hasher.combine(m.toolCallID)
        hasher.combine(m.createdAt)
        hasher.combine(m.reasoningContent)
        hasher.combine(m.usageTokens)
        hasher.combine(m.promptTokens)
        hasher.combine(m.completionTokens)
        hasher.combine(m.elapsedSeconds)
        hasher.combine(m.toolCalls.count)
        for call in m.toolCalls {
            hasher.combine(call.externalID)
            hasher.combine(call.toolName)
            hasher.combine(call.argumentsJSON)
        }
        return hasher.finalize()
    }

    static func render(
        messages: [AgentMessage],
        isDark: Bool,
        expandedToolGroupIDs: Set<String> = [],
        hoveredUserMessageID: UUID? = nil,
        baseFontSize: CGFloat = NSFont.systemFontSize
    ) -> NSAttributedString {
        let clampedSize = AgentSettingsStore.clampChatBaseFontSize(baseFontSize)
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(expandedToolGroupIDs.sorted())
        hasher.combine(hoveredUserMessageID)
        for m in messages {
            hasher.combine(messageHash(m))
        }
        let key = CacheKey(
            countAndHash: hasher.finalize(),
            isDark: isDark,
            baseFontSize: clampedSize
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
            expandedToolGroupIDs: expandedToolGroupIDs,
            hoveredUserMessageID: hoveredUserMessageID,
            baseFontSize: clampedSize
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
        expandedToolGroupIDs: Set<String>,
        hoveredUserMessageID: UUID?,
        baseFontSize: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // `bodyFont` / `monoFont` follow the user's chat-base size
        // knob (Q1=A) — they're used for message prose, plain tool
        // outputs, fenced code blocks, and inline-Markdown spans.
        // `chromeMonoFont` is the fixed-size mono used for tool-call
        // group summaries; chrome doesn't grow with body text.
        let bodyFont = NSFont.systemFont(ofSize: baseFontSize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
        let chromeMonoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let bodyColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor
        let codeBackgroundColor = NSColor.controlBackgroundColor

        // Cap tool bodies on the visible transcript to keep TextKit's
        // layout work bounded. The reader window shows the full body.
        let toolBodyLimit = 8_000
        let latestAssistantMessageID = messages.reversed().first {
            $0.role == .assistant && !$0.content.isEmpty
        }?.id

        var index = 0
        while index < messages.count {
            let message = messages[index]
            // Skip empty assistant placeholders (the loop emits them
            // while a turn is waiting on tool calls).
            if message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty {
                index += 1
                continue
            }

            if isToolCallOnly(message) {
                var groupMessages: [AgentMessage] = []
                while index < messages.count, isToolCallOnly(messages[index]) {
                    groupMessages.append(messages[index])
                    index += 1
                }
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n\n"))
                }
                let group = ToolCallHistoryGroup(messages: groupMessages)
                appendToolCallGroup(
                    group,
                    isExpanded: expandedToolGroupIDs.contains(group.id),
                    to: result,
                    monoFont: chromeMonoFont,
                    secondaryColor: secondaryColor
                )
                continue
            }

            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }

            // Role header.
            let isToolCallOnly = message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty
            appendHeader(
                for: message,
                isToolCallOnly: isToolCallOnly,
                to: result,
                headerFont: headerFont,
                secondaryColor: secondaryColor
            )

            // Body.
            let isHoveredUserMessage = message.role == .user && message.id == hoveredUserMessageID
            let messageBubbleStart = result.length
            var hasMessageBubbleContent = false
            let useMono = (message.role == .tool)
            let body: String
            if useMono, message.content.count > toolBodyLimit {
                let head = String(message.content.prefix(toolBodyLimit))
                let omitted = message.content.count - toolBodyLimit
                body = head + "\n\n…[truncated \(omitted) characters from this tool output — open the message reader for the full body]"
            } else {
                body = message.content
            }

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
                    paragraphStyle: bodyParagraphStyle(for: message.role),
                    userMessageID: message.id,
                    foregroundColor: nil
                )
                hasMessageBubbleContent = true
            }

            if !body.isEmpty {
                if hasMessageBubbleContent {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                }
                let bodyStart = result.length
                if useMono {
                    appendPlainBody(body, to: result, font: monoFont, color: bodyColor)
                } else {
                    appendMarkdownBody(
                        body,
                        to: result,
                        role: message.role,
                        bodyFont: bodyFont,
                        monoFont: monoFont,
                        bodyColor: bodyColor,
                        secondaryColor: secondaryColor,
                        codeBackgroundColor: codeBackgroundColor,
                        isDark: isDark
                    )
                }
                let bodyRange = NSRange(location: bodyStart, length: result.length - bodyStart)
                applyBubbleChrome(
                    kind: bubbleKind(for: message.role),
                    to: result,
                    range: bodyRange,
                    paragraphStyle: bodyParagraphStyle(for: message.role),
                    userMessageID: message.role == .user ? message.id : nil,
                    foregroundColor: nil
                )
                hasMessageBubbleContent = true
            }

            // Tool call summary (when the assistant emitted tool calls
            // *alongside* its own prose). Rendered through the same
            // collapsible header as the standalone tool-call group so
            // the bubble defaults to a one-line "▸ 执行了 N 条工具调用
            // · run_command  command: ssh ..." link; clicking flips the
            // chevron and reveals the full per-call summary below.
            if !message.toolCalls.isEmpty {
                if !body.isEmpty {
                    // Transparent spacer paragraph between the assistant
                    // body bubble and the tool summary bubble. Beyond
                    // resolving the bubble-baseline overlap, this gap
                    // is also the user-visible "the assistant's prose
                    // ended, a tool call starts here" separator — 22pt
                    // gives the two bubbles real breathing room without
                    // making the conversation feel disjointed.
                    let spacerStyle = NSMutableParagraphStyle()
                    spacerStyle.alignment = .left
                    spacerStyle.paragraphSpacing = 0
                    spacerStyle.lineSpacing = 0
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: MarkdownSpacing.inlineToolGroupBefore),
                            .foregroundColor: NSColor.clear,
                            .paragraphStyle: spacerStyle,
                        ]
                    ))
                }
                let inlineGroup = ToolCallHistoryGroup(
                    inlineMessageID: message.id,
                    calls: message.toolCalls
                )
                appendToolCallGroup(
                    inlineGroup,
                    isExpanded: expandedToolGroupIDs.contains(inlineGroup.id),
                    to: result,
                    monoFont: chromeMonoFont,
                    secondaryColor: secondaryColor
                )
            }

            if shouldShowFooter(for: message, body: body) {
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                let footerStart = result.length
                appendMessageFooter(
                    for: message,
                    isLatestAssistant: message.id == latestAssistantMessageID,
                    isVisible: message.role != .user || isHoveredUserMessage,
                    to: result
                )
                if hasMessageBubbleContent && message.toolCalls.isEmpty {
                    let messageRange = NSRange(location: messageBubbleStart, length: result.length - messageBubbleStart)
                    if message.role == .user && !isHoveredUserMessage {
                        applyBodyChrome(
                            to: result,
                            range: messageRange,
                            paragraphStyle: bodyParagraphStyle(for: message.role),
                            userMessageID: message.id
                        )
                    } else {
                        applyBubbleChrome(
                            kind: bubbleKind(for: message.role),
                            to: result,
                            range: messageRange,
                            paragraphStyle: bodyParagraphStyle(for: message.role),
                            userMessageID: message.role == .user ? message.id : nil,
                            foregroundColor: nil
                        )
                    }
                    let footerRange = NSRange(location: footerStart, length: result.length - footerStart)
                    result.addAttribute(
                        .paragraphStyle,
                        value: footerParagraphStyle(for: message.role),
                        range: footerRange
                    )
                }
            }

            index += 1
        }

        return result
    }

    private struct ToolCallHistoryGroup {
        let id: String
        let calls: [AgentMessageToolCall]

        init(messages: [AgentMessage]) {
            id = messages.map { $0.id.uuidString }.joined(separator: ":")
            calls = messages.flatMap(\.toolCalls)
        }

        /// Tool calls that came in *alongside* an assistant message's
        /// prose (not as a separate tool-call-only assistant turn).
        /// Keyed by the host message id so expand/collapse state is
        /// stable across re-renders of the same conversation.
        init(inlineMessageID: UUID, calls: [AgentMessageToolCall]) {
            id = "inline:" + inlineMessageID.uuidString
            self.calls = calls
        }
    }

    private static func isToolCallOnly(_ message: AgentMessage) -> Bool {
        message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty
    }

    private static func appendHeader(
        for message: AgentMessage,
        isToolCallOnly: Bool,
        to result: NSMutableAttributedString,
        headerFont: NSFont,
        secondaryColor: NSColor
    ) {
        let label: String
        let avatar: String
        let color: NSColor
        switch message.role {
        case .system:
            label = "System"
            avatar = "SYS"
            color = NSColor.systemPurple
        case .user:
            label = "You"
            avatar = "YOU"
            color = NSColor.controlAccentColor
        case .assistant:
            label = isToolCallOnly ? "Tool calls" : "Assistant"
            avatar = isToolCallOnly ? "TL" : "AI"
            color = isToolCallOnly ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        case .tool:
            label = message.toolCallID.map { "Tool output · \($0)" } ?? "Tool output"
            avatar = "OUT"
            color = NSColor.systemGreen
        }

        let headerStart = result.length
        switch message.role {
        case .user:
            result.append(NSAttributedString(
                string: label + "\n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: secondaryColor,
                ]
            ))
        case .assistant where !isToolCallOnly:
            result.append(starToken(color: color, font: headerFont))
            result.append(NSAttributedString(
                string: " " + label + "\n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: secondaryColor,
                ]
            ))
        case .system, .assistant, .tool:
            result.append(avatarToken(label: avatar, fill: color))
            result.append(NSAttributedString(
                string: " " + label + "\n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: isToolCallOnly ? color : secondaryColor,
                ]
            ))
        }
        result.addAttribute(
            .paragraphStyle,
            value: headerParagraphStyle(for: message.role),
            range: NSRange(location: headerStart, length: result.length - headerStart)
        )
        if message.role == .user {
            result.addAttribute(
                .agentChatHistoryUserMessageID,
                value: message.id.uuidString,
                range: NSRange(location: headerStart, length: result.length - headerStart)
            )
        }
    }

    private static func starToken(color: NSColor, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: "✦",
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize + 4, weight: .semibold),
                .foregroundColor: color,
            ]
        )
    }

    /// `avatarToken` produced a fresh NSImage on every header — the
    /// chat history renders all message headers on every cache-miss
    /// rebuild, so a 100-message transcript allocated 100 small NSImages
    /// + lockFocus/draw/unlockFocus rounds every time. Avatar labels are
    /// drawn from a tiny set (\"YOU\", \"S\", \"T\", short role initials),
    /// so caching by (label, fill identity) eliminates all of it.
    private struct AvatarCacheKey: Hashable {
        let label: String
        let fillDescription: String
    }
    private static let avatarCacheLock = NSLock()
    private static var avatarImageCache: [AvatarCacheKey: NSImage] = [:]

    private static func cachedAvatarImage(label: String, fill: NSColor) -> NSImage {
        let key = AvatarCacheKey(label: label, fillDescription: String(describing: fill))
        avatarCacheLock.lock()
        if let hit = avatarImageCache[key] {
            avatarCacheLock.unlock()
            return hit
        }
        avatarCacheLock.unlock()

        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.count > 2 ? 6.2 : 7.6, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attrs)
        let labelRect = NSRect(
            x: (size.width - labelSize.width) / 2,
            y: (size.height - labelSize.height) / 2 - 0.5,
            width: labelSize.width,
            height: labelSize.height
        )
        label.draw(in: labelRect, withAttributes: attrs)
        image.unlockFocus()

        avatarCacheLock.lock()
        avatarImageCache[key] = image
        avatarCacheLock.unlock()
        return image
    }

    private static func avatarToken(label: String, fill: NSColor) -> NSAttributedString {
        let image = cachedAvatarImage(label: label, fill: fill)
        let size = image.size
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -6, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func bubbleKind(for role: AgentRole) -> AgentChatHistoryBubbleKind {
        switch role {
        case .system:
            return .system
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .tool:
            return .tool
        }
    }

    private static func headerParagraphStyle(for role: AgentRole) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = role == .user ? .right : .left
        style.paragraphSpacing = role == .user ? 14 : MarkdownSpacing.headerToBody
        style.lineSpacing = 1
        style.headIndent = role == .user ? 150 : 0
        style.firstLineHeadIndent = style.headIndent
        style.tailIndent = role == .user ? -30 : -16
        return style
    }

    private static func bodyParagraphStyle(for role: AgentRole) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = MarkdownSpacing.bodyLine
        style.paragraphSpacing = role == .user ? MarkdownSpacing.userParagraph : MarkdownSpacing.assistantParagraph
        switch role {
        case .user:
            style.headIndent = AgentChatHistoryLayoutMetrics.userBodyHeadIndent
            style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.userBodyHeadIndent
            style.tailIndent = AgentChatHistoryLayoutMetrics.userBodyTailIndent
        case .assistant, .system, .tool:
            style.headIndent = 32
            style.firstLineHeadIndent = 32
            style.tailIndent = -18
        }
        return style
    }

    private static func codeBlockParagraphStyle(from baseStyle: NSParagraphStyle) -> NSParagraphStyle {
        let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if baseStyle.alignment != .right {
            style.headIndent = baseStyle.headIndent + 8
            style.firstLineHeadIndent = baseStyle.firstLineHeadIndent + 8
            style.tailIndent = baseStyle.tailIndent - 8
        }
        return style
    }

    /// 给代码块首段加 margin-top、末段加 margin-bottom。代码块内部每行
    /// 都是独立段落（保留字面 \n），before/spacing 设在整个 range 上会把
    /// 行与行之间也撑开，所以必须定点打在首末两个段落上。
    private static func applyCodeBlockVerticalMargins(
        to attributed: NSMutableAttributedString,
        codeRange: NSRange,
        baseStyle: NSParagraphStyle
    ) {
        guard codeRange.length > 0 else { return }
        let text = attributed.string as NSString
        let firstParagraph = text.paragraphRange(for: NSRange(location: codeRange.location, length: 0))
        let lastParagraph = text.paragraphRange(for: NSRange(location: NSMaxRange(codeRange) - 1, length: 0))
        if firstParagraph == lastParagraph {
            let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = MarkdownSpacing.codeBlockBefore
            style.paragraphSpacing = MarkdownSpacing.codeBlockAfter
            attributed.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
            return
        }
        let firstStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        firstStyle.paragraphSpacingBefore = MarkdownSpacing.codeBlockBefore
        attributed.addAttribute(.paragraphStyle, value: firstStyle, range: firstParagraph)
        let lastStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        lastStyle.paragraphSpacing = MarkdownSpacing.codeBlockAfter
        attributed.addAttribute(.paragraphStyle, value: lastStyle, range: lastParagraph)
    }

    private static func tableBlockParagraphStyle(from baseStyle: NSParagraphStyle) -> NSParagraphStyle {
        let style = codeBlockParagraphStyle(from: baseStyle).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.lineSpacing = MarkdownSpacing.tableLine
        style.paragraphSpacing = MarkdownSpacing.tableParagraph
        style.paragraphSpacingBefore = MarkdownSpacing.tableParagraphBefore
        return style
    }

    /// Paragraph style for inline Markdown headings. Inherits indent /
    /// alignment from the bubble's body style, then adds vertical air
    /// above (`paragraphSpacingBefore`) and below (`paragraphSpacing`)
    /// so `## 段标题` stops looking like a slightly-bigger run-in line.
    private static func headingParagraphStyle(from baseStyle: NSParagraphStyle) -> NSParagraphStyle {
        let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacingBefore = MarkdownSpacing.headingParagraphBefore
        style.paragraphSpacing = MarkdownSpacing.headingParagraph
        return style
    }

    private static func toolSummaryParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = MarkdownSpacing.toolLine
        style.paragraphSpacing = 3
        style.headIndent = 28
        style.firstLineHeadIndent = 28
        style.tailIndent = -28
        return style
    }

    private static func toolGroupHeaderParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = 1
        style.paragraphSpacingBefore = 2
        style.paragraphSpacing = 1
        style.headIndent = 22
        style.firstLineHeadIndent = 22
        style.tailIndent = -22
        return style
    }

    private static func footerParagraphStyle(for role: AgentRole) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = role == .user ? .right : .left
        style.lineSpacing = 1
        style.paragraphSpacing = 0
        switch role {
        case .user:
            style.headIndent = AgentChatHistoryLayoutMetrics.userBodyHeadIndent
            style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.userBodyHeadIndent
            style.tailIndent = AgentChatHistoryLayoutMetrics.userBodyTailIndent
        case .assistant:
            style.headIndent = 32
            style.firstLineHeadIndent = 32
            style.tailIndent = -18
        case .system, .tool:
            style.headIndent = 32
            style.firstLineHeadIndent = 32
            style.tailIndent = -18
        }
        return style
    }

    private static func applyBubbleChrome(
        kind: AgentChatHistoryBubbleKind,
        to attributed: NSMutableAttributedString,
        range: NSRange,
        paragraphStyle: NSParagraphStyle,
        userMessageID: UUID? = nil,
        foregroundColor: NSColor?
    ) {
        guard range.length > 0 else { return }
        attributed.addAttribute(.agentChatHistoryBubbleKind, value: NSNumber(value: kind.rawValue), range: range)
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        if let userMessageID {
            attributed.addAttribute(.agentChatHistoryUserMessageID, value: userMessageID.uuidString, range: range)
        }
        let codeParagraphStyle = codeBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryCodeBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: codeParagraphStyle, range: subrange)
            applyCodeBlockVerticalMargins(to: attributed, codeRange: subrange, baseStyle: codeParagraphStyle)
        }
        let tableParagraphStyle = tableBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryTableBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: tableParagraphStyle, range: subrange)
        }
        let headingStyle = headingParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryHeadingLevel, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: headingStyle, range: subrange)
        }
        guard let foregroundColor else { return }
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            if attributes[.link] == nil {
                attributed.addAttribute(.foregroundColor, value: foregroundColor, range: subrange)
            }
        }
    }

    private static func applyBodyChrome(
        to attributed: NSMutableAttributedString,
        range: NSRange,
        paragraphStyle: NSParagraphStyle,
        userMessageID: UUID?
    ) {
        guard range.length > 0 else { return }
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        if let userMessageID {
            attributed.addAttribute(.agentChatHistoryUserMessageID, value: userMessageID.uuidString, range: range)
        }
        let codeParagraphStyle = codeBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryCodeBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: codeParagraphStyle, range: subrange)
            applyCodeBlockVerticalMargins(to: attributed, codeRange: subrange, baseStyle: codeParagraphStyle)
        }
        let tableParagraphStyle = tableBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryTableBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: tableParagraphStyle, range: subrange)
        }
        let headingStyle = headingParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryHeadingLevel, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: headingStyle, range: subrange)
        }
    }

    private static func appendToolCallGroup(
        _ group: ToolCallHistoryGroup,
        isExpanded: Bool,
        to result: NSMutableAttributedString,
        monoFont: NSFont,
        secondaryColor: NSColor
    ) {
        let start = result.length
        let count = group.calls.count
        let chevron = isExpanded ? "▾" : "▸"
        let title = "\(chevron) 执行了 \(count) 条工具调用"
        let preview = collapsedToolPreview(for: group.calls)
        let titleText = preview.isEmpty ? title : "\(title) · \(preview)"
        result.append(NSAttributedString(
            string: titleText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: secondaryColor,
                .link: "agent-chat-history-tool-group",
                .agentChatHistoryToolGroupID: group.id,
            ]
        ))
        result.addAttribute(
            .paragraphStyle,
            value: toolGroupHeaderParagraphStyle(),
            range: NSRange(location: start, length: result.length - start)
        )

        guard isExpanded else { return }

        result.append(NSAttributedString(string: "\n", attributes: [.font: monoFont]))
        result.append(NSAttributedString(
            string: toolCallSummary(for: group.calls, argumentLimit: 220),
            attributes: [
                .font: monoFont,
                .foregroundColor: secondaryColor,
            ]
        ))
        applyBubbleChrome(
            kind: .toolSummary,
            to: result,
            range: NSRange(location: start, length: result.length - start),
            paragraphStyle: toolSummaryParagraphStyle(),
            foregroundColor: nil
        )
    }

    private static func collapsedToolPreview(for toolCalls: [AgentMessageToolCall]) -> String {
        guard let first = toolCalls.first else { return "" }
        let arguments = compactArguments(for: first, limit: 160)
        if arguments.isEmpty {
            return first.toolName
        }
        return "\(first.toolName)  \(arguments)"
    }

    private static func toolCallSummary(for toolCalls: [AgentMessageToolCall], argumentLimit: Int = 160) -> String {
        toolCalls
            .map { call in
                let (arguments, isTruncated) = compactArgumentsWithTruncationFlag(for: call, limit: argumentLimit)
                // No args at all → just the tool name; the old "0 B args"
                // tail was pure noise.
                if arguments.isEmpty {
                    return "tool  \(call.toolName)"
                }
                // Args fit in `argumentLimit` → no tail. The compact form
                // (e.g. `path: deployment.md`) already shows everything.
                if !isTruncated {
                    return "tool  \(call.toolName)  \(arguments)"
                }
                // Truncated → tell the user how much was hidden, in human
                // form ("共 1.4 KB · 已折叠"), not in "B" units that look
                // like a typo for ⌘B.
                return "tool  \(call.toolName)  \(arguments)  · 完整参数 \(byteLabel(call.argumentsJSON.count))"
            }
            .joined(separator: "\n")
    }

    /// Adapter that wraps `compactArguments` and reports whether the
    /// returned string had to drop content to fit. Two truncation
    /// sources: `trimmedInline` slicing a long value with `...`, or
    /// `compactArguments` itself picking only the first 2 preferred
    /// keys out of a dict that contains more. We detect the latter by
    /// comparing rendered key-count to dict.count.
    private nonisolated static func compactArgumentsWithTruncationFlag(
        for call: AgentMessageToolCall,
        limit: Int = 160
    ) -> (String, Bool) {
        let rendered = compactArguments(for: call, limit: limit)
        guard !rendered.isEmpty else { return ("", false) }

        // Source 1: any per-value trimming left a "..." marker behind.
        if rendered.contains("...") {
            return (rendered, true)
        }

        // Source 2: dict had more keys than we rendered. Parse the
        // JSON; if it's a dict with > 2 keys, compactArguments only
        // surfaced the first 2 (preferred or alphabetical).
        if let data = call.argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any],
           dict.count > 2 {
            return (rendered, true)
        }

        return (rendered, false)
    }

    private static func shouldShowFooter(
        for message: AgentMessage,
        body: String
    ) -> Bool {
        switch message.role {
        case .user:
            return !body.isEmpty || !message.textAttachments.isEmpty
        case .assistant:
            return !body.isEmpty
        case .system, .tool:
            return false
        }
    }

    private static func appendTextAttachments(
        _ attachments: [AgentTextAttachment],
        to result: NSMutableAttributedString,
        font: NSFont,
        secondaryColor: NSColor
    ) {
        for (index, attachment) in attachments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            let label = "▣ \(attachment.displayName) · \(attachment.byteLabel)"
            result.append(NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: secondaryColor,
                ]
            ))
        }
    }

    private static func appendMessageFooter(
        for message: AgentMessage,
        isLatestAssistant: Bool,
        isVisible: Bool = true,
        to result: NSMutableAttributedString
    ) {
        let start = result.length
        if message.role == .user {
            result.append(AgentChatHistoryFooterChrome.label(formatTimestamp(message.createdAt)))
            result.append(AgentChatHistoryFooterChrome.separator)
        }
        result.append(AgentChatHistoryFooterChrome.copyButton(copied: false, message: message.copyableContent))

        if message.role == .assistant {
            if let elapsed = message.elapsedSeconds, elapsed > 0 {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.elapsedLabel(formatElapsed(elapsed)))
            }
            if let summary = tokenSummary(for: message) {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.label(summary))
            }
            if isLatestAssistant {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.retryButton())
            }
        }

        if !isVisible {
            let footerRange = NSRange(location: start, length: result.length - start)
            result.removeAttribute(.link, range: footerRange)
            result.removeAttribute(.agentChatHistoryMessageCopyText, range: footerRange)
            result.removeAttribute(.agentChatHistoryRetryLastTurn, range: footerRange)
            result.addAttribute(.foregroundColor, value: NSColor.clear, range: footerRange)
        }

        result.addAttribute(
            .paragraphStyle,
            value: footerParagraphStyle(for: message.role),
            range: NSRange(location: start, length: result.length - start)
        )
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let dateStyle: DateFormatter.Style = calendar.isDateInToday(date) ? .none : .short
        return DateFormatter.localizedString(from: date, dateStyle: dateStyle, timeStyle: .short)
    }

    private static func tokenSummary(for message: AgentMessage) -> String? {
        if let prompt = message.promptTokens, let completion = message.completionTokens {
            return "in \(formatTokens(prompt)) · out \(formatTokens(completion))"
        }
        if let total = message.usageTokens, total > 0 {
            return "\(formatTokens(total)) tok"
        }
        return nil
    }

    private static func formatElapsed(_ seconds: Double) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private static func formatTokens(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return String(count)
    }

    private nonisolated static func compactArguments(for call: AgentMessageToolCall, limit: Int = 160) -> String {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              !dict.isEmpty else {
            return trimmedInline(call.argumentsJSON, limit: limit)
        }

        let preferredKeys: [String]
        switch call.toolName {
        case "run_command":
            preferredKeys = ["command", "cwd", "timeout"]
        case "grep_files":
            preferredKeys = ["pattern", "include", "path"]
        case "search_files":
            preferredKeys = ["query", "path"]
        case "read_file", "list_directory":
            preferredKeys = ["path", "limit", "offset"]
        case "ask_user":
            preferredKeys = ["question", "options"]
        case "read_skill":
            preferredKeys = ["skill", "name", "path"]
        case "list_mcp_tools", "call_mcp_tool":
            preferredKeys = ["server", "tool", "name"]
        case "spawn_agent":
            preferredKeys = ["label", "prompt"]
        case "claude_code", "codex_cli", "cursor_agent":
            preferredKeys = ["prompt", "permission_mode"]
        default:
            preferredKeys = ["command", "path", "pattern", "query", "question", "url", "name"]
        }

        var parts: [String] = []
        for key in preferredKeys {
            guard let value = dict[key] else { continue }
            let text = compactJSONValue(value)
            guard !text.isEmpty else { continue }
            parts.append("\(key): \(trimmedInline(text, limit: limit))")
            if parts.count >= 2 { break }
        }

        if parts.isEmpty {
            for key in dict.keys.sorted().prefix(2) {
                guard let value = dict[key] else { continue }
                let text = compactJSONValue(value)
                guard !text.isEmpty else { continue }
                parts.append("\(key): \(trimmedInline(text, limit: max(72, limit / 2)))")
            }
        }
        return parts.joined(separator: "  ")
    }

    private nonisolated static func compactJSONValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let rendered = array.prefix(3).map(compactJSONValue).filter { !$0.isEmpty }
            let suffix = array.count > rendered.count ? ", ..." : ""
            return "[" + rendered.joined(separator: ", ") + suffix + "]"
        case let dict as [String: Any]:
            let rendered = dict.keys.sorted().prefix(3).compactMap { key -> String? in
                guard let value = dict[key] else { return nil }
                let text = compactJSONValue(value)
                guard !text.isEmpty else { return nil }
                return "\(key): \(text)"
            }
            let suffix = dict.count > rendered.count ? ", ..." : ""
            return "{" + rendered.joined(separator: ", ") + suffix + "}"
        default:
            return String(describing: value)
        }
    }

    private nonisolated static func byteLabel(_ count: Int) -> String {
        if count < 1_024 {
            return "\(count) B"
        }
        let kb = Double(count) / 1_024.0
        return String(format: "%.1f KB", kb)
    }

    private nonisolated static func trimmedInline(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "..."
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
        case "go", "golang": return .go
        case "html": return .html
        case "css": return .css
        case "json", "jsonc", "jsonl": return .json
        case "md", "markdown": return .markdown
        case "sh", "shell", "bash", "zsh": return .shell
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "xml": return .xml
        case "sql": return .sql
        case "dockerfile": return .dockerfile
        case "make", "makefile": return .makefile
        case "ini", "conf": return .ini
        case "env", "dotenv": return .env
        case "rs", "rust": return .rust
        case "c": return .c
        case "cc", "cpp", "cxx", "c++": return .cpp
        case "cs", "csharp", "c#": return .csharp
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
        isDark: Bool
    ) {
        let normalized = AgentMarkdownNormalizer.normalizedForChatRendering(source)
        let safe = AgentLongTokenBreaker.inject(into: normalized)
        let blocks = MarkdownPreviewParser.blocks(from: safe)
        guard !blocks.isEmpty else {
            result.append(inlineMarkdownAttributedString(safe, baseFont: bodyFont, color: bodyColor))
            return
        }

        var didAppendBlock = false
        var codeBlockIndex = 0
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
                    baseFont: headingFont(level: level),
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
                let indent = String(repeating: "  ", count: min(block.indent, 4))
                result.append(NSAttributedString(
                    string: "\(indent)\(bulletGlyph(for: block.indent)) ",
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

            case .orderedList:
                appendBlockSeparator()
                let indent = String(repeating: "  ", count: min(block.indent, 4))
                result.append(NSAttributedString(
                    string: "\(indent)1. ",
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
                let codeBlockID = codeBlockIndex
                codeBlockIndex += 1
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
                result.append(AgentChatHistoryCodeCopyChrome.button(
                    copied: false,
                    code: block.text,
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

            case .table:
                appendBlockSeparator()
                if let headers = block.tableHeaders, let rows = block.tableRows {
                    let table = AgentMarkdownTableFormatter.formatted(
                        headers: headers,
                        rows: rows
                    )
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
                        if role != .user {
                            result.addAttribute(
                                .agentChatHistoryTableBlockID,
                                value: NSNumber(value: tableBlockID),
                                range: NSRange(location: tableBlockStart, length: result.length - tableBlockStart)
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
        return converted
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
            if attributes[.foregroundColor] == nil, attributes[.link] == nil {
                attributed.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1:
            return NSFont.systemFont(ofSize: 22, weight: .semibold)
        case 2:
            return NSFont.systemFont(ofSize: 18, weight: .semibold)
        case 3:
            return NSFont.systemFont(ofSize: 16, weight: .semibold)
        default:
            return NSFont.systemFont(ofSize: 14, weight: .semibold)
        }
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
