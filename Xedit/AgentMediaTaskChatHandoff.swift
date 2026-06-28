//
//  AgentMediaTaskChatHandoff.swift
//  WillDeep
//
//  Shared chat handoff helpers for media tasks surfaced in side panels and the
//  task monitor rail.
//

import Foundation

@MainActor
enum AgentMediaTaskChatHandoff {
    static func appendTaskContext(task: AgentMediaTask, appState: AppState) {
        var lines: [String] = [
            "请基于这个媒体任务继续处理：",
            "任务：\(task.title)",
            "任务句柄：\(task.displayHandle)",
            "状态：\(task.status.displayName)",
            "Provider：\(task.provider.displayName)",
            "类型：\(task.kind.displayName)"
        ]
        lines.append(contentsOf: taskTimeLines(task))
        if let model = clean(task.model) {
            lines.append("模型：\(model)")
        }
        if let remoteTaskID = clean(task.remoteTaskID) {
            lines.append("远端任务 ID：\(remoteTaskID)")
        }
        if let statusURL = clean(task.statusURL) {
            lines.append("状态 URL：\(statusURL)")
        }
        if let cancelURL = clean(task.cancelURL) {
            lines.append("取消 URL：\(cancelURL)")
        }
        if let statusEndpointSuffix = clean(task.statusEndpointSuffix) {
            lines.append("状态 endpoint suffix：\(statusEndpointSuffix)")
        }
        if let cancelEndpointSuffix = clean(task.cancelEndpointSuffix) {
            lines.append("取消 endpoint suffix：\(cancelEndpointSuffix)")
        }
        if let anchor = appState.agentShortDramaStore.anchor(for: task) {
            lines.append("短剧锚点：\(anchor.displayLabel)")
        }
        if let prompt = clean(task.prompt) {
            lines.append("Prompt：\(prompt)")
        }
        if let statusMessage = clean(task.statusMessage) {
            lines.append("状态信息：\(statusMessage)")
        }
        if let sourceImagePath = clean(task.sourceImagePath) {
            lines.append("源图路径：\(sourceImagePath)")
        }
        if let maskPath = clean(task.maskPath) {
            lines.append("蒙版路径：\(maskPath)")
        }
        if let reviewItemID = clean(task.reviewItemID) {
            lines.append("检查项 ID：\(reviewItemID)")
            lines.append(contentsOf: mediaTaskReviewActionLines(task: task, reviewItemID: reviewItemID))
        }
        if task.isActive {
            lines.append(contentsOf: mediaTaskActiveActionLines(task: task))
        }
        if let sourceImagePath = clean(task.sourceImagePath),
           let maskPath = clean(task.maskPath),
           isImageEditTask(task) {
            lines.append(contentsOf: mediaTaskReopenEditorLines(task: task, sourceImagePath: sourceImagePath, maskPath: maskPath))
        }
        if task.status == .failed || task.status == .canceled {
            lines.append(contentsOf: mediaTaskFailureActionLines(task: task))
        }
        if isRetryableShortDramaTask(task) {
            lines.append(contentsOf: mediaTaskRetryActionLines(task: task))
        }
        if !task.artifacts.isEmpty {
            lines.append("产物路径：")
            lines.append(contentsOf: task.artifacts.map { "- \($0.filePath)" })
            lines.append(contentsOf: completedArtifactActionLines(task: task))
        }
        append(lines.joined(separator: "\n"), task: task, appState: appState)
    }

    static func appendRetryContext(task: AgentMediaTask, appState: AppState) {
        var lines = [
            "请重试这个短剧媒体任务。请调用 short_drama_retry_media_task，并传入 task_id=\(task.displayHandle)。"
        ]
        lines.append(contentsOf: mediaTaskRetryActionLines(task: task))
        append(lines.joined(separator: "\n"), task: task, appState: appState)
    }

    static func hasCompletedImageArtifact(_ task: AgentMediaTask) -> Bool {
        task.status == .succeeded && task.artifacts.contains(where: isImageArtifact)
    }

    static func hasCompletedVideoArtifact(_ task: AgentMediaTask) -> Bool {
        task.status == .succeeded && task.artifacts.contains(where: isVideoArtifact)
    }

