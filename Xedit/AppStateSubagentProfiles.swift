//
//  AppStateSubagentProfiles.swift
//  WillDeep
//
//  Resolving a subagent trade's model binding against the provider library.
//
//  Binding resolution happens at spawn time, never at configuration time.
//  A trade's legacy default binding names some.im's GLM tier. That default is
//  used only when the parent conversation itself uses some.im; a private or
//  on-prem parent keeps every implicit worker on the same provider. An exact
//  provider entry chosen by the user is explicit and remains authoritative.
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
        // Managed trades: while the parent itself uses some.im, the model is
        // pinned to the virtual model that carries this trade's server-side
        // job prompt, so the prompt and the model tuned for it travel together
        // (docs/SOMEIM_WORKER_VIRTUAL_MODELS.md §3.8).
        if let hosted = resolvedHostedConfiguration(
            for: profile,
            parentConfiguration: parentConfiguration
        ) {
            return hosted
        }

        let binding = profile.modelBinding
        guard !binding.inheritsEverything else { return parentConfiguration }

        // Built-in profiles historically carried `some-im` as an automatic
        // cheap-model default. Do not let that implicit default exfiltrate a
        // private conversation merely because the same Mac is also signed in
        // to some.im. Selecting an exact provider entry in Settings is an
        // explicit override and is therefore still honored.
        if Self.implicitSomeIMBindingFollowsParent(
            binding: binding,
            parentProviderID: parentConfiguration.providerID
        ) {
            return parentConfiguration
        }

        // Model-only override (no provider selection): keep the parent's
        // transport and just swap the model id. New Settings bindings carry
        // an exact provider entry UUID; legacy bindings may carry only the
        // preset id.
        guard binding.preferredProviderEntryID != nil || binding.preferredProviderID != nil else {
            guard let model = binding.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty else { return parentConfiguration }
            var configuration = parentConfiguration
            configuration.model = model
            return configuration
        }

        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard let entry = AgentSubagentProfileCatalog.providerEntry(
            for: binding,
            in: agentProviderLibrary
        ), entry.isUsableForChatSelection(isSomeIMAuthenticated: authenticated) else {
            return parentConfiguration
        }

        // Materialize the key the same way interactive selection does —
        // library entries keep secrets in the Keychain until first use.
        materializeProviderLibraryEntryAPIKey(id: entry.id)
        let materialized = agentProviderLibrary.entries.first { $0.id == entry.id } ?? entry

        var configuration = materialized.makeConfiguration(
            imageDescription: parentConfiguration.imageDescription
        )
        if AgentSubagentProfileCatalog.bindingModelApplies(binding, to: entry),
           let model = binding.model?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    /// Whether this trade's model and job prompt are currently owned by
    /// some.im. Login alone is insufficient: private parent configurations
    /// remain private.
    func subagentTradeIsHosted(
        _ profile: AgentSubagentProfile,
        parentConfiguration: AgentConfiguration
    ) -> Bool {
        parentConfiguration.providerID == AgentProviderPreset.someIMID
            && profile.usesHostedJobPrompt(
            someIMAuthenticated: SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        )
    }

    /// The pinned configuration for a hosted trade, or nil when the trade is
    /// not hosted or some.im has no usable entry right now (signed out, key
    /// revoked, entry deleted) — in which case the caller continues down the
    /// normal user-configurable path.
    private func resolvedHostedConfiguration(
        for profile: AgentSubagentProfile,
        parentConfiguration: AgentConfiguration
    ) -> AgentConfiguration? {
        guard subagentTradeIsHosted(
            profile,
            parentConfiguration: parentConfiguration
        ),
              let hostedModel = profile.hostedVirtualModel else { return nil }
        guard let entry = agentProviderLibrary.entries
            .first(where: { $0.providerID == AgentProviderPreset.someIMID }),
              entry.isUsableForChatSelection(isSomeIMAuthenticated: true) else { return nil }

        materializeProviderLibraryEntryAPIKey(id: entry.id)
        let materialized = agentProviderLibrary.entries.first { $0.id == entry.id } ?? entry
        var configuration = materialized.makeConfiguration(
            imageDescription: agentConfiguration.imageDescription
        )
        configuration.model = hostedModel
        guard !configuration.normalized.requiresAPIKey
            || !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return configuration
    }

    /// Whether a trade will actually get its own binding right now. Drives
    /// the settings row's "unavailable — falls back" hint.
    func subagentProfileBindingIsAvailable(_ profile: AgentSubagentProfile) -> Bool {
        let binding = profile.modelBinding
        if binding.inheritsEverything { return true }
        guard binding.preferredProviderEntryID != nil || binding.preferredProviderID != nil else {
            return true
        }
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        return AgentSubagentProfileCatalog.providerEntry(
            for: binding,
            in: agentProviderLibrary
        )?.isUsableForChatSelection(isSomeIMAuthenticated: authenticated) == true
    }

    nonisolated static func implicitSomeIMBindingFollowsParent(
        binding: AgentSubagentProfile.ModelBinding,
        parentProviderID: String
    ) -> Bool {
        binding.preferredProviderEntryID == nil
            && binding.preferredProviderID == AgentProviderPreset.someIMID
            && parentProviderID != AgentProviderPreset.someIMID
    }
}
