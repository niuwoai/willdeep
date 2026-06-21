//
//  EditorSettingsSupport.swift
//  WillDeep
//
//  Small SwiftUI/AppKit support views used by Settings. The main
//  EditorSettingsView keeps the tab structure and settings state; this
//  file owns reusable chrome helpers and window behavior shims.
//

import SwiftUI
import AppKit
import Combine

enum EditorSettingsTab: Hashable {
    case typography
    case appearance
    case workspace
    case agent
    case localAgents
    case remoteRuntimes
    case mobileGateway
    case memory
    case rules
    case skills
    case connectors
    case mcp
    case tools
    case terminal
    case voice
}

@MainActor
final class EditorSettingsNavigation: ObservableObject {
    static let shared = EditorSettingsNavigation()

    @Published var selectedTab: EditorSettingsTab = .typography

    private init() {}

    func open(_ tab: EditorSettingsTab) {
        selectedTab = tab
        openWindow()
    }

    /// Open the settings window without changing the selected tab — used
    /// by the Agent status-bar gear so it lands on whatever section the
    /// user last had open.
    func openWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsKeyboardShortcutHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window,
                  event.window === window,
                  event.charactersIgnoringModifiers?.lowercased() == "w" else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.option) || modifiers.contains(.command) else {
                return event
            }

            window.performClose(nil)
            return nil
        }
    }
}

/// Secret field that toggles between SecureField (dots) and TextField
/// (revealed) via an eye button. Lets the user verify a pasted API key
/// without re-typing it. The reveal state lives in the view and is never
/// persisted, so closing Settings re-hides the key by default.
struct RevealableSecretField: View {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void

    @State private var isRevealed: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text, onCommit: onCommit)
                } else {
                    SecureField(placeholder, text: $text, onCommit: onCommit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? L10n.Settings.Provider.hideKey : L10n.Settings.Provider.showKey)
        }
    }
}

/// SwiftUI's `Settings { }` scene installs an `NSPanel` whose default
/// styleMask omits `.resizable`, so the user can't drag the corners
/// even after the SwiftUI view advertises `maxWidth: .infinity`. We
/// reach into the host window once it's available and add the
/// resizable + miniaturizable + zoom bits, drop the contentMaxSize
/// cap, and give it a sensible content min size.
struct SettingsWindowResizableEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        var mask = window.styleMask
        mask.insert(.resizable)
        mask.insert(.miniaturizable)
        mask.insert(.closable)
        mask.insert(.titled)
        window.styleMask = mask
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)
        window.isMovableByWindowBackground = false
        window.title = L10n.Settings.windowTitle
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
    }
}
