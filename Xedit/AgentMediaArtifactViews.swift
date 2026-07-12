//
//  AgentMediaArtifactViews.swift
//  WillDeep
//
//  Artifact thumbnails and image choice widgets for the media task side panel.
//

import AppKit
import SwiftUI

// Thumbnail interaction moved to AgentMediaArtifactThumbnail.swift:
// struct AgentMediaArtifactThumbnail: View
// private var shotAnchor: (projectID: UUID?, episodeID: UUID?, shotID: UUID)?
// private var assetAnchor: (projectID: UUID, assetKind: String, assetID: UUID)?
// private var canSelectAsShotPrimary: Bool
// private var canAttachAsAssetReference: Bool
// private var isSelectedShotPrimary: Bool
// private var isSelectedAssetReference: Bool
// selectAsShotPrimary()
// attachAsAssetReference()
// appState.agentShortDramaStore.selectShotArtifact(
// appState.agentShortDramaStore.attachReferenceImages(
// artifactPath: artifact.filePath
// appendPrimarySelectionFollowUp(anchor: anchor)
// appendAssetReferenceFollowUp(anchor: anchor)
// assetKind: sourceTask.assetKind
// assetID: sourceTask.assetID
// reviewItemID: sourceTask.reviewItemID
// ("review_item_id", reviewItemID)
// context.append("review_item_id: \(reviewItemID)")
// <short-drama-primary-artifact-selected>
// <short-drama-asset-reference-attached>
// action: attach_asset_reference_from_media_task
// attach_reference_tool: short_drama_attach_asset_reference_image
// generate_asset_reference_tool: short_drama_generate_asset_media
// edit_reference_tool: open_image_editor
// upscale_reference_tool: upscale_image
// video_from_image_arguments: image_path=\(artifact.filePath)
// resolve_review_arguments: project_id=\(projectValue), episode_id=\(episodeID.uuidString), shot_id=\(anchor.shotID.uuidString), item_id=\(reviewItemID)
// appState.agentComposerFocusRevision += 1
// appState.agentShortDramaStore.setActiveProject(id: projectID)
// AgentSidePanelOpenRequest(kind: .shortDrama)
// 设为分镜主图
// 当前分镜主图
// 设为人物/场景参考图
// 已是资产参考图
// canSendVideoArtifactToChat
// appendVideoArtifactContextToChat()
// <media-task-video-artifact-selected>
// action: continue_from_selected_video_artifact
// video_path: \(artifact.filePath)
// storyboard_widget_tool: short_drama_show_storyboard_widget
// open_review_tasks_tool: short_drama_open_media_tasks

enum AgentMediaTaskChoiceWidgetBuilder {
    static func widget(for task: AgentMediaTask, artifacts: [AgentMediaArtifact]) -> AgentWidget {
        AgentWidget(
            title: "媒体任务候选图",
            html: html(for: task, artifacts: artifacts),
            contextLines: contextLines(for: task, artifacts: artifacts)
        )
    }

    private static func contextLines(for task: AgentMediaTask, artifacts: [AgentMediaArtifact]) -> [String] {
        var lines = [
            "<media-task-image-choice-widget>",
            "action: media_task_image_choice_widget",
            "task_id: \(task.id.uuidString)",
            "task_handle: \(task.displayHandle)",
            "image_count: \(artifacts.count)"
        ]
        lines.append(contentsOf: mediaTaskAnchorLines(task: task))
        lines.append("image_paths: \(artifacts.map(\.filePath).joined(separator: " | "))")
        let candidates = artifacts.prefix(12)
        if !candidates.isEmpty {
            lines.append("candidate_actions:")
            for (index, artifact) in candidates.enumerated() {
                lines.append("- index: \(index + 1)")
                lines.append("  image_path: \(artifact.filePath)")
                if let tool = mediaTaskChoiceRecommendedTool(task: task) {
                    lines.append("  select_tool: \(tool)")
                    lines.append("  select_arguments: \(mediaTaskChoiceRecommendedArguments(task: task, artifact: artifact))")
                }
                lines.append("  edit_tool: \(mediaTaskActionRecommendedTool(action: "open_image_editor", task: task) ?? "open_image_editor")")
                lines.append("  edit_arguments: \(mediaTaskActionRecommendedArguments(action: "open_image_editor", task: task, artifact: artifact, extraLines: ["operation: inpaint"]))")
                lines.append("  erase_tool: \(mediaTaskActionRecommendedTool(action: "open_image_editor", task: task) ?? "open_image_editor")")
                lines.append("  erase_arguments: \(mediaTaskActionRecommendedArguments(action: "open_image_editor", task: task, artifact: artifact, extraLines: ["operation: erase"]))")
                lines.append("  upscale_tool: \(mediaTaskActionRecommendedTool(action: "upscale_image", task: task) ?? "upscale_image")")
                lines.append("  upscale_arguments: \(mediaTaskActionRecommendedArguments(action: "upscale_image", task: task, artifact: artifact, extraLines: []))")
                lines.append("  video_tool: generate_video_from_image")
                lines.append("  video_arguments: \(mediaTaskActionRecommendedArguments(action: "generate_video_from_image", task: task, artifact: artifact, extraLines: []))")
            }
        }
        lines.append("</media-task-image-choice-widget>")
        return lines
    }

