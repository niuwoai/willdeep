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
//  the note flips to "stop and report".
//

import Foundation

nonisolated enum AgentToolFailureGuidance {
    /// Failures of one tool in one turn before the note flips.
    static let perToolFailureLimit = 3
    /// Failures across all tools in one turn before the note flips.
    static let perTurnFailureLimit = 8

    static let recoverNote = "(WillDeep: this tool call failed. Do not stop here — diagnose the cause from the exit code/stderr above and try another approach to accomplish the goal. Only give up if you are genuinely blocked, and then explain what you tried and what you still need.)"

    static func note(toolName: String, toolFailures: Int, turnFailures: Int) -> String {
        guard toolFailures >= perToolFailureLimit || turnFailures >= perTurnFailureLimit else {
            return recoverNote
        }
        return "(WillDeep: \(toolName) has failed \(toolFailures) time(s) this turn, \(turnFailures) tool failure(s) in total. Stop retrying variations. Summarize for the user what you tried, what each attempt returned, and what you need from them — unless one clearly different approach remains that you have not tried yet. Never work around a site's access controls (captcha, security verification, login walls, rate limits) with spoofed user agents, proxies, third-party scraping relays or OCR.)"
    }
}

extension AppState {
    /// Count this failure for the turn and return the note to append.
    func recordToolFailureGuidance(runtime: AgentRuntime, toolName: String) -> String {
        runtime.currentTurnToolFailureCounts[toolName, default: 0] += 1
        return AgentToolFailureGuidance.note(
            toolName: toolName,
            toolFailures: runtime.currentTurnToolFailureCounts[toolName] ?? 0,
            turnFailures: runtime.currentTurnToolFailureCounts.values.reduce(0, +)
        )
    }
}
