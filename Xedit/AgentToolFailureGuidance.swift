//
//  AgentToolFailureGuidance.swift
//  WillDeep
//
//  The host note appended to every failed tool result. The early note
//  pushes the model to recover ("do not stop here"), which is right for a
//  typo or a missing flag. Repeated unconditionally it turned into a runaway
//  engine: one 2026-09-04 turn made 256 calls (225 web_fetch guesses at 404
//  URLs), and the 2026-09-22 Baidu turn escalated from browser tools to UA
//  spoofing, OCR, proxies and hand-written HTML parsers. Past a small budget
//  the note flips to "stop and report" — or, when nobody is watching (Goal,
//  dispatch node, scheduled routine), to "switch approach, park the blocker
//  in the plan, keep going; report only when everything left is blocked".
//

import Foundation

nonisolated enum AgentToolFailureGuidance {
    /// Failures of one tool in one turn before the note flips.
    static let perToolFailureLimit = 3
    /// Failures across all tools in one turn before the note flips.
    static let perTurnFailureLimit = 8

    static let recoverNote = "(WillDeep: this tool call failed. Do not stop here — diagnose the cause from the exit code/stderr above and try another approach to accomplish the goal. Only give up if you are genuinely blocked, and then explain what you tried and what you still need.)"

    /// Whether a human is around to receive "stop and report". Goal runs,
    /// dispatch nodes and scheduled routines continue with nobody watching;
    /// their system prompt says ordinary errors are not a reason to contact
    /// the user, so the breaker must not tell them the opposite at 3 a.m.
    enum Supervision: Equatable {
        case interactive
        case unattended
    }

    private static let accessControlWarning = "Never work around a site's access controls (captcha, security verification, login walls, rate limits) with spoofed user agents, proxies, third-party scraping relays or OCR."

    static func note(
        toolName: String,
        toolFailures: Int,
        turnFailures: Int,
        supervision: Supervision = .interactive
    ) -> String {
        guard toolFailures >= perToolFailureLimit || turnFailures >= perTurnFailureLimit else {
            return recoverNote
        }
        let tally = "\(toolName) has failed \(toolFailures) time(s) this turn, \(turnFailures) tool failure(s) in total."
        switch supervision {
        case .interactive:
            return "(WillDeep: \(tally) Stop retrying variations. Summarize for the user what you tried, what each attempt returned, and what you need from them — unless one clearly different approach remains that you have not tried yet. \(accessControlWarning))"
        case .unattended:
            return "(WillDeep: \(tally) This run is unattended: nobody is waiting to answer, so do not stop to ask the user. Stop retrying variations of the same call and switch to a clearly different approach. If this step stays blocked, record the blocker in the active plan with `update_plan` (the concrete error goes in `note`), then move on to other steps that can still make progress. Only when every remaining step is blocked, end the turn with a report of what you tried, what each attempt returned, and what would unblock it. \(accessControlWarning))"
        }
    }
}

extension AppState {
    /// Count this failure for the turn and return the note to append.
    func recordToolFailureGuidance(runtime: AgentRuntime, toolName: String) -> String {
        runtime.currentTurnToolFailureCounts[toolName, default: 0] += 1
        return AgentToolFailureGuidance.note(
            toolName: toolName,
            toolFailures: runtime.currentTurnToolFailureCounts[toolName] ?? 0,
            turnFailures: runtime.currentTurnToolFailureCounts.values.reduce(0, +),
            supervision: toolFailureSupervision(for: runtime)
        )
    }

    /// Same notion of "nobody is watching" the rest of the harness uses:
    /// dispatch/routine runs (`isUnattendedRun`), and a Goal the host keeps
    /// continuing on its own (`goalOwnsAutomaticContinuation`). A Goal still
    /// being defined, or one with an operator message queued, is interactive.
    func toolFailureSupervision(for runtime: AgentRuntime) -> AgentToolFailureGuidance.Supervision {
        runtime.isUnattendedRun || goalOwnsAutomaticContinuation(for: runtime) ? .unattended : .interactive
    }
}
