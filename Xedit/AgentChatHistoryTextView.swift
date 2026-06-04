//
//  AgentChatHistoryTextView.swift
//  VeilWriter
//
//  Renders the assistant transcript's historical (non-streaming)
//  messages into a single NSTextView. SwiftUI's per-message bubble
//  + LazyVStack layout couldn't handle medium-sized rich messages
//  (1.5 KB content with a few markdown tables / fenced code blocks /
//  HTML details elements) without freezing the main thread — 15 rcs
//  of bisection ruled out every individual modifier and content
//  truncation strategy. TextKit handles the same content incrementally
//  with no freeze regardless of length. Historical messages still
//  render Markdown, but the renderer bakes the whole history into one
//  TextKit attributed string instead of asking SwiftUI to build a view
//  tree per Markdown block.
//
//  Streaming behavior: the message that's currently being streamed
//  (the last assistant message while `isAgentResponding == true`)
//  is rendered separately as the existing SwiftUI bubble in
//  AgentChatTranscript so users still get token-by-token updates
//  with markdown formatting + the streaming cursor. Once the turn
//  ends, that message folds into this NSTextView on the next refresh.
//

import AppKit
import SwiftUI

/// Bakes a list of messages into one NSAttributedString and displays
/// them in an embedded NSTextView. Sized to fit; SwiftUI lays the
/// wrapper out as a regular block view.
struct AgentChatHistoryTextView: NSViewRepresentable {
    let messages: [AgentMessage]
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AgentChatHistoryNSTextView {
        let view = AgentChatHistoryNSTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        configure(view)
        view.applyMessages(
            renderedAttributedString(messages: messages, isDark: colorScheme == .dark)
        )
        return view
    }

    func updateNSView(_ nsView: AgentChatHistoryNSTextView, context: Context) {
        nsView.applyMessages(
            renderedAttributedString(messages: messages, isDark: colorScheme == .dark)
        )
    }

