//
//  AgentTurnReportView.swift
//  WillDeep
//
//  Compact audit card for the latest Agent turn.
//

import AppKit
import SwiftUI

struct AgentTurnReportCard: View {
    private static let initiallyVisibleToolCount = 8

    let report: AgentTurnReport
    /// rc13:popover 形态下传 `true`,让卡片以展开态出现 —— popover 本身
    /// 已经是 affordance,再让用户多点一下折叠 header 是冗余。
    var initiallyExpanded: Bool = false
    @State private var didCopy = false
    @State private var showsAllTools = false
    // Collapsed by default — the report is reference detail, not something
    // the user needs in their face every turn. One line until clicked,
    // same affordance as a collapsed tool-call group.
    @State private var isExpanded: Bool

    init(report: AgentTurnReport, initiallyExpanded: Bool = false) {
        self.report = report
        self.initiallyExpanded = initiallyExpanded
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            header
            if isExpanded {
                summaryGrid
                if report.recallSnapshot?.hasUsefulContent == true {
                    recallSection
                }
                if report.toolSummary.total > 0 {
                    toolSection
                }
                if !report.learningEvents.isEmpty {
                    learningSection
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isExpanded ? 10 : 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Transcript.turnReportTitle)
                    .agentChatSupportingFont(weight: .semibold)
                Text(isExpanded
                    ? L10n.Transcript.turnReportSubtitle(report.modelID, report.providerName)
                    : collapsedSummary)
                    .agentChatSupportingFont()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                copyReport()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(didCopy ? L10n.Transcript.turnReportCopied : L10n.Transcript.turnReportCopyHelp)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() } }
    }

    /// Compact one-line metrics shown when the card is collapsed: enough
    /// to glance the turn's shape without expanding.
    private var collapsedSummary: String {
        var parts = [L10n.Transcript.turnReportToolsInline("\(report.toolSummary.total)")]
        if let elapsed = report.elapsedSeconds {
            parts.append(String(format: "%.1fs", elapsed))
        }
        parts.append(report.interactionMode.displayName)
        return parts.joined(separator: " · ")
    }

    private var summaryGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 90), spacing: 8),
                GridItem(.flexible(minimum: 90), spacing: 8),
                GridItem(.flexible(minimum: 90), spacing: 8)
            ],
            alignment: .leading,
            spacing: 8
        ) {
            metric(L10n.Transcript.turnReportTools, "\(report.toolSummary.total)")
            metric(L10n.Transcript.turnReportApprovals, approvalSummary)
            metric(L10n.Transcript.turnReportLearning, "\(report.learningEvents.count)")
            if let recallSnapshot = report.recallSnapshot {
                metric(L10n.Transcript.turnReportRecall, recallSummary(for: recallSnapshot))
            }
            if let elapsed = report.elapsedSeconds {
                metric(L10n.Transcript.turnReportElapsed, String(format: "%.1fs", elapsed))
            }
            if let totalTokens = report.totalTokens {
                metric(L10n.Transcript.turnReportTokens, "\(totalTokens)")
            }
            metric(L10n.Transcript.turnReportMode, report.interactionMode.displayName)
        }
    }

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                labelChip(L10n.Transcript.turnReportSucceeded("\(report.toolSummary.succeeded)"), color: .green)
                if report.toolSummary.failed > 0 {
                    labelChip(L10n.Transcript.turnReportFailed("\(report.toolSummary.failed)"), color: .red)
                }
                if report.toolSummary.denied > 0 {
                    labelChip(L10n.Transcript.turnReportDenied("\(report.toolSummary.denied)"), color: .orange)
                }
                if report.toolSummary.escalated > 0 {
                    labelChip(L10n.Transcript.turnReportEscalated("\(report.toolSummary.escalated)"), color: .orange)
                }
            }

            ForEach(visibleTools) { call in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: iconName(for: call))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint(for: call))
                        .frame(width: 16, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(call.toolName)
                                .agentChatSupportingFont()
                                .lineLimit(1)
                            Text(statusLabel(for: call.status))
                                .agentChatSupportingFont()
                                .foregroundStyle(.secondary)
                            if let approval = call.approvalSource {
                                Text(approvalLabel(for: approval))
                                    .agentChatSupportingFont()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let sandbox = call.arguments["_sandbox"]?.stringValue() {
                            Text(L10n.Transcript.turnReportSandbox(sandbox))
                                .agentChatSupportingFont()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            if report.tools.count > Self.initiallyVisibleToolCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showsAllTools.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsAllTools ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(
                            showsAllTools
                                ? L10n.Transcript.turnReportShowLess
                                : L10n.Transcript.turnReportShowRemaining("\(hiddenToolCount)")
                        )
                        .agentChatSupportingFont(weight: .medium)
                    }
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }

    private var visibleTools: [AgentToolCall] {
        showsAllTools
            ? report.tools
            : Array(report.tools.prefix(Self.initiallyVisibleToolCount))
    }

    private var hiddenToolCount: Int {
        max(0, report.tools.count - Self.initiallyVisibleToolCount)
    }

    private var recallSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.Transcript.turnReportRecallSection)
                .agentChatSupportingFont(weight: .semibold)
                .foregroundStyle(.secondary)
            if let utilization = recallUtilizationLine {
                Text(utilization)
                    .agentChatSupportingFont()
                    .foregroundStyle(.secondary)
            }
            if let recallSnapshot = report.recallSnapshot {
                ForEach(recallSnapshot.items.prefix(4)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.kind == .memory ? "text.badge.plus" : "wand.and.stars")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(item.kind == .memory ? Color.blue : Color.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(item.kind == .memory ? L10n.Transcript.turnReportRecallMemory : L10n.Transcript.turnReportRecallSkill)
                                    .agentChatSupportingFont()
                                    .foregroundStyle(.secondary)
                                if let score = item.score {
                                    Text(L10n.Transcript.turnReportRecallScore(String(format: "%.2f", score)))
                                        .agentChatSupportingFont()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(item.title)
                                .agentChatSupportingFont()
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .agentChatSupportingFont()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            recallLinkStatusLabel(for: item)
                        }
                    }
                }
            }
        }
    }

    /// One-line "did recall feed learning?" tally, or nil when the turn
    /// recalled nothing. Words the no-learning case distinctly from a
    /// turn where learning ran but didn't draw on the recalled context.
    private var recallUtilizationLine: String? {
        guard let snapshot = report.recallSnapshot, !snapshot.items.isEmpty else { return nil }
        let u = AgentSelfLearning.recallUtilization(in: snapshot, events: report.learningEvents)
        guard u.hasLearning else { return L10n.Transcript.learningRecallNoLearning }
        return L10n.Transcript.learningRecallUtilization("\(u.linked)", "\(u.nearMiss)", "\(u.unused)")
    }

    /// Shows whether this recall hit was linked to a learning suggestion
    /// this turn, or — for a near miss — why it wasn't. Silent for items
    /// with no overlap, to avoid noise.
    @ViewBuilder
    private func recallLinkStatusLabel(for item: AgentTurnRecallItem) -> some View {
        switch AgentSelfLearning.recallItemLinkStatus(item, events: report.learningEvents) {
        case .linked:
            Label(L10n.Transcript.learningRecallLinkedTag, systemImage: "link")
                .agentChatSupportingFont()
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .nearMiss(let reason):
            Text(reason)
                .agentChatSupportingFont()
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .unrelated:
            EmptyView()
        }
    }

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.Transcript.turnReportLearningSection)
                .agentChatSupportingFont(weight: .semibold)
                .foregroundStyle(.secondary)
            ForEach(report.learningEvents.prefix(3)) { event in
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.purple)
                    Text(learningLine(for: event))
                        .agentChatSupportingFont()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var approvalSummary: String {
        let auto = report.toolSummary.autoApproved
        let user = report.toolSummary.userApproved + report.toolSummary.escalated
        if auto == 0 && user == 0 { return "0" }
        return L10n.Transcript.turnReportApprovalSummary("\(auto)", "\(user)")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .agentChatSupportingFont(weight: .semibold)
                .lineLimit(1)
            Text(title)
                .agentChatSupportingFont()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelChip(_ text: String, color: Color) -> some View {
        Text(text)
            .agentChatSupportingFont()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(reportText, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }

    private var reportText: String {
        var lines = [
            L10n.Transcript.turnReportTitle,
            "\(L10n.Transcript.turnReportModel): \(report.modelID)",
            "\(L10n.Transcript.turnReportProvider): \(report.providerName)",
            "\(L10n.Transcript.turnReportMode): \(report.interactionMode.displayName)",
            "\(L10n.Transcript.turnReportApprovalMode): \(report.approvalMode.displayName)",
            "\(L10n.Transcript.turnReportTools): \(report.toolSummary.total)",
            "\(L10n.Transcript.turnReportApprovals): \(approvalSummary)",
            "\(L10n.Transcript.turnReportLearning): \(report.learningEvents.count)"
        ]
        if let elapsed = report.elapsedSeconds {
            lines.append("\(L10n.Transcript.turnReportElapsed): \(String(format: "%.1fs", elapsed))")
        }
        if let totalTokens = report.totalTokens {
            lines.append("\(L10n.Transcript.turnReportTokens): \(totalTokens)")
        }
        if let recallSnapshot = report.recallSnapshot {
            lines.append("\(L10n.Transcript.turnReportRecall): \(recallSummary(for: recallSnapshot))")
            if let utilization = recallUtilizationLine {
                lines.append(utilization)
            }
        }
        for call in report.tools {
            lines.append("- \(call.toolName): \(statusLabel(for: call.status))")
        }
        if let recallSnapshot = report.recallSnapshot {
            for item in recallSnapshot.items {
                let kindLabel = item.kind == .memory ? L10n.Transcript.turnReportRecallMemory : L10n.Transcript.turnReportRecallSkill
                var line = "- \(kindLabel): \(item.title)"
                switch AgentSelfLearning.recallItemLinkStatus(item, events: report.learningEvents) {
                case .linked:
                    line += " [\(L10n.Transcript.learningRecallLinkedTag)]"
                case .nearMiss(let reason):
                    line += " [\(reason)]"
                case .unrelated:
                    break
                }
                lines.append(line)
            }
        }
        for event in report.learningEvents {
            lines.append("- \(learningLine(for: event))")
        }
        return lines.joined(separator: "\n")
    }

    private func recallSummary(for snapshot: AgentTurnRecallSnapshot) -> String {
        let memoryCount = snapshot.items.filter { $0.kind == .memory }.count
        let skillCount = snapshot.items.filter { $0.kind == .skill }.count
        return L10n.Transcript.turnReportRecallSummary("\(memoryCount)", "\(skillCount)")
    }

    private func learningLine(for event: AgentLearningEvent) -> String {
        let base: String
        if let action = event.action {
            let label = AgentLearningActionPresentation.label(for: action.kind)
            if let target = action.target?.trimmingCharacters(in: .whitespacesAndNewlines),
               !target.isEmpty {
                base = "\(label): \(target)"
            } else {
                base = "\(label): \(event.title)"
            }
        } else {
            base = event.title
        }
        if let recall = AgentLearningActionPresentation.relatedRecallSummary(for: event) {
            return "\(base) · \(recall)"
        }
        return base
    }

    private func iconName(for call: AgentToolCall) -> String {
        switch call.risk {
        case .read:
            return "doc.text.magnifyingglass"
        case .write:
            return "pencil"
        case .danger:
            return "exclamationmark.triangle"
        case .userInput:
            return "questionmark.bubble"
        }
    }

    private func tint(for call: AgentToolCall) -> Color {
        switch call.status {
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .denied:
            return .orange
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer, .running:
            return .blue
        }
    }

    private func statusLabel(for status: AgentToolCallStatus) -> String {
        switch status {
        case .pendingApproval:
            return L10n.Transcript.turnReportStatusPendingApproval
        case .awaitingConfirm:
            return L10n.Transcript.turnReportStatusAwaitingConfirm
        case .awaitingUserAnswer:
            return L10n.Transcript.turnReportStatusAwaitingAnswer
        case .running:
            return L10n.Transcript.turnReportStatusRunning
        case .succeeded:
            return L10n.Transcript.turnReportStatusSucceeded
        case .failed:
            return L10n.Transcript.turnReportStatusFailed
        case .denied:
            return L10n.Transcript.turnReportStatusDenied
        }
    }

    private func approvalLabel(for source: AgentToolApprovalSource) -> String {
        switch source {
        case .user:
            return L10n.Transcript.turnReportApprovalUser
        case .alwaysAllowList:
            return L10n.Transcript.turnReportApprovalAlwaysAllow
        case .staticAllowlist:
            return L10n.Transcript.turnReportApprovalStatic
        case .llmJudge:
            return L10n.Transcript.turnReportApprovalJudge
        case .goalMode, .dispatchTask:
            return L10n.Transcript.turnReportApprovalGoal
        case .workspaceAccess:
            return L10n.Transcript.turnReportApprovalWorkspace
        case .controlLease:
            return L10n.Transcript.turnReportApprovalControlLease
        case .escalated:
            return L10n.Transcript.turnReportApprovalEscalated
        case .trustedServer:
            return L10n.Transcript.turnReportApprovalTrustedServer
        }
    }
}
