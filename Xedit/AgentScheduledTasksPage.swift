//
//  AgentScheduledTasksPage.swift
//  WillDeep
//
//  Dedicated, searchable home for recurring Agent tasks. The sidebar keeps a
//  single navigation entry while this page scales to any number of routines.
//

import AppKit
import SwiftUI

enum AgentPrimaryDestination: Equatable {
    case conversation
    case scheduledTasks
    case dispatchBoard
    case roundtable
}

enum AgentScheduledTasksFilter {
    static func routines(_ routines: [AgentRoutine], matching query: String) -> [AgentRoutine] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return routines }
        return routines.filter { routine in
            [
                routine.name,
                routine.prompt,
                routine.schedule.summary,
                routine.workspaceDisplayName,
            ].contains { $0.localizedCaseInsensitiveContains(normalized) }
        }
    }
}

enum AgentAutomationTemplate: String, CaseIterable, Identifiable {
    case dailyBrief
    case weeklyReview
    case projectMonitor

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dailyBrief: return "bell"
        case .weeklyReview: return "calendar"
        case .projectMonitor: return "folder.badge.gearshape"
        }
    }

    var color: Color {
        switch self {
        case .dailyBrief: return .blue
        case .weeklyReview: return .purple
        case .projectMonitor: return .green
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
        case .dailyBrief: return .weekdaysAt(hour: 9, minute: 0)
        case .weeklyReview: return .weeklyAt(weekday: 6, hour: 17, minute: 0)
        case .projectMonitor: return .interval(minutes: 120)
        }
    }
}

