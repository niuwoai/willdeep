import SwiftUI

struct AgentSessionRetentionSettingsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Section(L10n.SessionManagement.section) {
            Toggle(L10n.SessionManagement.enabled, isOn: $appState.sessionRetentionSettings.enabled)
            Stepper(value: $appState.sessionRetentionSettings.keepCount,
                    in: AgentSessionRetentionSettings.allowedLimits) {
                Text(L10n.SessionManagement.keepCount(appState.sessionRetentionSettings.keepCount))
            }
            Text(L10n.SessionManagement.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.SessionManagement.protection)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.SessionManagement.runNow) { appState.requestAutomaticSessionArchiving() }
                    .disabled(!appState.sessionRetentionSettings.enabled || appState.sessionAutoArchiveRunning)
                if appState.sessionAutoArchiveRunning {
                    ProgressView().controlSize(.small)
                    Text(L10n.SessionManagement.running).foregroundStyle(.secondary)
                } else {
                    Text(L10n.SessionManagement.lastCount(appState.sessionAutoArchiveLastCount))
                        .foregroundStyle(.secondary)
                }
            }
            if appState.sessionAutoArchiveFailedCount > 0 {
                Text(L10n.SessionManagement.failedCount(appState.sessionAutoArchiveFailedCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension L10n {
    enum SessionManagement {
        static let section = String(localized: "section", table: "SessionManagement")
        static let enabled = String(localized: "enabled", table: "SessionManagement")
        static let description = String(localized: "description", table: "SessionManagement")
        static let protection = String(localized: "protection", table: "SessionManagement")
        static let runNow = String(localized: "run-now", table: "SessionManagement")
        static let running = String(localized: "running", table: "SessionManagement")
        static func keepCount(_ count: Int) -> String {
            String(format: String(localized: "keep-count", table: "SessionManagement"), count)
        }
        static func lastCount(_ count: Int) -> String {
            String(format: String(localized: "last-count", table: "SessionManagement"), count)
        }
        static func failedCount(_ count: Int) -> String {
            String(format: String(localized: "failed-count", table: "SessionManagement"), count)
        }
    }
}
