import SwiftUI

struct AgentGoalBudgetButton: View {
    let ownerID: UUID
    @State private var editor: Editor?

    private struct Editor: Identifiable {
        let id = UUID()
        let ledger: AgentModelRequestLedger
    }

    var body: some View {
        Button {
            editor = Editor(ledger: AgentModelRequestLedger(
                directory: AgentSessionStore.directory.appendingPathComponent("model-request-ledgers", isDirectory: true),
                ownerID: ownerID))
        } label: {
            Label(L10n.GoalBudget.title, systemImage: "gauge.with.needle")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("goal-budget.open")
        .sheet(item: $editor) { request in
            AgentGoalBudgetSheet(model: AgentGoalBudgetSettings(ledger: request.ledger))
        }
    }
}

struct AgentGoalBudgetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AgentGoalBudgetSettings

    init(model: AgentGoalBudgetSettings) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.GoalBudget.title).font(.headline)
            Text(L10n.GoalBudget.scope).font(.callout).foregroundStyle(.secondary)
            Label(L10n.GoalBudget.coverage, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let snapshot = model.snapshot {
                VStack(spacing: 8) {
                    metric(L10n.GoalBudget.reported, value: snapshot.exposure.accountedTokens.formatted())
                    metric(L10n.GoalBudget.reserved, value: snapshot.exposure.estimatedTokens.formatted())
                    metric(L10n.GoalBudget.unknown, value: snapshot.exposure.unquantifiedAttempts.formatted())
                    metric(L10n.GoalBudget.currentLimit,
                           value: snapshot.policy.tokenLimit?.formatted() ?? L10n.GoalBudget.unlimited)
                    metric(L10n.GoalBudget.remaining, value: remainingLabel(snapshot))
                }
                if snapshot.exposure.unquantifiedAttempts > 0 {
                    Text(L10n.GoalBudget.unknownWarning).font(.caption).foregroundStyle(.orange)
                }
            }

            Toggle(L10n.GoalBudget.limitEnabled, isOn: $model.isLimited)
                .disabled(model.snapshot == nil || model.isBusy)
                .accessibilityIdentifier("goal-budget.limit-enabled")
            if model.isLimited {
                TextField(L10n.GoalBudget.limitPlaceholder, text: $model.limitText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.snapshot == nil || model.isBusy)
                    .accessibilityIdentifier("goal-budget.limit")
                Text(L10n.GoalBudget.limitHint).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.GoalBudget.saveBehavior).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("goal-budget.error")
            }
            if let date = model.loadedAt {
                HStack(spacing: 4) {
                    Text(L10n.GoalBudget.snapshotTime)
                    Text(date, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.GoalBudget.reload) { Task { await model.load() } }
                    .disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.GoalEditorSheet.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button(L10n.GoalEditorSheet.save) {
                    Task { if await model.save() { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .accessibilityIdentifier("goal-budget.save")
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isBusy)
        .task { if model.snapshot == nil { await model.load() } }
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }.font(.callout)
    }

    private func remainingLabel(_ value: AgentModelRequestLedger.BudgetSnapshot) -> String {
        if value.policy.tokenLimit == nil { return L10n.GoalBudget.unlimited }
        return value.remainingTokens?.formatted() ?? L10n.GoalBudget.unquantified
    }
}
