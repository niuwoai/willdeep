//
//  AgentGoalContinuationBudget.swift
//  WillDeep
//
//  Long-horizon Goal continuation: budget, backoff ladder, ordered soft stop.
//

import Foundation

/// The execution budget for one Goal segment.
///
/// A long Goal used to stop after two acceptance rounds without progress.
/// That punished the most ordinary long-running state there is — waiting on
/// a build, a test suite, or a review — and handed control back with a red
/// banner and no way to resume except a button. The budget replaces that
/// proxy with something explainable: keep going until wall-clock or the
/// safety net actually runs out, then wrap up in an orderly way.
///
/// Tracking state lives here rather than on the runtime so it is persisted
/// with the Goal and survives a relaunch: a segment that already burned
/// three hours must not come back with a full budget.
nonisolated struct AgentGoalContinuationBudget: Codable, Equatable {
    /// Wall-clock ceiling for one segment. `nil` means unbounded.
    var wallClockLimit: TimeInterval?
    /// Safety net so a stuck Goal cannot spin forever when there is no clock
    /// limit. This is a backstop, not the primary gate.
    var maximumContinuations: Int
    /// Start of the current segment. `nil` until the first continuation.
    var segmentStartedAt: Date?
    /// Continuations already spent in this segment.
    var continuationsUsed: Int
    /// Wrap-up guidance was already delivered, so the next natural stop is
    /// accepted instead of being refused again.
    var wrapUpDispatched: Bool

    init(
        wallClockLimit: TimeInterval? = AgentGoalContinuationPolicy.defaultWallClockLimit,
        maximumContinuations: Int = AgentGoalContinuationPolicy.defaultMaximumContinuations,
        segmentStartedAt: Date? = nil,
        continuationsUsed: Int = 0,
        wrapUpDispatched: Bool = false
    ) {
        self.wallClockLimit = wallClockLimit
        self.maximumContinuations = maximumContinuations
        self.segmentStartedAt = segmentStartedAt
        self.continuationsUsed = continuationsUsed
        self.wrapUpDispatched = wrapUpDispatched
    }

    static let standard = AgentGoalContinuationBudget()

    /// A fresh segment that keeps the configured limits but drops all spend.
    var restarted: AgentGoalContinuationBudget {
        AgentGoalContinuationBudget(
            wallClockLimit: wallClockLimit,
            maximumContinuations: maximumContinuations
        )
    }
}

nonisolated enum AgentGoalContinuationPolicy {
    /// One segment defaults to four hours; the operator can widen it.
    static let defaultWallClockLimit: TimeInterval = 4 * 60 * 60
    static let defaultMaximumContinuations = 64
    /// Rounds without progress that are answered with plain guidance.
    static let guidanceRounds = 2
    /// Rounds without progress that are answered with a read-only
    /// reconciliation demand before escalating further.
    static let reconcileRounds = 4

    /// How hard the host pushes back. The rung never changes the decision to
    /// continue — only the wording and the constraints attached to it.
    enum Rung: Equatable {
        /// Name the next unchecked item and do it.
        case guidance
        /// Stop guessing; verify the checklist against the real tree.
        case reconcile
        /// Say what external condition is being waited on, or change approach.
        case backoff
    }

    enum SoftStopReason: Equatable {
        case wallClock
        case continuations
    }

    enum Outcome: Equatable {
        /// Goal is not met and budget remains: push the model back to work.
        case continueExecution(rung: Rung)
        /// Budget is spent: ask for a handover snapshot, then stop.
        case wrapUp(reason: SoftStopReason)
        /// The handover was already requested; stop without further nagging.
        case halt
    }

    /// Pure decision over a budget. Returns the outcome together with the
    /// budget to store, so the caller performs exactly one mutation and the
    /// whole ladder stays unit-testable without an AppState.
    static func evaluate(
        budget: AgentGoalContinuationBudget,
        now: Date,
        consecutiveRoundsWithoutProgress: Int
    ) -> (outcome: Outcome, budget: AgentGoalContinuationBudget) {
        var budget = budget
        guard !budget.wrapUpDispatched else { return (.halt, budget) }

        let startedAt = budget.segmentStartedAt ?? now
        budget.segmentStartedAt = startedAt

        if let limit = budget.wallClockLimit,
           now.timeIntervalSince(startedAt) >= limit {
            budget.wrapUpDispatched = true
            return (.wrapUp(reason: .wallClock), budget)
        }
        if budget.continuationsUsed >= budget.maximumContinuations {
            budget.wrapUpDispatched = true
            return (.wrapUp(reason: .continuations), budget)
        }

        budget.continuationsUsed += 1
        return (
            .continueExecution(rung: rung(forRoundsWithoutProgress: consecutiveRoundsWithoutProgress)),
            budget
        )
    }

    static func rung(forRoundsWithoutProgress rounds: Int) -> Rung {
        if rounds <= guidanceRounds {
            return .guidance
        }
        if rounds <= reconcileRounds {
            return .reconcile
        }
        return .backoff
    }

    /// Model-facing escalation appended to the ordinary acceptance prompt.
    /// Prompt text, not UI text, so it stays English and out of the catalog —
    /// the same split the existing continuation notices use.
    static func escalation(for rung: Rung) -> String? {
        switch rung {
        case .guidance:
            return nil
        case .reconcile:
            return "Several rounds have passed without the acceptance checklist moving. Before anything else, reconcile your assumptions against reality: read the actual files and run git status/diff to confirm whether the work you believe is done exists. Correct any item you checked off without evidence."
        case .backoff:
            return "Many rounds have passed without the acceptance checklist moving. State explicitly which external condition you are waiting on (a build, a test run, a background task) and check it directly, or take a different concrete step. Do not repeat the previous approach unchanged."
        }
    }

    /// Model-facing handover request used when the budget is spent. Mirrors
    /// the ordered wrap-up the CLI runtime performs, so a Goal that runs out
    /// of runway leaves a usable state snapshot instead of a red banner.
    static func wrapUpPrompt(remainingAcceptance: [String]) -> String {
        let remaining = remainingAcceptance.isEmpty
            ? "(none recorded)"
            : remainingAcceptance.joined(separator: "\n- ")
        return """
        The execution budget for this Goal segment is exhausted. The Goal is NOT complete. This is an orderly wrap-up, not a failure.

        Stop all new substantive work now: no new edits, no new files, no new background tasks. Produce a handover snapshot with exactly these sections:
        - STATE: current git branch, uncommitted files, current version
        - DONE: what was actually completed and how it was verified
        - REMAINING: what still has to happen, in the order it should happen
        - BLOCKERS: anything that stopped progress, with the specific error or condition
        - NEXT: the single action whoever resumes this Goal should take first

        Unchecked acceptance items:
        - \(remaining)
        """
    }
}
