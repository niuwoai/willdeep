//
//  AgentDeepAdmission.swift
//  WillDeep
//
//  Admission control for the scarce 1M tier.
//
//  The model may compile the task packet, but it does not get to decide
//  whether a 1M context window is free. Prompt-level rules ("escalate to
//  `deep` only when the work cannot be bounded") are advice, and advice
//  loses to the model's own read of the situation every time — it already
//  has the files open, and `profile="deep"` is one word shorter than
//  compiling a worker packet.
//
//  So the rule moves out of the prompt and into the runtime: a spawn that
//  wants `deep` must present a ticket, and the ticket is checked against
//  what this session was actually observed doing. Not what the model says
//  it tried — what it tried.
//
//  Three gates, in order:
//
//   1. The ticket exists and its fields say something. A four-character
//      `reason` is not a reason.
//   2. The runtime observed corroborating work: either one of the named
//      lower tiers really ran in this session, or the session did enough
//      first-hand repository inspection to have earned an opinion.
//   3. The budget has room. L is rationed per session like any other
//      scarce allocation.
//
//  Deliberately NOT here: any judgement about whether the escalation is a
//  *good* idea. This mechanism only refuses claims the runtime can falsify.
//  A well-evidenced escalation to deep is exactly what the tier is for.
//
//  Naming note: `AgentSubagentEscalation` is a different mechanism that
//  happens to share a word. That one retries a cheap trade on the parent's
//  model *after* it fails (handing work up when the trade was too small).
//  This one decides whether the L tier may be entered at all. They appear
//  in the same code paths, so they do not share a name.
//
//  See docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §4 step 2.
//

import Foundation

