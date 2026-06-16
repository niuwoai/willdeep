//
//  AgentLearningEventViews.swift
//  WillDeep
//
//  Visible audit card for automatic Agent learning outcomes.
//

import AppKit
import SwiftUI

struct AgentLearningEventsCard: View {
    let events: [AgentLearningEvent]
    @State private var copiedEventID: AgentLearningEvent.ID?

    private var visibleEvents: [AgentLearningEvent] {
        Array(events.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Transcript.learningCardTitle)
                        .font(AgentDesign.titleFont)
                    Text(L10n.Transcript.learningCardSubtitle(String(events.count)))
                        .font(AgentDesign.secondaryFont)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                    AgentLearningEventRow(
                        event: event,
                        didCopy: copiedEventID == event.id,
                        onCopy: { copy(event) }
                    )
                    if index < visibleEvents.count - 1 {
                        Divider()
                            .padding(.leading, 28)
                    }
                }
            }

            if events.count > visibleEvents.count {
                Text(L10n.Transcript.learningMore(String(events.count - visibleEvents.count)))
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
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

    private func copy(_ event: AgentLearningEvent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AgentLearningActionPresentation.copyText(for: event), forType: .string)
        copiedEventID = event.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedEventID == event.id {
                copiedEventID = nil
            }
        }
    }
}

private struct AgentLearningEventRow: View {
    let event: AgentLearningEvent
    let didCopy: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(AgentDesign.captionFont)
                        .foregroundStyle(tint)
                    Text(statusLabel)
                        .font(AgentDesign.captionFont)
                        .foregroundStyle(.secondary)
                    Text(AgentLearningActionPresentation.confidence(for: event).label)
                        .font(AgentDesign.captionFont)
                        .foregroundStyle(confidenceTint)
                    Spacer(minLength: 0)
                }

                Text(event.title)
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !event.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(event.detail)
                        .font(AgentDesign.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }

                if event.action != nil {
                    AgentLearningActionSummary(event: event)
                }
            }

            if !event.detail.isEmpty {
                Button(action: onCopy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(didCopy ? L10n.Transcript.learningCopied : L10n.Transcript.learningCopyHelp)
            }
        }
        .padding(.vertical, 8)
    }

    private var iconName: String {
        switch event.kind {
        case .memory:
            return "text.badge.plus"
        case .skill:
            return "wand.and.stars"
        case .mcpSuggestion:
            return "puzzlepiece.extension"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .memory:
            return .blue
        case .skill:
            return .purple
        case .mcpSuggestion:
            return .orange
        }
    }

    private var kindLabel: String {
        switch event.kind {
        case .memory:
            return L10n.Transcript.learningKindMemory
        case .skill:
            return L10n.Transcript.learningKindSkill
        case .mcpSuggestion:
            return L10n.Transcript.learningKindMCP
        }
    }

    private var statusLabel: String {
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

    private var confidenceTint: Color {
        switch AgentLearningActionPresentation.confidence(for: event) {
        case .low:
            return .orange
        case .medium:
            return .secondary
        case .high:
            return .green
        }
    }
}

private struct AgentLearningActionSummary: View {
    let event: AgentLearningEvent

    private var action: AgentLearningAction? { event.action }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: actionIcon)
                    .font(.system(size: 10, weight: .semibold))
                Text(AgentLearningActionPresentation.label(for: action?.kind ?? .saveMemory))
                    .font(AgentDesign.captionFont)
                    .fontWeight(.medium)
                if action?.requiresUserConfirmation == true {
                    Text(L10n.Transcript.learningActionNeedsConfirmation)
                        .font(AgentDesign.captionFont)
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)

            ForEach(secondaryLines, id: \.self) { line in
                Text(line)
                    .font(AgentDesign.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 2)
    }

    private var secondaryLines: [String] {
        guard action != nil else { return [] }
        return AgentLearningActionPresentation.summaryLines(for: event)
            .dropFirst()
            .filter { $0 != L10n.Transcript.learningActionNeedsConfirmation }
    }

    private var actionIcon: String {
        switch action?.kind ?? .saveMemory {
        case .saveMemory:
            return "text.badge.plus"
        case .createSkill, .proposeSkill:
            return "wand.and.stars"
        case .searchMCP, .suggestMCPInstall:
            return "puzzlepiece.extension"
        }
    }
}
