import Foundation

extension AgentConfiguration {
    func validateMagpieConnection() throws {
        if let failure = magpieFailure { throw failure }
        guard magpieConnection != nil else { return }
        _ = try AgentMagpieIntegration.validatedBaseURL(baseURL)
        try AgentMagpieIntegration.validateModel(model)
        guard apiKey == AgentMagpieIntegration.clientMarker,
              providerID == AgentProviderPreset.customID,
              customKindOverride == .openAIChat else { throw AgentMagpieIntegration.Failure(code: .client) }
    }
}
