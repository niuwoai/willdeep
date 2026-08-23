#!/usr/bin/env ruby
# frozen_string_literal: true

# short_drama_media_contract_test.rb — guard the short-drama production package
# handoff contract: exported package files, manifest import knobs, and the
# embedded Ruby script template.
#
# Usage:
#   ruby scripts/short_drama_media_contract_test.rb
#   ruby scripts/short_drama_media_contract_test.rb build/ci/short_drama_media_report.md build/ci/short_drama_media_report.json

require "fileutils"
require "json"
require "open3"
require "time"
require_relative "short_drama_media_contract_plan_import_checks"
require_relative "short_drama_media_contract_media_task_checks"
require_relative "short_drama_media_contract_media_tool_checks"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/short_drama_media_contract/report.md"
json_path = ARGV[1] || "build/short_drama_media_contract/report.json"
scratch_dir = File.join(repo_root, "build", "short_drama_media_contract")

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def extract_ruby_template(source)
  marker = "static func rubyMediaScriptTemplate() -> String {"
  start = source.index(marker)
  return nil unless start

  after_marker = source[start..]
  opener = after_marker.index('"""')
  return nil unless opener

  body_start = start + opener + 3
  closer = source.index("\n        \"\"\"", body_start)
  return nil unless closer

  raw = source[body_start...closer]
  raw.lines.map { |line| line.sub(/\A        /, "") }.join
end

def extract_swift_triple_quote(source, marker)
  start = source.index(marker)
  return nil unless start

  after_marker = source[start..]
  opener = after_marker.index('"""')
  return nil unless opener

  body_start = start + opener + 3
  closer = source.index("\n        \"\"\"", body_start)
  return nil unless closer

  raw = source[body_start...closer]
  raw.lines.map { |line| line.sub(/\A        /, "") }.join
end

checks = []
add_check = lambda do |name, status, evidence|
  checks << {
    name: name,
    status: status ? "passed" : "failed",
    evidence: evidence
  }
end

tools_source = read_file(repo_root, "Xedit/AgentShortDramaTools.swift")
production_exporter_source = [
  read_file(repo_root, "Xedit/AgentShortDramaProductionExporter.swift"),
  read_file(repo_root, "Xedit/AgentShortDramaProductionExporterWidgetHTML.swift"),
  read_file(repo_root, "Xedit/AgentShortDramaProductionExporterHandoffTemplates.swift"),
  read_file(repo_root, "Xedit/AgentShortDramaProductionGapReportLinks.swift"),
  read_file(repo_root, "Xedit/AgentShortDramaProductionReviewQueue.swift")
].join("\n")
production_review_recommendations_source = read_file(repo_root, "Xedit/AgentShortDramaProductionReviewRecommendations.swift")
image_tools_source = read_file(repo_root, "Xedit/AgentShortDramaImageTools.swift")
batch_tools_source = read_file(repo_root, "Xedit/AgentShortDramaBatchTools.swift")
short_drama_dispatcher_source = read_file(repo_root, "Xedit/AgentShortDramaToolDispatcher.swift")
media_task_tools_source = read_file(repo_root, "Xedit/AgentShortDramaMediaTaskTools.swift")
# AgentToolRunner 已按职责拆到多个同前缀文件，契约断言看的是整体行为，
# 所以这里把总分发和各工具实现拼成一份源码再做包含性检查。
dispatch_source = [
  read_file(repo_root, "Xedit/AgentTools.swift"),
  read_file(repo_root, "Xedit/AgentToolsFileEditing.swift"),
  read_file(repo_root, "Xedit/AgentToolsCommandExecution.swift"),
  read_file(repo_root, "Xedit/AgentToolsDelegatedAgents.swift"),
  read_file(repo_root, "Xedit/AgentToolsJobs.swift"),
  read_file(repo_root, "Xedit/AgentToolsExpertsAndSchedules.swift"),
  read_file(repo_root, "Xedit/AgentToolsWidgets.swift")
].join("\n")
media_tools_source = read_file(repo_root, "Xedit/AgentMediaTools.swift")
short_drama_main_source = read_file(repo_root, "Xedit/AgentShortDrama.swift")
short_drama_chat_context_source = read_file(repo_root, "Xedit/AgentShortDramaChatContext.swift")
short_drama_gap_actions_source = read_file(repo_root, "Xedit/AgentShortDramaProductionGapActions.swift")
short_drama_source = [short_drama_main_source, short_drama_chat_context_source, short_drama_gap_actions_source].join("\n")
asset_views_source = read_file(repo_root, "Xedit/AgentShortDramaAssetViews.swift")
media_tasks_source = read_file(repo_root, "Xedit/AgentMediaTasks.swift")
media_task_handoff_source = read_file(repo_root, "Xedit/AgentMediaTaskChatHandoff.swift")
media_artifact_views_source = read_file(repo_root, "Xedit/AgentMediaArtifactViews.swift")
generic_media_source = read_file(repo_root, "Xedit/AgentGenericMediaStatusIntegration.swift")
some_im_source = read_file(repo_root, "Xedit/SomeIMAsyncMediaIntegration.swift")
replicate_source = read_file(repo_root, "Xedit/ReplicateIntegration.swift")
image_edit_source = read_file(repo_root, "Xedit/AgentImageEditPanel.swift")
storyboard_widget_source = read_file(repo_root, "Xedit/AgentShortDramaStoryboardWidgetBuilder.swift")
import_source = read_file(repo_root, "Xedit/AgentMediaImportTools.swift")
registry_source = read_file(repo_root, "Xedit/AgentToolRegistry.swift")
panel_source = read_file(repo_root, "Xedit/AgentShortDramaExportActions.swift")
side_panel_source = read_file(repo_root, "Xedit/AgentSidePanel.swift")
mode_view_source = read_file(repo_root, "Xedit/AgentModeView.swift")
conversation_activity_overlay_source = read_file(repo_root, "Xedit/AgentConversationActivityOverlay.swift")
app_state_source = read_file(repo_root, "Xedit/AppState.swift")
app_state_loop_source = [
  read_file(repo_root, "Xedit/AppStateAgentLoop.swift"),
  read_file(repo_root, "Xedit/AppStateAgentMediaTaskNotices.swift")
].join("\n")
chat_header_source = read_file(repo_root, "Xedit/AgentChatHeader.swift")
widget_registry_source = read_file(repo_root, "Xedit/AgentWidgetRegistry.swift")
widget_source = read_file(repo_root, "Xedit/AgentWidget.swift")
widget_card_source = read_file(repo_root, "Xedit/AgentWidgetCardView.swift")
task_monitor_source = read_file(repo_root, "Xedit/AgentTaskMonitorRail.swift")

export_required = [
  "production-package.json",
  "production-package.md",
  "production-timeline.json",
  "production-shot-list.csv",
  "production-review-template.csv",
  "production-review-queue.csv",
  "media-import-manifest-template.json",
  "ruby-media-script-template.rb",
  "media-api.env.example",
  "widget-preview.html",
  "outputs"
]
export_required.each do |token|
  add_check.call(
    "export includes #{token}",
    production_exporter_source.include?(token) || tools_source.include?(token) || panel_source.include?(token),
    "`#{token}` referenced by production exporter or side-panel handoff."
  )
end

env_example_tokens = [
  "mediaAPIEnvExampleTemplate",
  "WILLDEEP_MEDIA_API_URL=",
  "WILLDEEP_MEDIA_API_TOKEN=",
  "WILLDEEP_MEDIA_API_METHOD=POST",
  "WILLDEEP_MEDIA_EXTRA_HEADERS_JSON=",
  "WILLDEEP_MEDIA_REQUEST_FORMAT=json",
  "WILLDEEP_MEDIA_REQUEST_PRESET=",
  "WILLDEEP_MEDIA_SOURCE_IMAGE_FIELD=image",
  "WILLDEEP_MEDIA_MASK_FIELD=mask",
  "WILLDEEP_REPLICATE_EXTRA_INPUT_JSON=",
  "WILLDEEP_MEDIA_PROVIDER=skill",
  "WILLDEEP_MEDIA_MODEL=",
  "WILLDEEP_MEDIA_POLL_URL_TEMPLATE=",
  "WILLDEEP_MEDIA_SUBMIT_ONLY=0",
  "WILLDEEP_MEDIA_EMBED_LOCAL_FILES=0"
]
env_example_tokens.each do |token|
  add_check.call(
    "env example token #{token}",
    production_exporter_source.include?(token),
    "Production package exports a secret-free environment example for Ruby/API handoff."
  )
end

manifest_fields = [
  'case baseDirectory = "base_directory"',
  'case filePath = "file_path"',
  'case taskTitle = "task_title"',
  'case statusEndpointSuffix = "status_endpoint_suffix"',
  'case cancelEndpointSuffix = "cancel_endpoint_suffix"',
  'case projectID = "project_id"',
  'case episodeID = "episode_id"',
  'case shotID = "shot_id"',
  'case assetKind = "asset_kind"',
  'case assetID = "asset_id"',
  'case reviewItemID = "review_item_id"',
  'case suggestedAction = "suggested_action"'
]
manifest_fields.each do |token|
  add_check.call(
    "manifest template field #{token}",
    production_exporter_source.include?(token),
    "Exporter template exposes importer-compatible coding key."
  )
end

