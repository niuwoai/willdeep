//
//  AgentGoalWakePolicy.swift
//  WillDeep
//
//  A Goal that is still running but deliberately not talking to a model right
//  now: the provider is down, the checklist has not moved for many rounds, or
//  the context compression it needs failed on a transient error. Each of those
//  used to end the Goal (or, for the no-progress ladder, push it back to work
//  immediately). They now park the Goal on one persisted, cancellable wait and
//  resume it when the wait is due. See docs/LONG_HORIZON_AUTONOMY.md §2.2 / §5.
//
//  Everything here is pure: the AppState glue lives in
//  AppStateAgentGoalWakes.swift and the timers in AgentGoalWakeCoordinator.
//

import Foundation

/// One pending automatic resumption of a Goal. Persisted on `AgentGoal`, so a
/// relaunch can tell "waiting on purpose" apart from "stopped" and pick the
/// wait back up instead of treating it as an interrupted turn.
nonisolated struct AgentGoalScheduledWake: Codable, Equatable, Identifiable {
    enum Reason: String, Codable, Equatable {
        /// The provider kept failing with a transient error after the turn's
        /// own retries were spent.
        case providerOutage
        /// §2.2 rung 3: five or more rounds without checklist progress.
        case noProgressBackoff
        /// The context compression a runway stop depends on failed on a
        /// transient error; the wake retries the compression first.
        case compressionRetry
    }

    var id: UUID
    var reason: Reason
    /// 1-based. Drives the delay and the "attempt N" the user sees.
    var attempt: Int
    var scheduledAt: Date
    var dueAt: Date
    /// Host instruction dispatched when the wake fires. Empty for
    /// `compressionRetry`, whose resumption belongs to the compression path.
    var instruction: String
    /// One-line reason shown in the tooltip, e.g. the provider error caption.
    var failureSummary: String?

    init(
        id: UUID = UUID(),
        reason: Reason,
        attempt: Int,
        scheduledAt: Date,
        dueAt: Date,
        instruction: String,
        failureSummary: String? = nil
    ) {
        self.id = id
        self.reason = reason
        self.attempt = attempt
        self.scheduledAt = scheduledAt
        self.dueAt = dueAt
        self.instruction = instruction
        self.failureSummary = failureSummary
    }

    private enum CodingKeys: String, CodingKey {
        case id, reason, attempt, scheduledAt, dueAt, instruction, failureSummary
    }

    /// A reason written by a newer build must not make the whole Goal — and
    /// with it the session — undecodable. Unknown reasons degrade to the
    /// generic "dispatch the stored instruction" behaviour.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let rawReason = try c.decode(String.self, forKey: .reason)
        reason = Reason(rawValue: rawReason) ?? .providerOutage
        attempt = try c.decode(Int.self, forKey: .attempt)
        scheduledAt = try c.decode(Date.self, forKey: .scheduledAt)
        dueAt = try c.decode(Date.self, forKey: .dueAt)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        failureSummary = try c.decodeIfPresent(String.self, forKey: .failureSummary)
    }
}

