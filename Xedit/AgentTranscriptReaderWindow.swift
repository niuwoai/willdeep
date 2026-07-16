//
//  AgentTranscriptReaderWindow.swift
//  WillDeep
//
//  A standalone, AppKit-only reader window for the full transcript of
//  an AgentSession. The chat pane in Agent mode caps its rendered
//  message count to keep SwiftUI's LazyVStack out of pathological
//  layout territory (deeply nested HStack/VStack/padding/background
//  per message bubble × LazyStack measureEstimates over every item =
//  main-thread freeze on long sessions). When users want to see the
//  full history, they open it here instead.
//
//  Implementation notes:
//   - `NSWindowController` + `NSScrollView` + `NSTextView`. No
//     SwiftUI. TextKit handles its own layout incrementally and
//     doesn't bother the main thread during scroll.
//   - Paged rendering: only the most recent `pageSize` messages are
//     rendered at open time. A "load earlier" link at the top of the
//     document prepends one more page per click. Rendering the whole
//     session in one shot froze the main thread and spiked memory on
//     multi-thousand-message sessions with many images.
//   - Markdown-with-role-headers format. No bubbles, no per-message
//     chrome. Selectable, copyable, supports ⌘F find (NSTextView ships
//     with that out of the box).
//   - One window per session id; reopening the same session re-uses
//     and brings forward the existing window instead of spawning a
//     duplicate.
//

import AppKit
import Foundation

/// Opens — and re-focuses — a reader window for the given session.
/// Window owners live in `AgentTranscriptReaderWindowRegistry` and
/// are kept alive until the user closes them.
@MainActor
enum AgentTranscriptReader {
    static func open(session: AgentSession) {
        AgentTranscriptReaderWindowRegistry.shared.open(session: session)
    }

    /// Open a focused reader showing a single message's full content.
    /// Used by the bubble "查看完整内容" button when a message is
    /// truncated in the chat pane because it's too long to render
    /// without freezing SwiftUI's layout.
    static func openSingleMessage(_ message: AgentMessage, sessionTitle: String) {
        AgentSingleMessageReaderWindowRegistry.shared.open(
            message: message,
            sessionTitle: sessionTitle
        )
    }
}

@MainActor
final class AgentTranscriptReaderWindowRegistry {
    static let shared = AgentTranscriptReaderWindowRegistry()
    private var windows: [UUID: AgentTranscriptReaderWindowController] = [:]

