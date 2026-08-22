//
//  AgentGlobalRulesSettingsView.swift
//  WillDeep
//
//  Settings tab for user-level Agent rules.
//

import AppKit
import SwiftUI

struct AgentGlobalRulesSettingsView: View {
    @State private var settings = AgentGlobalRulesSettings.default
    @State private var rulesText = ""
    @State private var statusMessage = ""
    @State private var isLoadingRules = false

    var body: some View {
        Form {
            Section(L10n.Settings.GlobalRules.fileSection) {
                Toggle(L10n.Settings.GlobalRules.enableToggle, isOn: Binding(
                    get: { settings.isEnabled },
                    set: { newValue in
                        settings.isEnabled = newValue
                        saveSettings()
                    }
                ))

                LabeledContent(L10n.Settings.GlobalRules.filePathLabel) {
                    HStack {
                        TextField("", text: Binding(
                            get: { settings.filePath },
                            set: { settings.filePath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button(L10n.Settings.buttonChoose) {
                            chooseRulesFile()
                        }

                        Button(L10n.Settings.GlobalRules.reloadButton) {
                            loadRulesText()
                        }
                        .disabled(isLoadingRules)
                    }
                }

                Text(L10n.Settings.GlobalRules.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let rulesRoot = AgentBundledRules.rootURL() {
                    LabeledContent(L10n.Settings.GlobalRules.bundledLibraryLabel) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(AgentGlobalRulesStore.displayPath(for: rulesRoot))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if let version = AgentBundledRules.manifest(rootURL: rulesRoot)?.rulesVersion {
                                Text(L10n.Settings.GlobalRules.bundledLibraryVersion(version))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section(L10n.Settings.GlobalRules.editorSection) {
                TextEditor(text: $rulesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )

                HStack {
                    Button(L10n.Settings.GlobalRules.loadBundledIndexButton) {
                        loadBundledIndex()
                    }

                    Button(L10n.Settings.buttonSave) {
                        saveRulesText()
                    }

                    Button(L10n.Settings.buttonRevert) {
                        loadRulesText()
                    }
                    .disabled(isLoadingRules)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text(L10n.Settings.GlobalRules.precedenceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isLoadingRules && rulesText.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
        }
        .task {
            await reloadRulesText(loadStoredSettings: true)
        }
    }

    private func saveSettings() {
        settings = settings.normalized
        AgentGlobalRulesStore.saveSettings(settings)
    }

    private func loadRulesText() {
        saveSettings()
        Task {
            await reloadRulesText(loadStoredSettings: false)
        }
    }

    @MainActor
    private func reloadRulesText(loadStoredSettings: Bool) async {
        guard !isLoadingRules else { return }
        isLoadingRules = true

        let snapshot = await AgentGlobalRulesStore.loadEditorSnapshot(
            settings: loadStoredSettings ? nil : settings
        )
        guard !Task.isCancelled else { return }

        settings = snapshot.settings
        rulesText = snapshot.text
        let displayPath = AgentGlobalRulesStore.displayPath(for: snapshot.url)
        statusMessage = rulesText.isEmpty
            ? L10n.Settings.GlobalRules.noFileStatus(displayPath)
            : L10n.Settings.GlobalRules.loadedStatus(displayPath)
        isLoadingRules = false
    }

    private func saveRulesText() {
        saveSettings()
        do {
            try AgentGlobalRulesStore.saveRules(rulesText, settings: settings)
            statusMessage = L10n.Settings.GlobalRules.savedStatus(
                AgentGlobalRulesStore.displayPath(for: AgentGlobalRulesStore.resolvedURL(for: settings.filePath))
            )
        } catch {
            statusMessage = L10n.Settings.GlobalRules.saveFailed(error.localizedDescription)
        }
    }

    private func loadBundledIndex() {
        rulesText = AgentGlobalRulesStore.defaultRulesTemplate
        statusMessage = L10n.Settings.GlobalRules.bundledIndexLoadedStatus
    }

    private func chooseRulesFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.Settings.GlobalRules.choosePanelTitle
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = AgentGlobalRulesStore.resolvedURL(for: settings.filePath)
            .deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.filePath = AgentGlobalRulesStore.displayPath(for: url)
        saveSettings()
        loadRulesText()
    }
}
