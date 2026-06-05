//
//  AgentStatusIndicators.swift
//  VeilWriter
//
//  Small status / dashboard surfaces shared across the chat pane, split
//  out of AgentModeView.swift in rc42:
//
//   - `AgentStatsDashboard`: the activity panel shown inside the empty
//     state for installs with at least one session. Two tabs (Overview /
//     Models) × three ranges (All / 30d / 7d), an 8-cell stat grid,
//     a heatmap that auto-sizes its column count to the available
//     width, and a tongue-in-cheek "War and Peace equivalents" fun
//     fact when the token total crosses 5%.
//   - `StatCell`: the small label-on-top-of-value tile used by the
//     dashboard grid.
//   - `PlanStatusPill`: tiny capsule that labels the current AgentPlan
//     status — proposed (orange) / approved+executing (green) / done
//     (blue) / rejected (red). Used by `AgentPlanCard`.
//
//  Previously `private struct` inside AgentModeView.swift; now internal
//  so the chat empty state and plan card can mount them across files.
//

import SwiftUI

// MARK: - Stats dashboard

struct AgentStatsDashboard: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: DashboardTab = .overview
    @State private var range: DashboardRange = .all

    enum DashboardTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case models = "Models"
        var id: String { rawValue }
    }

    enum DashboardRange: String, CaseIterable, Identifiable {
        case all = "All"
        case days30 = "30d"
        case days7 = "7d"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .all: return nil
            case .days30: return 30
            case .days7: return 7
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            statsGrid
            heatmap
            funFact
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AgentDesign.cardBackground.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var tabBar: some View {
        HStack {
            // Left-side Overview / Models selector.
            HStack(spacing: 2) {
                ForEach(DashboardTab.allCases) { tab in
                    Button { selectedTab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selectedTab == tab
                                    ? AnyShapeStyle(AgentDesign.cardBackground)
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
                        Text(value.rawValue)
                            .font(.system(size: 11, weight: range == value ? .semibold : .regular))
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
        AgentUsageStats.overview(for: filteredSessions)
    }

    private var filteredSessions: [AgentSession] {
        guard let days = range.days else { return appState.agentSessions }
        let calendar = Calendar.current
        guard let threshold = calendar.date(byAdding: .day, value: -days, to: Date()) else {
            return appState.agentSessions
        }
        return appState.agentSessions.map { session in
            var copy = session
            copy.messages = session.messages.filter { $0.createdAt >= threshold }
            return copy
        }.filter { !$0.messages.isEmpty }
    }

    private var statsGrid: some View {
        let stats = overview
        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            StatCell(title: L10n.StatCell.sessions, value: "\(stats.sessionCount)")
            StatCell(title: L10n.StatCell.messages, value: formatCompact(stats.messageCount))
            StatCell(
                title: stats.hasAnyRealUsage ? L10n.StatCell.tokens : L10n.StatCell.tokensEstimated,
                value: formatTokens(stats.totalTokens)
            )
            StatCell(title: L10n.StatCell.activeDays, value: "\(stats.activeDays)")
            StatCell(title: L10n.StatCell.currentStreak, value: "\(stats.currentStreak)d")
            StatCell(title: L10n.StatCell.longestStreak, value: "\(stats.longestStreak)d")
            StatCell(title: L10n.StatCell.peakHour, value: peakHourLabel(stats.peakHour))
            StatCell(title: L10n.StatCell.favoriteModel, value: stats.favoriteModel ?? "—")
        }
    }

    private var heatmap: some View {
        GeometryReader { proxy in
            let cellSize: CGFloat = 11
            let cellSpacing: CGFloat = 3
            let weekCount = heatmapWeekCount(
                for: proxy.size.width,
                cellSize: cellSize,
                spacing: cellSpacing
            )
            let cells = AgentUsageStats.heatmap(for: filteredSessions, weekCount: weekCount)
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

    private var heatmapHeight: CGFloat {
        let cellSize: CGFloat = 11
        let cellSpacing: CGFloat = 3
        return 7 * cellSize + 6 * cellSpacing
    }

    private func heatmapWeekCount(for width: CGFloat, cellSize: CGFloat, spacing: CGFloat) -> Int {
        let minimumWeekCount = 12
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(height: 0)
            }
        }
    }

    private func funFactString(ratio: Double) -> String {
        if ratio >= 1 {
            return String(format: "You've used ~%.1f× more tokens than War and Peace.", ratio)
        }
        let pct = Int(ratio * 100)
        return "You've used about \(pct)% of War and Peace in tokens so far."
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

    private func peakHourLabel(_ hour: Int?) -> String {
        guard let hour else { return "—" }
        let suffix = hour < 12 ? "AM" : "PM"
        let display = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(display) \(suffix)"
    }
}

struct StatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AgentDesign.cardBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
