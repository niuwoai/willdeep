//
//  AgentScheduledTasksPage.swift
//  WillDeep
//
//  Dedicated, searchable home for recurring Agent tasks. The sidebar keeps a
//  single navigation entry while this page scales to any number of routines.
//

import AppKit
import SwiftUI

/// 任务卡片标题行的固定尺寸。悬停操作条是这一行里最高的东西，标题行按它定高，
/// 操作条出现或消失时整张卡片的高度就不会变。
enum AgentScheduledTaskRowMetrics {
    static let actionButtonSide: CGFloat = 26
    /// 必须 ≥ `actionButtonSide`，否则悬停时按钮还是会把行撑高。
    static let titleRowHeight: CGFloat = 26
}

enum AgentPrimaryDestination: Equatable {
    case conversation
    case scheduledTasks
    case dispatchBoard
    case roundtable
    case plugin(AgentPluginDestinationID)
    case pluginCenter

    var pluginDestinationID: AgentPluginDestinationID? {
        guard case .plugin(let id) = self else { return nil }
        return id
    }

    var hostsDedicatedCenterSurface: Bool {
        switch self {
        case .conversation:
            return false
        case .scheduledTasks, .dispatchBoard, .roundtable, .plugin, .pluginCenter:
            return true
        }
    }
}

/// How one run reads in the recent-runs list.
///
/// A finished run carries no verdict here — no `失败` label, no warning
/// triangle, no extra weight. The reason: a scheduled run that failed at
/// 22:00 is routinely dealt with by hand afterwards, in the conversation it
/// left behind, and nothing ever came back to clear the badge. The list then
/// showed a permanent alarm for a problem that was fixed days ago, which is
/// worse than showing nothing — it trains you to ignore the section.
///
/// What survives is the part that was actually informative: the failure
/// reason, rendered as one muted line by the row itself. `运行中` keeps its
/// label because it is not a verdict — it says something is happening right
/// now, and it clears itself.
struct AgentRoutineRunOutcomePresentation: Equatable {
    let systemImage: String
    let label: String?

    init(outcome: AgentRoutineRunOutcome) {
        switch outcome {
        case .running:
            systemImage = "clock.arrow.circlepath"
            label = L10n.Automation.runOutcomeRunning
        case .succeeded, .failed, .interrupted, .unknown:
            systemImage = "clock"
            label = nil
        }
    }
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

    /// One type scale for the whole page, expressed as offsets from the
    /// user's chat size.
    ///
    /// Everything here — task name, schedule, prompt, workspace, timestamp —
    /// used to be drawn at exactly the same size, so three sections of
    /// near-identical rows arrived with no hierarchy at all: nothing said
    /// which line was the thing and which lines were about the thing. The
    /// floor at 10pt keeps the meta line legible for someone who has turned
    /// their chat text down.
    private func pageFont(_ sizeDelta: CGFloat = 0, weight: NSFont.Weight = .regular) -> Font {
        (AgentChatFontChoice.byID(appState.agentChatFontID) ?? .system)
            .swiftUIFont(size: max(10, appState.agentChatBaseFontSize + sizeDelta), weight: weight)
    }

