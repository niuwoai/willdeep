//
//  AgentTaskMonitorRail.swift
//  WillDeep
//
//  QoderWork-style right rail for dense Agent task monitoring.
//

import SwiftUI
import AppKit

// Snapshot digest contract moved to AgentTaskMonitorSnapshot.swift:
// mediaTaskDigest
// task.isActive || task.needsAttention || task.status == .succeeded

struct AgentTaskMonitorRail: View {
    @EnvironmentObject var appState: AppState
    var width: CGFloat = 320

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                monitorSection
                delegatedTasksSection
                todoSection
                deliverablesSection
                workFilesSection
                learningSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(width: width)
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
            if !runtimeJobs.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    // 最近任务最多展示 3 条，超出部分在内部纵向滚动，
                    // 避免任务列表把下方「待办/产物/工作文件」等模块撑出可视区域。
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(runtimeJobs.prefix(monitorJobDisplayLimit)) { job in
                                AgentRailJobRow(
                                    job: job,
                                    inspect: {
                                        appState.prefillAgentJobInspectionPrompt(for: job)
                                    },
                                    kill: {
                                        _ = appState.agentJobRegistry.kill(id: job.id)
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: monitorJobListMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    if runtimeJobs.count > monitorJobDisplayLimit {
                        Text(L10n.AgentTaskMonitor.moreBackgroundJobs(runtimeJobs.count - monitorJobDisplayLimit))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            if !visibleMediaTasks.isEmpty || !recentCompletedMediaTasks.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(mediaTaskSummaryText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button {
                            openFocusedMediaTaskPanel()
                        } label: {
                            Label("媒体任务", systemImage: "photo.on.rectangle.angled")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help("打开媒体任务侧栏")
                        Button {
                            appendFocusedMediaTaskScopeToChat()
                        } label: {
                            Image(systemName: "text.bubble")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help("发送媒体任务范围到聊天")
                    }
                    if !visibleMediaTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(visibleMediaTasks.prefix(monitorMediaTaskDisplayLimit)) { task in
                                AgentRailMediaTaskRow(task: task) {
                                    openMediaTaskPanel(for: task)
                                }
                            }
                        }
                        if visibleMediaTasks.count > monitorMediaTaskDisplayLimit {
                            Text("还有 \(visibleMediaTasks.count - monitorMediaTaskDisplayLimit) 个媒体任务")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !recentCompletedMediaTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("最近完成")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(recentCompletedMediaTasks.prefix(recentCompletedMediaTaskDisplayLimit)) { task in
                                AgentRailMediaTaskRow(task: task) {
                                    openMediaTaskPanel(for: task)
                                }
                            }
                        }
                        .padding(.top, visibleMediaTasks.isEmpty ? 0 : 2)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var delegatedTasksSection: some View {
        AgentRailSection(
            title: L10n.DelegatedTask.sectionTitle,
            systemImage: "person.2.badge.gearshape"
        ) {
            if delegatedTaskRuns.isEmpty {
                AgentRailEmptyRow(text: L10n.DelegatedTask.noTasks)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(delegatedTaskRuns.prefix(3)) { run in
                        AgentRailDelegatedTaskRow(run: run)
                    }
                }
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
        let artifacts = sessionArtifacts
        AgentRailSection(title: "产物", systemImage: "doc.richtext") {
            AgentRailMetaRow(label: "范围", value: "当前会话产生的文件与媒体")
            if artifacts.isEmpty {
                AgentRailEmptyRow(text: "本会话尚未产生文件或媒体产物")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(artifacts) { artifact in
                        AgentRailFileButton(
                            title: artifact.fileName,
                            subtitle: artifact.subtitle,
                            systemImage: artifact.systemImage,
                            tint: artifact.tint
                        ) {
                            AgentArtifactFileActions.openInFinder(artifact.url)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workFilesSection: some View {
        let groups = workFileGroups
        let files = sessionWorkFiles
        AgentRailSection(title: "工作文件", systemImage: "folder") {
            AgentRailMetaRow(label: "口径", value: "当前会话关联的未提交变更")
            if files.isEmpty {
                AgentRailEmptyRow(text: "暂无已修改文件")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        AgentRailDirectoryRow(group: group) {
                            AgentArtifactFileActions.openInFinder(group.finderURL)
                        }
                    }
                    if files.count > groups.reduce(0, { $0 + $1.count }) {
                        Text(L10n.AgentWorktreeSummary.moreFiles(files.count - groups.reduce(0, { $0 + $1.count })))
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

    private var runtimeJobs: [AgentBackgroundJob] {
        guard let runtimeID = appState.activeAgentSessionID else { return [] }
        return appState.agentJobRegistry.jobs(forRuntime: runtimeID)
    }

    private var delegatedTaskRuns: [AgentDelegatedTaskRun] {
        appState.activeRuntime?.delegatedTaskRuns ?? []
    }

    private var visibleMediaTasks: [AgentMediaTask] {
        appState.agentMediaTaskRegistry
            .tasks(forRuntime: appState.activeAgentSessionID)
            .filter { task in task.isActive || task.needsAttention }
    }

    private var recentCompletedMediaTasks: [AgentMediaTask] {
        appState.agentMediaTaskRegistry
            .tasks(forRuntime: appState.activeAgentSessionID)
            .filter { $0.status == .succeeded }
            .sorted {
                ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt)
            }
            .prefix(recentCompletedMediaTaskDisplayLimit)
            .map { $0 }
    }

    private var mediaTaskSummaryText: String {
        let active = visibleMediaTasks.filter(\.isActive).count
        let stale = visibleMediaTasks.filter { $0.isStaleActive() }.count
        let failed = visibleMediaTasks.filter(\.needsAttention).count
        let completed = recentCompletedMediaTasks.count
        if failed > 0 || stale > 0 {
            var parts: [String] = []
            if active > 0 { parts.append("\(active) 个进行中") }
            if stale > 0 { parts.append("\(stale) 个卡住") }
            if failed > 0 { parts.append("\(failed) 个需处理") }
            if completed > 0 { parts.append("\(completed) 个刚完成") }
            return "媒体生成：" + parts.joined(separator: "，")
        }
        if active > 0 && failed > 0 {
            if completed > 0 {
                return "媒体生成：\(active) 个进行中，\(failed) 个需处理，\(completed) 个刚完成"
            }
            return "媒体生成：\(active) 个进行中，\(failed) 个需处理"
        }
        if active > 0 {
            if completed > 0 {
                return "媒体生成：\(active) 个进行中，\(completed) 个刚完成"
            }
            return "媒体生成：\(active) 个进行中"
        }
        if failed > 0 {
            if completed > 0 {
                return "媒体生成：\(failed) 个需处理，\(completed) 个刚完成"
            }
            return "媒体生成：\(failed) 个需处理"
        }
        return "媒体生成：\(completed) 个刚完成"
    }

    private var focusedMediaTask: AgentMediaTask? {
        visibleMediaTasks.first(where: \.needsAttention)
            ?? visibleMediaTasks.first { $0.isStaleActive() }
            ?? visibleMediaTasks.first(where: \.isActive)
            ?? recentCompletedMediaTasks.first
    }

    private func openFocusedMediaTaskPanel() {
        guard let task = focusedMediaTask else {
            appState.agentMediaTaskPanelScope = nil
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            return
        }
        openMediaTaskPanel(for: task)
    }

    private func appendFocusedMediaTaskScopeToChat() {
        let scope = focusedMediaTask.flatMap(mediaTaskScope)
        let tasks = mediaTasks(matching: scope)
        let active = tasks.filter(\.isActive)
        let staleActive = active.filter { $0.isStaleActive() }
        let failed = tasks.filter(\.needsAttention)
        let finished = tasks.filter { !$0.isActive && !$0.needsAttention }
        let completedImageTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedImageArtifact)
        let completedVideoTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedVideoArtifact)
        let retryable = failed.filter(AgentMediaTaskChatHandoff.isRetryableShortDramaTask)
        var lines = [
            "请基于任务监控 rail 当前聚焦的媒体任务范围继续推进制作。",
            "",
            "<media-task-scope-status>",
            "action: inspect_media_task_scope_from_rail",
            "scope_label: \(scope?.label ?? "全部媒体任务")",
            "total_count: \(tasks.count)",
            "active_count: \(active.count)",
            "stale_active_count: \(staleActive.count)",
            "failed_count: \(failed.count)",
            "finished_count: \(finished.count)",
            "completed_image_task_count: \(completedImageTasks.count)",
            "completed_video_task_count: \(completedVideoTasks.count)",
            "open_tasks_tool: short_drama_open_media_tasks"
        ]
        if let scope {
            appendScopeLines(scope, to: &lines)
            let arguments = scopedArguments(scope)
            lines.append("open_tasks_arguments: \(arguments)")
            if !active.isEmpty {
                lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_tasks_arguments: \(arguments)")
            }
            if !retryable.isEmpty {
                lines.append("retry_failed_tool: short_drama_retry_failed_media_tasks")
                lines.append("retry_failed_dry_run_arguments: \(arguments), dry_run=true")
                lines.append("retry_failed_submit_arguments: \(arguments), dry_run=false")
            }
        } else {
            lines.append("open_tasks_arguments: scope=all")
        }
        if !active.isEmpty {
            lines.append("active_tasks:")
            lines.append(contentsOf: active.prefix(8).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
            lines.append("active_task_actions:")
            lines.append(contentsOf: active.prefix(8).compactMap(AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine))
            lines.append("active_task_follow_up: active_task_actions 已包含可直接调用的 provider 轮询/取消参数；也可先用 refresh_tasks_tool 刷新当前范围。")
        }
        if !staleActive.isEmpty {
            lines.append("stale_active_tasks:")
            lines.append(contentsOf: staleActive.prefix(8).compactMap(AgentMediaTaskChatHandoff.staleActiveTaskScopeSummaryLine))
            lines.append("stale_active_follow_up: stale_active_tasks 表示运行中但超过 30 分钟未更新；优先刷新同一范围，若仍无变化再询问用户是否取消、重试或等待外部回导。")
        }
        if !failed.isEmpty {
            lines.append("failed_tasks:")
            lines.append(contentsOf: failed.prefix(8).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
        }
        if !retryable.isEmpty {
            lines.append("retryable_failed_tasks:")
            lines.append(contentsOf: retryable.prefix(8).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
        }
        if !finished.isEmpty {
            lines.append("finished_tasks:")
            lines.append(contentsOf: finished.prefix(8).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
        }
        if !completedImageTasks.isEmpty {
            lines.append("completed_image_tasks:")
            lines.append(contentsOf: completedImageTasks.prefix(8).compactMap(AgentMediaTaskChatHandoff.completedImageScopeSummaryLine))
            lines.append("completed_image_follow_up: completed_image_tasks 已包含可直接调用的后续工具参数；对单个任务调用“发送任务上下文到聊天”还会展开完整 <media-task-completed-artifact-actions>。")
        }
        if !completedVideoTasks.isEmpty {
            lines.append("completed_video_tasks:")
            lines.append(contentsOf: completedVideoTasks.prefix(8).compactMap(AgentMediaTaskChatHandoff.completedVideoScopeSummaryLine))
            lines.append("completed_video_follow_up: completed_video_tasks 已包含可直接调用的审片、分镜板和任务范围参数；对单个任务调用“发送任务上下文到聊天”还会展开完整 <media-task-completed-video-actions>。")
        }
        lines.append("</media-task-scope-status>")
        appendPromptToChat(lines.joined(separator: "\n"), duplicateGuard: "<media-task-scope-status>")
    }

    private func openMediaTaskPanel(for task: AgentMediaTask) {
        let scope = mediaTaskScope(for: task)
        appState.agentMediaTaskPanelScope = scope
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
    }

    private func mediaTaskScope(for task: AgentMediaTask) -> AgentMediaTaskScope? {
        let projectID = clean(task.projectID) ?? clean(task.projectPath)
        let episodeID = clean(task.episodeID)
        let shotID = clean(task.shotID)
        let assetKind = clean(task.assetKind)
        let assetID = clean(task.assetID)
        let reviewItemID = clean(task.reviewItemID)
        if let reviewItemID {
            return AgentMediaTaskScope(
                label: "检查项任务：\(task.title)",
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID,
                reviewItemID: reviewItemID
            )
        }
        if let shotID {
            return AgentMediaTaskScope(
                label: "分镜任务：\(task.title)",
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID
            )
        }
        if let assetKind, let assetID {
            let assetLabel = assetKind == "scene" ? "场景资产任务" : "人物资产任务"
            return AgentMediaTaskScope(
                label: "\(assetLabel)：\(task.title)",
                projectID: projectID,
                assetKind: assetKind,
                assetID: assetID
            )
        }
        if let projectID {
            return AgentMediaTaskScope(
                label: "项目任务：\(task.title)",
                projectID: projectID
            )
        }
        return nil
    }

    private func mediaTasks(matching scope: AgentMediaTaskScope?) -> [AgentMediaTask] {
        let tasks = appState.agentMediaTaskRegistry.tasks(forRuntime: appState.activeAgentSessionID)
        guard let scope else { return tasks }
        return tasks.filter { scope.matches($0) }
    }

    private func appendScopeLines(_ scope: AgentMediaTaskScope, to lines: inout [String]) {
        lines.append("scope: \(retryScopeKind(scope))")
        appendCleanLine("project_id", scope.projectID, to: &lines)
        appendCleanLine("episode_id", scope.episodeID, to: &lines)
        appendCleanLine("shot_id", scope.shotID, to: &lines)
        appendCleanLine("asset_kind", scope.assetKind, to: &lines)
        appendCleanLine("asset_id", scope.assetID, to: &lines)
        appendCleanLine("review_item_id", scope.reviewItemID, to: &lines)
    }

    private func scopedArguments(_ scope: AgentMediaTaskScope) -> String {
        var pairs: [(String, String)] = [("scope", retryScopeKind(scope))]
        appendCleanPair("project_id", scope.projectID, to: &pairs)
        appendCleanPair("episode_id", scope.episodeID, to: &pairs)
        appendCleanPair("shot_id", scope.shotID, to: &pairs)
        appendCleanPair("asset_kind", scope.assetKind, to: &pairs)
        appendCleanPair("asset_id", scope.assetID, to: &pairs)
        appendCleanPair("review_item_id", scope.reviewItemID, to: &pairs)
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private func retryScopeKind(_ scope: AgentMediaTaskScope) -> String {
        if scope.reviewItemID != nil { return "review_item" }
        if scope.assetID != nil { return "asset" }
        if scope.shotID != nil { return "shot" }
        if scope.episodeID != nil { return "episode" }
        return "project"
    }

    private func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = clean(value) else { return }
        lines.append("\(key): \(value)")
    }

    private func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [(String, String)]) {
        guard let value = clean(value) else { return }
        pairs.append((key, value))
    }

    private func appendPromptToChat(_ prompt: String, duplicateGuard: String) {
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains(duplicateGuard) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 任务监控里「最近任务」最多展示的条数。
    private var monitorJobDisplayLimit: Int { 3 }

    /// 任务监控里最多直接展示的媒体任务数。
    private var monitorMediaTaskDisplayLimit: Int { 3 }

    /// 任务监控里最多直接展示的最近完成媒体任务数。
    private var recentCompletedMediaTaskDisplayLimit: Int { 2 }

    /// 最近任务列表的最大高度，超出后内部纵向滚动，避免撑爆右栏其余模块。
    private var monitorJobListMaxHeight: CGFloat { 232 }

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

    private var sessionArtifacts: [AgentRailArtifact] {
        guard let runtime = appState.activeRuntime else { return [] }
        var artifactsByPath: [String: AgentRailArtifact] = [:]

        if let workspaceURL = try? runtime.localWorkspaceURLForOptimisticUse() {
            for relativePath in runtime.agentArtifactPaths.sorted() {
                let url = workspaceURL.appendingPathComponent(relativePath).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    continue
                }
                artifactsByPath[url.path] = AgentRailArtifact(
                    url: url,
                    displayPath: relativePath,
                    isDirectory: isDirectory.boolValue
                )
            }
        }

        let mediaTasks = appState.agentMediaTaskRegistry.tasks
            .filter { $0.runtimeID == runtime.id }
            .sorted { $0.updatedAt > $1.updatedAt }
        for artifact in mediaTasks.flatMap(\.artifacts) {
            let url = URL(fileURLWithPath: artifact.filePath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            artifactsByPath[url.path] = AgentRailArtifact(
                url: url,
                displayPath: artifact.filePath,
                isDirectory: isDirectory.boolValue
            )
        }

        return AgentRailArtifact.collapsedForDisplay(Array(artifactsByPath.values)).sorted { lhs, rhs in
            lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
        }
    }

    private var workFileGroups: [AgentRailDirectoryGroup] {
        guard let repositoryRoot = appState.agentWorktreeChanges.repositoryRoot
            ?? (try? appState.activeRuntime?.localWorkspaceURLForOptimisticUse()) else {
            return []
        }
        let groups = Dictionary(grouping: sessionWorkFiles) { change in
            let parts = change.path.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : "根目录"
        }
        return groups
            .map { key, files in
                AgentRailDirectoryGroup(
                    id: key,
                    name: key,
                    count: files.count,
                    preview: files.prefix(2).map(\.fileName),
                    finderURL: AgentRailWorkFileFinderTarget.resolve(
                        repositoryRoot: repositoryRoot,
                        relativePaths: files.map(\.path)
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(6)
            .map { $0 }
    }

    private var sessionWorkFiles: [AgentFileChangeSummary] {
        let artifactPaths = appState.activeRuntime?.agentArtifactPaths ?? []
        return appState.agentWorktreeChanges.files.filter { !artifactPaths.contains($0.path) }
    }

    private var learningSummary: (memory: Int, skill: Int, mcp: Int, total: Int) {
        // 只统计「本轮」(>= 最近一条 user message) 的学习事件:历史轮次
        // 的事件不该让 rail 误以为有新进展、也不该触发任务监控自动展开。
        let events = appState.agentCurrentTurnLearningEvents
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

    @ViewBuilder
    var body: some View {
        if style == .composer, !currentSessionAliveJobs.isEmpty {
            backgroundTaskComposerCard
        } else if let phase {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                HStack(spacing: 7) {
                    Image(systemName: phase.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(phase.tint)
                    AgentActivitySweepLabel(
                        text: phase.label,
                        font: .system(size: 12, weight: .semibold),
                        isActive: shouldAnimateCurrentAction,
                        baseColor: phase.tint
                    )
                    if let startedAt = appState.agentTurnStartedAt, appState.isAgentResponding {
                        Spacer(minLength: 4)
                        Text(Self.formatElapsed(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(phase.tint.opacity(0.82))
                            .monospacedDigit()
                            .transaction { transaction in
                                if !AgentActivitySweepMetrics.animatesElapsedTime {
                                    transaction.animation = nil
                                }
                            }
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
    }

    private var backgroundTaskComposerCard: some View {
        let runningJobs = currentSessionAliveJobs
        let leadJob = runningJobs.first
        return Button {
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .backgroundTasks)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: runningJobs.isEmpty ? "checkmark.circle" : "play.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(runningJobs.isEmpty ? Color.secondary : Color.green)
                Text(L10n.AgentJobs.composerSummary(currentSessionJobs.count, runningJobs.count))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let leadJob {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(AgentBackgroundTaskPresentation.processName(command: leadJob.command))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(runningJobs.isEmpty ? 0.05 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.green.opacity(runningJobs.isEmpty ? 0.10 : 0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(Text(L10n.AgentJobs.managerTitle))
        .accessibilityHint(Text(L10n.AgentJobs.openManagerHelp))
    }

    private var currentSessionJobs: [AgentBackgroundJob] {
        guard let runtimeID = appState.activeAgentSessionID else { return [] }
        return appState.agentJobRegistry.jobs(forRuntime: runtimeID)
    }

    private var currentSessionAliveJobs: [AgentBackgroundJob] {
        currentSessionJobs.filter(\.isAlive)
    }

    private var shouldAnimateCurrentAction: Bool {
        // 有可识别动作标题时扫光，没有时泛化"思考中"兜底同样扫光——
        // 进行中反馈由动画文字承担，所以只要回合在响应且不处于压缩/
        // 等待用户决定这类静态状态，就保持动画。
        guard appState.isAgentResponding,
              !appState.isCompressingAgentContext,
              !appState.agentToolCalls.contains(where: { call in
                  call.status == .pendingApproval
                      || call.status == .awaitingConfirm
                      || call.status == .awaitingUserAnswer
              }) else {
            return false
        }
        return true
    }

    private var phase: AgentActivityPhase? {
        if appState.isCompressingAgentContext {
            // 灰色而非紫色：压缩是例行的后台维护，不是需要抢注意力的
            // 状态。彩色 tint 留给等待决定（橙）、任务运行（绿）这类
            // 真正要用户看一眼的阶段。
            return AgentActivityPhase(label: "压缩上下文中", systemImage: "arrow.down.forward.and.arrow.up.backward", tint: .secondary)
        }
        if let waiting = appState.agentToolCalls.last(where: { call in
            call.status == .pendingApproval || call.status == .awaitingConfirm || call.status == .awaitingUserAnswer
        }) {
            return AgentActivityPhase(label: waitingLabel(for: waiting), systemImage: "hand.raised", tint: .orange)
        }
        if let running = appState.agentToolCalls.last(where: { $0.status == .running }) {
            return phase(for: running)
        }
        if appState.agentRunningTaskCount > 0 {
            return AgentActivityPhase(label: "任务运行中", systemImage: "play.circle", tint: .green)
        }
        if appState.isAgentResponding {
            if let headline = appState.agentCurrentActivityHeadline {
                return AgentActivityPhase(
                    label: headline.liveTitle,
                    systemImage: headline.systemImage,
                    tint: .secondary
                )
            }
            // 没有可识别的 provider 动作标题时，composer 条回退到泛化
            // "思考中"——不产出状态标题的模型在纯响应期也要有活动反馈。
            // 任务监督栏（.rail）维持 rc6 的克制：只显示明确状态，不兜底。
            guard style == .composer else { return nil }
            return AgentActivityPhase(label: "思考中", systemImage: "brain", tint: .secondary)
        }
        return AgentActivityPhase(label: "空闲", systemImage: "checkmark.circle", tint: .secondary)
    }

    private func phase(for call: AgentToolCall) -> AgentActivityPhase {
        switch AgentToolKind.of(AgentToolCall(
            messageID: UUID(),
            externalID: "",
            toolName: call.toolName,
            arguments: [:],
            risk: .read,
            status: .running
        )) {
        case .fileExploration:
            return AgentActivityPhase(label: "搜索中", systemImage: "doc.text.magnifyingglass", tint: .blue)
        case .runCommand:
            return AgentActivityPhase(label: "验证中", systemImage: "terminal", tint: .orange)
        case .terminalOperation:
            return AgentActivityPhase(label: "操作终端", systemImage: "terminal", tint: .orange)
        case .fileMutation, .applyPatch:
            return AgentActivityPhase(label: "编辑中", systemImage: "pencil.line", tint: .green)
        case .subagent, .claudeCode, .codexCLI, .hermesCLI, .cursorAgent, .clineCLI:
            let delegatedProgress = call.delegatedProgress.map {
                L10n.DelegatedTask.liveProgress(
                    phase: $0.phase,
                    attempt: $0.attempt,
                    maximum: $0.maximumAttempts
                )
            }
            let label = AgentToolKind.of(call).delegatedActivityLabel(
                progress: delegatedProgress ?? call.subagentProgress
            ) ?? "委派中"
            return AgentActivityPhase(label: label, systemImage: "person.2", tint: .accentColor)
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
    var finderURL: URL
}

enum AgentRailWorkFileFinderTarget {
    nonisolated static func resolve(
        repositoryRoot: URL,
        relativePaths: [String],
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        let root = repositoryRoot.standardizedFileURL
        let paths = relativePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstPath = paths.first else { return root }
        let fileURL = root.appendingPathComponent(firstPath).standardizedFileURL
        if paths.count == 1, fileExists(fileURL.path) {
            return fileURL
        }

        let components = firstPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return root }
        return root.appendingPathComponent(String(components[0]), isDirectory: true).standardizedFileURL
    }
}

struct AgentRailArtifact: Identifiable {
    let url: URL
    let displayPath: String
    let isDirectory: Bool
    var itemCount: Int = 1

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var subtitle: String {
        if isDirectory, itemCount > 1 {
            return "\(displayPath) · \(itemCount) 个产物"
        }
        return displayPath
    }

    var systemImage: String {
        if isDirectory {
            return "folder"
        }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return "photo"
        case "mp4", "mov", "m4v", "webm", "avi":
            return "film"
        case "mp3", "wav", "m4a", "aac":
            return "waveform"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc.text"
        }
    }

    var tint: Color {
        if isDirectory {
            return .accentColor
        }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return .blue
        case "mp4", "mov", "m4v", "webm", "avi":
            return .orange
        case "mp3", "wav", "m4a", "aac":
            return .pink
        default:
            return .accentColor
        }
    }

    static func collapsedForDisplay(_ artifacts: [AgentRailArtifact]) -> [AgentRailArtifact] {
        let directoryArtifacts = artifacts.filter { $0.isDirectory }
        let visibleArtifacts = artifacts.filter { artifact in
            guard !artifact.isDirectory else { return true }
            return !directoryArtifacts.contains { directory in
                artifact.url.path.hasPrefix(directory.childPathPrefix)
            }
        }
        let grouped = Dictionary(grouping: visibleArtifacts) { artifact in
            artifact.directoryCollapseKey ?? "file:\(artifact.url.path)"
        }
        return grouped.values.compactMap { items in
            guard items.count > 1 else { return items.first }
            if let directory = items.first(where: \.isDirectory) {
                var collapsed = directory
                collapsed.itemCount = items.count
                return collapsed
            }
            guard var collapsed = items.first?.directorySummaryArtifact else {
                return items.sorted { lhs, rhs in
                    lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
                }.first
            }
            collapsed.itemCount = items.count
            return collapsed
        }
    }

    private var directoryCollapseKey: String? {
        if isDirectory {
            return displayPath.hasPrefix("/") ? "abs:\(url.path)" : "rel:\(displayPath)"
        }
        if displayPath.hasPrefix("/") {
            return "abs:\(url.deletingLastPathComponent().path)"
        }
        let components = displayPath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        return "rel:\(components[0])"
    }

    private var directorySummaryArtifact: AgentRailArtifact? {
        if isDirectory {
            return self
        }
        if displayPath.hasPrefix("/") {
            let directoryURL = url.deletingLastPathComponent().standardizedFileURL
            return AgentRailArtifact(
                url: directoryURL,
                displayPath: directoryURL.path,
                isDirectory: true
            )
        }
        let components = displayPath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        let directoryName = components[0]
        return AgentRailArtifact(
            url: url.deletingLastPathComponents(components.count - 1).standardizedFileURL,
            displayPath: directoryName,
            isDirectory: true
        )
    }

    private var childPathPrefix: String {
        url.path.hasSuffix("/") ? url.path : url.path + "/"
    }
}

private extension URL {
    func deletingLastPathComponents(_ count: Int) -> URL {
        var result = self
        for _ in 0..<max(0, count) {
            result.deleteLastPathComponent()
        }
        return result
    }
}

private struct AgentRailMediaTaskRow: View {
    @EnvironmentObject var appState: AppState
    let task: AgentMediaTask
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: task.kind.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 15)
                        Text(task.displayHandle)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(task.status.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.12))
                            .clipShape(Capsule())
                        Spacer(minLength: 0)
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(task.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("\(task.provider.displayName) · \(task.kind.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if task.isStaleActive() {
                            Text("未更新 \(task.staleActiveMinutes())m")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                        if task.artifacts.count > 0 {
                            Text("\(task.artifacts.count) 个产物")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            VStack(spacing: 4) {
                if task.isActive {
                    Button {
                        refreshTask()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("立即刷新这个媒体任务")
                    Button {
                        cancelTask()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("取消这个媒体任务")
                }
                Button {
                    AgentMediaTaskChatHandoff.appendTaskContext(task: task, appState: appState)
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("发送任务上下文到聊天")
            }
        }
        .padding(8)
        .background(tint.opacity(task.needsAttention ? 0.10 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(tint.opacity(task.needsAttention ? 0.24 : 0.10), lineWidth: 1)
        )
        .help("打开媒体任务侧栏，或用气泡按钮发送任务上下文到聊天")
    }

    private func refreshTask() {
        Task {
            await appState.agentMediaTaskPoller.refreshNow(
                taskID: task.id,
                registry: appState.agentMediaTaskRegistry
            )
        }
    }

    private func cancelTask() {
        Task {
            await appState.agentMediaTaskPoller.cancel(
                taskID: task.id,
                registry: appState.agentMediaTaskRegistry
            )
        }
    }

    private var tint: Color {
        if task.isStaleActive() {
            return .orange
        }
        switch task.status {
        case .queued, .submitted, .starting:
            return .accentColor
        case .processing:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .secondary
        }
    }
}

private struct AgentRailJobRow: View {
    let job: AgentBackgroundJob
    let inspect: () -> Void
    let kill: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: inspect) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: iconName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 15)
                        Text(job.displayHandle)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(statusText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.12))
                            .clipShape(Capsule())
                        Spacer(minLength: 0)
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(job.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(Self.formatDuration(job.duration))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let exitCode = job.exitCode {
                            Text("exit \(exitCode)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(exitCode == 0 ? .green : .red)
                        }
                        if job.outputByteCount > 0 {
                            Text("\(job.outputByteCount) B")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.AgentJobs.inspectOutputHelp)

            VStack(spacing: 0) {
                if job.isAlive {
                    Button(action: kill) {
                        Image(systemName: "stop.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(L10n.AgentJobs.kill)
                }
            }
        }
        .padding(8)
        .background(tint.opacity(job.needsAttention ? 0.10 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(tint.opacity(job.needsAttention ? 0.24 : 0.10), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch job.status {
        case .running: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .killed: return "stop.circle.fill"
        case .timedOut: return "clock.badge.exclamationmark.fill"
        case .launchFailed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch job.status {
        case .running: return .green
        case .completed: return .secondary
        case .failed, .launchFailed: return .red
        case .killed, .timedOut: return .orange
        }
    }

    private var statusText: String {
        switch job.status {
        case .running: return L10n.AgentJobs.statusRunning
        case .completed: return L10n.AgentJobs.statusCompleted
        case .failed: return L10n.AgentJobs.statusFailed
        case .killed: return L10n.AgentJobs.statusKilled
        case .timedOut: return L10n.AgentJobs.statusTimedOut
        case .launchFailed: return L10n.AgentJobs.statusLaunchFailed
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remaining = total % 60
        if minutes < 60 { return "\(minutes)m \(remaining)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct AgentRailDelegatedTaskRow: View {
    let run: AgentDelegatedTaskRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: phaseSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(phaseTint)
                    .frame(width: 16)
                Text(run.contract.executorName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(L10n.DelegatedTask.phase(run.phase))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseTint)
            }

            Text(run.contract.objective)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label(
                    L10n.DelegatedTask.attempt(
                        max(run.attempt, run.phase == .contracted ? 0 : 1),
                        run.contract.maxAttempts
                    ),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                Label(
                    L10n.DelegatedTask.changedFileCount(run.changedPaths.count),
                    systemImage: "doc.badge.ellipsis"
                )
                if let findings = run.willDeepAcceptance?.findings.count, findings > 0 {
                    Label(
                        L10n.DelegatedTask.findingCount(findings),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)

            if let finding = run.willDeepAcceptance?.findings.first {
                Text(finding)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let error = run.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(phaseTint.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(phaseTint.opacity(0.16), lineWidth: 1)
        )
    }

    private var phaseSymbol: String {
        switch run.phase {
        case .contracted:
            return "doc.badge.gearshape"
        case .executing:
            return "hammer"
        case .selfVerifying:
            return "person.crop.circle.badge.checkmark"
        case .willDeepVerifying:
            return "checkmark.shield"
        case .reworkRequired:
            return "arrow.uturn.backward.circle"
        case .readyForDelivery:
            return "checkmark.seal.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle"
        }
    }

    private var phaseTint: Color {
        switch run.phase {
        case .contracted:
            return .secondary
        case .executing, .selfVerifying, .willDeepVerifying:
            return .blue
        case .reworkRequired:
            return .orange
        case .readyForDelivery:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }
}

private struct AgentRailSection<Content: View>: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22, height: 22)
                    .background(palette.accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.controlFill.opacity(0.38))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.hairline.opacity(0.7), lineWidth: 1)
        )
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(subtitle)
    }
}

private struct AgentRailDirectoryRow: View {
    let group: AgentRailDirectoryGroup
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .focusable(false)
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