nonisolated enum AgentGoalWakePolicy {
    // MARK: - Backoff ladder (§2.2: 1 / 5 / 15 minutes, capped at 15)

    static let firstRetryDelay: TimeInterval = 60
    static let secondRetryDelay: TimeInterval = 5 * 60
    static let maximumRetryDelay: TimeInterval = 15 * 60
    static let retryDelays: [TimeInterval] = [firstRetryDelay, secondRetryDelay, maximumRetryDelay]

    /// `attempt` is 1-based; everything past the ladder stays at the cap.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let index = min(max(attempt - 1, 0), retryDelays.count - 1)
        return retryDelays[index]
    }

    /// Round 5 without progress is the first backoff (1 minute), round 6 the
    /// second (5 minutes), and so on. Rounds below the rung never wait.
    static func backoffAttempt(forRoundsWithoutProgress rounds: Int) -> Int {
        max(1, rounds - AgentGoalContinuationPolicy.reconcileRounds)
    }

    // MARK: - Which failures are worth waiting out

    /// Response-body markers of provider failures that retrying cannot fix,
    /// even though some providers send them with 429 or 5xx: an empty
    /// balance or quota, a disabled account, a moderation refusal. Waiting
    /// fifteen minutes on "insufficient_quota" only burns the night.
    static let terminalProviderBodyMarkers: [String] = [
        "insufficient_quota",
        "exceeded your current quota",
        "exceeded_current_quota",
        "insufficient balance",
        "insufficient_balance",
        "credit balance",
        "billing",
        "arrears",
        "account_deactivated",
        "余额不足",
        "欠费",
        "content_filter",
        "content_policy",
        "data_inspection_failed",
        "内容审核",
    ]

    /// Goal-level retry reuses the turn's own transient classification
    /// (408 / 429 / 5xx, lost network, empty or stalled stream, TLS) and
    /// then removes what only looks transient.
    static func isGoalRetryable(_ error: Error) -> Bool {
        guard AppState.isTransientProviderError(error) || AppState.isTLSHandshakeError(error) else {
            return false
        }
        guard !AppState.isContextOverflowError(error) else { return false }
        if case AgentClientError.serverStatus(let providerError) = error,
           bodyIndicatesTerminalFailure(providerError.responseBody) {
            return false
        }
        return true
    }

    static func bodyIndicatesTerminalFailure(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return terminalProviderBodyMarkers.contains { lowered.contains($0) }
    }

    enum CompressionFailureDisposition: Equatable {
        case retry
        case stop
    }

    /// A compression failure is retryable when waiting could change the
    /// outcome: the summary model's provider hiccuped, timed out or returned
    /// nothing, or the transcript moved underneath it. Deterministic
    /// failures stop: the required task state is larger than a checkpoint may
    /// hold, no summary provider is configured (`nil`), the budget is spent,
    /// or the request itself was rejected.
    static func compressionFailureDisposition(_ error: Error?) -> CompressionFailureDisposition {
        guard let error else { return .stop }
        if let failure = error as? AgentContextCheckpoint.Failure {
            switch failure {
            case .stale: return .retry
            case .tooLarge: return .stop
            }
        }
        if error is CancellationError || error is AgentToolExecutionBudgetError { return .stop }
        return isGoalRetryable(error) ? .retry : .stop
    }

    // MARK: - Eligibility

    /// The wall-clock budget is the only thing that ends a waiting Goal. A
    /// segment that has not started its clock yet has its whole runway.
    static func hasWallClockRunway(_ budget: AgentGoalContinuationBudget?, now: Date) -> Bool {
        guard let budget, let limit = budget.wallClockLimit else { return true }
        return budget.elapsed(at: now) < limit
    }

    /// Pure half of "may this Goal park on a wait instead of stopping".
    /// Dispatch-board nodes are left to their scheduler; external executors
    /// never reach the native loop that fails; a handed-over or
    /// admission-paused budget is already an ordered stop.
    static func canScheduleWake(
        interactionMode: AgentInteractionMode,
        executionAgent: AgentExecutionAgent,
        isUnattendedDispatchTask: Bool,
        goal: AgentGoal?,
        now: Date
    ) -> Bool {
        guard interactionMode == .goal,
              executionAgent == .willDeep,
              !isUnattendedDispatchTask,
              let goal,
              !goal.isEmpty,
              goal.checklist.isEmpty || goal.checklist.contains(where: { !$0.done }) else {
            return false
        }
        let budget = goal.continuationBudget
        guard budget?.wrapUpDispatched != true,
              budget?.modelAdmissionPaused != true else { return false }
        return hasWallClockRunway(budget, now: now)
    }

    /// Whether this runtime counts as "a Goal is executing" for sleep
    /// inhibition: a live turn, a queued dispatch, a compression, or a wait.
    static func holdsSleepInhibition(
        interactionMode: AgentInteractionMode,
        goal: AgentGoal?,
        isResponding: Bool,
        isAwaitingProviderSlot: Bool,
        isCompressingContext: Bool
    ) -> Bool {
        guard interactionMode == .goal,
              let goal,
              !goal.isEmpty,
              goal.checklist.isEmpty || goal.checklist.contains(where: { !$0.done }) else {
            return false
        }
        return goal.scheduledWake != nil || isResponding || isAwaitingProviderSlot || isCompressingContext
    }

    // MARK: - Scheduling and catch-up

    static func makeWake(
        reason: AgentGoalScheduledWake.Reason,
        attempt: Int,
        now: Date,
        instruction: String,
        failureSummary: String? = nil
    ) -> AgentGoalScheduledWake {
        AgentGoalScheduledWake(
            reason: reason,
            attempt: attempt,
            scheduledAt: now,
            dueAt: now.addingTimeInterval(delay(forAttempt: attempt)),
            instruction: instruction,
            failureSummary: failureSummary
        )
    }

    enum CatchUp: Equatable {
        case fireNow
        case wait(TimeInterval)
    }

    /// After a system wake (or at launch) the in-process timer is no longer
    /// trustworthy: the monotonic clock it slept on stood still while the Mac
    /// slept. The persisted wall-clock due date decides.
    static func catchUp(for wake: AgentGoalScheduledWake, now: Date) -> CatchUp {
        let remaining = wake.dueAt.timeIntervalSince(now)
        return remaining <= 0 ? .fireNow : .wait(remaining)
    }

    /// Whole minutes left, rounded up and never below one, for the notice.
    static func displayedMinutesRemaining(until dueAt: Date, now: Date) -> Int {
        let secondsPerMinute: TimeInterval = 60
        let remaining = dueAt.timeIntervalSince(now)
        return max(1, Int((remaining / secondsPerMinute).rounded(.up)))
    }

    // MARK: - Model-facing text

    /// Model-facing, not UI text, so it stays English and out of the catalog —
    /// the same split the other continuation notices use.
    static let providerOutageInstruction = """
    WillDeep automatic recovery: the previous model request failed because the model provider was temporarily unavailable, and the host waited before trying again. Continue the same Goal from where it stopped. Do not restart planning or replace the plan. Before repeating any write, command or other side effect, check the latest conversation and workspace evidence: an interrupted step may already have taken effect. Then pick the next unfinished step and do it.
    """
}