    private static func html(for task: AgentMediaTask, artifacts: [AgentMediaArtifact]) -> String {
        let items = artifacts.enumerated().map { index, artifact in
            itemHTML(task: task, artifact: artifact, index: index)
        }.joined(separator: "\n")
        return """
        <style>
          .wd-media-choice { display: grid; gap: 12px; }
          .head { display: flex; justify-content: space-between; gap: 12px; align-items: flex-start; border-bottom: 1px solid color-mix(in srgb, var(--secondary) 22%, transparent); padding-bottom: 10px; }
          .title { font-size: 17px; font-weight: 750; line-height: 1.25; }
          .meta { color: var(--secondary); margin-top: 4px; line-height: 1.4; }
          .pill { border: 1px solid color-mix(in srgb, var(--secondary) 24%, transparent); border-radius: 999px; padding: 4px 8px; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 7%, transparent); white-space: nowrap; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
          .candidate { border: 1px solid color-mix(in srgb, var(--secondary) 18%, transparent); border-radius: 8px; padding: 8px; display: grid; gap: 7px; background: color-mix(in srgb, var(--secondary) 5%, transparent); }
          .preview { width: 100%; aspect-ratio: 16 / 10; object-fit: cover; border-radius: 6px; background: color-mix(in srgb, var(--secondary) 8%, transparent); }
          .file { width: 100%; aspect-ratio: 16 / 10; border-radius: 6px; display: grid; place-items: center; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 8%, transparent); font-weight: 700; }
          .path { color: var(--secondary); font-size: 10px; font-family: ui-monospace, "SF Mono", Menlo, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .badge { color: var(--accent); font-size: 11px; font-weight: 650; min-height: 14px; }
          button { appearance: none; border: 1px solid color-mix(in srgb, var(--accent) 36%, transparent); background: color-mix(in srgb, var(--accent) 10%, transparent); color: var(--accent); border-radius: 6px; padding: 5px 8px; font: inherit; font-size: 12px; cursor: pointer; }
          button:hover { background: color-mix(in srgb, var(--accent) 18%, transparent); }
          .actions { display: flex; flex-wrap: wrap; gap: 6px; }
        </style>
        <div class="wd-media-choice">
          <div class="head">
            <div>
              <div class="title">选择媒体产物：\(escape(task.title))</div>
              <div class="meta">\(escape(task.displayHandle)) · \(escape(task.provider.displayName)) · \(escape(task.kind.displayName))</div>
            </div>
            <div class="pill">\(artifacts.count) 张图</div>
          </div>
          <div class="grid">\(items)</div>
        </div>
        """
    }

    private static func itemHTML(task: AgentMediaTask, artifact: AgentMediaArtifact, index: Int) -> String {
        let url = URL(fileURLWithPath: artifact.filePath)
        let preview: String
        if let dataURL = thumbnailDataURL(for: url, maxSide: 420, compression: 0.68) {
            preview = "<img class=\"preview\" src=\"\(dataURL)\" alt=\"\(escape(url.lastPathComponent))\">"
        } else {
            let ext = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
            preview = "<div class=\"file\">\(escape(ext))</div>"
        }
        // Contract migration: media-task choice buttons previously called
        // openEditorPrompt(task: task, artifact: artifact),
        // erasePrompt(task: task, artifact: artifact),
        // upscalePrompt(task: task, artifact: artifact), and
        // videoPrompt(task: task, artifact: artifact). They now use sendToolAction
        // while preserving those prompt helpers for fallback and source context.
        return """
        <article class="candidate">
          \(preview)
          <div class="badge">候选 \(index + 1)</div>
          <div class="path">\(escape(url.lastPathComponent))</div>
          <div class="actions">
            \(selectArtifactButton(task: task, artifact: artifact))
            \(mediaTaskToolActionButton(label: "打开蒙版", action: "open_image_editor", task: task, artifact: artifact, extraLines: ["operation: inpaint"], actionKey: "open_media_artifact_editor"))
            \(mediaTaskToolActionButton(label: "擦除区域", action: "open_image_editor", task: task, artifact: artifact, extraLines: ["operation: erase"], actionKey: "erase_media_artifact"))
            \(mediaTaskToolActionButton(label: "放大图片", action: "upscale_image", task: task, artifact: artifact, actionKey: "upscale_media_artifact"))
            \(mediaTaskToolActionButton(label: "生成视频", action: "generate_video_from_image", task: task, artifact: artifact, extraLines: ["kind: video_generation", "reference_image_path: \(artifact.filePath)"], actionKey: "video_from_media_artifact"))
          </div>
        </article>
        """
    }

    private static func selectArtifactButton(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        guard let tool = mediaTaskChoiceRecommendedTool(task: task) else {
            return "<button onclick=\"sendPrompt(\(selectArtifactPrompt(task: task, artifact: artifact)))\">选这张继续</button>"
        }
        return toolActionButton(
            label: "选这张继续",
            tool: tool,
            arguments: mediaTaskChoiceRecommendedArguments(task: task, artifact: artifact),
            note: selectArtifactPromptNote(task: task, artifact: artifact),
            actionKey: "select_media_artifact"
        )
    }

    private static func selectArtifactPrompt(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        return jsString(selectArtifactPromptNote(task: task, artifact: artifact))
    }

    private static func selectArtifactPromptNote(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        var context: [String] = [
            "<media-task-image-choice>",
            "action: select_media_artifact",
            "task_id: \(task.id.uuidString)",
            "task_handle: \(task.displayHandle)",
            "artifact_path: \(artifact.filePath)"
        ]
        if let projectID = task.projectID {
            context.append("project_id: \(projectID)")
        }
        if let episodeID = task.episodeID {
            context.append("episode_id: \(episodeID)")
        }
        if let shotID = task.shotID {
            context.append("shot_id: \(shotID)")
        }
        if let assetKind = task.assetKind {
            context.append("asset_kind: \(assetKind)")
        }
        if let assetID = task.assetID {
            context.append("asset_id: \(assetID)")
        }
        if let reviewItemID = task.reviewItemID {
            context.append("review_item_id: \(reviewItemID)")
        }
        context.append(contentsOf: mediaTaskChoiceRecommendationLines(task: task, artifact: artifact))
        context.append(contentsOf: mediaTaskChoiceFollowUpLines(task: task, artifact: artifact))
        context.append("</media-task-image-choice>")

        let instruction: String
        if task.projectID != nil, task.episodeID != nil, task.shotID != nil {
            instruction = "请把这张媒体任务候选图作为短剧分镜主图。请调用 short_drama_select_shot_artifact，并使用下面的 project_id / episode_id / shot_id / artifact_path；如果下面有 review_item_id，也要一并传入。完成后可基于这张图继续生成视频、重绘、放大或做连续性检查；如果下面有 review_item_id，后续媒体任务也必须继续携带。"
        } else {
            instruction = "我选择这张媒体任务候选图继续处理。请基于 artifact_path 分析图片，并根据上下文建议下一步：可以加入短剧分镜、放大、擦除、重绘或生成视频。"
        }

        return """
        \(instruction)

        \(context.joined(separator: "\n"))
        """
    }

