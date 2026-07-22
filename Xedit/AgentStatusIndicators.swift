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

struct AgentStatsDashboard: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: DashboardTab
    @State private var range: DashboardRange = .all

    init(initialTab: DashboardTab = .overview) {
        _selectedTab = State(initialValue: initialTab)
    }

    enum DashboardTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case models = "Models"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return L10n.StatsDashboard.tabsOverview
            case .models: return L10n.StatsDashboard.tabsModels
            }
        }
    }

    enum DashboardRange: String, CaseIterable, Identifiable {
        case all = "All"
        case days30 = "30d"
        case days7 = "7d"
        case hours24 = "24h"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L10n.StatsDashboard.rangeAll
            case .days30: return L10n.StatsDashboard.range30d
            case .days7: return L10n.StatsDashboard.range7d
            case .hours24: return L10n.StatsDashboard.range24h
            }
        }
        var days: Int? {
            switch self {
            case .all: return nil
            case .days30: return 30
            case .days7: return 7
            case .hours24: return 1
            }
        }
    }

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        Group {
            if appState.hasLoadedAgentUsageSnapshots {
                dashboardContent
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(palette.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.hairline, lineWidth: 1)
        )
        .task {
            await appState.loadAgentUsageSnapshotsIfNeeded()
        }
    }

    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            if selectedTab == .overview {
                metricStrip
                activitySection
                detailSections
                funFact
            } else {
                modelUsageList
            }
        }
    }

    private var tabBar: some View {
        HStack {
            // Left-side Overview / Models selector.
            HStack(spacing: 2) {
                ForEach(DashboardTab.allCases) { tab in
                    Button { selectedTab = tab } label: {
                        Text(tab.title)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize,
                                visualMinimum: 12,
                                weight: selectedTab == tab ? .semibold : .regular
                            ))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selectedTab == tab
                                    ? AnyShapeStyle(appState.editorSettings.interfaceSkin.palette.controlFill)
                                    : AnyShapeStyle(Color.clear)
                            )
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            // Right-side All / 30d / 7d range selector.
            HStack(spacing: 2) {
                ForEach(DashboardRange.allCases) { value in
                    Button { range = value } label: {
                        Text(value.title)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize,
                                visualMinimum: 11,
                                weight: range == value ? .semibold : .regular
                            ))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(range == value ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var overview: AgentUsageOverview {
        AgentUsageStats.overview(
            for: filteredUsageSnapshots,
            allTimeStreakSessions: appState.agentUsageSnapshots
        )
    }

    private var modelUsageRows: [AgentModelUsageRow] {
        AgentUsageStats.modelUsage(for: filteredUsageSnapshots)
    }

    private var capabilityRows: [AgentCapabilityUsageRow] {
        AgentUsageStats.capabilityUsage(for: filteredUsageSnapshots)
    }

    private var filteredUsageSnapshots: [AgentUsageSessionSnapshot] {
        guard let days = range.days else { return appState.agentUsageSnapshots }
        let calendar = Calendar.current
        guard let threshold = calendar.date(byAdding: .day, value: -days, to: Date()) else {
            return appState.agentUsageSnapshots
        }
        return appState.agentUsageSnapshots.map { session in
            var copy = session
            copy.messages = session.messages.filter { $0.createdAt >= threshold }
            return copy
        }.filter { !$0.messages.isEmpty }
    }

    private var metricStrip: some View {
        let stats = overview
        return HStack(spacing: 0) {
            DashboardMetric(
                title: L10n.StatsDashboard.metricTaskTurns,
                value: formatCompact(stats.userTurnCount)
            )
            DashboardMetric(
                title: L10n.StatsDashboard.metricToolCalls,
                value: formatCompact(stats.toolCallCount)
            )
            DashboardMetric(
                title: L10n.StatsDashboard.metricFilesChanged,
                value: formatCompact(stats.editedFileCount)
            )
            DashboardMetric(
                title: L10n.StatsDashboard.metricArtifacts,
                value: formatCompact(stats.artifactCount)
            )
            DashboardMetric(
                title: L10n.StatsDashboard.metricCurrentStreak,
                value: L10n.StatsDashboard.dayCount("\(stats.currentStreak)")
            )
        }
        .padding(.vertical, 4)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var activitySection: some View {
        let stats = overview
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.StatsDashboard.activityTitle)
                    .font(supportingFont(visualMinimum: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(L10n.StatsDashboard.activitySummary(
                    formatCompact(overview.messageCount),
                    stats.hasAnyRealUsage ? formatTokens(overview.totalTokens) : "≈\(formatTokens(overview.totalTokens))"
                ))
                    .font(supportingFont(visualMinimum: 10))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let cellSize: CGFloat = 10
                let cellSpacing: CGFloat = 3
                let weekCount = heatmapWeekCount(
                    for: proxy.size.width,
                    cellSize: cellSize,
                    spacing: cellSpacing
                )
                let cells = AgentUsageStats.heatmap(for: filteredUsageSnapshots, weekCount: weekCount)
                let maxCount = cells.flatMap { $0 }.map(\.count).max() ?? 0

                HStack(spacing: cellSpacing) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: cellSpacing) {
                            ForEach(column) { cell in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(for: cell.count, peak: maxCount))
                                    .frame(width: cellSize, height: cellSize)
                                    .help(L10n.HeatmapCell.tooltip(cellDateLabel(cell.date), String(cell.count)))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: heatmapHeight)
        }
    }

    private var heatmapHeight: CGFloat {
        let cellSize: CGFloat = 10
        let cellSpacing: CGFloat = 3
        return 7 * cellSize + 6 * cellSpacing
    }

    private var detailSections: some View {
        HStack(alignment: .top, spacing: 24) {
            insightSection
                .frame(maxWidth: .infinity, alignment: .leading)
            capabilitySection
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var insightSection: some View {
        let stats = overview
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.StatsDashboard.insightsTitle)
                .font(supportingFont(visualMinimum: 12, weight: .semibold))
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightSessions,
                value: formatCompact(stats.sessionCount)
            )
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightWorkspaces,
                value: formatCompact(stats.workspaceCount)
            )
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightActiveDays,
                value: L10n.StatsDashboard.dayCount("\(stats.activeDays)")
            )
            DashboardInsightRow(
                title: L10n.StatsDashboard.insightPeakHour,
                value: peakHourLabel(stats.peakHour)
            )
            if stats.workflowCount > 0 {
                DashboardInsightRow(
                    title: L10n.StatsDashboard.insightWorkflows,
                    value: formatCompact(stats.workflowCount)
                )
            }
        }
    }

    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.StatsDashboard.capabilitiesTitle)
                .font(supportingFont(visualMinimum: 12, weight: .semibold))
            if capabilityRows.isEmpty {
                Text(L10n.StatsDashboard.capabilitiesEmpty)
                    .font(supportingFont(visualMinimum: 11))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 68, alignment: .leading)
            } else {
                ForEach(capabilityRows.prefix(5)) { row in
                    HStack(spacing: 7) {
                        Image(systemName: row.capability.systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
                            .frame(width: 16)
                        Text(row.capability.title)
                            .font(supportingFont(visualMinimum: 11))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(L10n.StatsDashboard.callCount(formatCompact(row.callCount)))
                            .font(supportingFont(visualMinimum: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var modelUsageList: some View {
        let rows = modelUsageRows
        return Group {
            if rows.isEmpty {
                Text(L10n.ModelUsage.empty)
                    .font(supportingFont())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    modelUsageHeader
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rows) { row in
                                modelUsageRow(row)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxHeight: 190)
                    modelUsageFootnote(rows)
                }
            }
        }
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
        .font(supportingFont(visualMinimum: 10, weight: .medium))
        .foregroundStyle(.secondary)
        // Rows use the same inset for their tinted card background. Keeping
        // the header on that exact inner track aligns every column edge.
        .padding(.horizontal, AgentModelUsageTableLayout.horizontalInset)
    }

    private func modelUsageRow(_ row: AgentModelUsageRow) -> some View {
        HStack(alignment: .top, spacing: AgentModelUsageTableLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.providerName)
                        .font(supportingFont(visualMinimum: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(row.modelID)
                        .font(supportingFont(visualMinimum: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.modelID)
                }
                Text(modelUsageSubtitle(row))
                    .font(supportingFont(visualMinimum: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(formatTokens(row.promptTokens)) / \(formatTokens(row.completionTokens))")
                .font(supportingFont(visualMinimum: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: AgentModelUsageTableLayout.tokensWidth, alignment: .trailing)
                .help(L10n.ModelUsage.tokensHelp(formatTokens(row.promptTokens), formatTokens(row.completionTokens)))

            Text(formatPercent(row.cacheHitRate))
                .font(supportingFont(visualMinimum: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(row.cachedPromptTokens > 0 ? .primary : .secondary)
                .frame(width: AgentModelUsageTableLayout.cacheWidth, alignment: .trailing)

            Text(formatCost(row))
                .font(supportingFont(visualMinimum: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.estimatedCostUSD == nil ? .secondary : .primary)
                .frame(width: AgentModelUsageTableLayout.costWidth, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, AgentModelUsageTableLayout.horizontalInset)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    .font(supportingFont())
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
        return max(minimumWeekCount, fittingColumns)
    }

    private func color(for count: Int, peak: Int) -> Color {
        guard count > 0, peak > 0 else { return Color.secondary.opacity(0.12) }
        let intensity = min(1.0, Double(count) / Double(peak))
        return Color.accentColor.opacity(0.25 + 0.6 * intensity)
    }

    private func cellDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var funFact: some View {
        let stats = overview
        let ratio = AgentUsageStats.warAndPeaceEquivalents(tokenTotal: stats.totalTokens)
        return Group {
            if ratio > 0.05 {
                Text(funFactString(ratio: ratio))
                    .font(supportingFont())
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

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }

    private func formatPercent(_ value: Double) -> String {
        guard value > 0 else { return "0%" }
        return String(format: "%.0f%%", min(1, value) * 100)
    }

    private func formatCost(_ row: AgentModelUsageRow) -> String {
        guard let cost = row.estimatedCostUSD else { return L10n.ModelUsage.costUnknown }
        let prefix = row.hasEstimatedUsage ? "≈" : ""
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

private struct DashboardMetric: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 15,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 9
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 5)
        .overlay(alignment: .trailing) {
            Divider()
                .padding(.vertical, 5)
        }
    }
}

private struct DashboardInsightRow: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 11
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 11,
                    weight: .medium
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Plan status pill

struct PlanStatusPill: View {
    let status: AgentPlan.Status

    var body: some View {
        Text(labelText)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.white)
            .background(Capsule(style: .continuous).fill(pillColor))
    }

    private var labelText: String {
        switch status {
        case .proposed: return L10n.PlanStatus.proposed
        case .approved: return L10n.PlanStatus.approved
        case .executing: return L10n.PlanStatus.executing
        case .done: return L10n.PlanStatus.done
        case .rejected: return L10n.PlanStatus.rejected
        }
    }

    private var pillColor: Color {
        switch status {
        case .proposed: return .orange
        case .approved, .executing: return .green
        case .done: return .blue
        case .rejected: return .red
        }
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
