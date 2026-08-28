//
//  AgentSubagentSpeechSelectableText.swift
//  WillDeep
//
//  工种（子代理）发言的正文。
//
//  在这之前这里是一个 `Text(...).textSelection(.enabled)`：能拖蓝、能 ⌘C，
//  但选完什么也不弹。会话正文那套「添加到任务 / 收藏 / 一句话记待办」挂在
//  TextKit 大视图上，SwiftUI 的选区又读不出选中的原文，两边天然接不上。
//
//  于是这里换成一个只读 NSTextView：跟会话正文共用同一份气泡、同一份条目、
//  同一个右键菜单。测量姿势沿用圆桌那条（`RoundtableSelectableMessageText`），
//  正文仍是纯文本——工种边跑边渲染 markdown 正是当初把主线程压垮的形状。
//
//  和会话正文唯一的差别是气泡挂在哪：一条发言只有一两行高，28pt 的气泡放进
//  自己的 bounds 会溢出，而 AppKit 不把 bounds 之外的点击派给子视图。所以走
//  `.windowContent` 摆法，挂到窗口内容视图上，并在滚动时收起。
//

import AppKit
import SwiftUI

struct AgentSubagentSpeechSelectableText: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let onAddSelectionToTask: (String) -> Void
    let onSelectionPluginAction: (
        String, AgentPluginID, AgentPluginCommandID, @escaping (Bool) -> Void
    ) -> Void

    /// 轮次标记「R16」和正文用 `.firstTextBaseline` 对齐。NSViewRepresentable
    /// 不自带文本基线，不补这条 SwiftUI 会拿底边当基线——多行发言里标记会掉到
    /// 最后一行去。首行基线到顶边的距离就是字体的 ascender。
    static func firstBaselineOffset(fontSize: CGFloat) -> CGFloat {
        NSFont.systemFont(ofSize: fontSize).ascender
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AgentSubagentSpeechNSTextView {
        let textView = AgentSubagentSpeechNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        apply(to: textView, context: context)
        return textView
    }

    func updateNSView(_ textView: AgentSubagentSpeechNSTextView, context: Context) {
        apply(to: textView, context: context)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: AgentSubagentSpeechNSTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 1 else {
            // 无界/零宽的探测提议不能应 nil：那会按 frame 为 .zero 的文本视图算，
            // 理想宽度被当成 ~0，CJK（任意两字间可断行）会塌成一字一列的竖排。
            return context.coordinator.naturalSize(textView)
        }
        return context.coordinator.sizeThatFits(textView, width: width)
    }

    private func apply(to textView: AgentSubagentSpeechNSTextView, context: Context) {
        textView.onAddSelectionToTask = onAddSelectionToTask
        textView.onSelectionPluginAction = onSelectionPluginAction
        guard context.coordinator.renderedSource != text
            || context.coordinator.renderedFontSize != fontSize else {
            return
        }
        textView.textStorage?.setAttributedString(
            Self.attributedString(text: text, fontSize: fontSize)
        )
        context.coordinator.renderedSource = text
        context.coordinator.renderedFontSize = fontSize
        context.coordinator.invalidateMeasurement()
        textView.invalidateIntrinsicContentSize()
    }

    /// 一次成型：块结构与表格排版复用聊天正文那两套，结果是**一个**
    /// attributed string 交给这一个文本视图——不是每个块一层视图，那正是
    /// 当年把主线程压垮的形状。等宽 run（代码、表格）不会给 CJK 合成
    /// fallback，中文会掉成方框，所以渲染器收尾统一补一遍字形回退
    /// （见 SF Mono 那条复发记录）。
    private static func attributedString(text: String, fontSize: CGFloat) -> NSAttributedString {
        AgentSubagentSpeechMarkdown.attributedString(from: text, baseSize: fontSize)
    }

    final class Coordinator {
        private static let measurementTolerance: CGFloat = 0.5
        /// 无有效宽度提议时的排版上限，与会话正文的可读列同宽。
        private static let maximumNaturalWidth: CGFloat = 634

        var renderedSource: String?
        var renderedFontSize: CGFloat?
        private var measuredWidth: CGFloat?
        private var measuredHeight: CGFloat?
        private var naturalMeasurement: CGSize?

        func invalidateMeasurement() {
            measuredWidth = nil
            measuredHeight = nil
            naturalMeasurement = nil
        }

        func naturalSize(_ textView: NSTextView) -> CGSize {
            if let naturalMeasurement {
                return naturalMeasurement
            }
            let size = measure(textView, width: Self.maximumNaturalWidth, fitsWidth: true)
            naturalMeasurement = size
            return size
        }

        func sizeThatFits(_ textView: NSTextView, width: CGFloat) -> CGSize {
            if let measuredWidth,
               let measuredHeight,
               abs(measuredWidth - width) <= Self.measurementTolerance {
                return CGSize(width: width, height: measuredHeight)
            }
            let size = measure(textView, width: width, fitsWidth: false)
            measuredWidth = width
            measuredHeight = size.height
            return size
        }

        private func measure(_ textView: NSTextView, width: CGFloat, fitsWidth: Bool) -> CGSize {
            guard let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else {
                return CGSize(width: width, height: minimumHeight(textView))
            }
            container.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            return CGSize(
                width: fitsWidth ? max(1, ceil(used.width)) : width,
                height: max(minimumHeight(textView), ceil(used.height))
            )
        }

        /// 一行的高度兜底。发言正文最短也是一行，返回 0 会让 SwiftUI 把这条折没。
        private func minimumHeight(_ textView: NSTextView) -> CGFloat {
            ceil((textView.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)).boundingRectForFont.height)
        }
    }
}

