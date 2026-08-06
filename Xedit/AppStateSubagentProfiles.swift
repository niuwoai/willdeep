//
//  AppStateSubagentProfiles.swift
//  WillDeep
//
//  Resolving a subagent trade's model binding against the provider library.
//
//  Binding resolution happens at spawn time, never at configuration time.
//  A trade's default binding names some.im's GLM tier, and whether that is
//  usable depends on a login state that changes underneath us — resolving
//  late means signing in or out never requires migrating stored settings,
//  and an unusable binding degrades to the parent's model instead of
//  failing the spawn.
//

import Foundation

extension AppState {
    /// The configuration a trade's child loop should run on.
    ///
    /// Falls back to `parentConfiguration` whenever the binding inherits, the
    /// preferred provider has no usable library entry, or credentials are
    /// missing. Never throws: a cheap trade that cannot reach its cheap model
    /// is a cost regression, not a failed task.
    func resolvedSubagentConfiguration(
        for profile: AgentSubagentProfile,
        parentConfiguration: AgentConfiguration
    ) -> AgentConfiguration {
        let binding = profile.modelBinding
        guard !binding.inheritsEverything else { return parentConfiguration }

        // Model-only override (no provider change): keep the parent's
        // transport and just swap the model id.
        guard let preferredProviderID = binding.preferredProviderID else {
            guard let model = binding.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty else { return parentConfiguration }
            var configuration = parentConfiguration
            configuration.model = model
            return configuration
        }

        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard let entry = agentProviderLibrary.entries.first(where: {
            $0.providerID == preferredProviderID
                && $0.isUsableForChatSelection(isSomeIMAuthenticated: authenticated)
        }) else {
            return parentConfiguration
        }

        // Materialize the key the same way interactive selection does —
        // library entries keep secrets in the Keychain until first use.
        materializeProviderLibraryEntryAPIKey(id: entry.id)
        let materialized = agentProviderLibrary.entries.first { $0.id == entry.id } ?? entry

        var configuration = materialized.makeConfiguration(
            imageDescription: parentConfiguration.imageDescription
        )
        if let model = binding.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            configuration.model = model
        }
        // A trade that ends up without a usable key would fail every round;
        // the parent's configuration is the safer answer.
        if configuration.normalized.requiresAPIKey,
           configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parentConfiguration
        }
        return configuration
    }

    /// Whether a trade will actually get its own binding right now. Drives
    /// the settings row's "unavailable — falls back" hint.
    func subagentProfileBindingIsAvailable(_ profile: AgentSubagentProfile) -> Bool {
        let binding = profile.modelBinding
        if binding.inheritsEverything { return true }
        guard let preferredProviderID = binding.preferredProviderID else { return true }
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        return agentProviderLibrary.entries.contains {
            $0.providerID == preferredProviderID
                && $0.isUsableForChatSelection(isSomeIMAuthenticated: authenticated)
        }
    }
}
