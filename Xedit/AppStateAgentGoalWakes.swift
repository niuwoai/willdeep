//
//  AppStateAgentGoalWakes.swift
//  WillDeep
//
//  The one "Goal timed resumption" mechanism shared by three callers:
//
//    - A1  a Goal turn whose provider failure outlived the turn's own retries
//          waits 1 / 5 / 15 / 15 … minutes and tries again, instead of ending
//          the Goal with an error card;
//    - A3  the no-progress ladder's backoff rung (§2.2, round 5+) really
//          waits before the continuation instead of only changing its words;
//    - A5  a context compression that failed on a transient error is retried
//          after the same ladder instead of parking the Goal.
//
//  A wait holds no provider slot and no turn. It is persisted on the Goal
//  (`AgentGoal.scheduledWake`), so launch recovery and the system-wake
//  catch-up can both re-derive it from its wall-clock due date. Only the
//  wall-clock budget ends a waiting Goal; Stop, a new message, or any turn
//  that starts for the runtime cancels the wait at once.
//
//  While any Goal is executing — a live turn, a queued dispatch, a compression
//  or one of these waits — the process holds `idleSystemSleepDisabled`
//  (AgentSleepInhibitor). Pure rules live in AgentGoalWakePolicy.swift.
//

import AppKit
import Foundation
import os

extension AppState {
    static let goalWakeLog = Logger(subsystem: "com.willdeep.app", category: "goal-wake")

    /// Compression retried from a wait keeps the same tail as the runway
    /// path in `finishAgentLoopTurn`, which it stands in for.
    static let goalWakeCompressionKeepRecentMessages = 2

    // MARK: - Wiring

    /// Called once from `init`. Tests re-wire to a private center so a posted
    /// wake cannot reach other suites' AppStates.
    func configureAgentGoalWakes(
        systemWakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        agentGoalWakeCoordinator.observeSystemWake(center: systemWakeCenter) { [weak self] in
            self?.catchUpGoalWakes(rearmPending: true)
        }
    }

    /// AppState half of the eligibility check: the Goal still owns automatic
    /// continuation (not stopped, not complete, no operator message waiting,
    /// not planning-only) and the pure rules allow a wait.
    func goalCanScheduleWake(for runtime: AgentRuntime, now: Date = Date()) -> Bool {
        goalOwnsAutomaticContinuation(for: runtime)
            && AgentGoalWakePolicy.canScheduleWake(
                interactionMode: runtime.interactionMode,
                executionAgent: runtime.executionAgent,
                isUnattendedDispatchTask: runtime.isUnattendedDispatchTask,
                goal: runtime.currentGoal,
                now: now
            )
    }

    // MARK: - A1: provider outage

    /// Called from the turn loop's error path after the in-turn retries gave
    /// up. Returns true when the failure was parked on a Goal-level wait; the
    /// caller then ends the turn without an error card. The recovery
    /// checkpoint survives (`finishAgentLoopTurn` keeps it while a wait is
    /// pending), so a crash during the wait still resumes the Goal.
    func deferGoalTurnForProviderOutage(
        _ error: Error,
        runtime: AgentRuntime,
        assistantID: UUID,
        now: Date = Date()
    ) -> Bool {
        guard AgentGoalWakePolicy.isGoalRetryable(error),
              goalCanScheduleWake(for: runtime, now: now),
              var goal = runtime.currentGoal else { return false }
        // Same cleanup as the ordinary error path: an empty reply must not
        // stay behind as a blank bubble or a dangling context carrier.
        if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
           runtime.messages[index].content.isEmpty,
           runtime.messages[index].toolCalls.isEmpty {
            runtime.messages.remove(at: index)
            AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
        }
        // The in-turn "reconnecting 5/5" notice is superseded by the wait.
        if runtime.isShowingWatchdogStallNotice {
            runtime.clearTurnError()
            runtime.isShowingWatchdogStallNotice = false
        }
        let attempt = (goal.consecutiveTransientFailures ?? 0) + 1
        goal.consecutiveTransientFailures = attempt
        runtime.currentGoal = goal
        agentGoalWakeCoordinator.noteDeferredOutage(runtimeID: runtime.id, turnID: runtime.activeTurnID)
        scheduleGoalWake(
            AgentGoalWakePolicy.makeWake(
                reason: .providerOutage,
                attempt: attempt,
                now: now,
                instruction: AgentGoalWakePolicy.providerOutageInstruction,
                failureSummary: Self.friendlyMessage(for: error)
            ),
            for: runtime,
            now: now
        )
        return true
    }

