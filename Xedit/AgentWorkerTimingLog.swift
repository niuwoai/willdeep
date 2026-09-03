//
//  AgentWorkerTimingLog.swift
//  WillDeep
//
//  A local, append-only JSONL record of how long Worker runs and parent
//  turns actually take. Session sidecars already carry per-run usage, but
//  they are per session and are rewritten in place; answering "did the
//  multi-worker mode make turns slower this week?" needs one flat file that
//  survives session deletion and can be tailed, grepped, or loaded into a
//  notebook without decoding 291 sidecars.
//
//  Two record kinds share the file, distinguished by `kind`:
//
//   - `worker_run`: one line per Worker run, whatever started it (a model
//     `spawn_agent`, a background spawn, the serial preflight, the parallel
//     scout, a failed-command repair, the coding pipeline).
//   - `turn`: one line per parent turn with the pre-stream, first-token and
//     first-tool-boundary anchors, the route the runtime chose, and how many
//     Worker runs the turn used. Comparing turns with and without workers is
//     the whole point.
//
//  Lives next to judge.jsonl / sandbox.jsonl under AgentAudit. No prompt or
//  output text is recorded — identifiers, timestamps, counts and model names
//  only.
//

import Foundation

nonisolated enum AgentWorkerTimingLog {
    static let fileName = "worker-timing.jsonl"
    static let rotatedFileName = "worker-timing.1.jsonl"
    /// One rotation keeps the log bounded without a background janitor.
    static let rotationThresholdBytes: UInt64 = 16 * 1024 * 1024

    struct WorkerRunEntry: Codable, Equatable, Sendable {
        var kind = "worker_run"
        let recordedAt: Date
        let runID: UUID
        let sessionID: UUID
        let userMessageID: UUID?
        let profileID: String
        let source: String
        let status: String
        let model: String?
        let providerID: String?
        let requestedAt: Date
        let startedAt: Date?
        let finishedAt: Date
        /// `startedAt - requestedAt`: time spent queued behind approvals or
        /// the provider slot before the Worker's first model round.
        let queueSeconds: Double?
        /// `finishedAt - startedAt`: the Worker's own wall-clock.
        let runSeconds: Double?
        let rounds: Int?
        let toolInvocations: Int?
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let acceptedOutput: Bool?
        /// Parallel scout only: whether the report reached the parent at a
        /// tool boundary before the turn ended.
        let deliveredAtToolBoundary: Bool?
        let note: String?

        init(
            recordedAt: Date = Date(),
            runID: UUID,
            sessionID: UUID,
            userMessageID: UUID?,
            profileID: String,
            source: String,
            status: String,
            model: String?,
            providerID: String?,
            requestedAt: Date,
            startedAt: Date?,
            finishedAt: Date,
            rounds: Int? = nil,
            toolInvocations: Int? = nil,
            promptTokens: Int? = nil,
            completionTokens: Int? = nil,
            totalTokens: Int? = nil,
            acceptedOutput: Bool? = nil,
            deliveredAtToolBoundary: Bool? = nil,
            note: String? = nil
        ) {
            self.recordedAt = recordedAt
            self.runID = runID
            self.sessionID = sessionID
            self.userMessageID = userMessageID
            self.profileID = profileID
            self.source = source
            self.status = status
            self.model = model
            self.providerID = providerID
            self.requestedAt = requestedAt
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.queueSeconds = startedAt.map { $0.timeIntervalSince(requestedAt) }
            self.runSeconds = startedAt.map { finishedAt.timeIntervalSince($0) }
            self.rounds = rounds
            self.toolInvocations = toolInvocations
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
            self.acceptedOutput = acceptedOutput
            self.deliveredAtToolBoundary = deliveredAtToolBoundary
            self.note = note
        }
    }

    struct TurnEntry: Codable, Equatable, Sendable {
        var kind = "turn"
        let recordedAt: Date
        let sessionID: UUID
        let turnID: UUID
        let providerID: String
        let model: String
        let routeProfileID: String?
        let routeConfidence: Int?
        let delegationPolicy: String
        let outcome: String
        let dispatchedAt: Date
        let requestSentAt: Date?
        let firstTokenAt: Date?
        let firstToolBoundaryAt: Date?
        let finishedAt: Date
        /// `requestSentAt - dispatchedAt`: everything the host did before the
        /// first provider request (routing, preflight, prompt assembly…).
        let preStreamSeconds: Double?
        /// `firstTokenAt - dispatchedAt`: what the user perceives as latency.
        let firstTokenSeconds: Double?
        let firstToolBoundarySeconds: Double?
        let totalSeconds: Double
        let rounds: Int
        let workerRuns: Int
        let parallelScout: String?

        init(probe: AgentTurnTimingProbe, finishedAt: Date = Date(), outcome: String) {
            self.recordedAt = finishedAt
            self.sessionID = probe.sessionID
            self.turnID = probe.turnID
            self.providerID = probe.providerID
            self.model = probe.model
            self.routeProfileID = probe.routeProfileID
            self.routeConfidence = probe.routeConfidence
            self.delegationPolicy = probe.delegationPolicy
            self.outcome = outcome
            self.dispatchedAt = probe.dispatchedAt
            self.requestSentAt = probe.requestSentAt
            self.firstTokenAt = probe.firstTokenAt
            self.firstToolBoundaryAt = probe.firstToolBoundaryAt
            self.finishedAt = finishedAt
            self.preStreamSeconds = probe.requestSentAt?.timeIntervalSince(probe.dispatchedAt)
            self.firstTokenSeconds = probe.firstTokenAt?.timeIntervalSince(probe.dispatchedAt)
            self.firstToolBoundarySeconds = probe.firstToolBoundaryAt?.timeIntervalSince(probe.dispatchedAt)
            self.totalSeconds = finishedAt.timeIntervalSince(probe.dispatchedAt)
            self.rounds = probe.rounds
            self.workerRuns = probe.workerRuns
            self.parallelScout = probe.parallelScout
        }
    }

    static func record(_ entry: WorkerRunEntry) {
        guard let line = encodeLine(entry) else { return }
        Task.detached(priority: .utility) {
            await AgentWorkerTimingLogWriter.shared.append(line)
        }
    }

    static func record(_ entry: TurnEntry) {
        guard let line = encodeLine(entry) else { return }
        Task.detached(priority: .utility) {
            await AgentWorkerTimingLogWriter.shared.append(line)
        }
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("AgentAudit", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func encodeLine<T: Encodable>(_ entry: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json + "\n"
    }
}

extension AgentWorkerTimingLog.WorkerRunEntry {
    /// Host-dispatched workers (preflight, repairs, coding pipeline) from the
    /// session ledger record.
    init(hostRecord record: AgentHostWorkerRunRecord, sessionID: UUID, finishedAt: Date) {
        self.init(
            runID: record.id,
            sessionID: sessionID,
            userMessageID: record.userMessageID,
            profileID: record.profileID,
            source: record.source.rawValue,
            status: record.status.rawValue,
            model: record.model,
            providerID: record.providerID,
            requestedAt: record.requestedAt,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt ?? finishedAt,
            rounds: record.usage?.roundCount,
            toolInvocations: record.usage?.toolInvocationCount,
            promptTokens: record.usage?.promptTokens,
            completionTokens: record.usage?.completionTokens,
            totalTokens: record.usage?.usageTokens,
            acceptedOutput: record.acceptedOutput
        )
    }

    /// Model-requested `spawn_agent` runs that ran in the background.
    init(backgroundRun run: AgentSubagentRun) {
        self.init(
            runID: run.id,
            sessionID: run.parentRuntimeID,
            userMessageID: nil,
            profileID: run.profileID,
            source: "backgroundSpawn",
            status: run.status.rawValue,
            model: run.model,
            providerID: run.providerID,
            requestedAt: run.startedAt,
            startedAt: run.startedAt,
            finishedAt: run.finishedAt ?? Date(),
            rounds: run.roundCount,
            toolInvocations: run.toolInvocationCount,
            promptTokens: run.usageSplit.prompt,
            completionTokens: run.usageSplit.completion,
            totalTokens: run.usageTokens
        )
    }
}

/// Per-turn anchors, kept on the runtime while the turn is live and folded
/// into one `turn` line when it ends.
nonisolated struct AgentTurnTimingProbe: Equatable, Sendable {
    let sessionID: UUID
    let turnID: UUID
    let dispatchedAt: Date
    var providerID: String
    var model: String
    var routeProfileID: String?
    var routeConfidence: Int?
    var delegationPolicy: String
    var requestSentAt: Date?
    var firstTokenAt: Date?
    var firstToolBoundaryAt: Date?
    var rounds: Int = 0
    var workerRuns: Int = 0
    /// `started` / `delivered` / `cancelled` / `dropped`, nil when no
    /// parallel scout ran for this turn.
    var parallelScout: String?

    mutating func noteRequestSent(at date: Date = Date()) {
        if requestSentAt == nil { requestSentAt = date }
        rounds += 1
    }

    mutating func noteFirstToken(at date: Date = Date()) {
        if firstTokenAt == nil { firstTokenAt = date }
    }

    mutating func noteToolBoundary(at date: Date = Date()) {
        if firstToolBoundaryAt == nil { firstToolBoundaryAt = date }
    }
}

/// Serial appender with a single rotation. Off the MainActor: a turn ending
/// must not wait for disk.
actor AgentWorkerTimingLogWriter {
    static let shared = AgentWorkerTimingLogWriter(url: AgentWorkerTimingLog.defaultURL())

    let url: URL
    private let rotationThresholdBytes: UInt64

    init(url: URL, rotationThresholdBytes: UInt64 = AgentWorkerTimingLog.rotationThresholdBytes) {
        self.url = url
        self.rotationThresholdBytes = rotationThresholdBytes
    }

    func append(_ line: String) {
        guard let bytes = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        rotateIfNeeded()
        if fileManager.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: [.atomic])
        }
    }

    private func rotateIfNeeded() {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              size >= rotationThresholdBytes else { return }
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(AgentWorkerTimingLog.rotatedFileName)
        try? fileManager.removeItem(at: rotated)
        try? fileManager.moveItem(at: url, to: rotated)
    }
}