    func open(session: AgentSession) {
        if let existing = windows[session.id] {
            existing.refresh(with: session)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AgentTranscriptReaderWindowController(session: session)
        controller.onClose = { [weak self] sessionID in
            self?.windows.removeValue(forKey: sessionID)
        }
        windows[session.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// `.link` value for the "load earlier messages" control at the top of
/// the reader document. Same string-marker pattern as
/// `AgentChatHistoryTableLink` & co.
enum AgentTranscriptReaderLoadEarlierLink {
    static let value = "agent-transcript-reader-load-earlier"
}

@MainActor
final class AgentTranscriptReaderWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    /// Called when the underlying NSWindow closes so the registry can
    /// drop its reference.
    var onClose: ((UUID) -> Void)?
    private let sessionID: UUID
    /// rc14:挂在主菜单响应链外的窗口,默认接不到 Cmd+W —— 装一个本地
    /// keyDown 监听把它路由到 `performClose(_:)`。本窗口内嵌 NSTextView
    /// 用了 Find bar,所以 **不**把无修饰 Esc 也当关窗,免得截掉搜索取消。
    private var keyMonitor: Any?

    // 分页状态:一次性 render 整个 session 会在数千条消息+多图时构建
    // 巨型 NSAttributedString(主线程长卡顿+内存峰值),所以只渲染尾部
    // `pageSize` 条,顶部挂"载入更早"链接逐页往前补。
    private static let pageSize = 200
    private var messages: [AgentMessage] = []
    /// `messages` 中第一条已渲染消息的下标;>0 表示还有更早的页。
    private var visibleStart = 0
    /// 文档最顶部"载入更早"链接段的字符长度(0 = 已全部载入,无链接段)。
    /// 载入下一页时用它定位替换范围。
    private var headerLength = 0
    private weak var textView: NSTextView?

    init(session: AgentSession) {
        self.sessionID = session.id

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.allowsUndo = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.importsGraphics = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.translatesAutoresizingMaskIntoConstraints = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // Make the text view track the scroll view's content width so
        // long lines wrap instead of forcing horizontal scrolling.
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.title.isEmpty ? "Transcript" : "Transcript — \(session.title)"
        window.contentView = scrollView
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: false)

        self.textView = textView
        textView.delegate = self
        installTranscript(session: session)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// Replace the text content if the session shape changed since
    /// the window was opened (e.g. the user kept chatting in the
    /// underlying session). Called when re-`open` is invoked for the
    /// same id. Resets pagination back to the latest page.
    func refresh(with session: AgentSession) {
        window?.title = session.title.isEmpty ? "Transcript" : "Transcript — \(session.title)"
        installTranscript(session: session)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?(sessionID)
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    // MARK: - Transcript rendering (paged)

    /// (Re)build the document from scratch: "load earlier" header +
    /// the most recent `pageSize` messages + footer.
    private func installTranscript(session: AgentSession) {
        messages = session.messages
        visibleStart = max(0, messages.count - Self.pageSize)
        let header = Self.loadEarlierHeader(hiddenCount: visibleStart)
        headerLength = header.length
        let content = NSMutableAttributedString(attributedString: header)
        content.append(AgentChatHistoryRenderer.render(
            messages: Array(messages[visibleStart...]),
            isDark: false
        ))
        content.append(Self.footer(
            messageCount: messages.count,
            sessionID: sessionID,
            precededByContent: content.length > 0
        ))
        textView?.textStorage?.setAttributedString(content)
    }

    /// Prepend one more page of earlier messages, replacing the old
    /// "load earlier" header with a fresh one (or nothing when the
    /// whole transcript is now visible). Keeps the viewport anchored
    /// on the content the user was reading.
    private func loadEarlierPage() {
        guard visibleStart > 0,
              let textView,
              let textStorage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let newStart = max(0, visibleStart - Self.pageSize)
        let header = Self.loadEarlierHeader(hiddenCount: newStart)
        let replacement = NSMutableAttributedString(attributedString: header)
        replacement.append(AgentChatHistoryRenderer.render(
            messages: Array(messages[newStart..<visibleStart]),
            isDark: false
        ))
        // Renderer 只在同一次 render 内的消息之间插 "\n\n";页缝手工
        // 补一个,保持消息间距一致。
        replacement.append(NSAttributedString(
            string: "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ))

        let oldHeaderGlyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: headerLength),
            actualCharacterRange: nil
        )
        let oldTopHeight = layoutManager
            .boundingRect(forGlyphRange: oldHeaderGlyphRange, in: textContainer).maxY

        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: headerLength),
            with: replacement
        )
        headerLength = header.length
        visibleStart = newStart

        // 插入发生在视口上方,文档整体被顶下去了 —— 把滚动位置平移
        // 相同的高度,视口停留在点击前正在看的消息上。
        let insertedGlyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: replacement.length),
            actualCharacterRange: nil
        )
        let newTopHeight = layoutManager
            .boundingRect(forGlyphRange: insertedGlyphRange, in: textContainer).maxY
        if let scrollView = textView.enclosingScrollView {
            var origin = scrollView.contentView.bounds.origin
            origin.y += newTopHeight - oldTopHeight
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let value = link as? String,
              value == AgentTranscriptReaderLoadEarlierLink.value else { return false }
        loadEarlierPage()
        return true
    }

    private static func loadEarlierHeader(hiddenCount: Int) -> NSAttributedString {
        guard hiddenCount > 0 else { return NSAttributedString() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 12
        return NSAttributedString(
            string: L10n.AgentTranscriptReader.loadEarlier(min(pageSize, hiddenCount), hiddenCount) + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.linkColor,
                .link: AgentTranscriptReaderLoadEarlierLink.value,
                .cursor: NSCursor.pointingHand,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private static func footer(
        messageCount: Int,
        sessionID: UUID,
        precededByContent: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if precededByContent {
            result.append(NSAttributedString(
                string: "\n\n",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            ))
        }
        result.append(NSAttributedString(
            string: "—\n\(messageCount) message(s) total · session id \(sessionID.uuidString)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }
}

// MARK: - Single-message reader

/// Dedicated window for one message's full content. Used when the
/// chat pane truncates a message because it's too long for SwiftUI's
/// per-bubble layout to handle without freezing. One window per
/// message id so reopening the same message just brings it forward.
@MainActor
final class AgentSingleMessageReaderWindowRegistry {
    static let shared = AgentSingleMessageReaderWindowRegistry()
    private var windows: [UUID: AgentSingleMessageReaderWindowController] = [:]

    func open(message: AgentMessage, sessionTitle: String) {
        if let existing = windows[message.id] {
            existing.refresh(with: message, sessionTitle: sessionTitle)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AgentSingleMessageReaderWindowController(
            message: message,
            sessionTitle: sessionTitle
        )
        controller.onClose = { [weak self] id in
            self?.windows.removeValue(forKey: id)
        }
        windows[message.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AgentSingleMessageReaderWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((UUID) -> Void)?
    private let messageID: UUID
    /// rc14:同上,辅助 NSWindowController 默认接不到 Cmd+W,本窗口也用
    /// Find bar,所以无修饰 Esc 不当关窗。
    private var keyMonitor: Any?

    init(message: AgentMessage, sessionTitle: String) {
        self.messageID = message.id

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.allowsUndo = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.importsGraphics = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(role: message.role, sessionTitle: sessionTitle)
        window.contentView = scrollView
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: false)

        textView.textStorage?.setAttributedString(Self.render(message: message))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    func refresh(with message: AgentMessage, sessionTitle: String) {
        guard let scrollView = window?.contentView as? NSScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        window?.title = Self.windowTitle(role: message.role, sessionTitle: sessionTitle)
        textView.textStorage?.setAttributedString(Self.render(message: message))
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?(messageID)
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private static func windowTitle(role: AgentRole, sessionTitle: String) -> String {
        let roleLabel: String
        switch role {
        case .system: roleLabel = "system"
        case .user: roleLabel = "user"
        case .assistant: roleLabel = "assistant"
        case .tool: roleLabel = "tool"
        case .workflowReport: roleLabel = "workflow"
        case .widget: roleLabel = "widget"
        case .scheduledTask: roleLabel = "scheduled-task"
        }
        if sessionTitle.isEmpty {
            return "Message (\(roleLabel))"
        }
        return "Message (\(roleLabel)) — \(sessionTitle)"
    }

    private static func render(message: AgentMessage) -> NSAttributedString {
        AgentChatHistoryRenderer.render(messages: [message], isDark: false)
    }
}

// MARK: - Text attachment reader

@MainActor
final class AgentTextAttachmentReaderWindowRegistry {
    static let shared = AgentTextAttachmentReaderWindowRegistry()
    private var windows: [UUID: AgentTextAttachmentReaderWindowController] = [:]

    func open(attachment: AgentTextAttachment) {
        if let existing = windows[attachment.id] {
            existing.refresh(with: attachment)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AgentTextAttachmentReaderWindowController(attachment: attachment)
        controller.onClose = { [weak self] id in
            self?.windows.removeValue(forKey: id)
        }
        windows[attachment.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AgentTextAttachmentReaderWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((UUID) -> Void)?
    private let attachmentID: UUID
    private var keyMonitor: Any?

    init(attachment: AgentTextAttachment) {
        self.attachmentID = attachment.id

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.allowsUndo = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.importsGraphics = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: attachment)
        window.contentView = scrollView
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: false)
        textView.string = attachment.content
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    func refresh(with attachment: AgentTextAttachment) {
        guard let scrollView = window?.contentView as? NSScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        window?.title = Self.windowTitle(for: attachment)
        textView.string = attachment.content
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?(attachmentID)
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private static func windowTitle(for attachment: AgentTextAttachment) -> String {
        "\(attachment.displayName) · \(attachment.byteLabel)"
    }
}
