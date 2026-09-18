//
//  TelemetrySettingsView.swift
//  WillDeep
//
//  隐私设置：产品遥测的开关、匿名标识与数据删除。
//
//  这一页刻意把「收集什么」和「绝不收集什么」并列写清楚，而不是一句
//  「可能收集使用信息」了事——采集范围本来就该让人一眼看完。
//

import SwiftUI

struct TelemetrySettingsView: View {
    @State private var isEnabled = TelemetryPreferences().isEnabled
    @State private var installID = TelemetryPreferences().existingInstallID()
    @State private var statusMessage: String?
    @State private var isPerformanceReportingEnabled = TelemetryPreferences().isPerformanceReportingEnabled

    private let preferences = TelemetryPreferences()

    var body: some View {
        Form {
            Section(L10n.Telemetry.sectionTitle) {
                // 部署目标是 macOS 13.7，用旧签名的 onChange。
                Toggle(L10n.Telemetry.toggleTitle, isOn: $isEnabled)
                    .onChange(of: isEnabled) { newValue in
                        AgentTelemetry.setEnabled(newValue)
                        statusMessage = newValue ? nil : L10n.Telemetry.disabledNotice
                        installID = preferences.existingInstallID()
                    }

                Text(L10n.Telemetry.toggleHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L10n.Telemetry.endpointLabel) {
                    Text(TelemetryEndpoint.origin)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section(L10n.Telemetry.performanceSection) {
                Toggle(L10n.Telemetry.performanceToggle, isOn: $isPerformanceReportingEnabled)
                    .onChange(of: isPerformanceReportingEnabled) { newValue in
                        PerformanceWatchdog.setEnabled(newValue)
                    }
                Text(L10n.Telemetry.performanceHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.Telemetry.collectedTitle) {
                Text(L10n.Telemetry.collectedBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.Telemetry.notCollectedTitle) {
                Text(L10n.Telemetry.notCollectedBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.Telemetry.identitySection) {
                LabeledContent(L10n.Telemetry.identifierLabel) {
                    Text(installID ?? "—")
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(L10n.Telemetry.identityHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.Telemetry.resetIdentity) {
                    AgentTelemetry.resetInstallIdentity()
                    installID = preferences.existingInstallID()
                    statusMessage = L10n.Telemetry.identityReset
                }
                .disabled(installID == nil)
            }

            Section(L10n.Telemetry.deleteSection) {
                Button(L10n.Telemetry.deleteData) {
                    AgentTelemetry.requestDataDeletion()
                    statusMessage = L10n.Telemetry.deleteRequested
                }
                .disabled(installID == nil)
                Text(L10n.Telemetry.deleteHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            isEnabled = preferences.isEnabled
            isPerformanceReportingEnabled = preferences.isPerformanceReportingEnabled
            installID = preferences.existingInstallID()
            preferences.hasAcknowledgedNotice = true
        }
    }
}
