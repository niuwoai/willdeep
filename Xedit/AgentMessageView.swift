//
//  AgentMessageView.swift
//  WillDeep
//
//  Per-message SwiftUI surfaces for the chat transcript, split out of
//  AgentModeView.swift in rc42. The TextKit-baked history view handles
//  settled messages; this file owns the bubbles + helpers that still
//  need to live as SwiftUI:
//
//   - `AgentModeMessageView`: the per-message bubble. User on the right
//     with a soft card (hover reveals copy + timestamp), assistant
//     on the left with a sparkle avatar and the markdown body card. Takes
//     `isStreamingThisMessage` as a plain Bool prop — derived from AppState
//     in the parent — because reading AppState here would pull every
//     bubble into the invalidation graph (77% CPU in `AG::Subgraph::update`
//     during a 19s sample before the rc12 fix).
//   - `AgentAssistantMarkdownBody` + `AgentAssistantMarkdownRenderer`:
//     bakes one assistant message's Markdown into a single
//     `Text(AttributedString)`. Pre-rc9 used VStack + ForEach(blocks);
//     `LazyStack.measureEstimates` hit `ForEachState.item(at:offset:) + 1644`
//     under freeze. Single Text collapses a 200-block message to 1 view.
//   - `AgentLongTokenBreaker`: injects U+200B every 30 chars into
//     unbreakable runs. SwiftUI's line-breaker freezes on 150-char hash
//     paths (pnpm-store listings, etc.).
//   - `AgentStreamingCursor`: 7×14 blinking accent bar at the end of the
//     streaming message.
//   - `AgentUserContentSplitter`: pulls qwen-vl auto-generated image
//     descriptions out of user messages and hides them behind a
//     disclosure chip — cached by content hash because SwiftUI evaluates
//     user-bubble bodies many times per layout pass.
//   - `AgentImageDescriptionDisclosure`: white-on-accent chip that reveals
//     the spliced description on demand.
//   - `AgentMessageFooter`: copy + elapsed-seconds + prompt/completion
//     token caption row.
//   - `QueuedMessageRow`: orange-tinted card shown for messages still
//     waiting in the per-session queue.
//   - `AgentChatEmptyState`: the "✦ Welcome back" hero shown when the
//     session has no messages, with the stats dashboard tail (rendered
//     once at least one persisted session exists, otherwise just a
//     pick-a-folder subtitle).
//
//  Previously all `private struct` inside AgentModeView.swift; now
//  internal so the transcript and other agent views can compose them
//  across file boundaries. `AgentEmptyState` was renamed to
//  `AgentChatEmptyState` because the editor's panel view exposes its
//  own private `AgentEmptyState`.
//

import AppKit
import SwiftUI

