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

extension View {
    @ViewBuilder
    func focusEffectDisabledCompat() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }

    @ViewBuilder
    func symbolPulseCompat() -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.pulse)
        } else {
            self
        }
    }

    func onCompatibleChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        onChange(of: value, perform: action)
    }

    func onCompatibleChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(CompatibleChangeModifier(value: value, action: action))
    }

    func settingsFocusDisabled() -> some View {
        focusable(false)
            .focusEffectDisabledCompat()
    }
}

private struct CompatibleChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void

    @State private var previousValue: Value?

    func body(content: Content) -> some View {
        content
            .onAppear {
                previousValue = value
            }
            .onChange(of: value, perform: handleChange)
    }

    private func handleChange(_ newValue: Value) {
        let oldValue = previousValue ?? newValue
        previousValue = newValue
        action(oldValue, newValue)
    }
}

enum EditorSettingsTab: Hashable {
    case updates
    case privacy
    case agentAppearance
    case agent
    case localModels
    case notifications
    case subagents
    case someIM
    case replicate
    case localAgents
    case remoteRuntimes
    case mobileGateway
    case memory
    case rules
    case skills
    case connectors
    case mcp
    case tools
    case secrets
    case terminal
    case pet
}

extension EditorSettingsTab {
    /// Top-level group this pane lives under. The Settings window used to
    /// show all 16 panes as flat tabs (cramped, labels truncated); they're
    /// now bucketed into a handful of groups with a second-level segmented
    /// picker. Keeping all 16 cases intact means existing deep-links
    /// (e.g. `selectedTab = .mobileGateway`) still resolve to the right group.
    var group: SettingsGroup {
        switch self {
        case .updates, .privacy: return .general
        case .agentAppearance: return .agentAppearance
        case .localModels: return .localModels
        case .agent, .notifications, .memory, .rules: return .ai
        // Agent profiles is its own top-level group: it is where the model,
        // window, round budget and preloaded skills of every trade are set,
        // which is configuration people return to, not a corner of "AI".
        case .subagents: return .agentProfiles
        case .skills, .mcp, .tools, .secrets: return .agentTools
        case .localAgents, .remoteRuntimes: return .runtimes
        case .terminal: return .terminal
        case .someIM, .mobileGateway: return .accountAndDevices
        // `.replicate` stays a distinct case for deep-links, but renders as
        // a sub-connector inside the unified connectors hub.
        case .replicate, .connectors: return .integrations
        case .pet: return .pet
        }
    }

    /// Short label for the second-level segmented picker — reuses the
    /// existing per-pane menu titles so nothing new needs translating.
    var shortTitle: String {
        switch self {
        case .updates: return L10n.Settings.tabUpdates
        case .privacy: return L10n.Telemetry.tabTitle
        case .agentAppearance: return L10n.Settings.tabAgentAppearance
        case .localModels: return L10n.Settings.LocalModel.pageTitle
        case .agent: return L10n.Settings.tabAgent
        case .notifications: return L10n.AgentNotifications.Settings.tabTitle
        case .subagents: return L10n.AgentProfiles.tabTitle
        case .someIM: return L10n.Settings.tabSomeIM
        case .replicate: return L10n.Settings.tabReplicate
        case .localAgents: return L10n.Settings.tabLocalAgents
        case .remoteRuntimes: return L10n.Settings.tabRemoteRuntimes
        case .mobileGateway: return L10n.Settings.tabMobileGateway
        case .memory: return L10n.Settings.tabMemory
        case .rules: return L10n.Settings.tabRules
        case .skills: return L10n.Settings.tabSkills
        case .connectors: return L10n.Settings.tabConnectors
        case .mcp: return L10n.Settings.tabMcp
        case .tools: return L10n.Settings.tabTools
        case .secrets: return L10n.SecretManager.tabTitle
        case .terminal: return L10n.Settings.tabTerminal
        case .pet: return L10n.DesktopPet.settingsTabTitle
        }
    }
}

/// Top-level Settings groupings. Each becomes one tab in the Settings window;
/// groups with more than one pane render a second-level segmented picker.
enum SettingsGroup: Hashable, Identifiable {
    case accountAndDevices
    case ai
    case localModels
    case agentProfiles
    case agentTools
    case runtimes
    case integrations
    case terminal
    case pet
    case agentAppearance
    case general

    static let allCases: [Self] = [
        .accountAndDevices,
        .ai,
        .localModels,
        .agentProfiles,
        .agentTools,
        .runtimes,
        .integrations,
        .terminal,
        .pet,
        .agentAppearance,
        .general,
    ]

    var id: Self { self }