    static func completedImageScopeSummaryLine(task: AgentMediaTask) -> String? {
        guard task.status == .succeeded,
              let imagePath = task.artifacts.first(where: isImageArtifact)?.filePath else {
            return nil
        }
        let projectID = clean(task.projectID) ?? clean(task.projectPath)
        let episodeID = clean(task.episodeID)
        let shotID = clean(task.shotID)
        let assetKind = clean(task.assetKind)
        let assetID = clean(task.assetID)
        let reviewItemID = clean(task.reviewItemID)
        let imagePaths = task.artifacts.filter(isImageArtifact).map(\.filePath)
        var parts = [
            "- \(task.displayHandle)",
            "kind=\(task.kind.rawValue)",
            "title=\(task.title)",
            "image_path=\(imagePath)"
        ]
        parts.append(contentsOf: taskTimeParts(task))
        if let projectID, let episodeID, let shotID {
            let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
            let artifactArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(imagePath)\(reviewSuffix)"
            let imageArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), image_path=\(imagePath)\(reviewSuffix)"
            if imagePaths.count > 1 {
                parts.append("image_choice_tool=short_drama_show_image_choice_widget")
                parts.append("image_choice_arguments=project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)")
            }
            parts.append("select_primary_tool=short_drama_select_shot_artifact")
            parts.append("select_primary_arguments=\(artifactArguments)")
            parts.append("video_from_image_tool=generate_video_from_image")
            parts.append("video_from_image_arguments=\(imageArguments)")
            parts.append("edit_tool=short_drama_open_image_editor")
            parts.append("edit_arguments=\(artifactArguments), operation=inpaint")
            parts.append("erase_tool=short_drama_open_image_editor")
            parts.append("erase_arguments=\(artifactArguments), operation=erase")
            parts.append("upscale_tool=short_drama_upscale_shot_artifact")
            parts.append("upscale_arguments=\(artifactArguments)")
            if let reviewItemID {
                parts.append("resolve_review_tool=short_drama_resolve_review_item")
                parts.append("resolve_review_arguments=project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
            }
        } else {
            var imageArguments = "image_path=\(imagePath)"
            if let projectID { imageArguments += ", project_id=\(projectID)" }
            if let assetKind { imageArguments += ", asset_kind=\(assetKind)" }
            if let assetID { imageArguments += ", asset_id=\(assetID)" }
            if let reviewItemID { imageArguments += ", review_item_id=\(reviewItemID)" }
            if let projectID, let assetKind, let assetID {
                let assetArguments = "project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=\(imagePath)"
                let assetTaskArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
                let generateAssetArguments = "project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)"
                parts.append("open_asset_tasks_tool=short_drama_open_media_tasks")
                parts.append("open_asset_tasks_arguments=\(assetTaskArguments)")
                parts.append("refresh_asset_tasks_tool=short_drama_refresh_media_tasks")
                parts.append("refresh_asset_tasks_arguments=\(assetTaskArguments)")
                parts.append("generate_asset_reference_tool=short_drama_generate_asset_media")
                parts.append("generate_asset_reference_arguments=\(generateAssetArguments)")
                parts.append("attach_reference_tool=short_drama_attach_asset_reference_image")
                parts.append("attach_reference_arguments=\(assetArguments)")
            }
            if imagePaths.count > 1 {
                let joinedImagePaths = imagePaths.joined(separator: " | ")
                parts.append("image_choice_tool=show_image_choice_widget")
                parts.append("image_choice_arguments=image_paths=\(joinedImagePaths), \(imageArguments)")
            }
            parts.append("edit_tool=open_image_editor")
            parts.append("edit_arguments=\(imageArguments), operation=inpaint")
            parts.append("erase_tool=open_image_editor")
            parts.append("erase_arguments=\(imageArguments), operation=erase")
            parts.append("upscale_tool=upscale_image")
            parts.append("upscale_arguments=\(imageArguments)")
        }
        return parts.joined(separator: " · ")
    }

