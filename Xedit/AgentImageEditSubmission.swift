//
//  AgentImageEditSubmission.swift
//  WillDeep
//
//  Runtime context for the latest submitted mask-edit task. This mirrors
//  AgentImageChoiceSelection: the task still lives in AgentMediaTaskRegistry,
//  but the next model turn also receives a compact structured reminder.
//

import Foundation

struct AgentImageEditSubmission: Equatable, Identifiable {
    let id: UUID
    var taskID: UUID
    var taskHandle: String
    var provider: AgentMediaTaskProvider
    var kind: AgentMediaTaskKind
    var status: AgentMediaTaskStatus
    var title: String
    var prompt: String?
    var model: String?
    var remoteTaskID: String?
    var statusURL: String?
    var cancelURL: String?
    var statusEndpointSuffix: String?
    var cancelEndpointSuffix: String?
    var sourceImagePath: String
    var maskPath: String
    var projectID: String?
    var episodeID: String?
    var shotID: String?
    var assetKind: String?
    var assetID: String?
    var reviewItemID: String?
    var artifactPaths: [String]
    var createdAt: Date

    init?(task: AgentMediaTask) {
        guard let sourceImagePath = Self.clean(task.sourceImagePath),
              let maskPath = Self.clean(task.maskPath),
              Self.isMaskEditKind(task.kind) else {
            return nil
        }
        self.id = UUID()
        self.taskID = task.id
        self.taskHandle = task.displayHandle
        self.provider = task.provider
        self.kind = task.kind
        self.status = task.status
        self.title = task.title
        self.prompt = Self.clean(task.prompt)
        self.model = Self.clean(task.model)
        self.remoteTaskID = Self.clean(task.remoteTaskID)
        self.statusURL = Self.clean(task.statusURL)
        self.cancelURL = Self.clean(task.cancelURL)
        self.statusEndpointSuffix = Self.clean(task.statusEndpointSuffix)
        self.cancelEndpointSuffix = Self.clean(task.cancelEndpointSuffix)
        self.sourceImagePath = sourceImagePath
        self.maskPath = maskPath
        self.projectID = Self.clean(task.projectID ?? task.projectPath)
        self.episodeID = Self.clean(task.episodeID)
        self.shotID = Self.clean(task.shotID)
        self.assetKind = Self.clean(task.assetKind)
        self.assetID = Self.clean(task.assetID)
        self.reviewItemID = Self.clean(task.reviewItemID)
        self.artifactPaths = task.artifacts.map(\.filePath)
        self.createdAt = Date()
    }

    var systemPromptBlock: String {
        var lines = [
            "=== Latest Image Edit Submission ===",
            "<latest-image-edit-submission>",
            "task_id: \(taskHandle)",
            "task_uuid: \(taskID.uuidString)",
            "provider: \(provider.rawValue)",
            "kind: \(kind.rawValue)",
            "status: \(status.rawValue)",
            "title: \(title)",
            "source_image_path: \(sourceImagePath)",
            "mask_path: \(maskPath)"
        ]
        appendCleanLine("prompt", prompt, to: &lines)
        appendCleanLine("model", model, to: &lines)
        appendCleanLine("remote_task_id", remoteTaskID, to: &lines)
        appendCleanLine("status_url", statusURL, to: &lines)
        appendCleanLine("cancel_url", cancelURL, to: &lines)
        appendCleanLine("status_endpoint_suffix", statusEndpointSuffix, to: &lines)
        appendCleanLine("cancel_endpoint_suffix", cancelEndpointSuffix, to: &lines)
        appendCleanLine("project_id", projectID, to: &lines)
        appendCleanLine("episode_id", episodeID, to: &lines)
        appendCleanLine("shot_id", shotID, to: &lines)
        appendCleanLine("asset_kind", assetKind, to: &lines)
        appendCleanLine("asset_id", assetID, to: &lines)
        appendCleanLine("review_item_id", reviewItemID, to: &lines)
        if !artifactPaths.isEmpty {
            lines.append("artifact_paths:")
            lines.append(contentsOf: artifactPaths.prefix(12).map { "- \($0)" })
        }
        lines.append(contentsOf: followUpLines)
        lines.append("</latest-image-edit-submission>")
        return lines.joined(separator: "\n")
    }

