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
    let onRetryLastTurn: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AgentChatHistoryNSTextView {
        let view = AgentChatHistoryNSTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onRetryLastTurn = onRetryLastTurn
        configure(view)
        view.applyMessages(messages, isDark: colorScheme == .dark)
        return view
    }

    func updateNSView(_ nsView: AgentChatHistoryNSTextView, context: Context) {
        nsView.onRetryLastTurn = onRetryLastTurn
        nsView.applyMessages(messages, isDark: colorScheme == .dark)
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
            .underlineStyle: 0,
            .cursor: NSCursor.pointingHand,
        ]
    }
}

// MARK: - NSTextView subclass

final class AgentChatHistoryNSTextView: NSTextView {
    private var lastContentHash: Int?
    private var currentMessages: [AgentMessage] = []
    private var currentIsDark = false
    private var expandedToolGroupIDs = Set<String>()
    var onRetryLastTurn: (() -> Void)?

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = AgentChatHistoryBubbleLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)
        delegate = self
    }

    required init?(coder: NSCoder) {
        return nil
    }

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
    func applyMessages(_ messages: [AgentMessage], isDark: Bool) {
        currentMessages = messages
        currentIsDark = isDark
        renderCurrentMessages()
    }

    private func renderCurrentMessages() {
        let attr = AgentChatHistoryRenderer.render(
            messages: currentMessages,
            isDark: currentIsDark,
            expandedToolGroupIDs: expandedToolGroupIDs
        )
        let hash = attr.string.hashValue
        if hash == lastContentHash, attr.length == textStorage?.length {
            return
        }
        lastContentHash = hash
        textStorage?.setAttributedString(attr)
        invalidateIntrinsicContentSize()
    }
}

extension AgentChatHistoryNSTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let textStorage,
              charIndex >= 0,
              charIndex < textStorage.length else {
            return false
        }

        var codeButtonRange = NSRange(location: 0, length: 0)
        if let code = textStorage.attribute(
            .agentChatHistoryCodeCopyText,
            at: charIndex,
            effectiveRange: &codeButtonRange
        ) as? String,
           codeButtonRange.length == AgentChatHistoryCodeCopyChrome.idleLabel.utf16.count {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            replaceCopyButton(in: codeButtonRange, copied: true, code: code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) { [weak self] in
                self?.restoreCopyButtonIfNeeded(range: codeButtonRange, code: code)
            }
            return true
        }

        var footerButtonRange = NSRange(location: 0, length: 0)
        if let message = textStorage.attribute(
            .agentChatHistoryMessageCopyText,
            at: charIndex,
            effectiveRange: &footerButtonRange
        ) as? String,
           footerButtonRange.length == AgentChatHistoryFooterChrome.copyIdleLabel.utf16.count {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
            replaceFooterCopyButton(in: footerButtonRange, copied: true, message: message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) { [weak self] in
                self?.restoreFooterCopyButtonIfNeeded(range: footerButtonRange, message: message)
            }
            return true
        }

        if (textStorage.attribute(.agentChatHistoryRetryLastTurn, at: charIndex, effectiveRange: nil) as? NSNumber)?.boolValue == true {
            onRetryLastTurn?()
            return true
        }

        if let groupID = textStorage.attribute(.agentChatHistoryToolGroupID, at: charIndex, effectiveRange: nil) as? String {
            if expandedToolGroupIDs.contains(groupID) {
                expandedToolGroupIDs.remove(groupID)
            } else {
                expandedToolGroupIDs.insert(groupID)
            }
            lastContentHash = nil
            renderCurrentMessages()
            return true
        }

        return false
    }

    private func restoreCopyButtonIfNeeded(range: NSRange, code: String) {
        guard let textStorage,
              NSMaxRange(range) <= textStorage.length,
              textStorage.attributedSubstring(from: range).string == AgentChatHistoryCodeCopyChrome.copiedLabel else {
            return
        }
        replaceCopyButton(in: range, copied: false, code: code)
    }

    private func replaceCopyButton(in range: NSRange, copied: Bool, code: String) {
        guard let textStorage else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let color = copied ? NSColor.systemGreen : NSColor.secondaryLabelColor
        let replacement = AgentChatHistoryCodeCopyChrome.button(
            copied: copied,
            code: code,
            font: font,
            color: color
        )
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: replacement)
        textStorage.endEditing()
        invalidateIntrinsicContentSize()
    }

    private func restoreFooterCopyButtonIfNeeded(range: NSRange, message: String) {
        guard let textStorage,
              NSMaxRange(range) <= textStorage.length,
              textStorage.attributedSubstring(from: range).string == AgentChatHistoryFooterChrome.copyCopiedLabel else {
            return
        }
        replaceFooterCopyButton(in: range, copied: false, message: message)
    }

    private func replaceFooterCopyButton(in range: NSRange, copied: Bool, message: String) {
        guard let textStorage else { return }
        let replacement = AgentChatHistoryFooterChrome.copyButton(copied: copied, message: message)
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: replacement)
        textStorage.endEditing()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - TextKit chat chrome