    private static func mediaTaskToolActionButton(
        label: String,
        action: String,
        task: AgentMediaTask,
        artifact: AgentMediaArtifact,
        extraLines: [String] = [],
        actionKey: String
    ) -> String {
        let tool = mediaTaskActionRecommendedTool(action: action, task: task) ?? action
        return toolActionButton(
            label: label,
            tool: tool,
            arguments: mediaTaskActionRecommendedArguments(action: action, task: task, artifact: artifact, extraLines: extraLines),
            note: mediaTaskActionBlock(action: action, task: task, artifact: artifact, extraLines: extraLines),
            actionKey: actionKey
        )
    }

    private static func openEditorPrompt(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        jsString("""
        请打开这张媒体任务候选图的蒙版编辑器，方便我框选或涂抹要重绘的区域。请优先使用下面的 recommended_tool 和 recommended_arguments。

        \(mediaTaskActionBlock(action: "open_image_editor", task: task, artifact: artifact, extraLines: ["operation: inpaint"]))
        """)
    }

    private static func erasePrompt(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        jsString("""
        请打开这张媒体任务候选图的擦除蒙版编辑器，方便我框选或涂抹要移除的区域。请优先使用下面的 recommended_tool 和 recommended_arguments。

        \(mediaTaskActionBlock(action: "open_image_editor", task: task, artifact: artifact, extraLines: ["operation: erase"]))
        """)
    }

    private static func upscalePrompt(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        jsString("""
        请把这张媒体任务候选图提交到 Replicate 图片放大任务。请优先使用下面的 recommended_tool 和 recommended_arguments；如果下面有 review_item_id，也必须一并传入。

        \(mediaTaskActionBlock(action: "upscale_image", task: task, artifact: artifact))
        """)
    }

    private static func videoPrompt(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        jsString("""
        请把这张媒体任务候选图作为首帧/参考图生成视频。默认使用 Seedance 2.0；如果用户指定可灵/Kling，请在参数中加入 video_engine=kling。请优先使用下面的 recommended_tool 和 recommended_arguments，并根据上下文补充合适的视频运动提示词；如果下面有 review_item_id，也必须一并传入。

        \(mediaTaskActionBlock(action: "generate_video_from_image", task: task, artifact: artifact, extraLines: [
            "kind: video_generation",
            "reference_image_path: \(artifact.filePath)"
        ]))
        """)
    }

    private static func mediaTaskActionBlock(
        action: String,
        task: AgentMediaTask,
        artifact: AgentMediaArtifact,
        extraLines: [String] = []
    ) -> String {
        let lines = [
            "<media-task-image-choice>",
            "action: \(action)",
            "task_id: \(task.id.uuidString)",
            "task_handle: \(task.displayHandle)",
            "artifact_path: \(artifact.filePath)",
            "image_path: \(artifact.filePath)"
        ] + extraLines + mediaTaskAnchorLines(task: task) + mediaTaskActionRecommendationLines(
            action: action,
            task: task,
            artifact: artifact,
            extraLines: extraLines
        ) + [
            "</media-task-image-choice>"
        ]
        return lines.joined(separator: "\n")
    }

    private static func mediaTaskAnchorLines(task: AgentMediaTask) -> [String] {
        var lines: [String] = []
        appendCleanLine("project_id", task.projectID, to: &lines)
        appendCleanLine("episode_id", task.episodeID, to: &lines)
        appendCleanLine("shot_id", task.shotID, to: &lines)
        appendCleanLine("asset_kind", task.assetKind, to: &lines)
        appendCleanLine("asset_id", task.assetID, to: &lines)
        appendCleanLine("review_item_id", task.reviewItemID, to: &lines)
        return lines
    }

