import Foundation

extension L10n {
    enum SessionSandbox {
        static let disable = String(localized: "session-sandbox.disable", defaultValue: "Disable the local sandbox for this session; approvals remain active")
        static let enable = String(localized: "session-sandbox.enable", defaultValue: "Restore the local sandbox for this session")
        static let disabled = String(localized: "session-sandbox.disabled", defaultValue: "Local sandbox disabled for this session. Existing approvals still apply. Use /sandbox or More settings to restore it.")
        static let enabled = String(localized: "session-sandbox.enabled", defaultValue: "Local sandbox restored for subsequent commands in this session.")
        static let prompt = String(localized: "session-sandbox.prompt", defaultValue: "Optional message")
    }
}

extension AppState {
    func setLocalSandboxDisabled(_ disabled: Bool, text: String = "") {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        runtime.localSandboxDisabled = disabled
        runtime.session.sandboxEnabled = !disabled
        runtime.messages.append(AgentMessage(role: .system,
            content: disabled ? L10n.SessionSandbox.disabled : L10n.SessionSandbox.enabled))
        persistAgentSession(runtime: runtime)
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            runtime.input = message
            sendAgentMessage()
        }
    }
}
