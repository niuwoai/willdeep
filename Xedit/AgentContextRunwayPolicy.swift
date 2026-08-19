//
//  AgentContextRunwayPolicy.swift
//  WillDeep
//
//  Ordered stop for a single tool loop that outgrows the runway between
//  normal post-turn compression opportunities.
//

import Foundation

/// Protects the final slice of a model context window for a useful handover.
///
/// Normal context management still belongs to `AppStateAgentContextCompression`:
/// old turns are summarized after a response and the full local transcript is
/// preserved. This policy covers the different failure mode where one user turn
/// keeps calling tools long enough to move from safe to nearly full before that
/// post-turn compressor gets a chance to run.
nonisolated enum AgentContextRunwayPolicy {
    static let criticalUsedFraction = 0.90
    static let firstGuardedToolRound = 1

    /// How many times one user turn may be auto-resumed after a runway stop.
    ///
    /// The ordered stop plus compression normally buys back enough window for
    /// the work to finish. The case this bounds is the one where it doesn't:
    /// a task whose tool output refills the window as fast as compression
    /// drains it would otherwise loop stop → compress → resume → stop for as
    /// long as the user's credit lasts. After the ceiling the session parks
    /// and waits for a human.
    static let maximumAutomaticResumes = 3

    nonisolated struct Snapshot: Equatable, Sendable {
        let usedTokens: Int
        let contextWindow: Int

        var remainingTokens: Int {
            max(0, contextWindow - usedTokens)
        }

        var usedPercent: Int {
            min(100, max(0, Int((Double(usedTokens) / Double(max(1, contextWindow))) * 100)))
        }
    }

    nonisolated enum Decision: Equatable, Sendable {
        case continueExecution
        case handoff(Snapshot)
    }

    static func evaluate(
        usedTokens: Int,
        contextWindow: Int,
        toolRound: Int,
        handoffAlreadyRequested: Bool
    ) -> Decision {
        guard !handoffAlreadyRequested,
              toolRound >= firstGuardedToolRound else {
            return .continueExecution
        }

        let snapshot = Snapshot(
            usedTokens: max(0, usedTokens),
            contextWindow: max(1, contextWindow)
        )
        let usedFraction = Double(snapshot.usedTokens) / Double(snapshot.contextWindow)
        guard usedFraction >= criticalUsedFraction else {
            return .continueExecution
        }
        return .handoff(snapshot)
    }

    /// Model-facing instruction, intentionally not localized UI copy. The
    /// ordinary language instruction still controls the visible reply.
    static func handoffPrompt(snapshot: Snapshot) -> String {
        """
        === CONTEXT RUNWAY HANDOFF ===
        Host-observed context usage is approximately \(snapshot.usedTokens) of \(snapshot.contextWindow) tokens (\(snapshot.usedPercent)% used, about \(snapshot.remainingTokens) remaining). This estimate is a safety signal, not evidence that the task is complete.

        Stop opening new substantive work now. Do not call tools, edit files, start background work, or claim unverified completion. Use only evidence already present in this conversation and produce a compact handover in the user's language with exactly these sections:
        - PAUSE: say that context runway, not task completion, caused this ordered stop
        - DONE: only work actually completed and the evidence that verified it
        - ANCHORS: current branch/version when known, modified files, important paths/symbols, commands and test results needed to resume without guessing
        - REMAINING: unfinished work in execution order, plus concrete blockers or risks
        - NEXT PROMPT: one standalone sentence the user can send to resume, naming the first action and the most useful durable file/symbol anchor

        Continuity rules:
        - WillDeep keeps the full transcript locally and will compress this conversation as soon as this turn ends, then resume the work automatically using your NEXT PROMPT. Write it as the instruction that resumption will actually run.
        - Compression replaces the older turns with a summary, so anything only you can still see must be written into ANCHORS now or it is gone by the time work resumes.
        - A brand-new session does not automatically inherit this conversation. The NEXT PROMPT must therefore point to durable workspace state instead of saying only "continue".
        - Preserve any required machine-readable `progress` or `goal-check` block, using no changes when nothing became newly verified.
        """
    }

    /// Instruction handed back to the model after compression has reclaimed
    /// the window. The handover the model just wrote survives compression as
    /// part of the kept tail, so this only has to point at it rather than
    /// restate the task.
    static func resumePrompt(attempt: Int) -> String {
        """
        === CONTEXT RUNWAY RESUME ===
        Context compression finished and the window has been reclaimed. This is automatic resumption \(attempt) of at most \(maximumAutomaticResumes) for this task.

        Continue the work described by the NEXT PROMPT and REMAINING sections of your own handover above, treating its ANCHORS as the current state. Do not restate the handover, do not re-verify work its DONE section already recorded as verified, and do not start over from the original request.

        If the remaining work cannot be finished before the window fills again, prefer durable progress — write findings to files, land reviewable commits — over holding state in this conversation.
        """
    }
}
