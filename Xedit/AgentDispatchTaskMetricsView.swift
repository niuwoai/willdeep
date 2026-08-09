//
//  AgentDispatchTaskMetricsView.swift
//  WillDeep
//

import SwiftUI

enum AgentDispatchTaskMetricsPresentation: Equatable {
    case compact
    case detailed
}

struct AgentDispatchTaskMetricsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    let task: AgentDispatchTask
    let presentation: AgentDispatchTaskMetricsPresentation

    /// Reference-typed memo so recomputing inside body never schedules
    /// another render. The heavy token/cost rollup only re-runs when the
    /// (sessionID, messages.count) fingerprint moves; the 1 Hz timeline
    /// below ticks against a captured snapshot and pays pure arithmetic.
    @State private var snapshotCache = AgentDispatchTaskMetricsSnapshotCache()

    @ViewBuilder
    var body: some View {
        let snapshot = currentSnapshot()
        if task.state == .running || task.state == .reviewing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                AgentDispatchTaskMetricsContent(
                    metrics: snapshot.metrics(now: context.date),
                    presentation: presentation
                )
            }
        } else {
            AgentDispatchTaskMetricsContent(
                metrics: snapshot.metrics(now: Date()),
                presentation: presentation
            )
        }
    }

    private func currentSnapshot() -> AgentDispatchTaskMetricsSnapshot {
        let sessions = metricSessions
        let fingerprint = AgentDispatchTaskMetricsSnapshotCache.Fingerprint(
            taskState: task.state,
            runtimeSessionID: task.runtimeSessionID,
            runtimeSessionIDs: task.runtimeSessionIDs,
            sessions: sessions.map {
                AgentDispatchTaskMetricsSnapshotCache.SessionStamp(
                    id: $0.id,
                    messageCount: $0.messages.count,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
        )
        return snapshotCache.snapshot(for: fingerprint) {
            AgentDispatchTaskMetricsSnapshot.make(task: task, sessions: sessions)
        }
    }

    private var metricSessions: [AgentSession] {
        var sessionIDs = task.runtimeSessionIDs ?? []
        if let currentSessionID = task.runtimeSessionID,
           !sessionIDs.contains(currentSessionID) {
            sessionIDs.append(currentSessionID)
        }
        if !sessionIDs.contains(runtime.id) {
            sessionIDs.append(runtime.id)
        }

        var seenSessionIDs: Set<UUID> = []
        return sessionIDs.compactMap { sessionID in
            guard seenSessionIDs.insert(sessionID).inserted else { return nil }
            if let liveRuntime = appState.agentRuntimes[sessionID] {
                var session = liveRuntime.session
                session.messages = liveRuntime.messages
                return session
            }
            return appState.agentSessions.first { $0.id == sessionID }
        }
    }
}

/// Memo slot held in `@State` for identity, mutated freely during body
/// evaluation (it is not observable, so writes cannot re-render). Keyed by a
/// cheap fingerprint instead of the sessions themselves: comparing every
/// message for equality would cost as much as recomputing.
final class AgentDispatchTaskMetricsSnapshotCache {
    struct SessionStamp: Equatable {
        var id: UUID
        var messageCount: Int
        var createdAt: Date
        var updatedAt: Date
    }

    struct Fingerprint: Equatable {
        var taskState: AgentDispatchTaskState
        var runtimeSessionID: UUID?
        var runtimeSessionIDs: [UUID]?
        var sessions: [SessionStamp]
    }

    private var fingerprint: Fingerprint?
    private var cached: AgentDispatchTaskMetricsSnapshot = .empty

    func snapshot(
        for fingerprint: Fingerprint,
        compute: () -> AgentDispatchTaskMetricsSnapshot
    ) -> AgentDispatchTaskMetricsSnapshot {
        if self.fingerprint == fingerprint { return cached }
        let computed = compute()
        self.fingerprint = fingerprint
        cached = computed
        return computed
    }
}

struct AgentDispatchTaskMetricsContent: View {
    let metrics: AgentDispatchTaskMetrics
    let presentation: AgentDispatchTaskMetricsPresentation

    var body: some View {
        HStack(spacing: presentation == .compact ? 9 : 14) {
            metric(
                symbol: "text.word.spacing",
                value: tokenValue,
                help: L10n.Dispatch.metricTokensHelp(tokenValue)
            )
            metric(
                symbol: "clock",
                value: durationValue,
                help: L10n.Dispatch.metricDurationHelp(durationValue)
            )
            metric(
                symbol: "dollarsign",
                value: costValue,
                help: costHelp
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.Dispatch.metricsAccessibility(
                tokenValue,
                durationValue,
                costValue
            )
        )
    }

    private var tokenValue: String {
        let formatted = AgentDispatchMetricFormatting.tokenCount(metrics.totalTokens)
        let value = metrics.hasEstimatedTokens && metrics.totalTokens != nil
            ? L10n.Dispatch.metricApproximate(formatted)
            : formatted
        guard presentation == .detailed, metrics.totalTokens != nil else { return value }
        return L10n.Dispatch.metricTokensLabel(value)
    }

    private var durationValue: String {
        AgentDispatchMetricFormatting.duration(metrics.duration)
    }

    private var costValue: String {
        AgentDispatchMetricFormatting.estimatedCost(metrics.estimatedCostUSD)
    }

    private var costHelp: String {
        if metrics.hasUnpricedUsage {
            return L10n.Dispatch.metricUnpricedHelp
        }
        return L10n.Dispatch.metricCostHelp(costValue)
    }

    private func metric(symbol: String, value: String, help: String) -> some View {
        Label(value, systemImage: symbol)
            .font(.system(size: presentation == .compact ? 9 : 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .help(help)
    }
}
