//
//  AgentModelRouteLog.swift
//  WillDeep
//
//  One JSONL line per model-routing decision that did not simply use the
//  model it was asked for — a Worker trade that fell back to its parent's
//  model, a managed-routing turn and the judge's reason, a quality judge that
//  was unavailable. Before this file the only trace was the model name left
//  on a worker-timing line, so "why did the cheap scout run on the expensive
//  parent model?" had to be reverse-engineered from which model showed up.
//
//  Lives next to worker-timing.jsonl under AgentAudit (tests write to a
//  per-process temp file, same split). Identifiers, model names and short
//  machine-readable reasons only — never prompt or output text.
//

import Foundation
import os

nonisolated enum AgentModelRouteLog {
    static let fileName = "model-routing.jsonl"
    static let rotatedFileName = "model-routing.1.jsonl"
    static let rotationThresholdBytes: UInt64 = 4 * 1024 * 1024

    /// Which host path made the decision.
    enum Surface: String, Codable, Sendable {
        /// A Worker trade's model binding / tier resolved at spawn time.
        case workerBinding = "worker_binding"
        /// some.im managed routing picked the turn's main model.
        case managedRouting = "managed_routing"
        /// The managed-routing output-quality judge.
        case qualityJudge = "quality_judge"
    }

    /// Why the requested model was not the one that ran.
    enum Reason: String, Codable, Sendable {
        /// The worker tier / binding has no model configured.
        case bindingUnconfigured = "binding_unconfigured"
        /// The tier or binding targets some.im but the parent conversation is
        /// on another provider; private parents keep workers on their own
        /// provider.
        case privateParentKeepsProvider = "private_parent_keeps_provider"
        /// The bound provider entry is missing, unusable or signed out.
        case providerUnavailable = "provider_unavailable"
        /// The bound provider has no usable API key.
        case missingAPIKey = "missing_api_key"
        /// The judge call failed or returned nothing usable.
        case judgeUnavailable = "judge_unavailable"
        /// The judge proposed a model outside the allowlist.
        case judgeModelRejected = "judge_model_rejected"
        /// Routing chose normally; recorded for the judge's reason.
        case routed
    }

    struct Entry: Codable, Equatable, Sendable {
        var kind = "model_route"
        let recordedAt: Date
        let surface: Surface
        let sessionID: UUID?
        /// Trade id, or the routing domain for managed routing.
        let subject: String
        /// What was asked for: a model id, or `tier:<name>` for worker tiers.
        let requested: String?
        let providerID: String
        let model: String
        let fallback: Bool
        let reason: Reason
        /// Free-form detail from the decider (the judge's one-line reason).
        /// Bounded; never message content.
        let detail: String?

        init(
            recordedAt: Date = Date(),
            surface: Surface,
            sessionID: UUID?,
            subject: String,
            requested: String?,
            providerID: String,
            model: String,
            fallback: Bool,
            reason: Reason,
            detail: String? = nil
        ) {
            self.recordedAt = recordedAt
            self.surface = surface
            self.sessionID = sessionID
            self.subject = subject
            self.requested = requested
            self.providerID = providerID
            self.model = model
            self.fallback = fallback
            self.reason = reason
            self.detail = detail.map { String($0.prefix(AgentModelRouteLog.detailCharacterLimit)) }
        }
    }

    static let detailCharacterLimit = 240

    static func record(_ entry: Entry) {
        log(entry)
        guard let line = AgentWorkerTimingLog.encodeLine(entry) else { return }
        Task.detached(priority: .utility) {
            await writer.append(line)
        }
    }

    static func defaultURL(underTests: Bool = AgentWorkerTimingLog.isRunningUnderTests) -> URL {
        AgentWorkerTimingLog.defaultURL(underTests: underTests)
            .deletingLastPathComponent()
            .appendingPathComponent(
                underTests ? "\(ProcessInfo.processInfo.processIdentifier)-\(fileName)" : fileName
            )
    }

    private static let writer = AgentWorkerTimingLogWriter(
        url: defaultURL(),
        rotatedFileName: rotatedFileName,
        rotationThresholdBytes: rotationThresholdBytes
    )

    private static let logger = Logger(subsystem: "com.willdeep.agent", category: "model-routing")

    private static func log(_ entry: Entry) {
        logger.notice(
            "model route surface=\(entry.surface.rawValue, privacy: .public) subject=\(entry.subject, privacy: .public) requested=\(entry.requested ?? "-", privacy: .public) model=\(entry.model, privacy: .public) provider=\(entry.providerID, privacy: .public) fallback=\(entry.fallback, privacy: .public) reason=\(entry.reason.rawValue, privacy: .public)"
        )
    }
}
