import Foundation

nonisolated enum AgentContextCompressionReclamation {
    /// Leave room for the next tools and answer, rather than merely falling
    /// just below the 90% handoff threshold.
    static let targetUsedFraction = 0.75
    static let unknownSystemPromptReserveFraction = 0.25

    static func accepts(sourceTokens: Int, summaryTokens: Int, projectedTokens: Int, window: Int) -> Bool {
        guard sourceTokens > 0, summaryTokens > 0, window > 0,
              summaryTokens < sourceTokens, projectedTokens >= summaryTokens else { return false }
        return Double(projectedTokens) <= Double(window) * targetUsedFraction
    }
}

nonisolated struct AgentCompressionReclamationError: LocalizedError {
    let projectedTokens: Int
    let contextWindow: Int

    var errorDescription: String? {
        String(localized: "agent.compression.insufficient-reclamation", defaultValue: "The summary did not reclaim enough context. The original conversation and previous summary were preserved.")
    }
}

extension AppState {
    /// Compute against the *consumer* model, not the model used to summarize.
    /// Keep the candidate private until validated, so failed compression never
    /// destroys the previous usable checkpoint or races a foreground switch.
    func projectedTokensAfterCompression(
        for runtime: AgentRuntime,
        summary: String,
        through messageID: AgentMessage.ID?,
        checkpointText: String? = nil
    ) -> Int {
        let history = Self.modelFacingHistory(
            messages: runtime.messages,
            contextSummary: summary,
            contextSummaryThroughMessageID: messageID,
            checkpointText: checkpointText
        )
        let tools = AgentToolRegistry.tools(
            activeExperts: runtime.activeExperts,
            interactionMode: runtime.interactionMode,
            executionAgent: runtime.executionAgent,
            delegationPolicy: runtime.currentTurnDelegationPolicy,
            loadedPacks: runtime.loadedToolPacks
        )
        let systemTokens = runtime.contextSystemPromptTokenEstimate
            ?? Int(Double(agentContextWindow(for: runtime)) * AgentContextCompressionReclamation.unknownSystemPromptReserveFraction)
        return systemTokens + Self.estimateAgentTokens(
            messages: Self.collapseOldToolResults(in: history), tools: tools
        )
    }
}
