//
//  AgentLearningReviewSettingsView.swift
//  WillDeep
//
//  Settings section for reviewing automatic Agent learning items.
//

import AppKit
import SwiftUI

struct AgentLearningReviewSettingsSection: View {
    @StateObject private var reviewState = AgentLearningReviewState(items: [])
    @State private var copiedItemID: AgentLearningReviewItem.ID?
    @State private var copiedSearchQueryItemID: AgentLearningReviewItem.ID?
    @State private var editedSkillItemID: AgentLearningReviewItem.ID?
    @State private var createdSkillItemID: AgentLearningReviewItem.ID?
    @State private var configuredMCPItemID: AgentLearningReviewItem.ID?
    @State private var editingSkillDraftContext: SkillDraftEditorContext?

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
        .sheet(item: $editingSkillDraftContext) { context in
            AgentLearningReviewSkillDraftSheet(
                draft: context.draft,
                onSave: { draft in
                    reviewState.updateSkillDraft(id: context.itemID, draft: draft)
                    editingSkillDraftContext = nil
                    editedSkillItemID = context.itemID
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if editedSkillItemID == context.itemID {
                            editedSkillItemID = nil
                        }
                    }
                },
                onCancel: {
                    editingSkillDraftContext = nil
                }
            )
        }
        .task {
            await reviewState.reloadFromStore()
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
                    tag(
                        AgentLearningActionPresentation.confidence(for: item.event).shortLabel,
                        color: confidenceColor(for: item.event)
                    )
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

                        ForEach(actionDetailLines(for: item.event), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(isPending ? 3 : 1)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 2)
                }

                let quickActions = AgentLearningReviewActionPlanner.actions(for: item)
                if !quickActions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(quickActions) { quickAction in
                            quickActionButton(quickAction, for: item)
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

    @ViewBuilder
    private func quickActionButton(_ quickAction: AgentLearningReviewQuickAction, for item: AgentLearningReviewItem) -> some View {
        Button {
            performQuickAction(quickAction, for: item)
        } label: {
            Image(systemName: iconName(for: quickAction, item: item))
        }
        .buttonStyle(.borderless)
        .help(helpText(for: quickAction, item: item))
        .foregroundStyle(highlightedQuickActionID(quickAction, item: item) ? Color.accentColor : Color.secondary)
    }

    private func performQuickAction(_ quickAction: AgentLearningReviewQuickAction, for item: AgentLearningReviewItem) {
        if quickAction == .editSkillDraft {
            guard let draft = item.event.action?.skillDraft else { return }
            editingSkillDraftContext = SkillDraftEditorContext(itemID: item.id, draft: draft)
            return
        }
        guard AgentLearningReviewActionPlanner.perform(quickAction, for: item) else { return }
        if quickAction == .createSkillFromDraft {
            reviewState.markReviewed(id: item.id)
            createdSkillItemID = item.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if createdSkillItemID == item.id {
                    createdSkillItemID = nil
                }
            }
            return
        }
        if quickAction == .configureMCPFromDraft {
            configuredMCPItemID = item.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if configuredMCPItemID == item.id {
                    configuredMCPItemID = nil
                }
            }
            return
        }
        if quickAction == .copySearchQuery {
            copiedSearchQueryItemID = item.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if copiedSearchQueryItemID == item.id {
                    copiedSearchQueryItemID = nil
                }
            }
        }
    }

    private func iconName(for quickAction: AgentLearningReviewQuickAction, item: AgentLearningReviewItem) -> String {
        switch quickAction {
        case .editSkillDraft:
            return editedSkillItemID == item.id ? "checkmark" : "square.and.pencil"
        case .createSkillFromDraft:
            return createdSkillItemID == item.id ? "checkmark" : "plus.square.on.square"
        case .configureMCPFromDraft:
            return configuredMCPItemID == item.id ? "checkmark" : "plus.rectangle.on.folder"
        case .openSkillsTab:
            return "wand.and.stars"
        case .openSkillsFolder:
            return "folder"
        case .openMCPTab:
            return "globe"
        case .copySearchQuery:
            return copiedSearchQueryItemID == item.id ? "checkmark" : "magnifyingglass"
        }
    }

    private func helpText(for quickAction: AgentLearningReviewQuickAction, item: AgentLearningReviewItem) -> String {
        switch quickAction {
        case .editSkillDraft:
            return editedSkillItemID == item.id
                ? L10n.Settings.LearningReview.copied
                : L10n.Settings.LearningReview.editSkillDraft
        case .createSkillFromDraft:
            return createdSkillItemID == item.id
                ? L10n.Settings.LearningReview.copied
                : L10n.Settings.LearningReview.createSkillFromDraft
        case .configureMCPFromDraft:
            return configuredMCPItemID == item.id
                ? L10n.Settings.LearningReview.copied
                : L10n.Settings.LearningReview.configureMCPFromDraft
        case .openSkillsTab:
            return L10n.Settings.tabSkills
        case .openSkillsFolder:
            return L10n.Settings.Skill.openFolder
        case .openMCPTab:
            return L10n.Settings.tabMcp
        case .copySearchQuery:
            if copiedSearchQueryItemID == item.id {
                return L10n.Settings.LearningReview.copied
            }
            return L10n.Transcript.learningActionSearchMCP
        }
    }

    private func highlightedQuickActionID(_ quickAction: AgentLearningReviewQuickAction, item: AgentLearningReviewItem) -> Bool {
        (quickAction == .copySearchQuery && copiedSearchQueryItemID == item.id)
            || (quickAction == .editSkillDraft && editedSkillItemID == item.id)
            || (quickAction == .createSkillFromDraft && createdSkillItemID == item.id)
            || (quickAction == .configureMCPFromDraft && configuredMCPItemID == item.id)
    }

    private func actionDetailLines(for event: AgentLearningEvent) -> [String] {
        AgentLearningActionPresentation.conciseSummaryLines(for: event)
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

    private func confidenceColor(for event: AgentLearningEvent) -> Color {
        switch AgentLearningActionPresentation.confidence(for: event) {
        case .low:
            return .red
        case .medium:
            return .orange
        case .high:
            return .green
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

    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        Self.rowDateFormatter.string(from: date)
    }
}

private struct SkillDraftEditorContext: Identifiable {
    let itemID: AgentLearningReviewItem.ID
    let draft: AgentLearningSkillDraft

    var id: AgentLearningReviewItem.ID { itemID }
}

private struct AgentLearningReviewSkillDraftSheet: View {
    @State private var name: String
    @State private var description: String
    @State private var skillBody: String

    let onSave: (AgentLearningSkillDraft) -> Void
    let onCancel: () -> Void

    init(
        draft: AgentLearningSkillDraft,
        onSave: @escaping (AgentLearningSkillDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _name = State(initialValue: draft.name)
        _description = State(initialValue: draft.description)
        _skillBody = State(initialValue: draft.body)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Settings.LearningReview.editSkillDraftTitle)
                .font(.title3)
                .fontWeight(.semibold)

            TextField(L10n.Settings.Skill.skillNamePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)

            TextField(L10n.Settings.Skill.descriptionPlaceholder, text: $description)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $skillBody)
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button(L10n.Settings.Skill.cancelButton) {
                    onCancel()
                }
                Button(L10n.Settings.LearningReview.saveSkillDraft) {
                    onSave(
                        AgentLearningSkillDraft(
                            name: normalized(name),
                            description: normalized(description),
                            body: normalizedBody(skillBody)
                        )
                    )
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(normalized(name).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedBody(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.Settings.Skill.defaultBody : trimmed
    }
}
