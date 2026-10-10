import Foundation

extension AppState {
    func pauseForMainLoopStagnation(_ runtime: AgentRuntime) {
        runtime.feedbackBudgetStopReason = "no_progress"
        runtime.session.automaticWakeSuppressedAfterUserStop = true
        runtime.errorSeverity = .notice
        runtime.errorMessage = String(localized: "runtime-parameters.no-progress",
            defaultValue: "Execution paused after repeated failures or no new tool results. Review the blocker before continuing.")
        runtime.errorDetails = nil
        runtime.recordFeedback("runtime_stalled") { $0.stopReason = "no_progress" }
    }

    func runtimeParametersForNewTurn() throws -> AgentRuntimeParameters {
        let parameters = try agentLoopRuntimeParametersOverride ?? AgentRuntimeParameters.resolve()
        try parameters.validate()
        return parameters
    }

    func applySharedGoalLimits(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .goal,
              var goal = runtime.currentGoal, var parameters = runtime.runtimeParameters else { return }
        var budget = goal.continuationBudget ?? .standard
        if budget.activeElapsedSeconds == nil {
            budget.activeElapsedSeconds = budget.elapsed(at: Date())
            budget.segmentStartedAt = nil
        }
        if runtime.isResponding && budget.segmentStartedAt == nil { budget.segmentStartedAt = Date() }
        let clock = TimeInterval(parameters.goalWallClockMinutes * 60)
        budget.wallClockLimit = min(budget.wallClockLimit ?? clock, clock)
        budget.maximumContinuations = min(budget.maximumContinuations, parameters.goalMaxContinuations)
        parameters.goalWallClockMinutes = max(1, Int(ceil((budget.wallClockLimit ?? clock) / 60)))
        parameters.goalMaxContinuations = max(1, budget.maximumContinuations)
        goal.continuationBudget = budget
        runtime.currentGoal = goal
        if let ledger = modelRequestLedger(for: runtime) {
            do {
                let policy = try ledger.admissionPolicy()
                let effective = parameters.goalTokenBudget.map { min(policy.tokenLimit ?? $0, $0) } ?? policy.tokenLimit
                if policy.tokenLimit != effective {
                    try ledger.setAdmissionLimit(effective, expectedRevision: policy.revision)
                }
                // Legacy owner limits can be tighter than v1 permits (for
                // example one remaining token). Keep those in the ledger,
                // without producing a JSON profile that cannot be reloaded.
                if let effective, (1000...10_000_000).contains(effective) {
                    parameters.goalTokenBudget = effective
                }
            } catch {
                runtime.session.automaticWakeSuppressedAfterUserStop = true
                runtime.errorMessage = error.localizedDescription
                runtime.runtimeParameters = nil
                return
            }
        }
        runtime.runtimeParameters = parameters
    }

    func pauseForRuntimeBudget(_ runtime: AgentRuntime, reason: String) {
        runtime.feedbackBudgetStopReason = reason
        runtime.session.automaticWakeSuppressedAfterUserStop = true
        runtime.errorSeverity = .notice
        runtime.errorMessage = String(localized: "runtime-parameters.budget-paused",
            defaultValue: "The runtime budget was reached. Review the partial result before continuing.")
        runtime.errorDetails = nil
        runtime.recordFeedback("runtime_budget_limited") { $0.stopReason = reason }
    }
}