    /// `每天 22:00 · muchtoken · 下次 22:00`
    private func metaLine(for routine: AgentRoutine) -> String {
        var parts = [routine.schedule.summary, routine.workspaceDisplayName]
        if !routine.isEnabled {
            parts.append(L10n.Automation.pagePaused)
        } else if let next = routine.nextFireDate() {
            let when = Calendar.current.isDateInToday(next)
                ? next.formatted(date: .omitted, time: .shortened)
                : next.formatted(date: .abbreviated, time: .shortened)
            parts.append(L10n.Automation.pageNextRun(when))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                searchField
                    .padding(.top, 24)

                if !appState.agentRoutines.isEmpty {
                    routinesSection
                        .padding(.top, 26)
                }

                suggestionsSection
                    .padding(.top, 26)

                recentRunsSection
                    .padding(.top, 26)
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 48)
            // The page body has a deliberate reading-width cap. Once the
            // center column grows beyond it, keep that body centered instead
            // of pinning the whole Scheduled page to the sidebar edge.
            .frame(maxWidth: .infinity, alignment: .center)
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
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(L10n.Automation.pageYourTasks, count: filteredRoutines.count)
            if filteredRoutines.isEmpty {
                Text(L10n.Automation.pageEmptySearch)
                    .font(pageFont(-1))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 7) {
                    ForEach(filteredRoutines) { routine in
                        routineCard(routine)
                    }
                }
            }
        }
    }

    /// Suggestions are offers, not tasks. Rendering them as full-width rows
    /// with a prompt line made them read as three more scheduled tasks the
    /// user had somehow forgotten about — the page's own "your tasks" list
    /// and its catalogue of templates looked identical. They are compact
    /// cards now: name, cadence, a plus. What they are, and nothing more.
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(L10n.Automation.pageSuggestions)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(AgentAutomationTemplate.allCases) { template in
                    templateCard(template)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(pageFont(-1, weight: .semibold))
                .foregroundStyle(.primary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(pageFont(-2.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A task is the page's primary object, so it gets a card: name on its
    /// own line, then one meta line that answers "when, where, and when
    /// next", then the prompt.
    ///
    /// The workspace name used to float alone at the far right edge of a
    /// flat row, a full column away from the task it belonged to. It now
    /// sits in the meta line where it reads as an attribute of the task.
    private func routineCard(_ routine: AgentRoutine) -> some View {
        let isHovered = hoveredRoutineID == routine.id
        let palette = appState.editorSettings.interfaceSkin.palette
        return Button {
            editing = RoutineSheetTarget(routine: routine, isNew: false)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: routine.isEnabled ? "clock.fill" : "pause.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(routine.isEnabled ? Color.accentColor : Color.secondary)
                    Text(routine.name)
                        .font(pageFont(weight: .semibold))
                        .foregroundStyle(routine.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // 常驻布局、只切换可见性：以前是 `if isHovered` 直接插进
                    // 这一行，26 pt 的按钮一出现就把标题行、连带整张卡片撑高，
                    // 鼠标扫过列表就是一路抖。
                    routineActions(routine)
                        .hoverRevealed(isHovered)
                }
                .frame(height: AgentScheduledTaskRowMetrics.titleRowHeight)
                Text(metaLine(for: routine))
                    .font(pageFont(-2.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(routine.prompt)
                    .font(pageFont(-1))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Skin-neutral on purpose: the light skin's `controlFill` is
            // near-white against a near-white page, which drew "cards" with
            // no edge at all — three tasks read as one block of text.
            .background(isHovered ? palette.hoverFill : Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
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
                .frame(
                    width: AgentScheduledTaskRowMetrics.actionButtonSide,
                    height: AgentScheduledTaskRowMetrics.actionButtonSide
                )
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

    private func templateCard(_ template: AgentAutomationTemplate) -> some View {
        Button {
            openTemplate(template)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: template.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(template.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .font(pageFont(-1, weight: .medium))
                        .lineLimit(1)
                    Text(template.schedule.summary)
                        .font(pageFont(-2.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(template.prompt)
    }

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(L10n.Automation.pageRecentRuns)
            if recentRuns.isEmpty {
                Text(L10n.Automation.pageNoRecentRuns)
                    .font(pageFont(-1))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 1) {
                    ForEach(recentRuns) { run in
                        recentRunRow(run)
                    }
                }
            }
        }
    }

    private func recentRunRow(_ run: AgentRoutineRunRecord) -> some View {
        let conversationExists = appState.agentSessions.contains { $0.id == run.sessionID }
        let presentation = AgentRoutineRunOutcomePresentation(outcome: run.outcome)
        return Button {
            _ = appState.selectAgentSession(id: run.sessionID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 13)
                Text(run.routineName)
                    .font(pageFont(-1))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                // The reason is what the removed `失败` badge was standing in
                // front of, and the only line here that explains anything.
                if let failureMessage = run.failureMessage, !failureMessage.isEmpty {
                    Text(failureMessage)
                        .font(pageFont(-2.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 10)
                if let label = presentation.label {
                    Text(label)
                        .font(pageFont(-2.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(pageFont(-2.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
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
