//
//  AgentMediaTaskCompletionContext.swift
//  WillDeep
//
//  Compact runtime context for the most recent completed media task. The
//  registry remains the source of truth; this block makes the completion
//  actionable in the next model request.
//

import Foundation

struct AgentMediaTaskCompletionContext: Equatable, Identifiable {
    let id: UUID
    var taskID: UUID
    var taskHandle: String
    var provider: AgentMediaTaskProvider
    var kind: AgentMediaTaskKind
    var status: AgentMediaTaskStatus
    var title: String
    var prompt: String?
    var sourceImagePath: String?
    var maskPath: String?
    var reviewItemID: String?
    var projectID: String?
    var episodeID: String?
    var shotID: String?
    var assetKind: String?
    var assetID: String?
    var artifactPaths: [String]
    var videoPaths: [String]
    var imagePaths: [String]
    var completedAt: Date

    init(task: AgentMediaTask) {
        self.id = UUID()
        self.taskID = task.id
        self.taskHandle = task.displayHandle
        self.provider = task.provider
        self.kind = task.kind
        self.status = task.status
        self.title = task.title
        self.prompt = Self.clean(task.prompt)
        self.sourceImagePath = Self.clean(task.sourceImagePath)
        self.maskPath = Self.clean(task.maskPath)
        self.reviewItemID = Self.clean(task.reviewItemID)
        self.projectID = Self.clean(task.projectID ?? task.projectPath)
        self.episodeID = Self.clean(task.episodeID)
        self.shotID = Self.clean(task.shotID)
        self.assetKind = Self.clean(task.assetKind)
        self.assetID = Self.clean(task.assetID)
        self.artifactPaths = task.artifacts.map(\.filePath)
        self.imagePaths = task.artifacts.map(\.filePath).filter(Self.isImagePath)
        self.videoPaths = task.artifacts.map(\.filePath).filter(Self.isVideoPath)
        self.completedAt = task.finishedAt ?? task.updatedAt
    }

    var systemPromptBlock: String {
        var lines = [
            "=== Latest Media Task Completion ===",
            "<latest-media-task-completion>",
            "task_id: \(taskHandle)",
            "task_uuid: \(taskID.uuidString)",
            "provider: \(provider.rawValue)",
            "kind: \(kind.rawValue)",
            "status: \(status.rawValue)",
            "title: \(title)"
        ]
        appendCleanLine("prompt", prompt, to: &lines)
        appendCleanLine("source_image_path", sourceImagePath, to: &lines)
        appendCleanLine("mask_path", maskPath, to: &lines)
        appendCleanLine("project_id", projectID, to: &lines)
        appendCleanLine("episode_id", episodeID, to: &lines)
        appendCleanLine("shot_id", shotID, to: &lines)
        appendCleanLine("asset_kind", assetKind, to: &lines)
        appendCleanLine("asset_id", assetID, to: &lines)
        appendCleanLine("review_item_id", reviewItemID, to: &lines)
        appendList("artifact_paths", artifactPaths, to: &lines)
        appendList("image_paths", imagePaths, to: &lines)
        appendList("video_paths", videoPaths, to: &lines)
        lines.append(contentsOf: followUpLines)
        lines.append("</latest-media-task-completion>")
        return lines.joined(separator: "\n")
    }

