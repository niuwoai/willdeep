//
//  AgentTurnReportView.swift
//  WillDeep
//
//  Compact audit card for the latest Agent turn.
//

import AppKit
import SwiftUI

struct AgentTurnReportCard: View {
    let report: AgentTurnReport
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summaryGrid
            if report.toolSummary.total > 0 {
                toolSection
            }
            if !report.learningEvents.isEmpty {
                learningSection
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Transcript.turnReportTitle)
                    .font(AgentDesign.titleFont)
                Text(L10n.Transcript.turnReportSubtitle(report.modelID, report.providerName))
                    .font(AgentDesign.secondaryFont)
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
            .help(didCopy ? L10n.Transcript.turnReportCopied : L10n.Transcript.turnReportCopyHelp)
        }
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

            ForEach(report.tools) { call in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: iconName(for: call))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint(for: call))
                        .frame(width: 16, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(call.toolName)
                                .font(AgentDesign.secondaryFont)
                                .lineLimit(1)
                            Text(statusLabel(for: call.status))
                                .font(AgentDesign.captionFont)
                                .foregroundStyle(.secondary)
                            if let approval = call.approvalSource {
                                Text(approvalLabel(for: approval))
                                    .font(AgentDesign.captionFont)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let sandbox = call.arguments["_sandbox"]?.stringValue() {
                            Text(L10n.Transcript.turnReportSandbox(sandbox))
                                .font(AgentDesign.captionFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.Transcript.turnReportLearningSection)
                .font(AgentDesign.captionFont)
                .foregroundStyle(.secondary)
            ForEach(report.learningEvents.prefix(3)) { event in
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.purple)
                    Text(learningLine(for: event))
                        .font(AgentDesign.captionFont)
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
                .font(AgentDesign.secondaryFont.weight(.semibold))
                .lineLimit(1)
            Text(title)
                .font(AgentDesign.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AgentDesign.captionFont)
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
        for call in report.tools {
            lines.append("- \(call.toolName): \(statusLabel(for: call.status))")
        }
        for event in report.learningEvents {
            lines.append("- \(learningLine(for: event))")
        }
        return lines.joined(separator: "\n")
    }

    private func learningLine(for event: AgentLearningEvent) -> String {
        guard let action = event.action else {
            return event.title
        }
        let label = AgentLearningActionPresentation.label(for: action.kind)
        if let target = action.target?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            return "\(label): \(target)"
        }
        return "\(label): \(event.title)"
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
        case .goalMode:
            return L10n.Transcript.turnReportApprovalGoal
        case .workspaceAccess:
            return L10n.Transcript.turnReportApprovalWorkspace
        case .escalated:
            return L10n.Transcript.turnReportApprovalEscalated
        case .trustedServer:
            return L10n.Transcript.turnReportApprovalTrustedServer
        }
    }
}
