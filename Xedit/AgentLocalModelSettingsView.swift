//
//  AgentLocalModelSettingsView.swift
//  WillDeep
//
//  Settings UI for local OpenAI-compatible auxiliary models.
//

import SwiftUI
import AppKit

struct AgentLocalModelSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var settings = AgentSettingsStore.loadLocalModelSettings()
    @State private var savedSettings = AgentSettingsStore.loadLocalModelSettings()
    @State private var statusMessage = ""


    var body: some View {
        Section(L10n.Settings.LocalModel.pageTitle) {
            Text(L10n.Settings.LocalModel.serviceHelp)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.Settings.LocalModel.enabled, isOn: $settings.enabled)
                .onCompatibleChange(of: settings.enabled) { _, _ in save() }

            LabeledContent(L10n.Settings.LocalModel.baseURL) {
                TextField("", text: $settings.baseURL, onCommit: save)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.LocalModel.visionModel) {
                TextField("", text: $settings.visionModel, onCommit: save)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.LocalModel.llmModel) {
                TextField("", text: $settings.summaryModel, onCommit: save)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(L10n.Settings.LocalModel.preferVision, isOn: $settings.preferForImageUnderstanding)
                .onCompatibleChange(of: settings.preferForImageUnderstanding) { _, _ in save() }
            Toggle(L10n.Settings.LocalModel.preferTitle, isOn: $settings.preferForTitles)
                .onCompatibleChange(of: settings.preferForTitles) { _, _ in save() }
            Toggle(L10n.Settings.LocalModel.preferWorkerRouting, isOn: $settings.preferForWorkerRouting)
                .onCompatibleChange(of: settings.preferForWorkerRouting) { _, _ in save() }
            Text(L10n.Settings.LocalModel.workerRoutingHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(L10n.Settings.LocalModel.warmOnLaunch, isOn: $settings.warmOnLaunchAndKeepResident)
                .onCompatibleChange(of: settings.warmOnLaunchAndKeepResident) { _, _ in save() }
            Text(L10n.Settings.LocalModel.warmOnLaunchHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.Settings.LocalModel.exposeComposerModel, isOn: $settings.exposeAsComposerModel)
                .onCompatibleChange(of: settings.exposeAsComposerModel) { _, _ in save() }

            LabeledContent(L10n.Settings.LocalModel.composerModelName) {
                TextField("", text: $settings.composerDisplayName, prompt: Text(L10n.Settings.LocalModel.composerModelNamePlaceholder))
                    .onSubmit(save)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.exposeAsComposerModel)
            }

            HStack {
                Button(L10n.Settings.buttonSave) { save() }
                    .disabled(!settingsDiffer)
                Button(L10n.Settings.buttonRevert) { revert() }
                    .disabled(!settingsDiffer)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(L10n.Settings.LocalModel.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Settings.LocalModel.localProviderListed)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        .onAppear {
            let loaded = AgentSettingsStore.loadLocalModelSettings()
            settings = loaded
            savedSettings = loaded
        }
    }

    private var settingsDiffer: Bool {
        settings.normalized != savedSettings.normalized
    }

    private func save() {
        let normalized = settings.normalized
        settings = normalized
        savedSettings = normalized
        AgentSettingsStore.saveLocalModelSettings(normalized)
        appState.syncLocalModelComposerProvider(settings: normalized)
        statusMessage = L10n.Settings.savedStatus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if statusMessage == L10n.Settings.savedStatus {
                statusMessage = ""
            }
        }
    }

    private func revert() {
        settings = savedSettings
        statusMessage = ""
    }

}
