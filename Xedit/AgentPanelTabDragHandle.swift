import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let willDeepPanelTab = UTType(exportedAs: "com.willdeep.panel-tab")
}

/// Native drag sessions distinguish an outside drop from Escape cancellation.
struct AgentPanelTabDragHandle: NSViewRepresentable {
    let id: AgentPanelTabID
    let title: String
    let onClick: () -> Void
    let onDetach: () -> Void

    func makeNSView(context: Context) -> AgentPanelTabDragView { AgentPanelTabDragView() }
    func updateNSView(_ view: AgentPanelTabDragView, context: Context) {
        view.tabID = id
        view.title = title
        view.onClick = onClick
        view.onDetach = onDetach
        view.setAccessibilityLabel(title)
        view.setAccessibilityRole(.button)
    }
}

final class AgentPanelTabDragView: NSView, NSDraggingSource {
    var tabID: AgentPanelTabID?
    var title = ""
    var onClick: (() -> Void)?
    var onDetach: (() -> Void)?
    private var mouseDownEvent: NSEvent?
    private var isDragging = false
    private var escapeMonitor: Any?
    private var wasCancelled = false

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event; isDragging = false }
    override func mouseUp(with event: NSEvent) {
        if !isDragging { onClick?() }
        mouseDownEvent = nil
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownEvent, let tabID,
              hypot(event.locationInWindow.x - start.locationInWindow.x,
                    event.locationInWindow.y - start.locationInWindow.y) > 5,
              let data = try? JSONEncoder().encode(tabID) else { return }
        isDragging = true
        wasCancelled = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.wasCancelled = true }
            return event
        }
        let writer = NSPasteboardItem()
        writer.setData(data, forType: NSPasteboard.PasteboardType(UTType.willDeepPanelTab.identifier))
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: bounds.size, flipped: false) { [title] rect in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            (title as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
            ])
            return true
        }
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        // A failed drop elsewhere within the source window isn't a detach.
        if operation.isEmpty, !wasCancelled, window?.frame.contains(screenPoint) == false { onDetach?() }
        mouseDownEvent = nil
    }
}
