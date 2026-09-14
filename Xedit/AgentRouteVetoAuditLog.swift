//
//  AgentRouteVetoAuditLog.swift
//  WillDeep
//
//  AgentAudit/route-veto.jsonl — one line per privileged route that was
//  confirmed with the local model.
//
//  This log is not optional instrumentation. The veto can silently change
//  which worker a turn routes to, and its dominant failure mode is invisible
//  by construction: a model that ignores `think: false` returns empty
//  content, the reply is unusable, the keyword decision is upheld, and the
//  feature looks installed while doing nothing. That is exactly how the
//  approval judge failed for months. So every outcome is written — upheld
//  ones too — and the unusable rows carry *why*, so "it never fires" and
//  "it fires and always agrees" are distinguishable without a debugger.
//
//  `matchedMarker` is the column that answers the question this whole design
//  came from: which keyword is doing the false positives. `worker-timing`
//  only records the resulting profile, which cannot tell keyword from model.
//
//  See docs/WORKER_ROUTING_VETO_DESIGN.md §8.2.
//

import Foundation
import OSLog

enum AgentRouteVetoAuditLog {
    private static let logger = Logger(subsystem: "com.willdeep.app", category: "route-veto")

    /// 用户确认记原文前缀，截断 200 字符（2026-09-14）。走与 sandbox /
    /// judge 日志同一个脱敏器，凭据不会因为这条日志落盘。
    static let requestPrefixLimit = 200

    enum Outcome {
        case upheld(AgentWorkerRoutingVeto.Verdict)
        /// 模型说该降级，但关键词表跳过特权分支后没有给出任何判决——
        /// 没有目标可降，维持原判。
        case upheldWithoutTarget(AgentWorkerRoutingVeto.Verdict)
        case downgraded(AgentWorkerRoutingVeto.Verdict, to: AgentRequestRouter.Decision)
        case unusable(AgentWorkerRoutingVeto.Unusable)
        case timedOut

        var rawValue: String {
            switch self {
            case .upheld: "upheld"
            case .upheldWithoutTarget: "upheld_no_target"
            case .downgraded: "downgraded"
            case .unusable: "unusable"
            case .timedOut: "timed_out"
            }
        }

        var verdict: AgentWorkerRoutingVeto.Verdict? {
            switch self {
            case .upheld(let verdict), .upheldWithoutTarget(let verdict): verdict
            case .downgraded(let verdict, _): verdict
            case .unusable, .timedOut: nil
            }
        }

        var unusableReason: String? {
            switch self {
            case .unusable(let reason): reason.rawValue
            case .timedOut: "timeout"
            case .upheld, .upheldWithoutTarget, .downgraded: nil
            }
        }

        var downgradedTo: String? {
            if case .downgraded(_, let decision) = self { return decision.profileID }
            return nil
        }
    }

    struct Entry: Codable {
        let timestamp: Date
        let sessionID: String
        let keywordProfile: String
        let keywordConfidence: Int
        /// 关键词表里实际命中的那个词。误伤归因的主列。
        let matchedMarker: String?
        let outcome: String
        let confidence: Int?
        let unusableReason: String?
        let downgradedTo: String?
        let elapsedMS: Int
        let model: String
        let requestPrefix: String
    }

    static var url: URL? {
        AgentSandboxAuditLog.directory.appendingPathComponent("route-veto.jsonl")
    }

    static func record(
        ticket: AgentWorkerRoutingVeto.Ticket,
        outcome: Outcome,
        sessionID: UUID
    ) {
        let entry = Entry(
            timestamp: Date(),
            sessionID: sessionID.uuidString,
            keywordProfile: ticket.keywordDecision.profileID ?? "none",
            keywordConfidence: ticket.keywordDecision.confidence,
            matchedMarker: AgentRequestRouter.matchedPrivilegedMarker(in: ticket.requestText),
            outcome: outcome.rawValue,
            confidence: outcome.verdict?.confidence,
            unusableReason: outcome.unusableReason,
            downgradedTo: outcome.downgradedTo,
            elapsedMS: Int(Date().timeIntervalSince(ticket.startedAt) * 1000),
            model: ticket.model,
            requestPrefix: AgentSandboxPolicy.scrub(
                String(ticket.requestText.prefix(requestPrefixLimit))
            )
        )
        append(entry)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func append(_ entry: Entry) {
        guard let url, let data = try? encoder.encode(entry) else {
            logger.warning("route veto audit entry could not be encoded")
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
