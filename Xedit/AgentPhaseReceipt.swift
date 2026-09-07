//
//  AgentPhaseReceipt.swift
//  WillDeep
//
//  Three lines at every phase boundary of a Goal: what got done, what comes
//  next, roughly how long is left. Written when the host closes a roadmap
//  phase, persisted with the phase, shown on the goal card, and handed back
//  to the model when a restarted app or an interrupted run resumes — so
//  resumption starts from the last boundary instead of from nothing.
//
//  Two authors, in this order of trust:
//
//  1. The host writes one immediately from evidence it already holds: the
//     phase title, the plan's step tally, and the phase's own duration
//     projected over the phases still open. This one always exists and can
//     never stall.
//  2. The next planning prompt asks the model for a `receipt` block with the
//     same three lines. When it arrives it replaces the host's DONE/NEXT
//     wording, because the model knows what the steps meant; the ETA stays
//     host-computed, because the model's guess at its own speed is the one
//     line nobody should trust.
//

import Foundation

nonisolated struct AgentPhaseReceipt: Codable, Equatable, Sendable {
    enum Author: String, Codable, Sendable {
        case host
        case model
    }

    var done: String
    var next: String
    /// Rough remaining time in seconds for the whole Goal after this phase,
    /// nil when the host had nothing to project from (first phase closed
    /// with no start time).
    var remainingSeconds: TimeInterval?
    var recordedAt: Date
    var author: Author

    static let doneLabel = "DONE"
    static let nextLabel = "NEXT"
    static let etaLabel = "ETA"
    static let fenceLanguage = "receipt"
    static let maximumLineCharacters = 240

    // MARK: Host synthesis

    /// The host's receipt for the phase at `completedIndex`, using only what
    /// the roadmap and the finished plan already say.
    static func synthesized(
        roadmap: AgentGoalRoadmap,
        completedIndex: Int,
        plan: AgentPlan?,
        phaseStartedAt: Date?,
        now: Date = Date()
    ) -> AgentPhaseReceipt {
        let phases = roadmap.phases
        let completed = phases.indices.contains(completedIndex) ? phases[completedIndex] : nil
        let doneSteps = plan?.steps.filter { $0.status == .done }.count ?? 0
        let totalSteps = plan?.steps.count ?? 0
        let done: String
        if let completed {
            done = totalSteps > 0
                ? "\(completed.title) — \(doneSteps)/\(totalSteps) steps done"
                : completed.title
        } else {
            done = "Phase \(completedIndex + 1) finished"
        }

        let nextIndex = completedIndex + 1
        let next = phases.indices.contains(nextIndex)
            ? phases[nextIndex].title
            : "All phases complete; final acceptance"

        var remaining: TimeInterval?
        if let phaseStartedAt {
            let phaseDuration = max(0, now.timeIntervalSince(phaseStartedAt))
            let openPhases = phases.indices.filter { $0 > completedIndex }.count
            remaining = phaseDuration * Double(openPhases)
        }
        return AgentPhaseReceipt(
            done: clip(done),
            next: clip(next),
            remainingSeconds: remaining,
            recordedAt: now,
            author: .host
        )
    }

    /// Fold a model-written receipt into a host one: wording from the model,
    /// timing from the host.
    func refined(with modelReceipt: AgentPhaseReceipt) -> AgentPhaseReceipt {
        var merged = self
        if !modelReceipt.done.isEmpty { merged.done = modelReceipt.done }
        if !modelReceipt.next.isEmpty { merged.next = modelReceipt.next }
        merged.author = .model
        return merged
    }

    // MARK: Model-facing prompt and parser

    /// Appended to the next-phase planning prompt. Kept to one fenced block
    /// so the existing plan-block parser is not confused by extra prose.
    static let promptFragment = """
    Before the plan block, write a fenced `receipt` block with exactly these lines for the phase that just ended:
    DONE: what was actually completed, with the evidence that verified it
    NEXT: the first concrete action of the next phase
    Keep each line under 240 characters. This receipt is shown to the user and replayed when work resumes after an interruption.
    """

    /// Parse a fenced `receipt` block. Lenient about label decoration
    /// (`- **DONE:**`, `DONE —`) and returns nil when neither line is present.
    static func parse(from content: String) -> AgentPhaseReceipt? {
        guard let block = fencedBlock(in: content) else { return nil }
        var done = ""
        var next = ""
        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if let value = value(of: line, label: doneLabel) { done = value }
            if let value = value(of: line, label: nextLabel) { next = value }
        }
        guard !done.isEmpty || !next.isEmpty else { return nil }
        return AgentPhaseReceipt(
            done: clip(done),
            next: clip(next),
            remainingSeconds: nil,
            recordedAt: Date(),
            author: .model
        )
    }

    /// Compact rendering for prompts and the goal card.
    var lines: [String] {
        var result = ["\(Self.doneLabel): \(done)", "\(Self.nextLabel): \(next)"]
        if let remainingSeconds {
            result.append("\(Self.etaLabel): ~\(Self.formatDuration(remainingSeconds)) remaining")
        }
        return result
    }

    /// Block handed back to the model when resuming.
    var resumeContextBlock: String {
        """
        <last_phase_receipt recorded="\(ISO8601DateFormatter().string(from: recordedAt))">
        \(lines.joined(separator: "\n"))
        </last_phase_receipt>
        """
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    // MARK: Helpers

    private static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumLineCharacters else { return trimmed }
        return String(trimmed.prefix(maximumLineCharacters - 1)) + "…"
    }

    private static func fencedBlock(in content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        var inside = false
        var collected: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inside {
                if trimmed.hasPrefix("```"), trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == fenceLanguage {
                    inside = true
                }
                continue
            }
            if trimmed.hasPrefix("```") { return collected.joined(separator: "\n") }
            collected.append(line)
        }
        return inside ? collected.joined(separator: "\n") : nil
    }

    private static func value(of line: String, label: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Strip list markers and bold decoration the model likes to add.
        for prefix in ["- ", "* ", "• "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        text = text.replacingOccurrences(of: "**", with: "")
        guard text.uppercased().hasPrefix(label) else { return nil }
        var rest = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        for separator in [":", "：", "—", "-"] where rest.hasPrefix(separator) {
            rest = String(rest.dropFirst(separator.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return rest.isEmpty ? nil : rest
    }
}
