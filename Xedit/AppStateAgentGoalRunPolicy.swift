import Foundation

/// One continuation authority for mechanical segment boundaries. A segment
/// ending is not task completion, and it never overrides Stop or human input.
nonisolated enum AgentGoalRunBoundary: String {
    case planRoundLimit
    case toolRoundLimit
    case contextCompaction

    var instruction: String {
        switch self {
        case .planRoundLimit:
            return "The plan continuation segment ended; continue only remaining work."
        case .toolRoundLimit:
            return "The bounded tool-call segment ended. Tool receipts and workspace state survive; continue from them without replaying successful mutations."
        case .contextCompaction:
            return "Context compression completed. Resume the handover's REMAINING work; reuse verified evidence only while its input files and revision remain unchanged. Reconcile stale anchors before acting."
        }
    }
}

extension AppState {
    /// Refuse the entire proposed batch before approval cards or subagents are
    /// created. Only one host wrap-up turn is queued; an ignored wrap-up must
    /// not burn hundreds of tool rounds or repeatedly ask the user to approve.
    func stopExpiredGoalToolRound(for runtime: AgentRuntime, assistantID: UUID) -> Bool {
        guard let envelope = toolExecutionBudget(for: runtime) else { return false }
        do { try envelope.check(); return false }
        catch { return queueGoalBudgetWrapUp(for: runtime, assistantID: assistantID) }
    }

    private func queueGoalBudgetWrapUp(for runtime: AgentRuntime, assistantID: UUID) -> Bool {
        guard var goal = runtime.currentGoal else { return false }
        var budget = goal.continuationBudget ?? .standard
        let shouldQueueWrapUp = !budget.wrapUpDispatched
        budget.wrapUpDispatched = true
        goal.continuationBudget = budget
        runtime.currentGoal = goal
        if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
            runtime.messages[index].toolCalls = []
            if runtime.messages[index].content.isEmpty, runtime.messages[index].images.isEmpty,
               (runtime.messages[index].reasoningContent ?? "").isEmpty {
                runtime.messages.remove(at: index)
                AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
            }
        }
        runtime.errorMessage = L10n.GoalPlanning.budgetExhausted
        runtime.errorDetails = nil
        runtime.errorSeverity = .notice
        if shouldQueueWrapUp, !runtime.queuedMessages.contains(where: { $0.source == .operatorInput }) {
            runtime.queuedMessages.append(AgentQueuedMessage(
                text: AgentGoalContinuationPolicy.wrapUpPrompt(remainingAcceptance: goal.checklist.filter { !$0.done }.map(\.text)),
                images: [], executionAgent: runtime.executionAgent, source: .hostInstruction
            ))
        }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        return true
    }

    func toolExecutionBudget(for runtime: AgentRuntime) -> AgentToolExecutionBudget? {
        guard runtime.interactionMode == .goal, !runtime.currentTurnPlanningOnly,
              let budget = runtime.currentGoal?.continuationBudget else { return nil }
        return AgentToolExecutionBudget(budget: budget, requestLedger: modelRequestLedger(for: runtime),
            ownerGate: requestOwnerGate(for: runtime))
    }

    func modelRequestLedger(for runtime: AgentRuntime) -> AgentModelRequestLedger? {
        guard runtime.interactionMode == .goal, runtime.currentGoal != nil else { return nil }
        return AgentModelRequestLedger(
            directory: AgentSessionStore.directory.appendingPathComponent("model-request-ledgers", isDirectory: true),
            ownerID: runtime.session.dispatchParentProjectID ?? runtime.id)
    }

    /// Deliberation spends the same owner budget without starting or resetting
    /// the execution clock. Planning-only is a tool permission, not free LLM use.
    func auxiliaryModelExecutionBudget(for runtime: AgentRuntime) -> AgentToolExecutionBudget? {
        guard runtime.interactionMode == .goal, let goal = runtime.currentGoal else { return nil }
        return AgentToolExecutionBudget(budget: goal.continuationBudget ?? .standard,
            requestLedger: modelRequestLedger(for: runtime), ownerGate: requestOwnerGate(for: runtime))
    }

    /// Only the host's ordered handover may request prose after execution
    /// expires. Its proposed tools still pass the hard tool boundary above.
    func modelExecutionBudget(for runtime: AgentRuntime) -> AgentToolExecutionBudget? {
        let budget = toolExecutionBudget(for: runtime)
        return budget?.wrapUpOnly == true && runtime.currentGoal?.continuationBudget?.modelAdmissionPaused != true ? nil : budget
    }

    func goalOwnsAutomaticContinuation(for runtime: AgentRuntime) -> Bool {
        guard !Task.isCancelled,
              !dispatchContinuationIsSuspended(runtime),
              runtime.interactionMode == .goal,
              !runtime.currentTurnPlanningOnly,
              runtime.currentPlan?.isInterrupted != true,
              !runtime.queuedMessages.contains(where: { $0.source == .operatorInput }),
              let goal = runtime.currentGoal, !goal.isEmpty else { return false }
        return goal.checklist.isEmpty || goal.checklist.contains(where: { !$0.done })
    }

    /// Stamp the first execution boundary, not the first request to continue.
    /// The persisted stamp is never restarted by compression or another turn.
    func beginGoalExecutionBudgetIfNeeded(for runtime: AgentRuntime, now: Date = Date()) {
        guard goalOwnsAutomaticContinuation(for: runtime),
              let plan = runtime.currentPlan,
              [.approved, .executing, .done].contains(plan.status),
              var goal = runtime.currentGoal else { return }
        var budget = goal.continuationBudget ?? .standard
        guard budget.segmentStartedAt == nil, !budget.wrapUpDispatched else { return }
        budget.segmentStartedAt = now
        goal.continuationBudget = budget
        runtime.currentGoal = goal
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    func canResumeAfterContextCompaction(for runtime: AgentRuntime) -> Bool {
        if runtime.interactionMode == .goal {
            return goalOwnsAutomaticContinuation(for: runtime)
        }
        return runtime.contextRunwayResumeCount < AgentContextRunwayPolicy.maximumAutomaticResumes
    }
}
