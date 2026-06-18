//
//  CollaborationConnectorSettingsView.swift
//  WillDeep
//
//  Settings tab for collaboration platform connectors.
//

import SwiftUI
import AppKit

struct CollaborationConnectorSettingsView: View {
    @State private var settings = CollaborationConnectorSettingsStore.load()
    @State private var selectedPlatform: CollaborationConnectorPlatform = .feishu
    @State private var statusMessage = L10n.Settings.allChangesSaved

    private var enabledCount: Int {
        settings.connectors.filter(\.isEnabled).count
    }

    private var selectedConnector: CollaborationConnectorConfig {
        settings.connector(for: selectedPlatform)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Settings.Connectors.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.Settings.Connectors.enabledCount("\(enabledCount)", "\(settings.connectors.count)"))
                        .font(.headline)
                }
            }

            Section {
                ForEach(settings.connectors) { connector in
                    connectorRow(connector)
                }
            } header: {
                Text(L10n.Settings.Connectors.platformsSection)
            }

            connectorDetailSection(selectedConnector)
            capabilitySection(selectedConnector)
            safetySection(selectedConnector)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .onReceive(NotificationCenter.default.publisher(for: CollaborationConnectorSettingsStore.didChangeNotification)) { _ in
            settings = CollaborationConnectorSettingsStore.load()
        }
    }

    private func connectorRow(_ connector: CollaborationConnectorConfig) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: connector.platform.systemImageName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(connector.platform.tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(connector.platform.displayName)
                        .font(.headline)
                    if connector.platform.isExperimental {
                        Text(L10n.Settings.Connectors.experimentalBadge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                    }
                }
                Text(connector.platform.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusLine(for: connector))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPlatform = connector.platform
            }

            Spacer()

            Toggle(L10n.Settings.Connectors.enabledToggle, isOn: Binding(
                get: { connector.isEnabled },
                set: { enabled in
                    update(connector) { draft in
                        draft.isEnabled = enabled
                        draft.updatedAt = Date()
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedPlatform == connector.platform ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }

    private func connectorDetailSection(_ connector: CollaborationConnectorConfig) -> some View {
        Section {
            Picker(L10n.Settings.Connectors.authModeLabel, selection: binding(for: connector, \.authMode)) {
                ForEach(CollaborationConnectorAuthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Text(connector.authMode.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L10n.Settings.Connectors.connectionStateLabel, selection: binding(for: connector, \.connectionState)) {
                ForEach(CollaborationConnectorConnectionState.allCases) { state in
                    Text(state.displayName).tag(state)
                }
            }

            LabeledContent(L10n.Settings.Connectors.appIDLabel) {
                TextField("", text: binding(for: connector, \.appID), prompt: Text(L10n.Settings.Connectors.appIDPrompt))
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.Connectors.tenantIDLabel) {
                TextField("", text: binding(for: connector, \.tenantID), prompt: Text(L10n.Settings.Connectors.tenantIDPrompt))
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.Connectors.redirectURILabel) {
                TextField("", text: binding(for: connector, \.redirectURI), prompt: Text(L10n.Settings.Connectors.redirectURIPrompt))
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.Connectors.authorizationURLLabel) {
                TextField("", text: optionalBinding(for: connector, \.authorizationURL), prompt: Text(L10n.Settings.Connectors.authorizationURLPrompt))
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.Connectors.credentialReferenceLabel) {
                TextField("", text: binding(for: connector, \.credentialReference), prompt: Text(L10n.Settings.Connectors.credentialReferencePrompt))
                    .textFieldStyle(.roundedBorder)
            }

            Text(L10n.Settings.Connectors.authorizationURLHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L10n.Settings.Connectors.secretStorageNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    prepareAuthorization(for: connector)
                } label: {
                    Label(L10n.Settings.Connectors.prepareAuthorization, systemImage: "person.badge.key")
                }

                Button {
                    copyRedirectURI(for: connector)
                } label: {
                    Label(L10n.Settings.Connectors.copyRedirectURI, systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    clearCredentials(for: connector)
                } label: {
                    Label(L10n.Settings.Connectors.clearCredentials, systemImage: "key.slash")
                }

                if let docsURL = connector.platform.documentationURL {
                    Button {
                        NSWorkspace.shared.open(docsURL)
                    } label: {
                        Label(L10n.Settings.Connectors.openDocs, systemImage: "safari")
                    }
                }

                Spacer()
            }
        } header: {
            Text(L10n.Settings.Connectors.configurationSection(connector.platform.displayName))
        }
    }

    private func optionalBinding(
        for connector: CollaborationConnectorConfig,
        _ keyPath: WritableKeyPath<CollaborationConnectorConfig, String?>
    ) -> Binding<String> {
        Binding {
            settings.connector(for: connector.platform)[keyPath: keyPath] ?? ""
        } set: { newValue in
            update(connector) { draft in
                draft[keyPath: keyPath] = newValue
                draft.updatedAt = Date()
            }
        }
    }

    private func capabilitySection(_ connector: CollaborationConnectorConfig) -> some View {
        Section {
            LabeledContent(L10n.Settings.Connectors.defaultSpaceLabel) {
                TextField("", text: binding(for: connector, \.defaultSpace), prompt: Text(L10n.Settings.Connectors.defaultSpacePrompt))
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent(L10n.Settings.Connectors.defaultChatLabel) {
                TextField("", text: binding(for: connector, \.defaultChat), prompt: Text(L10n.Settings.Connectors.defaultChatPrompt))
                    .textFieldStyle(.roundedBorder)
            }

            ForEach(CollaborationConnectorCapability.allCases.filter { $0.isSupported(by: connector.platform) }) { capability in
                Toggle(capability.displayName, isOn: capabilityBinding(for: connector, capability: capability))
            }
        } header: {
            Text(L10n.Settings.Connectors.capabilitiesSection)
        }
    }

    private func safetySection(_ connector: CollaborationConnectorConfig) -> some View {
        Section {
            Picker(L10n.Settings.Connectors.writePolicyLabel, selection: binding(for: connector, \.writePolicy)) {
                ForEach(CollaborationConnectorWritePolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }

            Toggle(L10n.Settings.Connectors.cloudRelayToggle, isOn: binding(for: connector, \.cloudRelayEnabled))

            Text(L10n.Settings.Connectors.cloudRelayDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if connector.platform == .feishu {
                Text(L10n.Settings.Connectors.feishuDocsNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Settings.Connectors.safetySection)
        }
    }

    private func binding<Value>(
        for connector: CollaborationConnectorConfig,
        _ keyPath: WritableKeyPath<CollaborationConnectorConfig, Value>
    ) -> Binding<Value> {
        Binding {
            settings.connector(for: connector.platform)[keyPath: keyPath]
        } set: { newValue in
            update(connector) { draft in
                draft[keyPath: keyPath] = newValue
                draft.updatedAt = Date()
            }
        }
    }

    private func capabilityBinding(
        for connector: CollaborationConnectorConfig,
        capability: CollaborationConnectorCapability
    ) -> Binding<Bool> {
        Binding {
            settings.connector(for: connector.platform).enabledCapabilities.contains(capability)
        } set: { isEnabled in
            update(connector) { draft in
                var capabilities = Set(draft.enabledCapabilities)
                if isEnabled {
                    capabilities.insert(capability)
                } else {
                    capabilities.remove(capability)
                }
                draft.enabledCapabilities = CollaborationConnectorCapability.allCases.filter {
                    capabilities.contains($0)
                }
                draft.updatedAt = Date()
            }
        }
    }

    private func update(
        _ connector: CollaborationConnectorConfig,
        mutate: (inout CollaborationConnectorConfig) -> Void
    ) {
        var draft = settings.connector(for: connector.platform)
        mutate(&draft)
        CollaborationConnectorSettingsStore.upsert(draft)
        settings = CollaborationConnectorSettingsStore.load()
        statusMessage = L10n.Settings.allChangesSaved
    }

    private func prepareAuthorization(for connector: CollaborationConnectorConfig) {
        let request = CollaborationConnectorOAuthCoordinator.prepareAuthorization(for: connector)
        CollaborationConnectorSettingsStore.upsert(request.connector)
        settings = CollaborationConnectorSettingsStore.load()

        guard !request.connector.appID.isEmpty else {
            statusMessage = L10n.Settings.Connectors.authorizationNeedsAppID(connector.platform.displayName)
            return
        }

        if let authorizationURL = request.authorizationURL {
            NSWorkspace.shared.open(authorizationURL)
            statusMessage = L10n.Settings.Connectors.authorizationOpened(connector.platform.displayName)
        } else {
            statusMessage = L10n.Settings.Connectors.authorizationPrepared(connector.platform.displayName)
        }
    }

    private func copyRedirectURI(for connector: CollaborationConnectorConfig) {
        let value = connector.redirectURI.isEmpty
            ? CollaborationConnectorOAuthCoordinator.defaultRedirectURI(for: connector.platform)
            : connector.redirectURI
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        update(connector) { draft in
            if draft.redirectURI.isEmpty {
                draft.redirectURI = value
            }
            draft.updatedAt = Date()
        }
        statusMessage = L10n.Settings.Connectors.redirectURICopied(connector.platform.displayName)
    }

    private func clearCredentials(for connector: CollaborationConnectorConfig) {
        CollaborationConnectorOAuthCoordinator.clearCredentials(for: connector.platform)
        update(connector) { draft in
            draft.connectionState = .notConfigured
            draft.credentialReference = CollaborationConnectorOAuthCoordinator.credentialReference(
                platform: draft.platform,
                kind: .clientSecret
            )
            draft.updatedAt = Date()
        }
        statusMessage = L10n.Settings.Connectors.credentialsCleared(connector.platform.displayName)
    }

    private func statusLine(for connector: CollaborationConnectorConfig) -> String {
        L10n.Settings.Connectors.statusLine(
            connector.connectionState.displayName,
            connector.authMode.displayName,
            "\(connector.enabledCapabilities.count)"
        )
    }
}