    /// Panes in display order. Drives both the segmented picker and which
    /// pane a freshly-selected group falls back to.
    var tabs: [EditorSettingsTab] {
        switch self {
        case .general: return [.updates, .privacy]
        case .agentAppearance: return [.agentAppearance]
        case .pet: return [.pet]
        case .localModels: return [.localModels]
        case .ai: return [.agent, .notifications, .memory, .rules]
        case .agentProfiles: return [.subagents]
        case .agentTools: return [.skills, .mcp, .tools, .secrets]
        case .accountAndDevices: return [.someIM, .mobileGateway]
        case .runtimes: return [.localAgents, .remoteRuntimes]
        // A single connectors hub pane; each integration (飞书 / 钉钉 /
        // 企业微信 / Replicate / …) is a sub-connector inside it.
        case .integrations: return [.connectors]
        case .terminal: return [.terminal]
        }
    }

    var title: String {
        switch self {
        case .general: return L10n.Settings.tabUpdates
        case .agentAppearance: return L10n.Settings.groupAgentAppearance
        case .pet: return L10n.DesktopPet.settingsTabTitle
        case .localModels: return L10n.Settings.LocalModel.pageTitle
        case .ai: return L10n.Settings.groupAI
        case .agentProfiles: return L10n.AgentProfiles.tabTitle
        case .agentTools: return L10n.Settings.groupAgentTools
        case .accountAndDevices: return L10n.Settings.groupAccountAndDevices
        case .runtimes: return L10n.Settings.groupRuntimes
        case .integrations: return L10n.Settings.groupIntegrations
        case .terminal: return L10n.Settings.groupTerminal
        }
    }

    var icon: String {
        switch self {
        case .general: return "arrow.triangle.2.circlepath"
        case .agentAppearance: return "textformat.size"
        case .pet: return "pawprint.fill"
        case .localModels: return "cpu"
        case .ai: return "sparkles"
        case .agentProfiles: return "person.2.badge.gearshape"
        case .agentTools: return "wrench.and.screwdriver"
        case .accountAndDevices: return "person.crop.circle.badge.checkmark"
        case .runtimes: return "network"
        case .integrations: return "puzzlepiece.extension"
        case .terminal: return "rectangle.bottomthird.inset.filled"
        }
    }
}

@MainActor
final class EditorSettingsNavigation: ObservableObject {
    static let shared = EditorSettingsNavigation()

    @Published var selectedTab: EditorSettingsTab = .updates
    @Published var someIMBrowserLoginAutogenerateRequestID: UUID?
    private var fallbackSettingsWindowController: NSWindowController?

    private init() {}

    func open(_ tab: EditorSettingsTab, appState: AppState? = nil) {
        selectedTab = tab
        openFallbackSettingsWindow(appState: appState)
        DispatchQueue.main.async { [weak self] in
            self?.selectedTab = tab
        }
    }

    func openSomeIM(autogenerateBrowserLogin: Bool, appState: AppState? = nil) {
        if autogenerateBrowserLogin {
            someIMBrowserLoginAutogenerateRequestID = UUID()
        }
        // Always use the same concrete Settings window for this deep-link.
        // `showSettingsWindow:` may report success from the Agent window while
        // leaving the system Settings scene on its previous tab (or hidden).
        // The fallback controller is stable for both logged-in and logged-out
        // account footer actions, so the account name and gear reliably land
        // on the some.im integration pane.
        selectedTab = .someIM
        openFallbackSettingsWindow(appState: appState)
        DispatchQueue.main.async { [weak self] in
            self?.selectedTab = .someIM
        }
    }

    /// Open the settings window without changing the selected tab — used
    /// by the Agent status-bar gear so it lands on whatever section the
    /// user last had open.
    func openWindow(appState: AppState? = nil) {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openFallbackSettingsWindow(appState: appState)
    }

    private func openFallbackSettingsWindow(appState: AppState?) {
        if let window = fallbackSettingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let state = appState ?? AppState()
        let content = EditorSettingsView()
            .environmentObject(state)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = L10n.Settings.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.setContentSize(NSSize(width: 920, height: 700))
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        fallbackSettingsWindowController = controller
        controller.showWindow(nil)
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
        EnforcerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    /// `viewDidMoveToWindow` fires exactly when the view is attached to the
    /// host NSPanel, so `window` is guaranteed non-nil there. The previous
    /// one-shot `DispatchQueue.main.async` in makeNSView could run before the
    /// view had a window and then silently no-op — leaving the panel stuck at
    /// its default non-resizable styleMask (the "can't drag the corners" bug).
    private final class EnforcerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            SettingsWindowResizableEnforcer.apply(to: window)
        }
    }

    fileprivate static func apply(to window: NSWindow?) {
        guard let window else { return }
        var mask = window.styleMask
        mask.insert(.resizable)
        mask.insert(.miniaturizable)
        mask.insert(.closable)
        mask.insert(.titled)
        window.styleMask = mask
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)
        window.isMovableByWindowBackground = false
        window.title = L10n.Settings.windowTitle
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
    }
}