    private var followUpLines: [String] {
        var lines: [String] = []
        if status == .succeeded {
            lines.append("completion_note: artifacts have been synced into the media task registry and any matching short-drama shot or asset anchors.")
        } else {
            lines.append("completion_note: task ended without success; inspect status_message and decide whether to retry, cancel, or adjust the prompt.")
        }
        if let projectID {
            if let episodeID, let shotID {
                let shotScope = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot"
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: \(shotScope)")
                lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_tasks_arguments: \(shotScope)")
                if imagePaths.count > 1 {
                    lines.append("image_choice_tool: short_drama_show_image_choice_widget")
                    lines.append("image_choice_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewItemSuffix)")
                } else if let imagePath = imagePaths.first {
                    lines.append("select_primary_tool: short_drama_select_shot_artifact")
                    lines.append("select_primary_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(imagePath)\(reviewItemSuffix)")
                    lines.append("video_from_image_tool: generate_video_from_image")
                    lines.append("video_from_image_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), image_path=\(imagePath)\(reviewItemSuffix)")
                    lines.append("edit_image_tool: short_drama_open_image_editor")
                    lines.append("edit_image_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(imagePath), operation=inpaint\(reviewItemSuffix)")
                    lines.append("erase_image_tool: short_drama_open_image_editor")
                    lines.append("erase_image_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(imagePath), operation=erase\(reviewItemSuffix)")
                    lines.append("upscale_image_tool: short_drama_upscale_shot_artifact")
                    lines.append("upscale_image_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(imagePath)\(reviewItemSuffix)")
                }
                if !videoPaths.isEmpty {
                    lines.append("storyboard_widget_tool: short_drama_show_storyboard_widget")
                    lines.append("storyboard_widget_arguments: project_id=\(projectID), episode_id=\(episodeID)")
                }
                if let reviewItemID {
                    let reviewScope = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=review_item, review_item_id=\(reviewItemID)"
                    lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                    lines.append("open_review_tasks_arguments: \(reviewScope)")
                    lines.append("resolve_review_tool: short_drama_resolve_review_item")
                    lines.append("resolve_review_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
                }
            } else if let assetKind, let assetID {
                let assetScope = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
                lines.append("open_asset_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_asset_tasks_arguments: \(assetScope)")
                if let imagePath = imagePaths.first {
                    lines.append("attach_reference_tool: short_drama_attach_asset_reference_image")
                    lines.append("attach_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=\(imagePath)")
                }
            }
        } else if imagePaths.count > 1 {
            lines.append("image_choice_tool: show_image_choice_widget")
            lines.append("image_choice_arguments: image_paths=\(imagePaths.joined(separator: " | "))")
        } else if let imagePath = imagePaths.first {
            lines.append("edit_image_tool: open_image_editor")
            lines.append("edit_image_arguments: image_path=\(imagePath), operation=inpaint")
            lines.append("erase_image_tool: open_image_editor")
            lines.append("erase_image_arguments: image_path=\(imagePath), operation=erase")
            lines.append("upscale_image_tool: upscale_image")
            lines.append("upscale_image_arguments: image_path=\(imagePath)")
            lines.append("video_from_image_tool: generate_video_from_image")
            lines.append("video_from_image_arguments: image_path=\(imagePath)")
        }
        return lines
    }

    private var reviewItemSuffix: String {
        reviewItemID.map { ", review_item_id=\($0)" } ?? ""
    }

    private func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = Self.clean(value) else { return }
        lines.append("\(key): \(value)")
    }

    private func appendList(_ key: String, _ values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(key):")
        lines.append(contentsOf: values.prefix(12).map { "- \($0)" })
    }

    private nonisolated static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private nonisolated static func isVideoPath(_ path: String) -> Bool {
        ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
extension AppState {
    var agentLatestMediaTaskCompletion: AgentMediaTaskCompletionContext? {
        get { activeRuntime?.latestMediaTaskCompletion }
        set { activeRuntime?.latestMediaTaskCompletion = newValue }
    }

    func recordAgentMediaTaskCompletion(task: AgentMediaTask, runtimeID: UUID?) {
        let context = AgentMediaTaskCompletionContext(task: task)
        let runtime = runtimeID.flatMap { agentRuntimes[$0] } ?? activeRuntime
        runtime?.latestMediaTaskCompletion = context
        if let editSubmission = AgentImageEditSubmission(task: task) {
            runtime?.latestImageEditSubmission = editSubmission
        }
    }
}
