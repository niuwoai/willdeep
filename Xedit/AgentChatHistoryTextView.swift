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
    /// Raw user/assistant/tool-loop messages used only to recover user-turn
    /// boundaries and aggregate metrics. The visible TextKit body still uses
    /// `messages`, so internal tool results never leak into the transcript.
    var assistantTurnContextMessages: [AgentMessage]? = nil
    var isAssistantTurnActive = false
    /// User-controlled base size for the transcript body, threaded
    /// from `AppState.agentChatBaseFontSize`. Tool summaries and
    /// chrome stay on fixed sizes inside the renderer.
    let baseFontSize: CGFloat
    var fontID = AgentSettingsStore.chatFontIDDefault
    var lineHeightMultiple = AgentSettingsStore.chatLineHeightMultipleDefault
    let onRetryLastTurn: () -> Void
    /// 1.103.0-rc11: 本轮 turn-report 的工具调用次数(>0 才会在最近一条
    /// assistant 的 footer 里渲染 doc.text + 数字图标);nil/0 表示没有
    /// report 可看(0 次 tool call 的轮次原 PostStrip 也是不显示)。
    var latestTurnReportToolCount: Int? = nil
    /// 1.103.0-rc11: footer 报告图标被点时触发(SwiftUI 侧打开 popover)。
    var onShowTurnReport: (() -> Void)? = nil
    var onReferenceGeneratedImage: ((String) -> Void)? = nil
    var onAddSelectionToTask: ((String) -> Void)? = nil
    var onOpenFilePath: ((String) -> Void)? = nil
    var onOpenAttachmentCitation: ((AgentAttachmentCitationPayload) -> Void)? = nil
    var progressPlan: AgentPlan? = nil
    var onShowPlan: (() -> Void)? = nil
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
        view.onAddSelectionToTask = onAddSelectionToTask
        view.onOpenFilePath = onOpenFilePath
        view.onOpenAttachmentCitation = onOpenAttachmentCitation
        view.onShowPlan = onShowPlan
        view.onSearchResultCountChange = onSearchResultCountChange
        configure(view)
        view.applyMessages(
            messages,
            isDark: colorScheme == .dark,
            assistantTurnContextMessages: assistantTurnContextMessages,
            isAssistantTurnActive: isAssistantTurnActive,
            baseFontSize: baseFontSize,
            fontID: fontID,
            lineHeightMultiple: lineHeightMultiple,
            progressPlan: progressPlan,
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
        nsView.onAddSelectionToTask = onAddSelectionToTask
        nsView.onOpenFilePath = onOpenFilePath
        nsView.onOpenAttachmentCitation = onOpenAttachmentCitation
        nsView.onShowPlan = onShowPlan
        nsView.onSearchResultCountChange = onSearchResultCountChange
        nsView.applyMessages(
            messages,
            isDark: colorScheme == .dark,
            assistantTurnContextMessages: assistantTurnContextMessages,
            isAssistantTurnActive: isAssistantTurnActive,
            baseFontSize: baseFontSize,
            fontID: fontID,
            lineHeightMultiple: lineHeightMultiple,
            progressPlan: progressPlan,
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
            .cursor: NSCursor.arrow,
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
    private var currentAssistantTurnContextMessages: [AgentMessage] = []
    private var currentIsAssistantTurnActive = false
    private var currentIsDark = false
    private var currentBaseFontSize: CGFloat = NSFont.systemFontSize
    private var currentFontID = AgentSettingsStore.chatFontIDDefault
    private var currentLineHeightMultiple = AgentSettingsStore.chatLineHeightMultipleDefault
    private var currentProgressPlan: AgentPlan?
    private var currentLatestTurnReportToolCount: Int? = nil
    private var currentLayoutWidth = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth
    private var currentBaseAttributedString = NSAttributedString()
    private var currentSearchQuery = ""
    private var currentActiveSearchMatchIndex: Int?
    private var currentSearchIsDark = false
    private var lastReportedSearchResultCount: Int?
    private var expandedToolGroupIDs = Set<String>()
    private var expandedProgressBlockIDs = Set<String>()
    private var hoveredUserMessageID: UUID?
    private var hoverTrackingArea: NSTrackingArea?
    /// Pending "restore copy button label" work items keyed by the
    /// button's stable text-storage location. Rapid repeated clicks on
    /// the same button refresh that button's countdown without preventing
    /// other copied buttons from restoring themselves.
    private var pendingCodeCopyRestores: [Int: DispatchWorkItem] = [:]
    private var pendingFooterCopyRestores: [Int: DispatchWorkItem] = [:]
    private var selectionActionView: AgentChatSelectionActionView?
    private var selectionActionText: String?
    var onRetryLastTurn: (() -> Void)?
    /// 1.103.0-rc11: TextKit footer 里 doc.text 图标被点时回调 SwiftUI 侧
    /// 弹出 AgentTurnReportCard popover —— 见 AgentChatTranscript。
    var onShowTurnReport: (() -> Void)?
    var onReferenceGeneratedImage: ((String) -> Void)?
    var onAddSelectionToTask: ((String) -> Void)?
    var onOpenFilePath: ((String) -> Void)?
    var onOpenAttachmentCitation: ((AgentAttachmentCitationPayload) -> Void)?
    var onShowPlan: (() -> Void)?
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0 else { return }
        let resolvedWidth = AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(newSize.width)
        guard resolvedWidth != currentLayoutWidth else { return }
        currentLayoutWidth = resolvedWidth
        guard !currentMessages.isEmpty else { return }
        renderCurrentMessages()
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

    override func mouseDown(with event: NSEvent) {
        dismissSelectionAction()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // 气泡的显示/隐藏统一交给 textViewDidChangeSelection（选区落定的权威回调）。
        // 拖拽选区时结束的 mouseUp 会被 NSTextView 内部跟踪循环吞掉，这里不再依赖它触发。
    }

    /// 拖选 + ⌘C 走的是 AppKit 自己的复制链路,拿的是 textStorage 里的
    /// **渲染串**——排版专用的零宽断点会原样进剪贴板。纯文本这一味在这里
    /// 换成净化版;RTF 等富文本口味仍交给 super(粘到富文本编辑器里那些
    /// 零宽字符本来就是随格式走的,而且真正会被塞进终端的是 .string)。
    override func writeSelection(
        to pboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string else {
            return super.writeSelection(to: pboard, type: type)
        }
        let range = selectedRange()
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= (textStorage?.length ?? 0),
              let storageString = textStorage?.string else {
            return super.writeSelection(to: pboard, type: type)
        }
        let raw = (storageString as NSString).substring(with: range)
        pboard.setString(AgentCopyTextSanitizer.sanitize(raw), forType: .string)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let marker = generatedImageReferenceMarker(at: point)
        let selectedText = currentSelectedConversationText()
        guard marker != nil || selectedText != nil else {
            return super.menu(for: event)
        }
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        if let selectedText {
            menu.addItem(addSelectionToTaskMenuItem(selectedText: selectedText))
        }
        if let marker {
            let item = NSMenuItem(
                title: L10n.AgentGeneratedImage.quoteAction,
                action: #selector(quoteGeneratedImageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = marker
            menu.addItem(item)
        }
        return menu
    }

    private func addSelectionToTaskMenuItem(selectedText: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: L10n.AgentSelection.addToTask,
            action: #selector(addSelectionToTaskFromMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = selectedText
        item.isEnabled = true
        return item
    }

    private func showSelectionAction(selectedText: String) {
        guard let selectionRect = selectedTextBoundingRect() else {
            dismissSelectionAction()
            return
        }

        let actionView = selectionActionView ?? makeSelectionActionView()
        selectionActionText = selectedText
        actionView.isHidden = false

        let size = actionView.preferredSize
        let visible = visibleRect.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 6
        let proposedAboveY = isFlipped
            ? selectionRect.minY - size.height - gap
            : selectionRect.maxY + gap
        let proposedBelowY = isFlipped
            ? selectionRect.maxY + gap
            : selectionRect.minY - size.height - gap
        let fitsAbove = proposedAboveY >= visible.minY
            && proposedAboveY + size.height <= visible.maxY
        let targetY = fitsAbove ? proposedAboveY : proposedBelowY
        let unclampedX = selectionRect.midX - size.width / 2
        let maxX = max(visible.minX, visible.maxX - size.width)
        let targetX = min(max(unclampedX, visible.minX), maxX)
        let maxY = max(visible.minY, visible.maxY - size.height)
        actionView.frame = NSRect(
            x: targetX,
            y: min(max(targetY, visible.minY), maxY),
            width: size.width,
            height: size.height
        )
    }

    private func makeSelectionActionView() -> AgentChatSelectionActionView {
        let actionView = AgentChatSelectionActionView(title: L10n.AgentSelection.addToTask)
        actionView.onAdd = { [weak self] in
            guard let self, let selectedText = self.selectionActionText else { return }
            self.dismissSelectionAction()
            self.onAddSelectionToTask?(selectedText)
        }
        addSubview(actionView, positioned: .above, relativeTo: nil)
        selectionActionView = actionView
        return actionView
    }

    private func selectedTextBoundingRect() -> NSRect? {
        let range = selectedRange()
        guard range.location != NSNotFound,
              range.length > 0,
              let layoutManager,
              let textContainer else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    private func dismissSelectionAction() {
        selectionActionText = nil
        selectionActionView?.isHidden = true
    }

    private func currentSelectedConversationText() -> String? {
        let range = selectedRange()
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= (textStorage?.length ?? 0),
              let storageString = textStorage?.string else {
            return nil
        }
        let rawText = (storageString as NSString).substring(with: range)
        // 选区取的是渲染串,带着排版专用的零宽断点。这条出口会回流给模型
        // (「加入任务」/引用选区),所以净化之后必须重新打断注入标记。
        let cleaned = AgentCopyTextSanitizer.sanitizeForModelRoundTrip(rawText)
        let selectedText = AgentTextAttachment.sanitizedPastedContent(cleaned)
        return selectedText.isEmpty ? nil : selectedText
    }

    @discardableResult
    func addCurrentSelectionToTask() -> Bool {
        guard let selectedText = currentSelectedConversationText() else { return false }
        onAddSelectionToTask?(selectedText)
        return true
    }

    @objc private func addSelectionToTaskFromMenu(_ sender: NSMenuItem) {
        guard let selectedText = sender.representedObject as? String else {
            _ = addCurrentSelectionToTask()
            return
        }
        onAddSelectionToTask?(selectedText)
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
        assistantTurnContextMessages: [AgentMessage]? = nil,
        isAssistantTurnActive: Bool = false,
        baseFontSize: CGFloat = NSFont.systemFontSize,
        fontID: String = AgentSettingsStore.chatFontIDDefault,
        lineHeightMultiple: CGFloat = AgentSettingsStore.chatLineHeightMultipleDefault,
        progressPlan: AgentPlan? = nil,
        latestTurnReportToolCount: Int? = nil
    ) {
        let turnContextMessages = assistantTurnContextMessages ?? messages
        let fp = Self.inputFingerprint(
            messages: messages,
            assistantTurnContextMessages: turnContextMessages,
            isAssistantTurnActive: isAssistantTurnActive,
            isDark: isDark,
            baseFontSize: baseFontSize,
            fontID: fontID,
            lineHeightMultiple: lineHeightMultiple,
            progressPlan: progressPlan,
            latestTurnReportToolCount: latestTurnReportToolCount
        )
        if fp == lastInputFingerprint {
            return
        }
        dismissSelectionAction()
        lastInputFingerprint = fp
        currentMessages = messages
        currentAssistantTurnContextMessages = turnContextMessages
        currentIsAssistantTurnActive = isAssistantTurnActive
        currentIsDark = isDark
        currentBaseFontSize = baseFontSize
        currentFontID = fontID
        currentLineHeightMultiple = lineHeightMultiple
        currentProgressPlan = progressPlan
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
        assistantTurnContextMessages: [AgentMessage],
        isAssistantTurnActive: Bool,
        isDark: Bool,
        baseFontSize: CGFloat,
        fontID: String,
        lineHeightMultiple: CGFloat,
        progressPlan: AgentPlan?,
        latestTurnReportToolCount: Int?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(isDark)
        hasher.combine(baseFontSize)
        hasher.combine(fontID)
        hasher.combine(lineHeightMultiple)
        hasher.combine(messages.count)
        hasher.combine(isAssistantTurnActive)
        hasher.combine(latestTurnReportToolCount ?? -1)
        if let progressPlan {
            hasher.combine(progressPlan.status.rawValue)
            hasher.combine(progressPlan.steps.count)
            for step in progressPlan.steps {
                hasher.combine(step.id)
                hasher.combine(step.text)
                hasher.combine(step.status.rawValue)
            }
        }
        for m in messages {
            hasher.combine(m.id)
            hasher.combine(m.role.rawValue)
            hasher.combine(m.content.count)
            hasher.combine(m.reasoningContent?.count ?? -1)
            hasher.combine(m.images.count)
            for image in m.images {
                hasher.combine(image.id)
                hasher.combine(image.mimeType)
                // byteCount, never dataBase64: for file-backed images the
                // latter is a full disk read + base64 encode per call, and
                // this fingerprint runs on every streaming flush.
                hasher.combine(image.byteCount ?? -1)
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
            // Keep the streaming-hot-path fingerprint in sync with the
            // renderer cache key: a resolved tool receipt must invalidate
            // this early-exit, otherwise the outcome receipt is skipped.
            if let receipts = m.settledToolReceipts {
                for (callID, status) in receipts.sorted(by: { $0.key < $1.key }) {
                    hasher.combine(callID)
                    hasher.combine(status.rawValue)
                }
            }
        }
        for message in assistantTurnContextMessages
            where message.role == .user || message.role == .assistant {
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
        }
        return hasher.finalize()
    }

    private func renderCurrentMessages() {
        let attr = AgentChatHistoryRenderer.render(
            messages: currentMessages,
            isDark: currentIsDark,
            assistantTurnContextMessages: currentAssistantTurnContextMessages,
            isAssistantTurnActive: currentIsAssistantTurnActive,
            expandedToolGroupIDs: expandedToolGroupIDs,
            expandedProgressBlockIDs: expandedProgressBlockIDs,
            hoveredUserMessageID: hoveredUserMessageID,
            baseFontSize: currentBaseFontSize,
            fontID: currentFontID,
            lineHeightMultiple: currentLineHeightMultiple,
            layoutWidth: currentLayoutWidth,
            progressPlan: currentProgressPlan,
            latestTurnReportToolCount: currentLatestTurnReportToolCount
        )
        var hasher = Hasher()
        hasher.combine(attr.string)
        hasher.combine(attr.length)
        hasher.combine(currentIsDark)
        hasher.combine(currentBaseFontSize)
        hasher.combine(currentFontID)
        hasher.combine(currentLineHeightMultiple)
        hasher.combine(currentLayoutWidth)
        hasher.combine(expandedToolGroupIDs.sorted())
        hasher.combine(expandedProgressBlockIDs.sorted())
        hasher.combine(hoveredUserMessageID)
        let hash = hasher.finalize()
        if hash == lastContentHash, attr.length == currentBaseAttributedString.length {
            return
        }
        lastContentHash = hash
        currentBaseAttributedString = attr
        // Re-paint the highlights, but do NOT jump. A transcript rebuild is
        // not a search navigation: hover changes, streaming deltas, tool
        // groups expanding, and width changes all land here, and each one
        // used to yank the reader back to the active match. Scrolling to
        // the bottom during a search was the worst case — every message
        // the cursor crossed fired `mouseMoved`, rebuilt the body, and
        // bounced the viewport back to match #1.
        applySearchHighlight(scrollToActiveMatch: false)
        invalidateIntrinsicContentSize()
    }

    func applySearch(query: String, activeMatchIndex: Int?, isDark: Bool) {
        let normalizedQuery = AgentTranscriptSearch.normalizedQuery(query)
        guard normalizedQuery != currentSearchQuery
                || activeMatchIndex != currentActiveSearchMatchIndex
                || isDark != currentSearchIsDark else {
            return
        }
        currentSearchQuery = normalizedQuery
        currentActiveSearchMatchIndex = activeMatchIndex
        currentSearchIsDark = isDark
        // Only a real search navigation — a new query, next/previous, or a
        // theme change that re-derives the ranges — moves the viewport.
        applySearchHighlight(scrollToActiveMatch: true)
    }

    private func applySearchHighlight(scrollToActiveMatch: Bool) {
        let result = AgentTranscriptSearch.highlightedString(
            from: currentBaseAttributedString,
            query: currentSearchQuery,
            activeMatchIndex: currentActiveSearchMatchIndex,
            isDark: currentSearchIsDark
        )
        replaceTranscriptStoragePreservingSelection(with: result.attributedString)
        reportSearchResultCountIfNeeded(result.matchCount)
        if scrollToActiveMatch {
            scrollActiveSearchMatchIfNeeded(ranges: result.matchRanges)
        }
        invalidateIntrinsicContentSize()
    }

    /// Hover and search highlighting only change attributes. Replacing the
    /// whole NSTextStorage normally collapses the selection, which makes the
    /// selection action disappear immediately after it is shown. Preserve a
    /// valid selection whenever the underlying conversation text is unchanged.
    private func replaceTranscriptStoragePreservingSelection(
        with attributedString: NSAttributedString
    ) {
        guard let textStorage else { return }
        let range = selectedRange()
        let canPreserveSelection = range.location != NSNotFound
            && range.length > 0
            && NSMaxRange(range) <= attributedString.length
            && textStorage.string == attributedString.string

        if canPreserveSelection {
            delegate = nil
        }
        textStorage.setAttributedString(attributedString)
        if canPreserveSelection {
            setSelectedRange(range)
            delegate = self
            if let selectedText = currentSelectedConversationText() {
                showSelectionAction(selectedText: selectedText)
            }
        }
    }

    private func reportSearchResultCountIfNeeded(_ count: Int) {
        guard lastReportedSearchResultCount != count else { return }
        lastReportedSearchResultCount = count
        onSearchResultCountChange?(count)
    }

    /// Counts viewport jumps actually requested by a search navigation.
    /// A live scroll view is hard to assert against in a unit test, so this
    /// records the decision instead — see `AgentTranscriptSearchScrollTests`.
    private(set) var searchScrollRequestCount = 0

    private func scrollActiveSearchMatchIfNeeded(ranges: [NSRange]) {
        guard let index = AgentTranscriptSearch.clampedActiveIndex(
            currentActiveSearchMatchIndex,
            count: ranges.count
        ) else { return }
        let range = ranges[index]
        guard range.location >= 0, NSMaxRange(range) <= (textStorage?.length ?? 0) else {
            return
        }
        searchScrollRequestCount += 1
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

enum AgentChatSelectionActionMetrics {
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 9
    static let height: CGFloat = 28
    static let borderWidth: CGFloat = 0.5
    static let shadowRadius: CGFloat = 7
    static let shadowOffset = NSSize(width: 0, height: -2)
    static let lightShadowOpacity: Float = 0.16
    static let darkShadowOpacity: Float = 0.36

    static func backgroundColor(isDark: Bool, isHovered: Bool) -> NSColor {
        if isDark {
            return NSColor(calibratedWhite: isHovered ? 0.22 : 0.16, alpha: 0.98)
        }
        return NSColor(calibratedWhite: isHovered ? 0.965 : 1, alpha: 0.98)
    }

    static func borderColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.13)
    }
}

private final class AgentChatSelectionActionView: NSView {
    private let actionButton: NSButton
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    var onAdd: (() -> Void)?

    init(title: String) {
        actionButton = NSButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = AgentChatSelectionActionMetrics.cornerRadius
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = AgentChatSelectionActionMetrics.shadowRadius
        layer?.shadowOffset = AgentChatSelectionActionMetrics.shadowOffset
        applyAppearance()

        actionButton.target = self
        actionButton.action = #selector(addToTask(_:))
        actionButton.isBordered = false
        actionButton.focusRingType = .none
        actionButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        actionButton.contentTintColor = .labelColor
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionButton)
        NSLayoutConstraint.activate([
            actionButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AgentChatSelectionActionMetrics.horizontalPadding
            ),
            actionButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AgentChatSelectionActionMetrics.horizontalPadding
            ),
            actionButton.topAnchor.constraint(equalTo: topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    var preferredSize: NSSize {
        NSSize(
            width: ceil(actionButton.intrinsicContentSize.width)
                + AgentChatSelectionActionMetrics.horizontalPadding * 2,
            height: AgentChatSelectionActionMetrics.height
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        super.mouseExited(with: event)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: AgentChatSelectionActionMetrics.cornerRadius,
            cornerHeight: AgentChatSelectionActionMetrics.cornerRadius,
            transform: nil
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let borderInset = AgentChatSelectionActionMetrics.borderWidth / 2
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: borderInset, dy: borderInset),
            xRadius: AgentChatSelectionActionMetrics.cornerRadius,
            yRadius: AgentChatSelectionActionMetrics.cornerRadius
        )
        AgentChatSelectionActionMetrics.backgroundColor(
            isDark: isDark,
            isHovered: isHovered
        ).setFill()
        path.fill()
        AgentChatSelectionActionMetrics.borderColor(isDark: isDark).setStroke()
        path.lineWidth = AgentChatSelectionActionMetrics.borderWidth
        path.stroke()
    }

    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.shadowOpacity = isDark
            ? AgentChatSelectionActionMetrics.darkShadowOpacity
            : AgentChatSelectionActionMetrics.lightShadowOpacity
        needsDisplay = true
    }

    @objc private func addToTask(_ sender: NSButton) {
        onAdd?()
    }
}

extension AgentChatHistoryNSTextView: NSTextViewDelegate {
    // 选区落定的权威回调：拖拽选区时 NSTextView 的内部事件跟踪循环会吞掉结束的 mouseUp，
    // 单靠重写 mouseUp 无法在「按下→拖选→松开」路径上弹出气泡。这里改为监听选区变化，
    // 无论选区由鼠标拖拽、双击选词还是键盘 shift 选中，AppKit 都会回调。
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let selectedText = currentSelectedConversationText() else {
            dismissSelectionAction()
            return
        }
        showSelectionAction(selectedText: selectedText)
    }

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

        if let progressID = textStorage.attribute(
            .agentChatHistoryProgressToggleID,
            at: charIndex,
            effectiveRange: nil
        ) as? String {
            if expandedProgressBlockIDs.contains(progressID) {
                expandedProgressBlockIDs.remove(progressID)
            } else {
                expandedProgressBlockIDs.insert(progressID)
            }
            lastContentHash = nil
            renderCurrentMessages()
            return true
        }

        if (textStorage.attribute(
            .agentChatHistoryProgressShowPlan,
            at: charIndex,
            effectiveRange: nil
        ) as? NSNumber)?.boolValue == true {
            onShowPlan?()
            return true
        }

        if let attachment = textStorage.attribute(.agentChatHistoryTextAttachment, at: charIndex, effectiveRange: nil) as? AgentTextAttachment {
            AgentTextAttachmentReaderWindowRegistry.shared.open(attachment: attachment)
            return true
        }

        if let imageIDString = textStorage.attribute(
            .agentChatHistoryImageID,
            at: charIndex,
            effectiveRange: nil
        ) as? String,
           let imageID = UUID(uuidString: imageIDString),
           let image = currentMessages.lazy.flatMap(\.images).first(where: { $0.id == imageID }) {
            AgentImagePreviewWindowRegistry.shared.open(image: image)
            return true
        }

        if let citation = textStorage.attribute(
            .agentChatHistoryAttachmentCitation,
            at: charIndex,
            effectiveRange: nil
        ) as? AgentAttachmentCitationPayload {
            onOpenAttachmentCitation?(citation)
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
            AgentChatHistoryImageLink.value,
            AgentChatHistoryFilePathLink.value,
            AgentChatHistoryAttachmentCitationLink.value,
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
              textStorage.attribute(
                  .agentChatHistoryMessageCopyText,
                  at: range.location,
                  effectiveRange: nil
              ) as? String == message,
              textStorage.attribute(.link, at: range.location, effectiveRange: nil) == nil else {
            return
        }
        replaceFooterCopyButton(in: range, copied: false, message: message)
    }

    private func replaceFooterCopyButton(in range: NSRange, copied: Bool, message: String) {
        guard let textStorage else { return }
        let paragraphStyle = textStorage.attribute(
            .paragraphStyle,
            at: range.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let replacement = AgentChatHistoryFooterChrome.copyButton(
            copied: copied,
            message: message,
            paragraphStyle: paragraphStyle,
            baseFontSize: currentBaseFontSize
        )
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

    var drawsRoundedBackground: Bool {
        self != .assistant
    }
}

enum AgentChatHistoryLayoutMetrics {
    /// Shared body leading for live SwiftUI messages and TextKit history.
    /// Five points plus the 15 pt body baseline reproduces Codex's roughly
    /// 24 pt reading rhythm for both Latin text and wrapped Chinese prose.
    static let bodyLineSpacing: CGFloat = 5
    static let assistantContentHeadIndent: CGFloat = 32
    static let assistantContentTailInset: CGFloat = 18
    /// Nested lists advance by one compact text column. Continuation lines
    /// start after the marker so wrapped bullets scan like real lists rather
    /// than falling back underneath the dash/number.
    static let listNestingIndent: CGFloat = 18
    static let listHangingIndent: CGFloat = 22
    static let listParagraphSpacing: CGFloat = 3
    /// Variant A: process prose shares the configured body size with the
    /// answer, so grayscale — not a second type scale — carries hierarchy.
    /// The dark-mode value is lifted enough to retain the same readable role
    /// on a near-black transcript surface.
    static func assistantProcessTextColor(isDark: Bool) -> NSColor {
        let white: CGFloat = isDark ? 0.68 : 0.52
        return NSColor(srgbRed: white, green: white, blue: white, alpha: 1)
    }
    /// Measured from the Codex reference at 1x: 9 pt from the status line
    /// box to the divider, then 18 pt from the divider to the body line box.
    static let assistantStatusDividerTopSpacing: CGFloat = 9
    static let assistantStatusDividerBottomSpacing: CGFloat = 18
    static let assistantStatusDividerThickness: CGFloat = 1
    /// AppKit/SwiftUI compositing resolves this neutral overlay to #F0F0F0
    /// on the white reference surface.
    static let assistantStatusDividerOpacity: Double = 0.075
    /// Model-switch notices are inline milestones whose divider edges follow
    /// the same readable column as assistant prose.
    static let transcriptEventDividerGap: CGFloat = 12

    static func transcriptEventDividerSegments(
        textMinX: CGFloat,
        textMaxX: CGFloat,
        usableWidth: CGFloat
    ) -> [(start: CGFloat, end: CGFloat)] {
        let contentMinX = min(usableWidth, assistantContentHeadIndent)
        let contentMaxX = max(contentMinX, usableWidth - assistantContentTailInset)
        let leadingEnd = max(contentMinX, textMinX - transcriptEventDividerGap)
        let trailingStart = min(contentMaxX, textMaxX + transcriptEventDividerGap)
        var segments: [(start: CGFloat, end: CGFloat)] = []
        if leadingEnd > contentMinX {
            segments.append((
                start: contentMinX,
                end: leadingEnd
            ))
        }
        if trailingStart < contentMaxX {
            segments.append((
                start: trailingStart,
                end: contentMaxX
            ))
        }
        return segments
    }
    /// Inline-code chips may sit after a single proportional-font space.
    /// Keep the horizontal expansion below that space's advance so a
    /// one-glyph chip such as `/` cannot paint over the preceding text.
    static let inlineCodeChipHorizontalPadding: CGFloat = 2
    /// NSTextView draws in a flipped coordinate system, so name these by
    /// their on-screen edges instead of AppKit's geometric minY/maxY edges.
    static let inlineCodeChipVisualTopPadding: CGFloat = 0.5
    static let inlineCodeChipVisualBottomPadding: CGFloat = 0.5
    /// Code/table text is inset from the assistant paragraph. Their rounded
    /// background extends another 10 points around that text, so the right
    /// edge always covers the line-break boundary instead of ending early.
    static let richBlockTextInset: CGFloat = 8
    static let richBlockBackgroundPadding: CGFloat = 10
    static let richBlockMinimumWidth: CGFloat = 220
    static var richBlockBackgroundLeadingInset: CGFloat {
        assistantContentHeadIndent + richBlockTextInset - richBlockBackgroundPadding
    }
    static var richBlockBackgroundTrailingInset: CGFloat {
        assistantContentTailInset + richBlockTextInset - richBlockBackgroundPadding
    }

    static func inlineCodeChipContentHeight(
        fragmentHeight: CGFloat,
        naturalLineHeight: CGFloat,
        paragraphLineSpacing: CGFloat
    ) -> CGFloat {
        guard fragmentHeight > 0,
              naturalLineHeight > 0,
              paragraphLineSpacing > 0 else {
            return max(0, fragmentHeight)
        }
        let heightWithoutLineSpacing = fragmentHeight - paragraphLineSpacing
        guard heightWithoutLineSpacing >= naturalLineHeight else {
            // TextKit omits lineSpacing from the final line fragment. Do not
            // shrink that already-compact fragment a second time.
            return fragmentHeight
        }
        return heightWithoutLineSpacing
    }

    static func inlineCodeChipRect(
        for glyphRect: NSRect,
        at origin: NSPoint,
        contentHeight: CGFloat? = nil
    ) -> NSRect {
        let positionedRect = glyphRect.offsetBy(dx: origin.x, dy: origin.y)
        let resolvedContentHeight = min(
            positionedRect.height,
            max(0, contentHeight ?? positionedRect.height)
        )
        let minX = floor(positionedRect.minX - inlineCodeChipHorizontalPadding)
        let maxX = ceil(positionedRect.maxX + inlineCodeChipHorizontalPadding)
        return NSRect(
            x: minX,
            y: positionedRect.minY - inlineCodeChipVisualTopPadding,
            width: maxX - minX,
            height: resolvedContentHeight
                + inlineCodeChipVisualTopPadding
                + inlineCodeChipVisualBottomPadding
        )
    }

    static func assistantStatusDividerColor(isDark: Bool) -> NSColor {
        let white: CGFloat = isDark ? 1 : 0
        return NSColor(
            srgbRed: white,
            green: white,
            blue: white,
            alpha: CGFloat(assistantStatusDividerOpacity)
        )
    }
    // Codex-style user input stays in a right-side column instead of
    // becoming a full-width strip. The body remains left-aligned inside
    // that column, while short and long messages share a stable wrap width.
    static let userBubbleMinWidth: CGFloat = 260
    static let userBubbleMaxWidthRatio: CGFloat = 0.78
    static let userBubbleTrailingMargin: CGFloat = 30
    static let defaultTranscriptWidth: CGFloat = 1040
    static let userBubbleHorizontalPadding: CGFloat = 12
    static let userBubbleVerticalPadding: CGFloat = 8
    static let userBubbleCornerRadius: CGFloat = 14
    static let userBubbleFillOpacity: Double = 0.026
    static let userTurnTopSpacing: CGFloat = 10
    static let userBodyTailIndent = -(userBubbleTrailingMargin + userBubbleHorizontalPadding)
    static let userFooterTrailingInset: CGFloat = 10
    static let userFooterTopSpacing: CGFloat = 8
    static let userFooterBottomSpacing: CGFloat = 8
    static let userImageToBubbleSpacing: CGFloat = 14
    static let userMessageElementSpacing: CGFloat = 4
    /// Reuse TextKit renders while the window moves within a small width
    /// interval. Flooring keeps the rendered content inside the actual view;
    /// the maximum layout-width difference is `layoutWidthBucket - 1` points.
    static let layoutWidthBucket: CGFloat = 8
    /// Bubble backgrounds are drawn outside TextKit's glyph usedRect.
    /// Without this bottom slack the final user bubble can have its lower
    /// rounded corners clipped by the hosting SwiftUI layout.
    static let bubbleDrawingVerticalOverscan: CGFloat = 14

    static func resolvedLayoutWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return defaultTranscriptWidth }
        guard width >= layoutWidthBucket else { return floor(width) }
        return floor(width / layoutWidthBucket) * layoutWidthBucket
    }

    static func userBubbleWidth(for layoutWidth: CGFloat) -> CGFloat {
        let width = resolvedLayoutWidth(layoutWidth)
        let availableWidth = max(0, width - userBubbleTrailingMargin)
        return min(
            availableWidth,
            max(userBubbleMinWidth, width * userBubbleMaxWidthRatio)
        )
    }

    static func userBubbleLeadingEdge(for layoutWidth: CGFloat) -> CGFloat {
        let width = resolvedLayoutWidth(layoutWidth)
        return width - userBubbleWidth(for: width) - userBubbleTrailingMargin
    }

    static func userBodyHeadIndent(for layoutWidth: CGFloat) -> CGFloat {
        userBubbleLeadingEdge(for: layoutWidth) + userBubbleHorizontalPadding
    }
}

enum AgentChatHistoryTableLink {
    static let value = "agent-chat-history-table"
}

enum AgentChatHistoryTextAttachmentLink {
    static let value = "agent-chat-history-text-attachment"
}

enum AgentChatHistoryImageLink {
    static let value = "agent-chat-history-image"
}

enum AgentChatHistoryFilePathLink {
    static let value = "agent-chat-history-file-path"
}

enum AgentChatHistoryAttachmentCitationLink {
    static let value = "agent-chat-history-attachment-citation"
}

enum AgentChatHistoryTranscriptEventNotice {
    static let value = "agent-chat-history-transcript-event-notice"
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
        drawAssistantStatusDividers(forGlyphRange: glyphsToShow, at: origin)
        drawTranscriptEventNotices(forGlyphRange: glyphsToShow, at: origin)
        drawAgentBubbles(forGlyphRange: glyphsToShow, at: origin)
        drawAgentTables(forGlyphRange: glyphsToShow, at: origin)
        drawAgentProgressBlocks(forGlyphRange: glyphsToShow, at: origin)
        drawAgentCodeBlocks(forGlyphRange: glyphsToShow, at: origin)
        drawInlineCodeChips(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawAssistantStatusDividers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage, let textContainer = textContainers.first else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(
            .agentChatHistoryAssistantStatusDividerColor,
            in: characterRange,
            options: []
        ) { value, range, _ in
            guard range.length > 0, let color = value as? NSColor else { return }
            let dividerGlyphRange = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard NSIntersectionRange(dividerGlyphRange, glyphsToShow).length > 0,
                  dividerGlyphRange.location < numberOfGlyphs else { return }
            let lineFragment = lineFragmentRect(
                forGlyphAt: dividerGlyphRange.location,
                effectiveRange: nil
            )
            let horizontalInset = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
                + AgentChatHistoryLayoutMetrics.assistantContentTailInset
            let width = max(0, textContainer.size.width - horizontalInset)
            guard width > 0 else { return }
            let rect = NSRect(
                x: origin.x + AgentChatHistoryLayoutMetrics.assistantContentHeadIndent,
                y: origin.y
                    + lineFragment.minY
                    + AgentChatHistoryLayoutMetrics.assistantStatusDividerTopSpacing,
                width: width,
                height: AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness
            )
            color.setFill()
            NSBezierPath(rect: rect).fill()
        }
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
            guard kind.drawsRoundedBackground else { return }
            let drawKey = "\(fullEffectiveRange.location)-\(fullEffectiveRange.length)-\(kind.rawValue)"
            guard drawnRanges.insert(drawKey).inserted else { return }
            let bubbleGlyphRange = glyphRange(forCharacterRange: fullEffectiveRange, actualCharacterRange: nil)
            let visibleGlyphRange = NSIntersectionRange(bubbleGlyphRange, glyphsToShow)
            guard visibleGlyphRange.length > 0 else { return }
            let rect = bubbleRect(forGlyphRange: bubbleGlyphRange, kind: kind, at: origin)
            guard !rect.isNull, !rect.isEmpty else { return }
            bubbleColor(for: kind).setFill()
            let cornerRadius = kind == .user
                ? AgentChatHistoryLayoutMetrics.userBubbleCornerRadius
                : 8
            NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
        }
    }

    private func drawTranscriptEventNotices(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }
        let characterRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullStorageRange = NSRange(location: 0, length: textStorage.length)
        var drawnRanges = Set<String>()
        textStorage.enumerateAttribute(.agentChatHistoryTranscriptEventNotice, in: characterRange, options: []) { value, range, _ in
            guard range.length > 0, value != nil else { return }
            var fullEffectiveRange = NSRange(location: 0, length: 0)
            _ = textStorage.attribute(
                .agentChatHistoryTranscriptEventNotice,
                at: range.location,
                longestEffectiveRange: &fullEffectiveRange,
                in: fullStorageRange
            )
            let drawKey = "\(fullEffectiveRange.location)-\(fullEffectiveRange.length)"
            guard drawnRanges.insert(drawKey).inserted else { return }
            let glyphRange = self.glyphRange(forCharacterRange: fullEffectiveRange, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { return }
            self.enumerateLineFragments(forGlyphRange: glyphRange) { lineFragmentRect, usedRect, textContainer, _, _ in
                let width = self.usableWidth(for: textContainer, fallback: lineFragmentRect.width)
                let segments = AgentChatHistoryLayoutMetrics.transcriptEventDividerSegments(
                    textMinX: usedRect.minX,
                    textMaxX: usedRect.maxX,
                    usableWidth: width
                )
                let y = origin.y + lineFragmentRect.midY
                NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
                let path = NSBezierPath()
                for segment in segments {
                    path.move(to: NSPoint(x: origin.x + segment.start, y: y))
                    path.line(to: NSPoint(x: origin.x + segment.end, y: y))
                }
                path.lineWidth = 1
                path.stroke()
            }
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
            verticalInset = AgentChatHistoryLayoutMetrics.userBubbleVerticalPadding
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
            // Keep user input in a restrained right-side surface. The footer
            // is intentionally outside this rect and retains its own row.
            let width = AgentChatHistoryLayoutMetrics.userBubbleWidth(for: containerWidth)
            rect.origin.x = origin.x + AgentChatHistoryLayoutMetrics.userBubbleLeadingEdge(for: containerWidth)
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

    private func drawAgentProgressBlocks(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else { return }
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullStorageRange = NSRange(location: 0, length: textStorage.length)
        var drawnRanges = Set<String>()
        textStorage.enumerateAttribute(.agentChatHistoryProgressBlockID, in: characterRange, options: []) { value, range, _ in
            guard range.length > 0, let value = value as? String else { return }
            var fullEffectiveRange = NSRange(location: 0, length: 0)
            _ = textStorage.attribute(
                .agentChatHistoryProgressBlockID,
                at: range.location,
                longestEffectiveRange: &fullEffectiveRange,
                in: fullStorageRange
            )
            let drawKey = "\(fullEffectiveRange.location)-\(fullEffectiveRange.length)-\(value)"
            guard drawnRanges.insert(drawKey).inserted else { return }
            let blockGlyphRange = glyphRange(forCharacterRange: fullEffectiveRange, actualCharacterRange: nil)
            guard NSIntersectionRange(blockGlyphRange, glyphsToShow).length > 0 else { return }
            let rect = richBlockRect(forGlyphRange: blockGlyphRange, at: origin, verticalInset: 7)
            guard !rect.isNull, !rect.isEmpty else { return }
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.12).setStroke()
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
        guard let textStorage else { return }
        enumerateLineFragments(forGlyphRange: fullGlyphRange) { _, _, textContainer, lineGlyphRange, _ in
            let lineRange = NSIntersectionRange(lineGlyphRange, fullGlyphRange)
            let visibleRange = NSIntersectionRange(lineRange, glyphsToShow)
            guard visibleRange.length > 0 else { return }
            var rect = self.boundingRect(forGlyphRange: visibleRange, in: textContainer)
            guard !rect.isNull, !rect.isEmpty else { return }
            let visibleCharacterRange = self.characterRange(
                forGlyphRange: visibleRange,
                actualGlyphRange: nil
            )
            let codeFont = textStorage.attribute(
                .font,
                at: visibleCharacterRange.location,
                effectiveRange: nil
            ) as? NSFont
            let paragraphStyle = textStorage.attribute(
                .paragraphStyle,
                at: visibleCharacterRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let contentHeight = codeFont.map {
                AgentChatHistoryLayoutMetrics.inlineCodeChipContentHeight(
                    fragmentHeight: rect.height,
                    naturalLineHeight: self.defaultLineHeight(for: $0),
                    paragraphLineSpacing: paragraphStyle?.lineSpacing ?? 0
                )
            }
            rect = AgentChatHistoryLayoutMetrics.inlineCodeChipRect(
                for: rect,
                at: origin,
                contentHeight: contentHeight
            )
            let radius = min(6, rect.height / 2)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
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
            rect.origin.x = origin.x + AgentChatHistoryLayoutMetrics.richBlockBackgroundLeadingInset
            rect.size.width = max(
                AgentChatHistoryLayoutMetrics.richBlockMinimumWidth,
                containerWidth
                    - AgentChatHistoryLayoutMetrics.richBlockBackgroundLeadingInset
                    - AgentChatHistoryLayoutMetrics.richBlockBackgroundTrailingInset
            )
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
            rect.origin.x = origin.x + AgentChatHistoryLayoutMetrics.richBlockBackgroundLeadingInset
            rect.size.width = max(
                AgentChatHistoryLayoutMetrics.richBlockMinimumWidth,
                containerWidth
                    - AgentChatHistoryLayoutMetrics.richBlockBackgroundLeadingInset
                    - AgentChatHistoryLayoutMetrics.richBlockBackgroundTrailingInset
            )
        }
        return rect.integral
    }

    private func richBlockRect(
        forGlyphRange fullGlyphRange: NSRange,
        at origin: NSPoint,
        verticalInset: CGFloat
    ) -> NSRect {
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
        var rect = union.insetBy(dx: -10, dy: -verticalInset)
        if containerWidth > 0 {
            rect.origin.x = origin.x + AgentChatHistoryLayoutMetrics.richBlockBackgroundLeadingInset
            rect.size.width = max(
                AgentChatHistoryLayoutMetrics.richBlockMinimumWidth,
                containerWidth
                    - AgentChatHistoryLayoutMetrics.richBlockBackgroundLeadingInset
                    - AgentChatHistoryLayoutMetrics.richBlockBackgroundTrailingInset
            )
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
            return NSColor.labelColor.withAlphaComponent(
                CGFloat(AgentChatHistoryLayoutMetrics.userBubbleFillOpacity)
            )
        case .assistant:
            return .clear
        case .system:
            return NSColor.systemPurple.withAlphaComponent(0.12)
        case .tool:
            return NSColor.textBackgroundColor.withAlphaComponent(0.92)
        case .toolSummary:
            return NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
        }
    }
}