struct AgentScheduledTasksPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var hoveredRoutineID: AgentRoutine.ID?
    @State private var editing: RoutineSheetTarget?

    private struct RoutineSheetTarget: Identifiable {
        let id = UUID()
        let routine: AgentRoutine
        let isNew: Bool
    }

    private var filteredRoutines: [AgentRoutine] {
        AgentScheduledTasksFilter.routines(appState.agentRoutines, matching: query)
    }

    private var recentRuns: [AgentRoutineRunRecord] {
        AgentRoutineRunHistory.recent(appState.agentRoutineRuns)
    }

    private func pageFont(weight: NSFont.Weight = .regular) -> Font {
        (AgentChatFontChoice.byID(appState.agentChatFontID) ?? .system)
            .swiftUIFont(size: appState.agentChatBaseFontSize, weight: weight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                searchField
                    .padding(.top, 24)

                if !appState.agentRoutines.isEmpty {
                    routinesSection
                        .padding(.top, 28)
                }

                suggestionsSection
                    .padding(.top, 30)

                recentRunsSection
                    .padding(.top, 30)
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { target in
            AgentRoutineEditorView(routine: target.routine, isNew: target.isNew)
                .environmentObject(appState)
        }
        .onAppear(perform: openPendingRoutineIfNeeded)
        .onCompatibleChange(of: appState.pendingRoutineDetailID) { _, _ in
            openPendingRoutineIfNeeded()
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.Automation.pageTitle)
                    .font(pageFont(weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.Automation.pageSubtitle)
                    .font(pageFont())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                openTemplate(nil)
            } label: {
                Label(L10n.Automation.pageNewTask, systemImage: "plus")
                    .font(pageFont(weight: .medium))
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(appState.editorSettings.interfaceSkin.palette.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(L10n.Automation.helpCreate)
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(L10n.Automation.pageSearchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(pageFont())
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.Automation.pageYourTasks)
            if filteredRoutines.isEmpty {
                Text(L10n.Automation.pageEmptySearch)
                    .font(pageFont())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 6) {
                    ForEach(filteredRoutines) { routine in
                        routineRow(routine)
                    }
                }
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.Automation.pageSuggestions)
            VStack(spacing: 4) {
                ForEach(AgentAutomationTemplate.allCases) { template in
                    templateRow(template)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(pageFont(weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func routineRow(_ routine: AgentRoutine) -> some View {
        let isHovered = hoveredRoutineID == routine.id
        let palette = appState.editorSettings.interfaceSkin.palette
        return Button {
            editing = RoutineSheetTarget(routine: routine, isNew: false)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: routine.isEnabled ? "clock.fill" : "clock")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(routine.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(routine.name)
                            .font(pageFont(weight: .medium))
                            .foregroundStyle(routine.isEnabled ? .primary : .secondary)
                            .lineLimit(1)
                        Text(routine.schedule.summary)
                            .font(pageFont())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(routine.prompt)
                        .font(pageFont())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if isHovered {
                    routineActions(routine)
                } else {
                    Text(routine.workspaceDisplayName)
                        .font(pageFont())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .background(isHovered ? palette.hoverFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredRoutineID = routine.id
            } else if hoveredRoutineID == routine.id {
                hoveredRoutineID = nil
            }
        }
        .contextMenu { routineContextMenu(routine) }
    }

    private func routineActions(_ routine: AgentRoutine) -> some View {
        HStack(spacing: 3) {
            iconButton("play.fill", help: L10n.Automation.helpRunNow) {
                appState.runAgentRoutineNow(id: routine.id)
            }
            iconButton(routine.isEnabled ? "pause.fill" : "play.circle", help: routine.isEnabled ? L10n.Automation.menuDisable : L10n.Automation.menuEnable) {
                appState.toggleAgentRoutineEnabled(id: routine.id)
            }
        }
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func routineContextMenu(_ routine: AgentRoutine) -> some View {
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
            presentDeleteAlert(for: routine)
        }
    }

    /// Deleting an automation is unrecoverable — the schedule, prompt and
    /// settings go with it — and it sits one row below Edit in a context
    /// menu, so a mis-click used to destroy it outright. Same explicit
    /// NSAlert gate the session list already uses.
    private func presentDeleteAlert(for routine: AgentRoutine) {
        let alert = NSAlert()
        alert.messageText = L10n.Automation.deleteAlertTitle
        alert.informativeText = L10n.Automation.deleteAlertMessage(
            AgentRoutineDeletionPrompt.displayName(for: routine)
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Automation.deleteConfirm)
        alert.addButton(withTitle: L10n.Automation.deleteCancel)
        if let deleteButton = alert.buttons.first {
            deleteButton.hasDestructiveAction = true
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        appState.deleteAgentRoutine(id: routine.id)
    }

    private func templateRow(_ template: AgentAutomationTemplate) -> some View {
        Button {
            openTemplate(template)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: template.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(template.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(template.name)
                            .font(pageFont(weight: .medium))
                        Text(template.schedule.summary)
                            .font(pageFont())
                            .foregroundStyle(.secondary)
                    }
                    Text(template.prompt)
                        .font(pageFont())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.Automation.pageRecentRuns)
            if recentRuns.isEmpty {
                Text(L10n.Automation.pageNoRecentRuns)
                    .font(pageFont())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 4) {
                    ForEach(recentRuns) { run in
                        recentRunRow(run)
                    }
                }
            }
        }
    }

    private func recentRunRow(_ run: AgentRoutineRunRecord) -> some View {
        let conversationExists = appState.agentSessions.contains { $0.id == run.sessionID }
        return Button {
            _ = appState.selectAgentSession(id: run.sessionID)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(run.routineName)
                    .font(pageFont(weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(pageFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!conversationExists)
        .help(conversationExists ? L10n.Automation.helpOpenRecentRun : L10n.Automation.recentRunUnavailable)
    }

    private func openTemplate(_ template: AgentAutomationTemplate?) {
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

    private func openPendingRoutineIfNeeded() {
        guard let id = appState.pendingRoutineDetailID else { return }
        defer { appState.pendingRoutineDetailID = nil }
        guard let routine = appState.agentRoutines.first(where: { $0.id == id }) else { return }
        editing = RoutineSheetTarget(routine: routine, isNew: false)
    }
}