timeline_contract = {
  "production timeline is exported" =>
    production_exporter_source.include?("var timelineURL: URL") &&
    production_exporter_source.include?('appendingPathComponent("production-timeline.json"') &&
    production_exporter_source.include?("try encoder.encode(timeline(for: package)).write") &&
    production_exporter_source.include?("timelineURL: timelineURL"),
  "production gap report json is exported" =>
    production_exporter_source.include?("var gapReportURL: URL") &&
    production_exporter_source.include?("struct GapReport: Codable") &&
    production_exporter_source.include?('appendingPathComponent("production-gap-report.json"') &&
    production_exporter_source.include?("try encoder.encode(gapReport(for: package)).write") &&
    production_exporter_source.include?("private static func gapReport(for package: Package) -> GapReport") &&
    production_exporter_source.include?('case missingImageCount = "missing_image_count"') &&
    production_exporter_source.include?('case missingVideoCount = "missing_video_count"') &&
    production_exporter_source.include?('case missingAssetReferenceCount = "missing_asset_reference_count"') &&
    production_exporter_source.include?("struct Asset: Codable") &&
    production_exporter_source.include?('case referenceImageCount = "reference_image_count"') &&
    production_exporter_source.include?('case missingReference = "missing_reference"') &&
    production_exporter_source.include?('case linkedShotCount = "linked_shot_count"') &&
    production_exporter_source.include?('case linkedShotIDs = "linked_shot_ids"') &&
    production_exporter_source.include?('case linkedShotImageDryRunArguments = "linked_shot_image_dry_run_arguments"') &&
    production_exporter_source.include?('case linkedShotImageSubmitArguments = "linked_shot_image_submit_arguments"') &&
    production_exporter_source.include?('case linkedShotVideoDryRunArguments = "linked_shot_video_dry_run_arguments"') &&
    production_exporter_source.include?('case linkedShotVideoSubmitArguments = "linked_shot_video_submit_arguments"') &&
    production_exporter_source.include?('case generateReferenceDryRunArguments = "generate_reference_dry_run_arguments"') &&
    production_exporter_source.include?('case generateReferenceArguments = "generate_reference_arguments"') &&
    production_exporter_source.include?("private static func gapReportAssets(for project: AgentShortDramaProject) -> [GapReport.Asset]") &&
    production_exporter_source.include?("private static func gapReportAsset(") &&
    production_exporter_source.include?("linkedShotIDs: linkedShotIDs(forCharacterID: character.id, in: project)") &&
    production_exporter_source.include?("linkedShotIDs: linkedShotIDs(forSceneID: scene.id, in: project)") &&
    production_exporter_source.include?("private static func orderedUniqueShotIDs(") &&
    production_exporter_source.include?("linkedShotCount: linkedShotIDs.count") &&
    production_exporter_source.include?("let linkedShotArguments = linkedShotIDs.isEmpty ? nil : \"project_id=\\(projectID), shot_ids=[\\(linkedShotIDs.joined(separator: \",\"))]\"") &&
    production_exporter_source.include?("linkedShotImageDryRunArguments: linkedShotArguments.map { \"\\($0), kind=image_generation, target_filter=missing, dry_run=true\" }") &&
    production_exporter_source.include?("linkedShotVideoSubmitArguments: linkedShotArguments.map { \"\\($0), kind=video_generation, target_filter=missing, dry_run=false\" }") &&
    production_exporter_source.include?("missingAssetReferenceCount: assets.filter(\\.missingReference).count") &&
    production_exporter_source.include?("generateReferenceDryRunArguments: referenceImageCount == 0 ? generateDryRunArguments : nil") &&
    production_exporter_source.include?("generateReferenceArguments: referenceImageCount == 0 ? generateArguments : nil") &&
    production_exporter_source.include?('case batchActions = "batch_actions"') &&
    production_exporter_source.include?('case imageDryRunArguments = "image_dry_run_arguments"') &&
    production_exporter_source.include?('case imageSubmitArguments = "image_submit_arguments"') &&
    production_exporter_source.include?('case videoSubmitArguments = "video_submit_arguments"') &&
    production_exporter_source.include?("imageSubmitArguments: missingImage ? \"\\(baseArguments), kind=image_generation, dry_run=false\" : nil") &&
    production_exporter_source.include?("videoSubmitArguments: missingVideo ? \"\\(baseArguments), kind=video_generation, dry_run=false\" : nil") &&
    production_exporter_source.include?("private static func gapReportBatchActionPrefix(for package: Package) -> String") &&
    production_exporter_source.include?("package.scope == \"episode\"") &&
    production_exporter_source.include?("return \"project_id=\\(projectID), episode_id=\\(episodeID)\"") &&
    production_exporter_source.include?("target_filter=missing, dry_run=true") &&
    production_exporter_source.include?("gapReportURL: gapReportURL"),
  "production shot list csv is exported" =>
    production_exporter_source.include?("var shotListCSVURL: URL") &&
    production_exporter_source.include?('appendingPathComponent("production-shot-list.csv"') &&
    production_exporter_source.include?("private static func shotListCSV(for package: Package) -> String") &&
    production_exporter_source.include?("nonisolated static func csvRow(_ fields: [String]) -> String") &&
    production_exporter_source.include?("nonisolated static func csvField(_ raw: String) -> String") &&
    production_exporter_source.include?('"project_id"') &&
    production_exporter_source.include?('"episode_order"') &&
    production_exporter_source.include?('"selected_image_path"') &&
    production_exporter_source.include?('"open_review_item_count"') &&
    production_exporter_source.include?("videoPaths.joined(separator: \"\\n\")") &&
    production_exporter_source.include?("shotListCSVURL: shotListCSVURL"),
  "production review template csv is exported" =>
    production_exporter_source.include?("var reviewTemplateCSVURL: URL") &&
    production_exporter_source.include?('appendingPathComponent("production-review-template.csv"') &&
    production_exporter_source.include?("private static func reviewTemplateCSV(for package: Package) -> String") &&
    production_exporter_source.include?('"review_title"') &&
    production_exporter_source.include?('"review_status"') &&
    production_exporter_source.include?('"suggested_action"') &&
    production_exporter_source.include?('"review_item_id"') &&
    production_exporter_source.include?("reviewTemplateCSVURL: reviewTemplateCSVURL"),
  "production review queue csv is exported" =>
    production_exporter_source.include?("var reviewQueueCSVURL: URL") &&
    production_exporter_source.include?('appendingPathComponent("production-review-queue.csv"') &&
    production_exporter_source.include?("static func reviewQueueCSV(for package: Package) -> String") &&
    production_exporter_source.include?('"review_item_id"') &&
    production_exporter_source.include?('"suggested_action"') &&
    production_exporter_source.include?('"artifact_paths"') &&
    production_exporter_source.include?('"recommended_tool"') &&
    production_exporter_source.include?('"recommended_arguments"') &&
    production_exporter_source.include?('"open_review_tasks_arguments"') &&
    production_exporter_source.include?('"refresh_review_tasks_arguments"') &&
    production_exporter_source.include?('"resolve_review_arguments"') &&
    production_exporter_source.include?("let recommendation = productionReviewItemRecommendation(") &&
    production_exporter_source.include?("let reviewTasksArguments = \"\\(baseArguments), scope=review_item, review_item_id=\\(item.id.uuidString)\"") &&
    production_exporter_source.include?("recommendation.tool") &&
    production_exporter_source.include?("recommendation.arguments") &&
    production_exporter_source.include?("\"\\(baseArguments), item_id=\\(item.id.uuidString)\"") &&
    production_exporter_source.include?("for item in shot.reviewItems where item.status != .resolved") &&
    production_exporter_source.include?("reviewQueueCSVURL: reviewQueueCSVURL"),
  "production manifest creates repair items for open review queue" =>
    production_exporter_source.include?("var reviewItemID: String? = nil") &&
    production_exporter_source.include?("var suggestedAction: String? = nil") &&
    production_exporter_source.include?("for reviewItem in shot.reviewItems where reviewItem.status != .resolved") &&
    production_exporter_source.include?("guard let repairKind = repairManifestKind(for: reviewItem.kind)") &&
    production_exporter_source.include?("reviewItemID: reviewItem.id.uuidString") &&
    production_exporter_source.include?("suggestedAction: reviewItem.suggestedAction") &&
    production_exporter_source.include?("private static func repairManifestKind") &&
    production_exporter_source.include?("return \"image_inpaint\"") &&
    production_exporter_source.include?("return \"image_erase\"") &&
    production_exporter_source.include?("return \"image_upscale\"") &&
    production_exporter_source.include?("return \"image_generation\"") &&
    production_exporter_source.include?("private static func reviewRepairPrompt") &&
    production_exporter_source.include?("Suggested action: \\(suggestedAction)"),
  "production timeline has edit-friendly fields" =>
    production_exporter_source.include?("struct Timeline: Codable") &&
    production_exporter_source.include?('case exportedAt = "exported_at"') &&
    production_exporter_source.include?('case projectID = "project_id"') &&
    production_exporter_source.include?('case selectedImagePath = "selected_image_path"') &&
    production_exporter_source.include?('case videoPaths = "video_paths"') &&
    production_exporter_source.include?('case imagePaths = "image_paths"') &&
    production_exporter_source.include?('case openReviewItemCount = "open_review_item_count"'),
  "production timeline is ordered and classifies artifacts" =>
    production_exporter_source.include?("project.episodes.sorted(by: { $0.order < $1.order })") &&
    production_exporter_source.include?("episode.shots.sorted(by: { $0.order < $1.order })") &&
    production_exporter_source.include?("selectedImagePath: selectedImagePath(for: shot)") &&
    production_exporter_source.include?("videoPaths: shot.artifactPaths.filter(isVideoPath)") &&
    production_exporter_source.include?("imagePaths: shot.artifactPaths.filter(isImagePath)") &&
    production_exporter_source.include?("openReviewItemCount: shot.reviewItems.filter { $0.status != .resolved }.count"),
  "production markdown references timeline handoff" =>
    production_exporter_source.include?("Production timeline: `production-timeline.json`") &&
    production_exporter_source.include?("Production gap report: `production-gap-report.json`") &&
    production_exporter_source.include?("Production shot list CSV: `production-shot-list.csv`") &&
    production_exporter_source.include?("Review import template CSV: `production-review-template.csv`") &&
    production_exporter_source.include?("Review fix queue CSV: `production-review-queue.csv`") &&
    production_exporter_source.include?("For editing, assembly, or delivery scripts, read `production-timeline.json` first") &&
    production_exporter_source.include?("For machine-readable gap planning, read `production-gap-report.json`") &&
    production_exporter_source.include?("missing character/scene reference images") &&
    production_exporter_source.include?("each asset's `linked_shot_ids`") &&
    production_exporter_source.include?("ready-to-run asset-scoped `short_drama_generate_batch_media(shot_ids=...)` dry-run / submit arguments") &&
    production_exporter_source.include?("ready-to-run per-shot `short_drama_generate_shot_media` dry-run / submit arguments") &&
    production_exporter_source.include?("ready-to-run `short_drama_generate_asset_media` dry-run / submit arguments") &&
    production_exporter_source.include?("ready-to-run project/episode `short_drama_generate_batch_media(target_filter=missing)` dry-run / submit arguments") &&
    production_exporter_source.include?("read `production-shot-list.csv`, which flattens the same shot order into one row per shot") &&
    production_exporter_source.include?("fill `production-review-template.csv` and import it with `short_drama_import_review_csv(package_directory: <this package directory>)`") &&
    production_exporter_source.include?("read `production-review-queue.csv`, which flattens each unresolved review item into a repair task row") &&
    production_exporter_source.include?("with `recommended_tool`, `recommended_arguments`, review-task scope arguments, and resolve arguments") &&
    production_exporter_source.include?("The Ruby template can also update `production-review-queue.csv` when a manifest item carries `review_item_id`") &&
    production_exporter_source.include?("short_drama_import_review_csv(file_path: <this package directory>/production-review-queue.csv)"),
  "production widget previews expose timeline handoff" =>
    production_exporter_source.scan("production-timeline.json").length >= 4 &&
    production_exporter_source.scan("production-gap-report.json").length >= 4 &&
    production_exporter_source.scan("按时间线继续").length >= 2 &&
    production_exporter_source.scan("按缺口报告排产").length >= 2 &&
    production_exporter_source.scan("production-shot-list.csv").length >= 5 &&
    production_exporter_source.scan("production-review-template.csv").length >= 4 &&
    production_exporter_source.scan("production-review-queue.csv").length >= 4 &&
    production_exporter_source.scan("按 CSV 审片").length >= 2 &&
    production_exporter_source.include?("一镜一行的平面清单") &&
    production_exporter_source.include?("一条 reviewItem 一行的修复队列") &&
    production_exporter_source.include?("Review queue updates") &&
    production_exporter_source.include?("回写修复队列") &&
    production_exporter_source.include?("输出可执行的审片/剪辑准备清单") &&
    production_exporter_source.include?("缺失镜头和未解决检查项") &&
    production_exporter_source.include?("missing_asset_reference_count、missing_image_count、missing_video_count 和 open_review_item_count") &&
    production_exporter_source.include?("assets[].generate_reference_dry_run_arguments") &&
    production_exporter_source.include?("assets[].generate_reference_arguments") &&
    production_exporter_source.include?("linked_shot_image_dry_run_arguments") &&
    production_exporter_source.include?("linked_shot_video_submit_arguments") &&
    production_exporter_source.include?("剪辑脚本继续装配成片"),
  "production widget previews render shot timeline status" =>
    production_exporter_source.include?("private static func timelineSummaryHTML") &&
    production_exporter_source.include?("缺主图") &&
    production_exporter_source.include?("缺视频") &&
    production_exporter_source.include?("检查项清零") &&
    production_exporter_source.include?("timeline_items = episodes.sort_by") &&
    production_exporter_source.include?("selectedArtifactPath") &&
    production_exporter_source.include?("artifactPaths") &&
    production_exporter_source.include?("reviewItems"),
  "production widget shot rows stage per-shot repair prompts" =>
    production_exporter_source.include?("static func sendPromptButton") &&
    production_exporter_source.include?("private static func jsonStringLiteral") &&
    production_exporter_source.include?("查看任务") &&
    production_exporter_source.include?("short_drama_open_media_tasks") &&
    production_exporter_source.include?("scope=shot") &&
    production_exporter_source.include?("检查连续性") &&
    production_exporter_source.include?("short_drama_upsert_review_item") &&
    production_exporter_source.include?("kind 可用 continuity") &&
    production_exporter_source.include?("选主图") &&
    production_exporter_source.include?("short_drama_show_image_choice_widget") &&
    production_exporter_source.include?("<short-drama-production-image-choice>") &&
    production_exporter_source.include?("recommended_tool: short_drama_show_image_choice_widget") &&
    production_exporter_source.include?("post_select_video_tool: generate_video_from_image") &&
    production_exporter_source.include?("post_select_edit_tool: short_drama_open_image_editor") &&
    production_exporter_source.include?("post_select_erase_tool: short_drama_open_image_editor") &&
    production_exporter_source.include?("post_select_upscale_tool: short_drama_upscale_shot_artifact") &&
    production_exporter_source.include?("post_select_resolve_review_tool: short_drama_resolve_review_item") &&
    production_exporter_source.include?("private static func productionVideoReviewPrompt(") &&
    production_exporter_source.include?("<short-drama-production-video-action>") &&
    production_exporter_source.include?("action: review_shot_video_artifact") &&
    production_exporter_source.include?("video_path: \\(videoPath)") &&
    production_exporter_source.include?("open_shot_tasks_tool: short_drama_open_media_tasks") &&
    production_exporter_source.include?("storyboard_widget_tool: short_drama_show_storyboard_widget") &&
    production_exporter_source.include?("审片视频") &&
    production_exporter_source.include?("imageCount > 1") &&
    production_exporter_source.include?("image_count > 1") &&
    production_exporter_source.include?("video_path = artifacts.find") &&
    production_exporter_source.include?('"video_path: #{video_path}"') &&
    production_exporter_source.include?("video_context = [") &&
    production_exporter_source.include?("蒙版编辑") &&
    production_exporter_source.include?("short_drama_open_image_editor") &&
    production_exporter_source.include?("operation=inpaint") &&
    production_exporter_source.include?("擦除区域") &&
    production_exporter_source.include?("operation=erase") &&
    production_exporter_source.include?("放大主图") &&
    production_exporter_source.include?("short_drama_upscale_shot_artifact") &&
    production_exporter_source.include?("artifact_path=") &&
    production_exporter_source.include?("补主图") &&
    production_exporter_source.include?("kind=image_generation") &&
    production_exporter_source.include?("kind=image_generation、dry_run=true 预检") &&
    production_exporter_source.include?("补视频") &&
    production_exporter_source.include?("kind=video_generation") &&
    production_exporter_source.include?("kind=video_generation、dry_run=true 预检") &&
    production_exporter_source.include?("处理检查项") &&
    production_exporter_source.include?("private static func reviewItemActionButton") &&
    production_exporter_source.include?("<short-drama-review-item-action>") &&
    production_exporter_source.include?("review_item_id: \\(item.id.uuidString)") &&
    production_exporter_source.include?("recommended_tool: \\(recommendation.tool)") &&
    production_exporter_source.include?("recommended_arguments: \\(recommendation.arguments)") &&
    production_exporter_source.include?("review_tasks_tool: short_drama_open_media_tasks") &&
    production_exporter_source.include?("review_tasks_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), scope=review_item, review_item_id=\\(item.id.uuidString)") &&
    production_exporter_source.include?("refresh_review_tasks_tool: short_drama_refresh_media_tasks") &&
    production_exporter_source.include?("refresh_review_tasks_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), scope=review_item, review_item_id=\\(item.id.uuidString)") &&
    production_exporter_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    production_exporter_source.include?("resolve_review_arguments: project_id=\\(project.id.uuidString), episode_id=\\(episode.id.uuidString), shot_id=\\(shot.id.uuidString), item_id=\\(item.id.uuidString)") &&
    production_review_recommendations_source.include?("static func productionReviewItemRecommendation(") &&
    production_review_recommendations_source.include?("struct ProductionReviewItemRecommendation") &&
    production_review_recommendations_source.include?("tool: \"short_drama_open_image_editor\"") &&
    production_review_recommendations_source.include?("tool: \"short_drama_upscale_shot_artifact\"") &&
    production_review_recommendations_source.include?("tool: \"short_drama_generate_shot_media\"") &&
    production_review_recommendations_source.include?("tool: \"short_drama_open_media_tasks\"") &&
    production_exporter_source.include?("review_item_id=...") &&
    production_exporter_source.include?("review_item_action = lambda") &&
    production_exporter_source.include?("review_item_id = review_item_id_for(item)") &&
    production_exporter_source.include?('recommended_tool: #{recommendation[:tool]}') &&
    production_exporter_source.include?('recommended_arguments: #{recommendation[:arguments]}') &&
    production_exporter_source.include?('review_tasks_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, scope=review_item, review_item_id=#{review_item_id}') &&
    production_exporter_source.include?('refresh_review_tasks_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, scope=review_item, review_item_id=#{review_item_id}') &&
    production_exporter_source.include?('resolve_review_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, item_id=#{review_item_id}') &&
    production_exporter_source.include?('"review_item_id: #{review_item_id}"') &&
    production_exporter_source.include?("actions << review_item_action.call") &&
    production_exporter_source.include?("short_drama_resolve_review_item") &&
    production_exporter_source.include?("JSON.dump(\"请为这个短剧分镜补主图") &&
    production_exporter_source.include?('project_id=#{project_id}'),
  "production widget timeline stages scoped batch media prompts" =>
    production_exporter_source.include?("private static func batchTimelineActionsHTML") &&
    production_exporter_source.include?("批量检查连续性") &&
    production_exporter_source.include?("所有分镜的连续性和产物一致性") &&
    production_exporter_source.include?("short_drama_upsert_review_item 写回对应分镜") &&
    production_exporter_source.include?("批量补主图") &&
    production_exporter_source.include?("批量补视频") &&
    production_exporter_source.include?("short_drama_generate_batch_media") &&
    production_exporter_source.include?("dry_run=true") &&
    production_exporter_source.include?("dry_run=false") &&
    production_exporter_source.include?("target_filter=missing") &&
    production_exporter_source.include?("missing_image_count") &&
    production_exporter_source.include?("missing_video_count") &&
    production_exporter_source.include?("episode_clause"),
  "production widget episode management handoff prompts" =>
    production_exporter_source.include?("private static func episodeSummaryHTML") &&
    production_exporter_source.include?("分集管理") &&
    production_exporter_source.include?("episode_items = episodes.sort_by") &&
    production_exporter_source.include?("scope=episode") &&
    production_exporter_source.include?("本集分镜板") &&
    production_exporter_source.include?("short_drama_show_storyboard_widget") &&
    production_exporter_source.include?("这一集所有分镜的连续性") &&
    production_exporter_source.include?("short_drama_generate_batch_media") &&
    production_exporter_source.include?('episode_id=#{episode_id}') &&
    production_exporter_source.include?("主图齐备") &&
    production_exporter_source.include?("视频齐备"),
  "production widget asset reference handoff prompts" =>
    production_exporter_source.include?("private static func assetSummaryHTML") &&
    production_exporter_source.include?("private static func assetRowHTML") &&
    production_exporter_source.include?("参考资产") &&
    production_exporter_source.include?("缺参考图") &&
    production_exporter_source.include?("生成参考图") &&
    production_exporter_source.include?("short_drama_generate_asset_media") &&
    production_exporter_source.include?("scope=asset") &&
    production_exporter_source.include?("编辑参考图") &&
    production_exporter_source.include?("放大参考图") &&
    production_exporter_source.include?("open_asset_reference_editor") &&
    production_exporter_source.include?("upscale_asset_reference") &&
    production_exporter_source.include?("<short-drama-asset-widget-action>") &&
    production_exporter_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    production_exporter_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    production_exporter_source.include?("generate_asset_reference_tool: short_drama_generate_asset_media") &&
    production_exporter_source.include?("generate_asset_reference_dry_run_arguments") &&
    production_exporter_source.include?("dry_run=true 预检") &&
    production_exporter_source.include?("private static func assetTasksPrompt(") &&
    production_exporter_source.include?("open_image_editor") &&
    production_exporter_source.include?("upscale_image") &&
    production_exporter_source.include?('"character"') &&
    production_exporter_source.include?('"scene"') &&
    production_exporter_source.include?('asset_kind=#{asset_kind}') &&
    production_exporter_source.include?("asset_items =") &&
    production_exporter_source.include?("referenceImagePaths")
}
timeline_contract.each do |name, status|
  add_check.call(name, status, "Production timeline contract source check.")
