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
    /// User-controlled base size for the transcript body, threaded
    /// from `AppState.agentChatBaseFontSize`. Tool summaries and
    /// chrome stay on fixed sizes inside the renderer.
    let baseFontSize: CGFloat
    let onRetryLastTurn: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AgentChatHistoryNSTextView {
        let view = AgentChatHistoryNSTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onRetryLastTurn = onRetryLastTurn
        configure(view)
        view.applyMessages(
            messages,
            isDark: colorScheme == .dark,
            baseFontSize: baseFontSize
        )
        return view
    }

    func updateNSView(_ nsView: AgentChatHistoryNSTextView, context: Context) {
        nsView.onRetryLastTurn = onRetryLastTurn
        nsView.applyMessages(
            messages,
            isDark: colorScheme == .dark,
            baseFontSize: baseFontSize
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
    private var currentBaseFontSize: CGFloat = NSFont.systemFontSize
    private var expandedToolGroupIDs = Set<String>()
    private var hoveredUserMessageID: UUID?
    private var hoverTrackingArea: NSTrackingArea?
    /// Pending "restore copy button label" work items, one per outstanding
    /// click. Rapid repeated clicks on the same (or different) copy
    /// buttons cancel the prior pending restore — pre-rc38 these
    /// asyncAfter blocks accumulated, causing the label to flicker
    /// "Copied"→"Copy"→"Copied" out of order.
    private var pendingCodeCopyRestore: DispatchWorkItem?
    private var pendingFooterCopyRestore: DispatchWorkItem?
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredUserMessage(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredUserMessage(id: nil)
        super.mouseExited(with: event)
    }

    /// Swap text storage only when the attributed string actually
    /// changed. SwiftUI calls `updateNSView` on every parent body
    /// pass — without the guard we'd thrash TextKit every frame.
    func applyMessages(
        _ messages: [AgentMessage],
        isDark: Bool,
        baseFontSize: CGFloat = NSFont.systemFontSize
    ) {
        currentMessages = messages
        currentIsDark = isDark
        currentBaseFontSize = baseFontSize
        renderCurrentMessages()
    }

    private func renderCurrentMessages() {
        let attr = AgentChatHistoryRenderer.render(
            messages: currentMessages,
            isDark: currentIsDark,
            expandedToolGroupIDs: expandedToolGroupIDs,
            hoveredUserMessageID: hoveredUserMessageID,
            baseFontSize: currentBaseFontSize
        )
        var hasher = Hasher()
        hasher.combine(attr.string)
        hasher.combine(attr.length)
        hasher.combine(currentIsDark)
        hasher.combine(currentBaseFontSize)
        hasher.combine(expandedToolGroupIDs.sorted())
        hasher.combine(hoveredUserMessageID)
        let hash = hasher.finalize()
        if hash == lastContentHash, attr.length == textStorage?.length {
            return
        }
        lastContentHash = hash
        textStorage?.setAttributedString(attr)
        invalidateIntrinsicContentSize()
    }

    private func updateHoveredUserMessage(at point: NSPoint) {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
            updateHoveredUserMessage(id: nil)
            return
        }
        var containerPoint = point
        containerPoint.x -= textContainerInset.width
        containerPoint.y -= textContainerInset.height
        guard containerPoint.x >= 0, containerPoint.y >= 0 else {
            updateHoveredUserMessage(id: nil)
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            updateHoveredUserMessage(id: nil)
            return
        }
        let lineFragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard lineFragment.insetBy(dx: -24, dy: -8).contains(containerPoint) else {
            updateHoveredUserMessage(id: nil)
            return
        }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length,
              let idString = textStorage.attribute(.agentChatHistoryUserMessageID, at: charIndex, effectiveRange: nil) as? String,
              let id = UUID(uuidString: idString) else {
            updateHoveredUserMessage(id: nil)
            return
        }
        updateHoveredUserMessage(id: id)
    }

    private func updateHoveredUserMessage(id: UUID?) {
        guard hoveredUserMessageID != id else { return }
        hoveredUserMessageID = id
        lastContentHash = nil
        renderCurrentMessages()
    }
}

