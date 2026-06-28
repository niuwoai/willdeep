//
//  AgentShortDramaProductionReviewRecommendations.swift
//  WillDeep
//
//  Tool handoff recommendations for production-package review items.
//

import Foundation

extension AgentShortDramaProductionExporter {
    struct ProductionReviewItemRecommendation {
        let hint: String
        let tool: String
        let arguments: String
        var secondaryTool: String?
        var secondaryArguments: String?
    }

    static func productionReviewItemRecommendation(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem,
        selectedPath: String
    ) -> ProductionReviewItemRecommendation {
        let baseArguments = "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), review_item_id=\(item.id.uuidString)"
        let regenerateArguments = "\(baseArguments), kind=image_generation"
        switch item.kind {
        case .redraw:
            guard !selectedPath.isEmpty else {
                return ProductionReviewItemRecommendation(
                    hint: "当前分镜没有可编辑主图，请先调用 short_drama_generate_shot_media，并传入 review_item_id。",
                    tool: "short_drama_generate_shot_media",
                    arguments: regenerateArguments
                )
            }
            return ProductionReviewItemRecommendation(
                hint: "请调用 short_drama_open_image_editor，传入 operation=inpaint、artifact_path 和 review_item_id。",
                tool: "short_drama_open_image_editor",
                arguments: "\(baseArguments), operation=inpaint, artifact_path=\(selectedPath)"
            )
        case .erase:
            guard !selectedPath.isEmpty else {
                return ProductionReviewItemRecommendation(
                    hint: "当前分镜没有可擦除主图，请先调用 short_drama_generate_shot_media，并传入 review_item_id。",
                    tool: "short_drama_generate_shot_media",
                    arguments: regenerateArguments
                )
            }
            return ProductionReviewItemRecommendation(
                hint: "请调用 short_drama_open_image_editor，传入 operation=erase、artifact_path 和 review_item_id。",
                tool: "short_drama_open_image_editor",
                arguments: "\(baseArguments), operation=erase, artifact_path=\(selectedPath)"
            )
        case .upscale:
            guard !selectedPath.isEmpty else {
                return ProductionReviewItemRecommendation(
                    hint: "当前分镜没有可放大主图，请先调用 short_drama_generate_shot_media，并传入 review_item_id。",
                    tool: "short_drama_generate_shot_media",
                    arguments: regenerateArguments
                )
            }
            return ProductionReviewItemRecommendation(
                hint: "请调用 short_drama_upscale_shot_artifact，传入 artifact_path 和 review_item_id。",
                tool: "short_drama_upscale_shot_artifact",
                arguments: "\(baseArguments), artifact_path=\(selectedPath)"
            )
        case .reshoot:
            return ProductionReviewItemRecommendation(
                hint: "请调用 short_drama_generate_shot_media，传入 kind=image_generation 和 review_item_id。",
                tool: "short_drama_generate_shot_media",
                arguments: regenerateArguments
            )
        case .prompt:
            return ProductionReviewItemRecommendation(
                hint: "请先修正分镜 prompt；如果需要重新生成，请调用 short_drama_generate_shot_media 并传入 review_item_id。",
                tool: "short_drama_generate_shot_media",
                arguments: regenerateArguments,
                secondaryTool: "short_drama_upsert_review_item",
                secondaryArguments: "\(baseArguments), kind=prompt, status=doing"
            )
        case .continuity, .note:
            return ProductionReviewItemRecommendation(
                hint: "请先分析这条检查项；如果需要生成、编辑、放大或关闭检查项，必须沿用 review_item_id。",
                tool: "short_drama_open_media_tasks",
                arguments: "\(baseArguments), scope=review_item"
            )
        }
    }
}
