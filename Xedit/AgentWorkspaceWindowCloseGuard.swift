import AppKit
import SwiftUI

/// Protects the Settings window (and isolated QA preview) without replacing AppDelegate.
@MainActor struct AgentWorkspaceWindowCloseGuard: NSViewRepresentable {
    @ObservedObject var navigation: AgentWorkspaceNavigation

    func makeCoordinator() -> Coordinator { Coordinator(navigation: navigation) }
    func makeNSView(context: Context) -> WindowObserver {
        let view = WindowObserver()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: WindowObserver, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: WindowObserver, coordinator: Coordinator) { coordinator.attach(nil) }

    final class WindowObserver: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChanged?(window) }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private let navigation: AgentWorkspaceNavigation
        private weak var window: NSWindow?
        // NSObject's Objective-C forwarding hooks are nonisolated. AppKit invokes
        // them on the UI thread; this reference is only changed by attach there.
        nonisolated(unsafe) private var original: (any NSWindowDelegate)?
        init(navigation: AgentWorkspaceNavigation) { self.navigation = navigation }

        func attach(_ next: NSWindow?) {
            guard window !== next else { return }
            if let window, window.delegate === self { window.delegate = original }
            original = nil; window = next
            guard let next else { return }
            original = next.delegate
            next.delegate = self
            navigation.closeWorkspaceWindow = { [weak self] requestID in self?.closeAfterDialogDismisses(requestID) }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // Settings may use a system scene or the fallback controller.
            // Associate confirmation with the window actually being closed.
            navigation.closeWorkspaceWindow = { [weak self] requestID in self?.closeAfterDialogDismisses(requestID) }
            guard navigation.closeIntent.request(isDirty: !navigation.dirtySections.isEmpty) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            let delegate = original
            navigation.dirtySections.removeAll(); navigation.cancelPendingNavigation()
            navigation.closeIntent.continueEditing()
            delegate?.windowWillClose?(notification)
        }
        private func closeAfterDialogDismisses(_ requestID: UUID) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A synchronous performClose can be ignored while SwiftUI is
                // still dismissing its confirmation sheet. Bound this wait.
                for _ in 0..<20 {
                    do { try await Task.sleep(for: .milliseconds(25)) }
                    catch { navigation.closeIntent.abandonApprovedClose(requestID); return }
                    guard navigation.closeIntent.approvedRequestID == requestID, let window else { return }
                    guard window.attachedSheet == nil else { continue }
                    window.performClose(nil)
                    do { try await Task.sleep(for: .milliseconds(25)) }
                    catch { navigation.closeIntent.abandonApprovedClose(requestID); return }
                    if !window.isVisible { return }
                    break
                }
                // A blocked close must leave the unchanged editor protected.
                navigation.closeIntent.abandonApprovedClose(requestID)
            }
        }
        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
