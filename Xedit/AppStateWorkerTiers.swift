import Foundation

extension AppState {
    /// The app's stored tier bindings with `[worker_tiers.*]` from the shared
    /// `~/.willdeep/config.toml` layered on top.
    ///
    /// One merged value on purpose: the dispatch path and the context budget
    /// both ask which model a tier means, and they must not be able to
    /// disagree. See [`AgentWorkerTierSharedConfig`] for why the file wins.
    func effectiveWorkerTierModels(
        stored: AgentWorkerTierModels? = nil,
        shared: AgentWorkerTierSharedConfig? = nil
    ) -> AgentWorkerTierModels {
        AgentWorkerTierModels.merging(
            stored: stored ?? AgentProfileStore().workerTierModels(),
            shared: shared ?? AgentWorkerTierSharedConfig.cached(),
            resolveProviderPreset: workerTierProviderResolver()
        )
    }

    /// Maps a `[providers.<name>].provider` preset id onto a provider library
    /// entry this machine can actually sign requests with. An entry that is
    /// not usable for chat selection is no better than a missing one.
    func workerTierProviderResolver() -> AgentWorkerTierModels.ProviderResolver {
        let isSomeIMAuthenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        let entries = agentProviderLibrary.entries
        return { preset in
            entries.first {
                $0.providerID == preset
                    && $0.isUsableForChatSelection(isSomeIMAuthenticated: isSomeIMAuthenticated)
            }
            .map { ($0.id, $0.providerID) }
        }
    }

    /// Whether this tier is pinned by the shared config.toml rather than by
    /// the app's own settings — and if so, whether this machine can reach what
    /// the file names. The settings pane needs both halves: an editor that
    /// silently does nothing is worse than one that says why.
    func workerTierFileBinding(
        _ tier: AgentWorkerTier
    ) -> (entry: AgentWorkerTierSharedConfig.Entry, resolved: Bool)? {
        let file = AgentWorkerTierSharedConfig.cached()
        guard let entry = file[tier], entry.hasModel else { return nil }
        let binding = AgentWorkerTierModels.binding(
            for: entry, in: file, resolveProviderPreset: workerTierProviderResolver()
        )
        return (entry, binding.model != nil)
    }

    /// A missing explicit endpoint never falls through to another account.
    /// Automatic defaults are some.im-only; private parents stay private.
    func workerTierConfiguration(
        _ tier: AgentWorkerTier,
        parent: AgentConfiguration,
        models: AgentWorkerTierModels? = nil
    ) -> AgentConfiguration? {
        let binding = (models ?? effectiveWorkerTierModels())[tier]
        let model = binding.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else { return nil }
        var configuration: AgentConfiguration
        if let entryID = binding.preferredProviderEntryID {
            guard let entry = agentProviderLibrary.entries.first(where: { $0.id == entryID }),
                  entry.isUsableForChatSelection(
                    isSomeIMAuthenticated: SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
                  ) else { return nil }
            materializeProviderLibraryEntryAPIKey(id: entry.id)
            let materialized = agentProviderLibrary.entries.first { $0.id == entry.id } ?? entry
            configuration = materialized.makeConfiguration(imageDescription: parent.imageDescription)
        } else {
            guard binding.preferredProviderID == nil || binding.preferredProviderID == parent.providerID else {
                return nil
            }
            configuration = parent
        }
        configuration.model = model
        configuration = AgentSubagentModelCompatibility.configuration(configuration)
        guard !configuration.normalized.requiresAPIKey || !configuration.apiKey.isEmpty else { return nil }
        return configuration
    }

    func nextWorkerTierConfiguration(
        for profile: AgentSubagentProfile,
        current: AgentConfiguration,
        parent: AgentConfiguration,
        models: AgentWorkerTierModels? = nil
    ) -> (tier: AgentWorkerTier, configuration: AgentConfiguration)? {
        guard let tier = AgentWorkerTierModels.tier(for: profile.modelBinding),
              let next = tier.next,
              let original = workerTierConfiguration(tier, parent: parent, models: models),
              Self.sameWorkerModel(original, current),
              let target = workerTierConfiguration(next, parent: parent, models: models),
              !Self.sameWorkerModel(current, target) else { return nil }
        return (next, target)
    }

    nonisolated static func sameWorkerModel(_ lhs: AgentConfiguration, _ rhs: AgentConfiguration) -> Bool {
        lhs.providerID == rhs.providerID && lhs.baseURL == rhs.baseURL && lhs.model == rhs.model
    }
}
