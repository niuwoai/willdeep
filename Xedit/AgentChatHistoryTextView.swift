//
//  AgentChatHistoryTextView.swift
//  WillDeep
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
    /// 1.103.0-rc11: 本轮 turn-report 的工具调用次数(>0 才会在最近一条
    /// assistant 的 footer 里渲染 doc.text + 数字图标);nil/0 表示没有
    /// report 可看(0 次 tool call 的轮次原 PostStrip 也是不显示)。
    var latestTurnReportToolCount: Int? = nil
    /// 1.103.0-rc11: footer 报告图标被点时触发(SwiftUI 侧打开 popover)。
    var onShowTurnReport: (() -> Void)? = nil
    var onReferenceGeneratedImage: ((String) -> Void)? = nil
    var onOpenFilePath: ((String) -> Void)? = nil
    var searchQuery: String = ""
    var activeSearchMatchIndex: Int? = nil
    var onSearchResultCountChange: ((Int) -> Void)? = nil
    /// Imperative "scroll to this user message" trigger from the left-edge
    /// user-input minimap. The token debounces so the same target can be
    /// re-selected: bump the token to fire again with the same id.
    var scrollToUserMessageToken: Int = 0
    var scrollToUserMessageID: UUID? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AgentChatHistoryNSTextView {
        let view = AgentChatHistoryNSTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onRetryLastTurn = onRetryLastTurn
        view.onShowTurnReport = onShowTurnReport
        view.onReferenceGeneratedImage = onReferenceGeneratedImage
        view.onOpenFilePath = onOpenFilePath
        view.onSearchResultCountChange = onSearchResultCountChange
        configure(view)
        view.applyMessages(
            messages,
            isDark: colorScheme == .dark,
            baseFontSize: baseFontSize,
            latestTurnReportToolCount: latestTurnReportToolCount
        )
        view.applySearch(
            query: searchQuery,
            activeMatchIndex: activeSearchMatchIndex,
            isDark: colorScheme == .dark
        )
        return view
    }

    func updateNSView(_ nsView: AgentChatHistoryNSTextView, context: Context) {
        nsView.onRetryLastTurn = onRetryLastTurn
        nsView.onShowTurnReport = onShowTurnReport
        nsView.onReferenceGeneratedImage = onReferenceGeneratedImage
        nsView.onOpenFilePath = onOpenFilePath
        nsView.onSearchResultCountChange = onSearchResultCountChange
        nsView.applyMessages(
            messages,
            isDark: colorScheme == .dark,
            baseFontSize: baseFontSize,
            latestTurnReportToolCount: latestTurnReportToolCount
        )
        nsView.applySearch(
            query: searchQuery,
            activeMatchIndex: activeSearchMatchIndex,
            isDark: colorScheme == .dark
        )
        nsView.applyScrollRequest(token: scrollToUserMessageToken, userMessageID: scrollToUserMessageID)
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
    /// Cheap identity fingerprint of the last applyMessages input
    /// (id + role + content.count + reasoning.count + per-toolCall id /
    /// name / argumentsJSON.count, plus isDark + baseFontSize). When this
    /// matches we skip the renderer entirely — the streaming hot path
    /// (every textDelta re-publishes @Published, SwiftUI re-evaluates
    /// AgentChatTranscript.body, which rebuilds this view and triggers
    /// updateNSView → applyMessages, even though the history array's
    /// contents are unchanged because the streaming assistant message
    /// is rendered as a separate SwiftUI bubble). Without this early
    /// exit each token paid O(history total content bytes) just to
    /// hash the AgentChatHistoryRenderer cache key, pegging a core at
    /// 95%+ on conversations with multi-KB tool outputs.
    private var lastInputFingerprint: Int?
    private var currentMessages: [AgentMessage] = []
    private var currentIsDark = false
    private var currentBaseFontSize: CGFloat = NSFont.systemFontSize
    private var currentLatestTurnReportToolCount: Int? = nil
    private var currentBaseAttributedString = NSAttributedString()
    private var currentSearchQuery = ""
    private var currentActiveSearchMatchIndex: Int?
    private var currentSearchIsDark = false
    private var lastReportedSearchResultCount: Int?
    private var expandedToolGroupIDs = Set<String>()
    private var hoveredUserMessageID: UUID?
    private var hoverTrackingArea: NSTrackingArea?
    /// Pending "restore copy button label" work items keyed by the
    /// button's stable text-storage location. Rapid repeated clicks on
    /// the same button refresh that button's countdown without preventing
    /// other copied buttons from restoring themselves.
    private var pendingCodeCopyRestores: [Int: DispatchWorkItem] = [:]
    private var pendingFooterCopyRestores: [Int: DispatchWorkItem] = [:]
    var onRetryLastTurn: (() -> Void)?
    /// 1.103.0-rc11: TextKit footer 里 doc.text 图标被点时回调 SwiftUI 侧
    /// 弹出 AgentTurnReportCard popover —— 见 AgentChatTranscript。
    var onShowTurnReport: (() -> Void)?
    var onReferenceGeneratedImage: ((String) -> Void)?
    var onOpenFilePath: ((String) -> Void)?
    var onSearchResultCountChange: ((Int) -> Void)?

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
        let drawingHeight = used.height + AgentChatHistoryLayoutMetrics.bubbleDrawingVerticalOverscan
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(drawingHeight))
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = generatedImageReferenceMarker(at: point) else {
            return super.menu(for: event)
        }
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: L10n.AgentGeneratedImage.quoteAction,
            action: #selector(quoteGeneratedImageFromMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = marker
        menu.addItem(item)
        return menu
    }

    @objc private func quoteGeneratedImageFromMenu(_ sender: NSMenuItem) {
        guard let marker = sender.representedObject as? String else { return }
        onReferenceGeneratedImage?(marker)
    }

    /// Swap text storage only when the attributed string actually
    /// changed. SwiftUI calls `updateNSView` on every parent body
    /// pass — without the guard we'd thrash TextKit every frame.
    func applyMessages(
        _ messages: [AgentMessage],
        isDark: Bool,
        baseFontSize: CGFloat = NSFont.systemFontSize,
        latestTurnReportToolCount: Int? = nil
    ) {
        let fp = Self.inputFingerprint(
            messages: messages,
            isDark: isDark,
            baseFontSize: baseFontSize,
            latestTurnReportToolCount: latestTurnReportToolCount
        )
        if fp == lastInputFingerprint {
            return
        }
        lastInputFingerprint = fp
        currentMessages = messages
        currentIsDark = isDark
        currentBaseFontSize = baseFontSize
        currentLatestTurnReportToolCount = latestTurnReportToolCount
        renderCurrentMessages()
    }

    /// Identity-only digest of the inputs to applyMessages — uses
    /// `String.count` instead of hashing the actual bytes so we don't
    /// re-walk multi-KB tool outputs on every streaming token. Safe for
    /// the history array because streaming assistant messages are
    /// rendered as a SwiftUI bubble (not here), so the history is
    /// append-only and never gets in-place content edits at a fixed
    /// length.
    private static func inputFingerprint(
        messages: [AgentMessage],
        isDark: Bool,
        baseFontSize: CGFloat,
        latestTurnReportToolCount: Int?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(isDark)
        hasher.combine(baseFontSize)
        hasher.combine(messages.count)
        hasher.combine(latestTurnReportToolCount ?? -1)
        for m in messages {
            hasher.combine(m.id)
            hasher.combine(m.role.rawValue)
            hasher.combine(m.content.count)
            hasher.combine(m.reasoningContent?.count ?? -1)
            hasher.combine(m.images.count)
            for image in m.images {
                hasher.combine(image.id)
                hasher.combine(image.mimeType)
                hasher.combine(image.dataBase64.count)
                hasher.combine(image.source?.rawValue)
                hasher.combine(image.filePath)
                hasher.combine(image.model)
                hasher.combine(image.prompt)
                hasher.combine(image.createdAt)
            }
            hasher.combine(m.textAttachments.count)
            hasher.combine(m.toolCallID)
            hasher.combine(m.usageTokens)
            hasher.combine(m.promptTokens)
            hasher.combine(m.completionTokens)
            hasher.combine(m.cachedPromptTokens)
            hasher.combine(m.cacheWritePromptTokens)
            hasher.combine(m.reasoningTokens)
            hasher.combine(m.managedRoute?.selectedModel)
            hasher.combine(m.managedRoute?.tier.rawValue)
            hasher.combine(m.managedRoute?.didEscalate)
            hasher.combine(m.managedRoute?.didFallback)
            hasher.combine(m.toolCalls.count)
            for tc in m.toolCalls {
                hasher.combine(tc.externalID)
                hasher.combine(tc.toolName)
                hasher.combine(tc.argumentsJSON.count)
            }
        }
        return hasher.finalize()
    }

    private func renderCurrentMessages() {
        let attr = AgentChatHistoryRenderer.render(
            messages: currentMessages,
            isDark: currentIsDark,
            expandedToolGroupIDs: expandedToolGroupIDs,
            hoveredUserMessageID: hoveredUserMessageID,
            baseFontSize: currentBaseFontSize,
            latestTurnReportToolCount: currentLatestTurnReportToolCount
        )
        var hasher = Hasher()
        hasher.combine(attr.string)
        hasher.combine(attr.length)
        hasher.combine(currentIsDark)
        hasher.combine(currentBaseFontSize)
        hasher.combine(expandedToolGroupIDs.sorted())
        hasher.combine(hoveredUserMessageID)
        let hash = hasher.finalize()
        if hash == lastContentHash, attr.length == currentBaseAttributedString.length {
            return
        }
        lastContentHash = hash
        currentBaseAttributedString = attr
        applySearchHighlight()
        invalidateIntrinsicContentSize()
    }

    func applySearch(query: String, activeMatchIndex: Int?, isDark: Bool) {
        currentSearchQuery = AgentTranscriptSearch.normalizedQuery(query)
        currentActiveSearchMatchIndex = activeMatchIndex
        currentSearchIsDark = isDark
        applySearchHighlight()
    }

    private func applySearchHighlight() {
        let result = AgentTranscriptSearch.highlightedString(
            from: currentBaseAttributedString,
            query: currentSearchQuery,
            activeMatchIndex: currentActiveSearchMatchIndex,
            isDark: currentSearchIsDark
        )
        textStorage?.setAttributedString(result.attributedString)
        reportSearchResultCountIfNeeded(result.matchCount)
        scrollActiveSearchMatchIfNeeded(ranges: result.matchRanges)
        invalidateIntrinsicContentSize()
    }

    private func reportSearchResultCountIfNeeded(_ count: Int) {
        guard lastReportedSearchResultCount != count else { return }
        lastReportedSearchResultCount = count
        onSearchResultCountChange?(count)
    }

    private func scrollActiveSearchMatchIfNeeded(ranges: [NSRange]) {
        guard let index = AgentTranscriptSearch.clampedActiveIndex(
            currentActiveSearchMatchIndex,
            count: ranges.count
        ) else { return }
        let range = ranges[index]
        guard range.location >= 0, NSMaxRange(range) <= (textStorage?.length ?? 0) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.scrollRangeToVisible(range)
        }
    }

    // MARK: - User-input minimap scroll

    private var lastHandledScrollToken = 0

    /// Called from the representable's `updateNSView` with the minimap's scroll
    /// token/id. Fires at most once per new token (0 == the initial no-op).
    func applyScrollRequest(token: Int, userMessageID: UUID?) {
        guard token != lastHandledScrollToken else { return }
        lastHandledScrollToken = token
        guard let userMessageID else { return }
        _ = scrollToUserMessage(id: userMessageID)
    }

    /// Scrolls so the top of the user message stamped with `id` is visible.
    /// Returns true if that message exists in this text view.
    @discardableResult
    func scrollToUserMessage(id: UUID) -> Bool {
        guard let textStorage, textStorage.length > 0 else { return false }
        let target = id.uuidString
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var found: NSRange?
        textStorage.enumerateAttribute(.agentChatHistoryUserMessageID, in: fullRange, options: []) { value, range, stop in
            if let string = value as? String, string == target {
                found = range
                stop.pointee = true
            }
        }
        guard let range = found else { return false }
        let anchor = NSRange(location: range.location, length: 0)
        DispatchQueue.main.async { [weak self] in
            self?.scrollRangeToVisible(anchor)
        }
        return true
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
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length else {
            updateHoveredUserMessage(id: nil)
            return
        }
        // The formatter stamps `agentChatHistoryUserMessageID` on the
        // entire user-message range — "You" header, body, and footer all
        // share the same UUID. Hit-test against the union of every line
        // in that range, not just the line fragment under the cursor, so
        // hover stays sticky as the mouse traverses the empty horizontal
        // space between a short body (left-aligned) and the right-aligned
        // copy icon in the footer. The old `lineFragmentUsedRect` +
        // (-24, -8) check failed mid-transit for short messages like
        // "hey", causing the footer to vanish before the cursor reached
        // the copy icon.
        var attributeRange = NSRange(location: 0, length: 0)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard let idString = textStorage.attribute(
            .agentChatHistoryUserMessageID,
            at: charIndex,
            longestEffectiveRange: &attributeRange,
            in: fullRange
        ) as? String,
              let id = UUID(uuidString: idString),
              attributeRange.length > 0 else {
            updateHoveredUserMessage(id: nil)
            return
        }
        let attributeGlyphRange = layoutManager.glyphRange(forCharacterRange: attributeRange, actualCharacterRange: nil)
        let messageRect = layoutManager.boundingRect(forGlyphRange: attributeGlyphRange, in: textContainer)
        guard !messageRect.isEmpty,
              messageRect.insetBy(dx: -8, dy: -6).contains(containerPoint) else {
            updateHoveredUserMessage(id: nil)
            return
        }
        updateHoveredUserMessage(id: id)
    }

    private func generatedImageReferenceMarker(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
            return nil
        }
        var containerPoint = point
        containerPoint.x -= textContainerInset.width
        containerPoint.y -= textContainerInset.height
        guard containerPoint.x >= 0, containerPoint.y >= 0 else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return nil
        }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length else {
            return nil
        }
        return textStorage.attribute(
            .agentChatHistoryImageReferenceMarker,
            at: charIndex,
            effectiveRange: nil
        ) as? String
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
            codeButtonRange = AgentChatHistoryCopyRangeResolver.contiguousRange(
                in: textStorage,
                key: .agentChatHistoryCodeCopyText,
                matching: code,
                seedRange: codeButtonRange
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            replaceCopyButton(in: codeButtonRange, copied: true, code: code)
            let restoreKey = codeButtonRange.location
            pendingCodeCopyRestores[restoreKey]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.restoreCopyButtonIfNeeded(range: codeButtonRange, code: code, restoreKey: restoreKey)
            }
            pendingCodeCopyRestores[restoreKey] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
            return true
        }

        var footerButtonRange = NSRange(location: 0, length: 0)
        if let message = textStorage.attribute(
            .agentChatHistoryMessageCopyText,
            at: charIndex,
            effectiveRange: &footerButtonRange
        ) as? String {
            footerButtonRange = AgentChatHistoryCopyRangeResolver.contiguousRange(
                in: textStorage,
                key: .agentChatHistoryMessageCopyText,
                matching: message,
                seedRange: footerButtonRange
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
            replaceFooterCopyButton(in: footerButtonRange, copied: true, message: message)
            let restoreKey = footerButtonRange.location
            pendingFooterCopyRestores[restoreKey]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.restoreFooterCopyButtonIfNeeded(range: footerButtonRange, message: message, restoreKey: restoreKey)
            }
            pendingFooterCopyRestores[restoreKey] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
            return true
        }

        if (textStorage.attribute(.agentChatHistoryRetryLastTurn, at: charIndex, effectiveRange: nil) as? NSNumber)?.boolValue == true {
            onRetryLastTurn?()
            return true
        }

        if (textStorage.attribute(.agentChatHistoryShowTurnReport, at: charIndex, effectiveRange: nil) as? NSNumber)?.boolValue == true {
            onShowTurnReport?()
            return true
        }

        if let payload = textStorage.attribute(.agentChatHistoryTablePayload, at: charIndex, effectiveRange: nil) as? AgentMarkdownTablePayload {
            AgentMarkdownTableDetailWindowRegistry.open(payload: payload)
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

        if let attachment = textStorage.attribute(.agentChatHistoryTextAttachment, at: charIndex, effectiveRange: nil) as? AgentTextAttachment {
            AgentTextAttachmentReaderWindowRegistry.shared.open(attachment: attachment)
            return true
        }

        if let path = textStorage.attribute(.agentChatHistoryFilePath, at: charIndex, effectiveRange: nil) as? String {
            onOpenFilePath?(path)
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
            AgentChatHistoryFooterChrome.reportLinkValue,
            AgentChatHistoryTableLink.value,
            AgentChatHistoryTextAttachmentLink.value,
            AgentChatHistoryFilePathLink.value,
            "agent-chat-history-tool-group",
        ].contains(value)
    }

    private func restoreCopyButtonIfNeeded(range: NSRange, code: String, restoreKey: Int) {
        pendingCodeCopyRestores[restoreKey] = nil
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

    private func restoreFooterCopyButtonIfNeeded(range: NSRange, message: String, restoreKey: Int) {
        pendingFooterCopyRestores[restoreKey] = nil
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
    // 1.130.0-rc3：用户气泡从「固定 82% 宽、文字左缩进 172」改成
    // 几乎撑满内容列 —— 左侧只留约一个字宽。旧版在窄窗口里用户输入
    // 左边空出一大块（截图反馈），信息密度太低。
    static let userBubbleMinWidth: CGFloat = 260
    static let userBubbleTrailingMargin: CGFloat = 30
    /// 气泡背景矩形距内容列左缘的留白（正文缩进 16 − 气泡内衬 12）。
    static let userBubbleLeadingMargin: CGFloat = 4
    /// 用户正文左缩进：约一个汉字宽。
    static let userBodyHeadIndent: CGFloat = 16
    static let userBodyTailIndent: CGFloat = -46
    /// Bubble backgrounds are drawn outside TextKit's glyph usedRect.
    /// Without this bottom slack the final user bubble can have its lower
    /// rounded corners clipped by the hosting SwiftUI layout.
    static let bubbleDrawingVerticalOverscan: CGFloat = 14
}

enum AgentChatHistoryTableLink {
    static let value = "agent-chat-history-table"
}

enum AgentChatHistoryTextAttachmentLink {
    static let value = "agent-chat-history-text-attachment"
}

enum AgentChatHistoryFilePathLink {
    static let value = "agent-chat-history-file-path"
}

enum AgentChatHistoryCopyRangeResolver {
    static func contiguousRange(
        in attributed: NSAttributedString,
        key: NSAttributedString.Key,
        matching expectedValue: String,
        seedRange: NSRange
    ) -> NSRange {
        guard attributed.length > 0 else { return seedRange }
        let storageLength = attributed.length
        let seedLocation = min(max(seedRange.location, 0), storageLength - 1)
        var lowerBound = seedLocation
        var upperBound = min(max(NSMaxRange(seedRange), seedLocation + 1), storageLength)

        while lowerBound > 0,
              (attributed.attribute(key, at: lowerBound - 1, effectiveRange: nil) as? String) == expectedValue {
            lowerBound -= 1
        }
        while upperBound < storageLength,
              (attributed.attribute(key, at: upperBound, effectiveRange: nil) as? String) == expectedValue {
            upperBound += 1
        }

        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }
}

private final class AgentChatHistoryBubbleLayoutManager: NSLayoutManager {
    // Code blocks used to clip long lines and pan them horizontally via a
    // scroll-wheel override (`codeBlockHorizontalOffsets`). Code lines now
    // char-wrap inside the card (see codeBlockParagraphStyle), so the whole
    // shifted-glyph drawing path was removed.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawAgentBubbles(forGlyphRange: glyphsToShow, at: origin)
        drawAgentTables(forGlyphRange: glyphsToShow, at: origin)
        drawAgentCodeBlocks(forGlyphRange: glyphsToShow, at: origin)
        drawInlineCodeChips(forGlyphRange: glyphsToShow, at: origin)
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
            // 几乎撑满内容列：左缘只留 userBubbleLeadingMargin（正文缩进
            // 16 − 气泡内衬 12 = 4），右缘保持 trailing margin。窄到极限
            // 时退回 minWidth 右对齐，避免气泡比正文还窄。
            let width = max(
                AgentChatHistoryLayoutMetrics.userBubbleMinWidth,
                containerWidth
                    - AgentChatHistoryLayoutMetrics.userBubbleTrailingMargin
                    - AgentChatHistoryLayoutMetrics.userBubbleLeadingMargin
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

    private func drawInlineCodeChips(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullStorageRange = NSRange(location: 0, length: textStorage.length)
        var drawnRanges = Set<String>()
        textStorage.enumerateAttribute(.agentChatHistoryInlineCodeChipColor, in: characterRange, options: []) { value, range, _ in
            guard range.length > 0, let color = value as? NSColor else { return }
            var fullEffectiveRange = NSRange(location: 0, length: 0)
            _ = textStorage.attribute(
                .agentChatHistoryInlineCodeChipColor,
                at: range.location,
                longestEffectiveRange: &fullEffectiveRange,
                in: fullStorageRange
            )
            let drawKey = "\(fullEffectiveRange.location)-\(fullEffectiveRange.length)"
            guard drawnRanges.insert(drawKey).inserted else { return }
            let chipGlyphRange = glyphRange(forCharacterRange: fullEffectiveRange, actualCharacterRange: nil)
            drawInlineChipRange(chipGlyphRange, color: color, clippedTo: glyphsToShow, at: origin)
        }
    }

    private func drawInlineChipRange(
        _ fullGlyphRange: NSRange,
        color: NSColor,
        clippedTo glyphsToShow: NSRange,
        at origin: NSPoint
    ) {
        enumerateLineFragments(forGlyphRange: fullGlyphRange) { _, _, textContainer, lineGlyphRange, _ in
            let lineRange = NSIntersectionRange(lineGlyphRange, fullGlyphRange)
            let visibleRange = NSIntersectionRange(lineRange, glyphsToShow)
            guard visibleRange.length > 0 else { return }
            var rect = self.boundingRect(forGlyphRange: visibleRange, in: textContainer)
            guard !rect.isNull, !rect.isEmpty else { return }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -1.5)
            let radius = min(6, rect.height / 2)
            color.setFill()
            NSBezierPath(roundedRect: rect.integral, xRadius: radius, yRadius: radius).fill()
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
            // Deliberately faint — the user's own messages don't need a
            // prominent fill, just enough to set them apart from assistant text.
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.045)
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
