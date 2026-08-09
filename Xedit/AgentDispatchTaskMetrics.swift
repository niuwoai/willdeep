//
//  AgentDispatchTaskMetrics.swift
//  WillDeep
//
//  Session-backed observability for dispatch graph nodes and task takeover.
//

import Foundation

struct AgentDispatchTaskMetrics: Equatable {
    let totalTokens: Int?
    let hasEstimatedTokens: Bool
    let duration: TimeInterval?
    let estimatedCostUSD: Double?
    let hasUnpricedUsage: Bool

    static let empty = AgentDispatchTaskMetrics(
        totalTokens: nil,
        hasEstimatedTokens: false,
        duration: nil,
        estimatedCostUSD: nil,
        hasUnpricedUsage: false
    )

    static func make(
        task: AgentDispatchTask,
        session: AgentSession?,
        now: Date = Date()
    ) -> AgentDispatchTaskMetrics {
        make(
            task: task,
            sessions: session.map { [$0] } ?? [],
            now: now
        )
    }

    /// A dispatch node may own several runtime sessions after executor
    /// failover or a manual retry. Metrics belong to the node, so every
    /// attempt remains part of its cumulative usage instead of resetting to
    /// the newest session.
    static func make(
        task: AgentDispatchTask,
        sessions requestedSessions: [AgentSession],
        now: Date = Date()
    ) -> AgentDispatchTaskMetrics {
        AgentDispatchTaskMetricsSnapshot
            .make(task: task, sessions: requestedSessions)
            .metrics(now: now)
    }
}

/// The expensive half of `AgentDispatchTaskMetrics.make`: token/cost rollups
/// walk every assistant message of every attempt, so a 1 Hz TimelineView must
/// not re-run them per tick. The snapshot freezes everything that only changes
/// with session content and keeps the wall clock out; `metrics(now:)` is pure
/// arithmetic and is all a timeline tick has to pay for.
struct AgentDispatchTaskMetricsSnapshot: Equatable {
    static let empty = AgentDispatchTaskMetricsSnapshot(
        isEmpty: true,
        totalTokens: nil,
        hasEstimatedTokens: false,
        estimatedCostUSD: nil,
        hasUnpricedUsage: false,
        sealedDuration: 0,
        activeAttemptStart: nil
    )

    let isEmpty: Bool
    let totalTokens: Int?
    let hasEstimatedTokens: Bool
    let estimatedCostUSD: Double?
    let hasUnpricedUsage: Bool
    /// Summed intervals of completed attempts; fixed until sessions change.
    let sealedDuration: TimeInterval
    /// `createdAt` of the attempt that is still ticking, nil when none is.
    let activeAttemptStart: Date?

    func metrics(now: Date) -> AgentDispatchTaskMetrics {
        guard !isEmpty else { return .empty }
        let activeDuration = activeAttemptStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return AgentDispatchTaskMetrics(
            totalTokens: totalTokens,
            hasEstimatedTokens: hasEstimatedTokens,
            duration: sealedDuration + activeDuration,
            estimatedCostUSD: estimatedCostUSD,
            hasUnpricedUsage: hasUnpricedUsage
        )
    }

    static func make(
        task: AgentDispatchTask,
        sessions requestedSessions: [AgentSession]
    ) -> AgentDispatchTaskMetricsSnapshot {
        var seenSessionIDs: Set<UUID> = []
        let sessions = requestedSessions.filter { seenSessionIDs.insert($0.id).inserted }
        guard !sessions.isEmpty else { return .empty }
        let hasRecordedRuntime = task.runtimeSessionID != nil
            || !(task.runtimeSessionIDs ?? []).isEmpty
        guard sessions.contains(where: { !$0.messages.isEmpty })
                || task.state == .running
                || task.state == .reviewing
                || hasRecordedRuntime else {
            return .empty
        }

        let usageRows = AgentUsageStats.modelUsage(for: sessions)
        // Provider usage is recorded on assistant turns and already includes
        // the prompt side. Summing the generic overview would count operator
        // messages a second time whenever a provider supplied real totals.
        let totalTokens = usageRows.isEmpty
            ? nil
            : usageRows.reduce(0) { $0 + $1.totalTokens }
        let hasEstimatedTokens = usageRows.contains { $0.hasEstimatedUsage }
        let hasUnpricedUsage = usageRows.contains { $0.estimatedCostUSD == nil }
        let estimatedCostUSD: Double? = if usageRows.isEmpty || hasUnpricedUsage {
            nil
        } else {
            usageRows.compactMap(\.estimatedCostUSD).reduce(0, +)
        }

        // Each retry is a separate runtime interval. Sum those intervals so
        // the total neither resets on retry nor counts idle gaps between
        // attempts. Only the current active attempt keeps ticking.
        var sealedDuration: TimeInterval = 0
        var activeAttemptStart: Date?
        for session in sessions {
            let isCurrentActiveAttempt = task.runtimeSessionID == session.id
                && (task.state == .running || task.state == .reviewing)
            if isCurrentActiveAttempt {
                activeAttemptStart = session.createdAt
                continue
            }
            let latestMessageEnd = session.messages.map { message in
                message.createdAt.addingTimeInterval(max(0, message.elapsedSeconds ?? 0))
            }.max()
            // `updatedAt` is session metadata time, not execution time. It can
            // advance hours after completion when the app restores, renames,
            // or re-persists a session. Once an attempt has messages, seal its
            // interval at the final message's real end instead of letting
            // later metadata writes inflate every completed graph node.
            let completedAttemptEnd = latestMessageEnd ?? session.updatedAt
            sealedDuration += max(0, completedAttemptEnd.timeIntervalSince(session.createdAt))
        }

        return AgentDispatchTaskMetricsSnapshot(
            isEmpty: false,
            totalTokens: totalTokens,
            hasEstimatedTokens: hasEstimatedTokens,
            estimatedCostUSD: estimatedCostUSD,
            hasUnpricedUsage: hasUnpricedUsage,
            sealedDuration: sealedDuration,
            activeAttemptStart: activeAttemptStart
        )
    }
}

enum AgentDispatchMetricFormatting {
    static func tokenCount(_ count: Int?) -> String {
        guard let count else { return L10n.Dispatch.metricUnavailable }
        if count < 1_000 {
            return count.formatted()
        }
        if count < 1_000_000 {
            let value = Double(count) / 1_000
            return compact(value, suffix: "k")
        }
        let value = Double(count) / 1_000_000
        return compact(value, suffix: "M")
    }

    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return L10n.Dispatch.metricUnavailable }
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return L10n.Dispatch.metricDurationHours(hours, minutes)
        }
        if minutes > 0 {
            return L10n.Dispatch.metricDurationMinutes(minutes, seconds)
        }
        return L10n.Dispatch.metricDurationSeconds(seconds)
    }

    static func estimatedCost(_ cost: Double?) -> String {
        guard let cost else { return L10n.Dispatch.metricUnavailable }
        let precision = cost < 0.01 ? 3 : 2
        return L10n.Dispatch.metricEstimatedCost(
            String(format: "%.*f", precision, cost)
        )
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let precision = value.rounded() == value ? 0 : 1
        return String(format: "%.*f%@", precision, value, suffix)
    }
}
