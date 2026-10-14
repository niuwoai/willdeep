import SwiftUI

struct AgentSessionSchedulesView: View {
    @EnvironmentObject private var appState: AppState

    private var tasks: [AgentRoutine] {
        guard let sessionID = appState.activeAgentSessionID else { return [] }
        return appState.agentRoutines.filter { $0.originSessionID == sessionID }
    }

    var body: some View {
        if !tasks.isEmpty {
            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tasks) { routine in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(routine.name).lineLimit(1)
                                    Spacer()
                                    Text(routine.completedAt != nil ? L10n.ScheduledTaskCard.completed : routine.isEnabled ? L10n.SessionSchedules.enabled : L10n.SessionSchedules.paused)
                                        .foregroundStyle(.secondary)
                                    Button(routine.isEnabled ? L10n.SessionSchedules.pause : L10n.SessionSchedules.resume) {
                                        appState.toggleAgentRoutineEnabled(id: routine.id)
                                    }
                                    Button(L10n.ScheduledTaskCard.open) {
                                        AgentScheduledTaskCardNavigation.open(cardID: routine.id, in: appState)
                                    }
                                }
                                Text(routine.schedule.summary).foregroundStyle(.secondary)
                                ForEach(AgentRoutineRunHistory.recent(appState.agentRoutineRuns.filter { $0.routineID == routine.id }, limit: 5)) { run in
                                    HStack {
                                        Text(run.startedAt, style: .date)
                                        Text(run.startedAt, style: .time)
                                        Text(L10n.SessionSchedules.outcome(run.outcome))
                                        if let reason = run.failureMessage { Text(reason).lineLimit(2) }
                                    }.foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                }.frame(maxHeight: 180)
            } label: {
                Label("\(L10n.SessionSchedules.title) · \(tasks.count)", systemImage: "clock")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
