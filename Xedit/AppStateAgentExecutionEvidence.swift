import Foundation

extension AppState {
    @MainActor func runAgentLoop(for runtime: AgentRuntime, configuration: AgentConfiguration,
                                providerSlotClaimID: UUID, turnID: UUID) async {
        var trace = AgentExecutionTrace.root(sessionID: runtime.id, turnID: turnID, configuration: configuration)
        trace.seed.runtimeParameters = runtime.runtimeParameters ?? (try? runtimeParametersForNewTurn())
        await AgentExecutionTrace.$current.withValue(trace) {
            await runAgentLoopBody(for: runtime, configuration: configuration,
                providerSlotClaimID: providerSlotClaimID, turnID: turnID)
        }
    }
}
