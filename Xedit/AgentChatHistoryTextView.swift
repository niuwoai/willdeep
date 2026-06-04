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
//  with no freeze regardless of length.
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
/// system body font, with tool outputs in monospace. Tool outputs
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
        // Hash on (count, total content length, last message id+length).
        // Cheaper than hashing every byte of every message but still
        // disambiguates the common case where messages append.
        var hasher = Hasher()
        hasher.combine(messages.count)
        var totalLength = 0
        for m in messages {
            totalLength &+= m.content.count
        }
        hasher.combine(totalLength)
        if let last = messages.last {
            hasher.combine(last.id)
            hasher.combine(last.content.count)
            hasher.combine(last.toolCalls.count)
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
                result.append(NSAttributedString(
                    string: body,
                    attributes: [
                        .font: useMono ? monoFont : bodyFont,
                        .foregroundColor: bodyColor,
                    ]
                ))
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
}