    // MARK: - A3: no-progress backoff

    /// Called where a Goal continuation would be queued or dispatched. On the
    /// backoff rung the continuation is parked on a wait instead; returns true
    /// when it was, and the caller must not send it now.
    func deferGoalContinuationForBackoff(
        outcome: AgentGoalContinuationPolicy.Outcome,
        prompt: String,
        for runtime: AgentRuntime,
        now: Date = Date()
    ) -> Bool {
        guard case .continueExecution(rung: .backoff) = outcome,
              goalCanScheduleWake(for: runtime, now: now) else { return false }
        let attempt = AgentGoalWakePolicy.backoffAttempt(
            forRoundsWithoutProgress: runtime.consecutiveGoalRoundsWithoutChecklistProgress
        )
        scheduleGoalWake(
            AgentGoalWakePolicy.makeWake(
                reason: .noProgressBackoff,
                attempt: attempt,
                now: now,
                instruction: prompt
            ),
            for: runtime,
            now: now
        )
        return true
    }

    // MARK: - A5: compression retry

    /// Called when a runway compression failed and the session would
    /// otherwise be relayed (refused for Goals) and parked. A retryable
    /// failure waits on the same ladder and then compresses again; returns
    /// false for deterministic failures, which keep the original banner.
    func deferGoalAfterCompressionFailure(
        _ error: Error?,
        for runtime: AgentRuntime,
        now: Date = Date()
    ) -> Bool {
        // A turn that started while the compression ran owns the runtime now.
        guard !runtime.isResponding, !runtime.isAwaitingProviderSlot,
              AgentGoalWakePolicy.compressionFailureDisposition(error) == .retry,
              goalCanScheduleWake(for: runtime, now: now),
              var goal = runtime.currentGoal else { return false }
        let attempt = (goal.consecutiveTransientFailures ?? 0) + 1
        goal.consecutiveTransientFailures = attempt
        runtime.currentGoal = goal
        // The wait replaces the "Context compression failed" banner.
        runtime.clearTurnError()
        scheduleGoalWake(
            AgentGoalWakePolicy.makeWake(
                reason: .compressionRetry,
                attempt: attempt,
                now: now,
                instruction: "",
                failureSummary: error?.localizedDescription
            ),
            for: runtime,
            now: now
        )
        return true
    }

    // MARK: - Schedule / cancel / fire

    func scheduleGoalWake(_ wake: AgentGoalScheduledWake, for runtime: AgentRuntime, now: Date = Date()) {
        guard var goal = runtime.currentGoal else { return }
        goal.scheduledWake = wake
        runtime.currentGoal = goal
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        armGoalWakeTimer(for: runtime.id, wake: wake, now: now)
        Self.goalWakeLog.notice(
            "goal wake scheduled runtime=\(runtime.id.uuidString, privacy: .public) reason=\(wake.reason.rawValue, privacy: .public) attempt=\(wake.attempt) delaySeconds=\(Int(wake.dueAt.timeIntervalSince(now)))"
        )
        syncGoalSleepInhibition()
    }

    /// Takes a pending wait down. Returns true when there was one.
    @discardableResult
    func cancelGoalWake(for runtime: AgentRuntime, reason: String) -> Bool {
        agentGoalWakeCoordinator.disarm(runtimeID: runtime.id)
        guard let wake = runtime.currentGoal?.scheduledWake else { return false }
        clearGoalWake(for: runtime)
        Self.goalWakeLog.notice(
            "goal wake cancelled runtime=\(runtime.id.uuidString, privacy: .public) reason=\(wake.reason.rawValue, privacy: .public) by=\(reason, privacy: .public)"
        )
        syncGoalSleepInhibition()
        return true
    }