extension AgentChatHistoryNSTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let textStorage,
              charIndex >= 0,
              charIndex < textStorage.length else {
            return isInternalActionLink(link)
        }

        var codeButtonRange = NSRange(location: 0, length: 0)
        if let code = textStorage.attribute(
            .agentChatHistoryCodeCopyText,
            at: charIndex,
            effectiveRange: &codeButtonRange
        ) as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            replaceCopyButton(in: codeButtonRange, copied: true, code: code)
            pendingCodeCopyRestore?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.restoreCopyButtonIfNeeded(range: codeButtonRange, code: code)
            }
            pendingCodeCopyRestore = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
            return true
        }

        var footerButtonRange = NSRange(location: 0, length: 0)
        if let message = textStorage.attribute(
            .agentChatHistoryMessageCopyText,
            at: charIndex,
            effectiveRange: &footerButtonRange
        ) as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
            replaceFooterCopyButton(in: footerButtonRange, copied: true, message: message)
            pendingFooterCopyRestore?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.restoreFooterCopyButtonIfNeeded(range: footerButtonRange, message: message)
            }
            pendingFooterCopyRestore = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
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

        return isInternalActionLink(link)
    }

    private func isInternalActionLink(_ link: Any) -> Bool {
        let value: String?
        if let string = link as? String {
            value = string
        } else if let string = link as? NSString {
            value = string as String
        } else if let url = link as? URL {
            value = url.absoluteString
        } else if let url = link as? NSURL {
            value = url.absoluteString
        } else {
            value = nil
        }
        guard let value else { return false }
        return [
            AgentChatHistoryCodeCopyChrome.linkValue,
            AgentChatHistoryFooterChrome.copyLinkValue,
            AgentChatHistoryFooterChrome.retryLinkValue,
            "agent-chat-history-tool-group",
        ].contains(value)
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
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
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

enum AgentChatHistoryBubbleKind: Int {
    case user
    case assistant
    case system
    case tool
    case toolSummary
}

enum AgentChatHistoryLayoutMetrics {
    static let userBubbleMaxWidthRatio: CGFloat = 0.82
    static let userBubbleMinWidth: CGFloat = 260
    static let userBubbleTrailingMargin: CGFloat = 30
    static let userBodyHeadIndent: CGFloat = 172
    static let userBodyTailIndent: CGFloat = -46
}

extension NSAttributedString.Key {
    static let agentChatHistoryBubbleKind = NSAttributedString.Key("AgentChatHistoryBubbleKind")
    static let agentChatHistoryCodeBlockID = NSAttributedString.Key("AgentChatHistoryCodeBlockID")
    static let agentChatHistoryCodeCopyText = NSAttributedString.Key("AgentChatHistoryCodeCopyText")
    static let agentChatHistoryMessageCopyText = NSAttributedString.Key("AgentChatHistoryMessageCopyText")
    static let agentChatHistoryRetryLastTurn = NSAttributedString.Key("AgentChatHistoryRetryLastTurn")
    static let agentChatHistoryTableBlockID = NSAttributedString.Key("AgentChatHistoryTableBlockID")
    static let agentChatHistoryToolGroupID = NSAttributedString.Key("AgentChatHistoryToolGroupID")
    static let agentChatHistoryUserMessageID = NSAttributedString.Key("AgentChatHistoryUserMessageID")
}

private final class AgentChatHistoryBubbleLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawAgentBubbles(forGlyphRange: glyphsToShow, at: origin)
        drawAgentTables(forGlyphRange: glyphsToShow, at: origin)
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

    private func drawAgentTables(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullStorageRange = NSRange(location: 0, length: textStorage.length)
        var drawnRanges = Set<String>()
        textStorage.enumerateAttribute(.agentChatHistoryTableBlockID, in: characterRange, options: []) { value, range, _ in
            guard range.length > 0, let value = value as? NSNumber else { return }
            var fullEffectiveRange = NSRange(location: 0, length: 0)
            _ = textStorage.attribute(
                .agentChatHistoryTableBlockID,
                at: range.location,
                longestEffectiveRange: &fullEffectiveRange,
                in: fullStorageRange
            )
            let drawKey = "\(fullEffectiveRange.location)-\(fullEffectiveRange.length)-\(value.intValue)"
            guard drawnRanges.insert(drawKey).inserted else { return }
            let tableGlyphRange = glyphRange(forCharacterRange: fullEffectiveRange, actualCharacterRange: nil)
            let visibleGlyphRange = NSIntersectionRange(tableGlyphRange, glyphsToShow)
            guard visibleGlyphRange.length > 0 else { return }
            let rect = tableBlockRect(forGlyphRange: tableGlyphRange, at: origin)
            guard !rect.isNull, !rect.isEmpty else { return }
            NSColor.controlBackgroundColor.withAlphaComponent(0.38).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.14).setStroke()
            path.lineWidth = 1
            path.stroke()
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
        let verticalInset: CGFloat
        switch kind {
        case .user:
            verticalInset = 13
        case .toolSummary:
            // Keep this snug — when a tool summary sits directly under
            // an assistant body the two bubbles share an edge, and any
            // padding > the gap between their last/first line baselines
            // makes the two rounded rects overlap.
            verticalInset = 5
        case .assistant, .system, .tool:
            verticalInset = 8
        }
        var rect = union.insetBy(dx: -12, dy: -verticalInset)
        guard containerWidth > 0 else { return rect.integral }

        switch kind {
        case .user:
            let width = max(
                AgentChatHistoryLayoutMetrics.userBubbleMinWidth,
                containerWidth * AgentChatHistoryLayoutMetrics.userBubbleMaxWidthRatio
            )
            rect.origin.x = origin.x + containerWidth - width - AgentChatHistoryLayoutMetrics.userBubbleTrailingMargin
            rect.size.width = width
        case .assistant, .system, .tool:
            rect.origin.x = origin.x + 20
            rect.size.width = max(240, containerWidth - 34)
        case .toolSummary:
            rect.origin.x = origin.x + 12
            rect.size.width = max(220, containerWidth - 24)
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
            NSColor.quaternaryLabelColor.withAlphaComponent(0.05).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.10).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func tableBlockRect(forGlyphRange fullGlyphRange: NSRange, at origin: NSPoint) -> NSRect {
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
        var rect = union.insetBy(dx: -10, dy: -6)
        if containerWidth > 0 {
            rect.origin.x = origin.x + 30
            rect.size.width = max(220, containerWidth - 68)
        }
        return rect.integral
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
            rect.origin.x = origin.x + 30
            rect.size.width = max(220, containerWidth - 68)
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
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
        case .assistant:
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
        case .system:
            return NSColor.systemPurple.withAlphaComponent(0.12)
        case .tool:
            return NSColor.textBackgroundColor.withAlphaComponent(0.92)
        case .toolSummary:
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
        }
    }
}
