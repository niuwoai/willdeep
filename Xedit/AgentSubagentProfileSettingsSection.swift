//
//  AgentSubagentProfileSettingsSection.swift
//  WillDeep
//
//  Settings surface for subagent trades: which model each trade runs on.
//
//  Only the model binding is editable. Tool sets, prompts and budgets are
//  code, not configuration — a trade's narrow tool set is what makes it
//  cheap and accurate, and the read-only boundary is a safety property, so
//  neither is something to hand to a settings pane. The tool list is shown
//  read-only so the trade-off stays legible.
//

import SwiftUI

struct AgentSubagentProfileSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var overrides = AgentSubagentProfileStore.loadOverrides()
    @State private var fetchedModelsByProvider: [UUID: [String]] = [:]
    @State private var loadingProviderIDs: Set<UUID> = []
    @State private var fetchMessagesByProvider: [UUID: String] = [:]

    private var profiles: [AgentSubagentProfile] {
        AgentSubagentProfileCatalog.applyingOverrides(overrides)
    }

    var body: some View {
        ForEach(profiles) { profile in
            profileRow(profile)
        }
        Text(L10n.AgentDelegation.profilesSectionFooter)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func profileRow(_ profile: AgentSubagentProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(profile.localizedDisplayName)
                    .font(.subheadline.weight(.medium))
                Text("`\(profile.id)`")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            Text(profile.localizedPurpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent(L10n.AgentDelegation.profileProviderLabel) {
                Picker(
                    L10n.AgentDelegation.profileProviderLabel,
                    selection: providerEntryBinding(for: profile)
                ) {
                    if appState.agentProviderLibrary.entries.isEmpty {
                        Text(L10n.AgentDelegation.profileNoProviders)
                            .tag(Optional<UUID>.none)
                    } else {
                        ForEach(appState.agentProviderLibrary.entries) { entry in
                            Text(entry.displayName)
                                .tag(Optional(entry.id))
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(appState.agentProviderLibrary.entries.isEmpty)
            }

            LabeledContent(L10n.AgentDelegation.profileModelLabel) {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        TextField(
                            L10n.AgentDelegation.profileModelPlaceholder,
                            text: modelBinding(for: profile)
                        )
                        .textFieldStyle(.roundedBorder)

                        Menu {
                            ForEach(modelOptions(for: profile), id: \.self) { model in
                                Button(model) {
                                    modelBinding(for: profile).wrappedValue = model
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 16, height: 16)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .disabled(modelOptions(for: profile).isEmpty)
                        .help(L10n.AgentDelegation.profilePickFetchedModel)

                        Button {
                            fetchModels(for: profile)
                        } label: {
                            if isFetchingModels(for: profile) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(selectedProviderEntry(for: profile) == nil || isFetchingModels(for: profile))
                        .help(L10n.Settings.Provider.fetchModels)
                    }
                    .frame(maxWidth: 340)

                    if let message = fetchMessage(for: profile), !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !profile.modelBinding.inheritsEverything,
                       !appState.subagentProfileBindingIsAvailable(profile) {
                        // Not an error: an unusable binding silently runs on
                        // the parent's model. Saying so beats a user
                        // wondering why the cheap trade never got cheaper.
                        Text(L10n.AgentDelegation.profileUnavailableFallback)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent(L10n.AgentDelegation.profileToolsLabel) {
                Text(profile.toolNames.sorted().joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func currentBinding(for profile: AgentSubagentProfile) -> AgentSubagentProfile.ModelBinding {
        overrides[profile.id] ?? AgentSubagentProfileCatalog.profile(id: profile.id).modelBinding
    }

    private func selectedProviderEntry(for profile: AgentSubagentProfile) -> AgentProviderEntry? {
        AgentSubagentProfileCatalog.providerEntry(
            for: currentBinding(for: profile),
            in: appState.agentProviderLibrary
        )
            ?? AgentSubagentProfileCatalog.defaultProviderEntry(in: appState.agentProviderLibrary)
    }

    private func providerEntryBinding(for profile: AgentSubagentProfile) -> Binding<UUID?> {
        Binding(
            get: { selectedProviderEntry(for: profile)?.id },
            set: { entryID in
                guard let entryID,
                      let entry = appState.agentProviderLibrary.entries.first(where: { $0.id == entryID }) else {
                    return
                }
                var binding = currentBinding(for: profile)
                let changedProvider = binding.preferredProviderEntryID != entry.id
                binding.preferredProviderEntryID = entry.id
                binding.preferredProviderID = entry.providerID
                if changedProvider {
                    binding.model = entry.flashPrimary
                    binding.contextWindowTokens = nil
                }
                overrides[profile.id] = binding
                AgentSubagentProfileStore.saveOverrides(overrides)
                appState.materializeProviderLibraryEntryAPIKey(id: entry.id)
            }
        )
    }

    /// The text field is deliberately free-form. The adjacent menu is only a
    /// convenience filled by the provider's configured models and `/models`
    /// response; it never prevents a user from typing a model ID manually.
    private func modelBinding(for profile: AgentSubagentProfile) -> Binding<String> {
        Binding(
            get: {
                let binding = currentBinding(for: profile)
                if let entry = selectedProviderEntry(for: profile),
                   !AgentSubagentProfileCatalog.bindingModelApplies(binding, to: entry) {
                    return entry.flashPrimary
                }
                return binding.model ?? selectedProviderEntry(for: profile)?.flashPrimary ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var binding = currentBinding(for: profile)
                if let entry = selectedProviderEntry(for: profile) {
                    binding.preferredProviderEntryID = entry.id
                    binding.preferredProviderID = entry.providerID
                }
                binding.model = trimmed.isEmpty ? nil : trimmed
                binding.contextWindowTokens = nil
                overrides[profile.id] = binding
                AgentSubagentProfileStore.saveOverrides(overrides)
            }
        )
    }

    private func modelOptions(for profile: AgentSubagentProfile) -> [String] {
        guard let entry = selectedProviderEntry(for: profile) else { return [] }
        let candidates = entry.allFlashModels
            + entry.allProModels
            + (fetchedModelsByProvider[entry.id] ?? [])
        var seen = Set<String>()
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func isFetchingModels(for profile: AgentSubagentProfile) -> Bool {
        guard let entryID = selectedProviderEntry(for: profile)?.id else { return false }
        return loadingProviderIDs.contains(entryID)
    }

    private func fetchMessage(for profile: AgentSubagentProfile) -> String? {
        guard let entryID = selectedProviderEntry(for: profile)?.id else { return nil }
        return fetchMessagesByProvider[entryID]
    }

    private func fetchModels(for profile: AgentSubagentProfile) {
        guard let entry = selectedProviderEntry(for: profile),
              !loadingProviderIDs.contains(entry.id) else { return }
        loadingProviderIDs.insert(entry.id)
        fetchMessagesByProvider[entry.id] = L10n.Settings.Provider.fetchingModels
        appState.materializeProviderLibraryEntryAPIKey(id: entry.id)
        let resolvedEntry = appState.agentProviderLibrary.entries.first(where: { $0.id == entry.id }) ?? entry

        Task { @MainActor in
            defer { loadingProviderIDs.remove(entry.id) }
            do {
                let discoveries = try await fetchModelDiscoveries(for: resolvedEntry)
                let models = discoveries.map(\.id)
                fetchedModelsByProvider[entry.id] = models
                appState.recordFetchedAgentModelDiscoveries(discoveries)
                fetchMessagesByProvider[entry.id] = models.isEmpty
                    ? L10n.AgentDelegation.profileNoModelsReturned
                    : L10n.AgentDelegation.profileFetchedModels(models.count, resolvedEntry.displayName)
            } catch {
                fetchedModelsByProvider[entry.id] = []
                fetchMessagesByProvider[entry.id] = error.localizedDescription
            }
        }
    }

    private func fetchModelDiscoveries(for entry: AgentProviderEntry) async throws -> [AgentModelDiscovery] {
        let configuration = entry.makeConfiguration().normalized
        do {
            return try await AgentClient(configuration: configuration).fetchModelDiscoveries()
        } catch let originalError {
            guard AgentProviderBaseURLV1Probe.shouldRetry(after: originalError),
                  let candidate = AgentProviderBaseURLV1Probe.candidate(
                    baseURL: configuration.baseURL,
                    providerKind: configuration.providerKind
                  ) else {
                throw originalError
            }
            var candidateConfiguration = configuration
            candidateConfiguration.baseURL = candidate.baseURL
            do {
                return try await AgentClient(configuration: candidateConfiguration).fetchModelDiscoveries()
            } catch {
                throw originalError
            }
        }
    }
}
