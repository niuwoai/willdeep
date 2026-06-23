//
//  AgentTaskMonitorRail.swift
//  WillDeep
//
//  QoderWork-style right rail for dense Agent task monitoring.
//

import SwiftUI
import AppKit

struct AgentTaskMonitorRail: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                monitorSection
                todoSection
                deliverablesSection
                workFilesSection
                learningSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(width: 320)
        .background(palette.panelFill)
    }

    private var monitorSection: some View {
        AgentRailSection(title: "任务监控", systemImage: "rectangle.and.text.magnifyingglass") {
            AgentSemanticActivityStatusLine(style: .rail)
            if appState.agentRunningTaskCount > 0, let detail = appState.agentRunningTaskSummary {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var todoSection: some View {
        let items = todoItems
        AgentRailSection(title: "待办", systemImage: "checklist") {
            if items.isEmpty {
                AgentRailEmptyRow(text: "暂无 Plan / Goal 待办")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items) { item in
                        AgentRailTodoRow(item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deliverablesSection: some View {
        let files = deliverableFiles
        AgentRailSection(title: "产物", systemImage: "doc.richtext") {
            if let root = appState.agentWorktreeChanges.repositoryRoot ?? appState.rootDirectory {
                AgentRailMetaRow(label: "默认工作目录", value: root.lastPathComponent)
            }
            if files.isEmpty {
                AgentRailEmptyRow(text: "尚未识别最终文件")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(files) { file in
                        AgentRailFileButton(
                            title: file.fileName,
                            subtitle: file.path,
                            systemImage: "doc.text",
                            tint: .accentColor
                        ) {
                            appState.openAgentChangedFile(file.path)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workFilesSection: some View {
        let groups = workFileGroups
        AgentRailSection(title: "工作文件", systemImage: "folder") {
            if appState.agentWorktreeChanges.isEmpty {
                AgentRailEmptyRow(text: "暂无已修改文件")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        AgentRailDirectoryRow(group: group)
                    }
                    if appState.agentWorktreeChanges.fileCount > groups.reduce(0, { $0 + $1.count }) {
                        Text("还有 \(appState.agentWorktreeChanges.fileCount - groups.reduce(0, { $0 + $1.count })) 个文件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var learningSection: some View {
        let summary = learningSummary
        AgentRailSection(title: "技能与 MCP / 意识更新", systemImage: "brain.head.profile") {
            if summary.total == 0 {
                AgentRailEmptyRow(text: "本次暂无新学习建议")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if summary.memory > 0 {
                        AgentRailLearningRow(label: "记忆", count: summary.memory, tint: .green)
                    }
                    if summary.skill > 0 {
                        AgentRailLearningRow(label: "技能", count: summary.skill, tint: .purple)
                    }
                    if summary.mcp > 0 {
                        AgentRailLearningRow(label: "MCP", count: summary.mcp, tint: .orange)
                    }
                }
            }
        }
    }

    private var todoItems: [AgentRailTodoItem] {
        if let plan = appState.agentCurrentPlan, !plan.steps.isEmpty {
            return plan.steps.enumerated().map { offset, step in
                AgentRailTodoItem(
                    id: step.id,
                    text: step.text,
                    status: todoStatus(for: step.status, offset: offset, planStatus: plan.status)
                )
            }
        }
        if let goal = appState.agentCurrentGoal, !goal.checklist.isEmpty {
            let firstOpenID = goal.checklist.first(where: { !$0.done })?.id
            return goal.checklist.map { item in
                AgentRailTodoItem(
                    id: item.id,
                    text: item.text,
                    status: item.done ? .done : (item.id == firstOpenID && appState.isAgentResponding ? .active : .pending)
                )
            }
        }
        return []
    }

    private func todoStatus(
        for stepStatus: AgentPlan.StepStatus,
        offset: Int,
        planStatus: AgentPlan.Status
    ) -> AgentRailTodoStatus {
        switch stepStatus {
        case .done, .skipped:
            return .done
        case .inProgress:
            return .active
        case .failed:
            return .failed
        case .pending:
            if offset == 0 && appState.isAgentResponding && planStatus == .approved {
                return .active
            }
            return .pending
        }
    }

    private var deliverableFiles: [AgentFileChangeSummary] {
        appState.agentWorktreeChanges.files
            .filter { change in
                guard change.kind != .deleted else { return false }
                let ext = URL(fileURLWithPath: change.path).pathExtension.lowercased()
                return ["md", "markdown", "html", "pdf", "csv", "json", "xlsx", "docx"].contains(ext)
            }
            .sorted { lhs, rhs in
                deliverableRank(lhs.path) < deliverableRank(rhs.path)
            }
            .prefix(4)
            .map { $0 }
    }

    private func deliverableRank(_ path: String) -> Int {
        let lower = path.lowercased()
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return 0 }
        if lower.contains("report") || lower.contains("analysis") { return 1 }
        return 2
    }

    private var workFileGroups: [AgentRailDirectoryGroup] {
        let deliverablePaths = Set(deliverableFiles.map(\.path))
        let groups = Dictionary(grouping: appState.agentWorktreeChanges.files.filter { !deliverablePaths.contains($0.path) }) { change in
            let parts = change.path.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : "根目录"
        }
        return groups
            .map { key, files in
                AgentRailDirectoryGroup(
                    id: key,
                    name: key,
                    count: files.count,
                    preview: files.prefix(2).map(\.fileName)
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(6)
            .map { $0 }
    }

    private var learningSummary: (memory: Int, skill: Int, mcp: Int, total: Int) {
        let events = appState.agentCurrentTurnLearningEvents.isEmpty
            ? appState.agentLearningEvents
            : appState.agentCurrentTurnLearningEvents
        let memory = events.filter { $0.kind == .memory }.count
        let skill = events.filter { $0.kind == .skill }.count
        let mcp = events.filter { $0.kind == .mcpSuggestion }.count
        return (memory, skill, mcp, memory + skill + mcp)
    }
}

struct AgentSemanticActivityStatusLine: View {
    enum Style {
        case rail
        case composer
    }

    @EnvironmentObject var appState: AppState
    var style: Style

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            HStack(spacing: 7) {
                Image(systemName: phase.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(phase.tint)
                Text(phase.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(phase.tint)
                    .lineLimit(1)
                if let startedAt = appState.agentTurnStartedAt, appState.isAgentResponding {
                    Spacer(minLength: 4)
                    Text(Self.formatElapsed(context.date.timeIntervalSince(startedAt)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(phase.tint.opacity(0.82))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, style == .composer ? 12 : 0)
            .frame(height: style == .composer ? 26 : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if style == .composer {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(phase.tint.opacity(0.10))
                }
            }
            .overlay {
                if style == .composer {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(phase.tint.opacity(0.16), lineWidth: 1)
                }
            }
        }
    }

    private var phase: AgentActivityPhase {
        if appState.isCompressingAgentContext {
            return AgentActivityPhase(label: "压缩上下文中", systemImage: "arrow.down.forward.and.arrow.up.backward", tint: .purple)
        }
        if let waiting = appState.agentToolCalls.last(where: { call in
            call.status == .pendingApproval || call.status == .awaitingConfirm || call.status == .awaitingUserAnswer
        }) {
            return AgentActivityPhase(label: waitingLabel(for: waiting), systemImage: "hand.raised", tint: .orange)
        }
        if let running = appState.agentToolCalls.last(where: { $0.status == .running }) {
            return phase(for: running.toolName)
        }
        if appState.agentRunningTaskCount > 0 {
            return AgentActivityPhase(label: "任务运行中", systemImage: "play.circle", tint: .green)
        }
        if appState.isAgentResponding {
            return AgentActivityPhase(label: appState.agentLiveThinkingPreview == nil ? "思考中" : "反思中", systemImage: "sparkles", tint: .green)
        }
        return AgentActivityPhase(label: "空闲", systemImage: "checkmark.circle", tint: .secondary)
    }

    private func phase(for toolName: String) -> AgentActivityPhase {
        switch AgentToolKind.of(AgentToolCall(
            messageID: UUID(),
            externalID: "",
            toolName: toolName,
            arguments: [:],
            risk: .read,
            status: .running
        )) {
        case .fileExploration:
            return AgentActivityPhase(label: "搜索中", systemImage: "doc.text.magnifyingglass", tint: .blue)
        case .runCommand:
            return AgentActivityPhase(label: "验证中", systemImage: "terminal", tint: .orange)
        case .applyPatch:
            return AgentActivityPhase(label: "编辑中", systemImage: "pencil.line", tint: .green)
        case .subagent, .claudeCode, .codexCLI, .cursorAgent:
            return AgentActivityPhase(label: "委派中", systemImage: "person.2", tint: .purple)
        case .askUser:
            return AgentActivityPhase(label: "等待你回答", systemImage: "bubble.left.and.text.bubble.right", tint: .orange)
        case .other:
            return AgentActivityPhase(label: "处理中", systemImage: "gearshape", tint: .blue)
        }
    }

    private func waitingLabel(for call: AgentToolCall) -> String {
        switch call.status {
        case .pendingApproval:
            return "等待审批"
        case .awaitingConfirm:
            return "等待确认"
        case .awaitingUserAnswer:
            return "等待回答"
        case .running, .succeeded, .failed, .denied:
            return "处理中"
        }
    }

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remaining = total % 60
        if minutes < 60 { return "\(minutes)m \(remaining)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct AgentActivityPhase {
    var label: String
    var systemImage: String
    var tint: Color
}

private struct AgentRailTodoItem: Identifiable {
    var id: UUID
    var text: String
    var status: AgentRailTodoStatus
}

private enum AgentRailTodoStatus {
    case done
    case active
    case pending
    case failed
}

private struct AgentRailDirectoryGroup: Identifiable {
    var id: String
    var name: String
    var count: Int
    var preview: [String]
}

private struct AgentRailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(.bottom, 2)
    }
}

private struct AgentRailTodoRow: View {
    let item: AgentRailTodoItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
            Text(item.text)
                .font(.system(size: 12, weight: item.status == .active ? .semibold : .regular))
                .foregroundStyle(item.status == .done ? .secondary : .primary)
                .strikethrough(item.status == .done, color: .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var iconName: String {
        switch item.status {
        case .done: return "checkmark.circle.fill"
        case .active: return "arrow.right.circle.fill"
        case .pending: return "circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch item.status {
        case .done: return .green
        case .active: return .blue
        case .pending: return .secondary
        case .failed: return .red
        }
    }
}

private struct AgentRailFileButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(subtitle)
    }
}

private struct AgentRailDirectoryRow: View {
    let group: AgentRailDirectoryGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("(\(group.count))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if !group.preview.isEmpty {
                Text(group.preview.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct AgentRailLearningRow: View {
    let label: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text("\(count) 条")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

private struct AgentRailMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct AgentRailEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