    private static func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        lines.append("\(key): \(value)")
    }

    private static func mediaTaskActionRecommendationLines(
        action: String,
        task: AgentMediaTask,
        artifact: AgentMediaArtifact,
        extraLines: [String]
    ) -> [String] {
        guard let tool = mediaTaskActionRecommendedTool(action: action, task: task) else { return [] }
        return [
            "recommended_tool: \(tool)",
            "recommended_arguments: \(mediaTaskActionRecommendedArguments(action: action, task: task, artifact: artifact, extraLines: extraLines))"
        ]
    }

    private static func mediaTaskActionRecommendedTool(action: String, task: AgentMediaTask) -> String? {
        switch action {
        case "open_image_editor":
            if task.projectID != nil, task.episodeID != nil, task.shotID != nil {
                return "short_drama_open_image_editor"
            }
            return "open_image_editor"
        case "upscale_image":
            if task.projectID != nil, task.episodeID != nil, task.shotID != nil {
                return "short_drama_upscale_shot_artifact"
            }
            return "upscale_image"
        case "generate_video_from_image":
            return "generate_video_from_image"
        default:
            return nil
        }
    }

    private static func mediaTaskActionRecommendedArguments(
        action: String,
        task: AgentMediaTask,
        artifact: AgentMediaArtifact,
        extraLines: [String]
    ) -> String {
        let operation = extraLines.first(where: { $0.hasPrefix("operation:") })?
            .replacingOccurrences(of: "operation:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var pairs: [(String, String)] = []
        switch action {
        case "open_image_editor":
            if task.projectID != nil, task.episodeID != nil, task.shotID != nil {
                pairs.append(("artifact_path", artifact.filePath))
            } else {
                pairs.append(("image_path", artifact.filePath))
            }
            if let operation {
                pairs.append(("operation", operation))
            }
            appendMediaTaskAnchorPairs(task, to: &pairs)
        case "upscale_image":
            if task.projectID != nil, task.episodeID != nil, task.shotID != nil {
                pairs.append(("artifact_path", artifact.filePath))
            } else {
                pairs.append(("image_path", artifact.filePath))
            }
            appendMediaTaskAnchorPairs(task, to: &pairs)
        case "generate_video_from_image":
            pairs.append(("image_path", artifact.filePath))
            appendMediaTaskShotAnchorPairs(task, to: &pairs)
        default:
            pairs.append(("image_path", artifact.filePath))
            appendMediaTaskAnchorPairs(task, to: &pairs)
        }
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private static func appendMediaTaskAnchorPairs(_ task: AgentMediaTask, to pairs: inout [(String, String)]) {
        appendMediaTaskShotAnchorPairs(task, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
    }

    private static func appendMediaTaskShotAnchorPairs(_ task: AgentMediaTask, to pairs: inout [(String, String)]) {
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
    }

    private static func mediaTaskChoiceRecommendationLines(task: AgentMediaTask, artifact: AgentMediaArtifact) -> [String] {
        guard let tool = mediaTaskChoiceRecommendedTool(task: task) else { return [] }
        return [
            "recommended_tool: \(tool)",
            "recommended_arguments: \(mediaTaskChoiceRecommendedArguments(task: task, artifact: artifact))"
        ]
    }

    private static func mediaTaskChoiceRecommendedTool(task: AgentMediaTask) -> String? {
        if task.projectID != nil, task.episodeID != nil, task.shotID != nil {
            return "short_drama_select_shot_artifact"
        }
        if task.projectID != nil, task.assetKind != nil, task.assetID != nil {
            return "short_drama_attach_asset_reference_image"
        }
        return nil
    }

    private static func mediaTaskChoiceRecommendedArguments(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        var pairs: [(String, String)] = []
        if task.episodeID != nil, task.shotID != nil {
            pairs.append(("artifact_path", artifact.filePath))
        } else {
            pairs.append(("image_path", artifact.filePath))
        }
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private static func mediaTaskChoiceFollowUpLines(task: AgentMediaTask, artifact: AgentMediaArtifact) -> [String] {
        if task.projectID != nil, task.episodeID != nil, task.shotID != nil {
            var shotTaskPairs: [(String, String)] = []
            appendMediaTaskShotAnchorPairs(task, to: &shotTaskPairs)
            shotTaskPairs.append(("scope", "shot"))
            var artifactPairs: [(String, String)] = [("artifact_path", artifact.filePath)]
            appendMediaTaskShotAnchorPairs(task, to: &artifactPairs)
            appendCleanPair("review_item_id", task.reviewItemID, to: &artifactPairs)
            var imagePairs: [(String, String)] = [("image_path", artifact.filePath)]
            appendMediaTaskShotAnchorPairs(task, to: &imagePairs)
            appendCleanPair("review_item_id", task.reviewItemID, to: &imagePairs)
            var lines = [
                "post_select_open_shot_tasks_tool: short_drama_open_media_tasks",
                "post_select_open_shot_tasks_arguments: \(argumentString(shotTaskPairs))",
                "post_select_video_tool: generate_video_from_image",
                "post_select_video_arguments: \(argumentString(imagePairs))",
                "post_select_edit_tool: short_drama_open_image_editor",
                "post_select_edit_arguments: \(argumentString(artifactPairs)), operation=inpaint",
                "post_select_erase_tool: short_drama_open_image_editor",
                "post_select_erase_arguments: \(argumentString(artifactPairs)), operation=erase",
                "post_select_upscale_tool: short_drama_upscale_shot_artifact",
                "post_select_upscale_arguments: \(argumentString(artifactPairs))"
            ]
            if let reviewItemID = task.reviewItemID?.trimmingCharacters(in: .whitespacesAndNewlines), !reviewItemID.isEmpty {
                var reviewTaskPairs: [(String, String)] = []
                appendMediaTaskShotAnchorPairs(task, to: &reviewTaskPairs)
                reviewTaskPairs.append(("scope", "review_item"))
                reviewTaskPairs.append(("review_item_id", reviewItemID))
                var reviewPairs: [(String, String)] = []
                appendMediaTaskShotAnchorPairs(task, to: &reviewPairs)
                reviewPairs.append(("item_id", reviewItemID))
                lines.append("post_select_open_review_tasks_tool: short_drama_open_media_tasks")
                lines.append("post_select_open_review_tasks_arguments: \(argumentString(reviewTaskPairs))")
                lines.append("post_select_resolve_review_tool: short_drama_resolve_review_item")
                lines.append("post_select_resolve_review_arguments: \(argumentString(reviewPairs))")
            }
            return lines
        }
        if task.projectID != nil, task.assetKind != nil, task.assetID != nil {
            var attachPairs: [(String, String)] = [("image_path", artifact.filePath)]
            appendMediaTaskAssetAnchorPairs(task, to: &attachPairs)
            appendCleanPair("review_item_id", task.reviewItemID, to: &attachPairs)
            var taskPairs: [(String, String)] = []
            appendMediaTaskAssetAnchorPairs(task, to: &taskPairs)
            taskPairs.append(("scope", "asset"))
            return [
                "post_select_attach_reference_tool: short_drama_attach_asset_reference_image",
                "post_select_attach_reference_arguments: \(argumentString(attachPairs))",
                "post_select_open_asset_tasks_tool: short_drama_open_media_tasks",
                "post_select_open_asset_tasks_arguments: \(argumentString(taskPairs))"
            ]
        }
        return []
    }

    private static func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [(String, String)]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        pairs.append((key, value))
    }

    private static func appendMediaTaskAssetAnchorPairs(_ task: AgentMediaTask, to pairs: inout [(String, String)]) {
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
    }

    private static func argumentString(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    fileprivate static func thumbnailDataURL(for url: URL, maxSide: CGFloat, compression: CGFloat) -> String? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxSide / max(width, height))
        let targetSize = NSSize(width: width * scale, height: height * scale)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(targetSize.width.rounded())),
            pixelsHigh: max(1, Int(targetSize.height.rounded())),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
            return nil
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    fileprivate static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    fileprivate static func toolActionButton(
        label: String,
        tool: String,
        arguments: String,
        note: String,
        actionKey: String
    ) -> String {
        let payload = [
            "tool": tool,
            "arguments": arguments,
            "note": note,
            "action_key": actionKey
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        let object = String(data: data, encoding: .utf8) ?? "{}"
        return "<button onclick=\"\(escape("sendToolAction(\(object))"))\">\(escape(label))</button>"
    }

    fileprivate static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum AgentImageChoiceWidgetBuilder {
    struct AnchorContext {
        var projectID: String?
        var episodeID: String?
        var shotID: String?
        var assetKind: String?
        var assetID: String?
        var reviewItemID: String?

        var lines: [String] {
            [
                ("project_id", projectID),
                ("episode_id", episodeID),
                ("shot_id", shotID),
                ("asset_kind", assetKind),
                ("asset_id", assetID),
                ("review_item_id", reviewItemID)
            ].compactMap { key, value in
                guard let value, !value.isEmpty else { return nil }
                return "\(key): \(value)"
            }
        }

        var hasShotAnchor: Bool {
            projectID != nil && episodeID != nil && shotID != nil
        }

        var hasAssetAnchor: Bool {
            projectID != nil && assetKind != nil && assetID != nil
        }
    }

    static func widget(
        title: String,
        note: String?,
        imagePaths: [String],
        anchor: AnchorContext,
        contextLines: [String] = []
    ) -> AgentWidget {
        AgentWidget(
            title: title,
            html: html(title: title, note: note, imagePaths: imagePaths, anchor: anchor),
            contextLines: contextLines + choiceWidgetContextLines(title: title, imagePaths: imagePaths, anchor: anchor)
        )
    }

    private static func choiceWidgetContextLines(title: String, imagePaths: [String], anchor: AnchorContext) -> [String] {
        var lines = [
            "<image-choice-widget>",
            "action: show_image_choice_widget",
            "title: \(title)",
            "image_count: \(imagePaths.count)"
        ]
        lines.append(contentsOf: anchor.lines)
        lines.append("post_select_action_keys: \(postSelectActionKeys(anchor: anchor).joined(separator: ", "))")
        lines.append("image_paths: \(imagePaths.joined(separator: " | "))")
        let candidates = imagePaths.prefix(12)
        if !candidates.isEmpty {
            lines.append("candidate_actions:")
            for (index, path) in candidates.enumerated() {
                lines.append("- index: \(index + 1)")
                lines.append("  image_path: \(path)")
                if let tool = recommendedTool(action: "select_image", anchor: anchor) {
                    lines.append("  select_tool: \(tool)")
                    lines.append("  select_arguments: \(recommendedArguments(action: "select_image", path: path, anchor: anchor, extraLines: []))")
                }
                lines.append("  edit_tool: \(recommendedTool(action: "open_image_editor", anchor: anchor) ?? "open_image_editor")")
                lines.append("  edit_arguments: \(recommendedArguments(action: "open_image_editor", path: path, anchor: anchor, extraLines: ["operation: inpaint"]))")
                lines.append("  erase_tool: \(recommendedTool(action: "open_image_editor", anchor: anchor) ?? "open_image_editor")")
                lines.append("  erase_arguments: \(recommendedArguments(action: "open_image_editor", path: path, anchor: anchor, extraLines: ["operation: erase"]))")
                lines.append("  upscale_tool: \(recommendedTool(action: "upscale_image", anchor: anchor) ?? "upscale_image")")
                lines.append("  upscale_arguments: \(recommendedArguments(action: "upscale_image", path: path, anchor: anchor, extraLines: []))")
                lines.append("  video_tool: generate_video_from_image")
                lines.append("  video_arguments: \(recommendedArguments(action: "generate_video_from_image", path: path, anchor: anchor, extraLines: []))")
            }
        }
        lines.append("</image-choice-widget>")
        return lines
    }

    private static func postSelectActionKeys(anchor: AnchorContext) -> [String] {
        if anchor.hasShotAnchor {
            var keys = [
                "post_select_open_shot_tasks",
                "post_select_video",
                "post_select_edit",
                "post_select_erase",
                "post_select_upscale"
            ]
            if let reviewItemID = anchor.reviewItemID, !reviewItemID.isEmpty {
                keys.append("post_select_open_review_tasks")
                keys.append("post_select_resolve_review")
            }
            return keys
        }
        if anchor.hasAssetAnchor {
            return [
                "post_select_attach_reference",
                "post_select_open_asset_tasks",
                "post_select_generate_related_shots",
                "post_select_edit",
                "post_select_erase",
                "post_select_upscale"
            ]
        }
        return [
            "recommended_tool",
            "post_select_edit",
            "post_select_erase",
            "post_select_upscale"
        ]
    }

    private static func html(title: String, note: String?, imagePaths: [String], anchor: AnchorContext) -> String {
        let items = imagePaths.enumerated().map { index, path in
            itemHTML(path: path, index: index, anchor: anchor)
        }.joined(separator: "\n")
        let escapedNote = note.map { "<div class=\"meta\">\(AgentMediaTaskChoiceWidgetBuilder.escape($0))</div>" } ?? ""
        return """
        <style>
          .wd-media-choice { display: grid; gap: 12px; }
          .head { display: flex; justify-content: space-between; gap: 12px; align-items: flex-start; border-bottom: 1px solid color-mix(in srgb, var(--secondary) 22%, transparent); padding-bottom: 10px; }
          .title { font-size: 17px; font-weight: 750; line-height: 1.25; }
          .meta { color: var(--secondary); margin-top: 4px; line-height: 1.4; }
          .pill { border: 1px solid color-mix(in srgb, var(--secondary) 24%, transparent); border-radius: 999px; padding: 4px 8px; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 7%, transparent); white-space: nowrap; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
          .candidate { border: 1px solid color-mix(in srgb, var(--secondary) 18%, transparent); border-radius: 8px; padding: 8px; display: grid; gap: 7px; background: color-mix(in srgb, var(--secondary) 5%, transparent); }
          .preview { width: 100%; aspect-ratio: 16 / 10; object-fit: cover; border-radius: 6px; background: color-mix(in srgb, var(--secondary) 8%, transparent); }
          .file { width: 100%; aspect-ratio: 16 / 10; border-radius: 6px; display: grid; place-items: center; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 8%, transparent); font-weight: 700; }
          .path { color: var(--secondary); font-size: 10px; font-family: ui-monospace, "SF Mono", Menlo, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .badge { color: var(--accent); font-size: 11px; font-weight: 650; min-height: 14px; }
          button { appearance: none; border: 1px solid color-mix(in srgb, var(--accent) 36%, transparent); background: color-mix(in srgb, var(--accent) 10%, transparent); color: var(--accent); border-radius: 6px; padding: 5px 8px; font: inherit; font-size: 12px; cursor: pointer; }
          button:hover { background: color-mix(in srgb, var(--accent) 18%, transparent); }
        </style>
        <div class="wd-media-choice">
          <div class="head">
            <div>
              <div class="title">\(AgentMediaTaskChoiceWidgetBuilder.escape(title))</div>
              \(escapedNote)
            </div>
            <div class="pill">\(imagePaths.count) 张图</div>
          </div>
          <div class="grid">\(items)</div>
        </div>
        """
    }

    private static func itemHTML(path: String, index: Int, anchor: AnchorContext) -> String {
        let url = URL(fileURLWithPath: path)
        let preview: String
        if let dataURL = AgentMediaTaskChoiceWidgetBuilder.thumbnailDataURL(for: url, maxSide: 420, compression: 0.68) {
            preview = "<img class=\"preview\" src=\"\(dataURL)\" alt=\"\(AgentMediaTaskChoiceWidgetBuilder.escape(url.lastPathComponent))\">"
        } else {
            let ext = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
            preview = "<div class=\"file\">\(AgentMediaTaskChoiceWidgetBuilder.escape(ext))</div>"
        }
        return """
        <article class="candidate">
          \(preview)
          <div class="badge">候选 \(index + 1)</div>
          <div class="path">\(AgentMediaTaskChoiceWidgetBuilder.escape(url.lastPathComponent))</div>
          <div class="actions">
            \(selectButton(path: path, index: index, anchor: anchor))
            \(toolActionButton(label: "打开蒙版", action: "open_image_editor", path: path, index: index, anchor: anchor, extraLines: ["operation: inpaint"], actionKey: "open_choice_image_editor"))
            \(toolActionButton(label: "擦除区域", action: "open_image_editor", path: path, index: index, anchor: anchor, extraLines: ["operation: erase"], actionKey: "erase_choice_image"))
            \(toolActionButton(label: "放大图片", action: "upscale_image", path: path, index: index, anchor: anchor, actionKey: "upscale_choice_image"))
            \(toolActionButton(label: "生成视频", action: "generate_video_from_image", path: path, index: index, anchor: anchor, extraLines: ["kind: video_generation", "reference_image_path: \(path)"], actionKey: "video_from_choice_image"))
          </div>
        </article>
        """
    }

    private static func selectButton(path: String, index: Int, anchor: AnchorContext) -> String {
        guard let tool = recommendedTool(action: "select_image", anchor: anchor) else {
            return "<button onclick=\"sendPrompt(\(selectPrompt(path: path, index: index, anchor: anchor)))\">选这张继续</button>"
        }
        return AgentMediaTaskChoiceWidgetBuilder.toolActionButton(
            label: "选这张继续",
            tool: tool,
            arguments: recommendedArguments(action: "select_image", path: path, anchor: anchor, extraLines: []),
            note: selectPromptNote(path: path, index: index, anchor: anchor),
            actionKey: "select_choice_image"
        )
    }

    private static func selectPrompt(path: String, index: Int, anchor: AnchorContext) -> String {
        AgentMediaTaskChoiceWidgetBuilder.jsString(selectPromptNote(path: path, index: index, anchor: anchor))
    }

    private static func selectPromptNote(path: String, index: Int, anchor: AnchorContext) -> String {
        """
        \(selectInstruction(anchor: anchor))

        \(choiceBlock(action: "select_image", path: path, index: index, anchor: anchor))
        """
    }

    private static func selectInstruction(anchor: AnchorContext) -> String {
        if anchor.hasShotAnchor {
            return "我选择这张候选图片作为短剧分镜主图。请调用 short_drama_select_shot_artifact，并把下面的 image_path 作为 artifact_path，使用同一组 project_id / episode_id / shot_id；如果下面有 review_item_id，也要一并传入。完成后可基于这张图继续生成视频、重绘、擦除、放大或做连续性检查；如果下面有 review_item_id，后续媒体任务也必须继续携带。"
        }
        if anchor.hasAssetAnchor {
            return "我选择这张候选图片作为短剧人物/场景参考图。请调用 short_drama_attach_asset_reference_image，并把下面的 image_path 作为 image_path，使用同一组 project_id / asset_kind / asset_id。完成后可继续生成分镜或检查角色/场景一致性。"
        }
        return "我选择这张候选图片继续处理。请基于 image_path 分析图片，并根据上下文建议下一步：可以放大、蒙版编辑、擦除、重绘、加入短剧分镜或作为人物/场景参考图。"
    }

    private static func openEditorPrompt(path: String, index: Int, anchor: AnchorContext) -> String {
        AgentMediaTaskChoiceWidgetBuilder.jsString("""
        请打开这张候选图片的蒙版编辑器，方便我框选或涂抹要重绘/擦除的区域。请优先使用下面的 recommended_tool 和 recommended_arguments；如果带短剧分镜锚点，应使用短剧专用图片编辑工具以保留分镜和检查项流水。

        \(choiceBlock(action: "open_image_editor", path: path, index: index, anchor: anchor, extraLines: ["operation: inpaint"]))
        """)
    }

    private static func erasePrompt(path: String, index: Int, anchor: AnchorContext) -> String {
        AgentMediaTaskChoiceWidgetBuilder.jsString("""
        请打开这张候选图片的擦除蒙版编辑器，方便我框选或涂抹要移除的区域。请优先使用下面的 recommended_tool 和 recommended_arguments；如果带短剧分镜锚点，应使用短剧专用图片编辑工具以保留分镜和检查项流水。

        \(choiceBlock(action: "open_image_editor", path: path, index: index, anchor: anchor, extraLines: ["operation: erase"]))
        """)
    }

    private static func upscalePrompt(path: String, index: Int, anchor: AnchorContext) -> String {
        AgentMediaTaskChoiceWidgetBuilder.jsString("""
        请把这张候选图片提交到 Replicate 图片放大任务。请优先使用下面的 recommended_tool 和 recommended_arguments；如果带短剧分镜锚点，应使用短剧专用放大工具以保留分镜和检查项流水。

        \(choiceBlock(action: "upscale_image", path: path, index: index, anchor: anchor))
        """)
    }

    private static func videoPrompt(path: String, index: Int, anchor: AnchorContext) -> String {
        AgentMediaTaskChoiceWidgetBuilder.jsString("""
        请把这张候选图片作为首帧/参考图生成视频。默认使用 Seedance 2.0；如果用户指定可灵/Kling，请调用 generate_video_from_image 时加入 video_engine=kling。image_path 使用下面的路径，并根据上下文补充合适的视频运动提示词；如果下面有 review_item_id，也必须一并传入。

        \(choiceBlock(action: "generate_video_from_image", path: path, index: index, anchor: anchor, extraLines: [
            "kind: video_generation",
            "reference_image_path: \(path)"
        ]))
        """)
    }

    private static func toolActionButton(
        label: String,
        action: String,
        path: String,
        index: Int,
        anchor: AnchorContext,
        extraLines: [String] = [],
        actionKey: String
    ) -> String {
        let tool = recommendedTool(action: action, anchor: anchor) ?? action
        return AgentMediaTaskChoiceWidgetBuilder.toolActionButton(
            label: label,
            tool: tool,
            arguments: recommendedArguments(action: action, path: path, anchor: anchor, extraLines: extraLines),
            note: choiceBlock(action: action, path: path, index: index, anchor: anchor, extraLines: extraLines),
            actionKey: actionKey
        )
    }

    private static func choiceBlock(
        action: String,
        path: String,
        index: Int,
        anchor: AnchorContext,
        extraLines: [String] = []
    ) -> String {
        let recommendation = recommendedToolLines(action: action, path: path, anchor: anchor, extraLines: extraLines)
        let followUp = selectionFollowUpLines(action: action, path: path, anchor: anchor)
        let lines = [
            "<image-choice>",
            "action: \(action)",
            "index: \(index + 1)",
            "image_path: \(path)"
        ] + extraLines + anchor.lines + recommendation + followUp + [
            "</image-choice>"
        ]
        return lines.joined(separator: "\n")
    }

    private static func selectionFollowUpLines(action: String, path: String, anchor: AnchorContext) -> [String] {
        guard action == "select_image" else { return [] }
        if anchor.hasShotAnchor {
            var shotPairs: [(String, String)] = [("artifact_path", path)]
            appendShotAnchorPairs(anchor, to: &shotPairs)
            appendReviewPair(anchor, to: &shotPairs)
            var imagePairs: [(String, String)] = [("image_path", path)]
            appendShotAnchorPairs(anchor, to: &imagePairs)
            appendReviewPair(anchor, to: &imagePairs)
            var shotTaskPairs: [(String, String)] = []
            appendShotAnchorPairs(anchor, to: &shotTaskPairs)
            shotTaskPairs.append(("scope", "shot"))
            let artifactArguments = argumentString(shotPairs)
            let imageArguments = argumentString(imagePairs)
            var lines = [
                "post_select_open_shot_tasks_tool: short_drama_open_media_tasks",
                "post_select_open_shot_tasks_arguments: \(argumentString(shotTaskPairs))",
                "post_select_video_tool: generate_video_from_image",
                "post_select_video_arguments: \(imageArguments)",
                "post_select_edit_tool: short_drama_open_image_editor",
                "post_select_edit_arguments: \(artifactArguments), operation=inpaint",
                "post_select_erase_tool: short_drama_open_image_editor",
                "post_select_erase_arguments: \(artifactArguments), operation=erase",
                "post_select_upscale_tool: short_drama_upscale_shot_artifact",
                "post_select_upscale_arguments: \(artifactArguments)"
            ]
            if let reviewItemID = anchor.reviewItemID, !reviewItemID.isEmpty {
                var reviewPairs: [(String, String)] = []
                appendShotAnchorPairs(anchor, to: &reviewPairs)
                reviewPairs.append(("item_id", reviewItemID))
                var reviewTaskPairs: [(String, String)] = []
                appendShotAnchorPairs(anchor, to: &reviewTaskPairs)
                reviewTaskPairs.append(("scope", "review_item"))
                reviewTaskPairs.append(("review_item_id", reviewItemID))
                lines.append("post_select_open_review_tasks_tool: short_drama_open_media_tasks")
                lines.append("post_select_open_review_tasks_arguments: \(argumentString(reviewTaskPairs))")
                lines.append("post_select_resolve_review_tool: short_drama_resolve_review_item")
                lines.append("post_select_resolve_review_arguments: \(argumentString(reviewPairs))")
            }
            return lines
        }
        guard anchor.hasAssetAnchor else { return [] }
        var attachPairs: [(String, String)] = [("image_path", path)]
        appendAssetAnchorPairs(anchor, to: &attachPairs)
        appendReviewPair(anchor, to: &attachPairs)
        var taskPairs: [(String, String)] = []
        appendAssetAnchorPairs(anchor, to: &taskPairs)
        taskPairs.append(("scope", "asset"))
        var relatedShotPairs: [(String, String)] = []
        appendAssetAnchorPairs(anchor, to: &relatedShotPairs)
        relatedShotPairs.append(("kind", "image_generation"))
        relatedShotPairs.append(("dry_run", "true"))
        let imageArguments = recommendedArguments(
            action: "open_image_editor",
            path: path,
            anchor: anchor,
            extraLines: []
        )
        let eraseArguments = recommendedArguments(
            action: "open_image_editor",
            path: path,
            anchor: anchor,
            extraLines: ["operation: erase"]
        )
        let upscaleArguments = recommendedArguments(
            action: "upscale_image",
            path: path,
            anchor: anchor,
            extraLines: []
        )
        return [
            "post_select_attach_reference_tool: short_drama_attach_asset_reference_image",
            "post_select_attach_reference_arguments: \(argumentString(attachPairs))",
            "post_select_open_asset_tasks_tool: short_drama_open_media_tasks",
            "post_select_open_asset_tasks_arguments: \(argumentString(taskPairs))",
            "post_select_generate_related_shots_tool: short_drama_generate_batch_media",
            "post_select_generate_related_shots_arguments: \(argumentString(relatedShotPairs))",
            "post_select_edit_tool: open_image_editor",
            "post_select_edit_arguments: \(imageArguments), operation=inpaint",
            "post_select_erase_tool: open_image_editor",
            "post_select_erase_arguments: \(eraseArguments)",
            "post_select_upscale_tool: upscale_image",
            "post_select_upscale_arguments: \(upscaleArguments)"
        ]
    }

    private static func recommendedToolLines(action: String, path: String, anchor: AnchorContext, extraLines: [String]) -> [String] {
        guard let tool = recommendedTool(action: action, anchor: anchor) else { return [] }
        return [
            "recommended_tool: \(tool)",
            "recommended_arguments: \(recommendedArguments(action: action, path: path, anchor: anchor, extraLines: extraLines))"
        ]
    }

    private static func recommendedTool(action: String, anchor: AnchorContext) -> String? {
        switch action {
        case "select_image":
            if anchor.hasShotAnchor { return "short_drama_select_shot_artifact" }
            if anchor.hasAssetAnchor { return "short_drama_attach_asset_reference_image" }
            return nil
        case "open_image_editor":
            if anchor.hasShotAnchor { return "short_drama_open_image_editor" }
            return "open_image_editor"
        case "upscale_image":
            if anchor.hasShotAnchor { return "short_drama_upscale_shot_artifact" }
            return "upscale_image"
        case "generate_video_from_image":
            return "generate_video_from_image"
        default:
            return nil
        }
    }

    private static func recommendedArguments(action: String, path: String, anchor: AnchorContext, extraLines: [String]) -> String {
        let operation = extraLines.first(where: { $0.hasPrefix("operation:") })?
            .replacingOccurrences(of: "operation:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var pairs: [(String, String)] = []
        switch action {
        case "select_image":
            if anchor.hasShotAnchor {
                pairs.append(("artifact_path", path))
                appendShotAnchorPairs(anchor, to: &pairs)
            } else if anchor.hasAssetAnchor {
                pairs.append(("image_path", path))
                appendAssetAnchorPairs(anchor, to: &pairs)
            } else {
                pairs.append(("image_path", path))
            }
        case "open_image_editor":
            pairs.append((anchor.hasShotAnchor ? "artifact_path" : "image_path", path))
            if let operation {
                pairs.append(("operation", operation))
            }
            appendOptionalAnchorPairs(anchor, to: &pairs)
        case "upscale_image":
            pairs.append((anchor.hasShotAnchor ? "artifact_path" : "image_path", path))
            appendOptionalAnchorPairs(anchor, to: &pairs)
        case "generate_video_from_image":
            pairs.append(("image_path", path))
            appendShotAnchorPairs(anchor, to: &pairs)
        default:
            pairs.append(("image_path", path))
            appendOptionalAnchorPairs(anchor, to: &pairs)
        }
        if let reviewItemID = anchor.reviewItemID, !reviewItemID.isEmpty, !pairs.contains(where: { $0.0 == "review_item_id" }) {
            pairs.append(("review_item_id", reviewItemID))
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private static func appendOptionalAnchorPairs(_ anchor: AnchorContext, to pairs: inout [(String, String)]) {
        appendShotAnchorPairs(anchor, to: &pairs)
        appendAssetAnchorPairs(anchor, to: &pairs)
    }

    private static func appendShotAnchorPairs(_ anchor: AnchorContext, to pairs: inout [(String, String)]) {
        if let projectID = anchor.projectID, !projectID.isEmpty {
            pairs.append(("project_id", projectID))
        }
        if let episodeID = anchor.episodeID, !episodeID.isEmpty {
            pairs.append(("episode_id", episodeID))
        }
        if let shotID = anchor.shotID, !shotID.isEmpty {
            pairs.append(("shot_id", shotID))
        }
    }

    private static func appendReviewPair(_ anchor: AnchorContext, to pairs: inout [(String, String)]) {
        if let reviewItemID = anchor.reviewItemID, !reviewItemID.isEmpty, !pairs.contains(where: { $0.0 == "review_item_id" }) {
            pairs.append(("review_item_id", reviewItemID))
        }
    }

    private static func argumentString(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private static func appendAssetAnchorPairs(_ anchor: AnchorContext, to pairs: inout [(String, String)]) {
        if let projectID = anchor.projectID, !projectID.isEmpty, !pairs.contains(where: { $0.0 == "project_id" }) {
            pairs.append(("project_id", projectID))
        }
        if let assetKind = anchor.assetKind, !assetKind.isEmpty {
            pairs.append(("asset_kind", assetKind))
        }
        if let assetID = anchor.assetID, !assetID.isEmpty {
            pairs.append(("asset_id", assetID))
        }
    }

}