/// The escalation ticket a `deep` spawn must carry.
nonisolated struct AgentDeepAdmissionTicket: Equatable, Sendable {
    /// Why the standard tier could not finish the job.
    var reason: String
    /// Lower tiers already attempted in this session. Cross-checked against
    /// what actually ran — naming a trade you never spawned does not help.
    var attemptedProfiles: [String]
    /// Measured evidence that the material exceeds a smaller window or
    /// cannot be sharded.
    var contextEvidence: String
    /// Why independent worker packets cannot solve this.
    var whyNotDecompose: String

    /// Parse the `escalation` argument of a `spawn_agent` call.
    ///
    /// Accepts both a JSON string and a real object for the same reason
    /// `task` does: the tool parameter vocabulary has no object type, but
    /// models send objects anyway, and losing a spawn to a formatting
    /// preference helps nobody.
    static func parse(_ value: AgentJSONValue?) -> AgentDeepAdmissionTicket? {
        guard let fields = AgentJSONValue.objectFields(unwrapping: value) else { return nil }

        let reason = trimmedString(fields["reason"])
        let contextEvidence = trimmedString(fields["context_evidence"])
        let whyNotDecompose = trimmedString(fields["why_not_decompose"])
        let attempted = stringList(fields["attempted_profiles"])
        // An entirely empty object is the same as no ticket at all; saying
        // so here keeps the refusal message accurate.
        guard !reason.isEmpty || !contextEvidence.isEmpty
            || !whyNotDecompose.isEmpty || !attempted.isEmpty else { return nil }

        return AgentDeepAdmissionTicket(
            reason: reason,
            attemptedProfiles: attempted,
            contextEvidence: contextEvidence,
            whyNotDecompose: whyNotDecompose
        )
    }

    private static func trimmedString(_ value: AgentJSONValue?) -> String {
        value?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func stringList(_ value: AgentJSONValue?) -> [String] {
        // Tolerate `attempted_profiles: "scout"` — a one-element list that
        // lost its brackets is still a usable claim.
        if let single = value?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !single.isEmpty {
            return [single]
        }
        guard case .array(let items)? = value else { return [] }
        return items.compactMap {
            let text = $0.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }
    }
}

/// What this session was observed doing, which is what a ticket gets checked
/// against. Value type on purpose: `authorize` returns the updated
/// observation rather than mutating shared state, so the decision is a pure
/// function and testable without a runtime.
nonisolated struct AgentDeepAdmissionObservation: Equatable, Sendable {
    /// Lower-tier trades that actually ran in this session, lowercased.
    /// Recorded only after a spawn passes packet and write-set validation —
    /// a rejected spawn must not become the evidence that unlocks deep.
    var attemptedProfiles: Set<String> = []
    /// Successful first-hand read-only inspections (grep, read, git history).
    var successfulInspections: Int = 0
    /// Deep spawns already admitted this session.
    var deepCalls: Int = 0

    mutating func recordProfileAttempt(_ profileID: String) {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized != AgentSubagentProfileCatalog.deepID else { return }
        attemptedProfiles.insert(normalized)
    }

    mutating func recordToolSuccess(_ toolName: String) {
        guard AgentDeepAdmission.inspectionToolNames.contains(toolName) else { return }
        successfulInspections += 1
    }
}

nonisolated enum AgentDeepAdmission {
    /// Below this, a field is a gesture rather than a statement. Generous on
    /// purpose: this gate is here to catch `reason: "needed"`, not to grade
    /// prose.
    static let minimumFieldCharacters = 12

    /// Inspections that count as having looked at the repository yourself.
    /// Only read-only tools whose success means something was actually read;
    /// a failed grep teaches the session nothing and must not accumulate.
    static let inspectionToolNames: Set<String> = [
        "grep_files", "search_files", "list_directory", "read_file", "glob",
        "git_status", "git_diff", "git_log", "git_blame",
    ]

    /// Corroboration threshold when no lower-tier trade was run: the session
    /// must have looked at the repository itself at least this many times.
    /// Two is the point where "I checked and it doesn't fit" stops being an
    /// assertion about a repository nobody opened.
    static let minimumInspectionsWithoutWorkerAttempt = 2

    /// Deep spawns allowed per session before the budget refuses.
    ///
    /// willdeep-rs allows one per harness; a WillDeep session is much longer
    /// than a CLI harness, so one would spend the whole session's allowance
    /// on its first hard question. Configurable, and 0 disables deep outright.
    static let defaultBudgetPerSession = 3
    static let budgetCeiling = 16

    static func clampBudget(_ value: Int) -> Int {
        min(max(0, value), budgetCeiling)
    }

    enum Refusal: Equatable, Error {
        case ticketMissing
        case fieldTooVague(field: String)
        case noAttemptedProfiles
        case noCorroboratingWork
        case budgetExhausted(limit: Int)

        /// What the model is told. These are the only explanation the model
        /// gets, so each one names the specific thing that was missing and
        /// what to do instead — a refusal it cannot act on just becomes a
        /// retry with the same arguments.
        var modelFacingMessage: String {
            switch self {
            case .ticketMissing:
                return "The `deep` trade is the scarce 1M tier and needs an `escalation` ticket: `reason` (why the standard tier could not finish), `attempted_profiles` (the lower trades you already ran), `context_evidence` (measured evidence the material does not fit or shard), and `why_not_decompose` (why worker packets cannot cover it). If you have not tried a bounded trade yet, do that first — that is usually the answer."
            case .fieldTooVague(let field):
                return "The `deep` escalation was refused: `\(field)` is too short to be a reason. State the concrete blocker in a sentence."
            case .noAttemptedProfiles:
                return "The `deep` escalation was refused: `attempted_profiles` is empty. Name the bounded trades you already ran in this session, or run one before escalating."
            case .noCorroboratingWork:
                return "The `deep` escalation was refused: this session has not been observed running any of the lower trades you named, nor doing enough first-hand inspection to know the work does not fit. Spawn a bounded worker (scout/reader/implementer) or inspect the repository yourself, then escalate with what you found."
            case .budgetExhausted(let limit):
                return limit == 0
                    ? "The `deep` trade is disabled in this workspace's settings. Decompose the work into bounded trades, or ask the user to raise the deep budget."
                    : "The `deep` budget for this session is spent (\(limit) call\(limit == 1 ? "" : "s")). Decompose what remains into bounded trades, or ask the user to raise the budget in settings."
            }
        }
    }

    /// Decide whether a `deep` spawn may proceed.
    ///
    /// Returns the updated observation on success — the caller stores it, so
    /// the budget only moves when a spawn is actually admitted.
    static func authorize(
        ticket: AgentDeepAdmissionTicket?,
        observation: AgentDeepAdmissionObservation,
        budget: Int = defaultBudgetPerSession
    ) -> Result<AgentDeepAdmissionObservation, Refusal> {
        let budget = clampBudget(budget)
        // Check the budget first when it is zero: "deep is turned off" is a
        // more useful thing to hear than a critique of a ticket that was
        // never going to be accepted.
        if budget == 0 { return .failure(.budgetExhausted(limit: 0)) }

        guard let ticket else { return .failure(.ticketMissing) }

        for (name, value) in [
            ("reason", ticket.reason),
            ("context_evidence", ticket.contextEvidence),
            ("why_not_decompose", ticket.whyNotDecompose),
        ] where value.count < minimumFieldCharacters {
            return .failure(.fieldTooVague(field: name))
        }

        let namedProfiles = ticket.attemptedProfiles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !namedProfiles.isEmpty else { return .failure(.noAttemptedProfiles) }

        // The cross-check: at least one named trade really ran, or the
        // session did its own looking. Without this the ticket is just the
        // model asserting it tried, which is the thing being verified.
        let observedAttempt = namedProfiles.contains { observation.attemptedProfiles.contains($0) }
        if !observedAttempt,
           observation.successfulInspections < minimumInspectionsWithoutWorkerAttempt {
            return .failure(.noCorroboratingWork)
        }

        guard observation.deepCalls < budget else {
            return .failure(.budgetExhausted(limit: budget))
        }

        var updated = observation
        updated.deepCalls += 1
        return .success(updated)
    }
}
