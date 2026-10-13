import AppKit
import Testing
@testable import WillDeep

@Suite("聊天历史悬停生命周期", .serialized)
@MainActor
struct AgentChatHistoryHoverLifecycleTests {
    private func hasTranscriptHoverArea(_ view: AgentChatHistoryNSTextView) -> Bool {
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited]
        // NSTextView also owns AppKit cursor/text tracking (551/552). Those
        // remain AppKit's responsibility; verify the transcript's area (547).
        return view.trackingAreas.contains { $0.options == options }
    }
    @Test("悬停限于视图追踪区域，移除后清理，重新挂载恢复")
    func attachDetachAndReattach() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView = host
        let view = AgentChatHistoryNSTextView()
        view.frame = host.bounds
        window.acceptsMouseMovedEvents = false
        host.addSubview(view)
        view.updateTrackingAreas()
        #expect(!window.acceptsMouseMovedEvents)
        #expect(hasTranscriptHoverArea(view))
        view.removeFromSuperview()
        view.updateTrackingAreas()
        #expect(!hasTranscriptHoverArea(view))
        host.addSubview(view)
        view.updateTrackingAreas()
        #expect(hasTranscriptHoverArea(view))
    }

    @Test("窗口开始关闭或 SwiftUI 拆卸后不会重新创建悬停追踪")
    func closeAndDismantle() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = AgentChatHistoryNSTextView()
        window.contentView = view
        view.updateTrackingAreas()
        #expect(hasTranscriptHoverArea(view))
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        view.updateTrackingAreas()
        #expect(!hasTranscriptHoverArea(view))
        AgentChatHistoryTextView.dismantleNSView(view, coordinator: ())
        view.updateTrackingAreas()
        #expect(view.delegate == nil)
        #expect(!hasTranscriptHoverArea(view))
    }
}
