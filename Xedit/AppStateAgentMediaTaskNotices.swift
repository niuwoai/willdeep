//
//  AppStateAgentMediaTaskNotices.swift
//  WillDeep
//
//  Formatting helpers for media-task completion notices. Kept separate from
//  the streaming loop so provider orchestration does not absorb presentation
//  details for image and short-drama follow-up actions.
//

import Foundation

extension AppState {
    nonisolated static func mediaTaskNoticeScopeArguments(
        projectID: String?,
        episodeID: String?,
        shotID: String?,
        assetKind: String?,
        assetID: String?,
        reviewItemID: String?
    ) -> String? {
        guard projectID != nil || episodeID != nil || shotID != nil || assetKind != nil || assetID != nil || reviewItemID != nil else {
            return nil
        }
        var pairs: [String] = []
        if let projectID { pairs.append("project_id=\(projectID)") }
        if let episodeID { pairs.append("episode_id=\(episodeID)") }
        if let shotID { pairs.append("shot_id=\(shotID)") }
        if let reviewItemID {
            pairs.append("scope=review_item")
            pairs.append("review_item_id=\(reviewItemID)")
        } else if let assetKind, let assetID {
            pairs.append("scope=asset")
            pairs.append("asset_kind=\(assetKind)")
            pairs.append("asset_id=\(assetID)")
        } else if shotID != nil {
            pairs.append("scope=shot")
        } else if episodeID != nil {
            pairs.append("scope=episode")
        } else {
            pairs.append("scope=project")
        }
        return pairs.joined(separator: ", ")
    }

    nonisolated static func mediaTaskFollowUpLines(for task: AgentMediaTask) -> [String] {
        guard task.status == .succeeded else {
            return ["- If the task failed or was canceled, explain the provider message and ask whether to retry or adjust the prompt."]
        }
        var lines: [String] = []
        if cleanMediaTaskNoticeValue(task.shotID) != nil {
            let imageArtifacts = task.artifacts.filter(Self.isImageArtifact)
            if imageArtifacts.count > 1 {
                lines.append("- For multiple image candidates, call `short_drama_show_image_choice_widget` so the user can pick the shot primary image.")
            } else if let artifact = imageArtifacts.first {
                lines.append("- For a single accepted storyboard image, call `short_drama_select_shot_artifact` with `artifact_path: \"\(artifact.filePath)\"` when the user wants it as the shot primary image.")
            }
            if let videoArtifact = task.artifacts.first(where: Self.isVideoArtifact) {
                lines.append("- This completed video is available at `\(videoArtifact.filePath)`; open or refresh the same shot media tasks, then return to `short_drama_show_storyboard_widget` to continue reviewing the episode.")
            }
            if isImageFollowUpKind(task.kind) {
                lines.append("- To continue production from a chosen keyframe, call `generate_video_from_image` with the artifact `image_path` and the same shot anchors; include `review_item_id` too when this task is linked to a review item. If the shot primary image is already selected and no explicit artifact path is needed, `short_drama_generate_shot_media(kind: \"video_generation\")` is also valid.")
                lines.append("- To refine the image, call `short_drama_open_image_editor` for mask redraw/erase, or `short_drama_upscale_shot_artifact` for enlargement.")
            }
            if cleanMediaTaskNoticeValue(task.reviewItemID) != nil {
                lines.append("- To inspect all tasks for the same review item, call `short_drama_open_media_tasks(scope: \"review_item\")` with the same project/episode/shot anchors and `review_item_id`.")
                lines.append("- This task is linked to a review item; after confirming the artifact fixes the issue, call `short_drama_resolve_review_item` with the same project/episode/shot anchors and `review_item_id`.")
            }
        } else if cleanMediaTaskNoticeValue(task.assetID) != nil {
            if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                lines.append("- To save this result as an asset reference image, call `short_drama_attach_asset_reference_image` with `image_path: \"\(artifact.filePath)\"` and the same asset anchors.")
                lines.append("- To refine this asset reference, call `open_image_editor` for redraw/erase or `upscale_image`; keep the same `project_id`, `asset_kind`, and `asset_id` so completed artifacts return to the asset.")
            }
            lines.append("- This result is anchored to a character or scene asset; use it as reference context for later `short_drama_generate_shot_media` calls.")
        } else if isImageFollowUpKind(task.kind) {
            if task.artifacts.filter(Self.isImageArtifact).count > 1 {
                lines.append("- For multiple image candidates outside a short-drama shot, call `show_image_choice_widget` with the artifact paths so the user can choose one before editing, upscaling, or generating video.")
            }
            lines.append("- Offer to attach one artifact to chat, open it in the image editor with `open_image_editor`, upscale it with `upscale_image`, generate video from it with `generate_video_from_image`, or import it into a short-drama shot/asset.")
        }
        return lines
    }

    nonisolated static func isImageFollowUpKind(_ kind: AgentMediaTaskKind) -> Bool {
        kind == .imageGeneration || kind == .imageEdit || kind == .imageInpaint || kind == .imageErase || kind == .imageUpscale
    }

    nonisolated static func mediaTaskNoticeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    nonisolated static func isImageArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }
        let pathExtension = URL(fileURLWithPath: artifact.filePath).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(pathExtension)
    }

    nonisolated static func isVideoArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("video/") {
            return true
        }
        let pathExtension = URL(fileURLWithPath: artifact.filePath).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(pathExtension)
    }

    nonisolated static func cleanMediaTaskNoticeValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
