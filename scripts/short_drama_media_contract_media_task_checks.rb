# frozen_string_literal: true

# short_drama_media_contract_media_task_checks.rb — 媒体任务这一组契约断言：
# 锚点徽标、任务面板的过滤与批量操作、任务注册表落盘、任务监视栏、组件
# （show_widget）接力，以及图片编辑器的蒙版与 Replicate 配置提示。
#
# 从 short_drama_media_contract_test.rb 拆出来：那个脚本 2995 行，离
# scripts/complexity_guard.rb 的 hard_limit=3000 只差 5 行。断言体逐行原样
# 搬运，缩进刻意保持与拆分前一致（不额外缩进一层），方便和历史 diff 逐行对照。

def short_drama_media_contract_media_task_checks(
  image_tools_source:,
  dispatch_source:,
  media_tools_source:,
  short_drama_source:,
  asset_views_source:,
  media_tasks_source:,
  media_task_handoff_source:,
  media_artifact_views_source:,
  some_im_source:,
  replicate_source:,
  image_edit_source:,
  registry_source:,
  side_panel_source:,
  mode_view_source:,
  conversation_activity_overlay_source:,
  app_state_source:,
  app_state_loop_source:,
  chat_header_source:,
  widget_source:,
  widget_card_source:,
  task_monitor_source:
)
{
  "short drama side panel shows anchored media task badges" =>
    short_drama_source.include?("mediaTaskBadge(") &&
    short_drama_source.include?("scope: mediaTaskScope(project: project)") &&
    short_drama_source.include?("mediaTaskHealthSummary(") &&
    short_drama_source.include?("private func mediaTaskHealthSummary(tasks: [AgentMediaTask], scope: AgentMediaTaskScope?, title: String = \"任务\") -> some View") &&
    short_drama_source.include?("Text(\"运行 \\(active)\")") &&
    short_drama_source.include?("Text(\"失败 \\(failed)\")") &&
    short_drama_source.include?("Text(\"完成 \\(completed)\")") &&
    short_drama_source.include?("latest.displayHandle") &&
    short_drama_source.include?("tasks: allProjectMediaTasks()") &&
    short_drama_source.include?("title: \"全部任务\"") &&
    short_drama_source.include?("private func allProjectMediaTasks() -> [AgentMediaTask]") &&
    short_drama_source.include?("let projectIDs = Set(store.projects.map { $0.id.uuidString })") &&
    short_drama_source.include?("let completed = tasks.filter { $0.status == .succeeded }.count") &&
    short_drama_source.include?("label: compact ? \"\\(completed)\" : \"完成 \\(completed)\",") &&
    short_drama_source.include?("systemImage: \"checkmark.circle.fill\"") &&
    short_drama_source.include?("mediaTasks(project: AgentShortDramaProject, episode: AgentShortDramaEpisode, shot: AgentShortDramaShot)") &&
    short_drama_source.include?("clock.arrow.circlepath"),
  "short drama media task badges open scoped media panel" =>
    short_drama_source.include?("openMediaTasksPanel(scope: scope)") &&
    short_drama_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)") &&
    short_drama_source.include?(".buttonStyle(.plain)") &&
    short_drama_source.include?("打开媒体任务侧栏"),
  "short drama asset cards show anchored media task badges" =>
    asset_views_source.include?("mediaTaskBadge(tasks: mediaTasks(item), scope: mediaTaskScope(item), compact: true)") &&
    short_drama_source.include?("mediaTasks(project: AgentShortDramaProject, asset: ShortDramaAssetSummary)") &&
    short_drama_source.include?("task.assetKind == asset.assetKind"),
  "media task panel supports scoped filtering" =>
    side_panel_source.include?("let mediaTaskScope: AgentMediaTaskScope?") &&
    app_state_source.include?("@Published var agentMediaTaskPanelScope: AgentMediaTaskScope?") &&
    mode_view_source.include?("appState.agentMediaTaskPanelScope = request.mediaTaskScope") &&
    media_tasks_source.include?("struct AgentMediaTaskScope") &&
    media_tasks_source.include?("func matches(_ task: AgentMediaTask) -> Bool") &&
    media_tasks_source.include?("var reviewItemID: String?") &&
    media_tasks_source.include?("task.reviewItemID != reviewItemID") &&
    media_tasks_source.include?("allTasks.filter { scope.matches($0) }") &&
    media_tasks_source.include?("清除媒体任务筛选"),
  "media task panel supports status filtering" =>
    media_tasks_source.include?("enum AgentMediaTaskStatusFilter") &&
    media_tasks_source.include?("@State private var statusFilter: AgentMediaTaskStatusFilter = .all") &&
    media_tasks_source.include?("scopedTasks.filter { statusFilter.matches($0) }") &&
    media_tasks_source.include?("Picker(\"任务状态\", selection: $statusFilter)") &&
    media_tasks_source.include?(".pickerStyle(.segmented)") &&
    media_tasks_source.include?("按任务状态筛选"),
  "media task registry persists tasks across app restarts" =>
    media_tasks_source.include?("init(fileURL: URL = AgentMediaTaskRegistry.defaultFileURL())") &&
    media_tasks_source.include?("self.tasks = Self.load(from: fileURL)") &&
    media_tasks_source.include?("WillDeep/media-tasks/tasks.json") &&
    media_tasks_source.include?("encoder.dateEncodingStrategy = .iso8601") &&
    media_tasks_source.include?("decoder.dateDecodingStrategy = .iso8601") &&
    media_tasks_source.include?("try data.write(to: fileURL, options: [.atomic])") &&
    media_tasks_source.include?("var statusEndpointSuffix: String?") &&
    media_tasks_source.include?("var cancelEndpointSuffix: String?") &&
    media_tasks_source.include?("trimHistory(saveAfterTrim: false)") &&
    media_tasks_source.include?("AgentMediaTaskRegistry: failed to save tasks"),
  "provider media downloads avoid overwriting duplicate artifact names" =>
    some_im_source.include?("private static func uniqueFileURL(in directory: URL, filename: String) -> URL") &&
    some_im_source.include?("uniqueFileURL(in: directory, filename: filename)") &&
    some_im_source.include?("SomeIMMediaArtifact(title: fileURL.lastPathComponent") &&
    replicate_source.include?("private static func uniqueFileURL(in directory: URL, filename: String) -> URL") &&
    replicate_source.include?("uniqueFileURL(in: directory, filename: filename)") &&
    replicate_source.include?("title: fileURL.lastPathComponent"),
  "some.im persisted endpoint suffixes drive refresh and cancel" =>
    media_tasks_source.include?("endpointSuffix(for: task)") &&
    media_tasks_source.include?("cancelEndpointSuffix(for: task)") &&
    media_tasks_source.include?("clean(task.statusEndpointSuffix)") &&
    media_tasks_source.include?("clean(task.cancelEndpointSuffix)") &&
    media_tools_source.include?("existingTask?.statusEndpointSuffix") &&
    media_tools_source.include?("existingTask?.cancelEndpointSuffix"),
  "media task side panel shortcut exposes active or failed counts" =>
    chat_header_source.include?("private var visibleMediaTasks: [AgentMediaTask]") &&
    chat_header_source.include?("private var mediaTaskCounts: (active: Int, failed: Int)") &&
    chat_header_source.include?("AgentSidePanelShortcutControl(") &&
    chat_header_source.include?("counts.failed > 0") &&
    chat_header_source.include?("counts.active > 0") &&
    chat_header_source.include?("sidePanelTitle(for: item)") &&
    chat_header_source.include?("button.toolTip = title") && chat_header_source.include?("button.setAccessibilityLabel(title)") &&
    chat_header_source.include?("需处理") &&
    chat_header_source.include?("运行中"),
  "task monitor rail shows media task status summary" =>
    task_monitor_source.include?("private var visibleMediaTasks: [AgentMediaTask]") &&
    task_monitor_source.include?("private var recentCompletedMediaTasks: [AgentMediaTask]") &&
    task_monitor_source.include?("recentCompletedMediaTaskDisplayLimit") &&
    task_monitor_source.include?("最近完成") &&
    task_monitor_source.include?("刚完成") &&
    task_monitor_source.include?("mediaTaskSummaryText") &&
    task_monitor_source.include?("AgentRailMediaTaskRow") &&
    task_monitor_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks)") &&
    task_monitor_source.include?("mediaTaskDigest") &&
    task_monitor_source.include?("task.isActive || task.needsAttention || task.status == .succeeded") &&
    task_monitor_source.include?("媒体生成：") &&
    task_monitor_source.include?("打开媒体任务侧栏"),
  "media task rows can manually refresh and cancel active remote tasks" =>
    media_tasks_source.include?("func refreshNow(taskID: UUID, registry: AgentMediaTaskRegistry) async") &&
    media_tasks_source.include?("func cancel(taskID: UUID, registry: AgentMediaTaskRegistry) async") &&
    media_tasks_source.include?("cancelReplicate(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry)") &&
    media_tasks_source.include?("cancelSomeIM(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry)") &&
    media_tasks_source.include?("cancelGeneric(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry)") &&
    media_tasks_source.include?("AgentGenericMediaStatusClient.canCancel(task)") &&
    media_tasks_source.include?("立即刷新任务状态") &&
    media_tasks_source.include?("取消远端任务") &&
    media_tasks_source.include?("await appState.agentMediaTaskPoller.refreshNow") &&
    media_tasks_source.include?("await appState.agentMediaTaskPoller.cancel("),
  "media task panel can bulk refresh visible active tasks" =>
    media_tasks_source.include?("@State private var isRefreshingVisible = false") &&
    media_tasks_source.include?("private var refreshableScopedTasks: [AgentMediaTask]") &&
    media_tasks_source.include?("func refreshVisibleActiveTasks()") &&
    media_tasks_source.include?("刷新运行中") &&
    media_tasks_source.include?("立即刷新当前筛选范围内的运行中任务"),
  "media task panel can send scoped status summary to chat" =>
    media_tasks_source.include?("appendScopedStatusToChat") &&
    media_tasks_source.include?("发送状态到聊天") &&
    media_tasks_source.include?("把当前筛选范围内的媒体任务状态摘要发送到聊天") &&
    media_tasks_source.include?("<media-task-scope-status>") &&
    media_tasks_source.include?("action: inspect_media_task_scope") &&
    media_tasks_source.include?("active_count: \\(active.count)") &&
    media_tasks_source.include?("failed_count: \\(failed.count)") &&
    media_tasks_source.include?("finished_count: \\(finished.count)") &&
    media_tasks_source.include?("let completedImageTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedImageArtifact)") &&
    media_tasks_source.include?("let completedVideoTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedVideoArtifact)") &&
    media_tasks_source.include?("completed_image_task_count: \\(completedImageTasks.count)") &&
    media_tasks_source.include?("completed_video_task_count: \\(completedVideoTasks.count)") &&
    media_tasks_source.include?("active_task_actions:") &&
    media_tasks_source.include?("AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine") &&
    media_tasks_source.include?("active_task_follow_up: active_task_actions 已包含可直接调用的 provider 轮询/取消参数") &&
    media_tasks_source.include?("completed_image_tasks:") &&
    media_tasks_source.include?("AgentMediaTaskChatHandoff.completedImageScopeSummaryLine") &&
    media_tasks_source.include?("completed_image_follow_up: completed_image_tasks 已包含可直接调用的后续工具参数") &&
    media_tasks_source.include?("completed_video_tasks:") &&
    media_tasks_source.include?("AgentMediaTaskChatHandoff.completedVideoScopeSummaryLine") &&
    media_tasks_source.include?("completed_video_follow_up: completed_video_tasks 已包含可直接调用的审片、分镜板和任务范围参数") &&
    media_task_handoff_source.include?("parts.append(\"image_choice_tool=short_drama_show_image_choice_widget\")") &&
    media_task_handoff_source.include?("parts.append(\"image_choice_tool=show_image_choice_widget\")") &&
    media_task_handoff_source.include?("parts.append(\"image_choice_arguments=image_paths=\\(joinedImagePaths), \\(imageArguments)\")") &&
    media_tasks_source.include?("<media-task-completed-artifact-actions>") &&
    media_tasks_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    media_tasks_source.include?("retry_failed_tool: short_drama_retry_failed_media_tasks") &&
    media_tasks_source.include?("private func appendScopeLines(_ scope: AgentMediaTaskScope, to lines: inout [String])") &&
    media_tasks_source.include?("appendPromptToChat(lines.joined(separator: \"\\n\"), duplicateGuard: \"<media-task-scope-status>\")"),
  "media task rows expose image choice widget" =>
    media_tasks_source.include?("AgentMediaTaskChoiceWidgetBuilder") &&
    media_tasks_source.include?("Label(\"候选图\", systemImage: \"rectangle.grid.2x2\")") &&
    media_artifact_views_source.include?("title: \"媒体任务候选图\"") &&
    media_artifact_views_source.include?("html: html(for: task, artifacts: artifacts)") &&
    media_artifact_views_source.include?("contextLines: contextLines(for: task, artifacts: artifacts)") &&
    media_artifact_views_source.include?("private static func contextLines(for task: AgentMediaTask, artifacts: [AgentMediaArtifact]) -> [String]") &&
    media_artifact_views_source.include?("<media-task-image-choice-widget>") &&
    media_artifact_views_source.include?("action: media_task_image_choice_widget") &&
    media_artifact_views_source.include?("candidate_actions:") &&
    media_artifact_views_source.include?("select_tool: \\(tool)") &&
    media_artifact_views_source.include?("edit_arguments: \\(mediaTaskActionRecommendedArguments(action: \"open_image_editor\", task: task, artifact: artifact, extraLines: [\"operation: inpaint\"]))") &&
    media_artifact_views_source.include?("erase_arguments: \\(mediaTaskActionRecommendedArguments(action: \"open_image_editor\", task: task, artifact: artifact, extraLines: [\"operation: erase\"]))") &&
    media_artifact_views_source.include?("upscale_arguments: \\(mediaTaskActionRecommendedArguments(action: \"upscale_image\", task: task, artifact: artifact, extraLines: []))") &&
    media_artifact_views_source.include?("video_arguments: \\(mediaTaskActionRecommendedArguments(action: \"generate_video_from_image\", task: task, artifact: artifact, extraLines: []))") &&
    media_artifact_views_source.include?("<media-task-image-choice>") &&
    media_artifact_views_source.include?("short_drama_select_shot_artifact") &&
    media_artifact_views_source.include?("short_drama_attach_asset_reference_image") &&
    media_artifact_views_source.include?("asset_kind: \\(assetKind)") &&
    media_artifact_views_source.include?("asset_id: \\(assetID)") &&
    media_artifact_views_source.include?("recommended_tool: \\(tool)") &&
    media_artifact_views_source.include?("recommended_arguments: \\(mediaTaskChoiceRecommendedArguments(task: task, artifact: artifact))") &&
    media_artifact_views_source.include?("mediaTaskChoiceFollowUpLines(task: task, artifact: artifact)") &&
    media_artifact_views_source.include?("return \"short_drama_select_shot_artifact\"") &&
    media_artifact_views_source.include?("return \"short_drama_attach_asset_reference_image\"") &&
    media_artifact_views_source.include?("pairs.append((\"artifact_path\", artifact.filePath))") &&
    media_artifact_views_source.include?("pairs.append((\"image_path\", artifact.filePath))") &&
    media_artifact_views_source.include?("appendCleanPair(\"review_item_id\", task.reviewItemID") &&
    media_artifact_views_source.include?("post_select_open_shot_tasks_tool: short_drama_open_media_tasks") &&
    media_artifact_views_source.include?("post_select_open_shot_tasks_arguments: \\(argumentString(shotTaskPairs))") &&
    media_artifact_views_source.include?("post_select_video_tool: generate_video_from_image") &&
    media_artifact_views_source.include?("post_select_video_arguments: \\(argumentString(imagePairs))") &&
    media_artifact_views_source.include?("post_select_edit_tool: short_drama_open_image_editor") &&
    media_artifact_views_source.include?("post_select_edit_arguments: \\(argumentString(artifactPairs)), operation=inpaint") &&
    media_artifact_views_source.include?("post_select_erase_tool: short_drama_open_image_editor") &&
    media_artifact_views_source.include?("post_select_erase_arguments: \\(argumentString(artifactPairs)), operation=erase") &&
    media_artifact_views_source.include?("post_select_upscale_tool: short_drama_upscale_shot_artifact") &&
    media_artifact_views_source.include?("post_select_upscale_arguments: \\(argumentString(artifactPairs))") &&
    media_artifact_views_source.include?("post_select_open_review_tasks_tool: short_drama_open_media_tasks") &&
    media_artifact_views_source.include?("post_select_open_review_tasks_arguments: \\(argumentString(reviewTaskPairs))") &&
    media_artifact_views_source.include?("post_select_resolve_review_tool: short_drama_resolve_review_item") &&
    media_artifact_views_source.include?("post_select_resolve_review_arguments: \\(argumentString(reviewPairs))") &&
    media_artifact_views_source.include?("post_select_attach_reference_tool: short_drama_attach_asset_reference_image") &&
    media_artifact_views_source.include?("post_select_attach_reference_arguments: \\(argumentString(attachPairs))") &&
    media_artifact_views_source.include?("post_select_open_asset_tasks_tool: short_drama_open_media_tasks") &&
    media_artifact_views_source.include?("post_select_open_asset_tasks_arguments: \\(argumentString(taskPairs))") &&
    media_artifact_views_source.include?("后续媒体任务也必须继续携带") &&
    media_artifact_views_source.include?("openEditorPrompt(task: task, artifact: artifact)") &&
    media_artifact_views_source.include?("erasePrompt(task: task, artifact: artifact)") &&
    media_artifact_views_source.include?("upscalePrompt(task: task, artifact: artifact)") &&
    media_artifact_views_source.include?("videoPrompt(task: task, artifact: artifact)") &&
    media_artifact_views_source.include?("mediaTaskActionBlock(action: \"open_image_editor\"") &&
    media_artifact_views_source.include?("mediaTaskActionBlock(action: \"upscale_image\"") &&
    media_artifact_views_source.include?("mediaTaskActionBlock(action: \"generate_video_from_image\"") &&
    media_artifact_views_source.include?("return \"short_drama_open_image_editor\"") &&
    media_artifact_views_source.include?("return \"short_drama_upscale_shot_artifact\"") &&
    media_artifact_views_source.include?("recommended_arguments: \\(mediaTaskActionRecommendedArguments(action: action, task: task, artifact: artifact, extraLines: extraLines))") &&
    media_artifact_views_source.include?("reference_image_path: \\(artifact.filePath)") &&
    media_tasks_source.include?("打开候选图选择器"),
  "show_widget accepts skill generated html files" =>
    registry_source.include?('name: "html_path"') &&
    registry_source.include?("Pass either `html` for inline markup or `html_path`") &&
    registry_source.include?("WillDeep's short-drama export package directory") &&
    dispatch_source.include?("private static func widgetHTML") &&
    dispatch_source.include?('arguments["html_path"]') &&
    dispatch_source.include?("resolveWidgetHTMLURL") &&
    dispatch_source.include?("widgetTemporaryDirectories()") &&
    dispatch_source.include?("FileManager.default.temporaryDirectory") &&
    dispatch_source.include?("URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)") &&
    dispatch_source.include?("shortDramaExportsDirectory") &&
    dispatch_source.include?("WillDeep/short-drama/exports") &&
    dispatch_source.include?("isWidgetHTMLURLAllowed") &&
    dispatch_source.include?("html_path must point to a .html, .htm, or .svg file.") &&
    dispatch_source.include?("Data(contentsOf: url)") &&
    dispatch_source.include?("AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)") &&
    dispatch_source.include?("AgentSidePanelOpenRequest(kind: .widget)") &&
    dispatch_source.include?("<widget-follow-up>") &&
    dispatch_source.include?("action: show_widget_follow_up") &&
    dispatch_source.include?("source: \\(arguments[\"html_path\"]?.stringValue() == nil ? \"inline_html\" : \"html_path\")"),
  "show_widget preserves skill callback metadata" =>
    widget_source.include?("var contextLines: [String]") &&
    widget_source.include?("var contextBlock: String") &&
    dispatch_source.include?("(\"html_path\", \"html_path\")") &&
    registry_source.include?('name: "source_label"') &&
    registry_source.include?('name: "source_path"') &&
    registry_source.include?('name: "package_directory"') &&
    registry_source.include?('name: "widget_context"') &&
    registry_source.include?('name: "recommended_tool"') &&
    registry_source.include?('name: "recommended_arguments"') &&
    registry_source.include?('name: "project_id"') &&
    registry_source.include?('name: "episode_id"') &&
    registry_source.include?('name: "shot_id"') &&
    registry_source.include?('name: "asset_kind"') &&
    registry_source.include?('name: "asset_id"') &&
    registry_source.include?('name: "review_item_id"') &&
    dispatch_source.include?("(\"review_item_id\", \"review_item_id\")") &&
    dispatch_source.include?("lines.append(contentsOf: widgetShortDramaHandoffLines(arguments: arguments))") &&
    dispatch_source.include?("private static func widgetShortDramaHandoffLines(arguments: [String: AgentJSONValue]) -> [String]") &&
    dispatch_source.include?("open_widget_tasks_tool: short_drama_open_media_tasks") &&
    dispatch_source.include?("open_widget_tasks_arguments: \\(scopeArguments)") &&
    dispatch_source.include?("refresh_widget_tasks_tool: short_drama_refresh_media_tasks") &&
    dispatch_source.include?("refresh_widget_tasks_arguments: \\(scopeArguments)") &&
    dispatch_source.include?("resolve_widget_review_tool: short_drama_resolve_review_item") &&
    dispatch_source.include?("resolve_widget_review_arguments: \\(resolveArguments)") &&
    dispatch_source.include?("scope=asset, asset_kind=\\(assetKind), asset_id=\\(assetID)") &&
    dispatch_source.include?("pairs.append(\"episode_id=\\(episodeID)\")") &&
    dispatch_source.include?("pairs.append(\"scope=\\(episodeID == nil ? \"project\" : \"episode\")\")") &&
    dispatch_source.include?("let contextLines = try widgetContextLines(arguments: arguments)") &&
    dispatch_source.include?("AgentWidget(title: title, html: html, contextLines: contextLines)") &&
    dispatch_source.include?("private static func widgetContextLines") &&
    dispatch_source.include?("recommended_arguments") &&
    dispatch_source.include?("show_widget context metadata must be 8 KB or smaller.") &&
    dispatch_source.include?("\\(widget.contextBlock)") &&
    side_panel_source.include?("\\(widget.contextBlock)"),
  "widget sendPrompt carries source context back to chat" =>
    widget_card_source.include?("AgentWidgetWebView(") &&
    widget_card_source.include?("widgetID: widget.id") &&
    widget_card_source.include?("widgetTitle: widget.title") &&
    widget_card_source.include?("widgetContext: widget.contextBlock") &&
    widget_card_source.include?("context.coordinator.widgetID = widgetID") &&
    widget_card_source.include?("context.coordinator.widgetTitle = widgetTitle") &&
    widget_card_source.include?("context.coordinator.widgetContext = widgetContext") &&
    widget_card_source.include?("private func promptWithWidgetContext(_ prompt: String) -> String") &&
    widget_card_source.include?("<widget-action>") &&
    widget_card_source.include?("action: widget_send_prompt") &&
    widget_card_source.include?("widget_id: \\(widgetID.uuidString)") &&
    widget_card_source.include?("widget_title: \\(widgetTitle)") &&
    widget_card_source.include?("source: sendPrompt") &&
    widget_card_source.include?("\\(widgetContext)") &&
    widget_card_source.include?("appState.agentInput = self.promptWithWidgetContext(trimmed)"),
  "widget side panel exposes recommended tool handoff" =>
    widget_source.include?("var recommendedAction: AgentWidgetRecommendedAction?") &&
    widget_source.include?("var handoffActions: [AgentWidgetHandoffAction]") &&
    widget_source.include?("key.hasSuffix(\"_tool\")") &&
    widget_source.include?("key != \"recommended_tool\"") &&
    widget_source.include?("compactHandoffAction(from: line)") &&
    widget_source.include?("inlineContextValue(named: \"tool\", in: line)") &&
    widget_source.include?("inlineContextTailValue(named: \"arguments\", in: line)") &&
    widget_source.include?("([\":\", \"=\"] as [Character])") &&
    widget_source.include?("contextValue(named: \"\\(baseKey)_arguments\")") &&
    widget_source.include?("contextValue(named: \"recommended_tool\")") &&
    widget_source.include?("contextValue(named: \"recommended_arguments\")") &&
    widget_source.include?("struct AgentWidgetRecommendedAction") &&
    widget_source.include?("struct AgentWidgetHandoffAction") &&
    side_panel_source.include?("widgetRecommendedActionRow") &&
    side_panel_source.include?("widgetHandoffActionRows") &&
    side_panel_source.include?("let handoffAction = recommendedHandoffAction(action)") &&
    side_panel_source.include?("private func recommendedHandoffAction(_ action: AgentWidgetRecommendedAction) -> AgentWidgetHandoffAction") &&
    side_panel_source.include?("Text(\"可用动作\")") &&
    side_panel_source.include?("appendWidgetRecommendedActionToChat") &&
    side_panel_source.include?("appendWidgetHandoffActionToChat") &&
    side_panel_source.include?("openWidgetMediaTaskListIfAvailable(handoffAction)") &&
    side_panel_source.include?("openWidgetRemoteTaskRefreshIfAvailable(handoffAction)") &&
    side_panel_source.include?("openWidgetRemoteTaskInspectIfAvailable(handoffAction)") &&
    side_panel_source.include?("openWidgetProductionPackagePreviewIfAvailable(handoffAction)") &&
    side_panel_source.include?("openWidgetReviewPanelIfAvailable(handoffAction)") &&
    side_panel_source.include?("openWidgetHTMLIfAvailable(handoffAction)") &&
    side_panel_source.include?("openWidgetMediaTaskScopeIfAvailable(action)") &&
    side_panel_source.include?("openWidgetRemoteTaskRefreshIfAvailable(action)") &&
    side_panel_source.include?("openWidgetRemoteTaskInspectIfAvailable(action)") &&
    side_panel_source.include?("private func widgetMediaTask(from fields: [String: String], provider: AgentMediaTaskProvider) -> AgentMediaTask?") &&
    side_panel_source.include?("openWidgetProductionPackagePreviewIfAvailable(action)") &&
    side_panel_source.include?("private func openWidgetPreview(packageDirectory: String, action: AgentWidgetHandoffAction) -> Bool") &&
    side_panel_source.include?("private func openWidgetReviewPanelIfAvailable(_ action: AgentWidgetHandoffAction)") &&
    side_panel_source.include?("openWidgetImageEditorIfAvailable(action)") &&
    side_panel_source.include?("openShortDramaWidgetIfAvailable(action)") &&
    side_panel_source.include?("appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)") &&
    side_panel_source.include?("private func mediaTaskScope(from arguments: String?) -> AgentMediaTaskScope?") &&
    side_panel_source.include?("private func refreshWidgetMediaTaskScope(_ scope: AgentMediaTaskScope)") &&
    side_panel_source.include?("appState.agentMediaTaskPoller.refreshNow") &&
    side_panel_source.include?("private func openWidgetImageEditorIfAvailable(_ action: AgentWidgetHandoffAction)") &&
    side_panel_source.include?("appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .imageEditor)") &&
    side_panel_source.include?("AgentShortDramaStoryboardWidgetBuilder.imageChoiceWidget") &&
    side_panel_source.include?("AgentShortDramaStoryboardWidgetBuilder.widget(for: project") &&
    side_panel_source.include?("<widget-recommended-action>") &&
    side_panel_source.include?("<widget-handoff-action>") &&
    side_panel_source.include?("action: run_widget_recommended_tool") &&
    side_panel_source.include?("action: run_widget_handoff_tool") &&
    side_panel_source.include?("recommended_tool: \\(action.tool)") &&
    side_panel_source.include?("recommended_arguments: \\(action.displayArguments)") &&
    side_panel_source.include?("handoff_key: \\(action.key)") &&
    side_panel_source.include?("handoff_tool: \\(action.tool)") &&
    side_panel_source.include?("handoff_arguments: \\(action.displayArguments)") &&
    side_panel_source.include?("source: widget_side_panel_recommended_action") &&
    side_panel_source.include?("source: widget_side_panel_handoff_action") &&
    side_panel_source.include?(".help(presentation.help)"),
  "media task rows link back to short drama anchors" =>
    short_drama_source.include?("struct AgentShortDramaTaskAnchor") &&
    short_drama_source.include?("func anchor(for task: AgentMediaTask) -> AgentShortDramaTaskAnchor?") &&
    media_tasks_source.include?("appState.agentShortDramaStore.anchor(for: task)") &&
    media_tasks_source.include?("appState.agentShortDramaStore.setActiveProject(id: anchor.projectID)") &&
    media_tasks_source.include?("AgentSidePanelOpenRequest(kind: .shortDrama)") &&
    media_tasks_source.include?("打开对应短剧项目") &&
    media_tasks_source.include?("appendShortDramaAnchorContextToChat(anchor: anchor)") &&
    media_tasks_source.include?("<media-task-short-drama-anchor>") &&
    media_tasks_source.include?("action: inspect_media_task_short_drama_anchor") &&
    media_tasks_source.include?("open_scope_tool: short_drama_open_media_tasks") &&
    media_tasks_source.include?("shortDramaAnchorScopeArguments(anchor: anchor)") &&
    media_tasks_source.include?("发送短剧锚点上下文到聊天"),
  "media task rows can send task context to chat" =>
    media_tasks_source.include?("appendTaskContextToChat()") &&
    media_tasks_source.include?("AgentMediaTaskChatHandoff.appendTaskContext(task: task, appState: appState)") &&
    media_tasks_source.include?("发送任务上下文到聊天") &&
    media_task_handoff_source.include?("请基于这个媒体任务继续处理") &&
    media_task_handoff_source.include?("任务句柄：\\(task.displayHandle)") &&
    media_task_handoff_source.include?("状态 URL：\\(statusURL)") &&
    media_task_handoff_source.include?("取消 URL：\\(cancelURL)") &&
    media_task_handoff_source.include?("状态 endpoint suffix") &&
    media_task_handoff_source.include?("取消 endpoint suffix") &&
    media_task_handoff_source.include?("<short-drama-media-task-review-actions>") &&
    media_task_handoff_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    media_task_handoff_source.include?("open_review_tasks_arguments: \\(baseArguments), scope=review_item, review_item_id=\\(reviewItemID)") &&
    media_task_handoff_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    media_task_handoff_source.include?("resolve_review_arguments: \\(baseArguments), item_id=\\(reviewItemID)") &&
    media_task_handoff_source.include?("<media-task-active-actions>") &&
    media_task_handoff_source.include?("mediaTaskActiveActionLines(task: task)") &&
    media_task_handoff_source.include?("refresh_scope_tool: short_drama_refresh_media_tasks") &&
    media_task_handoff_source.include?("refresh_scope_arguments: \\(scopeArguments)") &&
    media_task_handoff_source.include?("poll_tool: replicate_poll_prediction") &&
    media_task_handoff_source.include?("cancel_tool: replicate_cancel_prediction") &&
    media_task_handoff_source.include?("poll_tool: some_im_poll_media_task") &&
    media_task_handoff_source.include?("cancel_tool: some_im_cancel_media_task") &&
    media_task_handoff_source.include?("private static func mediaTaskScopeArguments(task: AgentMediaTask) -> String") &&
    media_task_handoff_source.include?("<media-task-completed-artifact-actions>") &&
    media_task_handoff_source.include?("completedArtifactActionLines(task: task)") &&
    media_task_handoff_source.include?("static func hasCompletedImageArtifact(_ task: AgentMediaTask)") &&
    media_task_handoff_source.include?("static func hasCompletedVideoArtifact(_ task: AgentMediaTask)") &&
    media_task_handoff_source.include?("static func activeTaskScopeSummaryLine(task: AgentMediaTask) -> String?") &&
    media_task_handoff_source.include?("poll_tool=replicate_poll_prediction") &&
    media_task_handoff_source.include?("cancel_tool=some_im_cancel_media_task") &&
    media_task_handoff_source.include?("static func completedImageScopeSummaryLine(task: AgentMediaTask) -> String?") &&
    media_task_handoff_source.include?("static func completedVideoScopeSummaryLine(task: AgentMediaTask) -> String?") &&
    media_task_handoff_source.include?("video_action=continue_from_completed_video_artifact") &&
    media_task_handoff_source.include?("let reviewSuffix = reviewItemID.map { \", review_item_id=\\($0)\" } ?? \"\"") &&
    media_task_handoff_source.include?("select_primary_tool=short_drama_select_shot_artifact") &&
    media_task_handoff_source.include?("select_primary_arguments=\\(artifactArguments)") &&
    media_task_handoff_source.include?("video_from_image_tool=generate_video_from_image") &&
    media_task_handoff_source.include?("video_from_image_arguments=\\(imageArguments)") &&
    media_task_handoff_source.include?("open_asset_tasks_tool=short_drama_open_media_tasks") &&
    media_task_handoff_source.include?("open_asset_tasks_arguments=\\(assetTaskArguments)") &&
    media_task_handoff_source.include?("refresh_asset_tasks_tool=short_drama_refresh_media_tasks") &&
    media_task_handoff_source.include?("refresh_asset_tasks_arguments=\\(assetTaskArguments)") &&
    media_task_handoff_source.include?("generate_asset_reference_tool=short_drama_generate_asset_media") &&
    media_task_handoff_source.include?("generate_asset_reference_arguments=\\(generateAssetArguments)") &&
    media_task_handoff_source.include?("attach_reference_tool=short_drama_attach_asset_reference_image") &&
    media_task_handoff_source.include?("attach_reference_arguments=\\(assetArguments)") &&
    media_task_handoff_source.include?("image_choice_tool: short_drama_show_image_choice_widget") &&
    media_task_handoff_source.include?("let reviewSuffix = reviewItemID.map { \", review_item_id=\\($0)\" } ?? \"\"") &&
    media_task_handoff_source.include?("image_choice_arguments: \\(choiceArguments)") &&
    media_task_handoff_source.include?("select_primary_tool: short_drama_select_shot_artifact") &&
    media_task_handoff_source.include?("select_primary_arguments: \\(artifactArguments)") &&
    media_task_handoff_source.include?("video_from_image_tool: generate_video_from_image") &&
    media_task_handoff_source.include?("video_from_image_arguments: \\(imageArguments)") &&
    media_task_handoff_source.include?("edit_tool: short_drama_open_image_editor") &&
    media_task_handoff_source.include?("edit_arguments: \\(artifactArguments), operation=inpaint") &&
    media_task_handoff_source.include?("erase_tool: short_drama_open_image_editor") &&
    media_task_handoff_source.include?("erase_arguments: \\(artifactArguments), operation=erase") &&
    media_task_handoff_source.include?("upscale_tool: short_drama_upscale_shot_artifact") &&
    media_task_handoff_source.include?("upscale_arguments: \\(artifactArguments)") &&
    media_task_handoff_source.include?("<media-task-completed-video-actions>") &&
    media_task_handoff_source.include?("action: continue_from_completed_video_artifact") &&
    media_task_handoff_source.include?("video_path: \\(videoPath)") &&
    media_task_handoff_source.include?("open_shot_tasks_tool: short_drama_open_media_tasks") &&
    media_task_handoff_source.include?("refresh_shot_tasks_tool: short_drama_refresh_media_tasks") &&
    media_task_handoff_source.include?("storyboard_widget_tool: short_drama_show_storyboard_widget") &&
    media_task_handoff_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    media_task_handoff_source.include?("private static func isVideoArtifact(_ artifact: AgentMediaArtifact) -> Bool") &&
    media_task_handoff_source.include?("open_asset_tasks_tool: short_drama_open_media_tasks") &&
    media_task_handoff_source.include?("open_asset_tasks_arguments: \\(assetTaskArguments)") &&
    media_task_handoff_source.include?("refresh_asset_tasks_tool: short_drama_refresh_media_tasks") &&
    media_task_handoff_source.include?("refresh_asset_tasks_arguments: \\(assetTaskArguments)") &&
    media_task_handoff_source.include?("generate_asset_reference_tool: short_drama_generate_asset_media") &&
    media_task_handoff_source.include?("generate_asset_reference_arguments: \\(generateAssetArguments)") &&
    media_task_handoff_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    media_task_handoff_source.include?("attach_reference_arguments: \\(assetArguments)") &&
    media_task_handoff_source.include?("edit_tool: open_image_editor") &&
    media_task_handoff_source.include?("upscale_tool: upscale_image") &&
    media_task_handoff_source.include?("mediaTaskRetryActionLines(task: task)") &&
    media_task_handoff_source.include?("static func appendRetryContext(task: AgentMediaTask, appState: AppState)") &&
    media_task_handoff_source.include?("<short-drama-media-task-retry>") &&
    media_task_handoff_source.include?("retry_tool: short_drama_retry_media_task") &&
    media_task_handoff_source.include?("retry_arguments: task_id=\\(task.displayHandle)") &&
    media_task_handoff_source.include?("<media-task-failure-actions>") &&
    media_task_handoff_source.include?("recover_failed_media_task") &&
    media_task_handoff_source.include?("script_recovery_note: 这是制作包 manifest/Ruby/Skill 外部脚本失败项") &&
    media_task_handoff_source.include?("gap_report_follow_up: 若这个任务仍缺主图/视频") &&
    media_task_handoff_source.include?("short_drama_generate_batch_media(target_filter=missing)") &&
    media_task_handoff_source.include?("manual_recovery_note: 当前 provider 缺少可自动重试的本地参数") &&
    media_task_handoff_source.include?("private static func isManifestScriptFailure(_ task: AgentMediaTask) -> Bool") &&
    media_task_handoff_source.include?("message.contains(\"Manifest 外部脚本失败\")") &&
    media_task_handoff_source.include?("static func failedTaskScopeSummaryLine(task: AgentMediaTask) -> String?") &&
    media_task_handoff_source.include?("script_recovery_note=rerun ruby-media-script-template.rb with WILLDEEP_MEDIA_ONLY_FAILED=1") &&
    media_task_handoff_source.include?("retry_failed_scope_dry_run_arguments=\\(mediaTaskScopeArguments(task: task)), dry_run=true") &&
    media_task_handoff_source.include?("static func isRetryableShortDramaTask(_ task: AgentMediaTask)") &&
    media_task_handoff_source.include?("appState.agentInput += \"\\n\\n\\(prompt)\"") &&
    media_task_handoff_source.include?("appState.agentComposerFocusRevision += 1"),
  "task monitor rail can send media task context to chat" =>
    task_monitor_source.include?("private struct AgentRailMediaTaskRow: View") &&
    task_monitor_source.include?("@EnvironmentObject var appState: AppState") &&
    task_monitor_source.include?("openMediaTaskPanel(for: task)") &&
    task_monitor_source.include?("openFocusedMediaTaskPanel()") &&
    task_monitor_source.include?("visibleMediaTasks.first(where: \\.needsAttention)") &&
    task_monitor_source.include?("visibleMediaTasks.first(where: \\.isActive)") &&
    task_monitor_source.include?("recentCompletedMediaTasks.first") &&
    task_monitor_source.include?("appendFocusedMediaTaskScopeToChat()") &&
    task_monitor_source.include?("inspect_media_task_scope_from_rail") &&
    task_monitor_source.include?("<media-task-scope-status>") &&
    task_monitor_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    task_monitor_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    task_monitor_source.include?("retry_failed_tool: short_drama_retry_failed_media_tasks") &&
    task_monitor_source.include?("retry_failed_dry_run_arguments: \\(arguments), dry_run=true") &&
    task_monitor_source.include?("retryable_failed_tasks:") &&
    task_monitor_source.include?("failed.filter(AgentMediaTaskChatHandoff.isRetryableShortDramaTask)") &&
    task_monitor_source.include?("let completedImageTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedImageArtifact)") &&
    task_monitor_source.include?("let completedVideoTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedVideoArtifact)") &&
    task_monitor_source.include?("completed_image_task_count: \\(completedImageTasks.count)") &&
    task_monitor_source.include?("completed_video_task_count: \\(completedVideoTasks.count)") &&
    task_monitor_source.include?("active_task_actions:") &&
    task_monitor_source.include?("AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine") &&
    task_monitor_source.include?("active_task_follow_up: active_task_actions 已包含可直接调用的 provider 轮询/取消参数") &&
    task_monitor_source.include?("completed_image_tasks:") &&
    task_monitor_source.include?("AgentMediaTaskChatHandoff.completedImageScopeSummaryLine") &&
    task_monitor_source.include?("completed_image_follow_up: completed_image_tasks 已包含可直接调用的后续工具参数") &&
    task_monitor_source.include?("completed_video_tasks:") &&
    task_monitor_source.include?("AgentMediaTaskChatHandoff.completedVideoScopeSummaryLine") &&
    task_monitor_source.include?("completed_video_follow_up: completed_video_tasks 已包含可直接调用的审片、分镜板和任务范围参数") &&
    media_task_handoff_source.include?("imagePaths.count > 1") &&
    media_task_handoff_source.include?("image_choice_arguments=project_id=\\(projectID), episode_id=\\(episodeID), shot_id=\\(shotID)\\(reviewSuffix)") &&
    task_monitor_source.include?("appendPromptToChat(lines.joined(separator: \"\\n\"), duplicateGuard: \"<media-task-scope-status>\")") &&
    task_monitor_source.include?("appState.agentComposerFocusRevision += 1") &&
    task_monitor_source.include?("appState.agentMediaTaskPanelScope = scope") &&
    task_monitor_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)") &&
    task_monitor_source.include?("reviewItemID: reviewItemID") &&
    task_monitor_source.include?("shotID: shotID") &&
    task_monitor_source.include?("assetKind: assetKind") &&
    task_monitor_source.include?("assetID: assetID") &&
    task_monitor_source.include?("AgentMediaTaskChatHandoff.appendTaskContext(task: task, appState: appState)") &&
    task_monitor_source.include?("if task.isActive") &&
    task_monitor_source.include?("Image(systemName: \"arrow.clockwise\")") &&
    task_monitor_source.include?("立即刷新这个媒体任务") &&
    task_monitor_source.include?("Image(systemName: \"xmark.circle\")") &&
    task_monitor_source.include?("取消这个媒体任务") &&
    task_monitor_source.include?("private func refreshTask()") &&
    task_monitor_source.include?("await appState.agentMediaTaskPoller.refreshNow") &&
    task_monitor_source.include?("private func cancelTask()") &&
    task_monitor_source.include?("await appState.agentMediaTaskPoller.cancel(") &&
    task_monitor_source.include?("Image(systemName: \"text.bubble\")") &&
    task_monitor_source.include?("发送任务上下文到聊天") &&
    task_monitor_source.include?("打开媒体任务侧栏，或用气泡按钮发送任务上下文到聊天"),
  "media task rows can continue storyboard images to video" =>
    media_tasks_source.include?("private var canContinueShotToVideo: Bool") &&
    media_tasks_source.include?("appendShotVideoContinuationToChat()") &&
    media_tasks_source.include?("Image(systemName: \"film.stack\")") &&
    media_tasks_source.include?("<short-drama-media-follow-up>") &&
    media_tasks_source.include?("action: generate_video_from_media_task") &&
    media_tasks_source.include?("selected_artifact_path: \\(primaryImage)") &&
    media_tasks_source.include?("lines.append(\"review_item_id: \\(reviewItemID)\")") &&
    media_tasks_source.include?("如果下面有 review_item_id，也必须一并传入") &&
    media_tasks_source.include?("short_drama_show_image_choice_widget") &&
    media_tasks_source.include?("short_drama_select_shot_artifact") &&
    media_tasks_source.include?("generate_video_from_image") &&
    media_tasks_source.include?("image_path 使用 selected_artifact_path"),
  "media task thumbnails can select short-drama primary image" =>
    media_artifact_views_source.include?("struct AgentMediaArtifactThumbnail: View") &&
    media_artifact_views_source.include?("private var shotAnchor: (projectID: UUID?, episodeID: UUID?, shotID: UUID)?") &&
    media_artifact_views_source.include?("private var assetAnchor: (projectID: UUID, assetKind: String, assetID: UUID)?") &&
    media_artifact_views_source.include?("private var canSelectAsShotPrimary: Bool") &&
    media_artifact_views_source.include?("private var canAttachAsAssetReference: Bool") &&
    media_artifact_views_source.include?("private var isSelectedShotPrimary: Bool") &&
    media_artifact_views_source.include?("private var isSelectedAssetReference: Bool") &&
    media_artifact_views_source.include?("selectAsShotPrimary()") &&
    media_artifact_views_source.include?("attachAsAssetReference()") &&
    media_artifact_views_source.include?("appState.agentShortDramaStore.selectShotArtifact(") &&
    media_artifact_views_source.include?("appState.agentShortDramaStore.attachReferenceImages(") &&
    media_artifact_views_source.include?("artifactPath: artifact.filePath") &&
    media_artifact_views_source.include?("appendPrimarySelectionFollowUp(anchor: anchor)") &&
    media_artifact_views_source.include?("appendAssetReferenceFollowUp(anchor: anchor)") &&
    media_artifact_views_source.include?("<short-drama-primary-artifact-selected>") &&
    media_artifact_views_source.include?("<short-drama-asset-reference-attached>") &&
    media_artifact_views_source.include?("action: attach_asset_reference_from_media_task") &&
    media_artifact_views_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    media_artifact_views_source.include?("generate_asset_reference_tool: short_drama_generate_asset_media") &&
    media_artifact_views_source.include?("edit_reference_tool: open_image_editor") &&
    media_artifact_views_source.include?("upscale_reference_tool: upscale_image") &&
    media_artifact_views_source.include?("video_from_image_arguments: image_path=\\(artifact.filePath)") &&
    media_artifact_views_source.include?("resolve_review_arguments: project_id=\\(projectValue), episode_id=\\(episodeID.uuidString), shot_id=\\(anchor.shotID.uuidString), item_id=\\(reviewItemID)") &&
    media_artifact_views_source.include?("appState.agentComposerFocusRevision += 1") &&
    media_artifact_views_source.include?("appState.agentShortDramaStore.setActiveProject(id: projectID)") &&
    media_artifact_views_source.include?("AgentSidePanelOpenRequest(kind: .shortDrama)") &&
    media_artifact_views_source.include?("设为分镜主图") &&
    media_artifact_views_source.include?("当前分镜主图") &&
    media_artifact_views_source.include?("设为人物/场景参考图") &&
    media_artifact_views_source.include?("已是资产参考图"),
  "media task completion notice carries anchors and uses session card instead of auto-open" =>
    app_state_loop_source.include?("mediaTaskAnchorLines(for: task)") &&
    app_state_loop_source.include?("mediaTaskFollowUpLines(for: task)") &&
    app_state_loop_source.include?("mediaTaskActionLines(for: task)") &&
    app_state_loop_source.include?("mediaTaskPanelScope(for task: AgentMediaTask)") &&
    !app_state_loop_source.include?("finishedMediaTasks.first(where: \\.needsAttention)") &&
    conversation_activity_overlay_source.include?("static func scopedTasks") &&
    conversation_activity_overlay_source.include?("task.runtimeID == runtimeID") &&
    conversation_activity_overlay_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks)") &&
    app_state_loop_source.include?("检查项任务：\\(task.title)") &&
    app_state_loop_source.include?("分镜任务：\\(task.title)") &&
    app_state_loop_source.include?("项目任务：\\(task.title)") &&
    app_state_loop_source.include?("Anchors:") &&
    app_state_loop_source.include?("Suggested follow-up:") &&
    app_state_loop_source.include?("Structured action context:") &&
    app_state_loop_source.include?("<media-task-action>") &&
    app_state_loop_source.include?("Status URL: \\(statusURL)") &&
    app_state_loop_source.include?("Cancel URL: \\(cancelURL)") &&
    app_state_loop_source.include?("Source image: \\(sourceImagePath)") &&
    app_state_loop_source.include?("Mask: \\(maskPath)") &&
    app_state_loop_source.include?("status_url: \\(statusURL)") &&
    app_state_loop_source.include?("cancel_url: \\(cancelURL)") &&
    app_state_loop_source.include?("status_endpoint_suffix: \\(statusEndpointSuffix)") &&
    app_state_loop_source.include?("cancel_endpoint_suffix: \\(cancelEndpointSuffix)") &&
    app_state_loop_source.include?("source_image_path: \\(sourceImagePath)") &&
    app_state_loop_source.include?("mask_path: \\(maskPath)") &&
    app_state_loop_source.include?("project_id: \\(projectID)") &&
    app_state_loop_source.include?("episode_id: \\(episodeID)") &&
    app_state_loop_source.include?("shot_id: \\(shotID)") &&
    app_state_loop_source.include?("asset_kind: \\(assetKind)") &&
    app_state_loop_source.include?("mediaTaskNoticeScopeArguments(") &&
    app_state_loop_source.include?("open_scope_tasks_tool: short_drama_open_media_tasks") &&
    app_state_loop_source.include?("open_scope_tasks_arguments: \\(scopeArguments)") &&
    app_state_loop_source.include?("refresh_scope_tasks_tool: short_drama_refresh_media_tasks") &&
    app_state_loop_source.include?("refresh_scope_tasks_arguments: \\(scopeArguments)") &&
    app_state_loop_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    app_state_loop_source.include?("scope=shot") &&
    app_state_loop_source.include?("scope=asset") &&
    app_state_loop_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    app_state_loop_source.include?("scope=review_item, review_item_id=\\(reviewItemID)") &&
    app_state_loop_source.include?("To inspect all tasks for the same review item") &&
    app_state_loop_source.include?("short_drama_show_image_choice_widget") &&
    app_state_loop_source.include?("candidate_arguments: project_id=\\(projectID), episode_id=\\(episodeID), shot_id=\\(shotID)\\(reviewSuffix)") &&
    app_state_loop_source.include?("let candidateImagePaths = task.artifacts.filter(Self.isImageArtifact).map(\\.filePath)") &&
    app_state_loop_source.include?("static func isImageArtifact(_ artifact: AgentMediaArtifact)") &&
    app_state_loop_source.include?("candidate_image_paths: \\(candidateImages)") &&
    app_state_loop_source.include?("candidate_preview_tool: show_image_choice_widget") &&
    app_state_loop_source.include?("candidate_preview_arguments: image_paths=\\(candidateImages), project_id=\\(projectID), episode_id=\\(episodeID), shot_id=\\(shotID)\\(reviewSuffix)") &&
    app_state_loop_source.include?("short_drama_select_shot_artifact") &&
    app_state_loop_source.include?("task.artifacts.first(where: Self.isImageArtifact)") &&
    app_state_loop_source.include?("completed_video_path: \\(videoArtifact.filePath)") &&
    app_state_loop_source.include?("completed_video_action: continue_from_completed_video_artifact") &&
    app_state_loop_source.include?("storyboard_widget_tool: short_drama_show_storyboard_widget") &&
    app_state_loop_source.include?("This completed video is available at") &&
    app_state_loop_source.include?("static func isVideoArtifact(_ artifact: AgentMediaArtifact)") &&
    app_state_loop_source.include?("generate_video_from_image") &&
    app_state_loop_source.include?("video_from_image_tool: generate_video_from_image") &&
    app_state_loop_source.include?("short_drama_generate_shot_media") &&
    app_state_loop_source.include?("short_drama_open_image_editor") &&
    app_state_loop_source.include?("edit_arguments: \\(artifactArguments), operation=inpaint") &&
    app_state_loop_source.include?("erase_tool: short_drama_open_image_editor") &&
    app_state_loop_source.include?("erase_arguments: \\(artifactArguments), operation=erase") &&
    app_state_loop_source.include?("short_drama_upscale_shot_artifact") &&
    app_state_loop_source.include?("upscale_arguments: \\(artifactArguments)") &&
    app_state_loop_source.include?("short_drama_attach_asset_reference_image") &&
    app_state_loop_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    app_state_loop_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    app_state_loop_source.include?("refresh_tasks_arguments: project_id=\\(projectID), scope=asset, asset_kind=\\(assetKind), asset_id=\\(assetID)") &&
    app_state_loop_source.include?("generate_asset_reference_tool: short_drama_generate_asset_media") &&
    app_state_loop_source.include?("generate_asset_reference_arguments: project_id=\\(projectID), asset_kind=\\(assetKind), asset_id=\\(assetID)") &&
    app_state_loop_source.include?("edit_arguments: image_path=\\(artifact.filePath), operation=inpaint, project_id=\\(projectID), asset_kind=\\(assetKind), asset_id=\\(assetID)") &&
    app_state_loop_source.include?("erase_arguments: image_path=\\(artifact.filePath), operation=erase, project_id=\\(projectID), asset_kind=\\(assetKind), asset_id=\\(assetID)") &&
    app_state_loop_source.include?("upscale_arguments: image_path=\\(artifact.filePath), project_id=\\(projectID), asset_kind=\\(assetKind), asset_id=\\(assetID)") &&
    app_state_loop_source.include?("To refine this asset reference") &&
    app_state_loop_source.include?("candidate_tool: show_image_choice_widget") &&
    app_state_loop_source.include?("edit_tool: open_image_editor") &&
    app_state_loop_source.include?("erase_tool: open_image_editor") &&
    app_state_loop_source.include?("upscale_tool: upscale_image") &&
    app_state_loop_source.include?("retry_tool: short_drama_retry_media_task") &&
    app_state_loop_source.include?("artifact_paths:"),
  "image editor supports inverted masks" =>
    image_edit_source.include?("@State private var invertMask = false") &&
    image_edit_source.include?("Toggle(L10n.AgentImageEditor.invertToggle, isOn: $invertMask)") &&
    image_edit_source.include?("background: invertMask ? .white : .black") &&
    image_edit_source.include?("CGColor(gray: invertMask ? 0 : 1, alpha: 1)") &&
    image_edit_source.include?("mask-inverted"),
  "image editor supports multi-rect masks" =>
    image_edit_source.include?("@State private var maskRects: [CGRect] = []") &&
    image_edit_source.include?("maskRects.append(rect)") &&
    image_edit_source.include?("maskRects.popLast()") &&
    image_edit_source.include?("private func rectsForMask(imageInfo: ImageInfo) -> [CGRect]") &&
    image_edit_source.include?("for rect in pixelRects") &&
    image_edit_source.include?("L10n.AgentImageEditor.exportedMaskInverted(\"\\(partCount)\", eraseSuffix + seedSuffix, output.path)") &&
    image_edit_source.include?("L10n.AgentImageEditor.exportedMask(\"\\(partCount)\", eraseSuffix + seedSuffix, output.path)"),
  "image editor supports brush masks" =>
    image_edit_source.include?("@State private var maskStrokes: [MaskStroke] = []") &&
    image_edit_source.include?("@State private var maskEraseStrokes: [MaskStroke] = []") &&
    image_edit_source.include?("@State private var maskTool: MaskTool = .rectangle") &&
    image_edit_source.include?("@State private var brushPaintMode: BrushPaintMode = .add") &&
    image_edit_source.include?("@State private var brushSize: Double = 28") &&
    image_edit_source.include?("Picker(L10n.AgentImageEditor.maskToolPicker, selection: $maskTool)") &&
    image_edit_source.include?("Picker(L10n.AgentImageEditor.brushModePicker, selection: $brushPaintMode)") &&
    image_edit_source.include?("Slider(value: $brushSize") &&
    image_edit_source.include?("activeStroke = MaskStroke") &&
    image_edit_source.include?("maskEraseStrokes.append(stroke)") &&
    image_edit_source.include?("private func strokesForMask(imageInfo: ImageInfo) -> [PixelMaskStroke]") &&
    image_edit_source.include?("private func eraseStrokesForMask(imageInfo: ImageInfo) -> [PixelMaskStroke]") &&
    image_edit_source.include?("context.setLineCap(.round)") &&
    image_edit_source.include?("context.setFillColor(CGColor(gray: invertMask ? 1 : 0, alpha: 1))") &&
    image_edit_source.include?("private enum BrushPaintMode") &&
    image_edit_source.include?("case subtract") &&
    image_edit_source.include?("L10n.AgentImageEditor.brushModeEraser") &&
    image_edit_source.include?("private struct PixelMaskStroke") &&
    image_edit_source.include?("L10n.AgentImageEditor.summaryFull("),
  "image editor can reopen an existing mask as a seed layer" =>
    app_state_source.include?("agentImageEditorMaskURL") &&
    registry_source.include?('AgentToolParameter(name: "mask_path", type: .string, description: "Optional existing local PNG mask to load as the editor') &&
    image_edit_source.include?("@State private var seedMaskInfo: ImageInfo?") &&
    image_edit_source.include?("reloadSeedMask()") &&
    image_edit_source.include?("context.draw(") &&
    image_edit_source.include?("L10n.AgentImageEditor.exportedSeedSuffix") &&
    image_edit_source.include?("seedMaskInfo != nil || !maskRects.isEmpty") &&
    media_tools_source.include?("appState.agentImageEditorMaskURL = maskURL") &&
    image_tools_source.include?("appState.agentImageEditorMaskURL = maskPath.map") &&
    app_state_loop_source.include?("reopen_editor_tool: short_drama_open_image_editor") &&
    app_state_loop_source.include?("mask_path=\\(maskPath)") &&
    media_task_handoff_source.include?("<image-edit-reopen-action>") &&
    media_task_handoff_source.include?("reopen_editor_arguments: \\(arguments)"),
  "image editor surfaces Replicate configuration issues" =>
    image_edit_source.include?("private var replicateConfigurationIssue: String?") &&
    image_edit_source.include?("ReplicateIntegrationStore.isConfigured") &&
    image_edit_source.include?("L10n.AgentImageEditor.replicateNeedToken") &&
    image_edit_source.include?("L10n.AgentImageEditor.replicateNeedInpaintVersion") &&
    image_edit_source.include?("L10n.AgentImageEditor.replicateNeedEraseVersion") &&
    image_edit_source.include?("EditorSettingsNavigation.shared.open(.replicate, appState: appState)") &&
    image_edit_source.include?("L10n.AgentImageEditor.openReplicateSettings") &&
    image_edit_source.include?("return replicateConfigurationIssue == nil"),
}
end
