//
//  AgentContextRunwayHandoffDisplay.swift
//  WillDeep
//
//  Splits the `NEXT PROMPT` relay line out of a context-runway handover so
//  the transcript stops showing an instruction the host is about to run by
//  itself.
//

import WillDeepCore
import Foundation

/// Presentation-side companion to `AgentContextRunwayPolicy`.
///
/// The handover the model writes at ~90% context is five sections, and four
/// of them are for the human: why it stopped, what got verified, which
/// anchors survive compression, what is left. The fifth — `NEXT PROMPT` — is
/// a *machine* instruction: `AppStateAgentContextCompression` compresses the
/// conversation the moment the turn ends and resumes the work itself, so by
/// the time a person finishes reading that paragraph the session has usually
/// already acted on it. Left in the body it reads as "you must now copy this
/// somewhere", which is exactly the thing nobody has to do.
///
/// So the finished handover is not rendered as prose at all: it becomes a
/// card (`AgentContextRunwayHandoffHistoryRenderer`) whose sections this type
/// parses out, with the relay line shown as "what continuing will send" above
/// two actions — continue here, or carry it into a fresh session. The stored
/// `content` is untouched — compression, resume, copy, export and the
/// transcript reader all still see the complete handover.
nonisolated enum AgentContextRunwayHandoffDisplay {
    /// Section labels of the handover contract in `AgentContextRunwayPolicy
    /// .handoffPrompt`. Deliberately duplicated as display-side literals
    /// rather than shared with the prompt: the prompt is a model-facing
    /// English contract that may be reworded, while this list has to keep
    /// recognizing whatever older sessions already stored on disk.
    static let relayLabel = "NEXT PROMPT"
    static let companionLabels = ["PAUSE", "DONE", "ANCHORS", "REMAINING"]

    /// How many *other* handover sections must be present before the relay
    /// line is treated as protocol rather than prose.
    ///
    /// Without this floor, an assistant answering a question *about* the
    /// handoff feature ("the model writes a NEXT PROMPT line…") would have
    /// its own sentence silently swallowed. Requiring the surrounding
    /// sections means the message really is a handover.
    ///
    /// Raised from 2 to 3 (plus the `PAUSE` requirement below) when the
    /// handover stopped being "prose minus one line" and became a card that
    /// replaces the whole message body: a false positive used to cost one
    /// hidden sentence, and now costs the entire reply's normal rendering.
    static let minimumCompanionSections = 3

    /// The section that makes a handover a handover. Every other label shows
    /// up in ordinary engineering prose ("DONE: 3 of 5", "REMAINING work"),
    /// while `PAUSE:` at the head of a line is the one thing only the
    /// handover contract asks for.
    static let requiredCompanionLabel = "PAUSE"

    /// One human-facing section of the handover, in the order the model wrote
    /// it. `NEXT PROMPT` is deliberately not in here — it lives on
    /// `relayPrompt` because it is the payload of an action, not a paragraph.
    struct Section: Equatable {
        /// Canonical contract label (`PAUSE`, `DONE`, `ANCHORS`,
        /// `REMAINING`), uppercased regardless of how the model decorated it.
        let label: String
        /// The section text with its label and colon stripped.
        let body: String
    }

    struct Extraction: Equatable {
        /// Body to render, with the relay section removed. Equal to the input
        /// when this message is not a handover.
        let visibleContent: String
        /// The relay instruction with its `NEXT PROMPT:` label stripped, or
        /// nil when this message carries no recognizable handover.
        let relayPrompt: String?
        /// The human-facing sections, in written order. Empty when this
        /// message is not a handover — a non-handover has no sections to
        /// invent, and callers must not fall back to guessing.
        let sections: [Section]

        var isHandoff: Bool { relayPrompt != nil }
    }

    static func extract(from content: String) -> Extraction {
        let lines = content.components(separatedBy: .newlines)
        var labeled: [(label: String, range: Range<Int>)] = []
        var isInsideFence = false
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            // A fenced block is a quotation of the protocol, not the protocol.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInsideFence.toggle()
                index += 1
                continue
            }
            guard !isInsideFence, let label = sectionLabel(of: lines[index]) else {
                index += 1
                continue
            }
            // Keep the FIRST occurrence of each label: a model that repeats
            // itself has already made the later copies redundant, and
            // anchoring the relay on the first keeps its range contiguous.
            if !labeled.contains(where: { $0.label == label }) {
                labeled.append((label, index..<endOfSection(startingAfter: index, in: lines)))
            }
            index += 1
        }

        let companions = labeled.filter { $0.label != relayLabel }
        guard let relayRange = labeled.first(where: { $0.label == relayLabel })?.range,
              companions.count >= minimumCompanionSections,
              companions.contains(where: { $0.label == requiredCompanionLabel }) else {
            return Extraction(visibleContent: content, relayPrompt: nil, sections: [])
        }

        let relayPrompt = sectionText(of: lines[relayRange])
        guard !relayPrompt.isEmpty else {
            // A bare `NEXT PROMPT:` with nothing after it gives the card
            // nothing to send, so leave the body exactly as written.
            return Extraction(visibleContent: content, relayPrompt: nil, sections: [])
        }

        var remaining = Array(lines[..<relayRange.lowerBound])
        remaining.append(contentsOf: lines[relayRange.upperBound...])
        while let last = remaining.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            remaining.removeLast()
        }
        return Extraction(
            visibleContent: remaining.joined(separator: "\n"),
            relayPrompt: relayPrompt,
            sections: companions.map {
                Section(label: $0.label, body: sectionText(of: lines[$0.range]))
            }
        )
    }

    /// Convenience for callers that only need the footer action payload.
    static func relayPrompt(in content: String) -> String? {
        extract(from: content).relayPrompt
    }

    /// What the "continue here" footer action actually sends.
    ///
    /// The button sends immediately — it is a shortcut, and a shortcut that
    /// still needs a Return keypress is just a slower way to type one word.
    /// The composer is empty in almost every case this button appears (the
    /// user just finished reading the handover), but when it is not, the
    /// draft rides along instead of being dropped: `sendAgentMessage()`
    /// clears the input, so anything left behind would be gone with no way
    /// to get it back.
    static func composedResumeInput(currentInput: String, resumeWord: String) -> String {
        let draft = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? resumeWord : "\(draft)\n\n\(resumeWord)"
    }

    // MARK: - Parsing

    /// The relay section runs until the next handover section starts, or to
    /// the end of the message. The contract puts `NEXT PROMPT` last, so in
    /// practice this is "to the end" — but a model that reorders the sections
    /// must not take the rest of the handover down with it.
    private static func endOfSection(startingAfter start: Int, in lines: [String]) -> Int {
        var index = start + 1
        var isInsideFence = false
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInsideFence.toggle()
                index += 1
                continue
            }
            if !isInsideFence, sectionLabel(of: lines[index]) != nil {
                return index
            }
            index += 1
        }
        return lines.count
    }

    /// The text of one handover section: everything after the label's colon
    /// on the opening line, plus the lines that follow it.
    private static func sectionText(of lines: ArraySlice<String>) -> String {
        guard let first = lines.first else { return "" }
        var body: [String] = []
        let stripped = undecorated(first)
        if let colonIndex = stripped.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            // `- **NEXT PROMPT:** text` leaves a dangling `**` after the
            // colon — the emphasis run that opened before the label.
            let tail = stripped[stripped.index(after: colonIndex)...]
                .drop(while: { $0 == "*" || $0 == "_" })
            body.append(String(tail))
        }
        body.append(contentsOf: lines.dropFirst())
        return body
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the handover section this line opens, or nil.
    private static func sectionLabel(of line: String) -> String? {
        let stripped = undecorated(line)
        guard !stripped.isEmpty else { return nil }
        // Longest label first: nothing here is a prefix of anything else
        // today, but ordering keeps that from becoming a silent bug.
        for label in ([relayLabel] + companionLabels).sorted(by: { $0.count > $1.count }) {
            guard stripped.prefix(label.count).uppercased() == label else { continue }
            var remainder = stripped.dropFirst(label.count)
            while let first = remainder.first, first == "*" || first == "_" || first == " " {
                remainder = remainder.dropFirst()
            }
            if remainder.isEmpty || remainder.first == ":" || remainder.first == "：" {
                return label
            }
        }
        return nil
    }

    /// Strips list bullets, quote markers, heading hashes and emphasis from
    /// the head of a line. Models write the same section as `NEXT PROMPT:`,
    /// `- **NEXT PROMPT:**` and `## NEXT PROMPT` depending on the day.
    private static func undecorated(_ line: String) -> String {
        var value = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        var changed = true
        while changed {
            changed = false
            if let first = value.first, "#>-*+•".contains(first) {
                // `**BOLD**` opens with the same `*` a bullet uses. Drop the
                // emphasis run wholesale so `- **DONE:**` reduces cleanly.
                let marker = first
                var candidate = value
                while candidate.first == marker {
                    candidate = candidate.dropFirst()
                }
                value = candidate.drop(while: { $0 == " " || $0 == "\t" })
                changed = true
            } else if value.hasPrefix("__") {
                value = value.dropFirst(2).drop(while: { $0 == " " || $0 == "\t" })
                changed = true
            }
        }
        return String(value)
    }
}
