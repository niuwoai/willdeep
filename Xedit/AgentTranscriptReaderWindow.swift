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
//     SwiftUI. NSTextView gets the entire transcript baked into one
//     `NSAttributedString` once at open time; TextKit handles its
//     own layout incrementally and doesn't bother the main thread
//     during scroll.
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

@MainActor
final class AgentTranscriptReaderWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the underlying NSWindow closes so the registry can
    /// drop its reference.
    var onClose: ((UUID) -> Void)?
    private let sessionID: UUID

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

        let attributed = Self.renderTranscript(session: session)
        textView.textStorage?.setAttributedString(attributed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// Replace the text content if the session shape changed since
    /// the window was opened (e.g. the user kept chatting in the
    /// underlying session). Called when re-`open` is invoked for the
    /// same id.
    func refresh(with session: AgentSession) {
        guard let scrollView = window?.contentView as? NSScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        window?.title = session.title.isEmpty ? "Transcript" : "Transcript — \(session.title)"
        textView.textStorage?.setAttributedString(Self.renderTranscript(session: session))
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(sessionID)
    }

    // MARK: - Transcript rendering

    /// Build the full transcript as one NSAttributedString using the
    /// same TextKit Markdown renderer as the chat-pane history.
    private static func renderTranscript(session: AgentSession) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: AgentChatHistoryRenderer.render(
            messages: session.messages,
            isDark: false
        ))
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let secondaryColor = NSColor.secondaryLabelColor

        // Add a small footer with overall message count.
        if result.length > 0 {
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
        }
        result.append(NSAttributedString(
            string: "—\n\(session.messages.count) message(s) total · session id \(session.id.uuidString)",
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
        onClose?(messageID)
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