    /// Stop always wins (docs §8): a waiting Goal has no turn to cancel, so
    /// Stop takes the wait down itself and says so in the transcript. A runway
    /// compression that is still running must not resume the Goal afterwards
    /// either.
    func cancelGoalWakeForUserStop(_ runtime: AgentRuntime) {
        runtime.pendingContextRunwayResume = false
        let wasWaiting = cancelGoalWake(for: runtime, reason: "user stop")
        if wasWaiting, !runtime.isResponding, !runtime.isAwaitingProviderSlot {
            _ = appendStoppedTurnEvent(to: runtime, content: L10n.Composer.stopped)
        }
    }

    /// Any turn that starts for the runtime supersedes its wait: the user
    /// wrote, a background job finished, or the wait itself fired.
    func noteGoalTurnStarted(for runtime: AgentRuntime) {
        cancelGoalWake(for: runtime, reason: "turn started")
        syncGoalSleepInhibition()
    }

    /// End of `finishAgentLoopTurn` for the owning turn. A turn that got an
    /// answer from the provider resets the transient-failure ladder; the turn
    /// that was just parked on an outage wait keeps it.
    func noteGoalTurnFinished(for runtime: AgentRuntime, turnID: UUID) {
        let parkedOnOutage = agentGoalWakeCoordinator.consumeDeferredOutage(runtimeID: runtime.id, turnID: turnID)
        if !parkedOnOutage,
           runtime.lastTurnFailure == nil,
           var goal = runtime.currentGoal,
           goal.consecutiveTransientFailures != nil {
            goal.consecutiveTransientFailures = nil
            runtime.currentGoal = goal
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        }
        syncGoalSleepInhibition()
    }

    func fireGoalWake(runtimeID: UUID, wakeID: UUID, now: Date = Date()) {
        agentGoalWakeCoordinator.disarm(runtimeID: runtimeID)
        defer { syncGoalSleepInhibition() }
        guard let runtime = runtime(for: runtimeID),
              let wake = runtime.currentGoal?.scheduledWake,
              wake.id == wakeID else { return }
        clearGoalWake(for: runtime)
        // Something else already owns the runtime; the wait was superseded.
        guard !runtime.isResponding,
              !runtime.isAwaitingProviderSlot,
              runtime.requestTask == nil,
              !runtime.isCompressingContext else {
            Self.goalWakeLog.notice("goal wake superseded runtime=\(runtimeID.uuidString, privacy: .public)")
            return
        }
        // Stop, completion, a queued operator message or a mode switch since
        // the wait began all mean the Goal no longer resumes on its own.
        guard goalOwnsAutomaticContinuation(for: runtime),
              runtime.executionAgent == .willDeep,
              !runtime.isUnattendedDispatchTask else {
            Self.goalWakeLog.notice("goal wake dropped runtime=\(runtimeID.uuidString, privacy: .public)")
            return
        }
        Self.goalWakeLog.notice(
            "goal wake fired runtime=\(runtimeID.uuidString, privacy: .public) reason=\(wake.reason.rawValue, privacy: .public) attempt=\(wake.attempt)"
        )
        switch wake.reason {
        case .providerOutage, .noProgressBackoff:
            // An expired wall clock is handled by the turn itself: its budget
            // gate turns the request into the ordered wrap-up (soft stop).
            dispatchAgentMessage(for: runtime, text: wake.instruction, images: [], source: .hostInstruction)
        case .compressionRetry:
            resumeGoalCompressionAfterWake(runtime, now: now)
        }
    }

