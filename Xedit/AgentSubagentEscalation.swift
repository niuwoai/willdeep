//
//  AgentSubagentEscalation.swift
//  WillDeep
//
//  When a cheap trade cannot finish the job, hand it up — never down.
//
//  Profiles trade capability for cost. The bill for that trade shows up as
//  a subagent that burns its rounds without producing a usable report, and
//  the money saved comes straight back as the parent redoing the work.
//  This is the ladder that stops it: one clean re-run on the parent's model.
//
//  Two rules carried over from managed routing:
//   - Only upward. A run never retries on something cheaper.
//   - Always visible. The escalation is recorded on the transcript and shown
//     in the inspector, because a fallback nobody can see is indistinguishable
//     from one that never fires.
//

import Foundation

nonisolated enum AgentSubagentEscalation {
    /// A report this short is not an answer — it is a small model giving up
    /// with prose. Deliberately generous: escalating on a real (if terse)
    /// answer only costs one extra run, while missing a stall costs the
    /// parent a whole redo.
    static let minimumUsefulReportCharacters = 40

    /// Whether `outcome` should be retried on the parent's model.
    ///
    /// The round cap is the honest signal: the runner returns a partial
    /// report with an explanatory note when a child exhausts its rounds
    /// without stopping on its own.
    static func shouldEscalate(
        outcome: AgentSubagentRunner.Outcome,
        profile: AgentSubagentProfile
    ) -> Bool {
        guard profile.escalation == .retryWithParentModel else { return false }
        if outcome.roundCount >= profile.maxRounds { return true }
        let report = outcome.report.trimmingCharacters(in: .whitespacesAndNewlines)
        return report.count < minimumUsefulReportCharacters
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

    /// The profile the retry runs under: the trade's identity is kept for
    /// reporting, but it gets `deep`'s tools and budgets — retrying the same
    /// narrow tool set on a bigger model usually reproduces the same dead end.
    static func escalatedProfile(from profile: AgentSubagentProfile) -> AgentSubagentProfile {
        var escalated = profile
        escalated.modelBinding = .inheritsParent
        escalated.toolNames = AgentSubagentProfileCatalog.deep.toolNames
        escalated.maxRounds = AgentSubagentProfileCatalog.deep.maxRounds
        escalated.toolPayloadCharacterLimit = AgentSubagentProfileCatalog.deep.toolPayloadCharacterLimit
        escalated.escalation = .none
        // The editor trade keeps its single-file write scope through the
        // retry; the lock and approval are unchanged, so the door stays the
        // same width.
        if profile.requiresWriteAccess {
            escalated.toolNames = AgentSubagentProfileCatalog.editor.toolNames
            escalated.toolPayloadCharacterLimit = AgentSubagentProfileCatalog.editor.toolPayloadCharacterLimit
        }
        return escalated
    }
}