/// CRITICAL: this view used to `@EnvironmentObject var appState: AppState`
/// to compute `isStreamingThisMessage`. That single dependency dragged
/// every bubble in the transcript into AppState's invalidation graph —
/// any AppState mutation (delegated `agent*` change, token streamed in,
/// sidebar status flip, whatever) caused AttributeGraph to re-run
/// `update` across every visible AgentModeMessageView. Instruments
/// profiling under the freeze showed `AG::Subgraph::update` at 77%
/// and `AG::Graph::UpdateStack::update` at 76% of total CPU — a
/// 15-second main-thread hang for a 19-second sample. By taking
/// `isStreamingThisMessage` as a Bool prop from the parent, the bubble
/// only invalidates when its own message or that streaming flag
/// actually changes; AppState's delegated `agent*` mutations no
/// longer touch the bubbles.
struct AgentModeMessageView: View {
    let message: AgentMessage
    let isStreamingThisMessage: Bool
    /// User-chosen Agent chat base font size (pt). Drives the prose
    /// font in the user bubble and the inline Markdown body for the
    /// streaming assistant message. Defaults to system body so existing
    /// callers that don't pass it keep working.
    var baseFontSize: CGFloat = NSFont.systemFontSize
    @State private var isHoveringUser = false

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantContent
        case .system: assistantContent
        case .tool: EmptyView()
        case .workflowReport:
            if let report = message.workflowReport {
                AgentWorkflowCardView(report: report)
            } else {
                EmptyView()
            }
        }
    }

    // User messages: right-aligned, softly framed, and capped at ~78%
    // of the chat column so long pastes still wrap nicely.
    private var userBubble: some View {
        // For text-only providers we splice the qwen-vl description right
        // into the user message content (so the next turn echoes it back
        // verbatim, and so providers without image support still get the
        // signal). That made the bubble grow into a wall of AI-generated
        // bullets — see screenshot. Split it back out at render time: the
        // user's own prose stays inline, the description collapses into a
        // disclosure chip.
        let split = AgentUserContentSplitter.split(message.content)
        // rc13: collapsed the previous HStack { Spacer; VStack { VStack
        // {...}.frame(maxWidth:); footer } }.frame(maxWidth:) chain.
        // Two nested .frame(maxWidth:) plus an HStack Spacer is a
        // SwiftUI layout pathology — the Spacer needs to know the
        // container width to size itself, the inner frame needs the
        // outer geometry to compute its 0.78 share, and the outer
        // frame in turn depends on what the inner one returns. Under
        // LazyVStack scrolling the resulting `StackPlacement.flushMinorGroup`
        // / `LazyHVStack.lengthAndSpacing` ping-pong froze the main
        // thread on long sessions. New shape: a single VStack with one
        // trailing alignment, right-aligned by the parent ForEach's
        // frame(alignment: .leading)? — no, kept right via .frame(...
        // alignment: .trailing) once at the end, and the inner card
        // is sized by its content (capped via .frame on the bubble
        // itself, not on its inner padding chrome).
        return VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                if !message.textAttachments.isEmpty {
                    AgentTextAttachmentBubbleStrip(attachments: message.textAttachments)
                }
                if !split.visible.isEmpty {
                    // Inject zero-width break points into any
                    // unbreakable run >30 chars (see
                    // AgentLongTokenBreaker). Without this a
                    // user paste like a pnpm-store listing
                    // (150-char hash file names per line) sends
                    // SwiftUI's line-breaker into a freeze that
                    // takes the whole chat pane down on scroll.
                    // Real text restored.
                    Text(AgentLongTokenBreaker.inject(into: split.visible))
                        .font(.system(size: baseFontSize))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let description = split.description {
                    AgentImageDescriptionDisclosure(description: description)
                }
                if !message.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.images) { image in
                                AgentImageThumbnail(image: image, size: 96, allowsRemoval: false, onRemove: nil)
                            }
                        }
                    }
                }
                if !message.content.isEmpty || !message.textAttachments.isEmpty {
                    // Footer (timestamp + copy) is always shown — no longer
                    // hover-gated — so the send time is visible at rest.
                    AgentMessageFooter(message: message, alignment: .trailing, showsUserTimestamp: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .background(
                RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHoveringUser ? 0.03 : 0.018))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(isHoveringUser ? 0.026 : 0.014), lineWidth: 1)
            )
            .frame(maxWidth: AgentDesign.chatMaxContentWidth * AgentDesign.userMessageMaxWidthRatio, alignment: .leading)
            .onHover { isHoveringUser = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // Assistant messages: left-aligned, wrapped in a soft card so the
    // boundary of one model turn is obvious. Body renders through the
    // existing MarkdownPreview pipeline (also used by the editor's
    // Markdown side preview) — headings, lists, quotes, dividers, inline
    // formatting, and fenced code blocks all render. The parser flushes
    // an unterminated ``` block at EOF, so streaming code blocks show up
    // correctly while still being typed.
    private var assistantContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.78))
                .frame(width: 18, height: 20, alignment: .center)
                .padding(.top, 10)
            if !message.content.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    AgentAssistantMarkdownBody(
                        content: message.content,
                        isStreaming: isStreamingThisMessage,
                        baseFontSize: baseFontSize
                    )
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                        .background(
                            RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius, style: .continuous)
                                .stroke(Color.primary.opacity(0.035), lineWidth: 1)
                        )
                    // Don't show the footer while the stream is still
                    // running — elapsedSeconds isn't stamped until
                    // `.finishedTurn`, so the row would briefly read
                    // "copy · — · —" and then update. Wait until the
                    // turn settles.
                    if !isStreamingThisMessage {
                        AgentMessageFooter(message: message, alignment: .leading)
                            .padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
    }
}

