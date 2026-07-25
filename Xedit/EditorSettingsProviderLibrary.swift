import SwiftUI

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
    @State private var importMessage: String?

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
        .onCompatibleChange(of: appState.agentProviderLibrary.activeID) { _, _ in
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

                Menu {
                    ForEach(ProviderImportSource.allCases) { source in
                        Button(source.displayName) {
                            let message = appState.importProviders(from: source)
                            importMessage = message
                            selectedEntryID = appState.agentProviderLibrary.activeID
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(String(
                    localized: "settings.provider.importFromTool",
                    defaultValue: "从 Claude Code / openclaw / hermes 的配置导入 provider"
                ))

                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            if let importMessage {
                Text(importMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
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
            appState.materializeProviderLibraryEntryAPIKey(id: entry.id)
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
            // Bind the editor's identity to the selected entry. Without
            // this SwiftUI reuses one editor instance across entries and
            // its local @State buffers leak between them — editing one
            // entry's display name bled into another (and a freshly added
            // entry never got its own independent state). `.id` forces a
            // clean rebuild + reload whenever the selection changes.
            .id(entry.id)
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
        if let selectedEntryID {
            appState.materializeProviderLibraryEntryAPIKey(id: selectedEntryID)
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
    /// 备选模型是进阶用法：多数服务商只填一个主模型。默认收起那两个
    /// 大 TextEditor，用一个开关按需展开。加载 entry 时若已存在备选内容
    /// 就强制打开——绝不隐藏用户已经填过 / 系统已塞入(如 vision 模型)的
    /// 备选，只清理空框占地。
    @State private var showsAlternates: Bool = false

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
        .onCompatibleChange(of: entry.id) { _, _ in loadFromEntry() }
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
                            .onCompatibleChange(of: displayName) { _, _ in commit() }
                    }
                    fieldRow(L10n.Settings.Provider.presetLabel) {
                        Picker("", selection: $providerID) {
                            ForEach(AgentProviderPreset.all) { p in
                                Text("\(p.displayName) · \(p.kind.shortLabel)").tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .onCompatibleChange(of: providerID) { _, newID in
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
                            .onCompatibleChange(of: baseURL) { _, _ in commit() }
                    }
                    baseURLStatusRow
                    fieldRow(L10n.Settings.Provider.apiKeyLabel) {
                        RevealableSecretField(
                            text: $apiKey,
                            placeholder: "",
                            onCommit: commit
                        )
                        .onCompatibleChange(of: apiKey) { _, _ in commit() }
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
                    Text(L10n.Settings.Provider.protocolOpenAIChat).tag(AgentProviderKind?.some(.openAIChat))
                    Text(L10n.Settings.Provider.protocolAnthropicMessages).tag(AgentProviderKind?.some(.anthropicMessages))
                    Text(L10n.Settings.Provider.protocolGoogleGemini).tag(AgentProviderKind?.some(.geminiGenerateContent))
                    Text(L10n.Settings.Provider.protocolOpenAIResponses).tag(AgentProviderKind?.some(.openAIResponses))
                }
                .labelsHidden()
                .onCompatibleChange(of: customKindOverride) { _, _ in commit() }
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
        case .openAIChat: return "bubble.left.and.bubble.right"
        case .openAIResponses: return "brain"
        case .anthropicMessages: return "a.circle"
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
                        alternatesBinding: $flashAlternatesText,
                        showsAlternates: showsAlternates || !flashAlternatesText.isEmpty
                    )
                    Divider()
                    modelGroup(
                        title: "Pro",
                        primaryBinding: $proPrimary,
                        alternatesBinding: $proAlternatesText,
                        showsAlternates: showsAlternates || !proAlternatesText.isEmpty
                    )
                    Toggle(isOn: $showsAlternates) {
                        Text(L10n.Settings.Provider.showAlternatesToggle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, labelWidth + 8)
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
                        .onCompatibleChange(of: routingMode) { _, _ in commit() }
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
        alternatesBinding: Binding<String>,
        showsAlternates: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow(L10n.Settings.Provider.primarySuffix(title)) {
                modelField(text: primaryBinding)
            }
            if showsAlternates {
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
                            .onCompatibleChange(of: alternatesBinding.wrappedValue) { _, _ in commit() }
                        Text(L10n.Settings.Provider.alternatesHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .onCompatibleChange(of: text.wrappedValue) { _, _ in commit() }
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
        // 已有备选内容的服务商加载时直接展开，避免"填过的备选看不见"。
        showsAlternates = !entry.flashAlternates.isEmpty || !entry.proAlternates.isEmpty
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
        // Skip no-op writes. Every `.onChange(of:)` field fires `commit`,
        // including the bulk reset inside `loadFromEntry` when the editor
        // (re)loads an entry — without this guard that reload would write
        // the just-loaded values straight back, which under instance reuse
        // could clobber a different entry. Only persist a genuine edit.
        guard updated != entry else { return }
        onChange(updated)
    }

    private func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