    static func completedVideoScopeSummaryLine(task: AgentMediaTask) -> String? {
        guard task.status == .succeeded,
              let videoPath = task.artifacts.first(where: isVideoArtifact)?.filePath else {
            return nil
        }
        let projectID = clean(task.projectID) ?? clean(task.projectPath)
        let episodeID = clean(task.episodeID)
        let shotID = clean(task.shotID)
        let assetKind = clean(task.assetKind)
        let assetID = clean(task.assetID)
        let reviewItemID = clean(task.reviewItemID)
        var parts = [
            "- \(task.displayHandle)",
            "kind=\(task.kind.rawValue)",
            "title=\(task.title)",
            "video_path=\(videoPath)",
            "video_action=continue_from_completed_video_artifact"
        ]
        parts.append(contentsOf: taskTimeParts(task))
        if let projectID, let episodeID, let shotID {
            let shotArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot"
            parts.append("open_shot_tasks_tool=short_drama_open_media_tasks")
            parts.append("open_shot_tasks_arguments=\(shotArguments)")
            parts.append("refresh_shot_tasks_tool=short_drama_refresh_media_tasks")
            parts.append("refresh_shot_tasks_arguments=\(shotArguments)")
            parts.append("storyboard_widget_tool=short_drama_show_storyboard_widget")
            parts.append("storyboard_widget_arguments=project_id=\(projectID), episode_id=\(episodeID)")
            if let reviewItemID {
                let reviewArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=review_item, review_item_id=\(reviewItemID)"
                parts.append("open_review_tasks_tool=short_drama_open_media_tasks")
                parts.append("open_review_tasks_arguments=\(reviewArguments)")
                parts.append("resolve_review_tool=short_drama_resolve_review_item")
                parts.append("resolve_review_arguments=project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
            }
        } else if let projectID, let assetKind, let assetID {
            let assetArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
            parts.append("open_asset_tasks_tool=short_drama_open_media_tasks")
            parts.append("open_asset_tasks_arguments=\(assetArguments)")
            parts.append("refresh_asset_tasks_tool=short_drama_refresh_media_tasks")
            parts.append("refresh_asset_tasks_arguments=\(assetArguments)")
        } else if let projectID {
            parts.append("open_project_tasks_tool=short_drama_open_media_tasks")
            parts.append("open_project_tasks_arguments=project_id=\(projectID), scope=project")
            parts.append("refresh_project_tasks_tool=short_drama_refresh_media_tasks")
            parts.append("refresh_project_tasks_arguments=project_id=\(projectID), scope=project")
        }
        return parts.joined(separator: " · ")
    }

    static func activeTaskScopeSummaryLine(task: AgentMediaTask) -> String? {
        guard task.isActive else { return nil }
        var parts = [
            "- \(task.displayHandle)",
            "status=\(task.status.rawValue)",
            "provider=\(task.provider.rawValue)",
            "kind=\(task.kind.rawValue)",
            "title=\(task.title)"
        ]
        parts.append(contentsOf: taskTimeParts(task))
        if let remoteTaskID = clean(task.remoteTaskID) {
            parts.append("remote_task_id=\(remoteTaskID)")
        }
        if let statusURL = clean(task.statusURL) {
            parts.append("status_url=\(statusURL)")
        }
        if let statusEndpointSuffix = clean(task.statusEndpointSuffix) {
            parts.append("status_endpoint_suffix=\(statusEndpointSuffix)")
        }
        switch task.provider {
        case .replicate:
            parts.append("poll_tool=replicate_poll_prediction")
            parts.append("poll_arguments=task_id=\(task.displayHandle)")
            parts.append("cancel_tool=replicate_cancel_prediction")
            parts.append("cancel_arguments=task_id=\(task.displayHandle)")
        case .someIM:
            parts.append("poll_tool=some_im_poll_media_task")
            parts.append("poll_arguments=task_id=\(task.displayHandle)")
            parts.append("cancel_tool=some_im_cancel_media_task")
            parts.append("cancel_arguments=task_id=\(task.displayHandle)")
        case .skill, .local, .unknown:
            if AgentGenericMediaStatusClient.canPoll(task) {
                parts.append("generic_poll_tool=short_drama_refresh_media_tasks")
                parts.append("generic_poll_arguments=\(mediaTaskScopeArguments(task: task))")
                parts.append("generic_poll_note=https_status_url_will_be_polled_by_scope_refresh")
            } else {
                parts.append("poll_note=use_refresh_scope_tool_or_external_callback")
            }
            if AgentGenericMediaStatusClient.canCancel(task) {
                parts.append("generic_cancel_note=cancel_url_available_in_media_task_side_panel")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func staleActiveTaskScopeSummaryLine(task: AgentMediaTask) -> String? {
        guard task.isStaleActive() else { return nil }
        var parts = [
            "- \(task.displayHandle)",
            "status=\(task.status.rawValue)",
            "provider=\(task.provider.rawValue)",
            "kind=\(task.kind.rawValue)",
            "title=\(task.title)",
            "stale_active=true",
            "stale_minutes=\(task.staleActiveMinutes())",
            "open_tasks_tool=short_drama_open_media_tasks",
            "open_tasks_arguments=\(mediaTaskScopeArguments(task: task))",
            "refresh_scope_tool=short_drama_refresh_media_tasks",
            "refresh_scope_arguments=\(mediaTaskScopeArguments(task: task))"
        ]
        parts.append(contentsOf: taskTimeParts(task))
        if let statusURL = clean(task.statusURL) {
            parts.append("status_url=\(statusURL)")
        }
        if let cancelURL = clean(task.cancelURL) {
            parts.append("cancel_url=\(cancelURL)")
        }
        switch task.provider {
        case .replicate:
            parts.append("poll_tool=replicate_poll_prediction")
            parts.append("poll_arguments=task_id=\(task.displayHandle)")
        case .someIM:
            parts.append("poll_tool=some_im_poll_media_task")
            parts.append("poll_arguments=task_id=\(task.displayHandle)")
        case .skill, .local, .unknown:
            if AgentGenericMediaStatusClient.canPoll(task) {
                parts.append("generic_poll_tool=short_drama_refresh_media_tasks")
                parts.append("generic_poll_arguments=\(mediaTaskScopeArguments(task: task))")
            } else {
                parts.append("external_callback_note=wait_for_external_import_or_manual_update")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func failedTaskScopeSummaryLine(task: AgentMediaTask) -> String? {
        guard task.status == .failed || task.status == .canceled else { return nil }
        var parts = [
            "- \(task.displayHandle)",
            "status=\(task.status.rawValue)",
            "provider=\(task.provider.rawValue)",
            "kind=\(task.kind.rawValue)",
            "title=\(task.title)",
            "open_tasks_tool=short_drama_open_media_tasks",
            "open_tasks_arguments=\(mediaTaskScopeArguments(task: task))"
        ]
        parts.append(contentsOf: taskTimeParts(task))
        if let message = clean(task.statusMessage) {
            parts.append("status_message=\(message)")
        }
        if isRetryableShortDramaTask(task) {
            parts.append("retry_tool=short_drama_retry_media_task")
            parts.append("retry_arguments=task_id=\(task.displayHandle)")
            parts.append("retry_failed_scope_tool=short_drama_retry_failed_media_tasks")
            parts.append("retry_failed_scope_dry_run_arguments=\(mediaTaskScopeArguments(task: task)), dry_run=true")
        } else if isManifestScriptFailure(task) {
            parts.append("script_recovery_note=rerun ruby-media-script-template.rb with WILLDEEP_MEDIA_ONLY_FAILED=1 or read production-gap-report.json before requeueing missing media")
        } else {
            parts.append("manual_recovery_note=inspect status_message and provider metadata before resubmitting")
        }
        return parts.joined(separator: " · ")
    }

    private static func mediaTaskActiveActionLines(task: AgentMediaTask) -> [String] {
        let scopeArguments = mediaTaskScopeArguments(task: task)
        var lines = [
            "",
            "<media-task-active-actions>",
            "action: continue_active_media_task",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "status: \(task.status.rawValue)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "open_tasks_tool: short_drama_open_media_tasks",
            "open_tasks_arguments: \(scopeArguments)",
            "refresh_scope_tool: short_drama_refresh_media_tasks",
            "refresh_scope_arguments: \(scopeArguments)"
        ]
        lines.append(contentsOf: taskTimeBlockLines(task))
        if task.isStaleActive() {
            lines.append("stale_active: true")
            lines.append("stale_minutes: \(task.staleActiveMinutes())")
            lines.append("stale_follow_up: 这个任务运行中但超过 30 分钟未更新；优先刷新同一范围，若仍无变化再询问用户是否取消、重试或等待外部回导。")
        }
        if let remoteTaskID = clean(task.remoteTaskID) {
            lines.append("remote_task_id: \(remoteTaskID)")
        }
        if let statusURL = clean(task.statusURL) {
            lines.append("status_url: \(statusURL)")
        }
        if let cancelURL = clean(task.cancelURL) {
            lines.append("cancel_url: \(cancelURL)")
        }
        if let statusEndpointSuffix = clean(task.statusEndpointSuffix) {
            lines.append("status_endpoint_suffix: \(statusEndpointSuffix)")
        }
        if let cancelEndpointSuffix = clean(task.cancelEndpointSuffix) {
            lines.append("cancel_endpoint_suffix: \(cancelEndpointSuffix)")
        }
        switch task.provider {
        case .replicate:
            lines.append("poll_tool: replicate_poll_prediction")
            lines.append("poll_arguments: task_id=\(task.displayHandle)")
            lines.append("cancel_tool: replicate_cancel_prediction")
            lines.append("cancel_arguments: task_id=\(task.displayHandle)")
        case .someIM:
            lines.append("poll_tool: some_im_poll_media_task")
            lines.append("poll_arguments: task_id=\(task.displayHandle)")
            lines.append("cancel_tool: some_im_cancel_media_task")
            lines.append("cancel_arguments: task_id=\(task.displayHandle)")
        case .skill, .local, .unknown:
            if AgentGenericMediaStatusClient.canPoll(task) {
                lines.append("generic_poll_tool: short_drama_refresh_media_tasks")
                lines.append("generic_poll_arguments: \(scopeArguments)")
                lines.append("generic_poll_note: 这个任务带 HTTPS status_url；调用 generic_poll_tool 刷新同一范围会由任务中心轮询并下载完成产物。")
            } else {
                lines.append("poll_note: 这个任务请优先用 refresh_scope_tool 刷新；若来源不支持远程轮询，聊天应说明需要等待外部回导或手动更新。")
            }
            if AgentGenericMediaStatusClient.canCancel(task) {
                lines.append("generic_cancel_note: 这个任务带 HTTPS cancel_url；如用户要求取消，请打开媒体任务侧栏使用取消按钮，避免聊天里泄露或误调用第三方地址。")
            }
        }
        lines.append("</media-task-active-actions>")
        return lines
    }

    private static func mediaTaskReviewActionLines(task: AgentMediaTask, reviewItemID: String) -> [String] {
        guard let projectID = clean(task.projectID) ?? clean(task.projectPath),
              let shotID = clean(task.shotID) else {
            return []
        }
        let episodeID = clean(task.episodeID)
        var argumentPairs = [
            "project_id=\(projectID)",
            "shot_id=\(shotID)"
        ]
        if let episodeID {
            argumentPairs.insert("episode_id=\(episodeID)", at: 1)
        }
        let baseArguments = argumentPairs.joined(separator: ", ")
        return [
            "",
            "<short-drama-media-task-review-actions>",
            "action: review_item_follow_up",
            "project_id: \(projectID)",
            episodeID.map { "episode_id: \($0)" },
            "shot_id: \(shotID)",
            "review_item_id: \(reviewItemID)",
            "open_review_tasks_tool: short_drama_open_media_tasks",
            "open_review_tasks_arguments: \(baseArguments), scope=review_item, review_item_id=\(reviewItemID)",
            "resolve_review_tool: short_drama_resolve_review_item",
            "resolve_review_arguments: \(baseArguments), item_id=\(reviewItemID)",
            "</short-drama-media-task-review-actions>"
        ].compactMap { $0 }
    }

    private static func mediaTaskReopenEditorLines(task: AgentMediaTask, sourceImagePath: String, maskPath: String) -> [String] {
        let operation = task.kind == .imageErase ? "erase" : "inpaint"
        let projectID = clean(task.projectID) ?? clean(task.projectPath)
        let episodeID = clean(task.episodeID)
        let shotID = clean(task.shotID)
        let assetKind = clean(task.assetKind)
        let assetID = clean(task.assetID)
        let reviewItemID = clean(task.reviewItemID)
        var lines = [
            "",
            "<image-edit-reopen-action>",
            "action: reopen_image_editor_with_seed_mask",
            "source_image_path: \(sourceImagePath)",
            "mask_path: \(maskPath)",
            "operation: \(operation)"
        ]
        if let projectID { lines.append("project_id: \(projectID)") }
        if let episodeID { lines.append("episode_id: \(episodeID)") }
        if let shotID { lines.append("shot_id: \(shotID)") }
        if let assetKind { lines.append("asset_kind: \(assetKind)") }
        if let assetID { lines.append("asset_id: \(assetID)") }
        if let reviewItemID { lines.append("review_item_id: \(reviewItemID)") }
        if let projectID, let episodeID, let shotID {
            var arguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
            if let reviewItemID {
                arguments += ", review_item_id=\(reviewItemID)"
            }
            lines.append("reopen_editor_tool: short_drama_open_image_editor")
            lines.append("reopen_editor_arguments: \(arguments)")
        } else {
            var arguments = "image_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
            if let projectID { arguments += ", project_id=\(projectID)" }
            if let assetKind { arguments += ", asset_kind=\(assetKind)" }
            if let assetID { arguments += ", asset_id=\(assetID)" }
            if let reviewItemID { arguments += ", review_item_id=\(reviewItemID)" }
            lines.append("reopen_editor_tool: open_image_editor")
            lines.append("reopen_editor_arguments: \(arguments)")
        }
        lines.append("</image-edit-reopen-action>")
        return lines
    }

    private static func mediaTaskRetryActionLines(task: AgentMediaTask) -> [String] {
        var lines: [String] = [
            "",
            "<short-drama-media-task-retry>",
            "action: retry_media_task",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "status: \(task.status.rawValue)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "retry_tool: short_drama_retry_media_task",
            "retry_arguments: task_id=\(task.displayHandle)"
        ]
        if let projectID = clean(task.projectID) ?? clean(task.projectPath) {
            lines.append("project_id: \(projectID)")
        }
        if let episodeID = clean(task.episodeID) {
            lines.append("episode_id: \(episodeID)")
        }
        if let shotID = clean(task.shotID) {
            lines.append("shot_id: \(shotID)")
        }
        if let assetKind = clean(task.assetKind) {
            lines.append("asset_kind: \(assetKind)")
        }
        if let assetID = clean(task.assetID) {
            lines.append("asset_id: \(assetID)")
        }
        if let model = clean(task.model) {
            lines.append("model: \(model)")
        }
        if let endpoint = clean(task.statusEndpointSuffix) ?? clean(task.cancelEndpointSuffix) {
            lines.append("endpoint_suffix: \(endpoint)")
        }
        if let sourceImagePath = clean(task.sourceImagePath) {
            lines.append("source_image_path: \(sourceImagePath)")
        }
        if let maskPath = clean(task.maskPath) {
            lines.append("mask_path: \(maskPath)")
        }
        if let reviewItemID = clean(task.reviewItemID) {
            lines.append("review_item_id: \(reviewItemID)")
        }
        lines.append("</short-drama-media-task-retry>")
        return lines
    }

    private static func mediaTaskFailureActionLines(task: AgentMediaTask) -> [String] {
        let scopeArguments = mediaTaskScopeArguments(task: task)
        var lines: [String] = [
            "",
            "<media-task-failure-actions>",
            "action: recover_failed_media_task",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "status: \(task.status.rawValue)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "open_tasks_tool: short_drama_open_media_tasks",
            "open_tasks_arguments: \(scopeArguments)",
            "refresh_scope_tool: short_drama_refresh_media_tasks",
            "refresh_scope_arguments: \(scopeArguments)"
        ]
        lines.append(contentsOf: taskTimeBlockLines(task))
        if let message = clean(task.statusMessage) {
            lines.append("status_message: \(message)")
        }
        if isRetryableShortDramaTask(task) {
            lines.append("retry_tool: short_drama_retry_media_task")
            lines.append("retry_arguments: task_id=\(task.displayHandle)")
            lines.append("retry_failed_scope_tool: short_drama_retry_failed_media_tasks")
            lines.append("retry_failed_scope_dry_run_arguments: \(scopeArguments), dry_run=true")
        } else if isManifestScriptFailure(task) {
            lines.append("script_recovery_note: 这是制作包 manifest/Ruby/Skill 外部脚本失败项；请先查看 status_message，再重新运行 ruby-media-script-template.rb 或读取 production-gap-report.json 重新排产。")
            lines.append("gap_report_follow_up: 若这个任务仍缺主图/视频，请从同一制作包的 production-gap-report.json 读取 batch_actions，并先 dry-run short_drama_generate_batch_media(target_filter=missing)。")
        } else {
            lines.append("manual_recovery_note: 当前 provider 缺少可自动重试的本地参数；请检查 status_message、源图/蒙版/远端任务信息，再决定重新提交或等待外部回导。")
        }
        lines.append("</media-task-failure-actions>")
        return lines
    }

    private static func completedArtifactActionLines(task: AgentMediaTask) -> [String] {
        guard task.status == .succeeded else {
            return []
        }
        var result: [String] = []
        let projectID = clean(task.projectID) ?? clean(task.projectPath)
        let episodeID = clean(task.episodeID)
        let shotID = clean(task.shotID)
        let assetKind = clean(task.assetKind)
        let assetID = clean(task.assetID)
        let reviewItemID = clean(task.reviewItemID)

        if let imagePath = task.artifacts.first(where: isImageArtifact)?.filePath {
            result.append(contentsOf: completedImageArtifactActionLines(
                task: task,
                imagePath: imagePath,
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID,
                assetKind: assetKind,
                assetID: assetID,
                reviewItemID: reviewItemID
            ))
        }
        if let videoPath = task.artifacts.first(where: isVideoArtifact)?.filePath {
            result.append(contentsOf: completedVideoArtifactActionLines(
                task: task,
                videoPath: videoPath,
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID,
                assetKind: assetKind,
                assetID: assetID,
                reviewItemID: reviewItemID
            ))
        }
        return result
    }

    private static func completedImageArtifactActionLines(
        task: AgentMediaTask,
        imagePath: String,
        projectID: String?,
        episodeID: String?,
        shotID: String?,
        assetKind: String?,
        assetID: String?,
        reviewItemID: String?
    ) -> [String] {
        var lines: [String] = [
            "",
            "<media-task-completed-artifact-actions>",
            "action: continue_from_completed_media_artifact",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "artifact_count: \(task.artifacts.count)",
            "image_path: \(imagePath)"
        ]
        lines.append(contentsOf: taskTimeBlockLines(task))
        if let projectID { lines.append("project_id: \(projectID)") }
        if let episodeID { lines.append("episode_id: \(episodeID)") }
        if let shotID { lines.append("shot_id: \(shotID)") }
        if let assetKind { lines.append("asset_kind: \(assetKind)") }
        if let assetID { lines.append("asset_id: \(assetID)") }
        if let reviewItemID { lines.append("review_item_id: \(reviewItemID)") }

        if task.artifacts.filter(isImageArtifact).count > 1, let projectID, let episodeID, let shotID {
            let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
            let choiceArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)"
            lines.append("image_choice_tool: short_drama_show_image_choice_widget")
            lines.append("image_choice_arguments: \(choiceArguments)")
        }
        if let projectID, let episodeID, let shotID {
            let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
            let artifactArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(imagePath)\(reviewSuffix)"
            let imageArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), image_path=\(imagePath)\(reviewSuffix)"
            lines.append("select_primary_tool: short_drama_select_shot_artifact")
            lines.append("select_primary_arguments: \(artifactArguments)")
            lines.append("video_from_image_tool: generate_video_from_image")
            lines.append("video_from_image_arguments: \(imageArguments)")
            lines.append("edit_tool: short_drama_open_image_editor")
            lines.append("edit_arguments: \(artifactArguments), operation=inpaint")
            lines.append("erase_tool: short_drama_open_image_editor")
            lines.append("erase_arguments: \(artifactArguments), operation=erase")
            lines.append("upscale_tool: short_drama_upscale_shot_artifact")
            lines.append("upscale_arguments: \(artifactArguments)")
            if let reviewItemID {
                lines.append("resolve_review_tool: short_drama_resolve_review_item")
                lines.append("resolve_review_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
            }
        } else {
            var imageArguments = "image_path=\(imagePath)"
            if let projectID { imageArguments += ", project_id=\(projectID)" }
            if let assetKind { imageArguments += ", asset_kind=\(assetKind)" }
            if let assetID { imageArguments += ", asset_id=\(assetID)" }
            if let reviewItemID { imageArguments += ", review_item_id=\(reviewItemID)" }
            if let projectID, let assetKind, let assetID {
                let assetArguments = "project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=\(imagePath)"
                let assetTaskArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
                let generateAssetArguments = "project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)"
                lines.append("open_asset_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_asset_tasks_arguments: \(assetTaskArguments)")
                lines.append("refresh_asset_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_asset_tasks_arguments: \(assetTaskArguments)")
                lines.append("generate_asset_reference_tool: short_drama_generate_asset_media")
                lines.append("generate_asset_reference_arguments: \(generateAssetArguments)")
                lines.append("attach_reference_tool: short_drama_attach_asset_reference_image")
                lines.append("attach_reference_arguments: \(assetArguments)")
            }
            lines.append("edit_tool: open_image_editor")
            lines.append("edit_arguments: \(imageArguments), operation=inpaint")
            lines.append("erase_tool: open_image_editor")
            lines.append("erase_arguments: \(imageArguments), operation=erase")
            lines.append("upscale_tool: upscale_image")
            lines.append("upscale_arguments: \(imageArguments)")
        }
        lines.append("</media-task-completed-artifact-actions>")
        return lines
    }

    private static func completedVideoArtifactActionLines(
        task: AgentMediaTask,
        videoPath: String,
        projectID: String?,
        episodeID: String?,
        shotID: String?,
        assetKind: String?,
        assetID: String?,
        reviewItemID: String?
    ) -> [String] {
        var lines: [String] = [
            "",
            "<media-task-completed-video-actions>",
            "action: continue_from_completed_video_artifact",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "artifact_count: \(task.artifacts.count)",
            "video_path: \(videoPath)"
        ]
        lines.append(contentsOf: taskTimeBlockLines(task))
        if let projectID { lines.append("project_id: \(projectID)") }
        if let episodeID { lines.append("episode_id: \(episodeID)") }
        if let shotID { lines.append("shot_id: \(shotID)") }
        if let assetKind { lines.append("asset_kind: \(assetKind)") }
        if let assetID { lines.append("asset_id: \(assetID)") }
        if let reviewItemID { lines.append("review_item_id: \(reviewItemID)") }

        if let projectID, let episodeID, let shotID {
            let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
            let shotTaskArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot\(reviewSuffix)"
            lines.append("open_shot_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_shot_tasks_arguments: \(shotTaskArguments)")
            lines.append("refresh_shot_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_shot_tasks_arguments: \(shotTaskArguments)")
            lines.append("storyboard_widget_tool: short_drama_show_storyboard_widget")
            lines.append("storyboard_widget_arguments: project_id=\(projectID), episode_id=\(episodeID)")
            if let reviewItemID {
                let reviewArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=review_item, review_item_id=\(reviewItemID)"
                lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_review_tasks_arguments: \(reviewArguments)")
                lines.append("resolve_review_tool: short_drama_resolve_review_item")
                lines.append("resolve_review_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
            }
        } else if let projectID, let assetKind, let assetID {
            let assetTaskArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
            lines.append("open_asset_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_asset_tasks_arguments: \(assetTaskArguments)")
            lines.append("refresh_asset_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_asset_tasks_arguments: \(assetTaskArguments)")
        } else if let projectID {
            lines.append("open_project_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_project_tasks_arguments: project_id=\(projectID), scope=project")
            lines.append("refresh_project_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_project_tasks_arguments: project_id=\(projectID), scope=project")
        }
        lines.append("</media-task-completed-video-actions>")
        return lines
    }

    private static func mediaTaskScopeArguments(task: AgentMediaTask) -> String {
        var pairs: [String] = []
        if let projectID = clean(task.projectID) ?? clean(task.projectPath) {
            pairs.append("project_id=\(projectID)")
        }
        if let episodeID = clean(task.episodeID) {
            pairs.append("episode_id=\(episodeID)")
        }
        if let shotID = clean(task.shotID) {
            pairs.append("shot_id=\(shotID)")
        }
        if let reviewItemID = clean(task.reviewItemID) {
            pairs.append("scope=review_item")
            pairs.append("review_item_id=\(reviewItemID)")
        } else if let assetKind = clean(task.assetKind), let assetID = clean(task.assetID) {
            pairs.append("scope=asset")
            pairs.append("asset_kind=\(assetKind)")
            pairs.append("asset_id=\(assetID)")
        } else if clean(task.shotID) != nil {
            pairs.append("scope=shot")
        } else if clean(task.episodeID) != nil {
            pairs.append("scope=episode")
        } else {
            pairs.append("scope=project")
        }
        if pairs.isEmpty {
            pairs.append("scope=all")
        }
        return pairs.joined(separator: ", ")
    }

    private static func isImageArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }
        let pathExtension = URL(fileURLWithPath: artifact.filePath).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(pathExtension)
    }

    private static func isVideoArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("video/") {
            return true
        }
        let pathExtension = URL(fileURLWithPath: artifact.filePath).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(pathExtension)
    }

    private static func append(_ prompt: String, task: AgentMediaTask, appState: AppState) {
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains(task.displayHandle) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func taskTimeLines(_ task: AgentMediaTask) -> [String] {
        var lines = [
            "创建时间：\(isoTimestamp(task.createdAt))",
            "更新时间：\(isoTimestamp(task.updatedAt))"
        ]
        if let finishedAt = task.finishedAt {
            lines.append("完成时间：\(isoTimestamp(finishedAt))")
        }
        return lines
    }

    private static func taskTimeParts(_ task: AgentMediaTask) -> [String] {
        var parts = [
            "created_at=\(isoTimestamp(task.createdAt))",
            "updated_at=\(isoTimestamp(task.updatedAt))"
        ]
        if let finishedAt = task.finishedAt {
            parts.append("finished_at=\(isoTimestamp(finishedAt))")
        }
        return parts
    }

    private static func taskTimeBlockLines(_ task: AgentMediaTask) -> [String] {
        var lines = [
            "created_at: \(isoTimestamp(task.createdAt))",
            "updated_at: \(isoTimestamp(task.updatedAt))"
        ]
        if let finishedAt = task.finishedAt {
            lines.append("finished_at: \(isoTimestamp(finishedAt))")
        }
        return lines
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func isImageEditTask(_ task: AgentMediaTask) -> Bool {
        task.kind == .imageEdit || task.kind == .imageInpaint || task.kind == .imageErase
    }

    private static func isManifestScriptFailure(_ task: AgentMediaTask) -> Bool {
        guard task.status == .failed || task.status == .canceled else { return false }
        guard let message = clean(task.statusMessage) else { return false }
        return message.contains("Manifest 外部脚本失败")
            || message.lowercased().contains("last_error")
            || task.provider == .skill
    }

    static func isRetryableShortDramaTask(_ task: AgentMediaTask) -> Bool {
        guard task.status == .failed || task.status == .canceled else { return false }
        guard task.projectID != nil || task.projectPath != nil else { return false }
        if task.provider == .replicate {
            let hasShotAnchor = task.episodeID != nil && task.shotID != nil
            let hasAssetAnchor = task.assetKind != nil && task.assetID != nil
            guard hasShotAnchor || hasAssetAnchor else { return false }
            if task.kind == .imageUpscale {
                return clean(task.sourceImagePath) != nil
            }
            if task.kind == .imageErase || task.kind == .imageInpaint || task.kind == .imageEdit {
                return clean(task.sourceImagePath) != nil && clean(task.maskPath) != nil
            }
            return false
        }
        guard task.provider == .someIM else { return false }
        if task.kind == .imageErase || task.kind == .imageInpaint || task.kind == .imageEdit {
            let hasShotAnchor = task.episodeID != nil && task.shotID != nil
            let hasAssetAnchor = task.assetKind != nil && task.assetID != nil
            return (hasShotAnchor || hasAssetAnchor)
                && clean(task.sourceImagePath) != nil
                && clean(task.maskPath) != nil
        }
        if task.assetKind != nil, task.assetID != nil, task.kind == .imageGeneration {
            return true
        }
        guard task.episodeID != nil, task.shotID != nil else { return false }
        return task.kind == .imageGeneration || task.kind == .videoGeneration
    }
}
