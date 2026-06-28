//
//  AgentShortDramaToolDispatcher.swift
//  WillDeep
//
//  Keeps the main AgentToolRunner switch from growing every time the
//  short-drama production surface gains a new tool.
//

import Foundation

enum AgentShortDramaToolDispatcher {
    static func canHandle(_ name: String) -> Bool {
        name.hasPrefix("short_drama_")
    }

    static func run(
        name: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        switch name {
        case "short_drama_create_project":
            return try await AgentShortDramaTools.createProject(arguments: arguments, context: context)
        case "short_drama_import_plan":
            return try await AgentShortDramaTools.importPlan(arguments: arguments, context: context)
        case "short_drama_export_plan_template":
            return try await AgentShortDramaTools.exportPlanTemplate(arguments: arguments, context: context)
        case "short_drama_upsert_episode":
            return try await AgentShortDramaTools.upsertEpisode(arguments: arguments, context: context)
        case "short_drama_upsert_character":
            return try await AgentShortDramaTools.upsertCharacter(arguments: arguments, context: context)
        case "short_drama_upsert_scene":
            return try await AgentShortDramaTools.upsertScene(arguments: arguments, context: context)
        case "short_drama_attach_asset_reference_image":
            return try await AgentShortDramaTools.attachAssetReferenceImage(arguments: arguments, context: context)
        case "short_drama_upsert_shot":
            return try await AgentShortDramaTools.upsertShot(arguments: arguments, context: context)
        case "short_drama_duplicate_shot":
            return try await AgentShortDramaTools.duplicateShot(arguments: arguments, context: context)
        case "short_drama_move_shot":
            return try await AgentShortDramaTools.moveShot(arguments: arguments, context: context)
        case "short_drama_delete_structure_item":
            return try await AgentShortDramaTools.deleteStructureItem(arguments: arguments, context: context)
        case "short_drama_reorder_structure_items":
            return try await AgentShortDramaTools.reorderStructureItems(arguments: arguments, context: context)
        case "short_drama_generate_shot_media":
            return try await AgentShortDramaTools.generateShotMedia(arguments: arguments, context: context)
        case "short_drama_generate_batch_media":
            return try await AgentShortDramaBatchTools.generateBatchMedia(arguments: arguments, context: context)
        case "short_drama_generate_asset_media":
            return try await AgentShortDramaTools.generateAssetMedia(arguments: arguments, context: context)
        case "short_drama_upsert_review_item":
            return try await AgentShortDramaTools.upsertReviewItem(arguments: arguments, context: context)
        case "short_drama_import_review_csv":
            return try await AgentShortDramaTools.importReviewCSV(arguments: arguments, context: context)
        case "short_drama_resolve_review_item":
            return try await AgentShortDramaTools.resolveReviewItem(arguments: arguments, context: context)
        case "short_drama_update_shot_statuses":
            return try await AgentShortDramaTools.updateShotStatuses(arguments: arguments, context: context)
        case "short_drama_update_shot_links":
            return try await AgentShortDramaTools.updateShotLinks(arguments: arguments, context: context)
        case "short_drama_select_shot_artifact":
            return try await AgentShortDramaTools.selectShotArtifact(arguments: arguments, context: context)
        case "short_drama_list_projects":
            return try await AgentShortDramaTools.listProjects(arguments: arguments, context: context)
        case "short_drama_show_storyboard_widget":
            return try await AgentShortDramaTools.showStoryboardWidget(arguments: arguments, context: context)
        case "short_drama_show_image_choice_widget":
            return try await AgentShortDramaTools.showImageChoiceWidget(arguments: arguments, context: context)
        case "short_drama_open_media_tasks":
            return try await AgentShortDramaMediaTaskTools.openMediaTasks(arguments: arguments, context: context)
        case "short_drama_refresh_media_tasks":
            return try await AgentShortDramaMediaTaskTools.refreshMediaTasks(arguments: arguments, context: context)
        case "short_drama_retry_media_task":
            return try await AgentShortDramaMediaTaskTools.retryMediaTask(arguments: arguments, context: context)
        case "short_drama_retry_failed_media_tasks":
            return try await AgentShortDramaMediaTaskTools.retryFailedMediaTasks(arguments: arguments, context: context)
        case "short_drama_open_image_editor":
            return try await AgentShortDramaImageTools.openImageEditor(arguments: arguments, context: context)
        case "short_drama_upscale_shot_artifact":
            return try await AgentShortDramaImageTools.upscaleShotArtifact(arguments: arguments, context: context)
        case "short_drama_export_production_package":
            return try await AgentShortDramaTools.exportProductionPackage(arguments: arguments, context: context)
        default:
            throw AgentToolError.unknownTool(name)
        }
    }
}
