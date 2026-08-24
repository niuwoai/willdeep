# frozen_string_literal: true

# short_drama_media_contract_plan_import_checks.rb — 短剧规划导入这一组契约
# 断言：规划 JSON 导入 / 模板导出 / 检查项 CSV 回导、侧边栏的制作接力入口，
# 以及结构增删改（删除、重排、复制分镜、批量状态与链接）的工具注册与分发。
#
# 从 short_drama_media_contract_test.rb 拆出来：那个脚本 2995 行，离
# scripts/complexity_guard.rb 的 hard_limit=3000 只差 5 行。断言体逐行原样
# 搬运，缩进刻意保持与拆分前一致（不额外缩进一层），方便和历史 diff 逐行对照。

def short_drama_media_contract_plan_import_checks(
  tools_source:,
  production_exporter_source:,
  short_drama_dispatcher_source:,
  short_drama_chat_context_source:,
  short_drama_source:,
  media_tasks_source:,
  storyboard_widget_source:,
  registry_source:,
  panel_source:
)
{
  "short_drama_import_plan registered" => registry_source.include?('name: "short_drama_import_plan"'),
  "short_drama_import_plan dispatched" =>
    short_drama_dispatcher_source.include?('case "short_drama_import_plan"'),
  "short_drama_export_plan_template registered" => registry_source.include?('name: "short_drama_export_plan_template"'),
  "short_drama_export_plan_template dispatched" =>
    short_drama_dispatcher_source.include?('case "short_drama_export_plan_template"'),
  "plan template generator exists" =>
    tools_source.include?("enum AgentShortDramaPlanTemplate") &&
    tools_source.include?("short-drama-plan-template.json") &&
    tools_source.include?('"characters": ["lead", "rival"]'),
  "short drama side panel exposes plan import" =>
    panel_source.include?("importShortDramaPlanFromFile") &&
    short_drama_source.include?("导入短剧规划 JSON"),
  "short drama side panel exposes plan template" =>
    panel_source.include?("exportShortDramaPlanTemplate") &&
    short_drama_source.include?("生成短剧规划 JSON 模板"),
  "short drama plan dry-run registered" =>
    registry_source.include?('name: "dry_run"') &&
    tools_source.include?("Short-drama plan dry-run. No project was created or updated."),
  "short drama review csv import registered and dispatched" =>
    registry_source.include?('name: "short_drama_import_review_csv"') &&
    registry_source.include?("review_title/title/issue") &&
    registry_source.include?("csv_path") &&
    registry_source.include?("package_directory") &&
    registry_source.include?("production-review-template.csv from this directory") &&
    registry_source.include?("production-review-queue.csv") &&
    registry_source.include?("review_item_id") &&
    registry_source.include?("status/review_status") &&
    registry_source.include?("update or close existing reviewItems") &&
    registry_source.include?("dry_run") &&
    short_drama_dispatcher_source.include?('case "short_drama_import_review_csv"') &&
    tools_source.include?("static func importReviewCSV") &&
    tools_source.include?("reviewCSVString(arguments: arguments)") &&
    tools_source.include?('arguments["package_directory"]') &&
    tools_source.include?('"production-review-template.csv"') &&
    tools_source.include?("private static func reviewCSVFileString") &&
    tools_source.include?('throw AgentToolError.missingArgument("csv, file_path, or package_directory")') &&
    tools_source.include?("parseCSV(csv)") &&
    tools_source.include?("CSV must include a shot_id column.") &&
    tools_source.include?('"review_title", "title", "issue"') &&
    tools_source.include?("existingReviewItemID(in: project, shotID: shotID, title: title, kind: kind)") &&
    tools_source.include?("private static func existingReviewItemID") &&
    tools_source.include?("normalizeReviewTitle(item.title) == normalizedTitle") &&
    tools_source.include?("item.status != .resolved") &&
    tools_source.include?("let updateSuffix = itemID.map") &&
    tools_source.include?("store.upsertReviewItem("),
  "production widget csv review handoff can write review items" =>
    production_exporter_source.scan("short_drama_import_review_csv").length >= 2 &&
    production_exporter_source.scan("package_directory").length >= 3 &&
    production_exporter_source.scan("production-review-queue.csv").length >= 4 &&
    production_exporter_source.scan("kind/severity/suggested_action").length >= 2 &&
    production_exporter_source.include?("写回对应分镜 reviewItems"),
  "short drama side panel imports review csv files" =>
    panel_source.include?("Label(\"预检审片\"") &&
    panel_source.include?("Label(\"导入审片\"") &&
    panel_source.include?("Label(\"审片模板\"") &&
    panel_source.include?("Label(\"修复队列\"") &&
    panel_source.include?("importReviewCSVFromFile(dryRun: true)") &&
    panel_source.include?("importReviewCSVFromFile(dryRun: false)") &&
    panel_source.include?("revealReviewTemplateCSV()") &&
    panel_source.include?("revealReviewQueueCSV()") &&
    panel_source.include?("activateFileViewerSelecting([export.reviewTemplateCSVURL])") &&
    panel_source.include?("activateFileViewerSelecting([export.reviewQueueCSVURL])") &&
    panel_source.include?("AgentShortDramaTools.importReviewCSV(") &&
    panel_source.include?("production-review-template.csv") &&
    panel_source.include?("production-review-queue.csv") &&
    panel_source.include?("review_item_id/review_status") &&
    panel_source.include?("更新或关闭已有检查项") &&
    panel_source.include?('"file_path": .string(url.path)') &&
    panel_source.include?('"dry_run": .bool(dryRun)') &&
    panel_source.include?("stageImportedReviewCSVPrompt(fileURL: url, result: result)") &&
    panel_source.include?("已导入短剧审片 CSV") &&
    panel_source.include?("已定位审片 CSV 模板") &&
    panel_source.include?("已定位检查项修复队列") &&
    panel_source.include?("可点击“导入审片”写回分镜检查项") &&
    panel_source.include?("一条未解决 reviewItem 一行") &&
    panel_source.include?("project/episode/shot 锚点"),
  "short drama side panel exposes plan dry-run" =>
    panel_source.include?("importShortDramaPlanFromFile(dryRun: Bool)") &&
    short_drama_source.include?("预检短剧规划 JSON"),
  "short drama side panel can register pending production tasks" =>
    panel_source.include?("Label(\"登记任务\"") &&
    panel_source.include?("importLastProductionPackage(dryRun: false, importPendingTasks: true)") &&
    panel_source.include?('"import_pending_tasks": .bool(importPendingTasks)'),
  "short drama side panel stages chat after production import" =>
    panel_source.include?("stageImportedProductionPackagePrompt(") &&
    panel_source.include?("已完成短剧制作包") &&
    panel_source.include?("剪辑时间线：\\(export.timelineURL.path)") &&
    panel_source.include?("缺口报告：\\(export.gapReportURL.path)") &&
    panel_source.include?("分镜 CSV 清单：\\(export.shotListCSVURL.path)") &&
    panel_source.include?("审片 CSV 模板：\\(export.reviewTemplateCSVURL.path)") &&
    panel_source.include?("检查项修复队列：\\(export.reviewQueueCSVURL.path)") &&
    panel_source.include?("媒体任务侧栏状态") &&
    panel_source.include?("候选图选择器") &&
    panel_source.include?("继续安排视频生成") &&
    panel_source.include?("刷新、重试或调整 prompt") &&
    panel_source.include?("appState.agentComposerFocusRevision += 1"),
  "short drama side panel can reveal media API env example" =>
    panel_source.include?("Label(\"配置 API\"") &&
    panel_source.include?("revealMediaAPIEnvExample") &&
    panel_source.include?("activateFileViewerSelecting([export.envExampleURL])"),
  "short drama side panel can open production widget preview" =>
    panel_source.include?("Label(\"预览网页\"") &&
    panel_source.include?("openProductionWidgetPreview") &&
    panel_source.include?("let widgetStatus = queueProductionWidgetPreview(export: export)") &&
    panel_source.include?("网页组件：") &&
    panel_source.include?("private func queueProductionWidgetPreview(export: AgentShortDramaProductionExporter.ExportResult) -> String") &&
    panel_source.include?("private func productionPackageWidgetContextLines(") &&
    panel_source.include?("String(contentsOf: export.widgetPreviewURL, encoding: .utf8)") &&
    panel_source.include?("AgentWidget(") &&
    panel_source.include?("contextLines: productionPackageWidgetContextLines(export: export, sourceLabel: \"short-drama-side-panel-auto-export\")") &&
    panel_source.include?("\"<production-package-handoff>\",") &&
    panel_source.include?("\"action: short_drama_side_panel_production_widget\",") &&
    panel_source.include?("\"review_queue_import_arguments: file_path=\\(export.reviewQueueCSVURL.path), dry_run=true\",") &&
    panel_source.include?("AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)") &&
    panel_source.include?("AgentSidePanelOpenRequest(kind: .widget)") &&
    panel_source.include?("widget-preview.html"),
  "short drama side panel can stage Ruby script run handoff" =>
    panel_source.include?("Label(\"运行脚本\"") &&
    panel_source.include?("stageProductionScriptPrompt") &&
    panel_source.include?("Ruby 脚本：\\(export.rubyScriptTemplateURL.path)") &&
    panel_source.include?("media-api.env.example 需要哪些环境变量") &&
    panel_source.include?("run_command 因 workspace 边界不能访问这个 Application Support 目录") &&
    panel_source.include?("cd \\(shellQuoted(export.directory.path)) && ruby \\(shellQuoted(export.rubyScriptTemplateURL.lastPathComponent))") &&
    panel_source.include?("import_pending_tasks: true") &&
    panel_source.include?("缺口报告：\\(export.gapReportURL.path)") &&
    panel_source.include?("分镜 CSV 清单：\\(export.shotListCSVURL.path)") &&
    panel_source.include?("审片 CSV 模板：\\(export.reviewTemplateCSVURL.path)") &&
    panel_source.include?("检查项修复队列：\\(export.reviewQueueCSVURL.path)") &&
    panel_source.include?("<ruby-media-script-run-handoff>") &&
    panel_source.include?("action: run_short_drama_ruby_media_script") &&
    panel_source.include?("recommended_command: cd \\(shellQuoted(export.directory.path)) && ruby \\(shellQuoted(export.rubyScriptTemplateURL.lastPathComponent))") &&
    panel_source.include?("dry_run_import_arguments: package_directory=\\(export.directory.path), dry_run=true, import_pending_tasks=true") &&
    panel_source.include?("pending_import_arguments: package_directory=\\(export.directory.path), dry_run=false, import_pending_tasks=true") &&
    panel_source.include?("review_queue_import_arguments: file_path=\\(export.reviewQueueCSVURL.path), dry_run=true") &&
    panel_source.include?("widget_arguments: title=短剧制作预览, html_path=\\(export.widgetPreviewURL.path), source_label=ruby-media-script-side-panel") &&
    panel_source.include?("security_note: keep real API tokens in a private env file or shell environment") &&
    panel_source.include?("private func shellQuoted"),
  "short drama side panel can restage production handoff prompt" =>
    panel_source.include?("Label(\"接力聊天\"") &&
    panel_source.include?("restageProductionPackagePrompt") &&
    panel_source.include?("stageProductionPackagePrompt(project: project, episode: nil, export: export)") &&
    panel_source.include?("appState.agentComposerFocusRevision += 1") &&
    panel_source.include?("production-timeline.json 作为剪辑/装配顺序清单") &&
    panel_source.include?("production-gap-report.json") &&
    panel_source.include?("short_drama_generate_batch_media(target_filter=missing)") &&
    panel_source.include?("production-shot-list.csv") &&
    panel_source.include?("production-review-template.csv") &&
    panel_source.include?("production-review-queue.csv") &&
    panel_source.include?("short_drama_import_review_csv(package_directory: \\(export.directory.path))") &&
    panel_source.include?("WILLDEEP_MEDIA_API_METHOD") &&
    panel_source.include?("WILLDEEP_MEDIA_EXTRA_HEADERS_JSON") &&
    panel_source.include?("WILLDEEP_MEDIA_REQUEST_FORMAT=multipart") &&
    panel_source.include?("source_image_path / mask_path") &&
    panel_source.include?("WILLDEEP_MEDIA_SOURCE_IMAGE_FIELD / WILLDEEP_MEDIA_MASK_FIELD") &&
    panel_source.include?("*-candidate-N sibling") &&
    panel_source.include?("show_widget") &&
    panel_source.include?("widget-preview.html"),
  "short drama production package handoff exposes timeline path" =>
    panel_source.include?("剪辑时间线：") &&
    panel_source.include?("\\(export.timelineURL.path)") &&
    panel_source.include?("缺口报告：") &&
    panel_source.include?("\\(export.gapReportURL.path)") &&
    panel_source.include?("分镜 CSV 清单：") &&
    panel_source.include?("\\(export.shotListCSVURL.path)") &&
    panel_source.include?("审片 CSV 模板：") &&
    panel_source.include?("\\(export.reviewTemplateCSVURL.path)") &&
    panel_source.include?("检查项修复队列：") &&
    panel_source.include?("\\(export.reviewQueueCSVURL.path)") &&
    panel_source.include?("productionPackageHandoff(export: export, action: \"production_package_exported\")") &&
    panel_source.include?("productionPackageHandoff(export: export, action: \"production_package_imported\")") &&
    panel_source.include?("<production-package-handoff>") &&
    panel_source.include?("dry_run_import_arguments: package_directory=\\(export.directory.path), dry_run=true, import_pending_tasks=true") &&
    panel_source.include?("submit_import_arguments: package_directory=\\(export.directory.path), dry_run=false, import_pending_tasks=true") &&
    panel_source.include?("review_template_import_arguments: package_directory=\\(export.directory.path), dry_run=true") &&
    panel_source.include?("review_queue_import_arguments: file_path=\\(export.reviewQueueCSVURL.path), dry_run=true") &&
    panel_source.include?("widget_arguments: title=短剧制作预览, html_path=\\(export.widgetPreviewURL.path)") &&
    tools_source.include?("Production timeline: \\(export.timelineURL.path)") &&
    tools_source.include?("Production gap report: \\(export.gapReportURL.path)") &&
    tools_source.include?("Production shot list CSV: \\(export.shotListCSVURL.path)") &&
    tools_source.include?("Production review template CSV: \\(export.reviewTemplateCSVURL.path)") &&
    tools_source.include?("Production review queue CSV: \\(export.reviewQueueCSVURL.path)") &&
    tools_source.include?("action: short_drama_export_production_package") &&
    tools_source.include?("let widgetStatus = await queueProductionPackageWidgetIfAvailable(export: export, context: context)") &&
    tools_source.include?("private static func queueProductionPackageWidgetIfAvailable(") &&
    tools_source.include?("AgentWidget(title: \"短剧制作预览\", html: html, contextLines: contextLines)") &&
    tools_source.include?("AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)") &&
    tools_source.include?("AgentSidePanelOpenRequest(kind: .widget)") &&
    tools_source.include?("Widget panel: \\(widgetStatus)") &&
    tools_source.include?("\"<production-package-handoff>\",") &&
    tools_source.include?("\"action: short_drama_export_production_package_widget\",") &&
    tools_source.include?("\"manifest_path: \\(export.mediaManifestTemplateURL.path)\",") &&
    tools_source.include?("\"timeline_path: \\(export.timelineURL.path)\",") &&
    tools_source.include?("\"gap_report_path: \\(export.gapReportURL.path)\",") &&
    tools_source.include?("\"review_template_import_arguments: package_directory=\\(export.directory.path), dry_run=true\",") &&
    tools_source.include?("\"review_queue_import_arguments: file_path=\\(export.reviewQueueCSVURL.path), dry_run=true\",") &&
    tools_source.include?("\"widget_context: production_package_preview\",") &&
    tools_source.include?("\"</production-package-handoff>\"") &&
    tools_source.include?("dry_run_import_arguments: package_directory=\\(export.directory.path), dry_run=true, import_pending_tasks=true") &&
    tools_source.include?("submit_import_arguments: package_directory=\\(export.directory.path), dry_run=false, import_pending_tasks=true") &&
    tools_source.include?("review_queue_import_arguments: file_path=\\(export.reviewQueueCSVURL.path), dry_run=true") &&
    tools_source.include?("widget_arguments: title=短剧制作预览, html_path=\\(export.widgetPreviewURL.path)"),
  "short drama side panel can export episode package" =>
    panel_source.include?("exportEpisodePackage(project: AgentShortDramaProject, episode: AgentShortDramaEpisode)") &&
    panel_source.include?("AgentShortDramaProductionExporter.export(project: project, episodeID: episode?.id)") &&
    short_drama_source.include?("exportEpisodePackage(project: project, episode: episode)") &&
    short_drama_source.include?("导出本集制作包") &&
    storyboard_widget_source.include?("production-timeline.json") &&
    production_exporter_source.include?("episodeID == nil ? \"project\" : \"episode\"") &&
    production_exporter_source.include?("let scopedShots = copy.episodes.flatMap(\\.shots)") &&
    production_exporter_source.include?("let sceneIDs = Set(scopedShots.compactMap(\\.sceneID))") &&
    production_exporter_source.include?("let characterIDs = Set(scopedShots.flatMap(\\.characterIDs))") &&
    production_exporter_source.include?("copy.scenes = copy.scenes.filter { sceneIDs.contains($0.id) }") &&
    production_exporter_source.include?("copy.characters = copy.characters.filter { characterIDs.contains($0.id) }"),
  "short drama selected artifact defaults to images" =>
    short_drama_source.include?("private func preferredSelectedArtifact(in paths: [String]) -> String?") &&
    short_drama_source.include?("paths.first(where: isImagePath) ?? paths.first") &&
    short_drama_source.include?("selectedArtifactPath = preferredSelectedArtifact(in: shot.artifactPaths)") &&
    tools_source.include?("nonisolated private static func preferredSelectedArtifact(in paths: [String]) -> String?") &&
    tools_source.include?("?? preferredSelectedArtifact(in: artifactPaths)"),
  "short drama can show episode storyboard widget" =>
    storyboard_widget_source.include?("static func widget(") &&
    storyboard_widget_source.include?("episode: AgentShortDramaEpisode") &&
    storyboard_widget_source.include?("mediaTasks: [AgentMediaTask] = []") &&
    short_drama_source.include?("showEpisodeStoryboardWidget(project: project, episode: episode)") &&
    short_drama_source.include?("生成本集网页分镜板") &&
    tools_source.include?('optionalUUID(arguments["episode_id"])') &&
    registry_source.include?('name: "episode_id"') &&
    registry_source.include?("the storyboard widget only includes that episode"),
  "storyboard widget supports episode batch generation prompts" =>
    storyboard_widget_source.include?("<short-drama-project-widget-action>") &&
    storyboard_widget_source.include?("projectBatchPrompt(project: project, kind: \"image_generation\")") &&
    storyboard_widget_source.include?("projectBatchPrompt(project: project, kind: \"video_generation\")") &&
    storyboard_widget_source.include?("private static func projectContinuityPrompt(project: AgentShortDramaProject) -> String") &&
    storyboard_widget_source.include?("generate_project_images") &&
    storyboard_widget_source.include?("generate_project_videos") &&
    storyboard_widget_source.include?("continuity_review_project") &&
    storyboard_widget_source.include?("全剧图片") &&
    storyboard_widget_source.include?("全剧视频") &&
    storyboard_widget_source.include?("全剧检查") &&
    storyboard_widget_source.include?("short_drama_generate_batch_media") &&
    storyboard_widget_source.include?("short_drama_upsert_review_item") &&
    storyboard_widget_source.include?("<short-drama-episode-widget-action>") &&
    storyboard_widget_source.include?("episodeBatchPrompt(project: project, episode: episode, kind: \"image_generation\")") &&
    storyboard_widget_source.include?("episodeBatchPrompt(project: project, episode: episode, kind: \"video_generation\")") &&
    storyboard_widget_source.include?("批量图片") &&
    storyboard_widget_source.include?("批量视频") &&
    storyboard_widget_source.include?("请调用 short_drama_generate_batch_media，并传入 project_id、episode_id"),
  "storyboard widget supports episode package export prompt" =>
    storyboard_widget_source.include?("projectExportPrompt(project: project)") &&
    storyboard_widget_source.include?("导出全剧包") &&
    storyboard_widget_source.include?("action: export_project_package") &&
    storyboard_widget_source.include?("episodeExportPrompt(project: project, episode: episode)") &&
    storyboard_widget_source.include?("导出本集包") &&
    storyboard_widget_source.include?("action: export_episode_package") &&
    storyboard_widget_source.include?("short_drama_export_production_package") &&
    storyboard_widget_source.include?("media-api.env.example"),
  "short drama structure delete tool is registered and context-aware" =>
    registry_source.include?('name: "short_drama_delete_structure_item"') &&
    registry_source.include?("Delete one short-drama structure item") &&
    registry_source.include?('AgentToolParameter(name: "item_type"') &&
    registry_source.include?('AgentToolParameter(name: "dry_run"') &&
    short_drama_dispatcher_source.include?('case "short_drama_delete_structure_item"') &&
    tools_source.include?("static func deleteStructureItem(") &&
    tools_source.include?("private struct StructureDeletionPlan") &&
    tools_source.include?("<short-drama-structure-delete>") &&
    short_drama_source.include?("func deleteEpisode(projectID: UUID, episodeID: UUID)") &&
    short_drama_source.include?("func deleteShot(projectID: UUID, episodeID: UUID?, shotID: UUID)") &&
    short_drama_source.include?("func deleteCharacter(projectID: UUID, characterID: UUID)") &&
    short_drama_source.include?("func deleteScene(projectID: UUID, sceneID: UUID)") &&
    short_drama_source.include?("delete_episode_dry_run_arguments") &&
    short_drama_source.include?("delete_shot_dry_run_arguments") &&
    short_drama_source.include?("delete_asset_dry_run_arguments"),
  "short drama structure reorder tool is registered and context-aware" =>
    registry_source.include?('name: "short_drama_reorder_structure_items"') &&
    registry_source.include?("Reorder short-drama episodes") &&
    registry_source.include?('AgentToolParameter(name: "ordered_ids"') &&
    short_drama_dispatcher_source.include?('case "short_drama_reorder_structure_items"') &&
    tools_source.include?("static func reorderStructureItems(") &&
    tools_source.include?("private struct ReorderStructureResult") &&
    tools_source.include?("<short-drama-structure-reorder>") &&
    short_drama_source.include?("func reorderEpisodes(projectID: UUID, orderedIDs: [UUID])") &&
    short_drama_source.include?("func reorderShots(projectID: UUID, episodeID: UUID, orderedIDs: [UUID])") &&
    short_drama_source.include?("reorder_episodes_dry_run_arguments") &&
    short_drama_source.include?("reorder_shots_dry_run_arguments"),
  "short drama shot duplicate tool is registered and context-aware" =>
    registry_source.include?('name: "short_drama_duplicate_shot"') &&
    registry_source.include?("Duplicate an existing short-drama shot") &&
    registry_source.include?('AgentToolParameter(name: "copy_artifacts"') &&
    registry_source.include?('AgentToolParameter(name: "copy_review_items"') &&
    short_drama_dispatcher_source.include?('case "short_drama_duplicate_shot"') &&
    tools_source.include?("static func duplicateShot(") &&
    tools_source.include?("<short-drama-shot-duplicated>") &&
    tools_source.include?("generate_new_shot_image_tool: short_drama_generate_shot_media") &&
    short_drama_source.include?("func duplicateShot(") &&
    short_drama_source.include?("copyArtifacts: Bool") &&
    short_drama_source.include?("copyReviewItems: Bool") &&
    short_drama_source.include?("duplicate_shot_arguments"),
  "short drama shot move tool retargets media task anchors" =>
    registry_source.include?('name: "short_drama_move_shot"') &&
    registry_source.include?("Move an existing short-drama shot to another episode") &&
    registry_source.include?('AgentToolParameter(name: "target_episode_id"') &&
    short_drama_dispatcher_source.include?('case "short_drama_move_shot"') &&
    tools_source.include?("static func moveShot(") &&
    tools_source.include?("<short-drama-shot-moved>") &&
    tools_source.include?("updated_media_task_count") &&
    media_tasks_source.include?("func moveShortDramaShotAnchors(projectID: UUID, shotID: UUID, episodeID: UUID) -> Int") &&
    short_drama_source.include?("func moveShot(") &&
    short_drama_source.include?("targetEpisodeID: UUID") &&
    short_drama_source.include?("move_shot_arguments"),
  "short drama batch shot status tool is registered and context-aware" =>
    registry_source.include?('name: "short_drama_update_shot_statuses"') &&
    registry_source.include?("Batch update short-drama shot statuses") &&
    registry_source.include?('AgentToolParameter(name: "shot_ids"') &&
    registry_source.include?('AgentToolParameter(name: "dry_run"') &&
    short_drama_dispatcher_source.include?('case "short_drama_update_shot_statuses"') &&
    tools_source.include?("static func updateShotStatuses(") &&
    tools_source.include?("<short-drama-shot-status-batch>") &&
    short_drama_source.include?("func updateShotStatuses(") &&
    short_drama_source.include?("batch_status_dry_run_arguments") &&
    short_drama_source.include?("batch_episode_status_dry_run_arguments"),
  "short drama batch shot links tool is registered and context-aware" =>
    registry_source.include?('name: "short_drama_update_shot_links"') &&
    registry_source.include?("Batch assign or adjust short-drama shot scene and character links") &&
    registry_source.include?('AgentToolParameter(name: "scene_id"') &&
    registry_source.include?('AgentToolParameter(name: "clear_scene"') &&
    registry_source.include?('AgentToolParameter(name: "character_ids"') &&
    registry_source.include?('AgentToolParameter(name: "append_character_ids"') &&
    registry_source.include?('AgentToolParameter(name: "remove_character_ids"') &&
    short_drama_dispatcher_source.include?('case "short_drama_update_shot_links"') &&
    tools_source.include?("static func updateShotLinks(") &&
    tools_source.include?("<short-drama-shot-links-batch>") &&
    tools_source.include?("append_character_ids") &&
    tools_source.include?("remove_character_ids") &&
    short_drama_source.include?("func updateShotLinks(") &&
    short_drama_chat_context_source.include?("batch_links_dry_run_arguments") &&
    short_drama_chat_context_source.include?("batch_episode_links_dry_run_arguments") &&
    short_drama_chat_context_source.include?("update_shot_links_dry_run_arguments"),
}
end
