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
    @State private var authorizationRequest: CollaborationConnectorOAuthRequest?
    @State private var larkCLIAuthorizationURL: URL?
    @State private var larkCLIIsWorking = false
    @AppStorage("com.willdeep.connectors.showAdvancedConfiguration") private var showAdvancedConfiguration = false

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
                ForEach(authModes(for: connector)) { mode in
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

            if connector.platform == .feishu {
                feishuAuthorizationSection(connector)
            } else if connector.platform == .dingtalk && connector.authMode == .officialMCP {
                dingtalkMCPSection(connector)
            } else {
                standardOAuthFields(connector)
            }
        } header: {
            Text(L10n.Settings.Connectors.configurationSection(connector.platform.displayName))
        }
    }

    private func feishuAuthorizationSection(_ connector: CollaborationConnectorConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(connector.authMode == .officialLarkCLI
                ? L10n.Settings.Connectors.larkCLIHelp
                : L10n.Settings.Connectors.feishuQRCodeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                if let authorizationURL = currentAuthorizationURL(for: connector) {
                    SettingsQRCodeView(
                        text: authorizationURL.absoluteString,
                        accessibilityLabel: L10n.Settings.Connectors.feishuQRCodeAccessibilityLabel,
                        unavailableText: L10n.Settings.Connectors.feishuQRCodeUnavailable,
                        pointSize: 172
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.Settings.Connectors.feishuQRCodeReady)
                            .font(.headline)
                        Text(authorizationURL.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                } else {
                    ConnectorUnavailablePlaceholder(
                        title: L10n.Settings.Connectors.feishuQRCodePlaceholderTitle,
                        systemImage: "qrcode",
                        description: L10n.Settings.Connectors.feishuQRCodePlaceholderDescription
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                if connector.authMode == .officialLarkCLI {
                    Button {
                        startLarkCLIConfig(for: connector)
                    } label: {
                        Label(L10n.Settings.Connectors.larkCLIConfigureApp, systemImage: "sparkles")
                    }
                    .disabled(larkCLIIsWorking)

                    Button {
                        startLarkCLILogin(for: connector)
                    } label: {
                        Label(L10n.Settings.Connectors.larkCLILogin, systemImage: "person.badge.key")
                    }
                    .disabled(larkCLIIsWorking)
                }

                if connector.authMode != .officialLarkCLI {
                    Button {
                        prepareAuthorization(for: connector, openInBrowser: false)
                    } label: {
                        Label(L10n.Settings.Connectors.generateQRCode, systemImage: "qrcode")
                    }

                    Button {
                        prepareAuthorization(for: connector, openInBrowser: true)
                    } label: {
                        Label(L10n.Settings.Connectors.openAuthorization, systemImage: "safari")
                    }
                }

                if let authorizationURL = currentAuthorizationURL(for: connector) {
                    Button {
                        copyAuthorizationURL(authorizationURL, for: connector)
                    } label: {
                        Label(L10n.Settings.Connectors.copyAuthorizationURL, systemImage: "doc.on.doc")
                    }
                }

                Spacer()
            }

            if connector.authMode == .officialLarkCLI {
                larkCLISection(connector)
            }

            DisclosureGroup(isExpanded: $showAdvancedConfiguration) {
                advancedConfigurationFields(connector)
                    .padding(.top, 6)
            } label: {
                Label(L10n.Settings.Connectors.advancedConfiguration, systemImage: "slider.horizontal.3")
            }
        }
        .onAppear {
            ensureFeishuAuthorizationRequest(for: connector)
        }
        .onChange(of: connector.appID) { _ in
            ensureFeishuAuthorizationRequest(for: settings.connector(for: connector.platform))
        }
    }

    private func larkCLISection(_ connector: CollaborationConnectorConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Connectors.larkCLIHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    installLarkCLI(for: connector)
                } label: {
                    Label(L10n.Settings.Connectors.larkCLIInstall, systemImage: "arrow.down.circle")
                }
                .disabled(larkCLIIsWorking)

                Button {
                    verifyLarkCLIStatus(for: connector)
                } label: {
                    Label(L10n.Settings.Connectors.larkCLIVerify, systemImage: "checkmark.seal")
                }
                .disabled(larkCLIIsWorking)

                if let executable = AgentLarkCLI.executablePath() {
                    Text(L10n.Settings.Connectors.larkCLIInstalled(executable))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(L10n.Settings.Connectors.larkCLINotInstalled)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(.top, 2)
    }

    private func dingtalkMCPSection(_ connector: CollaborationConnectorConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Settings.Connectors.dingtalkMCPHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    openDingTalkMCPDraft(for: connector)
                } label: {
                    Label(L10n.Settings.Connectors.dingtalkMCPConfigure, systemImage: "server.rack")
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

            DisclosureGroup(isExpanded: $showAdvancedConfiguration) {
                standardOAuthFields(connector)
                    .padding(.top, 6)
            } label: {
                Label(L10n.Settings.Connectors.advancedConfiguration, systemImage: "slider.horizontal.3")
            }
        }
    }

    private func standardOAuthFields(_ connector: CollaborationConnectorConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(L10n.Settings.Connectors.appIDLabel) {
                TextField("", text: binding(for: connector, \.appID), prompt: Text(L10n.Settings.Connectors.appIDPrompt))
                    .textFieldStyle(.roundedBorder)
            }

            advancedConfigurationFields(connector)

            HStack {
                Button {
                    prepareAuthorization(for: connector, openInBrowser: true)
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
        }
    }

    private func advancedConfigurationFields(_ connector: CollaborationConnectorConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if connector.platform == .feishu {
                LabeledContent(L10n.Settings.Connectors.appIDLabel) {
                    TextField("", text: binding(for: connector, \.appID), prompt: Text(L10n.Settings.Connectors.appIDPrompt))
                        .textFieldStyle(.roundedBorder)
                }
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

            if connector.platform == .feishu {
                HStack {
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
            }
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

    private func authModes(for connector: CollaborationConnectorConfig) -> [CollaborationConnectorAuthMode] {
        CollaborationConnectorAuthMode.allCases.filter { mode in
            switch mode {
            case .officialLarkCLI:
                return connector.platform == .feishu
            case .officialMCP:
                return connector.platform == .dingtalk
            default:
                return true
            }
        }
    }

    private func prepareAuthorization(
        for connector: CollaborationConnectorConfig,
        openInBrowser: Bool,
        updateStatus: Bool = true
    ) {
        let request = CollaborationConnectorOAuthCoordinator.prepareAuthorization(for: connector)
        authorizationRequest = request
        CollaborationConnectorSettingsStore.upsert(request.connector)
        settings = CollaborationConnectorSettingsStore.load()

        guard request.authorizationURL != nil || !request.connector.appID.isEmpty else {
            statusMessage = L10n.Settings.Connectors.authorizationNeedsAppID(connector.platform.displayName)
            return
        }

        if let authorizationURL = request.authorizationURL {
            if openInBrowser {
                NSWorkspace.shared.open(authorizationURL)
                statusMessage = L10n.Settings.Connectors.authorizationOpened(connector.platform.displayName)
            } else if updateStatus {
                statusMessage = L10n.Settings.Connectors.authorizationQRCodeReady(connector.platform.displayName)
            }
        } else if updateStatus {
            statusMessage = L10n.Settings.Connectors.authorizationPrepared(connector.platform.displayName)
        }
    }

    private func ensureFeishuAuthorizationRequest(for connector: CollaborationConnectorConfig) {
        guard connector.platform == .feishu,
              connector.authMode != .officialLarkCLI,
              currentAuthorizationURL(for: connector) == nil else {
            return
        }
        prepareAuthorization(for: connector, openInBrowser: false, updateStatus: false)
    }

    private func currentAuthorizationURL(for connector: CollaborationConnectorConfig) -> URL? {
        if connector.platform == .feishu,
           connector.authMode == .officialLarkCLI,
           let larkCLIAuthorizationURL {
            return larkCLIAuthorizationURL
        }
        if connector.platform == .feishu,
           connector.authMode == .officialLarkCLI,
           let raw = connector.authorizationURL,
           let url = URL(string: raw) {
            return url
        }
        guard let request = authorizationRequest,
              request.connector.platform == connector.platform,
              request.connector.appID == connector.appID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return request.authorizationURL
    }

    private func copyAuthorizationURL(_ url: URL, for connector: CollaborationConnectorConfig) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        statusMessage = L10n.Settings.Connectors.authorizationURLCopied(connector.platform.displayName)
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

    private func installLarkCLI(for connector: CollaborationConnectorConfig) {
        guard !larkCLIIsWorking else { return }
        larkCLIIsWorking = true
        statusMessage = L10n.Settings.Connectors.larkCLIInstalling
        Task {
            let result = await AgentLarkCLI.installOfficialCLI()
            await MainActor.run {
                larkCLIIsWorking = false
                if result.isSuccess {
                    update(connector) { draft in
                        draft.authMode = .officialLarkCLI
                        draft.connectionState = .ready
                    }
                    statusMessage = L10n.Settings.Connectors.larkCLIInstallSucceeded
                } else {
                    statusMessage = L10n.Settings.Connectors.larkCLICommandFailed(shortProcessOutput(result))
                }
            }
        }
    }

    private func startLarkCLIConfig(for connector: CollaborationConnectorConfig) {
        runLarkCLIInteractiveCommand(
            for: connector,
            arguments: ["config", "init", "--new"],
            startedMessage: L10n.Settings.Connectors.larkCLIConfigStarted,
            successMessage: L10n.Settings.Connectors.larkCLIConfigFinished,
            markConnected: false
        )
    }

    private func startLarkCLILogin(for connector: CollaborationConnectorConfig) {
        runLarkCLIInteractiveCommand(
            for: connector,
            arguments: ["auth", "login", "--recommend", "--no-wait"],
            startedMessage: L10n.Settings.Connectors.larkCLILoginStarted,
            successMessage: L10n.Settings.Connectors.larkCLILoginFinished,
            markConnected: false
        )
    }

    private func verifyLarkCLIStatus(for connector: CollaborationConnectorConfig) {
        runLarkCLIInteractiveCommand(
            for: connector,
            arguments: ["auth", "status"],
            startedMessage: L10n.Settings.Connectors.larkCLIVerifying,
            successMessage: L10n.Settings.Connectors.larkCLIVerified,
            markConnected: true
        )
    }

    private func openDingTalkMCPDraft(for connector: CollaborationConnectorConfig) {
        update(connector) { draft in
            draft.authMode = .officialMCP
            if draft.connectionState == .notConfigured {
                draft.connectionState = .ready
            }
        }
        AgentMCPServerCreationCoordinator.shared.open(with: AgentLearningMCPDraft(
            capability: L10n.Settings.Connectors.dingtalkMCPCapability,
            serverName: "dingtalk",
            installHint: L10n.Settings.Connectors.dingtalkMCPInstallHint,
            searchQuery: "open-dingtalk dingtalk-mcp",
            transport: .stdio,
            command: "npx",
            args: ["-y", "dingtalk-mcp@latest"],
            env: [
                "DINGTALK_Client_ID": connector.appID,
                "DINGTALK_Client_Secret": ""
            ],
            url: nil,
            headers: nil,
            startupTimeout: 60,
            reason: L10n.Settings.Connectors.dingtalkMCPReason
        ))
        statusMessage = L10n.Settings.Connectors.dingtalkMCPDraftOpened
    }

    private func runLarkCLIInteractiveCommand(
        for connector: CollaborationConnectorConfig,
        arguments: [String],
        startedMessage: String,
        successMessage: String,
        markConnected: Bool
    ) {
        guard !larkCLIIsWorking else { return }
        guard let executable = AgentLarkCLI.executablePath() else {
            statusMessage = L10n.Settings.Connectors.larkCLINotInstalled
            return
        }
        larkCLIIsWorking = true
        statusMessage = startedMessage
        Task {
            let result = await AgentLarkCLI.runCapture(
                executable: executable,
                arguments: arguments,
                timeout: arguments == ["auth", "status"] ? 20 : 10
            )
            let url = AgentLarkCLI.firstURL(in: result.combinedOutput)
            await MainActor.run {
                larkCLIIsWorking = false
                if let url {
                    larkCLIAuthorizationURL = url
                    update(connector) { draft in
                        draft.authMode = .officialLarkCLI
                        draft.authorizationURL = url.absoluteString
                        draft.connectionState = .ready
                    }
                    statusMessage = L10n.Settings.Connectors.larkCLIQRCodeReady
                    return
                }
                if result.isSuccess || result.timedOut {
                    update(connector) { draft in
                        draft.authMode = .officialLarkCLI
                        if markConnected {
                            draft.connectionState = .connected
                        } else if draft.connectionState == .notConfigured {
                            draft.connectionState = .ready
                        }
                    }
                    statusMessage = successMessage
                } else {
                    statusMessage = L10n.Settings.Connectors.larkCLICommandFailed(shortProcessOutput(result))
                }
            }
        }
    }

    private func shortProcessOutput(_ result: AgentLarkCLI.ProcessResult) -> String {
        let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return "exit=\(result.exitStatus)"
        }
        return output.count > 180 ? String(output.prefix(180)) + "..." : output
    }
}

private struct ConnectorUnavailablePlaceholder: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}
