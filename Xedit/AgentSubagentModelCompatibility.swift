import Foundation

/// Transitional model selection only. Worker instructions belong to the profile,
/// never to a model ID. Remove the base-model default when three-tier routing lands.
nonisolated enum AgentSubagentModelCompatibility {
    static let baseModel = "someim-32b"

    /// The seven legacy aliases that previously injected job prompts on some.im.
    /// This is a compatibility list, not a live inventory or a list to expand.
    static let legacyTradeIDs: Set<String> = [
        "scout", "reader", "editor", "test_fixer",
        "build_fixer", "log_inspector", "git_detective",
    ]

    static let legacyModels: Set<String> = Set(legacyTradeIDs.map {
        "\(baseModel)-\($0.replacingOccurrences(of: "_", with: "-"))"
    })

    static func recommendedModel(for tradeID: String, providerID: String) -> String? {
        guard providerID == AgentProviderPreset.someIMID,
              legacyTradeIDs.contains(tradeID) else { return nil }
        return baseModel
    }

    /// Normalize saved aliases at the request boundary, including Workflow and
    /// parent-model retries. Never rewrite a private endpoint's same-named model,
    /// unknown aliases, or auxiliary compressor/security-judge models.
    static func configuration(_ configuration: AgentConfiguration) -> AgentConfiguration {
        guard configuration.providerID == AgentProviderPreset.someIMID,
              legacyModels.contains(configuration.model.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return configuration }
        var migrated = configuration
        migrated.model = baseModel
        return migrated
    }
}
