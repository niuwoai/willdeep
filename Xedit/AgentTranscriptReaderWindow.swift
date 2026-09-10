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
//     SwiftUI. The transcript is paged so only a bounded message
//     segment is baked into an `NSAttributedString` at any one time.
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

nonisolated enum AgentTranscriptPagination {
    static let messagesPerPage = 60

    static func pageCount(for messageCount: Int) -> Int {
        let safeCount = max(0, messageCount)
        return max(1, (safeCount + messagesPerPage - 1) / messagesPerPage)
    }

    static func messageRange(messageCount: Int, pageIndex: Int) -> Range<Int> {
        let safeCount = max(0, messageCount)
        let lastPageIndex = pageCount(for: safeCount) - 1
        let safePageIndex = min(max(0, pageIndex), lastPageIndex)
        let lowerBound = min(safeCount, safePageIndex * messagesPerPage)
        let upperBound = min(safeCount, lowerBound + messagesPerPage)
        return lowerBound..<upperBound
    }
}

@MainActor
final class AgentTranscriptReaderWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the underlying NSWindow closes so the registry can
    /// drop its reference.
    var onClose: ((UUID) -> Void)?
    private let sessionID: UUID
    private var session: AgentSession
    private var currentPageIndex: Int
    private let textView: NSTextView
    private let previousPageButton: NSButton
    private let nextPageButton: NSButton
    private let pageLabel: NSTextField
    /// rc14:挂在主菜单响应链外的窗口,默认接不到 Cmd+W —— 装一个本地
    /// keyDown 监听把它路由到 `performClose(_:)`。本窗口内嵌 NSTextView
    /// 用了 Find bar,所以 **不**把无修饰 Esc 也当关窗,免得截掉搜索取消。
    private var keyMonitor: Any?

    init(session: AgentSession) {
        self.sessionID = session.id
        self.session = session
        self.currentPageIndex = AgentTranscriptPagination.pageCount(for: session.messages.count) - 1

        let textView = NSTextView()
        self.textView = textView
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

        let previousPageButton = NSButton()
        self.previousPageButton = previousPageButton
        previousPageButton.bezelStyle = .texturedRounded
        previousPageButton.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: "Previous transcript page"
        )
        previousPageButton.toolTip = "Previous page"

        let nextPageButton = NSButton()
        self.nextPageButton = nextPageButton
        nextPageButton.bezelStyle = .texturedRounded
        nextPageButton.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Next transcript page"
        )
        nextPageButton.toolTip = "Next page"

        let pageLabel = NSTextField(labelWithString: "")
        self.pageLabel = pageLabel
        pageLabel.alignment = .center
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let pageControls = NSStackView(views: [previousPageButton, pageLabel, nextPageButton])
        pageControls.orientation = .horizontal
        pageControls.alignment = .centerY
        pageControls.spacing = 8

        let contentView = NSView()
        pageControls.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pageControls)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            pageControls.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            pageControls.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: pageControls.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

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
        window.contentView = contentView
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: false)
        previousPageButton.target = self
        previousPageButton.action = #selector(showPreviousPage)
        nextPageButton.target = self
        nextPageButton.action = #selector(showNextPage)
        renderCurrentPage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// Replace the text content if the session shape changed since
    /// the window was opened (e.g. the user kept chatting in the
    /// underlying session). Called when re-`open` is invoked for the
    /// same id.
    func refresh(with session: AgentSession) {
        let oldLastPageIndex = AgentTranscriptPagination.pageCount(for: self.session.messages.count) - 1
        let wasShowingLatestPage = currentPageIndex == oldLastPageIndex
        self.session = session
        let newLastPageIndex = AgentTranscriptPagination.pageCount(for: session.messages.count) - 1
        currentPageIndex = wasShowingLatestPage ? newLastPageIndex : min(currentPageIndex, newLastPageIndex)
        window?.title = session.title.isEmpty ? "Transcript" : "Transcript — \(session.title)"
        renderCurrentPage()
    }

    @objc private func showPreviousPage() {
        guard currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        renderCurrentPage()
    }

    @objc private func showNextPage() {
        let lastPageIndex = AgentTranscriptPagination.pageCount(for: session.messages.count) - 1
        guard currentPageIndex < lastPageIndex else { return }
        currentPageIndex += 1
        renderCurrentPage()
    }

    private func renderCurrentPage() {
        let messageCount = session.messages.count
        let range = AgentTranscriptPagination.messageRange(
            messageCount: messageCount,
            pageIndex: currentPageIndex
        )
        let messages = Array(session.messages[range])
        textView.textStorage?.setAttributedString(Self.renderTranscript(
            messages: messages,
            messageRange: range,
            session: session
        ))

        let pageCount = AgentTranscriptPagination.pageCount(for: messageCount)
        pageLabel.stringValue = "Page \(currentPageIndex + 1) of \(pageCount)"
        previousPageButton.isEnabled = currentPageIndex > 0
        nextPageButton.isEnabled = currentPageIndex + 1 < pageCount
        textView.scrollToBeginningOfDocument(nil)
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

    // MARK: - Transcript rendering

    /// Build one bounded transcript page using the same TextKit Markdown
    /// renderer as the chat-pane history.
    private static func renderTranscript(
        messages: [AgentMessage],
        messageRange: Range<Int>,
        session: AgentSession
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false
        ))
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let secondaryColor = NSColor.secondaryLabelColor

        // Add a small footer with the visible range and overall message count.
        if result.length > 0 {
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
        }
        let visibleRange: String
        if messageRange.isEmpty {
            visibleRange = "0"
        } else {
            visibleRange = "\(messageRange.lowerBound + 1)–\(messageRange.upperBound)"
        }
        result.append(NSAttributedString(
            string: "—\nShowing \(visibleRange) of \(session.messages.count) message(s) · session id \(session.id.uuidString)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: secondaryColor,
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
        case .specProposal: roleLabel = "design-proposal"
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