end

import_contract = {
  "import_media_manifest registered" => registry_source.include?('name: "import_media_manifest"'),
  "package_directory parameter registered" => registry_source.include?('name: "package_directory"'),
  "package_directory resolves default manifest" =>
    import_source.include?('arguments["package_directory"]') &&
    import_source.include?('"media-import-manifest-template.json"'),
  "import_media_manifest surfaces widget preview handoff" =>
    import_source.include?("private static func widgetPreviewURL") &&
    import_source.include?('"widget-preview.html"') &&
    import_source.include?("Widget preview: \\(url.path)") &&
    import_source.include?("let packageDirectory = url.deletingLastPathComponent().path") &&
    import_source.include?('"source_label":"import-media-manifest"') &&
    import_source.include?('"source_path":"\\(url.path)"') &&
    import_source.include?('"package_directory":"\\(packageDirectory)"') &&
    import_source.include?('"recommended_tool":"import_media_manifest"') &&
    import_source.include?('"recommended_arguments":"package_directory=\\(packageDirectory), dry_run=true, import_pending_tasks=true"') &&
    import_source.include?("let widgetPreviewHint = widgetPreviewHint(for: widgetPreviewURL)") &&
    import_source.include?("let widgetPreviewStatus = await queueWidgetPreviewIfAvailable(") &&
    import_source.include?("tasks: tasks,") &&
    import_source.include?("pendingTasks: pendingTasks,") &&
    import_source.include?("Widget panel: \\(widgetPreviewStatus)") &&
    import_source.include?("private static func queueWidgetPreviewIfAvailable") &&
    import_source.include?("tasks: [AgentMediaTask]") &&
    import_source.include?("pendingTasks: [AgentMediaTask]") &&
    import_source.include?("AgentWidget(title: \"短剧制作预览\", html: html, contextLines: contextLines)") &&
    import_source.include?("AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)") &&
    import_source.include?("let openMediaTasks = !pendingTasks.isEmpty || !failedTasks.isEmpty") &&
    import_source.include?("let mediaTaskScope = openMediaTasks ? projectScope : nil") &&
    import_source.include?("AgentSidePanelOpenRequest(kind: openMediaTasks ? .mediaTasks : .widget, mediaTaskScope: mediaTaskScope)") &&
    import_source.include?("private static func sharedProjectScope(for tasks: [AgentMediaTask]) -> AgentMediaTaskScope?") &&
    import_source.include?("let projectIDs = Set(tasks.compactMap { clean($0.projectID) ?? clean($0.projectPath) })") &&
    import_source.include?("AgentMediaTaskScope(label: \"导回短剧项目任务\", projectID: projectID)") &&
    import_source.include?("opened media task side panel for pending/failed tasks") &&
    import_source.include?("opened widget side panel") &&
    import_source.include?("<media-import-widget-handoff>") &&
    import_source.include?("action: import_media_manifest_widget_preview") &&
    import_source.include?("let timelineURL = packageURL.appendingPathComponent(\"production-timeline.json\"") &&
    import_source.include?("let gapReportURL = packageURL.appendingPathComponent(\"production-gap-report.json\"") &&
    import_source.include?("let shotListURL = packageURL.appendingPathComponent(\"production-shot-list.csv\"") &&
    import_source.include?("let reviewTemplateURL = packageURL.appendingPathComponent(\"production-review-template.csv\"") &&
    import_source.include?("let reviewQueueURL = packageURL.appendingPathComponent(\"production-review-queue.csv\"") &&
    import_source.include?("let failedTasks = tasks.filter { $0.status == .failed || $0.status == .canceled }") &&
    import_source.include?("let completedTasks = tasks.filter { $0.status == .succeeded }") &&
    import_source.include?("let projectScope = sharedProjectScope(for: tasks)") &&
    import_source.include?("task_count: \\(tasks.count)") &&
    import_source.include?("pending_task_count: \\(pendingTasks.count)") &&
    import_source.include?("failed_task_count: \\(failedTasks.count)") &&
    import_source.include?("completed_task_count: \\(completedTasks.count)") &&
    import_source.include?("task_ids: \\(tasks.isEmpty ? \"(none)\" : tasks.map(\\.displayHandle).joined(separator: \", \"))") &&
    import_source.include?("pending_task_ids: \\(pendingTasks.isEmpty ? \"(none)\" : pendingTasks.map(\\.displayHandle).joined(separator: \", \"))") &&
    import_source.include?("failed_task_ids: \\(failedTasks.isEmpty ? \"(none)\" : failedTasks.map(\\.displayHandle).joined(separator: \", \"))") &&
    import_source.include?("media_task_status_tool: list_media_tasks") &&
    import_source.include?("media_task_status_arguments: only_active=false") &&
    import_source.include?("active_media_task_status_arguments: only_active=true") &&
    import_source.include?("widget_preview_path: \\(url.path)") &&
    import_source.include?("timeline_path: \\(timelineURL.path)") &&
    import_source.include?("gap_report_path: \\(gapReportURL.path)") &&
    import_source.include?("shot_list_path: \\(shotListURL.path)") &&
    import_source.include?("review_template_path: \\(reviewTemplateURL.path)") &&
    import_source.include?("review_queue_path: \\(reviewQueueURL.path)") &&
    import_source.include?("recommended_tool: import_media_manifest") &&
    import_source.include?("recommended_arguments: package_directory=\\(packageDirectory), dry_run=true, import_pending_tasks=true") &&
    import_source.include?("submit_import_tool: import_media_manifest") &&
    import_source.include?("submit_import_arguments: package_directory=\\(packageDirectory), dry_run=false, import_pending_tasks=true") &&
    import_source.include?("review_queue_import_tool: short_drama_import_review_csv") &&
    import_source.include?("review_queue_import_arguments: file_path=\\(reviewQueueURL.path), dry_run=true") &&
    import_source.include?("projectMediaTaskHandoffLines(for: projectScope)") &&
    import_source.include?("private static func projectMediaTaskHandoffLines(for scope: AgentMediaTaskScope?) -> [String]") &&
    import_source.include?("UUID(uuidString: projectID) != nil") &&
    import_source.include?("project_media_tasks_tool: short_drama_open_media_tasks") &&
    import_source.include?("project_media_tasks_arguments: project_id=\\(projectID), scope=project") &&
    import_source.include?("refresh_project_media_tasks_tool: short_drama_refresh_media_tasks") &&
    import_source.include?("refresh_project_media_tasks_arguments: project_id=\\(projectID), scope=project") &&
    import_source.include?("project_media_tasks_scope_label: \\(scope?.label ?? \"导回短剧项目任务\")") &&
    import_source.include?("\\(widgetPreviewHint)"),
  "dry_run parameter registered" => registry_source.include?('name: "dry_run"'),
  "skip_missing parameter registered" => registry_source.include?('name: "skip_missing"'),
  "import_pending_tasks parameter registered" => registry_source.include?('name: "import_pending_tasks"'),
  "dry_run avoids task creation" => import_source.include?("No media tasks were created"),
  "skip_missing defaults true" => import_source.include?('arguments["skip_missing"]?.boolValue() ?? true'),
  "import_pending_tasks defaults false" => import_source.include?('arguments["import_pending_tasks"]?.boolValue() ?? false'),
  "endpoint suffix fallbacks registered for media imports" =>
    registry_source.include?('name: "status_endpoint_suffix"') &&
    registry_source.include?('name: "cancel_endpoint_suffix"') &&
    import_source.include?('statusEndpointSuffix: optionalString(arguments["status_endpoint_suffix"])') &&
    import_source.include?('cancelEndpointSuffix: optionalString(arguments["cancel_endpoint_suffix"])'),
  "manifest endpoint suffixes flow into imported task groups" =>
    import_source.include?('statusEndpointSuffix: item.trimmedStatusEndpointSuffix ?? manifest.trimmedStatusEndpointSuffix') &&
    import_source.include?('cancelEndpointSuffix: item.trimmedCancelEndpointSuffix ?? manifest.trimmedCancelEndpointSuffix') &&
    import_source.include?('statusEndpointSuffix: group.statusEndpointSuffix') &&
    import_source.include?('cancelEndpointSuffix: group.cancelEndpointSuffix'),
  "manifest import merges existing remote media tasks" =>
    import_source.include?("existingTask(for: group, registry: registry, runtimeID: context.runtimeID)") &&
    import_source.include?("registry.tasks(forRuntime: runtimeID).first") &&
    import_source.include?("matchesAnchors(task, group: group)") &&
    import_source.include?("normalizedRemoteKey") &&
    import_source.include?("Manifest 产物已导入。"),
  "manifest last_error imports as failed media tasks" =>
    import_source.include?('case lastError = "last_error"') &&
    import_source.include?("var trimmedLastError: String? { lastError.trimmedNonEmpty }") &&
    import_source.include?("private struct ManifestFailedItem") &&
    import_source.include?("var failedItems: [ManifestFailedItem] = []") &&
    import_source.include?("failedManifestItem(") &&
    import_source.include?("guard group.lastError != nil else") &&
    import_source.include?("let failedGrouped = Dictionary(grouping: failedItems, by: \\.group)") &&
    import_source.include?("Failed manifest tasks: \\(failedItems.count)") &&
    import_source.include?("status: .failed") &&
    import_source.include?("Manifest 外部脚本失败：\\(error)") &&
    import_source.include?("lastError: item.trimmedLastError ?? manifest.trimmedLastError ?? optionalString(arguments[\"last_error\"])") &&
    import_source.include?("failed_task_recovery_actions:") &&
    import_source.include?("AgentMediaTaskChatHandoff.failedTaskScopeSummaryLine") &&
    import_source.include?("failed_task_follow_up: failed_task_recovery_actions 已包含打开任务范围") &&
    import_source.include?("failedManifestDryRunRecoveryLines(") &&
    import_source.include?("<failed-manifest-dry-run-recovery>") &&
    import_source.include?("import_media_manifest_failed_dry_run_recovery") &&
    import_source.include?("failed_only_rerun_env: WILLDEEP_MEDIA_ONLY_FAILED=1") &&
    import_source.include?("dry-run 阶段尚未创建侧栏失败任务"),
  "pending remote manifest tasks are registered" =>
    import_source.include?("Manifest 远端异步任务已登记") &&
    import_source.include?("pendingManifestItem") &&
    import_source.include?("Pending remote tasks") &&
    import_source.include?("manifestImportFollowUpLines(tasks: tasks, pendingTasks: pendingTasks, gapReportURL: gapReportURL)") &&
    import_source.include?("let gapReportURL = productionGapReportURL(arguments: arguments, manifestURL: manifestURL)") &&
    import_source.include?("<media-import-follow-up>") &&
    import_source.include?("lines.append(contentsOf: projectMediaTaskHandoffLines(for: sharedProjectScope(for: tasks)))") &&
    import_source.include?("project_media_tasks_tool: short_drama_open_media_tasks") &&
    import_source.include?("refresh_project_media_tasks_tool: short_drama_refresh_media_tasks") &&
    import_source.include?("pending_task_ids: \\(pendingTasks.map(\\.displayHandle).joined(separator: \", \"))") &&
    import_source.include?("pending_active_task_actions:") &&
    import_source.include?("AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine") &&
    import_source.include?("pending_active_task_follow_up: pending_active_task_actions 已包含可直接调用的 provider 轮询/取消参数") &&
    import_source.include?("scoped_pending_task_actions:") &&
    import_source.include?("open_tasks_tool: short_drama_open_media_tasks") &&
    import_source.include?("refresh_tasks_tool: short_drama_refresh_media_tasks") &&
    import_source.include?("shortDramaMediaTaskScopeArguments(for task: AgentMediaTask)") &&
    import_source.include?("scope=review_item") &&
    import_source.include?("scope=asset"),
  "manifest import exposes production gap report follow-up" =>
    import_source.include?("let gapReportURL = productionGapReportURL(arguments: arguments, manifestURL: manifestURL)") &&
    import_source.include?("let gapReportFollowUp = manifestImportFollowUpLines(tasks: [], pendingTasks: [], gapReportURL: gapReportURL)") &&
    import_source.include?("manifestImportFollowUpLines(tasks: tasks, pendingTasks: pendingTasks, gapReportURL: gapReportURL)") &&
    import_source.include?("guard !tasks.isEmpty || gapReportURL != nil else { return \"\" }") &&
    import_source.include?("task_ids: \\(tasks.isEmpty ? \"(none)\" : tasks.map(\\.displayHandle).joined(separator: \", \"))") &&
    import_source.include?("private static func productionGapReportURL(arguments: [String: AgentJSONValue], manifestURL: URL) -> URL?") &&
    import_source.include?("appendingPathComponent(\"production-gap-report.json\"") &&
    import_source.include?("production_gap_report_path: \\(gapReportURL.path)") &&
    import_source.include?("production_gap_report_tool: short_drama_generate_batch_media") &&
    import_source.include?("production_gap_report_follow_up: 请先读取 production_gap_report_path") &&
    import_source.include?("short_drama_generate_batch_media(target_filter=missing, dry_run=true)") &&
    import_source.scan("gapReportFollowUp").length >= 3,
  "completed manifest image groups expose choice widget follow-up" =>
    import_source.include?("completed_image_choice_actions:") &&
    import_source.include?("imageChoiceAction(for: task, imagePaths: imagePaths)") &&
    import_source.include?("imageArtifactPaths(for: task)") &&
    import_source.include?("image_choice_tool: \\(tool)") &&
    import_source.include?("image_choice_arguments: \\(arguments)") &&
    import_source.include?("return (\"short_drama_show_image_choice_widget\", shortDramaImageChoiceArguments(for: task))") &&
    import_source.include?("return (\"show_image_choice_widget\", pairs.joined(separator: \", \"))") &&
    import_source.include?("image_paths=\\(imagePaths.joined(separator: \" | \"))") &&
    import_source.include?("appendCleanPair(\"review_item_id\", task.reviewItemID"),
  "completed imported images expose short drama action handoff" =>
    import_source.include?("completed_image_follow_up_actions:") &&
    import_source.include?("completedImageFollowUpActions(for: task, imagePath: imagePath)") &&
    import_source.include?("shortDramaArtifactArguments(for: task, pathKey: \"artifact_path\", imagePath: imagePath)") &&
    import_source.include?("shortDramaArtifactArguments(for: task, pathKey: \"image_path\", imagePath: imagePath)") &&
    import_source.include?("genericImageArguments(for: task, imagePath: imagePath)") &&
    import_source.include?("open_shot_tasks_tool: short_drama_open_media_tasks") &&
    import_source.include?("open_shot_tasks_arguments: \\(taskArguments)") &&
    import_source.include?("private static func shortDramaShotTaskArguments(for task: AgentMediaTask) -> String") &&
    import_source.include?("select_primary_tool: short_drama_select_shot_artifact") &&
    import_source.include?("select_primary_arguments: \\(artifactArguments)") &&
    import_source.include?("video_from_image_tool: generate_video_from_image") &&
    import_source.include?("video_from_image_arguments: \\(imageArguments)") &&
    import_source.include?("edit_tool: short_drama_open_image_editor") &&
    import_source.include?("edit_arguments: \\(artifactArguments), operation=inpaint") &&
    import_source.include?("erase_tool: short_drama_open_image_editor") &&
    import_source.include?("erase_arguments: \\(artifactArguments), operation=erase") &&
    import_source.include?("upscale_tool: short_drama_upscale_shot_artifact") &&
    import_source.include?("upscale_arguments: \\(artifactArguments)") &&
    import_source.include?("let reopenActions = reopenImageEditorActions(for: task)") &&
    import_source.include?("reopenImageEditorActions(for: task)") &&
    import_source.include?("reopen_editor_tool: short_drama_open_image_editor") &&
    import_source.include?("reopen_editor_tool: open_image_editor") &&
    import_source.include?("sourceImagePath = clean(task.sourceImagePath)") &&
    import_source.include?("maskPath = clean(task.maskPath)") &&
    import_source.include?("mask_path=\\(maskPath), operation=\\(operation)") &&
    import_source.include?("open_review_tasks_tool: short_drama_open_media_tasks") &&
    import_source.include?("open_review_tasks_arguments: \\(shortDramaReviewTaskArguments(for: task, reviewItemID: reviewItemID))") &&
    import_source.include?("private static func shortDramaReviewTaskArguments(for task: AgentMediaTask, reviewItemID: String) -> String") &&
    import_source.include?("resolve_review_tool: short_drama_resolve_review_item") &&
    import_source.include?("shortDramaReviewArguments(for: task, reviewItemID: reviewItemID)") &&
    import_source.include?("open_asset_tasks_tool: short_drama_open_media_tasks") &&
    import_source.include?("open_asset_tasks_arguments: \\(taskArguments)") &&
    import_source.include?("private static func assetTaskArguments(for task: AgentMediaTask) -> String") &&
    import_source.include?("attach_reference_tool: short_drama_attach_asset_reference_image") &&
    import_source.include?("attach_reference_arguments: \\(imageArguments)") &&
    import_source.include?("edit_tool: open_image_editor") &&
    import_source.include?("erase_tool: open_image_editor") &&
    import_source.include?("upscale_tool: upscale_image") &&
    import_source.include?("video_from_image_arguments: \\(imageArguments)") &&
    import_source.include?("pairs.append(\"\\(pathKey)=\\(imagePath)\")"),
  "directory import image groups expose choice widget follow-up" =>
    import_source.include?("let followUp = mediaDirectoryImportFollowUpLines(task: task)") &&
    import_source.include?("mediaDirectoryImportFollowUpLines(task: AgentMediaTask)") &&
    import_source.include?("action: \"import_media_directory_follow_up\"") &&
    import_source.include?("mediaImportFollowUpLines(") &&
    import_source.include?("action: \\(action)") &&
    import_source.include?("completed_image_choice_actions:") &&
    import_source.include?("image_choice_tool: \\(tool)") &&
    import_source.include?("image_choice_arguments: \\(arguments)"),
  "generic pending media tasks can be polled from https status urls" =>
    generic_media_source.include?("enum AgentGenericMediaStatusClient") &&
    generic_media_source.include?("static func canPoll(_ task: AgentMediaTask) -> Bool") &&
    generic_media_source.include?('url.scheme?.lowercased() == "https"') &&
    generic_media_source.include?("static func poll(task: AgentMediaTask") &&
    generic_media_source.include?("static func downloadArtifacts(") &&
    generic_media_source.include?("static func canCancel(_ task: AgentMediaTask) -> Bool") &&
    generic_media_source.include?("static func cancel(task: AgentMediaTask") &&
    generic_media_source.include?("private static func cancelRequest(") &&
    generic_media_source.include?('request.httpMethod = method') &&
    generic_media_source.include?('method: "POST"') &&
    generic_media_source.include?("response.statusCode == 405") &&
    generic_media_source.include?('method: "DELETE"') &&
    generic_media_source.include?("parseCancelResponse") &&
    generic_media_source.include?("AgentNetworkSupport.applyStandardHeaders") &&
    generic_media_source.include?("status(from rawStatus: String)") &&
    generic_media_source.include?("private static func firstOutputValue(in object: [String: AgentJSONValue])") &&
    generic_media_source.include?("private static let outputValueKeys") &&
    generic_media_source.include?('"artifact_url"') &&
    generic_media_source.include?('"download_url"') &&
    generic_media_source.include?('"file_url"') &&
    generic_media_source.include?('"artifacts"') &&
    generic_media_source.include?('"files"') &&
    generic_media_source.include?('"images"') &&
    generic_media_source.include?('"videos"') &&
    media_tasks_source.include?("AgentGenericMediaStatusClient.canPoll(task)") &&
    media_tasks_source.include?("private func pollGenericStatusURL") &&
    media_tasks_source.include?("AgentGenericMediaStatusClient.poll(task: task)") &&
    media_tasks_source.include?("AgentGenericMediaStatusClient.downloadArtifacts") &&
    media_tasks_source.include?("AgentGenericMediaStatusClient.canCancel(task)") &&
    media_tasks_source.include?("private func cancelGeneric(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry)") &&
    media_tasks_source.include?("AgentGenericMediaStatusClient.cancel(task: task)") &&
    media_tasks_source.include?("此任务来源缺少 HTTPS cancel_url") &&
    media_task_handoff_source.include?("AgentGenericMediaStatusClient.canPoll(task)") &&
    media_task_handoff_source.include?("generic_poll_tool=short_drama_refresh_media_tasks") &&
    media_task_handoff_source.include?("generic_poll_tool: short_drama_refresh_media_tasks") &&
    media_task_handoff_source.include?("generic_poll_arguments: \\(scopeArguments)") &&
    media_task_handoff_source.include?("AgentGenericMediaStatusClient.canCancel(task)") &&
    media_task_handoff_source.include?("generic_cancel_note=cancel_url_available_in_media_task_side_panel") &&
    media_task_handoff_source.include?("这个任务带 HTTPS cancel_url") &&
    media_task_tools_source.include?("AgentGenericMediaStatusClient.canPoll($0)") &&
    media_tasks_source.include?("AgentGenericMediaStatusClient.canPoll(task)"),
  "relative manifest paths stay inside base directory" =>
    import_source.include?("Manifest file_path escapes base_directory") &&
    import_source.include?("isInsideDirectory"),
  "production markdown includes dry-run handoff" =>
    production_exporter_source.include?("## Script Handoff") &&
    production_exporter_source.include?("markdown(for: package, directory: directory, includeResolvedReviewItems: includeResolvedReviewItems)") &&
    production_exporter_source.include?("productionPackageHandoffMarkdown(directory: directory)") &&
    production_exporter_source.include?("Paste this handoff block back into WillDeep Agent") &&
    production_exporter_source.include?("action: production_package_markdown_handoff") &&
    production_exporter_source.include?("widget_arguments: title=短剧制作预览, html_path=\\(widgetPreviewURL.path)") &&
    production_exporter_source.include?("source_label=production-package.md") &&
    production_exporter_source.include?('\\"dry_run\\":true') &&
    production_exporter_source.include?('\\"package_directory\\"'),
  "production markdown includes widget preview handoff" =>
    production_exporter_source.include?("Widget preview HTML: `widget-preview.html`") &&
    production_exporter_source.include?('\\"tool\\":\\"show_widget\\"') &&
    production_exporter_source.include?('\\"html_path\\":\\"<this package directory>/widget-preview.html\\"'),
  "initial production widget exposes structured package handoff" =>
    production_exporter_source.include?("<production-package-handoff>") &&
    production_exporter_source.include?("action: production_package_widget_preview") &&
    production_exporter_source.include?("widgetPreviewHTML(for: package, directory: directory, generated: [], skipped: [])") &&
    production_exporter_source.include?("manifest_path: \\(manifestURL.path)") &&
    production_exporter_source.include?("gap_report_path: \\(gapReportURL.path)") &&
    production_exporter_source.include?("review_template_path: \\(reviewTemplateURL.path)") &&
    production_exporter_source.include?("review_queue_path: \\(reviewQueueURL.path)") &&
    production_exporter_source.include?("dry_run_import_arguments: package_directory=\\(packageDirectory), dry_run=true, import_pending_tasks=true") &&
    production_exporter_source.include?("submit_import_arguments: package_directory=\\(packageDirectory), dry_run=false, import_pending_tasks=true") &&
    production_exporter_source.include?("review_template_import_arguments: package_directory=\\(packageDirectory), dry_run=true") &&
    production_exporter_source.include?("review_queue_import_arguments: file_path=\\(reviewQueueURL.path), dry_run=true") &&
    production_exporter_source.include?("优先使用下面 <production-package-handoff> 中的 dry_run_import_arguments") &&
    production_exporter_source.include?("请优先使用下面 <production-package-handoff> 中的 timeline_path、gap_report_path、dry_run_import_arguments 和 submit_import_arguments") &&
    production_exporter_source.include?("review_template_import_arguments 先 dry-run") &&
    production_exporter_source.include?("review_queue_import_arguments 预检回写") &&
    production_exporter_source.include?("let reviewQueueActions = reviewQueueActionItemsHTML(for: project)") &&
    production_exporter_source.include?("static func reviewQueueActionItemsHTML(for project: AgentShortDramaProject) -> String") &&
    production_exporter_source.include?("productionReviewItemRecommendation(") &&
    production_exporter_source.include?("recommended_tool=\\(escapeHTML(recommendation.tool))") &&
    production_exporter_source.include?("open_review_tasks_arguments=\\(escapeHTML(reviewTasksArguments))") &&
    production_exporter_source.include?("resolve_review_arguments=\\(escapeHTML(resolveArguments))") &&
    production_exporter_source.include?("action: fix_production_review_queue_item") &&
    production_exporter_source.include?("sendPromptButton(label: \"交给聊天处理\", prompt: prompt)") &&
    production_exporter_source.include?("修复队列推荐动作") &&
    production_exporter_source.include?("reviewQueueActions.isEmpty ? \"<li class=\\\"muted\\\">暂无待处理推荐动作</li>\" : reviewQueueActions"),
  "ruby media template writes endpoint suffix metadata" =>
    production_exporter_source.include?("WILLDEEP_MEDIA_STATUS_ENDPOINT_SUFFIX=") &&
    production_exporter_source.include?("WILLDEEP_MEDIA_CANCEL_ENDPOINT_SUFFIX=") &&
    production_exporter_source.include?("WILLDEEP_MEDIA_CANCEL_URL_TEMPLATE=") &&
    production_exporter_source.include?("def async_cancel_url(parsed)") &&
    production_exporter_source.include?("[\"cancel_url\"]") &&
    production_exporter_source.include?("[\"urls\", \"cancel\"]") &&
    production_exporter_source.include?("[\"links\", \"cancel\"]") &&
    production_exporter_source.include?('template = ENV["WILLDEEP_MEDIA_CANCEL_URL_TEMPLATE"]') &&
    production_exporter_source.include?("cancel_url = async_cancel_url(parsed)") &&
    production_exporter_source.include?('item["cancel_url"] ||= cancel_url if cancel_url') &&
    production_exporter_source.include?('item["status_endpoint_suffix"] ||= status_endpoint_suffix') &&
    production_exporter_source.include?('item["cancel_endpoint_suffix"] ||= cancel_endpoint_suffix'),
  "ruby media template writes widget preview html" =>
    production_exporter_source.include?("WIDGET_PREVIEW_PATH = File.join(ROOT, \"widget-preview.html\")") &&
    production_exporter_source.include?("GAP_REPORT_PATH = File.join(ROOT, \"production-gap-report.json\")") &&
    production_exporter_source.include?("def write_widget_preview(package, generated, pending, failed, skipped, review_queue_updates)") &&
    production_exporter_source.include?("<ruby-media-script-handoff>") &&
    production_exporter_source.include?('dry_run_import_arguments: package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=#{import_pending}') &&
    production_exporter_source.include?('submit_import_arguments: package_directory=#{PACKAGE_DIR}, dry_run=false, import_pending_tasks=#{import_pending}') &&
    production_exporter_source.include?('review_queue_import_arguments: file_path=#{REVIEW_QUEUE_PATH}, dry_run=#{review_queue_updates.zero?}') &&
    production_exporter_source.include?('widget_arguments: title=短剧制作预览, html_path=#{WIDGET_PREVIEW_PATH}') &&
    production_exporter_source.include?("优先使用下面 <ruby-media-script-handoff> 中的 dry_run_import_arguments") &&
    production_exporter_source.include?("优先使用下面 <ruby-media-script-handoff> 中的 review_queue_import_arguments") &&
    production_exporter_source.include?("review_queue_actions = load_review_queue") &&
    production_exporter_source.include?("修复队列推荐动作") &&
    production_exporter_source.include?('recommended_tool=#{row["recommended_tool"]}') &&
    production_exporter_source.include?('open_review_tasks_arguments=#{row["open_review_tasks_arguments"]}') &&
    production_exporter_source.include?('resolve_review_arguments=#{row["resolve_review_arguments"]}') &&
    production_exporter_source.include?("action_prompt = \"请处理这个制作包修复队列检查项。") &&
    production_exporter_source.include?('action_button = %(<button onclick="sendPrompt(#{JSON.dump(action_prompt)})">交给聊天处理</button>)') &&
    production_exporter_source.include?("def failed_job_info(item, relative_path, error)") &&
    production_exporter_source.include?("write_widget_preview(package, generated, pending, failed, skipped, review_queue_updates)") &&
    production_exporter_source.include?("Pending remote jobs") &&
    production_exporter_source.include?("Failed jobs") &&
    production_exporter_source.include?(">分析失败</button>") &&
    production_exporter_source.include?(">重跑失败</button>") &&
    production_exporter_source.include?("failed_analysis_prompt = \"请分析这个制作包 Ruby 媒体脚本的 failed jobs") &&
    production_exporter_source.include?("retry_failed_prompt = \"请只重跑这个制作包里的失败媒体项") &&
    production_exporter_source.include?('sendPrompt(#{JSON.dump(failed_analysis_prompt)})') &&
    production_exporter_source.include?('sendPrompt(#{JSON.dump(retry_failed_prompt)})') &&
    production_exporter_source.include?("请优先使用下面 <ruby-media-script-handoff> 中的 dry_run_import_arguments 让失败项登记为媒体任务") &&
    production_exporter_source.include?("再使用 submit_import_arguments 正式导入并打开媒体任务侧栏") &&
    production_exporter_source.include?("请优先使用下面 <ruby-media-script-handoff> 中的 widget_preview_path、gap_report_path、dry_run_import_arguments 和 submit_import_arguments") &&
    production_exporter_source.include?("请保留下面 <ruby-media-script-handoff> 作为导入和网页组件回流上下文") &&
    production_exporter_source.include?("并优先使用下面 <ruby-media-script-handoff> 中的 review_queue_import_arguments") &&
    production_exporter_source.scan('sendPrompt(#{JSON.dump("请读取这个制作包').length >= 5 &&
    production_exporter_source.include?("failed/failed_paths") &&
    production_exporter_source.include?("带 last_error 的 item") &&
    production_exporter_source.include?("WILLDEEP_MEDIA_ONLY_FAILED=1") &&
    production_exporter_source.include?("last_error 已被成功项清理") &&
    production_exporter_source.include?("读取 production-gap-report.json 重新排产") &&
    production_exporter_source.include?("failed_count: failed.length") &&
    production_exporter_source.include?('failed_paths: failed.map { |job| job["file_path"] }') &&
    production_exporter_source.include?("failed << failed_job_info(item, relative_path, e)") &&
    production_exporter_source.include?('item["last_error"] = "#{error.class}: #{error.message}"') &&
    production_exporter_source.include?("导回异步任务") &&
    production_exporter_source.include?("remote_task_id、status_url、cancel_url、status_endpoint_suffix、cancel_endpoint_suffix") &&
    production_exporter_source.include?("widget_preview_path: WIDGET_PREVIEW_PATH") &&
    production_exporter_source.include?("gap_report_path: GAP_REPORT_PATH")
}
import_contract.each do |name, status|
  add_check.call(name, status, "Import tool contract source check.")
