//
//  AgentComposerTaskProgress.swift
//  WillDeep
//
//  Compact task progress shown immediately above the Agent composer.
//

import SwiftUI

nonisolated struct AgentComposerTaskProgressSnapshot: Equatable {
    enum Kind: Equatable {
        case plan
        case goal
    }

    enum ItemStatus: Equatable {
        case pending
        case active
        case done
        case skipped
        case failed
    }

    struct Item: Equatable, Identifiable {
        let id: UUID
        let text: String
        let status: ItemStatus
    }

    let kind: Kind
    let items: [Item]
    let currentIndex: Int
    let completedCount: Int
    let isComplete: Bool
    let isBlocked: Bool

    var totalCount: Int { items.count }

    var progressFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return min(max(CGFloat(currentIndex) / CGFloat(totalCount), 0), 1)
    }

    var currentItem: Item? {
        guard items.indices.contains(currentIndex - 1) else { return nil }
        return items[currentIndex - 1]
    }

    static func preferred(
        plan: AgentPlan?,
        goal: AgentGoal?,
        isResponding: Bool
    ) -> Self? {
        guard isResponding else { return nil }

        if let planSnapshot = make(plan: plan, isResponding: isResponding) {
            return planSnapshot
        }
        return make(goal: goal, isResponding: isResponding)
    }

    static func make(plan: AgentPlan?, isResponding: Bool) -> Self? {
        guard isResponding,
              let plan,
              !plan.steps.isEmpty,
              plan.status != .proposed,
              plan.status != .rejected,
              plan.status != .done else {
            return nil
        }

        let firstExplicitActiveIndex = plan.steps.firstIndex { $0.status == .inProgress }
        let firstFailedIndex = plan.steps.firstIndex { $0.status == .failed }
        let firstPendingIndex = plan.steps.firstIndex { $0.status == .pending }
        let inferredActiveIndex: Int? = {
            guard firstExplicitActiveIndex == nil,
                  firstFailedIndex == nil,
                  isResponding,
                  plan.status == .approved || plan.status == .executing else {
                return nil
            }
            return firstPendingIndex
        }()

        let items = plan.steps.enumerated().map { offset, step in
            Item(
                id: step.id,
                text: step.text,
                status: itemStatus(
                    for: step.status,
                    isInferredActive: offset == inferredActiveIndex
                )
            )
        }
        let completedCount = items.filter { item in
            item.status == .done || item.status == .skipped
        }.count
        guard completedCount < items.count else { return nil }

        let currentZeroBasedIndex = firstExplicitActiveIndex
            ?? firstFailedIndex
            ?? firstPendingIndex
            ?? items.indices.last
            ?? 0

        return Self(
            kind: .plan,
            items: items,
            currentIndex: currentZeroBasedIndex + 1,
            completedCount: completedCount,
            isComplete: false,
            isBlocked: firstFailedIndex != nil
        )
    }

    static func make(goal: AgentGoal?, isResponding: Bool) -> Self? {
        guard isResponding,
              let goal,
              !goal.checklist.isEmpty else {
            return nil
        }

        let firstOpenIndex = goal.checklist.firstIndex { !$0.done }
        guard firstOpenIndex != nil else { return nil }

        let items = goal.checklist.enumerated().map { offset, item in
            Item(
                id: item.id,
                text: item.text,
                status: item.done
                    ? .done
                    : (offset == firstOpenIndex && isResponding ? .active : .pending)
            )
        }
        let completedCount = goal.checklist.filter(\.done).count
        let currentZeroBasedIndex = firstOpenIndex ?? items.indices.last ?? 0

        return Self(
            kind: .goal,
            items: items,
            currentIndex: currentZeroBasedIndex + 1,
            completedCount: completedCount,
            isComplete: false,
            isBlocked: false
        )
    }

    private static func itemStatus(
        for status: AgentPlan.StepStatus,
        isInferredActive: Bool
    ) -> ItemStatus {
        switch status {
        case .pending:
            return isInferredActive ? .active : .pending
        case .inProgress:
            return .active
        case .done:
            return .done
        case .skipped:
            return .skipped
        case .failed:
            return .failed
        }
    }
}

struct AgentComposerTaskProgressControl: View {
    @EnvironmentObject private var appState: AppState

    let snapshot: AgentComposerTaskProgressSnapshot

    @State private var isPresented = false
    @State private var isPinned = false
    @State private var isPillHovered = false
    @State private var isPanelHovered = false
    @State private var closeGeneration = 0