    private var followUpLines: [String] {
        let operation = kind == .imageErase ? "erase" : "inpaint"
        var lines = [
            "reopen_editor_tool: \(hasShotAnchor ? "short_drama_open_image_editor" : "open_image_editor")",
            "reopen_editor_arguments: \(reopenEditorArguments(operation: operation))"
        ]
        if status.isActive {
            lines.append("poll_note: this edit task is still active; refresh the media task scope before deciding whether to retry or continue.")
        }
        if let projectID {
            if let episodeID, let shotID {
                let shotScope = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot"
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: \(shotScope)")
                lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_tasks_arguments: \(shotScope)")
                if let reviewItemID {
                    let reviewScope = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=review_item, review_item_id=\(reviewItemID)"
                    lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                    lines.append("open_review_tasks_arguments: \(reviewScope)")
                    lines.append("refresh_review_tasks_tool: short_drama_refresh_media_tasks")
                    lines.append("refresh_review_tasks_arguments: \(reviewScope)")
                    lines.append("resolve_review_tool: short_drama_resolve_review_item")
                    lines.append("resolve_review_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
                }
            } else if let assetKind, let assetID {
                let assetScope = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
                lines.append("open_asset_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_asset_tasks_arguments: \(assetScope)")
                lines.append("refresh_asset_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_asset_tasks_arguments: \(assetScope)")
                lines.append("attach_completed_reference_tool: short_drama_attach_asset_reference_image")
                lines.append("attach_completed_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=<completed_artifact_path>")
            }
        }
        if status == .succeeded, let firstArtifact = artifactPaths.first {
            lines.append("completed_artifact_path: \(firstArtifact)")
            if hasShotAnchor {
                lines.append("select_completed_as_primary_tool: short_drama_select_shot_artifact")
                lines.append("select_completed_as_primary_arguments: \(shotBaseArguments), artifact_path=\(firstArtifact)")
                lines.append("video_from_completed_tool: generate_video_from_image")
                lines.append("video_from_completed_arguments: \(shotBaseArguments), image_path=\(firstArtifact)\(reviewItemSuffix)")
            } else {
                lines.append("edit_completed_tool: open_image_editor")
                lines.append("edit_completed_arguments: image_path=\(firstArtifact), operation=inpaint")
                lines.append("upscale_completed_tool: upscale_image")
                lines.append("upscale_completed_arguments: image_path=\(firstArtifact)")
            }
        }
        return lines
    }

    private var hasShotAnchor: Bool {
        projectID != nil && episodeID != nil && shotID != nil
    }

    private var shotBaseArguments: String {
        [
            projectID.map { "project_id=\($0)" },
            episodeID.map { "episode_id=\($0)" },
            shotID.map { "shot_id=\($0)" }
        ]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var reviewItemSuffix: String {
        reviewItemID.map { ", review_item_id=\($0)" } ?? ""
    }

    private func reopenEditorArguments(operation: String) -> String {
        var pairs = [
            hasShotAnchor ? "artifact_path=\(sourceImagePath)" : "image_path=\(sourceImagePath)",
            "mask_path=\(maskPath)",
            "operation=\(operation)"
        ]
        appendCleanPair("project_id", projectID, to: &pairs)
        appendCleanPair("episode_id", episodeID, to: &pairs)
        appendCleanPair("shot_id", shotID, to: &pairs)
        appendCleanPair("asset_kind", assetKind, to: &pairs)
        appendCleanPair("asset_id", assetID, to: &pairs)
        appendCleanPair("review_item_id", reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func isMaskEditKind(_ kind: AgentMediaTaskKind) -> Bool {
        kind == .imageEdit || kind == .imageErase || kind == .imageInpaint
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = Self.clean(value) else { return }
        lines.append("\(key): \(value)")
    }

    private func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [String]) {
        guard let value = Self.clean(value) else { return }
        pairs.append("\(key)=\(value)")
    }
}

@MainActor
extension AppState {
    var agentLatestImageEditSubmission: AgentImageEditSubmission? {
        get { activeRuntime?.latestImageEditSubmission }
        set { activeRuntime?.latestImageEditSubmission = newValue }
    }

    func recordAgentImageEditSubmission(task: AgentMediaTask) {
        guard let submission = AgentImageEditSubmission(task: task) else { return }
        let runtime = task.runtimeID.flatMap { agentRuntimes[$0] } ?? activeRuntime
        runtime?.latestImageEditSubmission = submission
    }
}