end

plan_import_contract = {}
plan_import_contract.merge!(
  short_drama_media_contract_plan_import_checks(
    tools_source: tools_source,
    production_exporter_source: production_exporter_source,
    short_drama_dispatcher_source: short_drama_dispatcher_source,
    short_drama_chat_context_source: short_drama_chat_context_source,
    short_drama_source: short_drama_source,
    media_tasks_source: media_tasks_source,
    storyboard_widget_source: storyboard_widget_source,
    registry_source: registry_source,
    panel_source: panel_source
  )
)
plan_import_contract.merge!(
  short_drama_media_contract_media_task_checks(
    image_tools_source: image_tools_source,
    dispatch_source: dispatch_source,
    media_tools_source: media_tools_source,
    short_drama_source: short_drama_source,
    asset_views_source: asset_views_source,
    media_tasks_source: media_tasks_source,
    media_task_handoff_source: media_task_handoff_source,
    media_artifact_views_source: media_artifact_views_source,
    some_im_source: some_im_source,
    replicate_source: replicate_source,
    image_edit_source: image_edit_source,
    registry_source: registry_source,
    side_panel_source: side_panel_source,
    mode_view_source: mode_view_source,
    conversation_activity_overlay_source: conversation_activity_overlay_source,
    app_state_source: app_state_source,
    app_state_loop_source: app_state_loop_source,
    chat_header_source: chat_header_source,
    widget_source: widget_source,
    widget_card_source: widget_card_source,
    task_monitor_source: task_monitor_source
  )
)
plan_import_contract.merge!(
  short_drama_media_contract_media_tool_checks(
    tools_source: tools_source,
    production_exporter_source: production_exporter_source,
    image_tools_source: image_tools_source,
    batch_tools_source: batch_tools_source,
    short_drama_dispatcher_source: short_drama_dispatcher_source,
    media_task_tools_source: media_task_tools_source,
    dispatch_source: dispatch_source,
    media_tools_source: media_tools_source,
    short_drama_source: short_drama_source,
    asset_views_source: asset_views_source,
    media_tasks_source: media_tasks_source,
    media_task_handoff_source: media_task_handoff_source,
    media_artifact_views_source: media_artifact_views_source,
    image_edit_source: image_edit_source,
    storyboard_widget_source: storyboard_widget_source,
    import_source: import_source,
    registry_source: registry_source,
    side_panel_source: side_panel_source,
    app_state_loop_source: app_state_loop_source,
    widget_registry_source: widget_registry_source
  )
)
plan_import_contract.each do |name, status|
  add_check.call(name, status, "Short-drama plan import source check.")
