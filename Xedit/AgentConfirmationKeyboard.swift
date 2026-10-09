import AppKit
import SwiftUI

nonisolated enum AgentConfirmationKey: Equatable {
    case allow, deny, alwaysAllow, option(Int)

    var displayLabel: String {
        switch self {
        case .allow: "Y"
        case .deny: "N"
        case .alwaysAllow: "A"
        case .option(let index): String(index + 1)
        }
    }

    static func parse(_ text: String, optionCount: Int, isQuestion: Bool, allowsAlways: Bool) -> Self? {
        if isQuestion, let number = Int(text), (1...9).contains(number), number <= optionCount {
            return .option(number - 1)
        }
        switch text.lowercased() {
        case "y": return .allow
        case "n": return .deny
        case "a" where !isQuestion && allowsAlways: return .alwaysAllow
        default: return nil
        }
    }

    @MainActor static func permitsTextResponder(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSTextView else { return true }
        // An empty composer doubles as the decision keyboard. Other editors,
        // existing drafts and IME marked text retain normal text entry.
        return text is ComposerNSTextView && text.string.isEmpty && !text.hasMarkedText()
    }
}

/// Window-local monitor: one visible card owns the decision keys; teardown
/// removes its monitor so completed/offscreen conversations cannot approve.
struct AgentConfirmationKeyboard: NSViewRepresentable {
    let handler: (String) -> Bool

    func makeNSView(context: Context) -> KeyboardView { KeyboardView(handler: handler) }
    func updateNSView(_ view: KeyboardView, context: Context) { view.handler = handler }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.removeMonitor() }

    final class KeyboardView: NSView {
        var handler: (String) -> Bool
        private var monitor: Any?

        init(handler: @escaping (String) -> Bool) {
            self.handler = handler
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.process(event)
            }
        }

        func process(_ event: NSEvent) -> NSEvent? {
            guard monitor != nil, let window, window.isKeyWindow,
                  event.window === window, !event.isARepeat,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  AgentConfirmationKey.permitsTextResponder(window.firstResponder),
                  let text = event.charactersIgnoringModifiers else { return event }
            return handler(text) ? nil : event
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
