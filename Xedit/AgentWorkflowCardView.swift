//
//  AgentWorkflowCardView.swift
//  WillDeep
//
//  Transcript-inline card for an in-flight or finished workflow run.
//  Reads WorkflowReport, renders status / progress / sub-agent list.
//  状态/进度都来自 report 字段，engine 后台 mutate 时 SwiftUI 自动重渲染
//  （AgentMessage.workflowReport 改变 → runtime.messages 整体重 assign →
//  @Published 通知 → body 重算）。
//

import SwiftUI

struct AgentWorkflowCardView: View {
    @EnvironmentObject private var appState: AppState
    let report: WorkflowReport

    /// 折叠展开看每个 sub-agent。默认折叠（运行中也不展开，避免抖动）。
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !report.args.isEmpty {
                Text(report.args)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            progressRow
            if expanded {
                Divider().opacity(0.5)
                subAgentsList
            }
            if !report.summary.isEmpty {
                Divider().opacity(0.5)
                Text(report.summary)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(strokeColor.opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(strokeColor)

            Text(report.displayTitle)
                .font(.system(size: 13, weight: .semibold))

            Text(L10n.WorkflowCard.workflowBadge)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.12))
                )
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if isActive {
                Button {
                    appState.cancelWorkflow(reportID: report.id)
                } label: {
                    Label(L10n.WorkflowCard.stop, systemImage: "stop.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(L10n.WorkflowCard.stopHelp)
            }

            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(expanded ? L10n.WorkflowCard.collapse : L10n.WorkflowCard.expand)
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                progressContent(now: context.date)
            }
        } else {
            progressContent(now: report.finishedAt ?? Date())
        }
    }

    private func progressContent(now: Date) -> some View {
        let total = report.subAgents.count
        let done = report.completedAgentCount
        return HStack(spacing: 8) {
            if isActive {
                ProgressView()
                    .controlSize(.small)
            }
            Text(L10n.WorkflowCard.agentsLabel(done: done, total: total))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(elapsedText(at: now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var subAgentsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(report.subAgents) { sub in
                HStack(spacing: 6) {
                    Image(systemName: subAgentSymbol(sub.status))
                        .font(.system(size: 10))
                        .foregroundStyle(subAgentColor(sub.status))
                    Text(sub.label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if sub.usageTokens > 0 {
                        Text(L10n.WorkflowCard.tokensShort(sub.usageTokens))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let started = sub.startedAt {
                        Text(durationLabel(from: started, to: sub.finishedAt))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if report.totalUsageTokens > 0 {
                Text(L10n.WorkflowCard.totalTokens(report.totalUsageTokens))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(strokeColor)
        }
    }

    // MARK: - Styling helpers

    private var strokeColor: Color {
        switch report.status {
        case .planning, .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var statusSymbol: String {
        switch report.status {
        case .planning: return "hourglass"
        case .running: return "gearshape.2"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var statusLabel: String {
        switch report.status {
        case .planning: return L10n.WorkflowCard.statusPlanning
        case .running: return L10n.WorkflowCard.statusRunning
        case .done: return L10n.WorkflowCard.statusDone
        case .failed: return L10n.WorkflowCard.statusFailed
        case .cancelled: return L10n.WorkflowCard.statusCancelled
        }
    }

    private func subAgentSymbol(_ status: WorkflowReport.SubAgent.Status) -> String {
        switch status {
        case .pending: return "circle.dotted"
        case .running: return "circle.dashed"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func subAgentColor(_ status: WorkflowReport.SubAgent.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }

    private var isActive: Bool {
        report.status == .planning || report.status == .running
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(report.startedAt).rounded()))
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func durationLabel(from start: Date, to end: Date?) -> String {
        let endDate = end ?? Date()
        let seconds = Int(endDate.timeIntervalSince(start).rounded())
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m\(seconds % 60)s"
    }
}
