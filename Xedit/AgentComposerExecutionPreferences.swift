import SwiftUI

extension L10n {
    enum ExecutionPreferences {
        static let sandbox = String(localized: "composer.execution.sandbox", defaultValue: "Use sandbox by default")
        static let sandboxHelp = String(localized: "composer.execution.sandbox-help", defaultValue: "AI can retry outside the sandbox when needed, subject to the current approval rules.")
        static let priority = String(localized: "composer.execution.priority", defaultValue: "Execution priority")
        static let subagent = String(localized: "composer.execution.subagent", defaultValue: "Subagent first")
        static let agent = String(localized: "composer.execution.agent", defaultValue: "Agent first")
    }
}

extension AgentRuntime {
    var resolvedComposerDelegationPolicy: AgentDelegationPolicy {
        if pendingDelegationPolicy != .automatic { return pendingDelegationPolicy }
        return session.prefersSubagents == false ? .agentPreferred : .automatic
    }
}

extension AppState {
    func setComposerPrefersSubagents(_ preferred: Bool) {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        runtime.session.prefersSubagents = preferred
        persistAgentSession(runtime: runtime)
    }
}

struct AgentComposerExecutionPreferences: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.ExecutionPreferences.sandbox, isOn: Binding(
                get: { !(appState.activeRuntime?.localSandboxDisabled ?? false) },
                set: { appState.setLocalSandboxDisabled(!$0) }
            ))
            .toggleStyle(.switch)
            .help(L10n.ExecutionPreferences.sandboxHelp)
            Picker(L10n.ExecutionPreferences.priority, selection: Binding(
                get: { appState.activeRuntime?.session.prefersSubagents ?? true },
                set: { appState.setComposerPrefersSubagents($0) }
            )) {
                Text(L10n.ExecutionPreferences.subagent).tag(true)
                Text(L10n.ExecutionPreferences.agent).tag(false)
            }
            .pickerStyle(.menu)
        }
        .font(.system(size: 12))
    }
}