    private func configure(_ view: AgentChatHistoryNSTextView) {
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.allowsUndo = false
        view.isRichText = true
        view.usesFontPanel = false
        view.usesRuler = false
        view.usesInspectorBar = false
        view.importsGraphics = false
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    /// Build the attributed string off the call site so SwiftUI's
    /// `updateNSView` stays cheap when content didn't change (the
    /// NSTextView subclass hashes incoming attributed strings and
    /// short-circuits no-op updates).
    private func renderedAttributedString(messages: [AgentMessage], isDark: Bool) -> NSAttributedString {
        AgentChatHistoryRenderer.render(messages: messages, isDark: isDark)
    }
}

// MARK: - NSTextView subclass

final class AgentChatHistoryNSTextView: NSTextView {
    private var lastContentHash: Int?

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).size
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    /// Swap text storage only when the attributed string actually
    /// changed. SwiftUI calls `updateNSView` on every parent body
    /// pass — without the guard we'd thrash TextKit every frame.
    func applyMessages(_ attr: NSAttributedString) {
        let hash = attr.string.hashValue
        if hash == lastContentHash, attr.length == textStorage?.length {
            return
        }
        lastContentHash = hash
        textStorage?.setAttributedString(attr)
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Renderer

/// Turns a list of `AgentMessage` into a single NSAttributedString
/// suitable for the chat-pane history NSTextView. Role headers are
/// rendered as small bold accent-colored labels; bodies use the
/// render Markdown for non-tool bodies, with tool outputs in monospace. Tool outputs
/// over 8 KB are truncated with a marker line so a 24 KB git-diff
/// dump doesn't bloat the visible transcript (users can still see
/// the full body via the per-message reader window).
enum AgentChatHistoryRenderer {
    /// Cache by (messages hash, isDark) so repeated SwiftUI updates
    /// during scroll (which don't change the message list) re-use
    /// the prior render.
    private static var cache: [CacheKey: NSAttributedString] = [:]
    private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 32

    private struct CacheKey: Hashable {
        let countAndHash: Int
        let isDark: Bool
    }

    static func render(messages: [AgentMessage], isDark: Bool) -> NSAttributedString {
        // Hash all visible message payloads. The old cheap key
        // (count + total length + last message) was enough for append-
        // only streaming, but Markdown rendering makes stale-cache
        // misses more visible when an older row is edited in place.
        var hasher = Hasher()
        hasher.combine(messages.count)
        for m in messages {
            hasher.combine(m.id)
            hasher.combine(m.role.rawValue)
            hasher.combine(m.content)
            hasher.combine(m.toolCallID)
            hasher.combine(m.reasoningContent)
            hasher.combine(m.toolCalls.count)
            for call in m.toolCalls {
                hasher.combine(call.externalID)
                hasher.combine(call.toolName)
                hasher.combine(call.argumentsJSON)
            }
        }
        let key = CacheKey(countAndHash: hasher.finalize(), isDark: isDark)
        if let hit = cache[key] {
            return hit
        }
        let result = makeAttributedString(messages: messages, isDark: isDark)
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return result
    }

    private static func makeAttributedString(messages: [AgentMessage], isDark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let bodyColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor
        let accentColor = NSColor.controlAccentColor
        let codeBackgroundColor = NSColor.controlBackgroundColor

        // Cap tool bodies on the visible transcript to keep TextKit's
        // layout work bounded. The reader window shows the full body.
        let toolBodyLimit = 8_000

        for message in messages {
            // Skip empty assistant placeholders (the loop emits them
            // while a turn is waiting on tool calls).
            if message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty {
                continue
            }

            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }

            // Role header.
            let header: String
            switch message.role {
            case .system: header = "SYSTEM"
            case .user: header = "USER"
            case .assistant: header = "ASSISTANT"
            case .tool: header = "TOOL\(message.toolCallID.map { " · \($0)" } ?? "")"
            }
            result.append(NSAttributedString(
                string: header + "\n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: accentColor,
                ]
            ))

            // Body.
            let useMono = (message.role == .tool)
            let body: String
            if useMono, message.content.count > toolBodyLimit {
                let head = String(message.content.prefix(toolBodyLimit))
                let omitted = message.content.count - toolBodyLimit
                body = head + "\n\n…[truncated \(omitted) characters from this tool output — open the message reader for the full body]"
            } else {
                body = message.content
            }

            if !body.isEmpty {
                if useMono {
                    appendPlainBody(body, to: result, font: monoFont, color: bodyColor)
                } else {
                    appendMarkdownBody(
                        body,
                        to: result,
                        bodyFont: bodyFont,
                        monoFont: monoFont,
                        bodyColor: bodyColor,
                        secondaryColor: secondaryColor,
                        codeBackgroundColor: codeBackgroundColor
                    )
                }
            }

            // Tool call summary line (when the assistant emitted tool calls).
            if !message.toolCalls.isEmpty {
                let summary = message.toolCalls
                    .map { "→ \($0.toolName)(\($0.argumentsJSON.count) byte args)" }
                    .joined(separator: "\n")
                if !body.isEmpty {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                }
                result.append(NSAttributedString(
                    string: summary,
                    attributes: [
                        .font: monoFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
            }
        }

        _ = isDark  // currently unused — colors come from the system semantic palette
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

    private static func appendMarkdownBody(
        _ source: String,
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        monoFont: NSFont,
        bodyColor: NSColor,
        secondaryColor: NSColor,
        codeBackgroundColor: NSColor
    ) {
        let safe = AgentLongTokenBreaker.inject(into: source)
        let blocks = MarkdownPreviewParser.blocks(from: safe)
        guard !blocks.isEmpty else {
            result.append(inlineMarkdownAttributedString(safe, baseFont: bodyFont, color: bodyColor))
            return
        }

        var didAppendBlock = false
        func appendBlockSeparator() {
            if didAppendBlock {
                result.append(NSAttributedString(
                    string: "\n\n",
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
                result.append(inlineMarkdownAttributedString(
                    block.text,
                    baseFont: headingFont(level: level),
                    color: bodyColor
                ))

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
                appendBlockSeparator()
                if let language = block.info?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                    result.append(NSAttributedString(
                        string: "\(language)\n",
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                            .foregroundColor: secondaryColor,
                        ]
                    ))
                }
                result.append(NSAttributedString(
                    string: block.text,
                    attributes: [
                        .font: monoFont,
                        .foregroundColor: bodyColor,
                        .backgroundColor: codeBackgroundColor,
                    ]
                ))

            case .divider:
                appendBlockSeparator()
                result.append(NSAttributedString(
                    string: "-----",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))

            case .table:
                appendBlockSeparator()
                if let headers = block.tableHeaders, let rows = block.tableRows {
                    let table = ([headers] + rows)
                        .map { $0.joined(separator: " | ") }
                        .joined(separator: "\n")
                    result.append(NSAttributedString(
                        string: table,
                        attributes: [
                            .font: monoFont,
                            .foregroundColor: bodyColor,
                        ]
                    ))
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
