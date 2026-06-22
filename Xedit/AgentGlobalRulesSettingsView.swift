//
//  AgentGlobalRulesSettingsView.swift
//  WillDeep
//
//  Settings tab for user-level Agent rules.
//

import AppKit
import SwiftUI

struct AgentGlobalRulesSettingsView: View {
    @State private var settings = AgentGlobalRulesStore.loadSettings()
    @State private var rulesText = ""
    @State private var statusMessage = ""

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
                    }
                }

                Text(L10n.Settings.GlobalRules.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Button(L10n.Settings.buttonSave) {
                        saveRulesText()
                    }

                    Button(L10n.Settings.buttonRevert) {
                        loadRulesText()
                    }

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
        .onAppear {
            loadRulesText()
        }
    }

    private func saveSettings() {
        settings = settings.normalized
        AgentGlobalRulesStore.saveSettings(settings)
    }

    private func loadRulesText() {
        saveSettings()
        AgentGlobalRulesStore.ensureDefaultRulesFileIfNeeded(settings: settings)
        let url = AgentGlobalRulesStore.resolvedURL(for: settings.filePath)
        rulesText = AgentGlobalRulesStore.readRulesFileText(at: url) ?? ""
        statusMessage = rulesText.isEmpty
            ? L10n.Settings.GlobalRules.noFileStatus(AgentGlobalRulesStore.displayPath(for: url))
            : L10n.Settings.GlobalRules.loadedStatus(AgentGlobalRulesStore.displayPath(for: url))
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
