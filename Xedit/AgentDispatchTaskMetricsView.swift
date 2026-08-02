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
    @ObservedObject var runtime: AgentRuntime
    let task: AgentDispatchTask
    let presentation: AgentDispatchTaskMetricsPresentation

    @ViewBuilder
    var body: some View {
        let snapshot = metrics(now: Date())
        if task.state == .running || task.state == .reviewing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                AgentDispatchTaskMetricsContent(
                    metrics: snapshot.updatingDuration(
                        max(0, context.date.timeIntervalSince(runtime.session.createdAt))
                    ),
                    presentation: presentation
                )
            }
        } else {
            AgentDispatchTaskMetricsContent(
                metrics: snapshot,
                presentation: presentation
            )
        }
    }

    private func metrics(now: Date) -> AgentDispatchTaskMetrics {
        var session = runtime.session
        session.messages = runtime.messages
        return AgentDispatchTaskMetrics.make(task: task, session: session, now: now)
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
