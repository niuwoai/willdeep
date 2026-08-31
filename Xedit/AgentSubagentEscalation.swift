//
//  AgentSubagentEscalation.swift
//  WillDeep
//
//  When a cheap trade cannot finish the job, hand it up — never down.
//
//  Profiles trade capability for cost. The bill for that trade shows up as
//  a subagent that burns its rounds without producing a usable report, and
//  the money saved comes straight back as the parent redoing the work.
//  This is the ladder that stops it: one clean re-run on the next configured tier.
//
//  Two rules carried over from managed routing:
//   - Only upward. A run never retries on something cheaper.
//   - Always visible. The escalation is recorded on the transcript and shown
//     in the inspector, because a fallback nobody can see is indistinguishable
//     from one that never fires.
//

import Foundation

nonisolated enum AgentSubagentEscalation {
    /// Whether `outcome` warrants trying the next configured model tier.
    ///
    /// The round cap is the honest signal: the runner returns a partial
    /// report with an explanatory note when a child exhausts its rounds
    /// without stopping on its own.
    static func shouldEscalate(
        outcome: AgentSubagentRunner.Outcome,
        profile: AgentSubagentProfile
    ) -> Bool {
        guard profile.escalation == .retryWithParentModel else { return false }
        // A verifier that ran and did not pass is the least ambiguous failure
        // this system can observe — no prose to interpret, no report length to
        // guess at. It outranks the other triggers precisely because it is the
        // one signal that cannot be faked by a confident-sounding model.
        if outcome.verifierPassed == false { return true }
        // Conversely, a passing verifier is proof the cheap trade did the job;
        // escalating then would pay twice for work already finished, however
        // terse the write-up.
        if outcome.verifierPassed == true { return false }
        if outcome.roundCount >= profile.maxRounds { return true }
        // A concise correct answer is not failure. Only a missing answer
        // warrants a retry when there is no verifier or round-limit signal.
        return outcome.report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a thrown provider error looks like the child overflowing its
    /// (smaller) context window, which is the other way a cheap trade fails.
    static func isContextOverflow(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("context length")
            || text.contains("context_length")
            || text.contains("maximum context")
            || text.contains("too many tokens")
            || text.contains("context window")
    }

    /// Upgrade intelligence, never authority: keep the original role's tools,
    /// prompts, write scope, and round budget. Only its model tier changes.
    static func escalatedProfile(from profile: AgentSubagentProfile) -> AgentSubagentProfile {
        var escalated = profile
        if let next = AgentWorkerTierModels.tier(for: profile.modelBinding)?.next {
            escalated.modelBinding = .init(workerTier: next)
        }
        escalated.escalation = .none
        return escalated
    }
}
