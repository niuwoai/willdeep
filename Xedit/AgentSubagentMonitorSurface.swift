//
//  AgentSubagentMonitorSurface.swift
//  WillDeep
//
//  Compact Worker progress monitor shared by the live transcript and visual
//  regression tooling. It deliberately depends only on presentation data,
//  not the agent session store.
//

import Foundation
import SwiftUI

struct AgentSubagentMonitorSurface: View {
    let activity: AgentSubagentLiveActivity
    let isRunning: Bool
    let taskTitle: String?
    let tint: Color
    let baseFontSize: CGFloat
    @Binding var isDetailsExpanded: Bool

    private var monitor: AgentSubagentMonitorPresentation {
        AgentSubagentMonitorPresentation(activity: activity, taskTitle: taskTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            monitorSummary
            Divider()
                .opacity(0.48)
            monitorFooter
        }
    }

    private var monitorSummary: some View {
        ViewThatFits(in: .horizontal) {
            wideMonitorSummary
                .frame(minWidth: 720)
            compactMonitorSummary
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var wideMonitorSummary: some View {
        HStack(alignment: .top, spacing: 0) {
            identityColumn
                .frame(minWidth: 172, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)
            verticalMonitorDivider
            phaseColumn
                .frame(minWidth: 280, idealWidth: 360, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            verticalMonitorDivider
            metricsColumn
                .frame(minWidth: 252, idealWidth: 282, alignment: .leading)
                .padding(.leading, 16)
        }
    }

    private var compactMonitorSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            identityColumn
            phaseColumn
            metricsColumn
        }
    }

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                Text(activity.workerName)
                    .font(monitorFont(minimum: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if !activity.model.isEmpty {
                    Text(activity.model)
                        .font(monitorFont(minimum: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            Text(monitor.taskTitle ?? L10n.AgentDelegation.monitorTaskFallback)
                .font(monitorFont(minimum: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private var phaseColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.AgentDelegation.monitorCurrentPhase)
                .font(monitorFont(minimum: 9))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(
                monitor.currentAction.isEmpty
                    ? L10n.AgentDelegation.monitorWaitingForUpdate
                    : monitor.currentAction
            )
            .font(monitorFont(minimum: 11, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier("subagent-monitor-phase")
            phaseTrack
        }
    }

    private var phaseTrack: some View {
        VStack(spacing: 4) {
            phaseTrackBar
            HStack(spacing: 6) {
                ForEach(AgentSubagentMonitorPhase.allCases, id: \.self) { phase in
                    Text(phase.title)
                        .font(monitorFont(
                            minimum: 8,
                            weight: phase == monitor.currentPhase ? .semibold : .regular
                        ))
                        .foregroundStyle(
                            phase == monitor.currentPhase
                                ? tint
                                : Color(nsColor: .tertiaryLabelColor)
                        )
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(L10n.AgentDelegation.monitorCurrentPhase): \(monitor.currentPhase.title)"
        )
    }

    private var phaseTrackBar: some View {
        GeometryReader { proxy in
            let phases = AgentSubagentMonitorPhase.allCases
            let lastIndex = max(phases.count - 1, 1)
            let horizontalInset: CGFloat = 4
            let trackWidth = max(0, proxy.size.width - horizontalInset * 2)
            let segmentWidth = trackWidth / CGFloat(lastIndex)
            let currentIndex = monitor.currentPhase.rawValue

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.72))
                    .frame(width: trackWidth, height: 2)
                    .offset(x: horizontalInset)
                Capsule()
                    .fill(tint)
                    .frame(width: segmentWidth * CGFloat(currentIndex), height: 2)
                    .offset(x: horizontalInset)
                ForEach(Array(phases.enumerated()), id: \.element) { index, _ in
                    let isCurrent = index == currentIndex
                    Circle()
                        .fill(index <= currentIndex ? tint : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: isCurrent ? 7 : 5, height: isCurrent ? 7 : 5)
                        .position(
                            x: horizontalInset + segmentWidth * CGFloat(index),
                            y: proxy.size.height / 2
                        )
                }
            }
        }
        .frame(height: 8)
    }

    private var metricsColumn: some View {
        HStack(alignment: .top, spacing: 13) {
            metric(
                value: "\(activity.round)/\(activity.maximumRounds)",
                label: L10n.AgentDelegation.monitorRoundsCompleted
            )
            metric(
                value: "\(activity.completedToolInvocations)",
                label: L10n.AgentDelegation.monitorToolCalls
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    AgentSubagentElapsedValue(
                        startedAt: activity.startedAt,
                        finishedAt: activity.finishedAt
                    )
                    .font(monitorFont(minimum: 12, weight: .medium))
                    .monospacedDigit()
                    Circle()
                        .fill(isRunning ? tint : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(
                            isRunning
                                ? L10n.AgentDelegation.monitorRunning
                                : L10n.AgentDelegation.monitorFinished
                        )
                }
                Text(L10n.AgentDelegation.monitorElapsed)
                    .font(monitorFont(minimum: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(monitorFont(minimum: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(label)
                .font(monitorFont(minimum: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var monitorFooter: some View {
        HStack(spacing: 8) {
            Text(L10n.AgentDelegation.monitorJustNow)
                .font(monitorFont(minimum: 9))
                .foregroundStyle(.tertiary)
            Image(systemName: latestActionSystemImage)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(
                monitor.latestAction.isEmpty
                    ? L10n.AgentDelegation.monitorWaitingForUpdate
                    : monitor.latestAction
            )
                .font(monitorFont(minimum: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("subagent-monitor-latest-action")
            Spacer(minLength: 12)
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(
                        isDetailsExpanded
                            ? L10n.AgentDelegation.monitorHideDetails
                            : L10n.AgentDelegation.monitorRunDetails
                    )
                    Image(systemName: isDetailsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(monitorFont(minimum: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("subagent-monitor-details-toggle")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var verticalMonitorDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.46))
            .frame(width: 0.5, height: 78)
    }

    private var latestActionSystemImage: String {
        let name = monitor.latestTool?.name.lowercased() ?? ""
        if name.contains("read") || name.contains("读取") { return "doc.text" }
        if name.contains("search") || name.contains("搜索") || name.contains("正则") {
            return "magnifyingglass"
        }
        if name.contains("edit") || name.contains("write")
            || name.contains("编辑") || name.contains("写入") {
            return "square.and.pencil"
        }
        if name.contains("command") || name.contains("运行") || name.contains("执行") {
            return "terminal"
        }
        return "circle.fill"
    }

    private func monitorFont(
        minimum: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        AgentDesign.chatSupportingFont(
            baseFontSize: baseFontSize,
            visualMinimum: minimum,
            weight: weight
        )
    }
}

/// A dedicated value view keeps the one-second clock from rebuilding the
/// identity, phase and action columns. It freezes as soon as the Worker ends.
private struct AgentSubagentElapsedValue: View {
    let startedAt: Date
    let finishedAt: Date?

    var body: some View {
        Group {
            if let finishedAt {
                Text(formatted(finishedAt.timeIntervalSince(startedAt)))
            } else {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(formatted(context.date.timeIntervalSince(startedAt)))
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
