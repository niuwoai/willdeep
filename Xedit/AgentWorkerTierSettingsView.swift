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
                    tierEditor(tier)
                } label: {
                    HStack {
                        Text(tier.title)
                        Spacer()
                        Text(models[tier].model ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { models = store.workerTierModels() }
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
            Text("128K").tag(AgentWorkerTierModels.standardWindow)
            Text("256K").tag(AgentWorkerTierModels.extendedWindow)
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
        Binding(get: { models[tier].contextWindowTokens ?? AgentWorkerTierModels.standardWindow }, set: {
            models[tier].contextWindowTokens = $0
            persist()
        })
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
