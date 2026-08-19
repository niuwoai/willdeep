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
        - WillDeep keeps the full transcript locally and will attempt normal context compression after this turn, so the user may continue in this same session once compression finishes.
        - A brand-new session does not automatically inherit this conversation. The NEXT PROMPT must therefore point to durable workspace state instead of saying only "continue".
        - Preserve any required machine-readable `progress` or `goal-check` block, using no changes when nothing became newly verified.
        """
    }
}
