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
  marker = "private static func rubyMediaScriptTemplate() -> String {"
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
  read_file(repo_root, "Xedit/AgentShortDramaProductionGapReportLinks.swift"),
  read_file(repo_root, "Xedit/AgentShortDramaProductionReviewQueue.swift")
].join("\n")
production_review_recommendations_source = read_file(repo_root, "Xedit/AgentShortDramaProductionReviewRecommendations.swift")
image_tools_source = read_file(repo_root, "Xedit/AgentShortDramaImageTools.swift")
batch_tools_source = read_file(repo_root, "Xedit/AgentShortDramaBatchTools.swift")
short_drama_dispatcher_source = read_file(repo_root, "Xedit/AgentShortDramaToolDispatcher.swift")
media_task_tools_source = read_file(repo_root, "Xedit/AgentShortDramaMediaTaskTools.swift")
dispatch_source = read_file(repo_root, "Xedit/AgentTools.swift")
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

plan_import_contract = {
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
    short_drama_source.include?("appState.agentInput += \"\\n\\n\\(prompt)\"") &&
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
    image_edit_source.include?("reviewItemID: appState.agentImageEditorContext?.reviewItemID") &&
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
    image_edit_source.include?("assetKind: appState.agentImageEditorContext?.assetKind") &&
    image_edit_source.include?("assetID: appState.agentImageEditorContext?.assetID") &&
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
