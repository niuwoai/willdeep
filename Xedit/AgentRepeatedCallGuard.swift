//
//  AgentRepeatedCallGuard.swift
//  WillDeep
//
//  Detects a model spinning in place: the same tool called with the same
//  arguments, getting back the same result (or failing every time). The
//  failure breaker (`AgentToolFailureGuidance`) only sees failures; a model
//  that re-reads the same file or re-runs the same passing command forever
//  looked busy to every other check, and in Goal mode that busy-ness passed
//  for progress.
//
//  Pure logic lives here; `AppStateAgentRepeatedCallGuard.swift` wires it to
//  tool results and to the Goal continuation decision.
//

import CryptoKit
import Foundation

nonisolated enum AgentRepeatedCallGuard {
    /// Identical repeats at which the tool result carries a "change approach"
    /// note for the model.
    static let hintThreshold = 3
    /// Identical repeats at which a Goal round stops counting as progress.
    static let stallThreshold = 5
    /// Distinct call signatures remembered at once. A Goal ledger survives
    /// continuation turns, so it needs a ceiling; the least recently seen
    /// signature is dropped first.
    static let maximumTrackedSignatures = 32
    /// Characters of a SHA-256 hex digest kept for signatures and results.
    static let digestLength = 32

    /// Tools that are polled by design: background-job and media-task status,
    /// explicit waits, and read-only plan/status queries. Asking the same
    /// question until the answer changes is their job.
    static let pollingToolNames: Set<String> = [
        "get_job_output",
        "list_jobs",
        "list_queued_tasks",
        "list_media_tasks",
        "some_im_poll_media_task",
        "replicate_poll_prediction",
        "short_drama_refresh_media_tasks",
        "chrome_wait_for",
        "computer_use_wait_for",
        "embedded_browser_wait_for",
        "chrome_status",
        "embedded_browser_status",
        "computer_use_get_app_state",
        "terminal_snapshot",
        "git_status",
        "update_plan",
    ]

    /// Argument keys that carry per-call noise rather than intent. Keys with
    /// a leading underscore are host-private and never part of the intent.
    static let volatileArgumentKeys: Set<String> = [
        "nonce",
        "request_id",
        "idempotency_key",
        "cache_buster",
        "timestamp",
    ]

    static func isExempt(toolName: String) -> Bool {
        pollingToolNames.contains(toolName)
    }

    /// Canonical form of a tool's arguments: keys sorted, whitespace between
    /// tokens dropped, string values trimmed, volatile keys removed. Text
    /// that is not a JSON object falls back to its trimmed self.
    static func normalizedArguments(_ argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(canonical(object)),
              let encoded = try? JSONSerialization.data(
                  withJSONObject: canonical(object),
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: encoded, encoding: .utf8) else {
            return trimmed
        }
        return text
    }

    static func signature(toolName: String, argumentsJSON: String) -> String {
        digest(toolName + "\u{1F}" + normalizedArguments(argumentsJSON))
    }

    static func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hash.prefix(digestLength))
    }

    private static func canonical(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, nested) in dictionary
            where !key.hasPrefix("_") && !volatileArgumentKeys.contains(key) {
                result[key] = canonical(nested)
            }
            return result
        case let array as [Any]:
            return array.map(canonical)
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return value
        }
    }

    /// Model-facing, appended after the tool result. Prompt text rather than
    /// UI copy: English and outside the string catalog, like the failure note.
    static func note(toolName: String, count: Int, failed: Bool, countsAgainstGoalProgress: Bool) -> String {
        let outcome = failed ? "it has failed every time" : "the result has not changed"
        let goal = countsAgainstGoalProgress
            ? " Rounds spent repeating it no longer count as Goal progress."
            : ""
        return "(WillDeep: this is call #\(count) of \(toolName) with identical arguments, and \(outcome). Repeating it will not produce anything new — change the arguments, use a different tool, or take a different approach. If you are waiting on a background task, rely on its completion notice instead of re-checking.\(goal))"
    }
}

/// Recently seen call signatures and what each returned. Persisted on the
/// Goal so a Goal cannot reset its own count by ending the turn; ordinary
/// conversations keep one per turn on the runtime.
nonisolated struct AgentRepeatedCallLedger: Codable, Equatable {
    enum Outcome: Equatable {
        case succeeded(resultDigest: String)
        case failed
    }

    struct Entry: Codable, Equatable {
        var signature: String
        var toolName: String
        var count: Int
        /// Digest of the last successful result; nil when the call failed.
        var resultDigest: String?
        var lastSeen: Int
    }

    var entries: [Entry] = []
    var sequence: Int = 0

    /// Record one completed call. Returns how many times in a row this exact
    /// call produced this exact outcome, or nil for exempt polling tools.
    /// A changed result starts the count over: the call did learn something.
    mutating func observe(toolName: String, argumentsJSON: String, outcome: Outcome) -> Int? {
        guard !AgentRepeatedCallGuard.isExempt(toolName: toolName) else { return nil }
        sequence += 1
        let signature = AgentRepeatedCallGuard.signature(toolName: toolName, argumentsJSON: argumentsJSON)
        let resultDigest: String?
        switch outcome {
        case .succeeded(let digest): resultDigest = digest
        case .failed: resultDigest = nil
        }
        if let index = entries.firstIndex(where: { $0.signature == signature }) {
            let unchanged = entries[index].resultDigest == resultDigest
            entries[index].count = unchanged ? entries[index].count + 1 : 1
            entries[index].resultDigest = resultDigest
            entries[index].lastSeen = sequence
            return entries[index].count
        }
        entries.append(Entry(signature: signature, toolName: toolName, count: 1,
                             resultDigest: resultDigest, lastSeen: sequence))
        if entries.count > AgentRepeatedCallGuard.maximumTrackedSignatures,
           let oldest = entries.indices.min(by: { entries[$0].lastSeen < entries[$1].lastSeen }) {
            entries.remove(at: oldest)
        }
        return 1
    }
}
