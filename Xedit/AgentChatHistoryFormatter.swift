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
        hasher.combine(m.cachedPromptTokens)
        hasher.combine(m.cacheWritePromptTokens)
        hasher.combine(m.reasoningTokens)
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
                } else if message.role == .user {
                    appendPlainBody(
                        AgentLongTokenBreaker.inject(into: body),
                        to: result,
                        font: bodyFont,
                        color: bodyColor
                    )
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
            // the bubble defaults to a one-line activity summary such
            // as "▸ 已读取 2 个文件 · 已运行 1 条命令"; clicking flips
            // the chevron and reveals the full per-call summary below.
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

    struct ToolCallHistoryGroup {
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
                                color: NSColor.linkColor
                            ))
                            let linkRange = NSRange(location: linkStart, length: result.length - linkStart)
                            result.addAttributes(
                                [
                                    .link: AgentChatHistoryTableLink.value,
                                    .cursor: NSCursor.pointingHand,
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

    /// A deliberately understated link color: the system link blue pulled
    /// part-way toward the body text color so links read as "tappable and
    /// a little different" without the loud full-saturation blue. Adapts
    /// to light/dark because both inputs are appearance-aware.
    private static func webLinkColor(base: NSColor) -> NSColor {
        NSColor.linkColor.blended(withFraction: 0.3, of: base) ?? NSColor.linkColor
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
