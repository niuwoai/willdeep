import SwiftUI

struct AgentDispatchDecisionCards: View {
    @EnvironmentObject private var appState: AppState
    let goal: AgentDispatchGoal

    var body: some View {
        if !goal.outstandingDecisions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.DispatchDecision.waiting).font(.headline)
                    Text(L10n.DispatchDecision.explanation).font(.caption).foregroundStyle(.secondary)
                    ForEach(goal.outstandingDecisions) { decision in
                        AgentDispatchDecisionCard(goal: goal, decision: decision) { answer in
                            appState.answerDispatchDecision(goalID: goal.id, decisionID: decision.id, answer: answer)
                        }
                    }
                }.padding(12)
            }.frame(maxHeight: 260)
            Divider()
        }
    }
}

private struct AgentDispatchDecisionCard: View {
    let goal: AgentDispatchGoal
    let decision: AgentDispatchDecision
    let onAnswer: (String) -> Void
    @State private var answer = ""
    @State private var selections: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !decision.question.title.isEmpty { Text(decision.question.title).fontWeight(.medium) }
            Text(decision.question.question).textSelection(.enabled)
            Text(goal.tasks.filter { task in
                (task.pendingDecisionIDs ?? []).contains(decision.id) && decision.applies(to: task, in: goal)
            }.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(decision.question.requestedInformation.enumerated()), id: \.offset) { _, text in Text(text) }
            if !decision.question.defaultAssumptions.isEmpty {
                Text(L10n.DispatchDecision.assumptions).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(decision.question.defaultAssumptions.enumerated()), id: \.offset) { _, text in Text(text) }
            }
            if let recorded = decision.answer {
                Text(L10n.DispatchDecision.recorded).font(.caption).foregroundStyle(.secondary)
                Text(recorded).textSelection(.enabled)
            } else {
            ForEach(Array(decision.question.options.enumerated()), id: \.offset) { _, option in
                if decision.question.multiSelect {
                    Toggle(option, isOn: Binding(get: { selections.contains(option) }, set: { value in
                        if value { selections.insert(option) } else { selections.remove(option) }
                        answer = decision.question.options.filter { selections.contains($0) }.joined(separator: ", ")
                    }))
                } else {
                    Button(option) { onAnswer(option) }.buttonStyle(.bordered)
                }
            }
            HStack {
                TextField(L10n.DispatchDecision.answerPlaceholder, text: $answer).textFieldStyle(.roundedBorder)
                Button(L10n.DispatchDecision.submit) { onAnswer(answer) }
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.count > 8_000)
            }
            }
        }.padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