// MARK: - Assistant Markdown body

/// Renders an assistant message's Markdown content as a SINGLE
/// `Text(AttributedString)` view. Pre-rc9 this used a `VStack` +
/// `ForEach(blocks)` + `MarkdownPreviewBlockView` per block — which
/// turned every assistant message into N SwiftUI views (one per
/// markdown block). Combined with the outer `LazyVStack` + the
/// `ForEach` over messages, SwiftUI ended up with **3 nested
/// ForEach** in a LazyVStack: messages → blocks → (inside code
/// blocks: lines). LLDB backtraces under freeze showed
/// `LazyStack.measureEstimates` recursively walking
/// `ForEachState.item(at:offset:) + 1644`, which is the smoking-gun
/// signature of SwiftUI's lazy-layout estimator expanding the entire
/// nested ForEach tree on every measure pass.
///
/// One Text per message collapses the view tree by 1-2 orders of
/// magnitude: a 200-block message goes from ~200 SwiftUI views to 1.
/// The tradeoff is we lose the per-block chrome — code blocks no
/// longer have a copy button or language pill, tables degrade to
/// piped text — but the chat pane stays responsive on long replies.
/// MarkdownPreviewBlockView itself is unchanged and still used by
/// the editor's Markdown side preview where view-tree size isn't a
/// concern.
struct AgentAssistantMarkdownBody: View {
    let content: String
    /// When true, appends a small blinking cursor at the end of the
    /// rendered body to signal that more tokens are still arriving.
    let isStreaming: Bool
    /// Base font size (pt) for the rendered Markdown body. Paragraph /
    /// list / quote / divider / table / code blocks scale from this;
    /// headings keep their relative hierarchy. Defaults to the system
    /// body size for callers that don't thread the user preference.
    var baseFontSize: CGFloat = NSFont.systemFontSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The Text on the bottom is the single-view substitute for
        // the old `VStack + ForEach(blocks)`. The streaming cursor
        // is a tiny separate view (one AgentStreamingCursor) — that
        // is fine because it's always either 0 or 1 child, never N.
        VStack(alignment: .leading, spacing: 4) {
            Text(AgentAssistantMarkdownRenderer.render(
                content,
                isDark: colorScheme == .dark,
                baseFontSize: baseFontSize
            ))
                .textSelection(.enabled)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if isStreaming {
                AgentStreamingCursor()
            }
        }
    }
}

/// Converts a streamed Markdown message into one `AttributedString`
/// that captures headings, paragraphs, lists, quotes, code blocks
/// (syntax highlighted + soft background), and dividers. Reused inside the
/// chat pane to keep the view-tree-per-message at one node.
///
/// Trade-offs vs the old per-block SwiftUI renderer:
///  - Code blocks have no per-block copy button or framed header in
///    this streaming path; the text remains selectable/copyable and
///    uses the shared syntax highlighter when the fence language is
///    known.
///  - Tables degrade to `cell │ cell` piped rows.
///  - Inline links inherit AttributedString's link styling.
/// The point of the trade-off is keeping SwiftUI's LazyVStack from
/// having to walk a deeply-nested ForEach tree during scroll-time
/// measurement passes.
enum AgentAssistantMarkdownRenderer {
    /// Bounded LRU keyed by content. Streaming new tokens changes
    /// the content (hash differs), so we re-render once and cache
    /// the result; subsequent SwiftUI body evaluations during scroll
    /// just hand back the prior AttributedString.
    private struct RenderCacheKey: Hashable {
        let contentHash: Int
        let isDark: Bool
        let baseFontSize: CGFloat
    }

    private static var cache: [RenderCacheKey: AttributedString] = [:]
    private static var cacheOrder: [RenderCacheKey] = []
    private static let cacheLock = NSLock()
    private static let cacheLimit = 128