end

plan_template = extract_swift_triple_quote(tools_source, "static func jsonString() -> String {")
plan_template_check = {
  ok: false,
  parsed: nil,
  error: nil
}
begin
  parsed = JSON.parse(plan_template.to_s)
  character_ids = parsed.fetch("characters").map { |item| item.fetch("id") }
  scene_ids = parsed.fetch("scenes").map { |item| item.fetch("id") }
  shots = parsed.fetch("episodes").flat_map { |episode| episode.fetch("shots") }
  shot_references_valid = shots.all? do |shot|
    scene_ids.include?(shot.fetch("scene")) &&
      shot.fetch("characters").all? { |character_id| character_ids.include?(character_id) }
  end
  required_top_level = %w[project_id title logline characters scenes episodes]
  required_shot_fields = %w[id title summary prompt status order scene characters artifact_paths selected_artifact_path]
  fields_valid = required_top_level.all? { |key| parsed.key?(key) } &&
    shots.all? { |shot| required_shot_fields.all? { |key| shot.key?(key) } }
  plan_template_check = {
    ok: shot_references_valid && fields_valid,
    parsed: {
      characters: character_ids.length,
      scenes: scene_ids.length,
      episodes: parsed.fetch("episodes").length,
      shots: shots.length
    },
    error: nil
  }
  add_check.call(
    "plan template parses and references resolve",
    plan_template_check[:ok],
    "Parsed #{character_ids.length} characters, #{scene_ids.length} scenes, #{shots.length} shots."
  )
