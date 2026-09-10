//
//  AgentSpecGateVerdict.swift
//  WillDeep
//
//  The decision the spec gate reached, and where it lands on disk.
//
//  Two lessons are baked into the shape of this type.
//
//  The first: a Bool cannot be audited. The approval judge spent months
//  failing 0-for-N because its failure path returned the same "no" as a
//  considered rejection, and nobody could tell the two apart. So the outcome
//  carries a reason code, and `judgeUnavailable` is a different value from
//  `judgeDowngraded` — "we asked and it said no" and "we never got an answer"
//  are different facts about the system.
//
//  The second: without a log there is no way to argue about the threshold.
//  The previous attempt at this feature was removed on impression rather than
//  measurement, because nothing recorded what it had decided. Every round
//  through the gate writes one line to spec-gate.jsonl, including the ones
//  that decided to do nothing, so the false-positive rate is a number someone
//  can compute rather than a feeling.
//
//  See docs/SPEC_FIRST_GATE_DESIGN.md §5 and §16.
//

import Foundation
import OSLog

struct AgentSpecGateVerdict: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// Carry on with the turn as if the gate did not exist.
        case proceed
        /// This request wants a written design first.
        case gate
    }

    enum Reason: String, Codable, Sendable {
        /// The setting is off. Nothing ran, nothing was logged.
        case disabled
        /// Excluded by construction: Goal mode, unattended dispatch, or no workspace.
        case excluded
        /// Signals did not clear the bar.
        case belowThreshold
        /// Phase 1: cleared the bar, recorded, deliberately not enforced.
        case shadowOnly
        /// The model reviewer said this is a local change after all.
        case judgeDowngraded
        /// The reviewer timed out, truncated, or had no usable provider.
        /// Fails open — see the invariant below.
        case judgeUnavailable
        /// Cleared the bar and survived review.
        case confirmed
        /// The user already released this session.
        case userOptedOut
    }

    let outcome: Outcome
    let reason: Reason
    let signals: [AgentSpecGateSignal]
    /// Populated from P4 onward, when a model reviewer is in the loop.
    var judgeModel: String?
    var judgeLatencyMS: Int?

    /// Every path that does not gate. Spelled out as a constructor so no call
    /// site can invent a `proceed` without saying why it proceeded.
    static func proceed(_ reason: Reason, signals: [AgentSpecGateSignal] = []) -> Self {
        AgentSpecGateVerdict(outcome: .proceed, reason: reason, signals: signals)
    }

    /// True when the gate would have stopped the turn had enforcement been on.
    /// Phase 1 uses this to count what Phase 3 would have blocked.
    var wouldGate: Bool {
        outcome == .gate || reason == .shadowOnly
    }
}

/// Append-only log of gate decisions, sibling to sandbox.jsonl and
/// judge.jsonl under Application Support/WillDeep/AgentAudit.
///
/// Deliberately its own file rather than a few more columns on judge.jsonl:
/// that log is already known to be missing run and profile identifiers and
/// has no rotation, and this one needs to be read as a population (how often
/// did we gate, how often did the user disagree) rather than scanned for a
/// single incident.
nonisolated enum AgentSpecGateAuditLog {
    private static let logger = Logger(subsystem: "com.willdeep.agent", category: "spec-gate")

    struct Entry: Codable, Equatable, Sendable {
        let timestamp: Date
        let sessionID: String
        let outcome: String
        let reason: String
        let signalKinds: [String]
        let evidence: [String]
        let requestLength: Int
        let judgeModel: String?
        let judgeLatencyMS: Int?
        /// Filled in later, when the user acts on the card. Phase 1 always
        /// writes nil — the column exists now so the Phase 3 rows are
        /// comparable with the shadow ones.
        var userChoice: String?
    }

    static var url: URL? {
        AgentSandboxAuditLog.directory.appendingPathComponent("spec-gate.jsonl")
    }

    static func record(
        verdict: AgentSpecGateVerdict,
        sessionID: UUID,
        requestLength: Int
    ) {
        // `disabled` and `excluded` are the quiet majority of turns. Writing
        // them would turn a population log into a per-message trace and bury
        // the rows that matter.
        guard verdict.reason != .disabled, verdict.reason != .excluded else { return }

        let entry = Entry(
            timestamp: Date(),
            sessionID: sessionID.uuidString,
            outcome: verdict.outcome.rawValue,
            reason: verdict.reason.rawValue,
            signalKinds: verdict.signals.map(\.kind.rawValue),
            evidence: verdict.signals.map { AgentSandboxPolicy.scrub($0.evidence) },
            requestLength: requestLength,
            judgeModel: verdict.judgeModel,
            judgeLatencyMS: verdict.judgeLatencyMS,
            userChoice: nil
        )
        append(entry)
    }

    /// Same shape as the sandbox and judge logs: ISO-8601 timestamps and
    /// sorted keys, so the three files can be read and diffed the same way.
    /// Configured locally because the sibling logs' encoder is fileprivate to
    /// their file, and reaching for it would mean widening that access for a
    /// four-line struct.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func append(_ entry: Entry) {
        guard let url,
              let data = try? encoder.encode(entry) else {
            // Losing an audit line is not worth failing a turn over, but it is
            // worth saying out loud. The judge that failed silently for months
            // failed exactly here.
            logger.warning("spec gate audit entry could not be encoded")
            return
        }
        var line = String(decoding: data, as: UTF8.self)
        line += "\n"
        guard let bytes = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: [.atomic])
        }
    }
}
