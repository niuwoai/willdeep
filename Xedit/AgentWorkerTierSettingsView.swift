import SwiftUI

struct AgentWorkerTierSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var models = AgentWorkerTierModels()
    var onSave: () -> Void = {}
    private let store = AgentProfileStore()

    var body: some View {
        Section {
            Text(String(localized: "三档模型", table: "WorkerArchitecture"))
                .font(.headline)
            Text(String(localized: "模型按能力分档，职责只决定工作方式和权限。上下文预算不代表模型智力，也不会突破模型实际窗口。", table: "WorkerArchitecture"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(AgentWorkerTier.allCases) { tier in
                DisclosureGroup {
                    tierBody(tier)
                } label: {
                    tierLabel(tier)
                }
            }
        }
        .onAppear {
            // The file may have been edited in another window since this pane
            // was last opened; the app never writes it, so it is the only one
            // of the two sides that can change behind our back.
            AgentWorkerTierSharedConfig.invalidateCache()
            models = store.workerTierModels()
        }
    }

    @ViewBuilder
    private func tierBody(_ tier: AgentWorkerTier) -> some View {
        if let pinned = appState.workerTierFileBinding(tier) {
            pinnedEditor(entry: pinned.entry, resolved: pinned.resolved)
        } else {
            tierEditor(tier)
        }
    }

    @ViewBuilder
    private func tierLabel(_ tier: AgentWorkerTier) -> some View {
        let pinned = appState.workerTierFileBinding(tier)
        HStack {
            Text(tier.title)
            Spacer()
            if let pinned {
                Image(systemName: pinned.resolved ? "doc.text" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(pinned.resolved ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
            Text(pinned?.entry.model ?? models[tier].model ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A tier pinned by the shared config.toml. The editors are not shown at
    /// all rather than shown disabled: the values here would be the app's
    /// stored ones, not the file's, so an editable-looking field would be
    /// displaying one answer while dispatch used another.
    @ViewBuilder
    private func pinnedEditor(
        entry: AgentWorkerTierSharedConfig.Entry,
        resolved: Bool
    ) -> some View {
        LabeledContent(L10n.AgentProfiles.fieldModel) {
            Text(entry.model ?? "—").textSelection(.enabled)
        }
        if let profile = entry.providerProfile {
            LabeledContent(L10n.AgentProfiles.fieldProvider) {
                Text(profile).textSelection(.enabled)
            }
        }
        if let window = entry.contextWindowTokens {
            LabeledContent(L10n.AgentProfiles.fieldContextWindow) {
                Text(String(window))
            }
        }
        Text(String(
            localized: "这一档由 ~/.willdeep/config.toml 的 [worker_tiers] 固定，命令行与 App 用同一个答案。要在这里编辑，先从配置文件里删掉这一段。",
            table: "WorkerArchitecture"
        ))
        .font(.caption).foregroundStyle(.secondary)
        if !resolved, let profile = entry.providerProfile {
            Text(String(
                localized: "配置文件指定的提供商 “\(profile)” 在本机没有可用的对应条目，这一档暂时派不出去。补上该提供商，或改用不指定提供商的写法以沿用当前会话的端点。",
                table: "WorkerArchitecture"
            ))
            .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func tierEditor(_ tier: AgentWorkerTier) -> some View {
        Picker(L10n.AgentProfiles.fieldProvider, selection: providerBinding(tier)) {
            Text(models[tier].preferredProviderID == AgentProviderPreset.someIMID
                ? String(localized: "自动（仅 some.im 会话）", table: "WorkerArchitecture")
                : String(localized: "跟随当前提供商", table: "WorkerArchitecture"))
                .tag(Optional<UUID>.none)
            ForEach(appState.agentProviderLibrary.entries) { entry in
                Text(entry.displayName).tag(Optional(entry.id))
            }
        }
        HStack {
            TextField(L10n.AgentProfiles.fieldModel, text: modelBinding(tier))
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(modelOptions(tier), id: \.self) { model in
                    Button(model) { modelBinding(tier).wrappedValue = model }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(modelOptions(tier).isEmpty)
        }
        Picker(L10n.AgentProfiles.fieldContextWindow, selection: contextBinding(tier)) {
            ForEach(contextWindowOptions(tier), id: \.self) { window in
                Text(AgentWorkerTierModels.windowLabel(window)).tag(window)
            }
        }
        Text(String(localized: "配置可用不等于实测通过；请使用提供商支持的模型 ID。未配置的私有提供商不会自动转发到 some.im。", table: "WorkerArchitecture"))
            .font(.caption).foregroundStyle(.secondary)
        Button(String(localized: "恢复此档默认配置", table: "WorkerArchitecture")) {
            models[tier] = AgentWorkerTierModels.defaultBinding(tier)
            persist()
        }
    }

    private func providerBinding(_ tier: AgentWorkerTier) -> Binding<UUID?> {
        Binding(get: { models[tier].preferredProviderEntryID }, set: { id in
            models[tier].preferredProviderEntryID = id
            models[tier].preferredProviderID = id.flatMap { id in
                appState.agentProviderLibrary.entries.first { $0.id == id }?.providerID
            }
            // Models are endpoint-specific; never carry an old provider's ID
            // into a newly selected endpoint without a deliberate choice.
            models[tier].model = nil
            persist()
        })
    }

    private func modelBinding(_ tier: AgentWorkerTier) -> Binding<String> {
        Binding(get: { models[tier].model ?? "" }, set: {
            models[tier].model = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            persist()
        })
    }

    private func contextBinding(_ tier: AgentWorkerTier) -> Binding<Int> {
        Binding(get: { models[tier].contextWindowTokens ?? AgentWorkerTierModels.extendedWindow }, set: {
            models[tier].contextWindowTokens = $0
            persist()
        })
    }

    /// A value stored by an older build, or merged in from config.toml, may
    /// not be one of the offered budgets. It is kept in the list so the picker
    /// shows what dispatch actually uses instead of rendering blank.
    private func contextWindowOptions(_ tier: AgentWorkerTier) -> [Int] {
        let current = contextBinding(tier).wrappedValue
        var options = AgentWorkerTierModels.selectableWindows
        if !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options
    }

    private func modelOptions(_ tier: AgentWorkerTier) -> [String] {
        let binding = models[tier]
        let entry = binding.preferredProviderEntryID.flatMap { id in
            appState.agentProviderLibrary.entries.first { $0.id == id }
        } ?? appState.agentProviderLibrary.entries.first {
            $0.providerID == (binding.preferredProviderID ?? appState.agentConfiguration.providerID)
        }
        return entry.map { AgentExecutionProfileModelCatalog.models(for: $0) } ?? []
    }

    private func persist() {
        store.save(workerTierModels: models)
        onSave()
    }
}
