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

    @ViewBuilder
    var body: some View {
        if task.state == .running || task.state == .reviewing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                AgentDispatchTaskMetricsContent(
                    metrics: metrics(now: context.date),
                    presentation: presentation
                )
            }
        } else {
            AgentDispatchTaskMetricsContent(
                metrics: metrics(now: Date()),
                presentation: presentation
            )
        }
    }

    private func metrics(now: Date) -> AgentDispatchTaskMetrics {
        AgentDispatchTaskMetrics.make(
            task: task,
            sessions: metricSessions,
            now: now
        )
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
