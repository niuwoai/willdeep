//
//  EditorSettingsView.swift
//  WillDeep
//
//  Preferences UI for editor appearance.
//

import SwiftUI
import AppKit

struct EditorSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var settingsNavigation = EditorSettingsNavigation.shared
    @State private var cliInstallState: CommandLineToolInstallState = .notInstalled
    @State private var cliStatusMessage = ""
    @State private var isInstallingCLI = false
    @State private var fetchedAgentModels: [String] = []
    @State private var isFetchingAgentModels = false
    @State private var agentModelFetchMessage = ""
    @State private var agentModelFetchBaseURLSuggestion: AgentProviderBaseURLSuggestion?
    @State private var fetchedImageModels: [String] = []
    @State private var isFetchingImageModels = false
    @State private var imageModelFetchMessage = ""
    @State var isInstallingWorkspaceWallpaper = false
    @State var workspaceWallpaperErrorMessage = ""

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
    @State private var imageProviderIDBuffer: String = AgentProviderPreset.someIMID
    @State private var imageBaseURLBuffer: String = ""
    @State private var imageModelBuffer: String = ""
    @State private var imageAPIKeyBuffer: String = ""
    /// Optional dedicated model name used solely for the
    /// "summarize this chat into a short title" call. Empty buffer ⇒
    /// the resolver falls back to the active flash model. See
    /// AgentConfiguration.titleSummaryModel() and
    /// AppStateAgentTitleSummarizer.
    @State private var agentTitleModelBuffer: String = ""
    @State private var agentCompressionModelBuffer: String = ""
    @State private var agentSaveStatus: String = ""
    // Web search provider preference plus provider keys for the
    // built-in web_search tool. Saved/loaded straight through
    // AgentSettingsStore — these have no slot in AgentConfiguration, so
    // they stay out of commitAgentBuffers.
    @State private var webSearchProviderBuffer: AgentWebSearchProvider = .auto
    @State private var webSearchProviderSaved: AgentWebSearchProvider = .auto
    @State private var exaSearchAPIKeyBuffer: String = ""
    @State private var exaSearchAPIKeySaved: String = ""
    @State private var braveSearchAPIKeyBuffer: String = ""
    @State private var braveSearchAPIKeySaved: String = ""
    @State private var webSearchSaveStatus: String = ""
    @State private var discoveredLocalAgents: [LocalAgentCLI.Discovery] = LocalAgentCLI.discoverAll()

    @State private var anthropicMaxOutputTokens: Double = Double(AgentSettingsStore.loadAnthropicMaxOutputTokens())
    @State private var appLanguagePreference = AppLocale.preference
    /// 非 nil = 用户这一轮改过语言但还没重启,横幅要一直挂着。
    @State private var pendingLanguageRestart: AppLanguagePreference?
    @State private var showLanguageRestartAlert = false

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsContent
        }
        .frame(
            minWidth: 760,
            idealWidth: 920,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 700,
            maxHeight: .infinity
        )
        .background(SettingsKeyboardShortcutHandler())
        .background(SettingsWindowResizableEnforcer())
        .settingsFocusDisabled()
        .onAppear {
            refreshCLIState()
            refreshLocalAgentDiscovery()
        }
    }

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SettingsGroup.allCases) { group in
                    Button {
                        settingsNavigation.selectedTab = group.tabs.first ?? settingsNavigation.selectedTab
                    } label: {
                        let isSelected = settingsNavigation.selectedTab.group == group
                        HStack(spacing: 8) {
                            Image(systemName: group.icon)
                                .frame(width: 16, alignment: .center)
                            Text(group.title)
                            Spacer(minLength: 0)
                        }
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.16))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .settingsFocusDisabled()
                    .help(group.title)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .settingsFocusDisabled()
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settingsNavigation.selectedTab.group.title)
                .font(.title3.weight(.semibold))

            settingsGroupContainer(settingsNavigation.selectedTab.group)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsFocusDisabled()
    }

    // MARK: Sidebar tab navigation

    @ViewBuilder
    private func settingsGroupContainer(_ group: SettingsGroup) -> some View {
        VStack(spacing: 12) {
            if group.tabs.count > 1 {
                Picker("", selection: subTabBinding(for: group)) {
                    ForEach(group.tabs, id: \.self) { tab in
                        Text(tab.shortTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .settingsFocusDisabled()
            }
            settingsPage(for: resolvedTab(in: group))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .settingsFocusDisabled()
            if group == .accountAndDevices {
                Divider()
                languageSettings
            }
        }
        .settingsFocusDisabled()
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Language.title)
                .font(.headline)
            HStack {
                Text(L10n.Settings.Language.pickerLabel)
                Spacer(minLength: 20)
                Picker("", selection: $appLanguagePreference) {
                    Text(L10n.Settings.Language.system).tag(AppLanguagePreference.system)
                    Text(L10n.Settings.Language.simplifiedChinese).tag(AppLanguagePreference.simplifiedChinese)
                    Text(L10n.Settings.Language.english).tag(AppLanguagePreference.english)
                    Text(L10n.Settings.Language.japanese).tag(AppLanguagePreference.japanese)
                    Text(L10n.Settings.Language.spanish).tag(AppLanguagePreference.spanish)
                    Text(L10n.Settings.Language.french).tag(AppLanguagePreference.french)
                }
                .labelsHidden()
                .frame(width: 190)
                .onChange(of: appLanguagePreference) { preference in
                    AppLocale.setPreference(preference)
                    // 点了一圈又点回本进程正在用的语言 = 什么都没变,
                    // 不该再催重启。
                    guard preference != AppLocale.launchPreference else {
                        pendingLanguageRestart = nil
                        return
                    }
                    // 界面语言只有重启才换得掉,静默生效会让用户以为
                    // 「点了没反应」。弹窗喊一嗓子,横幅留在原地兜底
                    // (用户点了「稍后」也还看得见)。
                    pendingLanguageRestart = preference
                    showLanguageRestartAlert = true
                }
            }
            if let pending = pendingLanguageRestart {
                languageRestartBanner(for: pending)
            } else {
                Text(L10n.Settings.Language.restartNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .alert(
            L10n.Settings.Language.changedAlertTitle,
            isPresented: $showLanguageRestartAlert
        ) {
            Button(L10n.Settings.Language.relaunchButton) {
                AppRelaunch.relaunch()
            }
            Button(L10n.Settings.Language.laterButton, role: .cancel) {}
        } message: {
            Text(
                L10n.Settings.Language.changedAlertMessage(
                    (pendingLanguageRestart ?? appLanguagePreference).nativeDisplayName
                )
            )
        }
    }

    /// 常驻横幅:弹窗关掉之后仍然提醒「这个改动还没生效」。
    private func languageRestartBanner(for preference: AppLanguagePreference) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Settings.Language.changedBannerTitle)
                    .font(.callout.weight(.semibold))
                Text(L10n.Settings.Language.changedBannerDetail(preference.nativeDisplayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.Settings.Language.coverageNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(L10n.Settings.Language.relaunchButton) {
                AppRelaunch.relaunch()
            }
            .buttonStyle(.borderedProminent)
            .settingsFocusDisabled()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                }
        }
    }

    /// Second-level segmented-picker binding, scoped to one group.
    private func subTabBinding(for group: SettingsGroup) -> Binding<EditorSettingsTab> {
        Binding(
            get: { resolvedTab(in: group) },
            set: { settingsNavigation.selectedTab = $0 }
        )
    }

    /// The selected pane if it belongs to `group`, otherwise the group's first.
    private func resolvedTab(in group: SettingsGroup) -> EditorSettingsTab {
        let current = settingsNavigation.selectedTab
        return current.group == group ? current : (group.tabs.first ?? current)
    }

    @ViewBuilder
    private func settingsPage(for tab: EditorSettingsTab) -> some View {
        switch tab {
        case .updates: updatesSettings
        case .editing: editingSettings
        case .typography: typographySettings
        case .appearance: appearanceSettings
        case .workspace: workspaceSettings
        case .agentAppearance: agentAppearanceSettings
        case .agent: agentSettings
        case .notifications: AgentAttentionSettingsView()
        case .subagents: AgentProfileSettingsView()
        case .someIM: SomeIMIntegrationSettingsView()
        // Deep-links to `.replicate` land on the unified connectors hub
        // with the Replicate sub-connector preselected.
        case .replicate: CollaborationConnectorSettingsView(initialSelection: .replicate)
        case .localAgents: localAgentSettings
        case .remoteRuntimes: AgentRuntimeSettingsView()
        case .mobileGateway: MobileGatewaySettingsView()
        case .memory: AgentMemorySettingsView()
        case .rules: AgentGlobalRulesSettingsView()
        case .skills: AgentSkillSettingsView()
        case .connectors: CollaborationConnectorSettingsView()
        case .mcp: AgentMCPSettingsView()
        case .tools: toolsSettings
        case .secrets: AgentSecretSettingsView()
        case .terminal: terminalSettings
        case .pet: petSettings
        }
    }

    private var petSettings: some View {
        DesktopPetSettingsPage()
    }

    private var agentSettings: some View {
        Form {
            Section(L10n.Settings.sectionAgentProviders) {
                AgentProviderLibrarySection(
                    fetchedAgentModels: $fetchedAgentModels,
                    isFetchingAgentModels: $isFetchingAgentModels,
                    agentModelFetchMessage: $agentModelFetchMessage,
                    baseURLSuggestion: $agentModelFetchBaseURLSuggestion,
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

            AgentLocalModelSettingsSection()

            Section(L10n.Settings.sectionConversationTitle) {
                LabeledContent(L10n.Settings.AgentBehavior.titleModelLabel) {
                    TextField("", text: $agentTitleModelBuffer, prompt: Text(L10n.Settings.AgentBehavior.titleModelPlaceholder))
                        .textFieldStyle(.roundedBorder)
                }
                Text(L10n.Settings.AgentBehavior.titleModelDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionContextCompression) {
                LabeledContent(L10n.Settings.AgentBehavior.compressionModelLabel) {
                    TextField(
                        "",
                        text: $agentCompressionModelBuffer,
                        prompt: Text(L10n.Settings.AgentBehavior.compressionModelPlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Text(L10n.Settings.AgentBehavior.compressionModelDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionWebTools) {
                Picker(L10n.Settings.WebTools.providerLabel, selection: $webSearchProviderBuffer) {
                    ForEach(AgentWebSearchProvider.allCases) { provider in
                        Text(L10n.Settings.WebTools.providerName(provider)).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent(L10n.Settings.WebTools.exaKeyLabel) {
                    RevealableSecretField(
                        text: $exaSearchAPIKeyBuffer,
                        placeholder: "",
                        onCommit: { commitWebSearchSettings() }
                    )
                }

                LabeledContent(L10n.Settings.WebTools.braveKeyLabel) {
                    RevealableSecretField(
                        text: $braveSearchAPIKeyBuffer,
                        placeholder: "",
                        onCommit: { commitWebSearchSettings() }
                    )
                }
                HStack {
                    Button(L10n.Settings.buttonSave) {
                        commitWebSearchSettings()
                    }
                    .disabled(!webSearchSettingsDiffer)

                    if !webSearchSaveStatus.isEmpty {
                        Text(webSearchSaveStatus)
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

                HStack {
                    Text(L10n.Settings.AgentBehavior.anthropicMaxOutputTokens)
                    Spacer()
                    Text("\(Int(anthropicMaxOutputTokens))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { anthropicMaxOutputTokens },
                        set: { newValue in
                            anthropicMaxOutputTokens = newValue
                            AgentSettingsStore.saveAnthropicMaxOutputTokens(Int(newValue))
                        }
                    ),
                    in: Double(AgentSettingsStore.anthropicMaxOutputTokensMin)
                        ... Double(AgentSettingsStore.anthropicMaxOutputTokensMax),
                    step: 1024
                )
                Text(L10n.Settings.AgentBehavior.anthropicMaxOutputTokensDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .onAppear {
            loadAgentBuffersFromAppState()
            anthropicMaxOutputTokens = Double(AgentSettingsStore.loadAnthropicMaxOutputTokens())
        }
        .onCompatibleChange(of: appState.agentConfiguration) { _, _ in
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
            || agentCompressionModelBuffer != configuration.compressionModel
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
        agentCompressionModelBuffer = configuration.compressionModel
        webSearchProviderSaved = AgentSettingsStore.loadWebSearchProvider()
        webSearchProviderBuffer = webSearchProviderSaved
        exaSearchAPIKeySaved = AgentSettingsStore.loadExaSearchAPIKey()
        exaSearchAPIKeyBuffer = exaSearchAPIKeySaved
        braveSearchAPIKeySaved = AgentSettingsStore.loadBraveSearchAPIKey()
        braveSearchAPIKeyBuffer = braveSearchAPIKeySaved
    }

    private var webSearchSettingsDiffer: Bool {
        webSearchProviderBuffer != webSearchProviderSaved
            || exaSearchAPIKeyBuffer != exaSearchAPIKeySaved
            || braveSearchAPIKeyBuffer != braveSearchAPIKeySaved
    }

    private func commitWebSearchSettings() {
        let exaTrimmed = exaSearchAPIKeyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = braveSearchAPIKeyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        AgentSettingsStore.saveWebSearchProvider(webSearchProviderBuffer)
        AgentSettingsStore.saveExaSearchAPIKey(exaTrimmed)
        AgentSettingsStore.saveBraveSearchAPIKey(trimmed)
        webSearchProviderSaved = webSearchProviderBuffer
        exaSearchAPIKeyBuffer = exaTrimmed
        exaSearchAPIKeySaved = exaTrimmed
        braveSearchAPIKeyBuffer = trimmed
        braveSearchAPIKeySaved = trimmed
        webSearchSaveStatus = L10n.Settings.savedStatus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if webSearchSaveStatus == L10n.Settings.savedStatus { webSearchSaveStatus = "" }
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
        configuration.compressionModel = agentCompressionModelBuffer
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appState.agentConfiguration = configuration.normalized
        loadAgentBuffersFromAppState()
        agentSaveStatus = L10n.Settings.savedStatus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if agentSaveStatus == L10n.Settings.savedStatus { agentSaveStatus = "" }
        }
    }

    private func commitImageDescriptionBuffers() {
        var configuration = appState.agentConfiguration
        configuration.imageDescription = AgentImageDescriptionConfiguration(
            providerID: imageProviderIDBuffer,
            baseURL: imageBaseURLBuffer,
            model: imageModelBuffer,
            apiKey: imageAPIKeyBuffer
        ).normalized
        appState.agentConfiguration = configuration.normalized
        let saved = appState.agentConfiguration.imageDescription
        imageProviderIDBuffer = saved.providerID
        imageBaseURLBuffer = saved.baseURL
        imageModelBuffer = saved.model
        imageAPIKeyBuffer = saved.apiKey
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

            AgentComputerUsePermissionSettingsSection()
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

    private func fetchAgentModels() {
        isFetchingAgentModels = true
        agentModelFetchMessage = ""
        let configuration = appState.agentConfiguration.normalized

        Task {
            let result: Result<[AgentModelDiscovery], Error>
            do {
                let models = try await AgentClient(configuration: configuration).fetchModelDiscoveries()
                result = .success(models)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                isFetchingAgentModels = false
                switch result {
                case .success(let discoveries):
                    let modelIDs = discoveries.map(\.id)
                    fetchedAgentModels = modelIDs
                    appState.recordFetchedAgentModelDiscoveries(discoveries)
                    if modelIDs.isEmpty {
                        agentModelFetchMessage = "No models returned."
                    } else {
                        agentModelFetchMessage = "Fetched \(modelIDs.count) models."
                        if agentFlashModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = modelIDs.first {
                            agentFlashModelBuffer = firstModel
                        }
                        if agentProModelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let firstModel = modelIDs.first {
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
        agentModelFetchBaseURLSuggestion = nil
        let configuration = entry.makeConfiguration().normalized

        Task {
            let result: Result<AgentProviderModelFetchResult, Error>
            do {
                let models = try await AgentClient(configuration: configuration).fetchModelDiscoveries()
                result = .success(AgentProviderModelFetchResult(discoveries: models))
            } catch let originalError {
                if AgentProviderBaseURLV1Probe.shouldRetry(after: originalError),
                   let candidate = AgentProviderBaseURLV1Probe.candidate(
                       baseURL: configuration.baseURL,
                       providerKind: configuration.providerKind
                   ) {
                    var candidateConfiguration = configuration
                    candidateConfiguration.baseURL = candidate.baseURL
                    do {
                        let models = try await AgentClient(
                            configuration: candidateConfiguration
                        ).fetchModelDiscoveries()
                        result = .success(AgentProviderModelFetchResult(
                            discoveries: models,
                            baseURLCandidate: candidate
                        ))
                    } catch {
                        // The recovery candidate failed too. Keep the original
                        // 404 because it describes the address the user
                        // actually entered, rather than implying we saved /v1.
                        result = .failure(originalError)
                    }
                } else {
                    result = .failure(originalError)
                }
            }

            await MainActor.run {
                isFetchingAgentModels = false
                switch result {
                case .success(let fetchResult):
                    let discoveries = fetchResult.discoveries
                    let modelIDs = discoveries.map(\.id)
                    fetchedAgentModels = modelIDs
                    appState.recordFetchedAgentModelDiscoveries(discoveries)
                    if let candidate = fetchResult.baseURLCandidate {
                        agentModelFetchBaseURLSuggestion = AgentProviderBaseURLSuggestion(
                            entryID: entry.id,
                            originalBaseURL: entry.baseURL,
                            suggestedBaseURL: candidate.baseURL,
                            adjustment: candidate.adjustment
                        )
                        switch candidate.adjustment {
                        case .append:
                            agentModelFetchMessage = L10n.Settings.Provider.v1ProbeSucceeded(
                                String(modelIDs.count),
                                candidate.baseURL
                            )
                        case .remove:
                            agentModelFetchMessage = L10n.Settings.Provider.v1RemovalProbeSucceeded(
                                String(modelIDs.count),
                                candidate.baseURL
                            )
                        }
                    } else if modelIDs.isEmpty {
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
                        agentModelFetchMessage = "Fetched \(modelIDs.count) models for \(entry.displayName).\(suffix)"
                    }
                case .failure(let error):
                    fetchedAgentModels = []
                    agentModelFetchMessage = error.localizedDescription
                }
            }
        }
    }

    private struct AgentProviderModelFetchResult {
        let discoveries: [AgentModelDiscovery]
        var baseURLCandidate: AgentProviderBaseURLV1Candidate? = nil
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
                        commitImageDescriptionBuffers()
                    }
                case .failure(let error):
                    fetchedImageModels = []
                    imageModelFetchMessage = error.localizedDescription
                }
            }
        }
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
