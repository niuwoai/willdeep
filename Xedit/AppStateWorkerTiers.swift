import Foundation

extension AppState {
    /// A missing explicit endpoint never falls through to another account.
    /// Automatic defaults are some.im-only; private parents stay private.
    func workerTierConfiguration(
        _ tier: AgentWorkerTier,
        parent: AgentConfiguration,
        models: AgentWorkerTierModels? = nil
    ) -> AgentConfiguration? {
        let binding = (models ?? AgentProfileStore().workerTierModels())[tier]
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
