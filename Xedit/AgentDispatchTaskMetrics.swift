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

    func updatingDuration(_ duration: TimeInterval?) -> AgentDispatchTaskMetrics {
        AgentDispatchTaskMetrics(
            totalTokens: totalTokens,
            hasEstimatedTokens: hasEstimatedTokens,
            duration: duration,
            estimatedCostUSD: estimatedCostUSD,
            hasUnpricedUsage: hasUnpricedUsage
        )
    }

    static func make(
        task: AgentDispatchTask,
        session: AgentSession?,
        now: Date = Date()
    ) -> AgentDispatchTaskMetrics {
        guard let session else { return .empty }
        guard !session.messages.isEmpty || task.state == .running || task.state == .reviewing else {
            return .empty
        }

        let usageRows = AgentUsageStats.modelUsage(for: [session])
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

        // Dispatch runtimes are created immediately before launch, so their
        // session creation time is the honest wall-clock start. Active nodes
        // keep ticking; terminal nodes freeze at the latest persisted event.
        let endDate: Date
        if task.state == .running || task.state == .reviewing {
            endDate = now
        } else {
            let latestMessageEnd = session.messages.map { message in
                message.createdAt.addingTimeInterval(max(0, message.elapsedSeconds ?? 0))
            }.max()
            endDate = max(session.updatedAt, latestMessageEnd ?? session.createdAt)
        }
        let duration = max(0, endDate.timeIntervalSince(session.createdAt))

        return AgentDispatchTaskMetrics(
            totalTokens: totalTokens,
            hasEstimatedTokens: hasEstimatedTokens,
            duration: duration,
            estimatedCostUSD: estimatedCostUSD,
            hasUnpricedUsage: hasUnpricedUsage
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
