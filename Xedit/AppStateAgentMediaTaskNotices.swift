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

    nonisolated static func mediaTaskCompletionNotice(for task: AgentMediaTask) -> String {
        let artifactLines: [String] = task.artifacts.isEmpty
            ? ["Artifacts: none."]
            : ["Artifacts:"] + task.artifacts.map { "- \($0.title): \($0.filePath)" }
        let anchorLines = mediaTaskAnchorLines(for: task)
        let followUpLines = mediaTaskFollowUpLines(for: task)
        let actionLines = mediaTaskActionLines(for: task)
        var lines = [
            "<media-task-notification>",
            "Remote media task \(task.displayHandle) finished while you were not in this turn.",
            "Provider: \(task.provider.displayName)",
            "Kind: \(task.kind.displayName)",
            "Title: \(task.title)",
            "Status: \(task.status.rawValue).",
            "Created at: \(mediaTaskNoticeTimestamp(task.createdAt))",
            "Updated at: \(mediaTaskNoticeTimestamp(task.updatedAt))"
        ]
        if let finishedAt = task.finishedAt {
            lines.append("Finished at: \(mediaTaskNoticeTimestamp(finishedAt))")
        }
        if let model = task.model, !model.isEmpty {
            lines.append("Model: \(model)")
        }
        if let remoteTaskID = task.remoteTaskID, !remoteTaskID.isEmpty {
            lines.append("Remote task id: \(remoteTaskID)")
        }
        if let statusURL = task.statusURL, !statusURL.isEmpty {
            lines.append("Status URL: \(statusURL)")
        }
        if let cancelURL = task.cancelURL, !cancelURL.isEmpty {
            lines.append("Cancel URL: \(cancelURL)")
        }
        if let sourceImagePath = task.sourceImagePath, !sourceImagePath.isEmpty {
            lines.append("Source image: \(sourceImagePath)")
        }
        if let maskPath = task.maskPath, !maskPath.isEmpty {
            lines.append("Mask: \(maskPath)")
        }
        if let message = task.statusMessage, !message.isEmpty {
            lines.append("Status message: \(message)")
        }
        if !anchorLines.isEmpty {
            lines.append("Anchors:")
            lines.append(contentsOf: anchorLines)
        }
        lines.append(contentsOf: artifactLines)
        if !followUpLines.isEmpty {
            lines.append("Suggested follow-up:")
            lines.append(contentsOf: followUpLines)
        }
        if !actionLines.isEmpty {
            lines.append("Structured action context:")
            lines.append(contentsOf: actionLines)
        }
        lines.append("</media-task-notification>")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func mediaTaskAnchorLines(for task: AgentMediaTask) -> [String] {
        var lines: [String] = []
        if let projectID = cleanMediaTaskNoticeValue(task.projectID) ?? cleanMediaTaskNoticeValue(task.projectPath) {
            lines.append("- project_id: \(projectID)")
        }
        if let episodeID = cleanMediaTaskNoticeValue(task.episodeID) {
            lines.append("- episode_id: \(episodeID)")
        }
        if let shotID = cleanMediaTaskNoticeValue(task.shotID) {
            lines.append("- shot_id: \(shotID)")
        }
        if let assetKind = cleanMediaTaskNoticeValue(task.assetKind) {
            lines.append("- asset_kind: \(assetKind)")
        }
        if let assetID = cleanMediaTaskNoticeValue(task.assetID) {
            lines.append("- asset_id: \(assetID)")
        }
        if let reviewItemID = cleanMediaTaskNoticeValue(task.reviewItemID) {
            lines.append("- review_item_id: \(reviewItemID)")
        }
        return lines
    }

    nonisolated private static func mediaTaskPanelScope(for task: AgentMediaTask) -> AgentMediaTaskScope? {
        let projectID = cleanMediaTaskNoticeValue(task.projectID) ?? cleanMediaTaskNoticeValue(task.projectPath)
        let episodeID = cleanMediaTaskNoticeValue(task.episodeID)
        let shotID = cleanMediaTaskNoticeValue(task.shotID)
        let assetKind = cleanMediaTaskNoticeValue(task.assetKind)
        let assetID = cleanMediaTaskNoticeValue(task.assetID)
        let reviewItemID = cleanMediaTaskNoticeValue(task.reviewItemID)
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

    nonisolated private static func mediaTaskActionLines(for task: AgentMediaTask) -> [String] {
        var lines = [
            "<media-task-action>",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "status: \(task.status.rawValue)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "created_at: \(mediaTaskNoticeTimestamp(task.createdAt))",
            "updated_at: \(mediaTaskNoticeTimestamp(task.updatedAt))"
        ]
        if let finishedAt = task.finishedAt {
            lines.append("finished_at: \(mediaTaskNoticeTimestamp(finishedAt))")
        }
        let projectID = cleanMediaTaskNoticeValue(task.projectID) ?? cleanMediaTaskNoticeValue(task.projectPath)
        let episodeID = cleanMediaTaskNoticeValue(task.episodeID)
        let shotID = cleanMediaTaskNoticeValue(task.shotID)
        let assetKind = cleanMediaTaskNoticeValue(task.assetKind)
        let assetID = cleanMediaTaskNoticeValue(task.assetID)
        let reviewItemID = cleanMediaTaskNoticeValue(task.reviewItemID)
        let statusURL = cleanMediaTaskNoticeValue(task.statusURL)
        let cancelURL = cleanMediaTaskNoticeValue(task.cancelURL)
        let statusEndpointSuffix = cleanMediaTaskNoticeValue(task.statusEndpointSuffix)
        let cancelEndpointSuffix = cleanMediaTaskNoticeValue(task.cancelEndpointSuffix)
        let sourceImagePath = cleanMediaTaskNoticeValue(task.sourceImagePath)
        let maskPath = cleanMediaTaskNoticeValue(task.maskPath)
        if let statusURL { lines.append("status_url: \(statusURL)") }
        if let cancelURL { lines.append("cancel_url: \(cancelURL)") }
        if let statusEndpointSuffix { lines.append("status_endpoint_suffix: \(statusEndpointSuffix)") }
        if let cancelEndpointSuffix { lines.append("cancel_endpoint_suffix: \(cancelEndpointSuffix)") }
        if let sourceImagePath { lines.append("source_image_path: \(sourceImagePath)") }
        if let maskPath { lines.append("mask_path: \(maskPath)") }
        if let projectID { lines.append("project_id: \(projectID)") }
        if let episodeID { lines.append("episode_id: \(episodeID)") }
        if let shotID { lines.append("shot_id: \(shotID)") }
        if let assetKind { lines.append("asset_kind: \(assetKind)") }
        if let assetID { lines.append("asset_id: \(assetID)") }
        if let reviewItemID { lines.append("review_item_id: \(reviewItemID)") }
        if let scopeArguments = mediaTaskNoticeScopeArguments(
            projectID: projectID,
            episodeID: episodeID,
            shotID: shotID,
            assetKind: assetKind,
            assetID: assetID,
            reviewItemID: reviewItemID
        ) {
            lines.append("open_scope_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_scope_tasks_arguments: \(scopeArguments)")
            lines.append("refresh_scope_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_scope_tasks_arguments: \(scopeArguments)")
        }

        if task.status == .succeeded {
            if let projectID, let episodeID, let shotID {
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot")
                let candidateImagePaths = task.artifacts.filter(Self.isImageArtifact).map(\.filePath)
                if candidateImagePaths.count > 1 {
                    lines.append("candidate_tool: short_drama_show_image_choice_widget")
                    let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
                    lines.append("candidate_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)")
                    let candidateImages = candidateImagePaths.joined(separator: " | ")
                    lines.append("candidate_image_paths: \(candidateImages)")
                    lines.append("candidate_preview_tool: show_image_choice_widget")
                    lines.append("candidate_preview_arguments: image_paths=\(candidateImages), project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)")
                } else if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                    lines.append("select_primary_tool: short_drama_select_shot_artifact")
                    lines.append("select_primary_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(artifact.filePath)")
                }
                if let videoArtifact = task.artifacts.first(where: Self.isVideoArtifact) {
                    lines.append("completed_video_path: \(videoArtifact.filePath)")
                    lines.append("completed_video_action: continue_from_completed_video_artifact")
                    lines.append("open_shot_tasks_tool: short_drama_open_media_tasks")
                    lines.append("open_shot_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot")
                    lines.append("refresh_shot_tasks_tool: short_drama_refresh_media_tasks")
                    lines.append("refresh_shot_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot")
                    lines.append("storyboard_widget_tool: short_drama_show_storyboard_widget")
                    lines.append("storyboard_widget_arguments: project_id=\(projectID), episode_id=\(episodeID)")
                }
                if isImageFollowUpKind(task.kind) {
                    if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                        let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
                        let artifactArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(artifact.filePath)\(reviewSuffix)"
                        lines.append("video_from_image_tool: generate_video_from_image")
                        lines.append("video_from_image_arguments: image_path=\(artifact.filePath), project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)")
                        lines.append("edit_tool: short_drama_open_image_editor")
                        lines.append("edit_arguments: \(artifactArguments), operation=inpaint")
                        lines.append("erase_tool: short_drama_open_image_editor")
                        lines.append("erase_arguments: \(artifactArguments), operation=erase")
                        lines.append("upscale_tool: short_drama_upscale_shot_artifact")
                        lines.append("upscale_arguments: \(artifactArguments)")
                    }
                    lines.append("video_tool: short_drama_generate_shot_media")
                    lines.append("video_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), kind=video_generation")
                }
                if let reviewItemID {
                    lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                    lines.append("open_review_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=review_item, review_item_id=\(reviewItemID)")
                    lines.append("resolve_review_tool: short_drama_resolve_review_item")
                    lines.append("resolve_review_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
                }
            } else if let projectID, let assetKind, let assetID {
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)")
                lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)")
                lines.append("generate_asset_reference_tool: short_drama_generate_asset_media")
                lines.append("generate_asset_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                    lines.append("attach_reference_tool: short_drama_attach_asset_reference_image")
                    lines.append("attach_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=\(artifact.filePath)")
                    lines.append("edit_tool: open_image_editor")
                    lines.append("edit_arguments: image_path=\(artifact.filePath), operation=inpaint, project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                    lines.append("erase_tool: open_image_editor")
                    lines.append("erase_arguments: image_path=\(artifact.filePath), operation=erase, project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                    lines.append("upscale_tool: upscale_image")
                    lines.append("upscale_arguments: image_path=\(artifact.filePath), project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                }
                lines.append("next_step: use this reference image when generating related short-drama shots.")
            } else if isImageFollowUpKind(task.kind) {
                let imageArtifacts = task.artifacts.filter(Self.isImageArtifact)
                if imageArtifacts.count > 1 {
                    let imagePaths = imageArtifacts.map(\.filePath).joined(separator: " | ")
                    lines.append("candidate_tool: show_image_choice_widget")
                    lines.append("candidate_arguments: image_paths=\(imagePaths)")
                } else if let artifact = imageArtifacts.first {
                    lines.append("edit_tool: open_image_editor")
                    lines.append("edit_arguments: image_path=\(artifact.filePath), operation=inpaint")
                    lines.append("erase_tool: open_image_editor")
                    lines.append("erase_arguments: image_path=\(artifact.filePath), operation=erase")
                    lines.append("upscale_tool: upscale_image")
                    lines.append("upscale_arguments: image_path=\(artifact.filePath)")
                    lines.append("video_from_image_tool: generate_video_from_image")
                    lines.append("video_from_image_arguments: image_path=\(artifact.filePath)")
                }
                lines.append("next_step: attach one artifact to chat, open it in the image editor, upscale it, generate video from it, or import it into a short-drama shot or asset.")
            }
        } else {
            if let sourceImagePath, let maskPath, isImageFollowUpKind(task.kind) {
                let operation = task.kind == .imageErase ? "erase" : "inpaint"
                if let projectID, let episodeID, let shotID {
                    lines.append("reopen_editor_tool: short_drama_open_image_editor")
                    var reopenArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
                    if let reviewItemID {
                        reopenArguments += ", review_item_id=\(reviewItemID)"
                    }
                    lines.append("reopen_editor_arguments: \(reopenArguments)")
                } else {
                    lines.append("reopen_editor_tool: open_image_editor")
                    var reopenArguments = "image_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
                    if let projectID {
                        reopenArguments += ", project_id=\(projectID)"
                    }
                    if let assetKind {
                        reopenArguments += ", asset_kind=\(assetKind)"
                    }
                    if let assetID {
                        reopenArguments += ", asset_id=\(assetID)"
                    }
                    if let reviewItemID {
                        reopenArguments += ", review_item_id=\(reviewItemID)"
                    }
                    lines.append("reopen_editor_arguments: \(reopenArguments)")
                }
            }
            if projectID != nil {
                lines.append("retry_tool: short_drama_retry_media_task")
                lines.append("retry_arguments: task_id=\(task.displayHandle)")
            }
            if let projectID {
                let scopeArguments: String
                if let episodeID, let shotID {
                    scopeArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot"
                } else if let assetKind, let assetID {
                    scopeArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
                } else {
                    scopeArguments = "project_id=\(projectID), scope=project"
                }
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: \(scopeArguments)")
            }
        }

        if !task.artifacts.isEmpty {
            lines.append("artifact_paths:")
            lines.append(contentsOf: task.artifacts.prefix(12).map { "- \($0.filePath)" })
            if task.artifacts.count > 12 {
                lines.append("- ... \(task.artifacts.count - 12) more")
            }
        }
        lines.append("</media-task-action>")
        return lines
    }
}
