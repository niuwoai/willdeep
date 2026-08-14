//
//  AgentSecretSettingsView.swift
//  WillDeep
//
//  Settings → Agent tools → Secrets. Same list the Composer's lock button
//  shows, plus the ability to add secrets without going through a chat.
//

import SwiftUI

struct AgentSecretSettingsView: View {
    @State private var isAddPresented = false
    @State private var rows: [AgentSecretInput] = [AgentSecretInput(label: "", secret: "")]
    /// Bumped after a save so the list view re-runs its `onAppear` reload.
    @State private var reloadToken = UUID()

    var body: some View {
        Form {
            Section(L10n.SecretManager.paneTitle) {
                Text(L10n.SecretManager.paneDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                AgentSecretManagerView(mode: .manage, maxListHeight: 320)
                    .id(reloadToken)

                HStack {
                    Spacer()
                    Button {
                        rows = [AgentSecretInput(label: "", secret: "")]
                        isAddPresented = true
                    } label: {
                        Label(L10n.SecretManager.addAction, systemImage: "plus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isAddPresented) {
            addSheet
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text(L10n.SecretManager.addTitle)
                    .font(.headline)
            }

            Text(L10n.Composer.secretAliasRule)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AgentSecretRowsEditor(rows: $rows)

            HStack {
                Spacer()
                Button(L10n.Automation.cancel) {
                    isAddPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.SecretManager.saveAction) {
                    _ = AgentSecretStore.saveSecrets(rows)
                    isAddPresented = false
                    reloadToken = UUID()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    AgentSecretRowValidation.validCount(rows) == 0
                        || AgentSecretRowValidation.hasIncompleteRow(rows)
                )
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
