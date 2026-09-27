//
//  AgentGoalVerificationRelaunch.swift
//  WillDeep
//
//  A Goal completion candidate is persisted as `.verifying` the moment host
//  verification starts, and only the verifier itself moves it on (to
//  `.verified` or `.rejected`). When the process is killed mid-verification
//  nothing is left to do that: the restored candidate sat in `.verifying`
//  forever, host re-verification only accepts `.pending`, and the Goal could
//  never finish acceptance. Restore now puts such a candidate back to
//  `.pending` and marks it, and launch recovery hands the Goal back to the
//  model once so it can submit the goal-check again.
//
//  A verifier that is still running in this process owns its candidate:
//  another AppState/window restoring the same session must not reset it.
//

import Foundation

/// Candidates whose host verification is running in this process. Keyed by
/// candidate ID, so an unrelated session or a replaced candidate never
/// matches. Process-wide because several AppState instances can restore the
/// same session while one of them is verifying.
nonisolated final class AgentGoalVerificationInFlightRegistry: @unchecked Sendable {
    static let shared = AgentGoalVerificationInFlightRegistry()

    private let lock = NSLock()
    private var candidateIDs: Set<UUID> = []

    func begin(_ candidateID: UUID) {
        lock.lock(); defer { lock.unlock() }
        candidateIDs.insert(candidateID)
    }

    func end(_ candidateID: UUID) {
        lock.lock(); defer { lock.unlock() }
        candidateIDs.remove(candidateID)
    }

    func contains(_ candidateID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return candidateIDs.contains(candidateID)
    }
}

nonisolated enum AgentGoalVerificationRelaunchPolicy {
    /// Restore-time normalization. `.verifying` with no live verifier can
    /// only mean the verifier died with the previous process (Stop and every
    /// failure path settle the phase to `.rejected` before returning).
    static func normalizedForRestore(
        _ goal: AgentGoal,
        registry: AgentGoalVerificationInFlightRegistry = .shared
    ) -> AgentGoal {
        guard var verification = goal.verification,
              verification.phase == .verifying,
              !registry.contains(verification.id) else { return goal }
        var normalized = goal
        verification.phase = .pending
        verification.relaunchRecoveryPending = true
        normalized.verification = verification
        return normalized
    }

    /// Whether launch recovery still owes this Goal a continuation for an
    /// interrupted verification. Covers both the raw persisted snapshot
    /// (`.verifying`, before any restore) and the normalized live state.
    static func needsRecovery(
        _ goal: AgentGoal,
        registry: AgentGoalVerificationInFlightRegistry = .shared
    ) -> Bool {
        guard let verification = goal.verification else { return false }
        switch verification.phase {
        case .verifying:
            return !registry.contains(verification.id)
        case .pending:
            return verification.relaunchRecoveryPending == true
        case .rejected, .verified:
            return false
        }
    }
}

extension AgentGoalLaunchRecoveryPolicy {
    /// Model-facing prompt, not UI copy: English and outside the catalog,
    /// like the other launch continuation notices.
    static func verificationContinuationNotice() -> String {
        """
        WillDeep launch recovery: the app process stopped while the host was verifying this Goal's latest completion candidate. That verification never finished, so no acceptance item was granted and the checklist is still unchecked.

        Resume the same Goal. Do not create or replace a plan, do not restart Goal Teams, and do not repeat completed implementation. Inspect the current workspace first, re-run only the verification the unchecked acceptance items need (for code changes, the relevant repository-local tests), then end the reply with exactly one `goal-check` block so the host can verify it again. Preserve normal approval and confirmation gates.
        """
    }
}