    static func render(
        _ content: String,
        isDark: Bool,
        baseFontSize: CGFloat = NSFont.systemFontSize
    ) -> AttributedString {
        let key = RenderCacheKey(
            contentHash: content.hashValue,
            isDark: isDark,
            baseFontSize: baseFontSize
        )
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return hit }

        let result = build(from: content, isDark: isDark, baseFontSize: baseFontSize)

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

    private static func build(from content: String, isDark: Bool, baseFontSize: CGFloat) -> AttributedString {
        // Pre-process: inject zero-width breakpoints into unbreakable
        // runs of >30 chars. Otherwise a message containing e.g. a
        // pnpm-store listing (150-char hash paths, no spaces) freezes
        // SwiftUI Text's line-breaker on the whole chat pane.
        let normalized = AgentMarkdownNormalizer.normalizedForChatRendering(content)
        let safe = AgentLongTokenBreaker.inject(into: normalized)
        let blocks = MarkdownPreviewParser.blocks(from: safe)
        var result = AttributedString()
        var pendingCodeBottomSpacer = false

        func appendSeparator() {
            if !result.characters.isEmpty {
                result += AttributedString("\n\n")
                if pendingCodeBottomSpacer {
                    var spacer = AttributedString("\n")
                    spacer.font = .system(size: 6)
                    spacer.foregroundColor = Color.clear
                    result += spacer
                }
            }
            pendingCodeBottomSpacer = false
        }

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                appendSeparator()
                var heading = AttributedString(block.text)
                heading.font = headingFont(level: level)
                heading.foregroundColor = .primary
                result += heading

            case .paragraph:
                appendSeparator()
                var paragraph = inlineRendered(block.text, baseFontSize: baseFontSize)
                paragraph.foregroundColor = .primary
                result += paragraph

            case .quote:
                appendSeparator()
                var quote = AttributedString("❝ " + block.text)
                quote.font = .system(size: baseFontSize)
                quote.foregroundColor = .secondary
                result += quote

            case .unorderedList:
                appendSeparator()
                let bullet = block.indent == 0 ? "•" : (block.indent == 1 ? "◦" : "▪")
                let indent = String(repeating: "  ", count: block.indent)
                var prefix = AttributedString("\(indent)\(bullet) ")
                prefix.foregroundColor = .secondary
                var body = inlineRendered(block.text, baseFontSize: baseFontSize)
                body.foregroundColor = .primary
                result += prefix + body

            case .orderedList:
                appendSeparator()
                let indent = String(repeating: "  ", count: block.indent)
                var prefix = AttributedString("\(indent)1. ")
                prefix.foregroundColor = .secondary
                var body = inlineRendered(block.text, baseFontSize: baseFontSize)
                body.foregroundColor = .primary
                result += prefix + body

            case .code:
                // SwiftUI Text 不认 NSParagraphStyle，代码块的上下 margin
                // 只能用微型 spacer 行模拟（TextKit 历史路径走的是
                // applyCodeBlockVerticalMargins 的段落间距）。
                let hadPreviousContent = !result.characters.isEmpty
                appendSeparator()
                if hadPreviousContent {
                    var spacer = AttributedString("\n")
                    spacer.font = .system(size: 6)
                    spacer.foregroundColor = Color.clear
                    result += spacer
                }
                if let langHint = block.info?.trimmingCharacters(in: .whitespaces), !langHint.isEmpty {
                    var hint = AttributedString("\(langHint)\n")
                    hint.font = .system(size: 10, weight: .medium, design: .monospaced)
                    hint.foregroundColor = .secondary
                    result += hint
                }
                if let highlighted = highlightedCode(
                    block.text,
                    languageHint: block.info,
                    isDark: isDark,
                    baseFontSize: baseFontSize
                ) {
                    result += highlighted
                } else {
                    var code = AttributedString(block.text)
                    code.font = .system(size: baseFontSize, design: .monospaced)
                    code.foregroundColor = .primary
                    code.backgroundColor = Color.primary.opacity(0.035)
                    result += code
                }
                // 底部 margin 由下一次 appendSeparator 在 "\n\n" 之后补
                // 一行微型 spacer（与顶部结构完全镜像）；直接在这里追加
                // 会排在分隔符前面、把空隙撑成两个整行。代码块是最后
                // 一块时分隔符不会再来，flag 自然作废，流式中结尾是
                // 代码块也不会在气泡底部多出空白。
                pendingCodeBottomSpacer = true

            case .divider:
                appendSeparator()
                var divider = AttributedString("────────────────────────")
                divider.foregroundColor = .secondary
                result += divider

            case .table:
                // GFM tables render as monospaced `cell │ cell` rows
                // with a `─┼─` rule under the header — SwiftUI Text
                // can't host a real Grid in this single-AttributedString
                // path (rc9 fix: per-block ForEach in LazyVStack
                // freezes long replies). Wrap the plain layout with a
                // tinted background and a small spacer above so the
                // block is visually distinct from surrounding prose,
                // even while the stream is still in progress.
                let hadPrevious = !result.characters.isEmpty
                appendSeparator()
                if hadPrevious {
                    var leadSpacer = AttributedString("\n")
                    leadSpacer.font = .system(size: 4)
                    leadSpacer.foregroundColor = Color.clear
                    result += leadSpacer
                }
                if let headers = block.tableHeaders, let rows = block.tableRows {
                    let layout = AgentMarkdownTableFormatter.formattedWithSpans(
                        headers: headers,
                        rows: rows
                    )
                    if !layout.text.isEmpty {
                        var table = AttributedString(layout.text)
                        let monospaced = Font.system(size: baseFontSize, design: .monospaced)
                        table.font = monospaced
                        table.foregroundColor = .primary
                        table.backgroundColor = Color.primary.opacity(0.035)
                        // Bake the cells' inline Markdown (**bold**, *italic*,
                        // `code`) into the aligned monospaced layout. Spans are
                        // Character offsets into layout.text.
                        for span in layout.spans {
                            let lower = table.index(table.startIndex, offsetByCharacters: span.range.lowerBound)
                            let upper = table.index(table.startIndex, offsetByCharacters: span.range.upperBound)
                            let runRange = lower..<upper
                            switch span.style {
                            case .bold:
                                table[runRange].font = monospaced.bold()
                            case .italic:
                                table[runRange].font = monospaced.italic()
                            case .code:
                                table[runRange].backgroundColor = Color.primary.opacity(0.08)
                            }
                        }
                        result += table
                    }
                }
            }
        }

        return result
    }

    private static func highlightedCode(
        _ text: String,
        languageHint: String?,
        isDark: Bool,
        baseFontSize: CGFloat
    ) -> AttributedString? {
        guard let language = MarkdownCodeBlockView.language(forHint: languageHint) else {
            return nil
        }
        let font = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
        let theme: EditorTheme = isDark ? .graphite : .paper
        let highlighted = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlightSync(
            text,
            language: language,
            theme: theme,
            font: font
        ))
        let fullRange = NSRange(location: 0, length: highlighted.length)
        if fullRange.length > 0 {
            highlighted.addAttribute(.font, value: font, range: fullRange)
        }
        var rendered = AttributedString(highlighted)
        rendered.backgroundColor = Color.primary.opacity(0.035)
        return rendered
    }

    /// Run inline Markdown (bold/italic/`code`/links) through the
    /// same parser as the editor preview so styling stays consistent
    /// across the app. The base font size flows through so chat-mode
    /// can scale message body text per user preference.
    private static func inlineRendered(_ raw: String, baseFontSize: CGFloat) -> AttributedString {
        var rendered = MarkdownInline.attributedString(from: raw)
        let runs = rendered.runs
        for run in runs {
            // Only stamp a default font on runs that don't already
            // carry one (MarkdownInline assigns explicit fonts to
            // bold / italic / inline-code spans — leave those alone).
            if rendered[run.range].font == nil {
                rendered[run.range].font = .system(size: baseFontSize)
            }
        }
        return rendered
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .semibold)
        case 2: return .system(size: 18, weight: .semibold)
        case 3: return .system(size: 16, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }
}
