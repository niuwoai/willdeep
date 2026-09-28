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
        parentConfiguration: AgentConfiguration,
        sessionID: UUID? = nil
    ) -> AgentConfiguration {
        let requested: String?
        let resolution: (configuration: AgentConfiguration, fallbackReason: AgentModelRouteLog.Reason?)
        if let tier = AgentWorkerTierModels.tier(for: profile.modelBinding) {
            requested = "tier:\(tier.rawValue)"
            switch workerTierResolution(tier, parent: parentConfiguration) {
            case .success(let configuration):
                resolution = (configuration, nil)
            case .failure(let unavailable):
                resolution = (parentConfiguration, unavailable.reason)
            }
        } else {
            requested = profile.modelBinding.model
            let bound = resolveSubagentBinding(for: profile, parentConfiguration: parentConfiguration)
            resolution = (AgentSubagentModelCompatibility.configuration(bound.configuration), bound.fallbackReason)
        }
        // A cheap trade silently running on the parent's model is a cost
        // regression nobody can see; say which trade fell back and why.
        if let reason = resolution.fallbackReason {
            AgentModelRouteLog.record(AgentModelRouteLog.Entry(
                surface: .workerBinding,
                sessionID: sessionID,
                subject: profile.id,
                requested: requested,
                providerID: resolution.configuration.providerID,
                model: resolution.configuration.model,
                fallback: true,
                reason: reason
            ))
        }
        return resolution.configuration
    }

    private func resolveSubagentBinding(
        for profile: AgentSubagentProfile,
        parentConfiguration: AgentConfiguration
    ) -> (configuration: AgentConfiguration, fallbackReason: AgentModelRouteLog.Reason?) {
        let binding = profile.modelBinding
        guard !binding.inheritsEverything else { return (parentConfiguration, nil) }

        // Built-in profiles historically carried `some-im` as an automatic
        // cheap-model default. Do not let that implicit default exfiltrate a
        // private conversation merely because the same Mac is also signed in
        // to some.im. Selecting an exact provider entry in Settings is an
        // explicit override and is therefore still honored.
        if Self.implicitSomeIMBindingFollowsParent(
            binding: binding,
            parentProviderID: parentConfiguration.providerID
        ) {
            return (parentConfiguration, .privateParentKeepsProvider)
        }

        // Model-only override (no provider selection): keep the parent's
        // transport and just swap the model id. New Settings bindings carry
        // an exact provider entry UUID; legacy bindings may carry only the
        // preset id.
        guard binding.preferredProviderEntryID != nil || binding.preferredProviderID != nil else {
            guard let model = binding.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty else { return (parentConfiguration, nil) }
            var configuration = parentConfiguration
            configuration.model = model
            return (configuration, nil)
        }

        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard let entry = AgentSubagentProfileCatalog.providerEntry(
            for: binding,
            in: agentProviderLibrary
        ), entry.isUsableForChatSelection(isSomeIMAuthenticated: authenticated) else {
            return (parentConfiguration, .providerUnavailable)
        }

        // Materialize the key the same way interactive selection does —
        // library entries keep secrets in the Keychain until first use.
        materializeProviderLibraryEntryAPIKey(id: entry.id)
        let materialized = agentProviderLibrary.entries.first { $0.id == entry.id } ?? entry

        var configuration = materialized.makeConfiguration(
            imageDescription: parentConfiguration.imageDescription
        )
        if AgentSubagentProfileCatalog.bindingModelApplies(binding, to: entry) {
            let model = binding.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !model.isEmpty {
                configuration.model = model
            } else if let recommended = AgentSubagentModelCompatibility.recommendedModel(
                for: profile.id, providerID: entry.providerID
            ) {
                configuration.model = recommended
            }
        }
        // A trade that ends up without a usable key would fail every round;
        // the parent's configuration is the safer answer.
        if configuration.normalized.requiresAPIKey,
           configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (parentConfiguration, .missingAPIKey)
        }
        return (configuration, nil)
    }

    /// Whether a trade will actually get its own binding right now. Drives
    /// the settings row's "unavailable — falls back" hint.
    func subagentProfileBindingIsAvailable(_ profile: AgentSubagentProfile) -> Bool {
        if let tier = AgentWorkerTierModels.tier(for: profile.modelBinding) {
            return workerTierConfiguration(tier, parent: agentConfiguration) != nil
        }
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
