import Foundation

nonisolated enum AgentWorkerContextBudget {
    static let outputReserve = 16_384

    struct Exceeded: LocalizedError {
        let used: Int
        let limit: Int
        var errorDescription: String? {
            "Worker context window budget exceeded (estimated input \(used), limit \(limit)). Split the task or select a tier with a larger supported window; no task instructions were discarded."
        }
    }

    static func inputLimit(
        profile: AgentSubagentProfile,
        configuration: AgentConfiguration,
        models: AgentWorkerTierModels
    ) -> Int {
        let declared = AgentWorkerTierModels.tier(for: profile.modelBinding).map {
            models[$0].contextWindowTokens ?? AgentWorkerTierModels.standardWindow
        } ?? profile.modelBinding.contextWindowTokens ?? AgentWorkerTierModels.standardWindow
        let supported = AppState.agentContextWindow(model: configuration.model, providerID: configuration.providerID)
        let window = max(1, min(declared, supported))
        // Reserve output and estimator headroom. A budget never fabricates a
        // provider's capacity or silently truncates the original task/prompt.
        return max(1, window - min(outputReserve, window / 4) - window / 10)
    }

    static func validate(messages: [AgentMessage], tools: [AgentToolDescriptor], limit: Int) throws {
        let used = AppState.estimateAgentTokens(messages: messages, tools: tools)
        guard used <= limit else { throw Exceeded(used: used, limit: limit) }
    }
}