/// 只读文本视图 + 选区气泡。除了气泡的摆法，行为与会话正文保持一致：
/// 选区落定弹气泡、右键出同一批菜单项、⌘C 走净化过的纯文本。
final class AgentSubagentSpeechNSTextView: NSTextView {
    var onAddSelectionToTask: ((String) -> Void)?
    var onSelectionPluginAction: (
        (String, AgentPluginID, AgentPluginCommandID, @escaping (Bool) -> Void) -> Void
    )?

    private lazy var selectionActionPresenter: AgentChatSelectionActionPresenter = {
        let presenter = AgentChatSelectionActionPresenter(owner: self, placement: .windowContent)
        presenter.onAddSelectionToTask = { [weak self] text in
            self?.onAddSelectionToTask?(text)
        }
        presenter.onSelectionPluginAction = { [weak self] text, pluginID, commandID, completion in
            guard let handler = self?.onSelectionPluginAction else {
                completion(false)
                return
            }
            handler(text, pluginID, commandID, completion)
        }
        return presenter
    }()

    private var scrollObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        delegate = self
    }

    /// 显式搭一套 TextKit 1。不传 textContainer 的话 AppKit 给的是 TextKit 2，
    /// 那条路上 `textStorage` 与 `layoutManager` 都是 nil——选区读不出原文，
    /// 排版也量不出高度，整条发言会静默塌成空白。
    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.init(frame: .zero, textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolling()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        // 气泡不是自己的子视图（挂在窗口内容视图上），宿主离场它不会跟着走。
        selectionActionPresenter.detach()
        removeScrollObserver()
    }

    override func mouseDown(with event: NSEvent) {
        selectionActionPresenter.dismiss()
        super.mouseDown(with: event)
    }

    /// 拖选 + ⌘C 拿的是渲染串。工种发言是纯文本，这里主要是和会话正文
    /// 走同一条净化出口，避免两处复制出来的东西不一样。
    override func writeSelection(
        to pboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string, let raw = selectedConversationText(sanitizeForModel: false) else {
            return super.writeSelection(to: pboard, type: type)
        }
        pboard.setString(raw, forType: .string)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let selectedText = selectedConversationText() else {
            return super.menu(for: event)
        }
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        AgentChatSelectionActionCatalog.appendMenuItems(
            to: menu,
            selectedText: selectedText,
            target: self,
            builtInAction: #selector(addSelectionToTaskFromMenu(_:)),
            pluginAction: #selector(runSelectionPluginActionFromMenu(_:))
        )
        return menu
    }

    @objc private func addSelectionToTaskFromMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onAddSelectionToTask?(text)
    }

    @objc private func runSelectionPluginActionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? AgentChatSelectionPluginMenuPayload else {
            return
        }
        onSelectionPluginAction?(payload.text, payload.pluginID, payload.commandID) { _ in }
    }

    func selectedConversationText(sanitizeForModel: Bool = true) -> String? {
        let range = selectedRange()
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= (textStorage?.length ?? 0),
              let storageString = textStorage?.string else {
            return nil
        }
        let raw = (storageString as NSString).substring(with: range)
        guard sanitizeForModel else {
            let sanitized = AgentCopyTextSanitizer.sanitize(raw)
            return sanitized.isEmpty ? nil : sanitized
        }
        let cleaned = AgentCopyTextSanitizer.sanitizeForModelRoundTrip(raw)
        let selected = AgentTextAttachment.sanitizedPastedContent(cleaned)
        return selected.isEmpty ? nil : selected
    }

    /// 滚动时收起气泡。`windowContent` 摆法下气泡的坐标钉在窗口上，
    /// 内容一滚它就会停在原地对不上选区——与其追着重摆，不如收起来。
    private func observeScrolling() {
        removeScrollObserver()
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.selectionActionPresenter.dismiss()
        }
    }

    private func removeScrollObserver() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollObserver = nil
    }
}

extension AgentSubagentSpeechNSTextView: NSTextViewDelegate {
    // 与会话正文同一条理由：拖拽选区时结束的 mouseUp 会被 NSTextView 的内部
    // 事件跟踪循环吞掉，气泡的出场只能挂在选区变化这个权威回调上。
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let selectedText = selectedConversationText(),
              let rect = selectedTextBoundingRect() else {
            selectionActionPresenter.dismiss()
            return
        }
        selectionActionPresenter.show(selectedText: selectedText, selectionRect: rect)
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
}
