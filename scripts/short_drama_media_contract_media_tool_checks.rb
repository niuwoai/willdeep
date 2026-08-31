# frozen_string_literal: true

# short_drama_media_contract_media_tool_checks.rb — 短剧与通用媒体工具这一组
# 契约断言：结构交给聊天的接力块、短剧图片 / 批量媒体工具、媒体任务重试与
# 蒙版接力，以及通用生图 / 蒙版编辑 / 放大 / 选图工具的注册、分发与后续动作。
#
# 从 short_drama_media_contract_test.rb 拆出来：那个脚本 2995 行，离
# scripts/complexity_guard.rb 的 hard_limit=3000 只差 5 行。断言体逐行原样
# 搬运，缩进刻意保持与拆分前一致（不额外缩进一层），方便和历史 diff 逐行对照。

def short_drama_media_contract_media_tool_checks(
  tools_source:,
  production_exporter_source:,
  image_tools_source:,
  batch_tools_source:,
  short_drama_dispatcher_source:,
  media_task_tools_source:,
  dispatch_source:,
  media_tools_source:,
  short_drama_source:,
  asset_views_source:,
  media_tasks_source:,
  media_task_handoff_source:,
  media_artifact_views_source:,
  image_edit_source:,
  storyboard_widget_source:,
  import_source:,
  registry_source:,
  side_panel_source:,
  app_state_loop_source:,
  widget_registry_source:
)
{
  "storyboard widget builder split from side panel" =>
    storyboard_widget_source.include?("enum AgentShortDramaStoryboardWidgetBuilder") &&
    storyboard_widget_source.include?("<short-drama-widget-action>") &&
    !short_drama_source.include?("enum AgentShortDramaStoryboardWidgetBuilder"),
  "widget side panel keeps selectable skill-generated widget history" =>
    widget_registry_source.include?("@Published private var historyByRuntime") &&
    widget_registry_source.include?("private let historyLimit = 20") &&
    widget_registry_source.include?("func widgets(forRuntime runtimeID: UUID?) -> [AgentWidget]") &&
    widget_registry_source.include?("func remember(_ widget: AgentWidget, forRuntime runtimeID: UUID)") &&
    side_panel_source.include?("@State private var selectedWidgetID: UUID?") &&
    side_panel_source.include?("private var widgets: [AgentWidget]") &&
    side_panel_source.include?("widgetRegistry.widgets(forRuntime: runtime?.id)") &&
    side_panel_source.include?("最近网页组件") &&
    side_panel_source.include?("selectedWidgetID = widget.id") &&
    side_panel_source.include?("AgentWidgetCardView(widget: widget)") &&
    side_panel_source.include?("Label(\"发送到聊天\", systemImage: \"text.bubble\")") &&
    side_panel_source.include?("private func appendWidgetContextToChat(_ widget: AgentWidget)") &&
    side_panel_source.include?("<widget-panel-context>") &&
    side_panel_source.include?("action: inspect_widget_from_side_panel") &&
    side_panel_source.include?("widget_id: \\(widget.id.uuidString)") &&
    side_panel_source.include?("widget_title: \\(widget.title)") &&
    side_panel_source.include?("source: widget_side_panel") &&
    side_panel_source.include?("按钮消息会附带 <widget-action> 来源上下文") &&
    side_panel_source.include?("appState.agentComposerFocusRevision += 1"),
  "short drama side panel can hand project structure to chat" =>
    short_drama_source.include?("func appendProjectContextToChat(_ project: AgentShortDramaProject)") &&
    short_drama_source.include?("func reviewQueueLines(project: AgentShortDramaProject, episodes: [AgentShortDramaEpisode], limit: Int) -> [String]") &&
    short_drama_source.include?("func mediaGapQueueLines(episodes: [AgentShortDramaEpisode], limit: Int) -> [String]") &&
    short_drama_source.include?("func mediaTaskQueueLines(tasks: [AgentMediaTask], limit: Int) -> [String]") &&
    short_drama_source.include?("func missingAssetReferenceQueueLines(project: AgentShortDramaProject, limit: Int) -> [String]") &&
    short_drama_source.include?("Image(systemName: \"text.bubble\")") &&
    short_drama_source.include?("发送项目结构到聊天") &&
    short_drama_source.include?("<short-drama-project-context>") &&
    short_drama_source.include?("action: inspect_short_drama_project_from_side_panel") &&
    short_drama_source.include?("episode_count: \\(summary.episodeCount)") &&
    short_drama_source.include?("shot_count: \\(summary.shotCount)") &&
    short_drama_source.include?("character_count: \\(summary.characterCount)") &&
    short_drama_source.include?("scene_count: \\(summary.sceneCount)") &&
    short_drama_source.include?("missing_image_count: \\(summary.missingImageCount)") &&
    short_drama_source.include?("missing_video_count: \\(summary.missingVideoCount)") &&
    short_drama_source.include?("productionGapActionStrip(") &&
    short_drama_source.include?("func productionGapActionStrip(") &&
    short_drama_source.include?("func productionGapParts(") &&
    short_drama_source.include?("Text(\"制作缺口\")") &&
    short_drama_source.include?("缺主图 \\(missingImages)") &&
    short_drama_source.include?("缺视频 \\(missingVideos)") &&
    short_drama_source.include?("检查项 \\(openReviews)") &&
    short_drama_source.include?("缺参考 \\(missingAssetReferences)") &&
    short_drama_source.include?("把缺主图队列和批量生成建议发送到聊天") &&
    short_drama_source.include?("直接提交缺失的人物/场景参考图任务") &&
    short_drama_source.include?("openMediaTasks: { openMediaTasksPanel(scope: mediaTaskScope(project: project)) }") &&
    short_drama_source.include?("generateAssetReferences: { submitMissingAssetReferences(project: project) }") &&
    short_drama_source.include?("openMediaTasksPanel(scope: mediaTaskScope(project: project))") &&
    short_drama_source.include?("查看全剧媒体任务") &&
    short_drama_source.include?("storyboard_widget_tool: short_drama_show_storyboard_widget") &&
    short_drama_source.include?("open_project_tasks_tool: short_drama_open_media_tasks") &&
    short_drama_source.include?("batch_image_dry_run_tool: short_drama_generate_batch_media") &&
    short_drama_source.include?("missing_image_batch_dry_run_arguments: project_id=\\(project.id.uuidString), kind=image_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("missing_image_batch_submit_arguments: project_id=\\(project.id.uuidString), kind=image_generation, target_filter=missing, dry_run=false") &&
    short_drama_source.include?("missing_video_batch_dry_run_arguments: project_id=\\(project.id.uuidString), kind=video_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("missing_video_batch_submit_arguments: project_id=\\(project.id.uuidString), kind=video_generation, target_filter=missing, dry_run=false") &&
    short_drama_source.include?("export_package_tool: short_drama_export_production_package") &&
    short_drama_source.include?("review_queue_tool: short_drama_open_media_tasks") &&
    short_drama_source.include?("review_queue_arguments: project_id=\\(project.id.uuidString), scope=project") &&
    short_drama_source.include?("review_queue_item: episode_id=\\(episode.id.uuidString)") &&
    short_drama_source.include?("media_gap_queue_tool: short_drama_generate_batch_media") &&
    short_drama_source.include?("media_gap_image_dry_run_arguments: project_id=\\(project.id.uuidString), kind=image_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("media_gap_video_dry_run_arguments: project_id=\\(project.id.uuidString), kind=video_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("missing_image_shot: episode_id=\\(episode.id.uuidString)") &&
    short_drama_source.include?("missing_video_shot: episode_id=\\(episode.id.uuidString)") &&
    short_drama_source.include?("media_task_queue_tool: short_drama_open_media_tasks") &&
    short_drama_source.include?("media_task_queue_arguments: project_id=\\(project.id.uuidString), scope=project") &&
    short_drama_source.include?("refresh_media_task_queue_tool: short_drama_refresh_media_tasks") &&
    short_drama_source.include?("retry_failed_media_task_queue_tool: short_drama_retry_failed_media_tasks") &&
    short_drama_source.include?("media_task_queue_item: task_id=\\(task.displayHandle)") &&
    short_drama_source.include?("provider=\\(task.provider.rawValue)") &&
    short_drama_source.include?("status=\\(task.status.rawValue)") &&
    short_drama_source.include?("private func appendProductionNextActions(") &&
    short_drama_source.include?("production_next_action_count: \\(actions.count)") &&
    short_drama_source.include?("production_next_action_\\(index + 1): \\(action)") &&
    short_drama_source.include?("action=retry_failed_media_tasks") &&
    short_drama_source.include?("action=review_open_items") &&
    short_drama_source.include?("action=generate_missing_images") &&
    short_drama_source.include?("action=generate_missing_videos") &&
    short_drama_source.include?("action=generate_missing_asset_references") &&
    short_drama_source.include?("action=export_or_storyboard_review") &&
    short_drama_source.include?("missing_asset_reference_queue_tool: short_drama_generate_asset_media") &&
    short_drama_source.include?("missing_asset_reference_item: asset_kind=\\(asset.assetKind)") &&
    short_drama_source.include?("generate_asset_reference_dry_run_arguments=project_id=\\(project.id.uuidString), asset_kind=\\(asset.assetKind), asset_id=\\(asset.id.uuidString), dry_run=true") &&
    short_drama_source.include?("generate_asset_reference_arguments=project_id=\\(project.id.uuidString), asset_kind=\\(asset.assetKind), asset_id=\\(asset.id.uuidString), dry_run=false") &&
    short_drama_source.include?("project.episodes.prefix(8)") &&
    short_drama_source.include?("panelScope.input += \"\\n\\n\\(prompt)\"") &&
    short_drama_source.include?("appState.agentComposerFocusRevision += 1"),
  "short drama side panel can hand episode structure to chat" =>
    short_drama_source.include?("func appendEpisodeContextToChat(project: AgentShortDramaProject, episode: AgentShortDramaEpisode)") &&
    short_drama_source.include?("发送本集结构到聊天") &&
    short_drama_source.include?("<short-drama-episode-context>") &&
    short_drama_source.include?("action: inspect_short_drama_episode_from_side_panel") &&
    short_drama_source.include?("episode_id: \\(episode.id.uuidString)") &&
    short_drama_source.include?("episode_order: \\(episode.order)") &&
    short_drama_source.include?("shot_count: \\(summary.shotCount)") &&
    short_drama_source.include?("missing_image_count: \\(summary.missingImageCount)") &&
    short_drama_source.include?("missing_video_count: \\(summary.missingVideoCount)") &&
    short_drama_source.include?("let summary = episodeStructureSummary(episode)") &&
    short_drama_source.include?("let parts = productionGapParts(") &&
    short_drama_source.include?("missingAssetReferences: 0") &&
    short_drama_source.include?("发送本集制作缺口和下一步建议到聊天") &&
    short_drama_source.include?("openMediaTasksPanel(scope: mediaTaskScope(project: project, episode: episode))") &&
    short_drama_source.include?("查看本集媒体任务") &&
    short_drama_source.include?("episode_storyboard_widget_tool: short_drama_show_storyboard_widget") &&
    short_drama_source.include?("open_episode_tasks_tool: short_drama_open_media_tasks") &&
    short_drama_source.include?("batch_episode_image_dry_run_tool: short_drama_generate_batch_media") &&
    short_drama_source.include?("batch_episode_video_dry_run_tool: short_drama_generate_batch_media") &&
    short_drama_source.include?("missing_episode_image_batch_dry_run_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), kind=image_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("missing_episode_image_batch_submit_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), kind=image_generation, target_filter=missing, dry_run=false") &&
    short_drama_source.include?("missing_episode_video_batch_dry_run_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), kind=video_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("missing_episode_video_batch_submit_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), kind=video_generation, target_filter=missing, dry_run=false") &&
    short_drama_source.include?("export_episode_package_tool: short_drama_export_production_package") &&
    short_drama_source.include?("review_queue_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episodeID), scope=episode") &&
    short_drama_source.include?("appendQueues(project: project, episodes: [episode], to: &lines, episodeID: episode.id.uuidString)") &&
    short_drama_source.include?("media_gap_image_dry_run_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episodeID), kind=image_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("media_gap_video_dry_run_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episodeID), kind=video_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("appendQueues(project: project, episodes: [episode], to: &lines, episodeID: episode.id.uuidString)") &&
    short_drama_source.include?("mediaTaskQueueLines(tasks: episodeTasks, limit: 10)") &&
    short_drama_source.include?("refresh_media_task_queue_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), scope=episode") &&
    short_drama_source.include?("retry_failed_media_task_queue_dry_run_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), scope=episode, dry_run=true") &&
    short_drama_source.include?("episodeID: episode.id.uuidString") &&
    short_drama_source.include?("missingAssetReferenceCount: 0") &&
    short_drama_source.include?("episode.shots.prefix(12)") &&
    short_drama_source.include?("has_selected_image=\\(hasImage)") &&
    short_drama_source.include?("has_video=\\(hasVideo)") &&
    short_drama_source.include?("已把本集结构发送到聊天输入框。"),
  "short drama side panel can hand shot structure to chat" =>
    short_drama_source.include?("func appendShotContextToChat(project: AgentShortDramaProject, episode: AgentShortDramaEpisode, shot: AgentShortDramaShot)") &&
    short_drama_source.include?("发送分镜结构到聊天") &&
    short_drama_source.include?("<short-drama-shot-context>") &&
    short_drama_source.include?("action: inspect_short_drama_shot_from_side_panel") &&
    short_drama_source.include?("shot_id: \\(shot.id.uuidString)") &&
    short_drama_source.include?("shot_order: \\(shot.order)") &&
    short_drama_source.include?("shot_status: \\(shot.status.rawValue)") &&
    short_drama_source.include?("openMediaTasksPanel(scope: mediaTaskScope(project: project, episode: episode, shot: shot))") &&
    short_drama_source.include?("查看本分镜媒体任务") &&
    short_drama_source.include?("open_shot_tasks_tool: short_drama_open_media_tasks") &&
    short_drama_source.include?("generate_shot_image_tool: short_drama_generate_shot_media") &&
    short_drama_source.include?("generate_shot_image_dry_run_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), kind=image_generation, dry_run=true") &&
    short_drama_source.include?("generate_shot_image_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), kind=image_generation, dry_run=false") &&
    short_drama_source.include?("generate_shot_video_tool: short_drama_generate_shot_media") &&
    short_drama_source.include?("generate_shot_video_dry_run_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), kind=video_generation, dry_run=true") &&
    short_drama_source.include?("generate_shot_video_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), kind=video_generation, dry_run=false") &&
    short_drama_source.include?("image_choice_widget_tool: short_drama_show_image_choice_widget") &&
    short_drama_source.include?("video_from_selected_image_tool: generate_video_from_image") &&
    short_drama_source.include?("edit_selected_image_tool: short_drama_open_image_editor") &&
    short_drama_source.include?("edit_selected_image_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), artifact_path=\\(selectedImagePath), operation=inpaint") &&
    short_drama_source.include?("erase_selected_image_tool: short_drama_open_image_editor") &&
    short_drama_source.include?("erase_selected_image_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), artifact_path=\\(selectedImagePath), operation=erase") &&
    short_drama_source.include?("upscale_selected_image_tool: short_drama_upscale_shot_artifact") &&
    short_drama_source.include?("review_item: id=\\(item.id.uuidString)") &&
    short_drama_source.include?("已把分镜结构发送到聊天输入框。"),
  "short drama side panel can hand asset structure to chat" =>
    asset_views_source.include?("appendContext: @escaping (ShortDramaAssetSummary) -> Void") &&
    asset_views_source.include?("appendContext(item)") &&
    asset_views_source.include?("发送资产结构到聊天") &&
    short_drama_source.include?("appendAssetContextToChat(project: project, asset: item)") &&
    short_drama_source.include?("func appendAssetContextToChat(project: AgentShortDramaProject, asset: ShortDramaAssetSummary)") &&
    short_drama_source.include?("<short-drama-asset-context>") &&
    short_drama_source.include?("action: inspect_short_drama_asset_from_side_panel") &&
    short_drama_source.include?("asset_kind: \\(asset.assetKind)") &&
    short_drama_source.include?("asset_id: \\(asset.id.uuidString)") &&
    short_drama_source.include?("reference_image_count: \\(imageReferences.count)") &&
    short_drama_source.include?("linked_shot_count: \\(linkedShots.count)") &&
    short_drama_source.include?("open_asset_tasks_tool: short_drama_open_media_tasks") &&
    short_drama_source.include?("generate_asset_reference_tool: short_drama_generate_asset_media") &&
    short_drama_source.include?("apply_asset_to_shots_tool: short_drama_update_shot_links") &&
    short_drama_source.include?("unlink_asset_from_shots_tool: short_drama_update_shot_links") &&
    short_drama_source.include?("linkedShotIDArgument") &&
    short_drama_source.include?("linked_shot_ids: \\(linkedShotIDs.joined(separator: \",\"))") &&
    short_drama_source.include?("generate_linked_shot_images_tool: short_drama_generate_batch_media") &&
    short_drama_source.include?("generate_linked_shot_images_dry_run_arguments: project_id=\\(project.id.uuidString)\\(linkedShotIDArgument), kind=image_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("generate_linked_shot_images_submit_arguments: project_id=\\(project.id.uuidString)\\(linkedShotIDArgument), kind=image_generation, target_filter=missing, dry_run=false") &&
    short_drama_source.include?("generate_linked_shot_videos_tool: short_drama_generate_batch_media") &&
    short_drama_source.include?("generate_linked_shot_videos_dry_run_arguments: project_id=\\(project.id.uuidString)\\(linkedShotIDArgument), kind=video_generation, target_filter=missing, dry_run=true") &&
    short_drama_source.include?("append_character_ids=true") &&
    short_drama_source.include?("remove_character_ids=[\\(asset.id.uuidString)]") &&
    short_drama_source.include?("edit_reference_image_tool: open_image_editor") &&
    short_drama_source.include?("erase_reference_image_tool: open_image_editor") &&
    short_drama_source.include?("upscale_reference_image_tool: upscale_image") &&
    short_drama_source.include?("linked_shot: \\($0)") &&
    short_drama_source.include?("已把\\(assetLabel)资产结构发送到聊天输入框。"),
  "short drama side panel can hand review item structure to chat" =>
    short_drama_source.include?("private func stageReviewItemPrompt(") &&
    short_drama_source.include?("<short-drama-review-item-context>") &&
    short_drama_source.include?("action: inspect_short_drama_review_item_from_side_panel") &&
    short_drama_source.include?("review_item_id: \\(item.id.uuidString)") &&
    short_drama_source.include?("review_kind: \\(item.kind.rawValue)") &&
    short_drama_source.include?("review_severity: \\(item.severity.rawValue)") &&
    short_drama_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    short_drama_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    short_drama_source.include?("redraw_tool: short_drama_open_image_editor") &&
    short_drama_source.include?("redraw_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), review_item_id=\\(item.id.uuidString), artifact_path=\\(primaryImagePath), operation=inpaint") &&
    short_drama_source.include?("erase_tool: short_drama_open_image_editor") &&
    short_drama_source.include?("erase_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), review_item_id=\\(item.id.uuidString), artifact_path=\\(primaryImagePath), operation=erase") &&
    short_drama_source.include?("upscale_tool: short_drama_upscale_shot_artifact") &&
    short_drama_source.include?("reshoot_tool: short_drama_generate_shot_media") &&
    short_drama_source.include?("review_item_id=\\(item.id.uuidString)") &&
    short_drama_source.include?("已把检查项结构发送到聊天输入框。"),
  "storyboard widget can open image editor from selected artifact" =>
    storyboard_widget_source.include?("重绘主图") &&
    storyboard_widget_source.include?("擦除主图") &&
    storyboard_widget_source.include?("放大主图") &&
    storyboard_widget_source.include?("选择候选图") &&
    storyboard_widget_source.include?("查看全部任务") &&
    storyboard_widget_source.include?("刷新全部任务") &&
    storyboard_widget_source.include?("private static func reviewItemPrompt(") &&
    storyboard_widget_source.include?("<short-drama-review-item-action>") &&
    storyboard_widget_source.include?("review_item_id: \\(item.id.uuidString)") &&
    storyboard_widget_source.include?("recommended_tool: \\(recommendation.tool)") &&
    storyboard_widget_source.include?("recommended_arguments: \\(recommendation.arguments)") &&
    storyboard_widget_source.include?("review_tasks_tool: short_drama_open_media_tasks") &&
    storyboard_widget_source.include?("review_tasks_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), scope=review_item, review_item_id=\\(item.id.uuidString)") &&
    storyboard_widget_source.include?("refresh_review_tasks_tool: short_drama_refresh_media_tasks") &&
    storyboard_widget_source.include?("refresh_review_tasks_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), scope=review_item, review_item_id=\\(item.id.uuidString)") &&
    storyboard_widget_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    storyboard_widget_source.include?("resolve_review_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), item_id=\\(item.id.uuidString)") &&
    storyboard_widget_source.include?("private static func reviewItemRecommendation(") &&
    storyboard_widget_source.include?("tool: \"short_drama_open_image_editor\"") &&
    storyboard_widget_source.include?("tool: \"short_drama_upscale_shot_artifact\"") &&
    storyboard_widget_source.include?("tool: \"short_drama_generate_shot_media\"") &&
    storyboard_widget_source.include?("tool: \"short_drama_open_media_tasks\"") &&
    storyboard_widget_source.include?("short_drama_open_media_tasks(scope=review_item") &&
    storyboard_widget_source.include?("review_item_id=...") &&
    storyboard_widget_source.include?("action: open_image_editor") &&
    storyboard_widget_source.include?("action: upscale_shot_artifact") &&
    storyboard_widget_source.include?("action: show_image_choice_widget") &&
    registry_source.include?("Optional short-drama review/fix item UUID copied into the image-choice handoff") &&
    tools_source.include?("let reviewItemID = optionalString(arguments[\"review_item_id\"])") &&
    tools_source.include?("Review item id: \\(reviewItemID ?? \"(none)\")") &&
    storyboard_widget_source.include?("reviewItemID: String? = nil") &&
    storyboard_widget_source.include?("review_item_id: \\(reviewItemID)") &&
    storyboard_widget_source.include?("后续媒体任务也必须继续携带") &&
    storyboard_widget_source.include?("post_select_video_tool: generate_video_from_image") &&
    storyboard_widget_source.include?("post_select_video_arguments: \\(imageArguments)") &&
    storyboard_widget_source.include?("post_select_edit_tool: short_drama_open_image_editor") &&
    storyboard_widget_source.include?("post_select_edit_arguments: \\(artifactArguments), operation=inpaint") &&
    storyboard_widget_source.include?("post_select_erase_tool: short_drama_open_image_editor") &&
    storyboard_widget_source.include?("post_select_erase_arguments: \\(artifactArguments), operation=erase") &&
    storyboard_widget_source.include?("post_select_upscale_tool: short_drama_upscale_shot_artifact") &&
    storyboard_widget_source.include?("post_select_upscale_arguments: \\(artifactArguments)") &&
    storyboard_widget_source.include?("post_select_resolve_review_tool: short_drama_resolve_review_item") &&
    storyboard_widget_source.include?("post_select_resolve_review_arguments: \\(baseArguments), item_id=\\(reviewItemID)") &&
    storyboard_widget_source.include?("private static func primaryVideoPath(for shot: AgentShortDramaShot) -> String?") &&
    storyboard_widget_source.include?("private static func videoReviewPrompt(") &&
    storyboard_widget_source.include?("审片视频") &&
    storyboard_widget_source.include?("<short-drama-widget-video-action>") &&
    storyboard_widget_source.include?("action: review_shot_video_artifact") &&
    storyboard_widget_source.include?("video_path: \\(videoPath)") &&
    storyboard_widget_source.include?("open_shot_tasks_tool: short_drama_open_media_tasks") &&
    storyboard_widget_source.include?("storyboard_widget_tool: short_drama_show_storyboard_widget") &&
    storyboard_widget_source.include?('action: "open_media_tasks"') &&
    storyboard_widget_source.include?('action: "refresh_media_tasks"') &&
    storyboard_widget_source.include?("short_drama_open_image_editor") &&
    storyboard_widget_source.include?("short_drama_upscale_shot_artifact") &&
    storyboard_widget_source.include?("short_drama_show_image_choice_widget") &&
    storyboard_widget_source.include?("short_drama_open_media_tasks") &&
    storyboard_widget_source.include?("short_drama_refresh_media_tasks") &&
    storyboard_widget_source.include?("private static func mediaTasksPrompt(") &&
    storyboard_widget_source.include?("private static func refreshMediaTasksPrompt(") &&
    storyboard_widget_source.include?("private static func mediaTaskActionPrompt(") &&
    storyboard_widget_source.include?("private static func projectMediaTasksPrompt(project: AgentShortDramaProject) -> String") &&
    storyboard_widget_source.include?("private static func projectRefreshMediaTasksPrompt(project: AgentShortDramaProject) -> String") &&
    storyboard_widget_source.include?("scope: project") &&
    storyboard_widget_source.include?("scope=project") &&
    storyboard_widget_source.include?("private static func imageChoicePrompt(") &&
    storyboard_widget_source.include?("private static func primaryImagePath(for shot: AgentShortDramaShot) -> String?"),
  "short drama widget can open and refresh scoped media tasks" =>
    registry_source.include?('name: "short_drama_open_media_tasks"') &&
    registry_source.include?('name: "short_drama_refresh_media_tasks"') &&
    short_drama_dispatcher_source.include?('case "short_drama_open_media_tasks"') &&
    short_drama_dispatcher_source.include?('case "short_drama_refresh_media_tasks"') &&
    short_drama_dispatcher_source.include?("AgentShortDramaMediaTaskTools.openMediaTasks") &&
    short_drama_dispatcher_source.include?("AgentShortDramaMediaTaskTools.refreshMediaTasks") &&
    media_task_tools_source.include?("static func openMediaTasks(arguments: [String: AgentJSONValue], context: AgentToolContext)") &&
    media_task_tools_source.include?("static func refreshMediaTasks(arguments: [String: AgentJSONValue], context: AgentToolContext)") &&
    media_task_tools_source.include?("AgentMediaTaskScope(") &&
    media_task_tools_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: resolved.scope)") &&
    media_task_tools_source.include?("appState.agentMediaTaskPanelScope = resolved.scope") &&
    media_task_tools_source.include?("resolved.scope.matches($0)") &&
    media_task_tools_source.include?("scopeKind = \"review_item\"") &&
    media_task_tools_source.include?("reviewItemID: reviewItem.item.id.uuidString") &&
    media_task_tools_source.include?("resolveReviewItem(") &&
    media_task_tools_source.include?("Review item: \\(resolved.reviewItemLabel ?? \"(all)\")") &&
    media_task_tools_source.include?("agentMediaTaskPoller.refreshNow") &&
    registry_source.include?("review_item, or review") &&
    registry_source.include?("Optional review item UUID for scope=review_item") &&
    short_drama_source.include?("list.bullet.rectangle") &&
    short_drama_source.include?("reviewMediaTasks(item: item)") &&
    short_drama_source.include?("tasks: reviewMediaTasks(item: item)") &&
    short_drama_source.include?("查看这个检查项的媒体任务") &&
    short_drama_source.include?("reviewItemID: item.id.uuidString") &&
    storyboard_widget_source.include?('let scope = shot == nil ? "episode" : "shot"') &&
    storyboard_widget_source.include?("scope=\\(scope)"),
  "short drama media generation returns task scope follow-up" =>
    tools_source.include?("mediaSubmissionFollowUp(task: updated, action: \"short_drama_generate_shot_media_follow_up\")") &&
    tools_source.include?("mediaSubmissionFollowUp(task: updated, action: \"short_drama_generate_asset_media_follow_up\")") &&
    tools_source.include?("Short-drama media task dry-run.") &&
    tools_source.include?("Reference image attached to some.im: \\(body[\"image\"] == nil ? \"false\" : \"true\")") &&
    registry_source.include?("validate the shot, prompt, model, endpoint, and optional video reference image without submitting a provider job") &&
    tools_source.include?("Short-drama asset reference media task dry-run.") &&
    tools_source.include?("submit_arguments: \\(submitArguments)") &&
    registry_source.include?("validate the character/scene asset and show the prompt/model/endpoint without submitting a provider job") &&
    tools_source.include?("<short-drama-media-submission-follow-up>") &&
    tools_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    tools_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    tools_source.include?("Cancel URL: \\(task.cancelURL ?? \"(none)\")") &&
    tools_source.include?("image_choice_tool: short_drama_show_image_choice_widget") &&
    tools_source.include?("select_primary_tool: short_drama_select_shot_artifact") &&
    tools_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    tools_source.include?("edit_arguments: \\(assetArguments), image_path=\\(artifact.filePath), operation=inpaint") &&
    tools_source.include?("erase_arguments: \\(assetArguments), image_path=\\(artifact.filePath), operation=erase") &&
    tools_source.include?("upscale_arguments: \\(assetArguments), image_path=\\(artifact.filePath)") &&
    tools_source.include?("video_from_image_tool: generate_video_from_image"),
  "short drama failed media tasks can be retried from stored anchors" =>
    registry_source.include?('name: "short_drama_retry_media_task"') &&
    registry_source.include?('name: "short_drama_retry_failed_media_tasks"') &&
    short_drama_dispatcher_source.include?('case "short_drama_retry_media_task"') &&
    short_drama_dispatcher_source.include?('case "short_drama_retry_failed_media_tasks"') &&
    short_drama_dispatcher_source.include?("AgentShortDramaMediaTaskTools.retryMediaTask") &&
    short_drama_dispatcher_source.include?("AgentShortDramaMediaTaskTools.retryFailedMediaTasks") &&
    media_task_tools_source.include?("static func retryMediaTask(arguments: [String: AgentJSONValue], context: AgentToolContext)") &&
    media_task_tools_source.include?("static func retryFailedMediaTasks(arguments: [String: AgentJSONValue], context: AgentToolContext)") &&
    media_task_tools_source.include?("dry-run retry failed short-drama media tasks") &&
    media_task_tools_source.include?("max(1, min(arguments[\"max_tasks\"]?.intValue() ?? 20, 50))") &&
    media_task_tools_source.include?("normalizedAssetKind") &&
    media_task_tools_source.include?("resolveAsset(project: project, scopeKind: scopeKind, assetKind: assetKind, assetID: assetID)") &&
    media_task_tools_source.include?('case "asset":') &&
    media_task_tools_source.include?('Asset: \\(resolved.assetLabel ?? "(all)")') &&
    media_task_tools_source.include?("AgentShortDramaTools.generateShotMedia") &&
    media_task_tools_source.include?("AgentShortDramaTools.generateAssetMedia") &&
    media_task_tools_source.include?("retryArguments[\"review_item_id\"] = .string(reviewItemID)") &&
    tools_source.include?("let reviewItemID = optionalString(arguments[\"review_item_id\"])") &&
    tools_source.include?("reviewItemID: reviewItemID") &&
    registry_source.include?('name: "short_drama_generate_shot_media"') &&
    registry_source.include?("Optional short-drama review/fix item UUID this image or video generation task is intended to resolve") &&
    media_task_tools_source.include?("retryReplicateMediaTask(task: task, context: context)") &&
    media_task_tools_source.include?("AgentShortDramaImageTools.upscaleShotArtifact") &&
    media_task_tools_source.include?("AgentMediaTools.editImageWithMask") &&
    media_task_tools_source.include?("Replicate image edit retry requires mask_path") &&
    media_task_tools_source.include?("Replicate upscale retry requires either shot anchors or asset_kind and asset_id.") &&
    media_task_tools_source.include?("Replicate image edit retry requires either shot anchors or asset_kind and asset_id.") &&
    media_task_tools_source.include?("AgentMediaTools.upscaleImage(arguments: retryArguments, context: context)") &&
    media_task_tools_source.include?("some.im asset image edit retry requires mask_path") &&
    media_task_tools_source.include?("\"asset_kind\": .string(assetKind)") &&
    media_task_tools_source.include?("\"asset_id\": .string(assetID)") &&
    media_task_tools_source.include?('"provider": .string("some_im")') &&
    media_task_tools_source.include?("some.im image edit retry requires mask_path") &&
    media_task_tools_source.include?("task.kind == .imageErase || task.kind == .imageInpaint || task.kind == .imageEdit") &&
    media_task_tools_source.include?("Only some.im generation and reconstructable Replicate image edit/upscale tasks can be retried") &&
    registry_source.include?('name: "asset_kind"') &&
    registry_source.include?('name: "asset_id"') &&
    registry_source.include?("project, episode, shot, asset, character, scene, review_item, or review") &&
    media_tasks_source.include?("canRetryViaChat") &&
    media_tasks_source.include?("AgentMediaTaskChatHandoff.isRetryableShortDramaTask(task)") &&
    media_tasks_source.include?("scopedTasks.filter(AgentMediaTaskChatHandoff.isRetryableShortDramaTask)") &&
    media_tasks_source.include?("AgentMediaTaskChatHandoff.appendRetryContext(task: task, appState: appState)") &&
    media_task_handoff_source.include?("task.provider == .replicate") &&
    media_task_handoff_source.include?("guard task.provider == .someIM else { return false }") &&
    media_task_handoff_source.include?("let hasAssetAnchor = task.assetKind != nil && task.assetID != nil") &&
    media_task_handoff_source.include?("clean(task.sourceImagePath) != nil && clean(task.maskPath) != nil") &&
    media_tasks_source.include?("appendScopedRetryToChat") &&
    media_tasks_source.include?("retryScopeKind") &&
    media_tasks_source.include?("return \"review_item\"") &&
    media_tasks_source.include?('"scope: \\(retryScopeKind(scope))"') &&
    media_task_handoff_source.include?("source_image_path: \\(sourceImagePath)") &&
    media_task_handoff_source.include?("mask_path: \\(maskPath)") &&
    media_task_handoff_source.include?("review_item_id: \\(reviewItemID)") &&
    media_task_handoff_source.include?("retry_tool: short_drama_retry_media_task") &&
    media_task_handoff_source.include?("retry_arguments: task_id=\\(task.displayHandle)") &&
    media_tasks_source.include?("retry_failed_tool: short_drama_retry_failed_media_tasks") &&
    media_tasks_source.include?("retry_failed_dry_run_arguments: \\(retryArguments), dry_run=true") &&
    media_tasks_source.include?("retry_failed_submit_arguments: \\(retryArguments), dry_run=false") &&
    media_tasks_source.include?("private func scopedRetryArguments(scope: AgentMediaTaskScope) -> String") &&
    media_task_handoff_source.include?("short_drama_retry_media_task") &&
    media_tasks_source.include?("short_drama_retry_failed_media_tasks") &&
    storyboard_widget_source.include?("retryFailedTasksActionHTML") &&
    storyboard_widget_source.include?("activeTasksActionHTML") &&
    storyboard_widget_source.include?("activeTasksPrompt") &&
    storyboard_widget_source.include?("continue_active_media_tasks") &&
    storyboard_widget_source.include?("active_task_actions:") &&
    storyboard_widget_source.include?("AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine") &&
    storyboard_widget_source.include?("处理任务") &&
    storyboard_widget_source.include?("short_drama_retry_failed_media_tasks") &&
    storyboard_widget_source.include?("scope=\\(scope)") &&
    storyboard_widget_source.include?("dry_run=true"),
  "image edit media tasks retain source and mask handoff paths" =>
    media_tasks_source.include?("var sourceImagePath: String?") &&
    media_tasks_source.include?("var maskPath: String?") &&
    media_tasks_source.include?("var reviewItemID: String?") &&
    media_tasks_source.include?("reviewItemID: String? = nil") &&
    media_tasks_source.include?("task.reviewItemID = reviewItemID") &&
    short_drama_source.include?("func updateReviewItemStatus(") &&
    media_tasks_source.include?("private func syncShortDramaLinks(for task: AgentMediaTask)") &&
    media_tasks_source.scan("syncShortDramaLinks(for: task)").size >= 3 &&
    media_tasks_source.include?("syncShortDramaShot(for: task)") &&
    media_tasks_source.include?("syncShortDramaAsset(for: task)") &&
    media_tasks_source.include?("syncShortDramaReviewItem(for: task)") &&
    media_tasks_source.include?("store.updateReviewItemStatus(") &&
    media_tasks_source.include?("reviewStatus = .doing") &&
    media_tasks_source.include?("reviewStatus = .open") &&
    media_tools_source.include?("sourceImagePath: cleanOptionalString(arguments[\"source_image_path\"])") &&
    media_tools_source.include?("reviewItemID: cleanOptionalString(arguments[\"review_item_id\"])") &&
    media_task_handoff_source.include?("if let sourceImagePath = clean(task.sourceImagePath)") &&
    media_task_handoff_source.include?("if let reviewItemID = clean(task.reviewItemID)") &&
    import_source.include?("reviewItemID: item.trimmedReviewItemID") &&
    import_source.include?("case reviewItemID = \"review_item_id\"") &&
    app_state_loop_source.include?("review_item_id: \\(reviewItemID)") &&
    app_state_loop_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    app_state_loop_source.include?("item_id=\\(reviewItemID)") &&
    media_tasks_source.include?("canResolveReviewItem") &&
    media_tasks_source.include?("linkedOpenReviewItem") &&
    media_tasks_source.include?("resolveLinkedReviewItem()") &&
    media_tasks_source.include?("checkmark.seal") &&
    media_tasks_source.include?("把关联短剧检查项标记为已解决") &&
    media_tasks_source.include?("这个任务缺少短剧项目锚点") &&
    media_tasks_source.include?("appState.agentShortDramaStore.resolveReviewItem") &&
    tools_source.include?("requiredUUID(arguments, keys: [\"item_id\", \"review_item_id\"])") &&
    registry_source.include?("carried through the selection result so the agent can keep follow-up media tasks and resolution on the same check item") &&
    tools_source.include?("let reviewItemID = optionalString(arguments[\"review_item_id\"])") &&
    tools_source.include?("store.setActiveProject(id: projectID)") &&
    tools_source.include?("AgentSidePanelOpenRequest(kind: .shortDrama)") &&
    tools_source.include?("<short-drama-primary-artifact-selected>") &&
    tools_source.include?("action: select_shot_primary_artifact") &&
    tools_source.include?("image_path: \\(artifactPath)") &&
    tools_source.include?("artifact_path: \\(artifactPath)") &&
    tools_source.include?("review_item_id: \\(reviewItemID)") &&
    tools_source.include?("</short-drama-primary-artifact-selected>") &&
    tools_source.include?("edit_tool: short_drama_open_image_editor") &&
    tools_source.include?("edit_arguments: project_id=\\(projectID.uuidString), episode_id=\\(episodeID.uuidString), shot_id=\\(shotID.uuidString), artifact_path=\\(artifactPath), operation=inpaint") &&
    tools_source.include?("erase_tool: short_drama_open_image_editor") &&
    tools_source.include?("erase_arguments: project_id=\\(projectID.uuidString), episode_id=\\(episodeID.uuidString), shot_id=\\(shotID.uuidString), artifact_path=\\(artifactPath), operation=erase") &&
    tools_source.include?("upscale_tool: short_drama_upscale_shot_artifact") &&
    tools_source.include?("upscale_arguments: project_id=\\(projectID.uuidString), episode_id=\\(episodeID.uuidString), shot_id=\\(shotID.uuidString), artifact_path=\\(artifactPath)") &&
    tools_source.include?("video_from_image_arguments: image_path=\\(artifactPath), project_id=\\(projectID.uuidString), episode_id=\\(episodeID.uuidString), shot_id=\\(shotID.uuidString)") &&
    tools_source.include?("resolve_review_arguments: project_id=\\(projectID.uuidString), episode_id=\\(episodeID.uuidString), shot_id=\\(shotID.uuidString), item_id=\\(reviewItemID)") &&
    image_edit_source.include?("sourceImagePath: imageInfo.url.path") &&
    image_edit_source.include?("maskPath: maskURL.path") &&
    image_edit_source.include?("var reviewItemID: String? = nil") &&
    image_edit_source.include?("reviewItemID: panelScope.imageContext?.reviewItemID") &&
    image_edit_source.include?("appendSubmittedEditTaskToChat(task: task, sourceImagePath: imageInfo.url.path, maskPath: maskURL.path)") &&
    image_edit_source.include?("<image-edit-task-submitted>") &&
    image_edit_source.include?("media_task_status_tool: list_media_tasks") &&
    image_edit_source.include?("media_task_status_arguments: only_active=false") &&
    image_edit_source.include?("active_media_task_status_arguments: only_active=true") &&
    image_edit_source.include?("target_task_id: \\(task.displayHandle)") &&
    image_edit_source.include?("AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine") &&
    image_edit_source.include?("active_task_actions:") &&
    image_edit_source.include?("active_task_follow_up: active_task_actions 已包含可直接调用的 provider 轮询/取消参数") &&
    image_edit_source.include?("appendReopenEditorActionLines(task: task, sourceImagePath: sourceImagePath, maskPath: maskPath, context: context, to: &lines)") &&
    image_edit_source.include?("<image-edit-reopen-action>") &&
    image_edit_source.include?("action: reopen_image_editor_with_seed_mask") &&
    image_edit_source.include?("reopen_editor_tool: short_drama_open_image_editor") &&
    image_edit_source.include?("reopen_editor_tool: open_image_editor") &&
    image_edit_source.include?("reopen_editor_arguments: \\(arguments)") &&
    image_edit_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    image_edit_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    image_edit_source.include?("refresh_tasks_arguments: \\(baseArguments)") &&
    image_edit_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    image_edit_source.include?("refresh_review_tasks_tool: short_drama_refresh_media_tasks") &&
    image_edit_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    image_edit_source.include?("resolve_review_arguments: \\(baseArguments), item_id=\\(reviewItemID)") &&
    image_edit_source.include?("open_asset_tasks_tool: short_drama_open_media_tasks") &&
    image_edit_source.include?("open_asset_tasks_arguments: \\(assetArguments)") &&
    image_edit_source.include?("refresh_asset_tasks_tool: short_drama_refresh_media_tasks") &&
    image_edit_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    image_edit_source.include?("attach_reference_arguments: project_id=\\(projectID), asset_kind=\\(assetKind), asset_id=\\(assetID), image_path=<completed_artifact_path>") &&
    image_edit_source.include?("appState.agentComposerFocusRevision += 1") &&
    media_tools_source.include?("reviewItemID: cleanOptionalString(arguments[\"review_item_id\"])") &&
    media_artifact_views_source.include?("reviewItemID: sourceTask.reviewItemID") &&
    media_artifact_views_source.include?("(\"review_item_id\", reviewItemID)") &&
    media_artifact_views_source.include?("context.append(\"review_item_id: \\(reviewItemID)\")") &&
    image_tools_source.include?("sourceImagePath: imagePath") &&
    image_tools_source.include?("reviewItemID: optionalString(arguments[\"review_item_id\"])") &&
    registry_source.include?('name: "source_image_path"') &&
    registry_source.include?('name: "mask_path"') &&
    registry_source.include?('AgentToolParameter(name: "review_item_id"') &&
    short_drama_source.include?("reviewItemID: item.id.uuidString") &&
    short_drama_source.include?("submitShotMedia(project: project, episode: episode, shot: shot, kind: .imageGeneration, reviewItemID: item.id.uuidString)") &&
    import_source.include?('case sourceImagePath = "source_image_path"') &&
    import_source.include?("sourceImagePath: item.trimmedSourceImagePath ?? manifest.trimmedSourceImagePath") &&
    import_source.include?("maskPath: group.maskPath") &&
    production_exporter_source.include?('case sourceImagePath = "source_image_path"') &&
    tools_source.include?("Source image: \\(task.sourceImagePath ?? \"(none)\")"),
  "asset reference images can open anchored mask editor" =>
    image_edit_source.include?("var assetKind: String? = nil") &&
    image_edit_source.include?("var assetID: String? = nil") &&
    image_edit_source.include?("assetKind: panelScope.imageContext?.assetKind") &&
    image_edit_source.include?("assetID: panelScope.imageContext?.assetID") &&
    media_artifact_views_source.include?("assetKind: sourceTask.assetKind") &&
    media_artifact_views_source.include?("assetID: sourceTask.assetID") &&
    asset_views_source.include?("projectID: UUID") &&
    asset_views_source.include?("编辑参考图蒙版") &&
    asset_views_source.include?("擦除参考图区域") &&
    asset_views_source.include?("放大参考图") &&
    asset_views_source.include?("openImageEditor(operation: .erase)") &&
    asset_views_source.include?("submitReplicateUpscale()") &&
    asset_views_source.include?("kind: .imageUpscale") &&
    asset_views_source.include?("projectID: asset.projectID.uuidString") &&
    asset_views_source.include?("assetKind: asset.assetKind") &&
    asset_views_source.include?("assetID: asset.id.uuidString") &&
    asset_views_source.include?("AgentSidePanelOpenRequest(kind: .imageEditor)") &&
    asset_views_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks)") &&
    short_drama_source.include?("projectID: project.id"),
  "storyboard widget displays media task status summaries" =>
    storyboard_widget_source.include?("mediaTasks: [AgentMediaTask] = []") &&
    storyboard_widget_source.include?("private static func taskSummaryHTML(_ tasks: [AgentMediaTask]) -> String") &&
    storyboard_widget_source.include?("tasks.filter(\\.isActive).count") &&
    storyboard_widget_source.include?("tasks.filter(\\.needsAttention).count") &&
    storyboard_widget_source.include?("task-pill active") &&
    storyboard_widget_source.include?("task-pill failed") &&
    storyboard_widget_source.include?("task-pill done") &&
    short_drama_source.include?("mediaTasks: appState.agentMediaTaskRegistry.tasks(forRuntime: runtimeID)") &&
    tools_source.include?("let mediaTasks = context.mediaTaskRegistry?.tasks(forRuntime: runtimeID) ?? []"),
  "short drama image tools are registered and implemented" =>
    registry_source.include?('name: "short_drama_open_image_editor"') &&
    registry_source.include?('name: "short_drama_upscale_shot_artifact"') &&
    short_drama_dispatcher_source.include?('case "short_drama_open_image_editor"') &&
    short_drama_dispatcher_source.include?('case "short_drama_upscale_shot_artifact"') &&
    short_drama_dispatcher_source.include?("AgentShortDramaImageTools.openImageEditor") &&
    short_drama_dispatcher_source.include?("AgentShortDramaImageTools.upscaleShotArtifact") &&
    image_tools_source.include?("static func openImageEditor(arguments: [String: AgentJSONValue], context: AgentToolContext)") &&
    image_tools_source.include?("static func upscaleShotArtifact(arguments: [String: AgentJSONValue], context: AgentToolContext)") &&
    image_tools_source.include?("AgentSidePanelOpenRequest(kind: .imageEditor)") &&
    image_tools_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks)") &&
    image_tools_source.include?("reviewItemID: reviewItemID") &&
    image_tools_source.include?("Review item id: \\(reviewItemID ?? \"(none)\")") &&
    registry_source.include?("Optional short-drama review/fix item UUID this upscale is intended to resolve") &&
    registry_source.scan("Optional backward-compatible alias for artifact_path. Prefer artifact_path in new handoffs.").length >= 2 &&
    image_tools_source.include?("appState.agentImageEditorPreferredOperation = operation") &&
    image_tools_source.include?("appState.agentImageEditorContext = AgentImageEditorContext(") &&
    image_tools_source.include?("ReplicateClient.createPrediction") &&
    image_tools_source.include?("optionalString(arguments[\"artifact_path\"])") &&
    image_tools_source.include?("optionalString(arguments[\"image_path\"])") &&
    image_tools_source.include?("kind: .imageUpscale"),
  "short drama batch media tool is registered and implemented" =>
    registry_source.include?('name: "short_drama_generate_batch_media"') &&
    batch_tools_source.include?("AgentVideoGenerationEngine.parse(arguments: arguments)") && batch_tools_source.include?("video_engine=\\(videoEngine.rawValue)") &&
    registry_source.include?('name: "target_filter"') &&
    registry_source.include?('AgentToolParameter(name: "shot_ids"') &&
    registry_source.include?("When missing, image_generation only targets shots without a selected main image") &&
    registry_source.include?('name: "dry_run"') &&
    registry_source.include?('name: "max_shots"') &&
    short_drama_dispatcher_source.include?('case "short_drama_generate_batch_media"') &&
    short_drama_dispatcher_source.include?("AgentShortDramaBatchTools.generateBatchMedia") &&
    batch_tools_source.include?("enum AgentShortDramaBatchTools") &&
    batch_tools_source.include?("static func generateBatchMedia(arguments: [String: AgentJSONValue], context: AgentToolContext)") &&
    batch_tools_source.include?("AgentShortDramaTools.generateShotMedia(arguments: shotArguments, context: context)") &&
    batch_tools_source.include?("let targetFilter = normalizedTargetFilter") &&
    batch_tools_source.include?("let explicitShotIDs = try uuidArray(arguments[\"shot_ids\"]?.stringArrayValue() ?? [], argumentName: \"shot_ids\")") &&
    batch_tools_source.include?("explicitShotIDs.isEmpty || explicitShotIDs.contains(target.shot.id)") &&
    batch_tools_source.include?("explicit_shot_filter_count: \\(explicitShotIDs.count)") &&
    batch_tools_source.include?("matchesTargetFilter(target.shot, kind: kind, targetFilter: targetFilter)") &&
    batch_tools_source.include?("Target filter: \\(targetFilter)") &&
    batch_tools_source.include?("case \"missing\":") &&
    batch_tools_source.include?("selectedImagePath(for: shot) == nil") &&
    batch_tools_source.include?("!hasVideoArtifact(shot)") &&
    batch_tools_source.include?("let maxShots = max(1, min(arguments[\"max_shots\"]?.intValue() ?? 200, 200))") &&
    batch_tools_source.include?("dry-run short drama batch") &&
    batch_tools_source.include?("AgentSidePanelOpenRequest(") &&
    batch_tools_source.include?("mediaTaskScope: AgentMediaTaskScope(") &&
    batch_tools_source.include?("<short-drama-batch-media-handoff>") &&
    batch_tools_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    batch_tools_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    batch_tools_source.include?("dry_run_tool: short_drama_generate_batch_media") &&
    batch_tools_source.include?("submit_tool: short_drama_generate_batch_media") &&
    batch_tools_source.include?("retry_failed_tool: short_drama_retry_failed_media_tasks") &&
    batch_tools_source.include?("target_shots: \\(targetIDs)") &&
    batch_tools_source.include?("private static func batchScopeArguments") &&
    batch_tools_source.include?("private static func uuidArray(_ values: [String], argumentName: String) throws -> Set<UUID>") &&
    batch_tools_source.include?("scope=episode") &&
    batch_tools_source.include?("scope=project"),
  "short drama tools are dispatched outside AgentTools main switch" =>
    dispatch_source.include?("AgentShortDramaToolDispatcher.canHandle(name)") &&
    dispatch_source.include?("AgentShortDramaToolDispatcher.run(") &&
    short_drama_dispatcher_source.include?("enum AgentShortDramaToolDispatcher") &&
    short_drama_dispatcher_source.include?("name.hasPrefix(\"short_drama_\")") &&
    !dispatch_source.include?('case "short_drama_create_project"') &&
    !dispatch_source.include?('case "short_drama_export_production_package"'),
  "media provider tools are split out of AgentTools main switch" =>
    dispatch_source.include?("AgentMediaTools.createMediaTask") &&
    dispatch_source.include?("AgentMediaTools.replicateCreatePrediction") &&
    dispatch_source.include?("AgentMediaTools.someIMCreateMediaTask") &&
    media_tools_source.include?("enum AgentMediaTools") &&
    media_tools_source.include?("static func createMediaTask") &&
    media_tools_source.include?("static func replicateCreatePrediction") &&
    media_tools_source.include?("static func someIMCreateMediaTask") &&
    !dispatch_source.include?("private static func createMediaTask") &&
    !dispatch_source.include?("private static func replicateCreatePrediction") &&
    !dispatch_source.include?("private static func someIMCreateMediaTask"),
  "create and update media task results expose immediate follow-up actions" =>
    media_tools_source.include?("payload: mediaTaskToolPayload(task: task, action: \"create_media_task_follow_up\")") &&
    media_tools_source.include?("payload: mediaTaskToolPayload(task: updated, action: \"update_media_task_follow_up\")") &&
    media_tools_source.include?("private static func mediaTaskToolFollowUp(task: AgentMediaTask, action: String)") &&
    media_tools_source.include?("<media-task-tool-follow-up>") &&
    media_tools_source.include?("image_choice_tool: \\(choice.tool)") &&
    media_tools_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    media_tools_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    media_tools_source.include?("private static func mediaTaskScopeArguments(task: AgentMediaTask) -> String?") &&
    media_tools_source.include?("scope=review_item") &&
    media_tools_source.include?("scope=asset") &&
    media_tools_source.include?("list_tasks_tool: list_media_tasks") &&
    media_tools_source.include?("short_drama_show_image_choice_widget") &&
    media_tools_source.include?("show_image_choice_widget") &&
    media_tools_source.include?("select_primary_tool: short_drama_select_shot_artifact") &&
    media_tools_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    media_tools_source.include?("edit_tool: open_image_editor") &&
    media_tools_source.include?("upscale_tool: upscale_image") &&
    media_tools_source.include?("video_from_image_tool: generate_video_from_image") &&
    media_tools_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    media_tools_source.include?("erase_tool: short_drama_open_image_editor") &&
    media_tools_source.include?("erase_arguments: \\(artifactArguments), operation=erase") &&
    media_tools_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    media_tools_source.include?("open_review_tasks_arguments: \\(reviewTaskArguments)") &&
    media_tools_source.include?("appendCleanPair(\"review_item_id\", task.reviewItemID"),
  "media task descriptions expose remote status and cancel urls" =>
    media_tools_source.include?("private static func describe(mediaTask task: AgentMediaTask) -> String") &&
    media_tools_source.include?("Status URL: \\(statusURL)") &&
    media_tools_source.include?("Cancel URL: \\(cancelURL)") &&
    media_tools_source.include?("let payload = filtered.map(describe(mediaTask:)).joined(separator: \"\\n\\n\")") &&
    media_tools_source.include?("payload: mediaTaskToolPayload(task: task, action: \"create_media_task_follow_up\")") &&
    media_tools_source.include?("payload: mediaTaskToolPayload(task: updated, action: \"update_media_task_follow_up\")"),
  "replicate and mask edit submit payloads expose cancel urls" =>
    media_tools_source.include?("Cancel URL: \\(prediction.urls?.cancel ?? \"(none)\")") &&
    media_tools_source.include?("cancelURL: prediction.urls?.cancel") &&
    media_tools_source.include?("cancelURL: response.cancelURL") &&
    media_tools_source.include?("Cancel URL: \\(cancelURL ?? \"(none)\")"),
  "upscale and mask edit submit payloads expose immediate follow-up actions" =>
    media_tools_source.include?("mediaTaskToolFollowUp(task: updated, action: \"upscale_image_follow_up\")") &&
    media_tools_source.include?("followUpAction: \"edit_image_with_mask_follow_up\"") &&
    media_tools_source.include?("let followUp = mediaTaskToolFollowUp(task: task, action: followUpAction)") &&
    media_tools_source.include?("registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID) ?? task"),
  "provider-native media tools reuse immediate follow-up payloads" =>
    media_tools_source.include?("action: \"replicate_create_prediction_follow_up\"") &&
    media_tools_source.include?("action: \"replicate_poll_prediction_follow_up\"") &&
    media_tools_source.include?("action: \"replicate_cancel_prediction_follow_up\"") &&
    media_tools_source.include?("action: \"some_im_create_media_task_follow_up\"") &&
    media_tools_source.include?("action: \"some_im_poll_media_task_follow_up\"") &&
    media_tools_source.include?("action: \"some_im_cancel_media_task_follow_up\"") &&
    media_tools_source.scan("mediaTaskToolPayload(task: updated").length >= 7,
  "generic image editor tool opens mask editor" =>
    registry_source.include?('name: "open_image_editor"') &&
    registry_source.include?('AgentToolParameter(name: "image_path"') &&
    registry_source.include?("Optional short-drama shot or asset anchors are preserved") &&
    dispatch_source.include?('case "open_image_editor"') &&
    dispatch_source.include?("AgentMediaTools.openImageEditor") &&
    media_tools_source.include?("static func openImageEditor(") &&
    media_tools_source.include?("resolveImageURL(rawPath") &&
    media_tools_source.include?("parseImageEditorOperation") &&
    media_tools_source.include?("AgentImageEditorContext(") &&
    media_tools_source.include?("assetKind: cleanOptionalString(arguments[\"asset_kind\"])") &&
    media_tools_source.include?("assetID: cleanOptionalString(arguments[\"asset_id\"])") &&
    media_tools_source.include?("AgentSidePanelOpenRequest(kind: .imageEditor)") &&
    media_tools_source.include?("open_image_editor is only available in conversational agent runtimes"),
  "image editor side panel exposes production anchors to chat" =>
    image_edit_source.include?("imageEditorContextCard(imageInfo: imageInfo)") &&
    image_edit_source.include?("Text(rows.isEmpty ? L10n.AgentImageEditor.contextCardGeneric : L10n.AgentImageEditor.contextCardAnchors)") &&
    image_edit_source.include?("appendImageEditorContextToChat") &&
    image_edit_source.include?("<image-editor-context>") &&
    image_edit_source.include?("action: inspect_image_editor_from_side_panel") &&
    image_edit_source.include?("submit_with_existing_mask_tool: edit_image_with_mask") &&
    image_edit_source.include?("let currentMaskURL = lastMaskURL ?? (hasMaskSelection ? exportMask() : nil)") &&
    image_edit_source.include?("current_mask_path: \\(currentMaskPath)") &&
    image_edit_source.include?("let currentSubmitArguments = imageEditorSubmitArguments(") &&
    image_edit_source.include?("maskPath: currentMaskPath,") &&
    image_edit_source.include?("submit_with_existing_mask_arguments: \\(currentSubmitArguments)") &&
    image_edit_source.include?("submit_inpaint_tool: edit_image_with_mask") &&
    image_edit_source.include?("submit_inpaint_arguments: \\(imageEditorSubmitArguments(imagePath: imageInfo.url.path, maskPath: currentMaskPath, operation: .inpaint))") &&
    image_edit_source.include?("submit_erase_tool: edit_image_with_mask") &&
    image_edit_source.include?("submit_erase_arguments: \\(imageEditorSubmitArguments(imagePath: imageInfo.url.path, maskPath: currentMaskPath, operation: .erase))") &&
    image_edit_source.include?("appendCleanPair(\"review_item_id\", context?.reviewItemID") &&
    image_edit_source.include?("open_shot_tasks_tool: short_drama_open_media_tasks") &&
    image_edit_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    image_edit_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    image_edit_source.include?("open_asset_tasks_tool: short_drama_open_media_tasks") &&
    image_edit_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    image_edit_source.include?("appendImageEditorContextAnchorLines") &&
    image_edit_source.include?("imageEditorContextRows") &&
    image_edit_source.include?("L10n.AgentImageEditor.sendToChatHelp"),
  "generic image mask edit tool submits existing masks" =>
    registry_source.include?('name: "edit_image_with_mask"') &&
    registry_source.include?("Submit an image edit task directly from a local image_path and mask_path") &&
    registry_source.include?('AgentToolParameter(name: "mask_path"') &&
    registry_source.include?('AgentToolParameter(name: "operation"') &&
    registry_source.include?('AgentToolParameter(name: "provider"') &&
    dispatch_source.include?('case "edit_image_with_mask"') &&
    dispatch_source.include?("AgentMediaTools.editImageWithMask") &&
    media_tools_source.include?("static func editImageWithMask(") &&
    media_tools_source.include?("let maskURL = try resolveImageURL(rawMaskPath") &&
    media_tools_source.include?("maskEditPrompt(arguments: arguments") &&
    media_tools_source.include?("submitReplicateMaskEdit(") &&
    media_tools_source.include?("submitSomeIMMaskEdit(") &&
    media_tools_source.include?("\"mask\": dataURL(for: maskURL)") &&
    media_tools_source.include?("\"mask\": try dataURL(for: maskURL)") &&
    media_tools_source.include?("kind: maskEditKind(for: operation)") &&
    media_tools_source.include?("sourceImagePath: imageURL.path") &&
    media_tools_source.include?("maskPath: maskURL.path") &&
    media_tools_source.include?("reviewItemID: cleanOptionalString(arguments[\"review_item_id\"]),") &&
    media_tools_source.include?("assetKind: cleanOptionalString(arguments[\"asset_kind\"])") &&
    media_tools_source.include?("assetID: cleanOptionalString(arguments[\"asset_id\"])") &&
    media_tools_source.include?("replicateMaskEditVersion(for: operation)") &&
    media_tools_source.include?("SomeIMAsyncMediaClient.submit") &&
    media_tools_source.include?("openMediaTaskPanelIfPossible(context: context)") &&
    media_tools_source.include?("Masked image edit submitted."),
  "generic image upscale tool submits Replicate media task" =>
    registry_source.include?('name: "upscale_image"') &&
    registry_source.include?("Submit a Replicate image upscale task for a local image path") &&
    registry_source.include?('AgentToolParameter(name: "version"') &&
    dispatch_source.include?('case "upscale_image"') &&
    dispatch_source.include?("AgentMediaTools.upscaleImage") &&
    media_tools_source.include?("static func upscaleImage(") &&
    media_tools_source.include?("ReplicateIntegrationStore.loadWorkflowSettings().upscaleVersion") &&
    media_tools_source.include?("ReplicateClient.createPrediction") &&
    media_tools_source.include?("private static func dataURL(for url: URL)") &&
    media_tools_source.include?("private static func jsonString(from object: [String: Any])") &&
    media_tools_source.include?("kind: .imageUpscale") &&
    media_tools_source.include?("sourceImagePath: imageURL.path") &&
    media_tools_source.include?("assetKind: cleanOptionalString(arguments[\"asset_kind\"])") &&
    media_tools_source.include?("assetID: cleanOptionalString(arguments[\"asset_id\"])") &&
    media_tools_source.include?("AgentSidePanelOpenRequest(kind: .mediaTasks)") &&
    media_tools_source.include?("Image upscale submitted."),
  "generic image choice widget can collect user selection" =>
    registry_source.include?('name: "show_image_choice_widget"') &&
    registry_source.include?('AgentToolParameter(name: "image_paths"') &&
    dispatch_source.include?('case "show_image_choice_widget"') &&
    dispatch_source.include?("AgentMediaTools.showImageChoiceWidget") &&
    media_tools_source.include?("static func showImageChoiceWidget(") &&
    media_tools_source.include?("AgentImageChoiceWidgetBuilder.widget") &&
    media_tools_source.include?("let contextLines = try imageChoiceWidgetContextLines(arguments: arguments, imageCount: imagePaths.count)") &&
    media_tools_source.include?("contextLines: contextLines") &&
    media_tools_source.include?("private static func imageChoiceWidgetContextLines") &&
    media_tools_source.include?("show_image_choice_widget context metadata must be 8 KB or smaller.") &&
    media_tools_source.include?("image_count: \\(imageCount)") &&
    media_tools_source.include?("\\(widget.contextBlock)") &&
    media_tools_source.include?("AgentSidePanelOpenRequest(kind: .widget)") &&
    media_tools_source.include?("show_image_choice_widget is only available in conversational agent runtimes") &&
    media_tools_source.include?("recommended_tool / recommended_arguments and post_select_* follow-up actions back to chat") &&
    media_tools_source.include?("post_select_action_keys and the structured post_select_* fields") &&
    registry_source.include?('name: "source_label"') &&
    registry_source.include?('name: "source_path"') &&
    registry_source.include?('name: "package_directory"') &&
    registry_source.include?('name: "widget_context"') &&
    registry_source.include?('name: "recommended_tool"') &&
    registry_source.include?('name: "recommended_arguments"') &&
    media_artifact_views_source.include?("enum AgentImageChoiceWidgetBuilder") &&
    media_artifact_views_source.include?("struct AnchorContext") &&
    media_artifact_views_source.include?("contextLines: [String] = []") &&
    media_artifact_views_source.include?("contextLines: contextLines + choiceWidgetContextLines(title: title, imagePaths: imagePaths, anchor: anchor)") &&
    media_artifact_views_source.include?("private static func choiceWidgetContextLines(title: String, imagePaths: [String], anchor: AnchorContext) -> [String]") &&
    media_artifact_views_source.include?("<image-choice-widget>") &&
    media_artifact_views_source.include?("action: show_image_choice_widget") &&
    media_artifact_views_source.include?("post_select_action_keys: \\(postSelectActionKeys(anchor: anchor).joined(separator: \", \"))") &&
    media_artifact_views_source.include?("private static func postSelectActionKeys(anchor: AnchorContext) -> [String]") &&
    media_artifact_views_source.include?("candidate_actions:") &&
    media_artifact_views_source.include?("select_arguments: \\(recommendedArguments(action: \"select_image\", path: path, anchor: anchor, extraLines: []))") &&
    media_artifact_views_source.include?("edit_arguments: \\(recommendedArguments(action: \"open_image_editor\", path: path, anchor: anchor, extraLines: [\"operation: inpaint\"]))") &&
    media_artifact_views_source.include?("erase_arguments: \\(recommendedArguments(action: \"open_image_editor\", path: path, anchor: anchor, extraLines: [\"operation: erase\"]))") &&
    media_artifact_views_source.include?("upscale_arguments: \\(recommendedArguments(action: \"upscale_image\", path: path, anchor: anchor, extraLines: []))") &&
    media_artifact_views_source.include?("video_arguments: \\(recommendedArguments(action: \"generate_video_from_image\", path: path, anchor: anchor, extraLines: []))") &&
    media_artifact_views_source.include?("\"project_id\", projectID") &&
    media_artifact_views_source.include?("\"asset_id\", assetID") &&
    media_artifact_views_source.include?("var hasShotAnchor: Bool") &&
    media_artifact_views_source.include?("var hasAssetAnchor: Bool") &&
    media_artifact_views_source.include?("short_drama_select_shot_artifact") &&
    media_artifact_views_source.include?("如果下面有 review_item_id，也要一并传入") &&
    media_artifact_views_source.include?("short_drama_attach_asset_reference_image") &&
    media_artifact_views_source.include?("<image-choice>") &&
    media_artifact_views_source.include?("image_path: \\(path)") &&
    media_artifact_views_source.include?("选这张继续") &&
    media_artifact_views_source.include?("打开蒙版") &&
    media_artifact_views_source.include?("擦除区域") &&
    media_artifact_views_source.include?("放大图片") &&
    media_artifact_views_source.include?("生成视频") &&
    media_artifact_views_source.include?("请优先使用下面的 recommended_tool 和 recommended_arguments；如果带短剧分镜锚点，应使用短剧专用图片编辑工具以保留分镜和检查项流水。") &&
    media_artifact_views_source.include?("请优先使用下面的 recommended_tool 和 recommended_arguments；如果带短剧分镜锚点，应使用短剧专用放大工具以保留分镜和检查项流水。") &&
    media_artifact_views_source.include?("choiceBlock(action: \"open_image_editor\"") &&
    media_artifact_views_source.include?("operation: erase") &&
    media_artifact_views_source.include?("choiceBlock(action: \"upscale_image\"") &&
    media_artifact_views_source.include?("choiceBlock(action: \"generate_video_from_image\"") &&
    media_artifact_views_source.include?("selectionFollowUpLines(action: action, path: path, anchor: anchor)") &&
    media_artifact_views_source.include?("post_select_open_shot_tasks_tool: short_drama_open_media_tasks") &&
    media_artifact_views_source.include?("post_select_open_shot_tasks_arguments: \\(argumentString(shotTaskPairs))") &&
    media_artifact_views_source.include?("post_select_video_tool: generate_video_from_image") &&
    media_artifact_views_source.include?("post_select_video_arguments: \\(imageArguments)") &&
    media_artifact_views_source.include?("post_select_edit_tool: short_drama_open_image_editor") &&
    media_artifact_views_source.include?("post_select_edit_arguments: \\(artifactArguments), operation=inpaint") &&
    media_artifact_views_source.include?("post_select_erase_tool: short_drama_open_image_editor") &&
    media_artifact_views_source.include?("post_select_erase_arguments: \\(artifactArguments), operation=erase") &&
    media_artifact_views_source.include?("post_select_upscale_tool: short_drama_upscale_shot_artifact") &&
    media_artifact_views_source.include?("post_select_upscale_arguments: \\(artifactArguments)") &&
    media_artifact_views_source.include?("post_select_open_review_tasks_tool: short_drama_open_media_tasks") &&
    media_artifact_views_source.include?("post_select_open_review_tasks_arguments: \\(argumentString(reviewTaskPairs))") &&
    media_artifact_views_source.include?("post_select_resolve_review_tool: short_drama_resolve_review_item") &&
    media_artifact_views_source.include?("post_select_resolve_review_arguments: \\(argumentString(reviewPairs))") &&
    media_artifact_views_source.include?("post_select_attach_reference_tool: short_drama_attach_asset_reference_image") &&
    media_artifact_views_source.include?("post_select_attach_reference_arguments: \\(argumentString(attachPairs))") &&
    media_artifact_views_source.include?("post_select_open_asset_tasks_tool: short_drama_open_media_tasks") &&
    media_artifact_views_source.include?("post_select_open_asset_tasks_arguments: \\(argumentString(taskPairs))") &&
    media_artifact_views_source.include?("post_select_generate_related_shots_tool: short_drama_generate_batch_media") &&
    media_artifact_views_source.include?("post_select_generate_related_shots_arguments: \\(argumentString(relatedShotPairs))") &&
    media_artifact_views_source.include?("canSendVideoArtifactToChat") &&
    media_artifact_views_source.include?("appendVideoArtifactContextToChat()") &&
    media_artifact_views_source.include?("<media-task-video-artifact-selected>") &&
    media_artifact_views_source.include?("action: continue_from_selected_video_artifact") &&
    media_artifact_views_source.include?("video_path: \\(artifact.filePath)") &&
    media_artifact_views_source.include?("storyboard_widget_tool: short_drama_show_storyboard_widget") &&
    media_artifact_views_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    media_artifact_views_source.include?("post_select_edit_tool: open_image_editor") &&
    media_artifact_views_source.include?("post_select_edit_arguments: \\(imageArguments), operation=inpaint") &&
    media_artifact_views_source.include?("post_select_erase_tool: open_image_editor") &&
    media_artifact_views_source.include?("post_select_erase_arguments: \\(eraseArguments)") &&
    media_artifact_views_source.include?("post_select_upscale_tool: upscale_image") &&
    media_artifact_views_source.include?("post_select_upscale_arguments: \\(upscaleArguments)") &&
    media_artifact_views_source.include?("recommended_tool: \\(tool)") &&
    media_artifact_views_source.include?("recommended_arguments: \\(recommendedArguments(action: action, path: path, anchor: anchor, extraLines: extraLines))") &&
    media_artifact_views_source.include?("if anchor.hasShotAnchor { return \"short_drama_select_shot_artifact\" }") &&
    media_artifact_views_source.include?("if anchor.hasAssetAnchor { return \"short_drama_attach_asset_reference_image\" }") &&
    media_artifact_views_source.include?("case \"open_image_editor\"") &&
    media_artifact_views_source.include?("if anchor.hasShotAnchor { return \"short_drama_open_image_editor\" }") &&
    media_artifact_views_source.include?("if anchor.hasShotAnchor { return \"short_drama_upscale_shot_artifact\" }") &&
    media_artifact_views_source.include?("return \"upscale_image\"") &&
    media_artifact_views_source.include?("return \"generate_video_from_image\"") &&
    media_artifact_views_source.include?("pairs.append((\"artifact_path\", path))") &&
    media_artifact_views_source.include?("pairs.append((anchor.hasShotAnchor ? \"artifact_path\" : \"image_path\", path))") &&
    media_artifact_views_source.include?("pairs.append((\"review_item_id\", reviewItemID))") &&
    media_artifact_views_source.include?("reference_image_path: \\(path)") &&
    media_artifact_views_source.include?("如果下面有 review_item_id，也必须一并传入") &&
    app_state_loop_source.include?("reviewSuffix = reviewItemID.map") &&
    app_state_loop_source.include?("review_item_id=\\($0)") &&
    app_state_loop_source.include?("include `review_item_id` too when this task is linked to a review item") &&
    registry_source.include?('AgentToolParameter(name: "project_id"') &&
    registry_source.include?('AgentToolParameter(name: "episode_id"') &&
    registry_source.include?('AgentToolParameter(name: "shot_id"') &&
    registry_source.include?('AgentToolParameter(name: "asset_kind"') &&
    registry_source.include?('AgentToolParameter(name: "asset_id"') &&
    registry_source.include?('name: "generate_video_from_image"') &&
    media_tools_source.include?("let engine = AgentVideoGenerationEngine.parse(arguments: arguments)") && media_tools_source.include?("return klingVideoFromImageHandoff(") &&
    registry_source.include?("Optional short-drama review/fix item UUID this video task is intended to resolve") &&
    dispatch_source.include?('case "generate_video_from_image"') &&
    dispatch_source.include?("AgentMediaTools.generateVideoFromImage") &&
    media_tools_source.include?("static func generateVideoFromImage(") &&
    media_tools_source.include?("AgentImageChoiceWidgetBuilder.AnchorContext(") &&
    media_tools_source.include?("projectID: cleanOptionalString(arguments[\"project_id\"])") &&
    media_tools_source.include?("assetID: cleanOptionalString(arguments[\"asset_id\"])") &&
    media_tools_source.include?('for key in ["model", "endpoint_suffix", "project_id", "episode_id", "shot_id", "asset_kind", "asset_id", "review_item_id"]') &&
    media_tools_source.include?("\"kind\": .string(\"video_generation\")") &&
    media_tools_source.include?("\"reference_image_path\": .string(imageURL.path)") &&
    media_tools_source.include?("reviewItemID: cleanOptionalString(arguments[\"review_item_id\"])") &&
    media_tools_source.include?("return try await someIMCreateMediaTask(arguments: mediaArguments, context: context)") &&
    registry_source.include?('AgentToolParameter(name: "reference_image_path"') &&
    registry_source.include?('AgentToolParameter(name: "source_image_path"') &&
    media_tools_source.include?("optionalSourceImageURL(arguments: arguments") &&
    media_tools_source.include?("sourceImagePath: sourceImageURL?.path") &&
    media_tools_source.include?("body[\"image\"] = try dataURL(for: sourceImageURL)") &&
    registry_source.include?('name: "short_drama_attach_asset_reference_image"') &&
    registry_source.include?("Append one or more local images to an existing short-drama character or scene asset") &&
    short_drama_dispatcher_source.include?('case "short_drama_attach_asset_reference_image"') &&
    short_drama_dispatcher_source.include?("AgentShortDramaTools.attachAssetReferenceImage") &&
    tools_source.include?("static func attachAssetReferenceImage(") &&
    tools_source.include?("store.attachReferenceImages(") &&
    tools_source.include?("store.setActiveProject(id: projectID)") &&
    tools_source.include?("AgentSidePanelOpenRequest(kind: .shortDrama)") &&
    tools_source.include?("<short-drama-asset-reference-attached>") &&
    tools_source.include?("action: attach_asset_reference_image") &&
    tools_source.include?("open_asset_tasks_tool: short_drama_open_media_tasks") &&
    tools_source.include?("open_asset_tasks_arguments: project_id=\\(projectID.uuidString), scope=asset, asset_kind=\\(assetKind), asset_id=\\(assetID.uuidString)") &&
    tools_source.include?("generate_related_shots_tool: short_drama_generate_batch_media") &&
    tools_source.include?("edit_tool: open_image_editor") &&
    tools_source.include?("upscale_tool: upscale_image") &&
    tools_source.include?("reference_image_paths:") &&
    tools_source.include?("image_path or image_paths"),
  "plan import accepts inline json" => tools_source.include?('arguments["json"]') && tools_source.include?('arguments["plan_json"]'),
  "plan import accepts file path" => tools_source.include?('arguments["file_path"]') && tools_source.include?('arguments["plan_path"]'),
  "plan import decodes production package" => tools_source.include?("AgentShortDramaProductionExporter.Package.self"),
  "plan import supports skill friendly snake case" =>
    tools_source.include?('case projectID = "project_id"') &&
    tools_source.include?('case visualPrompt = "visual_prompt"') &&
    tools_source.include?('case selectedArtifactPath = "selected_artifact_path"')
}
end