private enum AgentChatHistoryBubbleKind: Int {
    case user
    case assistant
    case system
    case tool
    case toolSummary
}

private extension NSAttributedString.Key {
    static let agentChatHistoryBubbleKind = NSAttributedString.Key("AgentChatHistoryBubbleKind")
    static let agentChatHistoryCodeBlockID = NSAttributedString.Key("AgentChatHistoryCodeBlockID")
    static let agentChatHistoryCodeCopyText = NSAttributedString.Key("AgentChatHistoryCodeCopyText")
    static let agentChatHistoryMessageCopyText = NSAttributedString.Key("AgentChatHistoryMessageCopyText")
    static let agentChatHistoryRetryLastTurn = NSAttributedString.Key("AgentChatHistoryRetryLastTurn")
    static let agentChatHistoryToolGroupID = NSAttributedString.Key("AgentChatHistoryToolGroupID")
}

private final class AgentChatHistoryBubbleLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawAgentBubbles(forGlyphRange: glyphsToShow, at: origin)
        drawAgentCodeBlocks(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawAgentBubbles(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullStorageRange = NSRange(location: 0, length: textStorage.length)
        var drawnRanges = Set<String>()
        textStorage.enumerateAttribute(.agentChatHistoryBubbleKind, in: characterRange, options: []) { value, range, _ in
            guard range.length > 0 else { return }
            var fullEffectiveRange = NSRange(location: 0, length: 0)
            let effectiveValue = textStorage.attribute(
                .agentChatHistoryBubbleKind,
                at: range.location,
                longestEffectiveRange: &fullEffectiveRange,
                in: fullStorageRange
            )
            guard let kind = bubbleKind(from: effectiveValue) else { return }
            let drawKey = "\(fullEffectiveRange.location)-\(fullEffectiveRange.length)-\(kind.rawValue)"
            guard drawnRanges.insert(drawKey).inserted else { return }
            let bubbleGlyphRange = glyphRange(forCharacterRange: fullEffectiveRange, actualCharacterRange: nil)
            let visibleGlyphRange = NSIntersectionRange(bubbleGlyphRange, glyphsToShow)
            guard visibleGlyphRange.length > 0 else { return }
            let rect = bubbleRect(forGlyphRange: bubbleGlyphRange, kind: kind, at: origin)
            guard !rect.isNull, !rect.isEmpty else { return }
            bubbleColor(for: kind).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
    }

    private func bubbleRect(forGlyphRange fullGlyphRange: NSRange, kind: AgentChatHistoryBubbleKind, at origin: NSPoint) -> NSRect {
        var union = NSRect.null
        var containerWidth: CGFloat = 0
        enumerateLineFragments(forGlyphRange: fullGlyphRange) { lineFragmentRect, _, textContainer, lineGlyphRange, _ in
            containerWidth = max(containerWidth, self.usableWidth(for: textContainer, fallback: lineFragmentRect.width))
            let lineRange = NSIntersectionRange(lineGlyphRange, fullGlyphRange)
            guard lineRange.length > 0 else { return }
            var lineRect = self.boundingRect(forGlyphRange: lineRange, in: textContainer)
            guard !lineRect.isEmpty else { return }
            lineRect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
            union = union.isNull ? lineRect : union.union(lineRect)
        }
        guard !union.isNull else { return union }
        var rect = union.insetBy(dx: -12, dy: -8)
        guard containerWidth > 0 else { return rect.integral }

        switch kind {
        case .user:
            let maxWidth = max(260, containerWidth * 0.82)
            let width = min(max(rect.width, 260), maxWidth)
            rect.origin.x = origin.x + containerWidth - width - 30
            rect.size.width = width
        case .assistant, .system, .tool:
            rect.origin.x = origin.x + 20
            rect.size.width = max(240, containerWidth - 34)
        case .toolSummary:
            rect.origin.x = origin.x + 32
            rect.size.width = max(220, containerWidth - 48)
        }

        return rect.integral
    }

    private func drawAgentCodeBlocks(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullStorageRange = NSRange(location: 0, length: textStorage.length)
        var drawnRanges = Set<String>()
        textStorage.enumerateAttribute(.agentChatHistoryCodeBlockID, in: characterRange, options: []) { value, range, _ in
            guard range.length > 0, let value = value as? NSNumber else { return }
            var fullEffectiveRange = NSRange(location: 0, length: 0)
            _ = textStorage.attribute(
                .agentChatHistoryCodeBlockID,
                at: range.location,
                longestEffectiveRange: &fullEffectiveRange,
                in: fullStorageRange
            )
            let drawKey = "\(fullEffectiveRange.location)-\(fullEffectiveRange.length)-\(value.intValue)"
            guard drawnRanges.insert(drawKey).inserted else { return }
            let codeGlyphRange = glyphRange(forCharacterRange: fullEffectiveRange, actualCharacterRange: nil)
            let visibleGlyphRange = NSIntersectionRange(codeGlyphRange, glyphsToShow)
            guard visibleGlyphRange.length > 0 else { return }
            let rect = codeBlockRect(forGlyphRange: codeGlyphRange, at: origin)
            guard !rect.isNull, !rect.isEmpty else { return }
            NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.32).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func codeBlockRect(forGlyphRange fullGlyphRange: NSRange, at origin: NSPoint) -> NSRect {
        var union = NSRect.null
        var containerWidth: CGFloat = 0
        enumerateLineFragments(forGlyphRange: fullGlyphRange) { lineFragmentRect, _, textContainer, lineGlyphRange, _ in
            containerWidth = max(containerWidth, self.usableWidth(for: textContainer, fallback: lineFragmentRect.width))
            let lineRange = NSIntersectionRange(lineGlyphRange, fullGlyphRange)
            guard lineRange.length > 0 else { return }
            var lineRect = self.boundingRect(forGlyphRange: lineRange, in: textContainer)
            guard !lineRect.isEmpty else { return }
            lineRect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
            union = union.isNull ? lineRect : union.union(lineRect)
        }
        guard !union.isNull else { return union }
        var rect = union.insetBy(dx: -10, dy: -7)
        if containerWidth > 0 {
            rect.origin.x = origin.x + 48
            rect.size.width = max(220, containerWidth - 84)
        }
        return rect.integral
    }

    private func usableWidth(for textContainer: NSTextContainer, fallback: CGFloat) -> CGFloat {
        let width = textContainer.size.width
        if width.isFinite, width > 0, width < 20_000 {
            return width
        }
        return fallback
    }

    private func bubbleKind(from value: Any?) -> AgentChatHistoryBubbleKind? {
        if let value = value as? NSNumber {
            return AgentChatHistoryBubbleKind(rawValue: value.intValue)
        }
        return nil
    }

    private func bubbleColor(for kind: AgentChatHistoryBubbleKind) -> NSColor {
        switch kind {
        case .user:
            return NSColor.controlAccentColor.withAlphaComponent(0.88)
        case .assistant:
            return NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        case .system:
            return NSColor.systemPurple.withAlphaComponent(0.12)
        case .tool:
            return NSColor.textBackgroundColor.withAlphaComponent(0.92)
        case .toolSummary:
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        }
    }
}

private enum AgentChatHistoryCodeCopyChrome {
    static let idleLabel = "⧉ Copy"
    static let copiedLabel = "✓ Done"
    private static let linkValue = "agent-chat-history-copy-code"

    static func button(copied: Bool, code: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let label = copied ? copiedLabel : idleLabel
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .underlineStyle: 0,
            .agentChatHistoryCodeCopyText: code,
        ]
        if !copied {
            attributes[.link] = linkValue
        }
        return NSAttributedString(string: label, attributes: attributes)
    }
}

private enum AgentChatHistoryFooterChrome {
    static let copyIdleLabel = "⧉"
    static let copyCopiedLabel = "✓"
    static let retryLabel = "↻"
    private static let copyLinkValue = "agent-chat-history-copy-message"
    private static let retryLinkValue = "agent-chat-history-retry-last-turn"

    static func copyButton(copied: Bool, message: String) -> NSAttributedString {
        let label = copied ? copyCopiedLabel : copyIdleLabel
        var attributes = baseLinkAttributes(color: copied ? NSColor.systemGreen : NSColor.secondaryLabelColor)
        attributes[.agentChatHistoryMessageCopyText] = message
        if !copied {
            attributes[.link] = copyLinkValue
        }
        return NSAttributedString(string: label, attributes: attributes)
    }

    static func retryButton() -> NSAttributedString {
        var attributes = baseLinkAttributes(color: NSColor.secondaryLabelColor)
        attributes[.link] = retryLinkValue
        attributes[.agentChatHistoryRetryLastTurn] = NSNumber(value: true)
        return NSAttributedString(string: retryLabel, attributes: attributes)
    }

    static var separator: NSAttributedString {
        NSAttributedString(
            string: "  ",
            attributes: [
                .font: footerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    static func label(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: footerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    static var footerFont: NSFont {
        NSFont.systemFont(ofSize: 10, weight: .medium)
    }

    private static func baseLinkAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: footerFont,
            .foregroundColor: color,
            .underlineStyle: 0,
        ]
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

    static func render(
        messages: [AgentMessage],
        isDark: Bool,
        expandedToolGroupIDs: Set<String> = []
    ) -> NSAttributedString {
        // Hash all visible message payloads. The old cheap key
        // (count + total length + last message) was enough for append-
        // only streaming, but Markdown rendering makes stale-cache
        // misses more visible when an older row is edited in place.
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(expandedToolGroupIDs.sorted())
        for m in messages {
            hasher.combine(m.id)
            hasher.combine(m.role.rawValue)
            hasher.combine(m.content)
            hasher.combine(m.toolCallID)
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
        }
        let key = CacheKey(countAndHash: hasher.finalize(), isDark: isDark)
        if let hit = cache[key] {
            return hit
        }
        let result = makeAttributedString(
            messages: messages,
            isDark: isDark,
            expandedToolGroupIDs: expandedToolGroupIDs
        )
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return result
    }

    private static func makeAttributedString(
        messages: [AgentMessage],
        isDark: Bool,
        expandedToolGroupIDs: Set<String>
    ) -> NSAttributedString {
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
                    result.append(NSAttributedString(string: "\n"))
                }
                let group = ToolCallHistoryGroup(messages: groupMessages)
                appendToolCallGroup(
                    group,
                    isExpanded: expandedToolGroupIDs.contains(group.id),
                    to: result,
                    monoFont: monoFont,
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
                accentColor: accentColor,
                secondaryColor: secondaryColor
            )

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
                applyBubbleChrome(
                    kind: bubbleKind(for: message.role),
                    to: result,
                    range: NSRange(location: bodyStart, length: result.length - bodyStart),
                    paragraphStyle: bodyParagraphStyle(for: message.role),
                    foregroundColor: message.role == .user ? .white : nil
                )
            }

            // Tool call summary line (when the assistant emitted tool calls).
            if !message.toolCalls.isEmpty {
                let summary = toolCallSummary(for: message.toolCalls)
                if !body.isEmpty {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                }
                let summaryStart = result.length
                result.append(NSAttributedString(
                    string: summary,
                    attributes: [
                        .font: monoFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
                applyBubbleChrome(
                    kind: .toolSummary,
                    to: result,
                    range: NSRange(location: summaryStart, length: result.length - summaryStart),
                    paragraphStyle: toolSummaryParagraphStyle(),
                    foregroundColor: nil
                )
            }

            if shouldShowFooter(for: message, body: body) {
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                appendMessageFooter(
                    for: message,
                    isLatestAssistant: message.id == latestAssistantMessageID,
                    to: result
                )
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
    }

    private static func isToolCallOnly(_ message: AgentMessage) -> Bool {
        message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty
    }

    private static func appendHeader(
        for message: AgentMessage,
        isToolCallOnly: Bool,
        to result: NSMutableAttributedString,
        headerFont: NSFont,
        accentColor: NSColor,
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
            color = isToolCallOnly ? NSColor.systemGreen : accentColor
        case .tool:
            label = message.toolCallID.map { "Tool output · \($0)" } ?? "Tool output"
            avatar = "OUT"
            color = NSColor.systemGreen
        }

        let headerStart = result.length
        result.append(avatarToken(label: avatar, fill: color))
        result.append(NSAttributedString(
            string: " " + label + "\n",
            attributes: [
                .font: headerFont,
                .foregroundColor: isToolCallOnly ? color : secondaryColor,
            ]
        ))
        result.addAttribute(
            .paragraphStyle,
            value: headerParagraphStyle(for: message.role),
            range: NSRange(location: headerStart, length: result.length - headerStart)
        )
    }

    private static func avatarToken(label: String, fill: NSColor) -> NSAttributedString {
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
        style.paragraphSpacing = 5
        style.lineSpacing = 1
        style.headIndent = role == .user ? 150 : 0
        style.firstLineHeadIndent = style.headIndent
        style.tailIndent = role == .user ? -30 : -16
        return style
    }

    private static func bodyParagraphStyle(for role: AgentRole) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = role == .user ? .right : .left
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        switch role {
        case .user:
            style.headIndent = 160
            style.firstLineHeadIndent = 160
            style.tailIndent = -46
        case .assistant, .system, .tool:
            style.headIndent = 32
            style.firstLineHeadIndent = 32
            style.tailIndent = -18
        }
        return style
    }

    private static func toolSummaryParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = 1
        style.paragraphSpacing = 2
        style.headIndent = 22
        style.firstLineHeadIndent = 22
        style.tailIndent = -22
        return style
    }

    private static func toolGroupHeaderParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = 1
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
            style.headIndent = 160
            style.firstLineHeadIndent = 160
            style.tailIndent = -46
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
        foregroundColor: NSColor?
    ) {
        guard range.length > 0 else { return }
        attributed.addAttributes([
            .agentChatHistoryBubbleKind: NSNumber(value: kind.rawValue),
            .paragraphStyle: paragraphStyle,
        ], range: range)
        guard let foregroundColor else { return }
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            if attributes[.link] == nil {
                attributed.addAttribute(.foregroundColor, value: foregroundColor, range: subrange)
            }
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

        let detailsStart = result.length
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
            range: NSRange(location: detailsStart + 1, length: result.length - detailsStart - 1),
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
                let arguments = compactArguments(for: call, limit: argumentLimit)
                if arguments.isEmpty {
                    return "tool  \(call.toolName)  · \(byteLabel(call.argumentsJSON.count)) args"
                }
                return "tool  \(call.toolName)  \(arguments)  · \(byteLabel(call.argumentsJSON.count)) args"
            }
            .joined(separator: "\n")
    }

    private static func shouldShowFooter(for message: AgentMessage, body: String) -> Bool {
        switch message.role {
        case .user, .assistant:
            return !body.isEmpty
        case .system, .tool:
            return false
        }
    }

    private static func appendMessageFooter(
        for message: AgentMessage,
        isLatestAssistant: Bool,
        to result: NSMutableAttributedString
    ) {
        let start = result.length
        result.append(AgentChatHistoryFooterChrome.copyButton(copied: false, message: message.content))

        if message.role == .assistant {
            if let elapsed = message.elapsedSeconds, elapsed > 0 {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.label("◷ \(formatElapsed(elapsed))"))
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

        result.addAttribute(
            .paragraphStyle,
            value: footerParagraphStyle(for: message.role),
            range: NSRange(location: start, length: result.length - start)
        )
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
        let safe = AgentLongTokenBreaker.inject(into: source)
        let blocks = MarkdownPreviewParser.blocks(from: safe)
        guard !blocks.isEmpty else {
            result.append(inlineMarkdownAttributedString(safe, baseFont: bodyFont, color: bodyColor))
            return
        }

        var didAppendBlock = false
        var codeBlockIndex = 0
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
                let codeBlockStart = result.length
                let codeBlockID = codeBlockIndex
                codeBlockIndex += 1
                let language = block.info?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayLanguage = (language?.isEmpty == false) ? language! : "code"
                let codeHeaderFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
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
