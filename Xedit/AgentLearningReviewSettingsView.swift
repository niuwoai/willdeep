//
//  AgentLearningReviewSettingsView.swift
//  WillDeep
//
//  Settings section for reviewing automatic Agent learning items.
//

import AppKit
import SwiftUI

struct AgentLearningReviewSettingsSection: View {
    @StateObject private var reviewState = AgentLearningReviewState()
    @State private var copiedItemID: AgentLearningReviewItem.ID?

    private var visiblePendingItems: [AgentLearningReviewItem] {
        Array(reviewState.pendingItems.prefix(8))
    }

    private var visibleReviewedItems: [AgentLearningReviewItem] {
        Array(reviewState.reviewedItems.prefix(6))
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Settings.LearningReview.title)
                        .font(.headline)
                    Text(L10n.Settings.LearningReview.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.Settings.LearningReview.pendingCount("\(reviewState.pendingItems.count)"))
                    .font(.caption)
                    .foregroundStyle(reviewState.pendingItems.isEmpty ? .secondary : Color.accentColor)
                    .monospacedDigit()
            }

            if reviewState.pendingItems.isEmpty {
                Text(L10n.Settings.LearningReview.empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visiblePendingItems) { item in
                    learningReviewRow(item, isPending: true)
                }

                if reviewState.pendingItems.count > visiblePendingItems.count {
                    Text(L10n.Settings.LearningReview.morePending("\(reviewState.pendingItems.count - visiblePendingItems.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !reviewState.reviewedItems.isEmpty {
                DisclosureGroup(L10n.Settings.LearningReview.reviewedDisclosure("\(reviewState.reviewedItems.count)")) {
                    ForEach(visibleReviewedItems) { item in
                        learningReviewRow(item, isPending: false)
                    }

                    HStack {
                        if reviewState.reviewedItems.count > visibleReviewedItems.count {
                            Text(L10n.Settings.LearningReview.moreReviewed("\(reviewState.reviewedItems.count - visibleReviewedItems.count)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            reviewState.clearReviewed()
                        } label: {
                            Label(L10n.Settings.LearningReview.clearReviewed, systemImage: "checklist.unchecked")
                        }
                    }
                }
            }
        } header: {
            Label(L10n.Settings.LearningReview.section, systemImage: "checklist.checked")
        }
        .onAppear {
            reviewState.refresh()
        }
    }

    private func learningReviewRow(_ item: AgentLearningReviewItem, isPending: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(for: item.event))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint(for: item.event))
                .frame(width: 22, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    tag(kindLabel(for: item.event), color: tint(for: item.event))
                    tag(statusLabel(for: item.event), color: .secondary)
                    if item.decision != .pending {
                        tag(decisionLabel(for: item.decision), color: .secondary)
                    }
                    Spacer()
                    Text(formatDate(item.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(item.event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.event.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.event.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isPending ? 5 : 2)
                        .textSelection(.enabled)
                }

                if let action = item.event.action {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: actionIconName(for: action))
                                .font(.system(size: 10, weight: .semibold))
                            Text(AgentLearningActionPresentation.label(for: action.kind))
                                .font(.caption)
                                .fontWeight(.medium)
                            if action.requiresUserConfirmation {
                                tag(L10n.Transcript.learningActionNeedsConfirmation, color: .orange)
                            }
                        }
                        .foregroundStyle(.secondary)

                        ForEach(actionDetailLines(for: action), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(isPending ? 3 : 1)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            VStack(spacing: 8) {
                Button {
                    copy(item)
                } label: {
                    Image(systemName: copiedItemID == item.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(copiedItemID == item.id ? L10n.Settings.LearningReview.copied : L10n.Settings.LearningReview.copy)

                if isPending {
                    Button {
                        reviewState.markReviewed(id: item.id)
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.Settings.LearningReview.markReviewed)

                    Button {
                        reviewState.dismiss(id: item.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.Settings.LearningReview.dismiss)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func copy(_ item: AgentLearningReviewItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AgentLearningActionPresentation.copyText(for: item.event), forType: .string)
        copiedItemID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedItemID == item.id {
                copiedItemID = nil
            }
        }
    }

    private func actionDetailLines(for action: AgentLearningAction) -> [String] {
        AgentLearningActionPresentation.summaryLines(for: action)
            .dropFirst()
            .filter { $0 != L10n.Transcript.learningActionNeedsConfirmation }
    }

    private func actionIconName(for action: AgentLearningAction) -> String {
        switch action.kind {
        case .saveMemory:
            return "text.badge.plus"
        case .createSkill, .proposeSkill:
            return "wand.and.stars"
        case .searchMCP, .suggestMCPInstall:
            return "puzzlepiece.extension"
        }
    }

    private func iconName(for event: AgentLearningEvent) -> String {
        switch event.kind {
        case .memory:
            return "text.badge.plus"
        case .skill:
            return "wand.and.stars"
        case .mcpSuggestion:
            return "puzzlepiece.extension"
        }
    }

    private func tint(for event: AgentLearningEvent) -> Color {
        switch event.kind {
        case .memory:
            return .blue
        case .skill:
            return .purple
        case .mcpSuggestion:
            return .orange
        }
    }

    private func kindLabel(for event: AgentLearningEvent) -> String {
        switch event.kind {
        case .memory:
            return L10n.Transcript.learningKindMemory
        case .skill:
            return L10n.Transcript.learningKindSkill
        case .mcpSuggestion:
            return L10n.Transcript.learningKindMCP
        }
    }

    private func statusLabel(for event: AgentLearningEvent) -> String {
        switch event.status {
        case .saved:
            return L10n.Transcript.learningStatusSaved
        case .created:
            return L10n.Transcript.learningStatusCreated
        case .suggested:
            return L10n.Transcript.learningStatusSuggested
        case .skipped:
            return L10n.Transcript.learningStatusSkipped
        case .failed:
            return L10n.Transcript.learningStatusFailed
        }
    }

    private func decisionLabel(for decision: AgentLearningReviewDecision) -> String {
        switch decision {
        case .pending:
            return L10n.Settings.LearningReview.decisionPending
        case .reviewed:
            return L10n.Settings.LearningReview.decisionReviewed
        case .dismissed:
            return L10n.Settings.LearningReview.decisionDismissed
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
