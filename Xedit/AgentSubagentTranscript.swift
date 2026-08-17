//
//  AgentSubagentTranscript.swift
//  WillDeep
//
//  Durable per-round record of one `spawn_agent` child loop, plus the
//  sidecar store that persists it.
//
//  Why a sidecar instead of the session JSON: a child loop routinely runs
//  a dozen rounds and each tool result can be tens of KB. Folding that into
//  `AgentSession` would push every one of those bytes through the session
//  store's serial write pipeline on every autosave, for data the user opens
//  maybe once. The session keeps only a `subagentRunID` on the tool call;
//  the transcript lives in its own file and is loaded on demand when the
//  inspector opens.
//

import Foundation
import OSLog

nonisolated struct AgentSubagentTranscript: Codable, Equatable, Sendable {
    nonisolated struct ToolCall: Codable, Equatable, Sendable, Identifiable {
        var id: String { externalID }
        let externalID: String
        var name: String
        var argumentsJSON: String
        var result: String
        var resultWasTruncated: Bool
        var durationSeconds: Double
    }

    nonisolated struct Round: Codable, Equatable, Sendable, Identifiable {
        var id: Int { index }
        /// 1-based, matching the "第 N 轮" progress line on the tool card.
        let index: Int
        var content: String
        /// Only provider-emitted visible reasoning (DeepSeek-R1 / qwen3 style).
        /// Hidden chain-of-thought is never reconstructed or inferred here.
        var reasoning: String?
        var toolCalls: [ToolCall]
        var usageTokens: Int
        var startedAt: Date
        var finishedAt: Date?
    }

    let runID: UUID
    var label: String
    var prompt: String
    var model: String
    var status: AgentSubagentRun.Status
    var rounds: [Round]
    var report: String
    var usageTokens: Int
    var startedAt: Date
    var finishedAt: Date?
    /// True when at least one field in this record hit a storage cap.
    var didTruncate: Bool
    /// Which trade ran (`scout` / `reader` / `deep` / `editor`). Nil for
    /// records written before profiles existed.
    var profileID: String?
    /// Set when a cheap trade stalled and the run was re-done on the
    /// parent's model; carries the model that was escalated away from.
    /// Escalation is recorded rather than silent — see AgentSubagentEscalation.
    var escalatedFromModel: String?
    /// Verifier command attached to the run's task packet. Nil for runs
    /// without a verifier (all records before skill-workers.v1).
    var verifierCommand: String?
    /// Ground-truth outcome: whether the verifier command exited 0.
    /// Nil when no verifier ran — distinct from `false`, which is a real
    /// failure. "Worker Verified Success" counts only non-nil values.
    var verifierPassed: Bool?
    /// Verifier attempts consumed (1-based). Nil when no verifier ran.
    var attemptCount: Int?
    /// Citations the runtime spot-checked in a report-only run, and how many
    /// pointed at nothing. Nil when no check ran — a report-only trade has no
    /// verifier verdict to record, and these two are the only thing about its
    /// answer a program can confirm. See AgentSubagentCitationAudit.
    var citationsChecked: Int?
    var citationsUnverifiable: Int?
    /// Workspace HEAD when the run started; anchors the transcript as a
    /// replayable case (same commit + same task packet → comparable reruns).
    var repoCommit: String?

    var toolInvocationCount: Int {
        rounds.reduce(0) { $0 + $1.toolCalls.count }
    }

    init(
        runID: UUID,
        label: String,
        prompt: String,
        model: String,
        status: AgentSubagentRun.Status = .running,
        rounds: [Round] = [],
        report: String = "",
        usageTokens: Int = 0,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        didTruncate: Bool = false,
        profileID: String? = nil,
        escalatedFromModel: String? = nil,
        verifierCommand: String? = nil,
        verifierPassed: Bool? = nil,
        attemptCount: Int? = nil,
        citationsChecked: Int? = nil,
        citationsUnverifiable: Int? = nil,
        repoCommit: String? = nil
    ) {
        self.runID = runID
        self.label = label
        self.prompt = prompt
        self.model = model
        self.status = status
        self.rounds = rounds
        self.report = report
        self.usageTokens = usageTokens
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.didTruncate = didTruncate
        self.profileID = profileID
        self.escalatedFromModel = escalatedFromModel
        self.verifierCommand = verifierCommand
        self.verifierPassed = verifierPassed
        self.attemptCount = attemptCount
        self.citationsChecked = citationsChecked
        self.citationsUnverifiable = citationsUnverifiable
        self.repoCommit = repoCommit
    }
}

// MARK: - Storage caps

extension AgentSubagentTranscript {
    /// Caps are per-field and generous enough that a normal run is recorded
    /// verbatim; they exist so one runaway `read_file` on a 40 MB log cannot
    /// turn an inspector record into a multi-megabyte file.
    enum Limits {
        static let toolResultCharacters = 8_000
        static let roundContentCharacters = 16_000
        static let promptCharacters = 8_000
        static let reportCharacters = 32_000
    }

    /// Truncates `text` to `limit`, reporting whether it had to.
    static func clamped(_ text: String, to limit: Int) -> (text: String, didTruncate: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }
}

// MARK: - Sidecar store

/// On-disk home for subagent transcripts, one JSON file per run.
///
/// Deliberately not part of `AgentSessionStore`'s write pipeline: these
/// files are written once when a child loop ends and read only when the
/// user opens the inspector.
nonisolated enum AgentSubagentTranscriptStore {
    private static let log = Logger(subsystem: "com.willdeep.agent", category: "subagent-transcript")

    /// Sibling of the session directory, so the test-sandbox redirect in
    /// `AgentSessionStore.directory` carries over automatically.
    static var directory: URL {
        AgentSessionStore.directory
            .deletingLastPathComponent()
            .appendingPathComponent("subagent-transcripts", isDirectory: true)
    }

    static func fileURL(for runID: UUID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString.lowercased()).json", isDirectory: false)
    }

    static func save(_ transcript: AgentSubagentTranscript) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(transcript)
            try data.write(to: fileURL(for: transcript.runID), options: .atomic)
        } catch {
            // A missing inspector record must never break the turn that
            // produced it — the run's report is already delivered.
            log.warning(
                "subagent transcript save failed for \(transcript.runID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func load(runID: UUID) -> AgentSubagentTranscript? {
        let url = fileURL(for: runID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AgentSubagentTranscript.self, from: data)
        } catch {
            log.warning(
                "subagent transcript decode failed for \(runID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func delete(runID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: runID))
    }
}
