//
//  EditorSettingsView.swift
//  WillDeep
//
//  Preferences UI for editor appearance.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EditorSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var cliInstallState: CommandLineToolInstallState = .notInstalled
    @State private var cliStatusMessage = ""
    @State private var isInstallingCLI = false
    @State private var fetchedAgentModels: [String] = []
    @State private var isFetchingAgentModels = false
    @State private var agentModelFetchMessage = ""
    @State private var fetchedImageModels: [String] = []
    @State private var isFetchingImageModels = false
    @State private var imageModelFetchMessage = ""

    // Local buffers for the Agent settings text fields. The previous
    // implementation bound directly to `appState.agentConfiguration`,
    // which sent every keystroke through the @Published didSet →
    // Keychain → normalize round-trip. Under macOS 26 SwiftUI that loop
    // sometimes clears the SecureField mid-type. Keeping the in-flight
    // text local means typing is purely a @State mutation; an explicit
    // Save button is the only commit point.
    @State private var agentBaseURLBuffer: String = ""
    @State private var agentModelBuffer: String = ""
    @State private var agentFlashModelBuffer: String = ""
    @State private var agentProModelBuffer: String = ""
    @State private var agentRoutingModeBuffer: AgentModelRoutingMode = .auto
    @State private var agentAPIKeyBuffer: String = ""
    @State private var imageProviderIDBuffer: String = ""
    @State private var imageBaseURLBuffer: String = ""
    @State private var imageModelBuffer: String = ""
    @State private var imageAPIKeyBuffer: String = ""
    /// Optional dedicated model name used solely for the
    /// "summarize this chat into a short title" call. Empty buffer ⇒
    /// the resolver falls back to the active flash model. See
    /// AgentConfiguration.titleSummaryModel() and
    /// AppStateAgentTitleSummarizer.
    @State private var agentTitleModelBuffer: String = ""
    @State private var agentSaveStatus: String = ""
    // Brave Search key for the built-in web_search tool. Saved/loaded
    // straight through AgentSettingsStore (Keychain) — it has no slot
    // in AgentConfiguration, so it stays out of commitAgentBuffers.
    @State private var braveSearchAPIKeyBuffer: String = ""
    @State private var braveSearchAPIKeySaved: String = ""
    @State private var braveSearchSaveStatus: String = ""
    @State private var discoveredLocalAgents: [LocalAgentCLI.Discovery] = LocalAgentCLI.discoverAll()

    var body: some View {
        TabView {
            typographySettings
                .tabItem {
                    Label(L10n.Settings.tabTypography, systemImage: "textformat")
                }

            appearanceSettings
                .tabItem {
                    Label(L10n.Settings.tabAppearance, systemImage: "slider.horizontal.3")
                }

            workspaceSettings
                .tabItem {
                    Label(L10n.Settings.tabWorkspace, systemImage: "sidebar.left")
                }

            agentSettings
                .tabItem {
                    Label(L10n.Settings.tabAgent, systemImage: "sparkles")
                }

            localAgentSettings
                .tabItem {
                    Label(L10n.Settings.tabLocalAgents, systemImage: "cpu")
                }

            AgentRuntimeSettingsView()
                .tabItem {
                    Label(L10n.Settings.tabRemoteRuntimes, systemImage: "network")
                }

            MobileGatewaySettingsView()
                .tabItem {
                    Label(L10n.Settings.tabMobileGateway, systemImage: "iphone.radiowaves.left.and.right")
                }

            AgentMemorySettingsView()
                .tabItem {
                    Label(L10n.Settings.tabMemory, systemImage: "brain.head.profile")
                }

            AgentGlobalRulesSettingsView()
                .tabItem {
                    Label(L10n.Settings.tabRules, systemImage: "doc.text.magnifyingglass")
                }

            AgentSkillSettingsView()
                .tabItem {
                    Label(L10n.Settings.tabSkills, systemImage: "wand.and.stars")
                }

            AgentMCPSettingsView()
                .tabItem {
                    Label(L10n.Settings.tabMcp, systemImage: "globe")
                }

            toolsSettings
                .tabItem {
                    Label(L10n.Settings.tabTools, systemImage: "terminal")
                }
        }
        .padding(20)
        .frame(
            minWidth: 560,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .background(SettingsKeyboardShortcutHandler())
        .background(SettingsWindowResizableEnforcer())
        .onAppear {
            refreshCLIState()
            refreshLocalAgentDiscovery()
        }
    }

    private var typographySettings: some View {
        Form {
            Section(L10n.Settings.sectionEditorText) {
                Picker(L10n.Settings.labelFont, selection: setting(\.fontID)) {
                    ForEach(EditorFontChoice.allCases) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }

                HStack {
                    Slider(value: setting(\.fontSize), in: 10...28, step: 1)
                    Text("\(Int(appState.editorSettings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Slider(value: setting(\.lineHeightMultiple), in: 1.0...1.8, step: 0.05)
                    Text(String(format: "%.2fx", appState.editorSettings.lineHeightMultiple))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Section(L10n.Settings.sectionWorkspaceText) {
                LabeledContent(L10n.Settings.labelTextSize) {
                    HStack {
                        Slider(value: setting(\.fileTreeFontSize), in: 10...16, step: 1)
                        Text("\(Int(appState.editorSettings.fileTreeFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent(L10n.Settings.labelLineHeight) {
                    HStack {
                        Slider(value: setting(\.fileTreeLineHeightMultiple), in: 1.0...2.0, step: 0.05)
                        Text(String(format: "%.2fx", appState.editorSettings.fileTreeLineHeightMultiple))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
            editorFormatSections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var editorFormatSections: some View {
        Section(L10n.Settings.sectionColorStyle) {
            Picker(L10n.Settings.labelTheme, selection: setting(\.themeID)) {
                ForEach(EditorTheme.all) { theme in
                    Text(theme.displayName).tag(theme.id)
                }
            }

            HStack(spacing: 8) {
                ForEach(EditorTheme.all) { theme in
                    Button {
                        update(\.themeID, theme.id)
                    } label: {
                        ThemeSwatch(theme: theme)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.displayName)
                }
            }
            .padding(.vertical, 4)
        }

        Section(L10n.Settings.sectionEditorBackground) {
            LabeledContent(L10n.Settings.labelImage) {
                HStack {
                    Text(backgroundImageLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(appState.editorSettings.windowBackgroundImagePath == nil ? .secondary : .primary)
                    Spacer(minLength: 8)
                    Button(L10n.Settings.buttonChoose) {
                        chooseBackgroundImage()
                    }
                    Button(L10n.Settings.buttonClear) {
                        update(\.windowBackgroundImagePath, nil)
                    }
                    .disabled(appState.editorSettings.windowBackgroundImagePath == nil)
                }
            }

            Picker(L10n.Settings.labelImageMode, selection: setting(\.windowBackgroundImageMode)) {
                ForEach(EditorBackgroundImageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(appState.editorSettings.windowBackgroundImagePath == nil)

            LabeledContent(L10n.Settings.labelImageSize) {
                HStack {
                    Slider(value: setting(\.windowBackgroundImageScale), in: 0.25...3, step: 0.05)
                    Text("\(Int(appState.editorSettings.windowBackgroundImageScale * 100))%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .disabled(appState.editorSettings.windowBackgroundImagePath == nil)

            LabeledContent(L10n.Settings.labelImageOpacity) {
                HStack {
                    Slider(value: setting(\.windowBackgroundImageOpacity), in: 0...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.windowBackgroundImageOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }

        Section(L10n.Settings.sectionEditor) {
            Toggle(L10n.Settings.toggleShowLineNumbers, isOn: setting(\.showsLineNumbers))
            Toggle(L10n.Settings.toggleHighlightCurrentLine, isOn: setting(\.highlightsCurrentLine))
            Toggle(L10n.Settings.toggleGlassEditorBackground, isOn: setting(\.editorGlassEnabled))

            Picker(L10n.Settings.labelGlassMaterial, selection: setting(\.editorGlassMaterial)) {
                ForEach(EditorGlassMaterial.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }
            .disabled(!appState.editorSettings.editorGlassEnabled)

            LabeledContent(L10n.Settings.labelGlassStrength) {
                HStack {
                    Slider(value: setting(\.editorGlassOpacity), in: 0...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.editorGlassOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!appState.editorSettings.editorGlassEnabled)

            LabeledContent(L10n.Settings.labelEditorSurface) {
                HStack {
                    Slider(value: setting(\.editorSurfaceOpacity), in: 0.25...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.editorSurfaceOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!appState.editorSettings.editorGlassEnabled)
        }
    }

    private var workspaceSettings: some View {
        Form {
            Section(L10n.Settings.sectionInspector) {
                Picker(L10n.Settings.labelDefaultView, selection: setting(\.preferredInspectorMode)) {
                    ForEach(EditorInspectorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker(L10n.Settings.labelViewOrder, selection: setting(\.inspectorPanelOrder)) {
                    ForEach(EditorInspectorPanelOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
            }

            Section(L10n.Settings.sectionSave) {
                Toggle(L10n.Settings.toggleTrimTrailingWhitespace, isOn: setting(\.trimsTrailingWhitespaceOnSave))
                Toggle(L10n.Settings.toggleEnsureFinalNewline, isOn: setting(\.ensuresFinalNewlineOnSave))
            }
        }
        .formStyle(.grouped)
    }

    private var agentSettings: some View {
        Form {
            Section(L10n.Settings.sectionAgentProviders) {
                AgentProviderLibrarySection(
                    fetchedAgentModels: $fetchedAgentModels,
                    isFetchingAgentModels: $isFetchingAgentModels,
                    agentModelFetchMessage: $agentModelFetchMessage,
                    onFetchModels: { entry in
                        fetchAgentModels(forEntry: entry)
                    }
                )
            }

            Section(L10n.Settings.sectionImageUnderstanding) {
                Picker(L10n.Settings.ImageUnderstanding.providerLabel, selection: imageProviderBinding) {
                    ForEach(AgentProviderPreset.all.filter(\.supportsImageInput)) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }

                LabeledContent(L10n.Settings.ImageUnderstanding.baseURLLabel) {
                    TextField("", text: $imageBaseURLBuffer)
                        .textFieldStyle(.roundedBorder)
                }

                agentModelField(L10n.Settings.ImageUnderstanding.visionModelLabel, text: $imageModelBuffer, models: fetchedImageModels)

                LabeledContent(L10n.Settings.ImageUnderstanding.apiKeyLabel) {
                    // No in-field placeholder: in a grouped Form the
                    // LabeledContent label on the left already names the
                    // field, and a trailing "sk-..." inside an empty
                    // SecureField looks like a stray value sitting next
                    // to the reveal button.
                    RevealableSecretField(
                        text: $imageAPIKeyBuffer,
                        placeholder: "",
                        onCommit: {}
                    )
                }

                Text(L10n.Settings.ImageUnderstanding.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(L10n.Settings.buttonSave) {
                        commitAgentBuffers()
                    }
                    .disabled(!agentBuffersDiffer)
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button(L10n.Settings.buttonRevert) {
                        loadAgentBuffersFromAppState()
                        agentSaveStatus = ""
                    }
                    .disabled(!agentBuffersDiffer)

                    Button(isFetchingAgentModels ? L10n.Settings.ImageUnderstanding.fetchingModels : L10n.Settings.ImageUnderstanding.fetchModels) {
                        fetchAgentModels()
                    }
                    .disabled(isFetchingAgentModels)

                    Button(isFetchingImageModels ? L10n.Settings.ImageUnderstanding.fetchingImages : L10n.Settings.ImageUnderstanding.fetchImageModels) {
                        fetchImageModels()
                    }
                    .disabled(isFetchingImageModels)

                    if !agentSaveStatus.isEmpty {
                        Text(agentSaveStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if !agentModelFetchMessage.isEmpty {
                        Text(agentModelFetchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if !imageModelFetchMessage.isEmpty {
                        Text(imageModelFetchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text(L10n.Settings.AgentBehavior.saveBehaviorNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionConversationTitle) {
                LabeledContent(L10n.Settings.AgentBehavior.titleModelLabel) {
                    TextField("", text: $agentTitleModelBuffer, prompt: Text(L10n.Settings.AgentBehavior.titleModelPlaceholder))
                        .textFieldStyle(.roundedBorder)
                }
                Text(L10n.Settings.AgentBehavior.titleModelDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionToolApproval) {
                Toggle(L10n.Settings.toggleAutoApproveSafe, isOn: Binding(
                    get: { appState.autoApproveSafeCommands },
                    set: { appState.autoApproveSafeCommands = $0 }
                ))
                Text(L10n.Settings.AgentBehavior.toolApprovalDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionWebTools) {
                LabeledContent(L10n.Settings.WebTools.braveKeyLabel) {
                    RevealableSecretField(
                        text: $braveSearchAPIKeyBuffer,
                        placeholder: "",
                        onCommit: { commitBraveSearchAPIKey() }
                    )
                }
                HStack {
                    Button(L10n.Settings.buttonSave) {
                        commitBraveSearchAPIKey()
                    }
                    .disabled(braveSearchAPIKeyBuffer == braveSearchAPIKeySaved)

                    if !braveSearchSaveStatus.isEmpty {
                        Text(braveSearchSaveStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.Settings.WebTools.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionConcurrency) {
                HStack {
                    Text(L10n.Settings.perProviderConcurrency)
                    Spacer()
                    Text("\(appState.perProviderConcurrencyLimit)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(appState.perProviderConcurrencyLimit) },
                        set: { appState.perProviderConcurrencyLimit = Int($0.rounded()) }
                    ),
                    in: 1...8,
                    step: 1
                )
                Text(L10n.Settings.AgentBehavior.concurrencyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionAgentAppearance) {
                HStack {
                    Text(L10n.Settings.chatBaseFontSize)
                    Spacer()
                    Text("\(Int(appState.agentChatBaseFontSize.rounded())) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(appState.agentChatBaseFontSize) },
                        set: { appState.agentChatBaseFontSize = CGFloat($0.rounded()) }
                    ),
                    in: Double(AgentSettingsStore.chatBaseFontSizeMin)
                        ... Double(AgentSettingsStore.chatBaseFontSizeMax),
                    step: 1
                )
                Text(L10n.Settings.AgentBehavior.agentAppearanceDescription("\(Int(AgentSettingsStore.chatBaseFontSizeMin))", "\(Int(AgentSettingsStore.chatBaseFontSizeMax))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadAgentBuffersFromAppState()
        }
        .onChange(of: appState.agentConfiguration) { _, _ in
            // External writes (e.g. fetchModels picking a default) should
            // refresh the buffers — but only when they currently match
            // what we last saved, so the user's in-flight typing isn't
            // clobbered.
            if !agentBuffersDiffer {
                loadAgentBuffersFromAppState()
            }
        }
    }

    /// Save button now only covers the Image Understanding fields and
    /// routing mode — all the per-provider Agent fields are managed
    /// live by the new `AgentProviderLibrarySection`.
    private var agentBuffersDiffer: Bool {
        let configuration = appState.agentConfiguration
        return agentRoutingModeBuffer != configuration.routingMode
            || imageProviderIDBuffer != configuration.imageDescription.providerID
            || imageBaseURLBuffer != configuration.imageDescription.baseURL
            || imageModelBuffer != configuration.imageDescription.model
            || imageAPIKeyBuffer != configuration.imageDescription.apiKey
            || agentTitleModelBuffer != configuration.titleModel
    }

    private func loadAgentBuffersFromAppState() {
        let configuration = appState.agentConfiguration
        agentBaseURLBuffer = configuration.baseURL
        agentModelBuffer = configuration.model
        agentFlashModelBuffer = configuration.flashModel
        agentProModelBuffer = configuration.proModel
        agentRoutingModeBuffer = configuration.routingMode
        agentAPIKeyBuffer = configuration.apiKey
        imageProviderIDBuffer = configuration.imageDescription.providerID
        imageBaseURLBuffer = configuration.imageDescription.baseURL
        imageModelBuffer = configuration.imageDescription.model
        imageAPIKeyBuffer = configuration.imageDescription.apiKey
        agentTitleModelBuffer = configuration.titleModel
        braveSearchAPIKeySaved = AgentSettingsStore.loadBraveSearchAPIKey()
        braveSearchAPIKeyBuffer = braveSearchAPIKeySaved
    }

    private func commitBraveSearchAPIKey() {
        let trimmed = braveSearchAPIKeyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        AgentSettingsStore.saveBraveSearchAPIKey(trimmed)
        braveSearchAPIKeyBuffer = trimmed
        braveSearchAPIKeySaved = trimmed
        braveSearchSaveStatus = L10n.Settings.savedStatus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if braveSearchSaveStatus == L10n.Settings.savedStatus { braveSearchSaveStatus = "" }
        }
    }

    private func commitAgentBuffers() {
        var configuration = appState.agentConfiguration
        configuration.routingMode = agentRoutingModeBuffer
        configuration.imageDescription = AgentImageDescriptionConfiguration(
            providerID: imageProviderIDBuffer,
            baseURL: imageBaseURLBuffer,
            model: imageModelBuffer,
            apiKey: imageAPIKeyBuffer
        )
        configuration.titleModel = agentTitleModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.agentConfiguration = configuration.normalized
        loadAgentBuffersFromAppState()
        agentSaveStatus = L10n.Settings.savedStatus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if agentSaveStatus == L10n.Settings.savedStatus { agentSaveStatus = "" }
        }
    }

    private func agentModelField(_ title: String, text: Binding<String>, models: [String]) -> some View {
        // The TextField's first arg doubles as its in-field placeholder.
        // Passing `title` made the model name (e.g. "Vision Model") show
        // up *inside* the empty input AND as the LabeledContent label on
        // the right — visually duplicated. Use an empty placeholder so
        // only the LabeledContent label remains.
        LabeledContent(title) {
            HStack {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)

                if !models.isEmpty {
                    Picker(L10n.Settings.ImageUnderstanding.fetchedModelsLabel, selection: text) {
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
        }
    }

    private var toolsSettings: some View {
        Form {
            Section(L10n.Settings.sectionAgentAlwaysAllow) {
                if appState.agentAlwaysAllowedCommands.isEmpty {
                    Text(L10n.Settings.noAlwaysAllowed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.agentAlwaysAllowedCommands) { command in
                        HStack {
                            Label(command.commandSignature, systemImage: "checkmark.shield")
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button(L10n.Settings.Tools.removeButton) {
                                appState.removeAgentAlwaysAllowedCommand(id: command.id)
                            }
                        }
                    }

                    Button(L10n.Settings.Tools.clearAllButton) {
                        appState.clearAgentAlwaysAllowedCommands()
                    }
                    .foregroundStyle(.red)
                }

                Text(L10n.Settings.Tools.alwaysAllowNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.Tools.cliSection) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("willdeep")
                            .font(.headline)
                        Text(cliStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(cliButtonTitle) {
                        installCLI()
                    }
                    .disabled(isInstallingCLI)
                }

                if !cliStatusMessage.isEmpty {
                    Text(cliStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var localAgentSettings: some View {
        Form {
            Section(L10n.Settings.LocalAgents.discoveredSection) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.LocalAgents.summary(
                            "\(discoveredLocalAgents.filter(\.isInstalled).count)",
                            "\(discoveredLocalAgents.count)"
                        ))
                        .font(.headline)
                        Text(L10n.Settings.LocalAgents.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(L10n.Settings.LocalAgents.refreshButton) {
                        refreshLocalAgentDiscovery()
                    }
                }

                ForEach(discoveredLocalAgents) { discovery in
                    localAgentRow(discovery)
                }
            }

            Section(L10n.Settings.LocalAgents.integrationSection) {
                Text(L10n.Settings.LocalAgents.integrationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func localAgentRow(_ discovery: LocalAgentCLI.Discovery) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: discovery.isInstalled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(discovery.isInstalled ? .green : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(discovery.cli.displayName)
                        .font(.headline)
                    Text(discovery.cli.commandName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(discovery.path ?? L10n.Settings.LocalAgents.notFound)
                    .font(.caption)
                    .foregroundStyle(discovery.isInstalled ? .secondary : .tertiary)
                    .lineLimit(2)

                Text(localAgentIntegrationText(discovery))
                    .font(.caption)
                    .foregroundStyle(discovery.cli.integration.isDirectlyCallable ? .green : .secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func localAgentIntegrationText(_ discovery: LocalAgentCLI.Discovery) -> String {
        switch discovery.cli.integration {
        case .directTool(let toolName):
            return L10n.Settings.LocalAgents.directTool(toolName)
        case .discoveryOnly:
            return L10n.Settings.LocalAgents.discoveryOnly
        }
    }

    private var backgroundImageLabel: String {
        guard let path = appState.editorSettings.windowBackgroundImagePath else {
            return L10n.Settings.noImageSelected
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var cliStatusText: String {
        switch cliInstallState {
        case .installed:
            return L10n.Settings.Tools.installedAt(CommandLineToolInstaller.installURL.path)
        case .needsUpdate:
            return L10n.Settings.Tools.needsUpdateAt(CommandLineToolInstaller.installURL.path)
        case .notInstalled:
            return L10n.Settings.Tools.notInstalled
        }
    }

    private var cliButtonTitle: String {
        if isInstallingCLI {
            return L10n.Settings.Tools.installingButton
        }

        switch cliInstallState {
        case .installed:
            return L10n.Settings.Tools.reinstallButton
        case .needsUpdate:
            return L10n.Settings.Tools.updateButton
        case .notInstalled:
            return L10n.Settings.Tools.installButton
        }
    }

    private func refreshCLIState() {
        cliInstallState = CommandLineToolInstaller.installState()
    }

    private func refreshLocalAgentDiscovery() {
        discoveredLocalAgents = LocalAgentCLI.discoverAll()
    }

    private func installCLI() {
        isInstallingCLI = true
        cliStatusMessage = L10n.Settings.Tools.installingMessage

        Task.detached {
            let result: Result<Void, Error>
            do {
                try CommandLineToolInstaller.install()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isInstallingCLI = false
                refreshCLIState()
                switch result {
                case .success:
                    cliStatusMessage = L10n.Settings.Tools.installedMessage
                case .failure(let error):
                    cliStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = L10n.Settings.chooseBackgroundImageTitle
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            update(\.windowBackgroundImagePath, url.path)
        }
    }

    private func fetchAgentModels() {
        isFetchingAgentModels = true
        agentModelFetchMessage = ""
        let configuration = appState.agentConfiguration.normalized

        Task {
            let result: Result<[String], Error>
            do {
                let models = try await AgentClient(configuration: configuration).fetchModels()
                result = .success(models)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isFetchingAgentModels = false
                switch result {
                case .success(let models):
                    fetchedAgentModels = models
                    appState.recordFetchedAgentModels(models)
                    if models.isEmpty {
                        agentModelFetchMessage = "No models returned."
                    } else {
                        agentModelFetchMessage = "Fetched \(models.count) models."
                        if agentFlashModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = models.first {
                            agentFlashModelBuffer = firstModel
                        }
                        if agentProModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = models.first {
                            agentProModelBuffer = firstModel
                        }
                    }
                case .failure(let error):
                    fetchedAgentModels = []
                    agentModelFetchMessage = error.localizedDescription
                }
            }
        }
    }

    /// Fetch /models from a specific library entry (as opposed to the
    /// currently active configuration). Used by the multi-provider
    /// section so each row can pull its own model list independently
    /// of which entry is currently active in the chat.
    private func fetchAgentModels(forEntry entry: AgentProviderEntry) {
        isFetchingAgentModels = true
        agentModelFetchMessage = ""
        let configuration = entry.makeConfiguration().normalized

        Task {
            let result: Result<[String], Error>
            do {
                let models = try await AgentClient(configuration: configuration).fetchModels()
                result = .success(models)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isFetchingAgentModels = false
                switch result {
                case .success(let models):
                    fetchedAgentModels = models
                    appState.recordFetchedAgentModels(models)
                    if models.isEmpty {
                        agentModelFetchMessage = "No models returned."
                    } else {
                        // Auto-activate this entry: fetching is a strong
                        // "I want to use this provider" signal. Without
                        // this the user can fetch DeepSeek models but the
                        // active ★ stays on another (keyless) provider,
                        // so the next chat send dies with missingAPIKey
                        // even though they just proved the key works.
                        let wasActive = appState.agentProviderLibrary.activeID == entry.id
                        if !wasActive {
                            appState.setActiveProviderLibraryEntry(id: entry.id)
                        }
                        let suffix = wasActive ? "" : " ★ Activated."
                        agentModelFetchMessage = "Fetched \(models.count) models for \(entry.displayName).\(suffix)"
                    }
                case .failure(let error):
                    fetchedAgentModels = []
                    agentModelFetchMessage = error.localizedDescription
                }
            }
        }
    }

    private func fetchImageModels() {
        isFetchingImageModels = true
        imageModelFetchMessage = ""
        let imageConfiguration = AgentImageDescriptionConfiguration(
            providerID: imageProviderIDBuffer,
            baseURL: imageBaseURLBuffer,
            model: imageModelBuffer,
            apiKey: imageAPIKeyBuffer
        ).normalized.agentConfiguration

        Task {
            let result: Result<[String], Error>
            do {
                let models = try await AgentClient(configuration: imageConfiguration).fetchModels()
                result = .success(models)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isFetchingImageModels = false
                switch result {
                case .success(let models):
                    fetchedImageModels = models
                    appState.recordFetchedAgentModels(models)
                    if models.isEmpty {
                        imageModelFetchMessage = "No image models returned."
                    } else {
                        imageModelFetchMessage = "Fetched \(models.count) image models."
                        if imageModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = models.first {
                            imageModelBuffer = firstModel
                        }
                    }
                case .failure(let error):
                    fetchedImageModels = []
                    imageModelFetchMessage = error.localizedDescription
                }
            }
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>) -> Binding<Value> {
        Binding {
            appState.editorSettings[keyPath: keyPath]
        } set: { newValue in
            update(keyPath, newValue)
        }
    }

    private func update<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>, _ value: Value) {
        var settings = appState.editorSettings
        settings[keyPath: keyPath] = value
        appState.editorSettings = settings.normalized()
    }

    private var agentProviderBinding: Binding<String> {
        Binding {
            appState.agentConfiguration.providerID
        } set: { providerID in
            var configuration = appState.agentConfiguration
            configuration.providerID = providerID
            if let preset = AgentProviderPreset.preset(id: providerID),
               preset.id != AgentProviderPreset.customID {
                configuration.baseURL = preset.baseURL
                configuration.model = preset.defaultModel
                configuration.flashModel = preset.defaultFlashModel
                configuration.proModel = preset.defaultProModel
                configuration.routingMode = .auto
                // Reflect the preset in the live buffers so the user
                // doesn't have to click Save just to make the picker
                // visibly take effect.
                agentBaseURLBuffer = preset.baseURL
                agentModelBuffer = preset.defaultModel
                agentFlashModelBuffer = preset.defaultFlashModel
                agentProModelBuffer = preset.defaultProModel
                agentRoutingModeBuffer = .auto
            }
            fetchedAgentModels = []
            agentModelFetchMessage = ""
            appState.agentConfiguration = configuration.normalized
        }
    }

    private var imageProviderBinding: Binding<String> {
        Binding {
            imageProviderIDBuffer
        } set: { providerID in
            imageProviderIDBuffer = providerID
            if let preset = AgentProviderPreset.preset(id: providerID),
               preset.id != AgentProviderPreset.customID {
                imageBaseURLBuffer = preset.baseURL
                imageModelBuffer = preset.defaultVisionModel
            }
            fetchedImageModels = []
            imageModelFetchMessage = ""
        }
    }

}

private struct SettingsKeyboardShortcutHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window,
                  event.window === window,
                  event.charactersIgnoringModifiers?.lowercased() == "w" else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.option) || modifiers.contains(.command) else {
                return event
            }

            window.performClose(nil)
            return nil
        }
    }
}

private struct ThemeSwatch: View {
    let theme: EditorTheme

    var body: some View {
        HStack(spacing: 0) {
            Color(nsColor: theme.backgroundColor)
            Color(nsColor: theme.keywordColor)
            Color(nsColor: theme.stringColor)
            Color(nsColor: theme.commentColor)
            Color(nsColor: theme.numberColor)
        }
        .frame(width: 64, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: theme.gutterTextColor).opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Agent provider library section

/// Phase C: Settings UI for the multi-provider library. Left pane lists
/// the user's saved providers with active-marker / add / remove
/// controls; right pane edits the selected entry's preset, base URL,
/// API key, flash primary + alternates, pro primary + alternates,
/// with a Fetch Models button that pulls per-entry. Edits commit
/// immediately to `appState.agentProviderLibrary` (no Save button) —
/// the legacy single-config Save flow continues to cover Image
/// Understanding and routing.
struct AgentProviderLibrarySection: View {
    @EnvironmentObject var appState: AppState
    @Binding var fetchedAgentModels: [String]
    @Binding var isFetchingAgentModels: Bool
    @Binding var agentModelFetchMessage: String
    let onFetchModels: (AgentProviderEntry) -> Void

    @State private var selectedEntryID: UUID?

    private var selectedEntry: AgentProviderEntry? {
        guard let id = selectedEntryID else { return nil }
        return appState.agentProviderLibrary.entries.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                providerList
                    .frame(width: 200)
                editorPane
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(L10n.Settings.Provider.editsAutoSave)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: ensureSelection)
        .onChange(of: appState.agentProviderLibrary.activeID) { _, _ in
            ensureSelection()
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.agentProviderLibrary.entries) { entry in
                        providerRow(entry)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .frame(minHeight: 260)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            HStack(spacing: 2) {
                Button {
                    addEntry()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(L10n.Settings.Provider.addTooltip)

                Button {
                    if let id = selectedEntryID {
                        appState.removeProviderLibraryEntry(id: id)
                        selectedEntryID = appState.agentProviderLibrary.entries.first?.id
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(selectedEntryID == nil || appState.agentProviderLibrary.entries.count <= 1)
                .help(L10n.Settings.Provider.removeTooltip)

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func providerRow(_ entry: AgentProviderEntry) -> some View {
        let isSelected = selectedEntryID == entry.id
        let isActive = appState.agentProviderLibrary.activeID == entry.id
        HStack(spacing: 8) {
            Button {
                appState.setActiveProviderLibraryEntry(id: entry.id)
            } label: {
                Image(systemName: isActive ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.yellow : Color.secondary.opacity(0.45))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isActive ? L10n.Settings.Provider.activeTooltip : L10n.Settings.Provider.makeActiveTooltip)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    // Tiny kind badge so the user can tell at a glance
                    // whether a row is OpenAI Chat / Anthropic / Gemini.
                    // Falls back to "OpenAI Chat" for unknown
                    // (custom-edited) provider IDs — matches the
                    // adapter dispatch in `AgentClient`.
                    Text(kindLabel(for: entry))
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected
                                      ? Color.white.opacity(0.18)
                                      : Color.secondary.opacity(0.12))
                        )
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
                Text(entry.flashPrimary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedEntryID = entry.id
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let entry = selectedEntry {
            AgentProviderEntryEditor(
                entry: entry,
                fetchedAgentModels: fetchedAgentModels,
                isFetchingAgentModels: isFetchingAgentModels,
                agentModelFetchMessage: agentModelFetchMessage,
                onFetch: { onFetchModels(entry) },
                onChange: { updated in
                    appState.upsertProviderLibraryEntry(updated)
                }
            )
        } else {
            Text(L10n.Settings.Provider.emptySelection)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func addEntry() {
        // Default new entries to DeepSeek, matching the fresh-install
        // provider and avoiding accidental OpenAI model suggestions.
        let preset = AgentProviderPreset.preset(id: AgentProviderPreset.deepSeekID) ?? AgentProviderPreset.all[0]
        let entry = AgentProviderEntry(
            providerID: preset.id,
            baseURL: preset.baseURL,
            apiKey: "",
            flashPrimary: preset.defaultFlashModel,
            proPrimary: preset.defaultProModel
        )
        appState.upsertProviderLibraryEntry(entry)
        selectedEntryID = entry.id
    }

    /// Sidebar badge label. Mirrors `AgentConfiguration.providerKind`
    /// resolution so the badge tells the truth about which adapter
    /// will actually be dispatched: Custom + override → the chosen
    /// kind; named preset → that preset's intrinsic kind; unknown
    /// providerID → OpenAI Chat (facade fallback).
    private func kindLabel(for entry: AgentProviderEntry) -> String {
        if entry.providerID == AgentProviderPreset.customID,
           let override = entry.customKindOverride {
            return override.shortLabel
        }
        let kind = AgentProviderPreset.preset(id: entry.providerID)?.kind ?? .openAIChat
        return kind.shortLabel
    }

    private func ensureSelection() {
        if selectedEntryID == nil
            || appState.agentProviderLibrary.entries.first(where: { $0.id == selectedEntryID }) == nil {
            selectedEntryID = appState.agentProviderLibrary.activeID
                ?? appState.agentProviderLibrary.entries.first?.id
        }
    }
}

/// Right-pane editor for one library entry. State buffers locally to
/// keep typing snappy; commits to AppState on `.onChange` so there's
/// no Save button to forget.
private struct AgentProviderEntryEditor: View {
    let entry: AgentProviderEntry
    let fetchedAgentModels: [String]
    let isFetchingAgentModels: Bool
    let agentModelFetchMessage: String
    let onFetch: () -> Void
    let onChange: (AgentProviderEntry) -> Void

    @State private var providerID: String = ""
    @State private var displayName: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var flashPrimary: String = ""
    @State private var flashAlternatesText: String = ""
    @State private var proPrimary: String = ""
    @State private var proAlternatesText: String = ""
    @State private var routingMode: AgentModelRoutingMode = .auto
    /// nil → use the preset's intrinsic kind (every named preset). Only
    /// meaningful when `providerID == custom`; the Picker is hidden
    /// otherwise. See `AgentProviderEntry.customKindOverride` for the
    /// persisted side.
    @State private var customKindOverride: AgentProviderKind? = nil

    // Section expansion. 路由 + 协议帮助卡片默认折叠 —— 多数用户配完一次
    // 就不再回来调，铺满垂直空间没意义。点击 header 可展开。
    @State private var isConnectionExpanded: Bool = true
    @State private var isModelsExpanded: Bool = true
    @State private var isRoutingExpanded: Bool = false
    @State private var isProtocolHelpExpanded: Bool = false

    private let labelWidth: CGFloat = 110

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                connectionGroup
                modelsGroup
                routingGroup
                fetchModelsRow
            }
            .padding(.trailing, 4)
        }
        .onAppear(perform: loadFromEntry)
        .onChange(of: entry.id) { _, _ in loadFromEntry() }
    }

    // MARK: - Connection

    private var connectionGroup: some View {
        GroupBox(label: collapsibleSectionLabel(
            L10n.Settings.Provider.connectionSection,
            system: "link",
            isExpanded: $isConnectionExpanded
        )) {
            if isConnectionExpanded {
            VStack(alignment: .leading, spacing: 10) {
                fieldRow(L10n.Settings.Provider.displayNameLabel) {
                    TextField(L10n.Settings.Provider.displayNamePlaceholder, text: $displayName, onCommit: commit)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: displayName) { _, _ in commit() }
                }
                fieldRow(L10n.Settings.Provider.presetLabel) {
                    Picker("", selection: $providerID) {
                        ForEach(AgentProviderPreset.all) { p in
                            Text("\(p.displayName) · \(p.kind.shortLabel)").tag(p.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: providerID) { _, newID in
                        // Snap to preset defaults so the user doesn't have
                        // to retype everything when switching brands.
                        if let preset = AgentProviderPreset.preset(id: newID), preset.id != AgentProviderPreset.customID {
                            baseURL = preset.baseURL
                            if !preset.recognizesModelID(flashPrimary) {
                                flashPrimary = preset.defaultFlashModel
                            }
                            if !preset.recognizesModelID(proPrimary) {
                                proPrimary = preset.defaultProModel
                            }
                            if displayName.isEmpty || AgentProviderPreset.all.map(\.displayName).contains(displayName) {
                                displayName = preset.displayName
                            }
                        }
                        if newID != AgentProviderPreset.customID {
                            // Switching away from Custom invalidates the
                            // kind override — it would otherwise sit
                            // dormant in storage and bite later.
                            customKindOverride = nil
                        }
                        commit()
                    }
                }
                customKindPickerRow
                protocolHelpCard
                fieldRow(L10n.Settings.Provider.baseURLLabel) {
                    TextField(baseURLPlaceholder, text: $baseURL, onCommit: commit)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: baseURL) { _, _ in commit() }
                }
                baseURLStatusRow
                fieldRow(L10n.Settings.Provider.apiKeyLabel) {
                    RevealableSecretField(
                        text: $apiKey,
                        placeholder: "",
                        onCommit: commit
                    )
                    .onChange(of: apiKey) { _, _ in commit() }
                }
                apiKeyHint
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            }
        }
    }

    /// Visible only when the Custom preset is selected. Lets the user
    /// pick which transport protocol their self-hosted endpoint
    /// speaks — without this, Custom is permanently locked to
    /// OpenAI Chat and a self-hosted Anthropic / Gemini / Responses
    /// proxy is unreachable.
    @ViewBuilder
    private var customKindPickerRow: some View {
        if providerID == AgentProviderPreset.customID {
            fieldRow(L10n.Settings.Provider.protocolLabel) {
                Picker("", selection: $customKindOverride) {
                    Text(L10n.Settings.Provider.openAIChatDefault).tag(AgentProviderKind?.none)
                    Text("OpenAI Chat").tag(AgentProviderKind?.some(.openAIChat))
                    Text("Anthropic Messages").tag(AgentProviderKind?.some(.anthropicMessages))
                    Text("Google Gemini").tag(AgentProviderKind?.some(.geminiGenerateContent))
                    Text("OpenAI Responses").tag(AgentProviderKind?.some(.openAIResponses))
                }
                .labelsHidden()
                .onChange(of: customKindOverride) { _, _ in commit() }
            }
        }
    }

    /// Placeholder for the Base URL field. For named presets, show the
    /// preset's default URL so the user can tell at a glance "leaving
    /// this empty would use X". For Custom and the empty-baseURL
    /// presets (some.im default uses its own value, custom is blank),
    /// fall back to a generic hint.
    private var baseURLPlaceholder: String {
        if let preset = AgentProviderPreset.preset(id: providerID),
           !preset.baseURL.isEmpty {
            return preset.baseURL
        }
        return "https://..."
    }

    /// Status pill under the Base URL field: green check when the user
    /// is on the preset's default URL, yellow note when they've
    /// customised it. Hidden for the Custom preset (no preset default
    /// to compare against — every URL is by definition user-chosen).
    @ViewBuilder
    private var baseURLStatusRow: some View {
        if let preset = AgentProviderPreset.preset(id: providerID),
           preset.id != AgentProviderPreset.customID,
           !preset.baseURL.isEmpty {
            let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
                .lowercased()
            let presetTrimmed = preset.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
                .lowercased()
            let isDefault = trimmed.isEmpty || trimmed == presetTrimmed
            HStack(spacing: 4) {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isDefault ? Color.green : Color.orange)
                Text(isDefault ? L10n.Settings.Provider.baseURLDefault : L10n.Settings.Provider.baseURLCustom)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, labelWidth + 8)
        }
    }

    /// Tinted card that explains which transport protocol the
    /// currently picked preset speaks. For Custom with a kind
    /// override, defers to the override's helpText so the user gets
    /// the same explanation as if they'd picked a named preset.
    @ViewBuilder
    private var protocolHelpCard: some View {
        if let preset = AgentProviderPreset.preset(id: providerID) {
            let effectiveKind: AgentProviderKind = {
                if preset.id == AgentProviderPreset.customID,
                   let override = customKindOverride {
                    return override
                }
                return preset.kind
            }()
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isProtocolHelpExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: protocolIcon(for: effectiveKind))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(L10n.Settings.Provider.protocolLine(effectiveKind.shortLabel))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                            .rotationEffect(.degrees(isProtocolHelpExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isProtocolHelpExpanded {
                    Text(effectiveKind.helpText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice = preset.inlineNotice {
                        Divider()
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isProtocolHelpExpanded ? 10 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
            .padding(.leading, labelWidth + 8)
        }
    }

    @ViewBuilder
    private var apiKeyHint: some View {
        if let preset = AgentProviderPreset.preset(id: providerID),
           !preset.apiKeySourceHint.isEmpty {
            Text(preset.apiKeySourceHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, labelWidth + 8)
        }
    }

    private func protocolIcon(for kind: AgentProviderKind) -> String {
        switch kind {
        case .openAIChat:           return "bubble.left.and.bubble.right"
        case .openAIResponses:      return "brain"
        case .anthropicMessages:    return "a.circle"
        case .geminiGenerateContent: return "sparkles"
        }
    }

    // MARK: - Models

    private var modelsGroup: some View {
        GroupBox(label: collapsibleSectionLabel(
            L10n.Settings.Provider.modelsSection,
            system: "cube.box",
            isExpanded: $isModelsExpanded
        )) {
            if isModelsExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    modelGroup(
                        title: "Flash",
                        primaryBinding: $flashPrimary,
                        alternatesBinding: $flashAlternatesText
                    )
                    Divider()
                    modelGroup(
                        title: "Pro",
                        primaryBinding: $proPrimary,
                        alternatesBinding: $proAlternatesText
                    )
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Routing

    private var routingGroup: some View {
        GroupBox(label: collapsibleSectionLabel(
            L10n.Settings.Provider.routingSection,
            system: "arrow.triangle.branch",
            isExpanded: $isRoutingExpanded
        )) {
            if isRoutingExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    fieldRow(L10n.Settings.Provider.defaultTierLabel) {
                        Picker("", selection: $routingMode) {
                            ForEach(AgentModelRoutingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .onChange(of: routingMode) { _, _ in commit() }
                    }
                    Text(routingMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, labelWidth + 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Fetch models row

    private var fetchModelsRow: some View {
        HStack(spacing: 10) {
            Button {
                onFetch()
            } label: {
                HStack(spacing: 4) {
                    if isFetchingAgentModels {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(isFetchingAgentModels ? L10n.Settings.Provider.fetchingModels : L10n.Settings.Provider.fetchModels)
                }
            }
            .disabled(isFetchingAgentModels)
            if !agentModelFetchMessage.isEmpty {
                Text(agentModelFetchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionLabel(_ title: String, system: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    /// 把 GroupBox header 做成可点击的折叠开关：右端一枚 chevron，点击
    /// 整条行切换展开。用 GroupBox 自带的 label slot 装它，外观跟原先的
    /// 静态 sectionLabel 接近，只是多了一只箭头。
    @ViewBuilder
    private func collapsibleSectionLabel(
        _ title: String,
        system: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: system)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func modelGroup(
        title: String,
        primaryBinding: Binding<String>,
        alternatesBinding: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow(L10n.Settings.Provider.primarySuffix(title)) {
                modelField(text: primaryBinding)
            }
            HStack(alignment: .top, spacing: 8) {
                Text(L10n.Settings.Provider.alternatesSuffix(title))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: alternatesBinding)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 52, maxHeight: 88)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .onChange(of: alternatesBinding.wrappedValue) { _, _ in commit() }
                    Text(L10n.Settings.Provider.alternatesHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func modelField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            TextField(L10n.Settings.Provider.modelIDPlaceholder, text: text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
            if !fetchedAgentModels.isEmpty {
                Menu {
                    ForEach(fetchedAgentModels, id: \.self) { id in
                        Button(id) { text.wrappedValue = id; commit() }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.Settings.Provider.pickFromFetched)
            }
        }
        .onChange(of: text.wrappedValue) { _, _ in commit() }
    }

    private func loadFromEntry() {
        providerID = entry.providerID
        displayName = entry.displayName
        baseURL = entry.baseURL
        apiKey = entry.apiKey
        flashPrimary = entry.flashPrimary
        flashAlternatesText = entry.flashAlternates.joined(separator: "\n")
        proPrimary = entry.proPrimary
        proAlternatesText = entry.proAlternates.joined(separator: "\n")
        routingMode = entry.routingMode
        customKindOverride = entry.customKindOverride
    }

    private func commit() {
        // Trim secrets / URLs before persisting. Pasting an API key from
        // a browser or password manager frequently brings a trailing
        // newline or a leading/trailing space along; the resulting
        // `Bearer sk-xxx\n` header is rejected by every upstream as
        // HTTP 401, which on the surface looks identical to a typo'd
        // key. Trim at commit time so what the user sees in the field
        // is exactly what we send.
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAPIKey != apiKey { apiKey = trimmedAPIKey }
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL != baseURL { baseURL = trimmedBaseURL }
        let updated = AgentProviderEntry(
            id: entry.id,
            providerID: providerID,
            displayName: displayName,
            baseURL: trimmedBaseURL,
            apiKey: trimmedAPIKey,
            flashPrimary: flashPrimary,
            flashAlternates: splitLines(flashAlternatesText),
            proPrimary: proPrimary,
            proAlternates: splitLines(proAlternatesText),
            routingMode: routingMode,
            customKindOverride: customKindOverride
        )
        onChange(updated)
    }

    private func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Secret field that toggles between SecureField (dots) and TextField
/// (revealed) via an eye button. Lets the user verify a pasted API key
/// without re-typing it. The reveal state lives in the view — never
/// persisted — so closing Settings re-hides the key by default.
private struct RevealableSecretField: View {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void

    @State private var isRevealed: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text, onCommit: onCommit)
                } else {
                    SecureField(placeholder, text: $text, onCommit: onCommit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? L10n.Settings.Provider.hideKey : L10n.Settings.Provider.showKey)
        }
    }
}

/// SwiftUI's `Settings { }` scene installs an `NSPanel` whose default
/// styleMask omits `.resizable`, so the user can't drag the corners
/// even after the SwiftUI view advertises `maxWidth: .infinity`.  We
/// reach into the host window once it's available and add the
/// resizable + miniaturizable + zoom bits, drop the contentMaxSize
/// cap, and give it a sensible content min size.  Result: feels like
/// a normal mac document window.
private struct SettingsWindowResizableEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        var mask = window.styleMask
        mask.insert(.resizable)
        mask.insert(.miniaturizable)
        mask.insert(.closable)
        mask.insert(.titled)
        window.styleMask = mask
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)
        window.isMovableByWindowBackground = false
        window.title = L10n.Settings.windowTitle
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
    }
}