    var body: some View {
        Button(action: togglePinnedPresentation) {
            HStack(spacing: 7) {
                pillStatusGlyph

                Text(
                    L10n.AgentTurnProgress.composerStepCount(
                        snapshot.currentIndex,
                        snapshot.totalCount
                    )
                )
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 13)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(palette.controlFill.opacity(isPillHovered ? 0.98 : 0.82))
            )
            .overlay(
                Capsule()
                    .stroke(palette.hairline.opacity(0.92), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.055), radius: 7, x: 0, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.AgentTurnProgress.composerHelp)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier("agent.composer.task-progress")
        .onHover(perform: handlePillHover)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentComposerTaskProgressPanel(snapshot: snapshot)
                .environmentObject(appState)
                .onHover(perform: handlePanelHover)
                .onDisappear {
                    isPinned = false
                    isPanelHovered = false
                }
        }
    }

    @ViewBuilder
    private var pillStatusGlyph: some View {
        if snapshot.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.green)
        } else if snapshot.isBlocked {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
        } else {
            ZStack {
                Circle()
                    .stroke(palette.accent.opacity(0.24), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: snapshot.progressFraction)
                    .stroke(
                        palette.accent.opacity(0.88),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
        }
    }

    private var palette: EditorInterfaceSkinPalette {
        appState.editorSettings.interfaceSkin.palette
    }

    private var accessibilityLabel: String {
        L10n.AgentTurnProgress.composerAccessibility(
            snapshot.currentIndex,
            snapshot.totalCount,
            snapshot.currentItem?.text ?? ""
        )
    }

    private func togglePinnedPresentation() {
        closeGeneration += 1
        if isPresented && isPinned {
            isPinned = false
            isPresented = false
            return
        }
        isPinned = true
        isPresented = true
    }

    private func handlePillHover(_ hovering: Bool) {
        isPillHovered = hovering
        if hovering {
            closeGeneration += 1
            isPresented = true
        } else {
            scheduleHoverDismissal()
        }
    }

    private func handlePanelHover(_ hovering: Bool) {
        isPanelHovered = hovering
        if hovering {
            closeGeneration += 1
        } else {
            scheduleHoverDismissal()
        }
    }

    private func scheduleHoverDismissal() {
        closeGeneration += 1
        let generation = closeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard generation == closeGeneration,
                  !isPinned,
                  !isPillHovered,
                  !isPanelHovered else {
                return
            }
            isPresented = false
        }
    }
}

struct AgentComposerTaskProgressPanel: View {
    @EnvironmentObject private var appState: AppState

    let snapshot: AgentComposerTaskProgressSnapshot

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { offset, item in
                    row(item, at: offset)
                }
            }
            .padding(5)
        }
        .scrollIndicators(.visible)
        .frame(width: 196)
        .frame(maxHeight: 300)
        .fixedSize(horizontal: true, vertical: false)
        .background(palette.controlFill.opacity(0.98))
        .accessibilityIdentifier("agent.composer.task-progress.panel")
    }

    private func row(
        _ item: AgentComposerTaskProgressSnapshot.Item,
        at offset: Int
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbolName(for: item.status))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(symbolColor(for: item.status))
                .frame(width: 14, height: 16)

            Text(item.text)
                .font(.system(size: 12, weight: offset + 1 == snapshot.currentIndex ? .medium : .regular))
                .foregroundStyle(textColor(for: item.status))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                L10n.AgentTurnProgress.composerItemAccessibility(
                    offset + 1,
                    statusLabel(for: item.status),
                    item.text
                )
            )
        )
    }

    private var palette: EditorInterfaceSkinPalette {
        appState.editorSettings.interfaceSkin.palette
    }

    private func symbolName(
        for status: AgentComposerTaskProgressSnapshot.ItemStatus
    ) -> String {
        switch status {
        case .pending:
            return "circle"
        case .active:
            return "circle.dotted"
        case .done:
            return "checkmark.circle.fill"
        case .skipped:
            return "minus.circle"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private func symbolColor(
        for status: AgentComposerTaskProgressSnapshot.ItemStatus
    ) -> Color {
        switch status {
        case .pending:
            return palette.secondaryText.opacity(0.62)
        case .active:
            return palette.accent.opacity(0.82)
        case .done:
            return .green
        case .skipped:
            return palette.secondaryText.opacity(0.72)
        case .failed:
            return .orange
        }
    }

    private func textColor(
        for status: AgentComposerTaskProgressSnapshot.ItemStatus
    ) -> Color {
        switch status {
        case .pending, .skipped:
            return palette.primaryText.opacity(0.72)
        case .active, .done, .failed:
            return palette.primaryText
        }
    }

    private func statusLabel(
        for status: AgentComposerTaskProgressSnapshot.ItemStatus
    ) -> String {
        switch status {
        case .pending:
            return L10n.AgentTurnProgress.statusPending
        case .active:
            return L10n.AgentTurnProgress.statusInProgress
        case .done:
            return L10n.AgentTurnProgress.statusDone
        case .skipped:
            return L10n.AgentTurnProgress.statusSkipped
        case .failed:
            return L10n.AgentTurnProgress.statusFailed
        }
    }
}
