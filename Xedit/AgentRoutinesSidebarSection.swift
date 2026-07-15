//
//  AgentRoutinesSidebarSection.swift
//  WillDeep
//
//  The user-facing Automations block in the Agent-mode sidebar. The
//  underlying model is still AgentRoutine for storage compatibility.
//

import SwiftUI

struct AgentRoutinesSidebarSection: View {
    @EnvironmentObject var appState: AppState

    /// The routine row currently under the mouse — drives the hover-only
    /// trailing controls (toggle / edit / delete). Same cursor-style
    /// pattern as session rows.
    @State private var hoveredRoutineID: AgentRoutine.ID?
    /// Routine being edited in the sheet, or nil when the sheet is closed.
    /// Using `Identifiable`-based `.sheet(item:)` so the sheet recreates
    /// fresh state every time it opens.
    @State private var editing: RoutineSheetTarget?

    private struct RoutineSheetTarget: Identifiable {
        let id = UUID()
        let routine: AgentRoutine
        let isNew: Bool
    }

    private enum AutomationTemplate: String, CaseIterable, Identifiable {
        case dailyBrief, weeklyReview, projectMonitor

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .dailyBrief: return "bell"
            case .weeklyReview: return "calendar"
            case .projectMonitor: return "folder.badge.gearshape"
            }
        }

        var name: String {
            switch self {
            case .dailyBrief: return L10n.Automation.templateDailyBriefName
            case .weeklyReview: return L10n.Automation.templateWeeklyReviewName
            case .projectMonitor: return L10n.Automation.templateProjectMonitorName
            }
        }

        var prompt: String {
            switch self {
            case .dailyBrief: return L10n.Automation.templateDailyBriefPrompt
            case .weeklyReview: return L10n.Automation.templateWeeklyReviewPrompt
            case .projectMonitor: return L10n.Automation.templateProjectMonitorPrompt
            }
        }

        var schedule: AgentRoutineSchedule {
            switch self {
            case .dailyBrief:
                return .weekdaysAt(hour: 9, minute: 0)
            case .weeklyReview:
                return .weeklyAt(weekday: 6, hour: 17, minute: 0)
            case .projectMonitor:
                return .interval(minutes: 120)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if appState.agentRoutines.isEmpty {
                emptyState
            } else {
                ForEach(appState.agentRoutines) { routine in
                    routineRow(routine)
                }
            }
            Spacer().frame(height: 12)
        }
        .sheet(item: $editing) { target in
            AgentRoutineEditorView(routine: target.routine, isNew: target.isNew)
                .environmentObject(appState)
        }
        .onChange(of: appState.pendingRoutineDetailID) { newValue in
            // A transcript scheduled-task card asked to open this task's detail.
            guard let id = newValue else { return }
            if let routine = appState.agentRoutines.first(where: { $0.id == id }) {
                editing = RoutineSheetTarget(routine: routine, isNew: false)
            }
            appState.pendingRoutineDetailID = nil
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L10n.Automation.header)
                .font(AgentDesign.sidebarSectionFont)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            Button {
                openTemplate(nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.Automation.helpCreate)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(L10n.Automation.emptyState)
                    .font(AgentDesign.sidebarAutomationFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(AutomationTemplate.allCases) { template in
                    templateButton(template)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func templateButton(_ template: AutomationTemplate) -> some View {
        Button {
            openTemplate(template)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: template.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
                Text(template.name)
                    .font(AgentDesign.sidebarAutomationFont)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func routineRow(_ routine: AgentRoutine) -> some View {
        let isHovered = (hoveredRoutineID == routine.id)
        let isEnabled = routine.isEnabled

        Button {
            editing = RoutineSheetTarget(routine: routine, isNew: false)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isEnabled ? "clock.fill" : "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 1) {
                    Text(routine.name)
                        .font(AgentDesign.sidebarAutomationFont)
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(routine.schedule.summary)
                        .font(AgentDesign.sidebarAutomationFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                trailingActions(routine: routine, isHovered: isHovered)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredRoutineID = routine.id
            } else if hoveredRoutineID == routine.id {
                hoveredRoutineID = nil
            }
        }
        .contextMenu {
            Button(routine.isEnabled ? L10n.Automation.menuDisable : L10n.Automation.menuEnable) {
                appState.toggleAgentRoutineEnabled(id: routine.id)
            }
            Button(L10n.Automation.runNow) {
                appState.runAgentRoutineNow(id: routine.id)
            }
            Divider()
            Button(L10n.Automation.edit) {
                editing = RoutineSheetTarget(routine: routine, isNew: false)
            }
            Button(L10n.Automation.delete, role: .destructive) {
                appState.deleteAgentRoutine(id: routine.id)
            }
        }
    }

    @ViewBuilder
    private func trailingActions(routine: AgentRoutine, isHovered: Bool) -> some View {
        HStack(spacing: 4) {
            if isHovered {
                Button {
                    appState.runAgentRoutineNow(id: routine.id)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.Automation.helpRunNow)

                Button {
                    appState.toggleAgentRoutineEnabled(id: routine.id)
                } label: {
                    Image(systemName: routine.isEnabled ? "pause.fill" : "play.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(routine.isEnabled ? L10n.Automation.menuDisable : L10n.Automation.menuEnable)
            }
        }
    }

    private func openTemplate(_ template: AutomationTemplate?) {
        var seeded = AgentRoutine(
            workspaceRootPath: appState.rootDirectory?.standardizedFileURL.path
        )
        if let template {
            seeded.name = template.name
            seeded.prompt = template.prompt
            seeded.schedule = template.schedule
        }
        editing = RoutineSheetTarget(routine: seeded, isNew: true)
    }
}
