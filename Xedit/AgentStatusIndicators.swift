//
//  AgentStatusIndicators.swift
//  WillDeep
//
//  Small status / dashboard surfaces shared across the chat pane, split
//  out of AgentModeView.swift in rc42:
//
//   - `AgentStatsDashboard`: the activity panel shown inside the empty
//     state for installs with at least one session. Its overview follows a
//     quiet, Codex-like activity page: one metric strip, an activity map,
//     and two grounded summaries for work patterns and used capabilities.
//   - `PlanStatusPill`: tiny capsule that labels the current AgentPlan
//     status — proposed (orange) / approved+executing (green) / done
//     (blue) / rejected (red). Used by `AgentPlanCard`.
//
//  Previously `private struct` inside AgentModeView.swift; now internal
//  so the chat empty state and plan card can mount them across files.
//

import SwiftUI

// MARK: - Stats dashboard

enum AgentModelUsageTableLayout {
    static let horizontalInset: CGFloat = 8
    static let columnSpacing: CGFloat = 8
    static let tokensWidth: CGFloat = 120
    static let cacheWidth: CGFloat = 56
    static let costWidth: CGFloat = 72
}

enum AgentStatsDashboardTypography {
    // Codex profile-card scale. Supporting copy stays readable while the
    // profile name and five top-line metrics carry the hierarchy.
    static let body: CGFloat = 14
    static let sectionTitle: CGFloat = 14
    static let metricValue: CGFloat = 15
    static let metricLabel: CGFloat = 13
    static let profileName: CGFloat = 22
    static let profileMeta: CGFloat = 13
    static let heroValue: CGFloat = 34
    static let heroLabel: CGFloat = 16
    static let modelSummaryValue: CGFloat = 24
    static let compactBadge: CGFloat = body
}

enum AgentStatsDashboardLayout {
    static let panelPadding: CGFloat = 0
    static let profileAvatarSize: CGFloat = 80
    static let summaryCornerRadius: CGFloat = 15
    static let metricStripHeight: CGFloat = 61
    static let heatmapCellSize: CGFloat = 8
    static let heatmapCellSpacing: CGFloat = 3
    static let maximumHeatmapWeeks = 52
}