rescue StandardError => e
  plan_template_check = { ok: false, parsed: nil, error: e.message }
  add_check.call(
    "plan template parses and references resolve",
    false,
    e.message
  )
end

ruby_template = extract_ruby_template(production_exporter_source)
add_check.call(
  "ruby template extracted",
  !ruby_template.to_s.empty?,
  "Extracted embedded rubyMediaScriptTemplate() body from Swift source."
)

ruby_check = {
  ok: false,
  stdout: "",
  stderr: "",
  status: nil
}
if ruby_template && !ruby_template.empty?
  FileUtils.mkdir_p(scratch_dir)
  template_path = File.join(scratch_dir, "ruby-media-script-template.rb")
  File.write(template_path, ruby_template)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", template_path)
  ruby_check = {
    ok: status.success?,
    stdout: stdout.strip,
    stderr: stderr.strip,
    status: status.exitstatus,
    template_path: template_path
  }
  add_check.call(
    "ruby template syntax",
    status.success?,
    [stdout.strip, stderr.strip].reject(&:empty?).join(" | ")
  )

  ruby_api_tokens = [
    'ENV["WILLDEEP_MEDIA_API_URL"]',
    'ENV["WILLDEEP_MEDIA_API_TOKEN"]',
    'ENV.fetch("WILLDEEP_MEDIA_API_METHOD", "POST")',
    'ENV.fetch("WILLDEEP_MEDIA_EXTRA_HEADERS_JSON", "")',
    'ENV.fetch("WILLDEEP_MEDIA_REQUEST_FORMAT", "json")',
    'ENV.fetch("WILLDEEP_MEDIA_REQUEST_PRESET", "")',
    "WILLDEEP_MEDIA_SOURCE_IMAGE_FIELD",
    "WILLDEEP_MEDIA_MASK_FIELD",
    "WILLDEEP_REPLICATE_EXTRA_INPUT_JSON",
    'ENV["WILLDEEP_MEDIA_PROVIDER"]',
    'ENV["WILLDEEP_MEDIA_MODEL"]',
    "WILLDEEP_MEDIA_TIMEOUT_SECONDS",
    "WILLDEEP_MEDIA_POLL_URL_TEMPLATE",
    "WILLDEEP_MEDIA_CANCEL_URL_TEMPLATE",
    "WILLDEEP_MEDIA_SUBMIT_ONLY",
    "WILLDEEP_MEDIA_ONLY_FAILED",
    "WILLDEEP_MEDIA_POLL_INTERVAL_SECONDS",
    "WILLDEEP_MEDIA_POLL_MAX_ATTEMPTS",
    "Provider preset: Replicate Predictions",
    "WILLDEEP_MEDIA_API_URL=https://api.replicate.com/v1/predictions",
    "WILLDEEP_MEDIA_REQUEST_PRESET=replicate_predictions",
    "Provider preset: some.im image/video gateway",
    "Existing source-image / mask tasks",
    "WIDGET_PREVIEW_PATH",
    "def annotate_remote_job!(item, response)",
    'item["remote_task_id"]',
    'item["status_url"]',
    'item["cancel_url"]',
    "def truthy_env?(name)",
    "def extra_headers",
    "def apply_extra_headers!(request)",
    "def submit_request_for(uri)",
    "Unsupported WILLDEEP_MEDIA_API_METHOD",
    "def pending_remote_item?(item)",
    "def should_process_item?(item)",
    "truthy_env?(\"WILLDEEP_MEDIA_ONLY_FAILED\")",
    'item["last_error"].to_s.strip != ""',
    "unless should_process_item?(item)",
    'item.delete("last_error")',
    "return nil if truthy_env?(\"WILLDEEP_MEDIA_SUBMIT_ONLY\")",
    "def pending_job_info(item, relative_path)",
    "def failed_job_info(item, relative_path, error)",
    "pending.first(80).map do |job|",
    "failed.first(80).map do |job|",
    "pending << pending_job_info(item, relative_path)",
    "failed << failed_job_info(item, relative_path, e)",
    'item["last_error"] = "#{error.class}: #{error.message}"',
    'job["remote_task_id"] && "remote=#{job["remote_task_id"]}"',
    'job["status_url"] && "status_url=#{job["status_url"]}"',
    'job["cancel_url"] && "cancel_url=#{job["cancel_url"]}"',
    'job["status_endpoint_suffix"] && "status_endpoint_suffix=#{job["status_endpoint_suffix"]}"',
    'job["cancel_endpoint_suffix"] && "cancel_endpoint_suffix=#{job["cancel_endpoint_suffix"]}"',
    "pending_count: pending.length",
    "failed_count: failed.length",
    'pending_paths: pending.map { |job| job["file_path"] }',
    'failed_paths: failed.map { |job| job["file_path"] }',
    "review_queue_path: REVIEW_QUEUE_PATH",
    "gap_report_path: GAP_REPORT_PATH",
    "review_queue_updates: review_queue_updates",
    "dry_run_import_tool: \"import_media_manifest\"",
    'dry_run_import_arguments: "package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=#{pending.length.positive?}"',
    "submit_import_tool: \"import_media_manifest\"",
    'submit_import_arguments: "package_directory=#{PACKAGE_DIR}, dry_run=false, import_pending_tasks=#{pending.length.positive?}"',
    "review_queue_import_tool: \"short_drama_import_review_csv\"",
    'review_queue_import_arguments: "file_path=#{REVIEW_QUEUE_PATH}, dry_run=#{review_queue_updates.zero?}"',
    "widget_tool: \"show_widget\"",
    'widget_arguments: "title=短剧制作预览, html_path=#{WIDGET_PREVIEW_PATH}, source_label=ruby-media-script-template, source_path=#{WIDGET_PREVIEW_PATH}, package_directory=#{PACKAGE_DIR}, recommended_tool=import_media_manifest, recommended_arguments=package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=#{pending.length.positive?}"',
    "follow_up_note: \"After import, read <media-import-follow-up>",
    "completed_image_choice_actions and completed_image_follow_up_actions",
    "inspect failed before retrying third-party API calls",
    "read gap_report_path before batch filling missing shots",
    "def load_review_queue",
    "def write_review_queue(rows)",
    "def review_item_id_for(item)",
    "def mark_review_queue_item!(rows, review_item_id",
    "def local_path_for(item, key)",
    "def mime_type_for(path)",
    "def data_url_for(path)",
    "def request_format",
    "def media_urls_from(value)",
    "def extract_media_outputs(response)",
    "def sibling_output_path(relative_path, index, source_url)",
    "def duplicate_manifest_item(item, relative_path, index, source_url)",
    "result_url",
    "download_url",
    "artifact_url",
    "file_url",
    "def append_multipart_file",
    "def assign_request_body!(request, body, source_image_path, mask_path)",
    "def replicate_predictions_body(body)",
    'input["image"] = source_image',
    'input["mask"] = mask_image',
    "version: version",
    'body = replicate_predictions_body(body) if request_preset == "replicate_predictions"',
    "multipart/form-data; boundary=",
    "SecureRandom.hex",
    "Unsupported WILLDEEP_MEDIA_REQUEST_FORMAT",
    "source_image_path: source_image_path",
    "mask_path: mask_path",
    "review_item_id: review_item_id_for(item)",
    'suggested_action: item["suggested_action"]',
    "WILLDEEP_MEDIA_EMBED_LOCAL_FILES",
    "source_image_data_url",
    "mask_data_url",
    "Base64.strict_encode64(File.binread(path))",
    "short_drama_import_review_csv with review_queue_path",
    "Review queue updates",
    "import_pending_tasks: true",
    "def poll_for_media(initial_response, item)",
    "manifest[\"items\"] << duplicate_manifest_item(item, candidate_relative_path, index, output[:source_url])",
    'candidate-#{index + 1}',
    "def write_widget_preview(package, generated, pending, failed, skipped, review_queue_updates)",
    "widget_preview_path",
    '["urls", "get"]',
    "def extract_media_bytes(response)",
    "Base64.decode64",
    "download_bytes(media_url)",
    "Net::HTTP::Patch",
    "apply_extra_headers!(request)"
  ]
  ruby_api_tokens.each do |token|
    add_check.call(
      "ruby template API handoff token #{token}",
      ruby_template.include?(token),
      "Ruby handoff template keeps third-party API calls configurable through environment variables and common response extractors."
    )
  end
end

failures = checks.select { |check| check[:status] != "passed" }
report = {
  ok: failures.empty?,
  generated_at: Time.now.utc.iso8601,
  checks: checks,
  plan_template_check: plan_template_check,
  ruby_check: ruby_check,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report) + "\n")

status_label = report[:ok] ? "PASS" : "FAIL"
md = +"# Short Drama Media Contract Report\n\n"
md << "**Status:** #{status_label}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n"
md << "- Plan template JSON: #{plan_template_check[:ok] ? "passed" : "failed"}\n"
md << "- Ruby template syntax: #{ruby_check[:ok] ? "passed" : "failed"}\n\n"

unless failures.empty?
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure[:name]} — #{failure[:evidence]}\n" }
  md << "\n"
end

md << "## Checks\n\n"
md << "| Check | Status | Evidence |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  evidence = check[:evidence].to_s.gsub("\n", "<br>")
  md << "| #{check[:name]} | `#{check[:status]}` | #{evidence} |\n"
end

File.write(File.expand_path(markdown_path, repo_root), md)

puts "short_drama_media_contract: #{status_label.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(report[:ok] ? 0 : 1)