    /// System wake (`rearmPending`) re-derives every wait from its wall-clock
    /// due date: the due ones fire now, the rest get a fresh timer for what is
    /// actually left. The 30-second scheduler tick is the safety net for a
    /// missed notification: it fires what is due and arms what lost its
    /// timer, without disturbing healthy timers.
    func catchUpGoalWakes(rearmPending: Bool, now: Date = Date()) {
        for runtime in Array(agentRuntimes.values) {
            guard let wake = runtime.currentGoal?.scheduledWake else { continue }
            switch AgentGoalWakePolicy.catchUp(for: wake, now: now) {
            case .fireNow:
                fireGoalWake(runtimeID: runtime.id, wakeID: wake.id, now: now)
            case .wait:
                if rearmPending || agentGoalWakeCoordinator.armedWakeID(for: runtime.id) != wake.id {
                    armGoalWakeTimer(for: runtime.id, wake: wake, now: now)
                }
            }
        }
        syncGoalSleepInhibition()
    }

    /// Launch recovery for a Goal that was waiting when the app quit or
    /// crashed. Returns true when a resumption started (the wait was already
    /// due); a wait that is not due yet is simply armed again.
    @discardableResult
    func restoreGoalWakeAfterLaunch(for runtime: AgentRuntime, now: Date = Date()) -> Bool {
        guard let wake = runtime.currentGoal?.scheduledWake else { return false }
        switch AgentGoalWakePolicy.catchUp(for: wake, now: now) {
        case .fireNow:
            fireGoalWake(runtimeID: runtime.id, wakeID: wake.id, now: now)
            return runtime.isResponding || runtime.isAwaitingProviderSlot || runtime.isCompressingContext
        case .wait:
            armGoalWakeTimer(for: runtime.id, wake: wake, now: now)
            syncGoalSleepInhibition()
            return false
        }
    }

    // MARK: - Sleep inhibition

    func syncGoalSleepInhibition() {
        let holders = agentRuntimes.values.filter {
            AgentGoalWakePolicy.holdsSleepInhibition(
                interactionMode: $0.interactionMode,
                goal: $0.currentGoal,
                isResponding: $0.isResponding,
                isAwaitingProviderSlot: $0.isAwaitingProviderSlot,
                isCompressingContext: $0.isCompressingContext
            )
        }.map(\.id)
        agentGoalWakeCoordinator.syncSleepInhibition(holders: Set(holders))
    }

    // MARK: - Private

    private func armGoalWakeTimer(for runtimeID: UUID, wake: AgentGoalScheduledWake, now: Date) {
        let delay = max(0, wake.dueAt.timeIntervalSince(now))
        agentGoalWakeCoordinator.arm(runtimeID: runtimeID, wakeID: wake.id, after: delay) { [weak self] runtimeID, wakeID in
            self?.fireGoalWake(runtimeID: runtimeID, wakeID: wakeID)
        }
    }

    private func clearGoalWake(for runtime: AgentRuntime) {
        guard var goal = runtime.currentGoal, goal.scheduledWake != nil else { return }
        goal.scheduledWake = nil
        runtime.currentGoal = goal
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    /// Compression first, then the ordinary runway resumption. If the wall
    /// clock ran out during the wait, the runway handover already written is
    /// the handover: stop in order and let Play grant a new segment.
    private func resumeGoalCompressionAfterWake(_ runtime: AgentRuntime, now: Date) {
        guard AgentGoalWakePolicy.hasWallClockRunway(runtime.currentGoal?.continuationBudget, now: now) else {
            if var goal = runtime.currentGoal {
                var budget = goal.continuationBudget ?? .standard
                budget.wrapUpDispatched = true
                goal.continuationBudget = budget
                runtime.currentGoal = goal
            }
            runtime.errorMessage = L10n.GoalPlanning.budgetExhausted
            runtime.errorDetails = nil
            runtime.errorSeverity = .notice
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            return
        }
        runtime.pendingContextRunwayResume = true
        compressAgentContext(for: runtime, keepRecent: Self.goalWakeCompressionKeepRecentMessages)
        guard !runtime.isCompressingContext else { return }
        // Nothing left to compress: resume anyway. The pre-send gate still
        // compresses in-turn if the request would not fit.
        resumeAfterContextRunwayStopIfNeeded(for: runtime)
    }
}