enum AgentStatsDashboardFormatting {
    static func duration(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 60 else { return "0m" }

        let totalMinutes = Int(value / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d\(hours)h\(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }
}

struct AgentStatsDashboard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: DashboardTab
    @State private var activityMode: ActivityMode = .daily
    @State private var displayedMonth: Date
    @State private var account = SomeIMIntegrationStore.loadAuthenticatedAccount()
    private let now: Date

    init(initialTab: DashboardTab = .overview, now: Date = Date()) {
        _selectedTab = State(initialValue: initialTab)
        _displayedMonth = State(
            initialValue: Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        )
        self.now = now
    }

    enum DashboardTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case models = "Models"
        case workers = "Workers"
        case calendar = "Calendar"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return L10n.StatsDashboard.tabsOverview
            case .models: return L10n.StatsDashboard.tabsModels
            case .workers: return L10n.StatsDashboard.tabsWorkers
            case .calendar: return L10n.StatsDashboard.usageCalendarTitle
            }
        }
    }

    enum ActivityMode: String, CaseIterable, Identifiable {
        case daily
        case weekly
        case cumulative
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: return L10n.StatsDashboard.activityDaily
            case .weekly: return L10n.StatsDashboard.activityWeekly
            case .cumulative: return L10n.StatsDashboard.activityCumulative
            }
        }
    }

    var body: some View {
        Group {
            if appState.hasLoadedAgentUsageSnapshots {
                dashboardContent
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(AgentStatsDashboardLayout.panelPadding)
        .task {
            await appState.loadAgentUsageSnapshotsIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: SomeIMIntegrationStore.accountDidChangeNotification
            )
        ) { _ in
            account = SomeIMIntegrationStore.loadAuthenticatedAccount()
        }
    }

    private var dashboardContent: some View {
        Group {
            switch selectedTab {
            case .overview:
                VStack(alignment: .leading, spacing: 0) {
                    profileHeader
                        .padding(.bottom, 43)
                    overviewSummaryBand
                        .padding(.bottom, 39)
                    activitySection
                        .padding(.bottom, 40)
                    detailSections
                }
            case .models:
                VStack(alignment: .leading, spacing: 14) {
                    modelDetailHeader
                    modelSummaryBand
                    modelUsageList
                }
            case .workers:
                VStack(alignment: .leading, spacing: 14) {
                    workerDetailHeader
                    workerSummaryBand
                    workerKPIBand
                    workerUsageList
                }
            case .calendar:
                usageCalendar
            }
        }
    }

    private var modelDetailHeader: some View {
        detailHeader(title: L10n.StatsDashboard.tabsModels)
    }

    private var workerDetailHeader: some View {
        detailHeader(title: L10n.StatsDashboard.tabsWorkers)
    }

    private func detailHeader(title: String) -> some View {
        HStack {
            Button {
                selectedTab = .overview
            } label: {
                Label(L10n.StatsDashboard.tabsOverview, systemImage: "chevron.left")
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.body,
                        weight: .medium
                    ))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text(title)
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.sectionTitle,
                    weight: .semibold
                ))
        }
    }

    /// All aggregates come from AppState's memoized model: recomputed only
    /// when the snapshots change, not on every body evaluation.
    private var dashboardModel: AgentUsageDashboardModel {
        appState.agentUsageDashboardModel()
    }

    private var overview: AgentUsageOverview {
        dashboardModel.overview
    }

    private var modelUsageRows: [AgentModelUsageRow] {
        dashboardModel.modelUsage
    }

    private var capabilityRows: [AgentCapabilityUsageRow] {
        dashboardModel.capabilityUsage
    }

    private var subagentUsageRows: [AgentSubagentUsageRow] {
        dashboardModel.subagentUsage
    }

    private var profileHeader: some View {
        VStack(spacing: 0) {
            profileAvatar
                .padding(.bottom, 23)
            Text(profileDisplayName)
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.profileName,
                    weight: .regular
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                Text(profileHandle)
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.profileMeta
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(profilePlanName)
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.profileMeta
                    ))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                appState.editorSettings.interfaceSkin.palette.hairline,
                                lineWidth: 1
                            )
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var profileAvatar: some View {
        ZStack {
            Circle()
                .fill(dashboardAvatarFill)
            if let url = validatedAvatarURL(account?.avatarURL) {
                CachedAvatarImage(url: url) {
                    profileInitials
                }
            } else {
                profileInitials
            }
        }
        .frame(
            width: AgentStatsDashboardLayout.profileAvatarSize,
            height: AgentStatsDashboardLayout.profileAvatarSize
        )
        .clipShape(Circle())
    }

    private var profileInitials: some View {
        Text(initials(for: profileDisplayName))
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(Color.white)
    }

    private var profileDisplayName: String {
        let accountName = account?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !accountName.isEmpty {
            return accountName
        }
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return fullName.isEmpty ? NSUserName() : fullName
    }

    private var profileHandle: String {
        if let email = account?.email,
           let localPart = email.split(separator: "@").first,
           !localPart.isEmpty {
            return "@\(localPart)"
        }
        return "@\(NSUserName())"
    }

    private var profilePlanName: String {
        let status = appState.someIMCodingPlanStatus
        if status.isActiveNow {
            let name = status.planName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? L10n.StatsDashboard.profilePlanPro : name
        }
        return L10n.StatsDashboard.profilePlanFree
    }

    private var overviewSummaryBand: some View {
        let stats = overview
        return HStack(spacing: 0) {
            Button {
                selectedTab = .models
            } label: {
                CodexDashboardMetric(
                    value: formatTokenCount(stats.totalTokens),
                    title: L10n.StatsDashboard.metricTotalTokens
                )
            }
            .buttonStyle(.plain)
            .help(L10n.StatsDashboard.modelsDisclosureHelp)
            metricDivider
            CodexDashboardMetric(
                value: formatTokenCount(peakTaskTokenCount),
                title: L10n.StatsDashboard.metricPeakTokens
            )
            metricDivider
            CodexDashboardMetric(
                value: L10n.StatsDashboard.dayCount("\(stats.currentStreak)"),
                title: L10n.StatsDashboard.metricCurrentStreak
            )
            metricDivider
            CodexDashboardMetric(
                value: L10n.StatsDashboard.dayCount("\(stats.longestStreak)"),
                title: L10n.StatsDashboard.metricLongestStreak
            )
        }
        .frame(height: AgentStatsDashboardLayout.metricStripHeight)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius)
                .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
        )
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 43)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.StatsDashboard.activityTitle)
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.sectionTitle,
                        weight: .semibold
                    ))
                Spacer(minLength: 0)
                HStack(spacing: 13) {
                    ForEach(ActivityMode.allCases) { mode in
                        Button {
                            activityMode = mode
                        } label: {
                            Text(mode.title)
                                .font(supportingFont(
                                    visualMinimum: AgentStatsDashboardTypography.body,
                                    weight: activityMode == mode ? .medium : .regular
                                ))
                                .foregroundStyle(activityMode == mode ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 11)

            GeometryReader { proxy in
                let cellSize = AgentStatsDashboardLayout.heatmapCellSize
                let cellSpacing = AgentStatsDashboardLayout.heatmapCellSpacing
                let cells = activityCells
                let displayCounts = activityDisplayCounts(cells)
                let maxCount = displayCounts.flatMap { $0 }.max() ?? 0

                HStack(spacing: cellSpacing) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { columnIndex, column in
                        VStack(spacing: cellSpacing) {
                            ForEach(Array(column.enumerated()), id: \.element.id) { rowIndex, cell in
                                // One tooltip string per cell per pass, via
                                // the cached formatter. The previous code
                                // formatted the tooltip twice per cell with
                                // a freshly allocated DateFormatter each
                                // time — ~700 formatter allocations for the
                                // 53-week grid on every body evaluation,
                                // which showed up as periodic main-thread
                                // stutter whenever AppState published.
                                let tooltip = L10n.HeatmapCell.tooltip(
                                    cellDateLabel(cell.date),
                                    formatInteger(cell.requestCount),
                                    formatTokenCount(cell.tokenCount)
                                )
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(color(
                                        for: displayCounts[columnIndex][rowIndex],
                                        peak: maxCount
                                    ))
                                    .frame(width: cellSize, height: cellSize)
                                    .help(tooltip)
                                    .accessibilityLabel(tooltip)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: heatmapHeight)
            .padding(.bottom, 10)

            monthLabels
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTab = .calendar
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L10n.StatsDashboard.usageCalendarOpenHelp)
        .accessibilityIdentifier("stats-token-activity")
        .accessibilityAction {
            selectedTab = .calendar
        }
    }

    private var usageCalendar: some View {
        let usage = AgentUsageStats.dailyUsage(
            for: appState.agentUsageSnapshots,
            in: displayedMonth
        )
        return VStack(alignment: .leading, spacing: 14) {
            detailHeader(title: L10n.StatsDashboard.usageCalendarTitle)
            usageCalendarMonthToolbar(usage: usage)
            usageCalendarWeekdayHeader
            usageCalendarGrid(usage: usage)
        }
        .accessibilityIdentifier("stats-usage-calendar")
    }

    private func usageCalendarMonthToolbar(usage: [AgentDailyUsage]) -> some View {
        HStack(spacing: 8) {
            Button {
                changeDisplayedMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.StatsDashboard.usageCalendarPreviousMonth)
            .accessibilityIdentifier("stats-usage-calendar-previous-month")

            Text(displayedMonth.formatted(.dateTime.year().month(.wide)))
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.profileName,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Button {
                changeDisplayedMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.StatsDashboard.usageCalendarNextMonth)
            .accessibilityIdentifier("stats-usage-calendar-next-month")

            Spacer(minLength: 12)

            Text(monthlyUsageSummary(usage))
                .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var usageCalendarWeekdayHeader: some View {
        LazyVGrid(columns: usageCalendarColumns, spacing: 0) {
            ForEach(Array(L10n.StatsDashboard.usageCalendarWeekdays.enumerated()), id: \.offset) { _, title in
                Text(title)
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.metricLabel,
                        weight: .medium
                    ))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func usageCalendarGrid(usage: [AgentDailyUsage]) -> some View {
        let usageByDay = Dictionary(uniqueKeysWithValues: usage.map {
            (Calendar.current.startOfDay(for: $0.date), $0)
        })
        return LazyVGrid(columns: usageCalendarColumns, spacing: 8) {
            ForEach(AgentUsageStats.calendarGridDates(for: displayedMonth), id: \.self) { date in
                usageCalendarDayCell(
                    date: date,
                    usage: usageByDay[Calendar.current.startOfDay(for: date)]
                )
            }
        }
    }

    private func usageCalendarDayCell(date: Date, usage: AgentDailyUsage?) -> some View {
        let isDisplayedMonth = Calendar.current.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isToday = isDisplayedMonth && Calendar.current.isDate(date, inSameDayAs: now)
        let dayNumber = Calendar.current.component(.day, from: date)
        return VStack(alignment: .center, spacing: 0) {
            Text("\(dayNumber)")
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.body,
                    weight: isToday ? .semibold : .regular
                ))
                .foregroundStyle(dayCellForeground(isToday: isToday, isDisplayedMonth: isDisplayedMonth))

            if isDisplayedMonth {
                Spacer(minLength: 4)
                Text(formatCalendarTokens(usage?.tokenCount ?? 0))
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.metricValue,
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(dayCellForeground(isToday: isToday, isDisplayedMonth: true))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(calendarDayFooter(usage))
                    .font(supportingFont(visualMinimum: 10))
                    .foregroundStyle(isToday ? Color.white.opacity(0.84) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .top)
        .background(dayCellBackground(isToday: isToday, isDisplayedMonth: isDisplayedMonth))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if isDisplayedMonth && !isToday {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var usageCalendarColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 48), spacing: 8),
            count: 7
        )
    }

    private func changeDisplayedMonth(by offset: Int) {
        guard let month = Calendar.current.date(
            byAdding: .month,
            value: offset,
            to: displayedMonth
        ) else {
            return
        }
        displayedMonth = Calendar.current.dateInterval(of: .month, for: month)?.start ?? month
    }

    private func monthlyUsageSummary(_ usage: [AgentDailyUsage]) -> String {
        let totalTokens = usage.reduce(0) { $0 + $1.tokenCount }
        let cost: String
        if usage.contains(where: { $0.estimatedCostUSD == nil }) {
            cost = L10n.ModelUsage.costUnknown
        } else {
            cost = formatCalendarCost(usage.compactMap(\.estimatedCostUSD).reduce(0, +))
        }
        return L10n.StatsDashboard.usageCalendarMonthSummary(
            formatCalendarTokens(totalTokens),
            cost,
            formatInteger(monthlySessionCount)
        )
    }

    private var monthlySessionCount: Int {
        guard let interval = Calendar.current.dateInterval(of: .month, for: displayedMonth) else {
            return 0
        }
        return appState.agentUsageSnapshots.count { session in
            session.messages.contains { interval.contains($0.createdAt) }
        }
    }

    private func calendarDayFooter(_ usage: AgentDailyUsage?) -> String {
        let cost = usage?.estimatedCostUSD.map(formatCalendarCost) ?? L10n.ModelUsage.costUnknown
        return L10n.StatsDashboard.usageCalendarDaySummary(
            cost,
            formatInteger(usage?.sessionCount ?? 0)
        )
    }

    private func formatCalendarTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000)
                .replacingOccurrences(of: ".00M", with: "M")
                .replacingOccurrences(of: "0M", with: "M")
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
                .replacingOccurrences(of: ".0k", with: "k")
        }
        return formatInteger(count)
    }

    private func formatCalendarCost(_ cost: Double) -> String {
        cost < 0.01 && cost > 0
            ? String(format: "$%.4f", cost)
            : String(format: "$%.2f", cost)
    }

    private func dayCellForeground(isToday: Bool, isDisplayedMonth: Bool) -> Color {
        if isToday { return .white }
        return isDisplayedMonth ? .primary : Color.secondary.opacity(0.45)
    }

    private func dayCellBackground(isToday: Bool, isDisplayedMonth: Bool) -> Color {
        if isToday {
            return Color(red: 0.10, green: 0.10, blue: 0.10)
        }
        if isDisplayedMonth {
            return colorScheme == .dark
                ? Color.white.opacity(0.025)
                : Color.black.opacity(0.012)
        }
        return .clear
    }

    private var heatmapHeight: CGFloat {
        let cellSize = AgentStatsDashboardLayout.heatmapCellSize
        let cellSpacing = AgentStatsDashboardLayout.heatmapCellSpacing
        return 7 * cellSize + 6 * cellSpacing
    }

    private var detailSections: some View {
        HStack(alignment: .top, spacing: 40) {
            insightSection
                .frame(maxWidth: .infinity, alignment: .leading)
            capabilitySection
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var insightSection: some View {
        let stats = overview
        return VStack(alignment: .leading, spacing: 11) {
            Text(L10n.StatsDashboard.insightsTitle)
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.sectionTitle,
                    weight: .semibold
                ))
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightManagedRouting,
                value: formatPercentage(managedRoutingRate)
            )
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightReasoningUsage,
                value: formatPercentage(reasoningUsageRate)
            )
            Button {
                selectedTab = .workers
            } label: {
                DashboardInsightRow(
                    title: L10n.StatsDashboard.insightFavoriteWorker,
                    value: favoriteWorkerLabel,
                    showsDisclosure: true
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.StatsDashboard.workersDisclosureHelp)
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightExploredSkills,
                value: formatInteger(uniqueToolCount)
            )
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightSkillUses,
                value: formatInteger(stats.toolCallCount)
            )
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightTasksTotal,
                value: formatInteger(stats.userTurnCount)
            )
        }
    }

    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(L10n.StatsDashboard.pluginsTitle)
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.sectionTitle,
                    weight: .semibold
                ))
            if capabilityRows.isEmpty {
                Text(L10n.StatsDashboard.pluginsEmpty)
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 68, alignment: .leading)
            } else {
                ForEach(Array(capabilityRows.prefix(5).enumerated()), id: \.element.id) { index, row in
                    CodexDashboardPluginRow(
                        capability: row.capability,
                        callCount: row.callCount,
                        tint: pluginTint(at: index)
                    )
                }
            }
        }
    }

    private var activityCells: [[AgentHeatmapCell]] {
        dashboardModel.heatmapCells
    }

    private func activityDisplayCounts(_ cells: [[AgentHeatmapCell]]) -> [[Int]] {
        switch activityMode {
        case .daily:
            return cells.map { $0.map(\.tokenCount) }
        case .weekly:
            return cells.map { column in
                let weeklyTotal = column.reduce(0) { $0 + $1.tokenCount }
                return column.map { _ in weeklyTotal }
            }
        case .cumulative:
            var runningTotal = 0
            return cells.map { column in
                column.map { cell in
                    runningTotal += cell.tokenCount
                    return runningTotal
                }
            }
        }
    }

    private static var cachedMonthFormatter: DateFormatter?

    private var monthLabels: some View {
        // Same caching rationale as `cellDateLabel`: this runs on every
        // body evaluation of an always-mounted dashboard.
        let formatter: DateFormatter
        if let cached = Self.cachedMonthFormatter, cached.locale == Locale.current {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = .current
            formatter.setLocalizedDateFormatFromTemplate("MMM")
            Self.cachedMonthFormatter = formatter
        }
        let calendar = Calendar.current
        let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) ?? Date()
        let months = (0..<12).compactMap { offset in
            calendar.date(byAdding: .month, value: offset - 11, to: currentMonth)
        }
        return HStack(spacing: 0) {
            ForEach(Array(months.enumerated()), id: \.offset) { index, date in
                Text(formatter.string(from: date))
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.metricLabel
                    ))
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: index == 0 ? .leading : (index == months.count - 1 ? .trailing : .center)
                    )
            }
        }
        .frame(height: 18)
    }

    private var peakTaskTokenCount: Int {
        dashboardModel.peakTaskTokenCount
    }

    private var managedRoutingRate: Double {
        dashboardModel.managedRoutingRate
    }

    private var reasoningUsageRate: Double {
        dashboardModel.reasoningUsageRate
    }

    private var favoriteWorkerLabel: String {
        guard let row = subagentUsageRows.first else { return "—" }
        let profile = AgentSubagentProfileCatalog.profile(id: row.profileID)
        return L10n.StatsDashboard.favoriteWorkerValue(
            profile.localizedDisplayName,
            formatInteger(row.invocationCount)
        )
    }

    private var uniqueToolCount: Int {
        dashboardModel.uniqueToolCount
    }

    private func pluginTint(at index: Int) -> Color {
        let colors: [Color] = [
            Color(red: 0.70, green: 0.31, blue: 0.91),
            Color(red: 0.18, green: 0.67, blue: 0.93),
            Color(red: 0.98, green: 0.56, blue: 0.20),
            Color(red: 0.45, green: 0.33, blue: 0.89),
            Color(red: 0.30, green: 0.33, blue: 0.37),
        ]
        return colors[index % colors.count]
    }

    private var workerSummaryBand: some View {
        let totalCalls = subagentUsageRows.reduce(0) { $0 + $1.invocationCount }
        return HStack(spacing: 0) {
            CodexDashboardMetric(
                value: formatInteger(totalCalls),
                title: L10n.StatsDashboard.workersTotalCalls
            )
            metricDivider
            CodexDashboardMetric(
                value: formatInteger(subagentUsageRows.count),
                title: L10n.StatsDashboard.workersProfilesUsed
            )
            metricDivider
            CodexDashboardMetric(
                value: formatInteger(dashboardModel.subagentSessionCount),
                title: L10n.StatsDashboard.workersChats
            )
        }
        .frame(height: AgentStatsDashboardLayout.metricStripHeight)
        .clipShape(RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius)
                .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
        )
    }

    /// The three skill-workers.v1 Phase 0 KPIs. Each shows a dash until it
    /// has a denominator: an honest "no data yet" beats a 0% that reads like
    /// a verdict.
    private var workerKPIBand: some View {
        let kpis = dashboardModel.skillWorkerKPIs
        return HStack(spacing: 0) {
            CodexDashboardMetric(
                value: formatOptionalPercent(kpis.skillCoverage),
                title: L10n.StatsDashboard.workersSkillCoverage
            )
            metricDivider
            CodexDashboardMetric(
                value: formatOptionalPercent(kpis.verifiedSuccessRate),
                title: L10n.StatsDashboard.workersVerifiedSuccess
            )
            metricDivider
            CodexDashboardMetric(
                value: formatOptionalPercent(kpis.escalationRate),
                title: L10n.StatsDashboard.workersEscalationRate
            )
        }
        .frame(height: AgentStatsDashboardLayout.metricStripHeight)
        .clipShape(RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius)
                .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
        )
    }

    private var workerUsageList: some View {
        let rowsByProfile = Dictionary(
            uniqueKeysWithValues: subagentUsageRows.map { ($0.profileID, $0) }
        )
        let profiles = AgentSubagentProfileCatalog.builtIn.sorted { lhs, rhs in
            let lhsCount = rowsByProfile[lhs.id]?.invocationCount ?? 0
            let rhsCount = rowsByProfile[rhs.id]?.invocationCount ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.id < rhs.id
        }
        let totalCalls = subagentUsageRows.reduce(0) { $0 + $1.invocationCount }
        let peakCalls = max(1, subagentUsageRows.map(\.invocationCount).max() ?? 0)

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.StatsDashboard.workersTitle)
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.sectionTitle,
                    weight: .semibold
                ))
            Text(L10n.StatsDashboard.workersSubtitle)
                .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    workerUsageRow(
                        profile: profile,
                        usage: rowsByProfile[profile.id],
                        totalCalls: totalCalls,
                        peakCalls: peakCalls
                    )
                    if index < profiles.count - 1 {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
            }
            .background(dashboardSummaryFill.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius)
                    .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
            )
        }
    }

    private func workerUsageRow(
        profile: AgentSubagentProfile,
        usage: AgentSubagentUsageRow?,
        totalCalls: Int,
        peakCalls: Int
    ) -> some View {
        let invocationCount = usage?.invocationCount ?? 0
        let sessionCount = usage?.sessionCount ?? 0
        let share = totalCalls > 0 ? Double(invocationCount) / Double(totalCalls) : 0

        return HStack(spacing: 12) {
            Image(systemName: workerSymbol(profile.id))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(dashboardAccent)
                .frame(width: 32, height: 32)
                .background(dashboardAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.localizedDisplayName)
                        .font(supportingFont(
                            visualMinimum: AgentStatsDashboardTypography.body,
                            weight: .semibold
                        ))
                    Text(profile.id)
                        .font(supportingFont(
                            visualMinimum: AgentStatsDashboardTypography.metricLabel,
                            design: .monospaced
                        ))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(L10n.StatsDashboard.workerUsageSummary(
                        formatInteger(invocationCount),
                        formatInteger(sessionCount),
                        formatPercentage(share)
                    ))
                        .font(supportingFont(
                            visualMinimum: AgentStatsDashboardTypography.metricLabel,
                            weight: .medium,
                            design: .monospaced
                        ))
                        .foregroundStyle(invocationCount > 0 ? Color.primary : Color.secondary)
                }

                ProgressView(value: Double(invocationCount), total: Double(peakCalls))
                    .progressViewStyle(.linear)
                    .tint(dashboardAccent)

                Text(profile.localizedPurpose)
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.metricLabel))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func workerSymbol(_ profileID: String) -> String {
        switch profileID {
        case AgentSubagentProfileCatalog.scoutID: return "scope"
        case AgentSubagentProfileCatalog.readerID: return "doc.text.magnifyingglass"
        case AgentSubagentProfileCatalog.editorID: return "pencil.line"
        default: return "brain.head.profile"
        }
    }

    private var modelUsageList: some View {
        let rows = modelUsageRows
        return Group {
            if rows.isEmpty {
                Text(L10n.ModelUsage.empty)
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.ModelUsage.title)
                            .font(supportingFont(
                                visualMinimum: AgentStatsDashboardTypography.sectionTitle,
                                weight: .semibold
                            ))
                        Spacer(minLength: 0)
                        Text(L10n.ModelUsage.summaryCount(
                            formatCompact(rows.count),
                            formatCompact(Set(rows.map(\.providerID)).count)
                        ))
                            .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            modelUsageHeader
                                .padding(.vertical, 8)
                            Divider()
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                modelUsageRow(row)
                                if index < rows.count - 1 {
                                    Divider()
                                        .padding(.horizontal, AgentModelUsageTableLayout.horizontalInset)
                                }
                            }
                        }
                        .background(dashboardSummaryFill.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius)
                                .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
                        )
                    }
                    .frame(maxHeight: 240)
                    modelUsageFootnote(rows)
                }
            }
        }
    }

    private var modelSummaryBand: some View {
        let rows = modelUsageRows
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(totalEstimatedCostLabel(rows))
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.modelSummaryValue,
                        weight: .semibold,
                        design: .monospaced
                    ))
                    .foregroundStyle(dashboardAccent)
                Text(L10n.ModelUsage.summaryEstimatedCost)
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)

            Divider()
                .frame(height: 44)

            ModelUsageSummaryFact(
                title: L10n.ModelUsage.summaryInputTokens,
                value: formatTokens(rows.reduce(0) { $0 + $1.promptTokens })
            )
            ModelUsageSummaryFact(
                title: L10n.ModelUsage.summaryOutputTokens,
                value: formatTokens(rows.reduce(0) { $0 + $1.completionTokens })
            )

            Spacer(minLength: 2)

            Divider()
                .frame(height: 44)

            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.ModelUsage.summaryHighestCache)
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                    .foregroundStyle(.secondary)
                Text(formatPercent(rows.map(\.cacheHitRate).max() ?? 0))
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.metricValue,
                        weight: .semibold,
                        design: .monospaced
                    ))
                    .foregroundStyle(dashboardAccent)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(dashboardSummaryFill)
        .clipShape(RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentStatsDashboardLayout.summaryCornerRadius)
                .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
        )
    }

    private var modelUsageHeader: some View {
        HStack(spacing: AgentModelUsageTableLayout.columnSpacing) {
            Text(L10n.ModelUsage.headerModel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.ModelUsage.headerTokens)
                .frame(width: AgentModelUsageTableLayout.tokensWidth, alignment: .trailing)
            Text(L10n.ModelUsage.headerCache)
                .frame(width: AgentModelUsageTableLayout.cacheWidth, alignment: .trailing)
            Text(L10n.ModelUsage.headerCost)
                .frame(width: AgentModelUsageTableLayout.costWidth, alignment: .trailing)
        }
        .font(supportingFont(
            visualMinimum: AgentStatsDashboardTypography.body,
            weight: .medium
        ))
        .foregroundStyle(.secondary)
        .padding(.horizontal, AgentModelUsageTableLayout.horizontalInset)
    }

    private func modelUsageRow(_ row: AgentModelUsageRow) -> some View {
        HStack(alignment: .top, spacing: AgentModelUsageTableLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.providerName)
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.compactBadge))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(row.modelID)
                    .font(supportingFont(
                        visualMinimum: AgentStatsDashboardTypography.body,
                        weight: .semibold
                    ))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.modelID)
                Text(modelUsageSubtitle(row))
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(formatTokens(row.promptTokens)) / \(formatTokens(row.completionTokens))")
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.body,
                    weight: .medium,
                    design: .monospaced
                ))
                .foregroundStyle(.primary)
                .frame(width: AgentModelUsageTableLayout.tokensWidth, alignment: .trailing)
                .help(L10n.ModelUsage.tokensHelp(formatTokens(row.promptTokens), formatTokens(row.completionTokens)))

            Text(formatPercent(row.cacheHitRate))
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.body,
                    weight: .medium,
                    design: .monospaced
                ))
                .foregroundStyle(row.cachedPromptTokens > 0 ? .primary : .secondary)
                .frame(width: AgentModelUsageTableLayout.cacheWidth, alignment: .trailing)

            Text(formatCost(row))
                .font(supportingFont(
                    visualMinimum: AgentStatsDashboardTypography.body,
                    weight: .semibold,
                    design: .monospaced
                ))
                .foregroundStyle(row.estimatedCostUSD == nil ? Color.secondary : dashboardAccent)
                .frame(width: AgentModelUsageTableLayout.costWidth, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, AgentModelUsageTableLayout.horizontalInset)
    }

    private func modelUsageSubtitle(_ row: AgentModelUsageRow) -> String {
        var parts = [
            L10n.ModelUsage.sessions(String(row.sessionCount)),
            L10n.ModelUsage.messages(String(row.messageCount))
        ]
        if row.reasoningTokens > 0 {
            parts.append(L10n.ModelUsage.reasoning(formatTokens(row.reasoningTokens)))
        }
        if row.cachedPromptTokens > 0 {
            parts.append(L10n.ModelUsage.cached(formatTokens(row.cachedPromptTokens)))
        }
        if row.isDelegatedExternal {
            parts.append(L10n.ModelUsage.sourceExternal)
        }
        if row.averageStablePrefixCharacters > 0 {
            parts.append(L10n.ModelUsage.prefix(formatTokens(row.averageStablePrefixCharacters)))
        }
        return parts.joined(separator: " · ")
    }

    private func modelUsageFootnote(_ rows: [AgentModelUsageRow]) -> some View {
        let hasUnknownPrice = rows.contains { $0.estimatedCostUSD == nil }
        let hasEstimatedUsage = rows.contains(where: \.hasEstimatedUsage)
        let hasDelegatedExternal = rows.contains(where: \.isDelegatedExternal)
        let text: String? = {
            if hasDelegatedExternal { return L10n.ModelUsage.footnoteExternalDelegated }
            if hasUnknownPrice && hasEstimatedUsage { return L10n.ModelUsage.footnoteUnknownAndEstimated }
            if hasUnknownPrice { return L10n.ModelUsage.footnoteUnknownPrice }
            if hasEstimatedUsage { return L10n.ModelUsage.footnoteEstimatedUsage }
            return nil
        }()
        return Group {
            if let text {
                Text(text)
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func heatmapWeekCount(for width: CGFloat, cellSize: CGFloat, spacing: CGFloat) -> Int {
        let minimumWeekCount = 16
        let availableWidth = max(0, width)
        let stride = cellSize + spacing
        guard stride > 0 else { return minimumWeekCount }

        let fittingColumns = Int((availableWidth + spacing) / stride)
        return min(
            AgentStatsDashboardLayout.maximumHeatmapWeeks,
            max(minimumWeekCount, fittingColumns)
        )
    }

    private func color(for count: Int, peak: Int) -> Color {
        guard count > 0, peak > 0 else { return dashboardHeatmapInactive }
        let intensity = min(1.0, Double(count) / Double(peak))
        return dashboardAccent.opacity(0.28 + 0.68 * intensity)
    }

    /// Shared, lazily built formatter — DateFormatter construction costs
    /// milliseconds, and the heatmap calls this for every one of ~371
    /// cells on every body pass. Rebuilt only if the locale changes.
    private static var cachedCellDateFormatter: DateFormatter?

    private func cellDateLabel(_ date: Date) -> String {
        if let formatter = Self.cachedCellDateFormatter,
           formatter.locale == Locale.current {
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        Self.cachedCellDateFormatter = formatter
        return formatter.string(from: date)
    }

    private var funFact: some View {
        let stats = overview
        let ratio = AgentUsageStats.warAndPeaceEquivalents(tokenTotal: stats.totalTokens)
        return Group {
            if ratio > 0.05 {
                Text(funFactString(ratio: ratio))
                    .font(supportingFont(visualMinimum: AgentStatsDashboardTypography.body))
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(height: 0)
            }
        }
    }

    private func funFactString(ratio: Double) -> String {
        if ratio >= 1 {
            return L10n.ModelUsage.warAndPeaceMoreTokens(String(format: "%.1f", ratio))
        }
        let pct = Int(ratio * 100)
        return L10n.ModelUsage.warAndPeacePercent("\(pct)")
    }

    private func formatCompact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatTokenCount(_ count: Int) -> String {
        let isSimplifiedChinese = Locale.preferredLanguages.first?
            .lowercased()
            .hasPrefix("zh-hans") == true
        if isSimplifiedChinese {
            if count >= 100_000_000 {
                return compactDecimal(Double(count) / 100_000_000) + "亿"
            }
            if count >= 10_000 {
                return compactDecimal(Double(count) / 10_000) + "万"
            }
            return formatInteger(count)
        }
        if count >= 1_000_000_000 {
            return compactDecimal(Double(count) / 1_000_000_000) + "B"
        }
        if count >= 1_000_000 {
            return compactDecimal(Double(count) / 1_000_000) + "M"
        }
        if count >= 1_000 {
            return compactDecimal(Double(count) / 1_000) + "K"
        }
        return formatInteger(count)
    }

    private func compactDecimal(_ value: Double) -> String {
        if value >= 100 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formatInteger(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func formatPercentage(_ value: Double) -> String {
        String(format: "%.0f%%", min(1, max(0, value)) * 100)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }

    private func formatPercent(_ value: Double) -> String {
        guard value > 0 else { return "0%" }
        return String(format: "%.0f%%", min(1, value) * 100)
    }

    /// nil means the metric has no denominator yet, which must render as
    /// "no data" rather than as 0%.
    private func formatOptionalPercent(_ value: Double?) -> String {
        guard let value else { return L10n.StatsDashboard.workersMetricNoData }
        return formatPercentage(value)
    }

    private func formatCost(_ row: AgentModelUsageRow) -> String {
        guard let cost = row.estimatedCostUSD else { return L10n.ModelUsage.costUnknown }
        return formatCostValue(cost, estimated: row.hasEstimatedUsage)
    }

    private func totalEstimatedCostLabel(_ rows: [AgentModelUsageRow]) -> String {
        let pricedRows = rows.compactMap { row -> (Double, Bool)? in
            guard let cost = row.estimatedCostUSD else { return nil }
            return (cost, row.hasEstimatedUsage)
        }
        guard !pricedRows.isEmpty else { return L10n.ModelUsage.costUnknown }
        return formatCostValue(
            pricedRows.reduce(0) { $0 + $1.0 },
            estimated: pricedRows.contains { $0.1 }
        )
    }

    private func formatCostValue(_ cost: Double, estimated: Bool) -> String {
        let prefix = estimated ? "≈" : ""
        if cost < 0.01 {
            return "\(prefix)$\(String(format: "%.4f", cost))"
        }
        return "\(prefix)$\(String(format: "%.2f", cost))"
    }

    private func peakHourLabel(_ hour: Int?) -> String {
        guard let hour else { return "—" }
        let suffix = hour < 12 ? "AM" : "PM"
        let display = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(display) \(suffix)"
    }

    // Codex 视觉皮肤：强调色从原 teal 绿改为 Codex 的蓝
    // (#3B6FE0 一族)。数据结构与布局不变,只对齐配色/高亮。
    private var dashboardAccent: Color {
        colorScheme == .dark
            ? Color(red: 0.44, green: 0.62, blue: 0.96)
            : Color(red: 0.23, green: 0.44, blue: 0.88)
    }

    private var dashboardAvatarFill: Color {
        colorScheme == .dark
            ? Color(red: 0.57, green: 0.43, blue: 0.24)
            : Color(red: 0.74, green: 0.58, blue: 0.33)
    }

    private var dashboardSelectionFill: Color {
        colorScheme == .dark
            ? dashboardAccent.opacity(0.16)
            : Color(red: 0.92, green: 0.95, blue: 0.99)
    }

    private var dashboardSummaryFill: Color {
        colorScheme == .dark
            ? appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.30)
            : Color(red: 0.985, green: 0.986, blue: 0.992)
    }

    private var dashboardHeatmapInactive: Color {
        colorScheme == .dark
            ? Color.secondary.opacity(0.16)
            : Color.secondary.opacity(0.08)
    }

    private func supportingFont(
        visualMinimum: CGFloat = 0,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        AgentDesign.chatSupportingFont(
            baseFontSize: appState.agentChatBaseFontSize,
            visualMinimum: visualMinimum,
            weight: weight,
            design: design
        )
    }

    private func initials(for value: String) -> String {
        let words = value
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .filter { !$0.isEmpty }
        if words.count >= 2 {
            return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        return String(value.prefix(2)).uppercased()
    }

    private func validatedAvatarURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

struct StatCell: View {
    @EnvironmentObject var appState: AppState

    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 10
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(value)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 16,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CodexDashboardMetric: View {
    @EnvironmentObject var appState: AppState
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.metricValue,
                    weight: .regular
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.metricLabel
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct CodexDashboardPluginRow: View {
    @EnvironmentObject var appState: AppState
    let capability: AgentUsageCapability
    let callCount: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.14))
                .overlay {
                    Image(systemName: capability.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 22, height: 22)
            Text(pluginName)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.body
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(L10n.StatsDashboard.pluginRunCount(formatInteger(callCount)))
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.body
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var pluginName: String {
        switch capability {
        case .workspace: return "@workspace"
        case .coding: return "@coding"
        case .terminal: return "@terminal"
        case .research: return "@research"
        case .browser: return "@browser"
        case .media: return "$imagegen"
        case .automation: return "@automation"
        case .integration: return "@integrations"
        case .general: return "@tools"
        }
    }

    private func formatInteger(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

private struct DashboardSummaryFact: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.metricValue,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.body
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ModelUsageSummaryFact: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.metricValue,
                    weight: .semibold,
                    design: .monospaced
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.body
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DashboardInsightRow: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let value: String
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.body
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: AgentStatsDashboardTypography.body,
                    weight: .medium
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Plan status pill

struct PlanStatusPill: View {
    let status: AgentPlan.Status
    /// User pressed Stop mid-execution: the pill must stop claiming
    /// "Executing" for a plan that is actually paused.
    var isInterrupted: Bool = false

    var body: some View {
        Text(labelText)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(pillTextColor)
            .background(Capsule(style: .continuous).fill(pillColor))
    }

    private var labelText: String {
        if isInterrupted { return L10n.PlanStatus.interrupted }
        switch status {
        case .proposed: return L10n.PlanStatus.proposed
        case .approved: return L10n.PlanStatus.approved
        case .executing: return L10n.PlanStatus.executing
        case .done: return L10n.PlanStatus.done
        case .rejected: return L10n.PlanStatus.rejected
        }
    }

    /// "Done" is the expected end of a plan, not news — it gets a quiet gray
    /// chip that recedes once you have read it. The states that still want
    /// something from you (awaiting approval, rejected) keep their hue, and
    /// executing keeps its own so a running plan stays findable at a glance.
    static func fillColor(status: AgentPlan.Status, isInterrupted: Bool) -> Color {
        if isInterrupted { return quietFill }
        switch status {
        case .proposed: return .orange
        case .approved, .executing: return .green
        case .done: return quietFill
        case .rejected: return .red
        }
    }

    static func textColor(status: AgentPlan.Status, isInterrupted: Bool) -> Color {
        if isInterrupted { return .secondary }
        switch status {
        case .done: return .secondary
        case .proposed, .approved, .executing, .rejected: return Color.white
        }
    }

    private static let quietFill = Color.primary.opacity(0.08)

    private var pillColor: Color {
        Self.fillColor(status: status, isInterrupted: isInterrupted)
    }

    /// White reads as a label only on a saturated chip; on the quiet gray
    /// fill it would wash out, so those states take secondary ink instead.
    private var pillTextColor: Color {
        Self.textColor(status: status, isInterrupted: isInterrupted)
    }
}

// MARK: - Running tasks row

/// Claude Code 式「✳ 1 running task」状态行：长任务（前台工具阻塞、
/// 后台编译作业）运行期间，transcript 底部用脉动星号 + 计数文案告诉
/// 用户"输出停了是因为在等任务，不是卡死了"。
///
/// 与普通文字计时的分工：本行表示"有具体任务在跑"，且**turn 结束后
/// 只要后台作业还活着就继续显示**——这是参照 Claude 界面的关键：
/// 它的 "1 running task" 在回复完成后依然挂着，直到任务退出。
///
/// 两者同一时刻只显示一个（任务行优先），由挂载方的条件分支保证，
/// 避免底部出现两枚动画互相打架。`onTap` 由 AgentPanelView 注入，
/// 点击展开右侧 jobs 抽屉；主聊天页暂无抽屉则保持纯展示。
///
/// 这一行**禁止挂 `.help()` tooltip**：SwiftUI 动态 tooltip 在悬停时
/// 经 `NSHostingView.responderNode` 强制同步求值视图图，而本行永久
/// `repeatForever` 脉动 + 流式期间高频重绘，两者撞车会触发 macOS 26.5
/// Observation 框架的崩溃（SIGBUS in `_AccessList.addAccess`，
/// 见 1.58.0-rc3 changelog）。任务明细改由 accessibility hint 承载，
/// 鼠标用户通过点击展开 jobs 抽屉查看。
struct AgentRunningTasksRow: View {
    let count: Int
    var isAgentTurnActive: Bool = true
    var labelOverride: String? = nil
    var detail: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityHint(detail ?? L10n.Transcript.runningTasksHelp)
    }

    private var rowContent: some View {
        HStack(spacing: 7) {
            // 脉动必须走 symbolEffect（渲染服务器驱动），禁用
            // withAnimation(.repeatForever)，避免主线程持续产生 SwiftUI 事务。
            runningIcon
                .frame(width: 14, height: 14)
            Text(label)
                .agentChatSupportingFont()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var runningIcon: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.breathe)
        } else {
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var label: String {
        if let labelOverride, !labelOverride.isEmpty {
            return labelOverride
        }
        if isAgentTurnActive {
            return count == 1
                ? L10n.Transcript.runningTaskOne
                : L10n.Transcript.runningTasksMany(String(count))
        }
        return count == 1
            ? L10n.Transcript.backgroundTaskOne
            : L10n.Transcript.backgroundTasksMany(String(count))
    }
}
