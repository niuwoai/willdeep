import Foundation

enum AgentShortDramaProductionGapAction {
    case missingImages
    case missingVideos
    case openReviews
}

extension AgentShortDramaPanel {
    func reviewQueueLines(project: AgentShortDramaProject, episodes: [AgentShortDramaEpisode], limit: Int) -> [String] {
        var lines: [String] = []
        for episode in episodes.sorted(by: { $0.order < $1.order }) {
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                for item in shot.reviewItems where item.status != .resolved {
                    lines.append(
                        "review_queue_item: episode_id=\(episode.id.uuidString), episode_title=\(episode.title), shot_id=\(shot.id.uuidString), shot_title=\(shot.title), review_item_id=\(item.id.uuidString), kind=\(item.kind.rawValue), severity=\(item.severity.rawValue), title=\(item.title)"
                    )
                    if lines.count >= limit { return lines }
                }
            }
        }
        return lines
    }

    func mediaGapQueueLines(episodes: [AgentShortDramaEpisode], limit: Int) -> [String] {
        var lines: [String] = []
        for episode in episodes.sorted(by: { $0.order < $1.order }) {
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                let hasSelectedImage = shot.selectedArtifactPath.map(isImagePath) ?? false
                if !hasSelectedImage {
                    lines.append("missing_image_shot: episode_id=\(episode.id.uuidString), episode_title=\(episode.title), shot_id=\(shot.id.uuidString), shot_title=\(shot.title), status=\(shot.status.rawValue)")
                }
                if !shot.artifactPaths.contains(where: isVideoPath) {
                    lines.append("missing_video_shot: episode_id=\(episode.id.uuidString), episode_title=\(episode.title), shot_id=\(shot.id.uuidString), shot_title=\(shot.title), status=\(shot.status.rawValue)")
                }
                if lines.count >= limit { return lines }
            }
        }
        return lines
    }

    func mediaTaskQueueLines(tasks: [AgentMediaTask], limit: Int) -> [String] {
        let prioritized = tasks
            .filter { $0.isActive || $0.needsAttention }
            .sorted { lhs, rhs in
                if lhs.needsAttention != rhs.needsAttention {
                    return lhs.needsAttention && !rhs.needsAttention
                }
                return lhs.createdAt < rhs.createdAt
            }
        return prioritized.prefix(limit).map { task in
            var parts = [
                "media_task_queue_item: task_id=\(task.displayHandle)",
                "provider=\(task.provider.rawValue)",
                "kind=\(task.kind.rawValue)",
                "status=\(task.status.rawValue)",
                "title=\(task.title)"
            ]
            if let episodeID = clean(task.episodeID) { parts.append("episode_id=\(episodeID)") }
            if let shotID = clean(task.shotID) { parts.append("shot_id=\(shotID)") }
            if let assetKind = clean(task.assetKind), let assetID = clean(task.assetID) {
                parts.append("asset_kind=\(assetKind)")
                parts.append("asset_id=\(assetID)")
            }
            if let reviewItemID = clean(task.reviewItemID) { parts.append("review_item_id=\(reviewItemID)") }
            return parts.joined(separator: ", ")
        }
    }

    func missingAssetReferenceQueueLines(project: AgentShortDramaProject, limit: Int) -> [String] {
        missingReferenceAssets(project).prefix(limit).map { asset in
            let assetLabel = asset.assetKind == "scene" ? "场景" : "人物"
            return "missing_asset_reference_item: asset_kind=\(asset.assetKind), asset_label=\(assetLabel), asset_id=\(asset.id.uuidString), asset_name=\(asset.name), generate_asset_reference_dry_run_arguments=project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString), dry_run=true, generate_asset_reference_arguments=project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString), dry_run=false"
        }
    }

    func appendProjectContextToChat(_ project: AgentShortDramaProject) {
        let summary = projectStructureSummary(project)
        let projectTasks = mediaTasks(project: project)
        let taskSummary = projectTasks.reduce(into: [String: Int]()) { counts, task in
            counts[task.status.rawValue, default: 0] += 1
        }
        var lines: [String] = [
            "<short-drama-project-context>",
            "action: inspect_short_drama_project_from_side_panel",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_count: \(summary.episodeCount)",
            "shot_count: \(summary.shotCount)",
            "character_count: \(summary.characterCount)",
            "scene_count: \(summary.sceneCount)",
            "open_review_count: \(summary.openReviewCount)",
            "selected_image_count: \(summary.selectedImageCount)",
            "video_count: \(summary.videoCount)",
            "missing_image_count: \(summary.missingImageCount)",
            "missing_video_count: \(summary.missingVideoCount)",
            "missing_asset_reference_count: \(missingAssetReferenceCount(project))",
            "active_media_task_count: \(projectTasks.filter(\.isActive).count)",
            "failed_media_task_count: \(projectTasks.filter(\.needsAttention).count)",
            "storyboard_widget_tool: short_drama_show_storyboard_widget",
            "storyboard_widget_arguments: project_id=\(project.id.uuidString)",
            "open_project_tasks_tool: short_drama_open_media_tasks",
            "open_project_tasks_arguments: project_id=\(project.id.uuidString), scope=project",
            "batch_image_dry_run_tool: short_drama_generate_batch_media",
            "batch_image_dry_run_arguments: project_id=\(project.id.uuidString), kind=image_generation, dry_run=true",
            "batch_video_dry_run_tool: short_drama_generate_batch_media",
            "batch_video_dry_run_arguments: project_id=\(project.id.uuidString), kind=video_generation, dry_run=true",
            "missing_image_batch_dry_run_tool: short_drama_generate_batch_media",
            "missing_image_batch_dry_run_arguments: project_id=\(project.id.uuidString), kind=image_generation, target_filter=missing, dry_run=true",
            "missing_image_batch_submit_tool: short_drama_generate_batch_media",
            "missing_image_batch_submit_arguments: project_id=\(project.id.uuidString), kind=image_generation, target_filter=missing, dry_run=false",
            "missing_video_batch_dry_run_tool: short_drama_generate_batch_media",
            "missing_video_batch_dry_run_arguments: project_id=\(project.id.uuidString), kind=video_generation, target_filter=missing, dry_run=true",
            "missing_video_batch_submit_tool: short_drama_generate_batch_media",
            "missing_video_batch_submit_arguments: project_id=\(project.id.uuidString), kind=video_generation, target_filter=missing, dry_run=false",
            "export_package_tool: short_drama_export_production_package",
            "export_package_arguments: project_id=\(project.id.uuidString)",
            "delete_structure_tool: short_drama_delete_structure_item",
            "delete_structure_note: 需要清理误导入的集、分镜、人物或场景时，先传 dry_run=true 预检影响范围。",
            "reorder_episodes_tool: short_drama_reorder_structure_items",
            "reorder_episodes_dry_run_arguments: project_id=\(project.id.uuidString), item_type=episode, ordered_ids=[按目标顺序填 episode_id], dry_run=true",
            "batch_status_tool: short_drama_update_shot_statuses",
            "batch_status_dry_run_arguments: project_id=\(project.id.uuidString), status=planned, dry_run=true",
            "batch_links_tool: short_drama_update_shot_links",
            "batch_links_dry_run_arguments: project_id=\(project.id.uuidString), scene_id=[场景 id], character_ids=[人物 id], dry_run=true"
        ]
        if let logline = clean(project.logline) { lines.append("logline: \(logline)") }
        appendMediaTaskSummary(taskSummary, to: &lines)
        appendProductionNextActions(
            lines: &lines,
            projectID: project.id.uuidString,
            episodeID: nil,
            failedTaskCount: projectTasks.filter(\.needsAttention).count,
            openReviewCount: summary.openReviewCount,
            missingImageCount: summary.missingImageCount,
            missingVideoCount: summary.missingVideoCount,
            missingAssetReferenceCount: missingAssetReferenceCount(project)
        )
        let mediaTaskQueue = mediaTaskQueueLines(tasks: projectTasks, limit: 12)
        if !mediaTaskQueue.isEmpty {
            lines.append("media_task_queue_tool: short_drama_open_media_tasks")
            lines.append("media_task_queue_arguments: project_id=\(project.id.uuidString), scope=project")
            lines.append("refresh_media_task_queue_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_media_task_queue_arguments: project_id=\(project.id.uuidString), scope=project")
            lines.append("retry_failed_media_task_queue_tool: short_drama_retry_failed_media_tasks")
            lines.append("retry_failed_media_task_queue_dry_run_arguments: project_id=\(project.id.uuidString), scope=project, dry_run=true")
            lines.append(contentsOf: mediaTaskQueue)
        }
        lines.append(contentsOf: project.episodes.prefix(8).map { "episode: order=\($0.order), id=\($0.id.uuidString), title=\($0.title), shot_count=\($0.shots.count)" })
        if !project.characters.isEmpty { lines.append("characters: \(project.characters.prefix(8).map(\.name).joined(separator: ", "))") }
        if !project.scenes.isEmpty { lines.append("scenes: \(project.scenes.prefix(8).map(\.name).joined(separator: ", "))") }
        let missingAssetReferences = missingAssetReferenceQueueLines(project: project, limit: 12)
        if !missingAssetReferences.isEmpty {
            lines.append("missing_asset_reference_queue_tool: short_drama_generate_asset_media")
            lines.append("missing_asset_reference_batch_note: 可逐条调用 generate_asset_reference_arguments；若要全量补齐，也可从侧栏点击补齐缺失的人物/场景参考图。")
            lines.append(contentsOf: missingAssetReferences)
        }
        let mediaGapQueue = mediaGapQueueLines(episodes: project.episodes, limit: 16)
        if !mediaGapQueue.isEmpty {
            lines.append("media_gap_queue_tool: short_drama_generate_batch_media")
            lines.append("media_gap_image_dry_run_arguments: project_id=\(project.id.uuidString), kind=image_generation, target_filter=missing, dry_run=true")
            lines.append("media_gap_video_dry_run_arguments: project_id=\(project.id.uuidString), kind=video_generation, target_filter=missing, dry_run=true")
            lines.append(contentsOf: mediaGapQueue)
        }
        let reviewQueue = reviewQueueLines(project: project, episodes: project.episodes, limit: 12)
        if !reviewQueue.isEmpty {
            lines.append("review_queue_tool: short_drama_open_media_tasks")
            lines.append("review_queue_arguments: project_id=\(project.id.uuidString), scope=project")
            lines.append(contentsOf: reviewQueue)
        }
        lines.append("follow_up: 请结合短剧项目结构、媒体任务侧栏和网页组件，决定下一步是补图、图生视频、生成分镜板、导出制作包还是处理检查项。")
        lines.append("</short-drama-project-context>")
        appendPrompt(lines: lines, duplicateGuard: "project_id: \(project.id.uuidString)", status: "已把短剧项目结构发送到聊天输入框。")
    }

    func appendEpisodeContextToChat(project: AgentShortDramaProject, episode: AgentShortDramaEpisode) {
        let summary = episodeStructureSummary(episode)
        let episodeTasks = mediaTasks(project: project, episode: episode)
        let taskSummary = episodeTasks.reduce(into: [String: Int]()) { counts, task in
            counts[task.status.rawValue, default: 0] += 1
        }
        var lines: [String] = [
            "<short-drama-episode-context>",
            "action: inspect_short_drama_episode_from_side_panel",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_count: \(summary.shotCount)",
            "open_review_count: \(summary.openReviewCount)",
            "selected_image_count: \(summary.selectedImageCount)",
            "video_count: \(summary.videoCount)",
            "missing_image_count: \(summary.missingImageCount)",
            "missing_video_count: \(summary.missingVideoCount)",
            "active_media_task_count: \(episodeTasks.filter(\.isActive).count)",
            "failed_media_task_count: \(episodeTasks.filter(\.needsAttention).count)",
            "episode_storyboard_widget_tool: short_drama_show_storyboard_widget",
            "episode_storyboard_widget_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString)",
            "open_episode_tasks_tool: short_drama_open_media_tasks",
            "open_episode_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), scope=episode",
            "batch_episode_image_dry_run_tool: short_drama_generate_batch_media",
            "batch_episode_image_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=image_generation, dry_run=true",
            "batch_episode_video_dry_run_tool: short_drama_generate_batch_media",
            "batch_episode_video_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=video_generation, dry_run=true",
            "missing_episode_image_batch_dry_run_tool: short_drama_generate_batch_media",
            "missing_episode_image_batch_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=image_generation, target_filter=missing, dry_run=true",
            "missing_episode_image_batch_submit_tool: short_drama_generate_batch_media",
            "missing_episode_image_batch_submit_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=image_generation, target_filter=missing, dry_run=false",
            "missing_episode_video_batch_dry_run_tool: short_drama_generate_batch_media",
            "missing_episode_video_batch_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=video_generation, target_filter=missing, dry_run=true",
            "missing_episode_video_batch_submit_tool: short_drama_generate_batch_media",
            "missing_episode_video_batch_submit_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=video_generation, target_filter=missing, dry_run=false",
            "export_episode_package_tool: short_drama_export_production_package",
            "export_episode_package_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString)",
            "delete_episode_dry_run_tool: short_drama_delete_structure_item",
            "delete_episode_dry_run_arguments: project_id=\(project.id.uuidString), item_type=episode, episode_id=\(episode.id.uuidString), dry_run=true",
            "reorder_shots_tool: short_drama_reorder_structure_items",
            "reorder_shots_dry_run_arguments: project_id=\(project.id.uuidString), item_type=shot, episode_id=\(episode.id.uuidString), ordered_ids=[按目标顺序填 shot_id], dry_run=true",
            "batch_episode_status_tool: short_drama_update_shot_statuses",
            "batch_episode_status_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), status=planned, dry_run=true",
            "batch_episode_links_tool: short_drama_update_shot_links",
            "batch_episode_links_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), scene_id=[场景 id], character_ids=[人物 id], dry_run=true"
        ]
        if let summaryText = clean(episode.summary) { lines.append("episode_summary: \(summaryText)") }
        appendMediaTaskSummary(taskSummary, to: &lines)
        appendProductionNextActions(
            lines: &lines,
            projectID: project.id.uuidString,
            episodeID: episode.id.uuidString,
            failedTaskCount: episodeTasks.filter(\.needsAttention).count,
            openReviewCount: summary.openReviewCount,
            missingImageCount: summary.missingImageCount,
            missingVideoCount: summary.missingVideoCount,
            missingAssetReferenceCount: 0
        )
        let mediaTaskQueue = mediaTaskQueueLines(tasks: episodeTasks, limit: 10)
        if !mediaTaskQueue.isEmpty {
            lines.append("media_task_queue_tool: short_drama_open_media_tasks")
            lines.append("media_task_queue_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), scope=episode")
            lines.append("refresh_media_task_queue_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_media_task_queue_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), scope=episode")
            lines.append("retry_failed_media_task_queue_tool: short_drama_retry_failed_media_tasks")
            lines.append("retry_failed_media_task_queue_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), scope=episode, dry_run=true")
            lines.append(contentsOf: mediaTaskQueue)
        }
        lines.append(contentsOf: episode.shots.prefix(12).map { shot in
            let hasImage = shot.selectedArtifactPath.map(isImagePath) ?? false
            let hasVideo = shot.artifactPaths.contains(where: isVideoPath)
            let openReviewCount = shot.reviewItems.filter { $0.status != .resolved }.count
            return "shot: order=\(shot.order), id=\(shot.id.uuidString), title=\(shot.title), status=\(shot.status.rawValue), has_selected_image=\(hasImage), has_video=\(hasVideo), open_review_count=\(openReviewCount)"
        })
        appendQueues(project: project, episodes: [episode], to: &lines, episodeID: episode.id.uuidString)
        lines.append("follow_up: 请只围绕这一集推进，优先判断缺主图、缺视频、失败任务和未解决检查项，再决定补图、图生视频、生成本集分镜板、导出本集制作包或处理具体分镜。")
        lines.append("</short-drama-episode-context>")
        appendPrompt(lines: lines, duplicateGuard: "episode_id: \(episode.id.uuidString)", status: "已把本集结构发送到聊天输入框。")
    }

    func appendProductionGapActionToChat(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode?,
        action: AgentShortDramaProductionGapAction
    ) {
        let episodes = episode.map { [$0] } ?? project.episodes
        let missingImageCount: Int
        let missingVideoCount: Int
        let openReviewCount: Int
        if let episode {
            let summary = episodeStructureSummary(episode)
            missingImageCount = summary.missingImageCount
            missingVideoCount = summary.missingVideoCount
            openReviewCount = summary.openReviewCount
        } else {
            let summary = projectStructureSummary(project)
            missingImageCount = summary.missingImageCount
            missingVideoCount = summary.missingVideoCount
            openReviewCount = summary.openReviewCount
        }
        let scopeLabel = episode.map { "第 \($0.order) 集：\($0.title)" } ?? "项目：\(project.title)"
        let scopeArguments = episode.map {
            "project_id=\(project.id.uuidString), episode_id=\($0.id.uuidString), scope=episode"
        } ?? "project_id=\(project.id.uuidString), scope=project"
        let batchArguments = episode.map {
            "project_id=\(project.id.uuidString), episode_id=\($0.id.uuidString)"
        } ?? "project_id=\(project.id.uuidString)"
        var lines: [String] = [
            "<short-drama-production-gap-action>",
            "action: \(productionGapActionName(action))",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "scope_label: \(scopeLabel)",
            "scope_arguments: \(scopeArguments)",
            "missing_image_count: \(missingImageCount)",
            "missing_video_count: \(missingVideoCount)",
            "open_review_count: \(openReviewCount)",
            "open_tasks_tool: short_drama_open_media_tasks",
            "open_tasks_arguments: \(scopeArguments)",
            "refresh_tasks_tool: short_drama_refresh_media_tasks",
            "refresh_tasks_arguments: \(scopeArguments)"
        ]
        if let episode {
            lines.append("episode_id: \(episode.id.uuidString)")
            lines.append("episode_title: \(episode.title)")
        }

        switch action {
        case .missingImages:
            lines.append("recommended_tool: short_drama_generate_batch_media")
            lines.append("dry_run_arguments: \(batchArguments), kind=image_generation, target_filter=missing, dry_run=true")
            lines.append("submit_arguments: \(batchArguments), kind=image_generation, target_filter=missing, dry_run=false")
            lines.append(contentsOf: mediaGapQueueLines(episodes: episodes, limit: 16).filter { $0.hasPrefix("missing_image_shot:") })
            lines.append("follow_up: 请先用 dry_run_arguments 预检缺主图范围；确认后再用 submit_arguments 正式提交，并打开媒体任务侧栏。")
        case .missingVideos:
            lines.append("recommended_tool: short_drama_generate_batch_media")
            lines.append("dry_run_arguments: \(batchArguments), kind=video_generation, target_filter=missing, dry_run=true")
            lines.append("submit_arguments: \(batchArguments), kind=video_generation, target_filter=missing, dry_run=false")
            lines.append(contentsOf: mediaGapQueueLines(episodes: episodes, limit: 16).filter { $0.hasPrefix("missing_video_shot:") })
            lines.append("follow_up: 请先用 dry_run_arguments 预检缺视频范围；正式提交时优先复用每条分镜主图作为首帧参考，并打开媒体任务侧栏。")
        case .openReviews:
            lines.append("recommended_tool: short_drama_open_media_tasks")
            lines.append("recommended_arguments: \(scopeArguments)")
            lines.append("resolve_tool: short_drama_resolve_review_item")
            lines.append(contentsOf: reviewQueueLines(project: project, episodes: episodes, limit: 16))
            lines.append("follow_up: 请逐条处理未解决检查项；重绘、擦除、放大、补拍任务必须保留 review_item_id，确认修复后再关闭检查项。")
        }
        lines.append("</short-drama-production-gap-action>")

        let duplicateGuard = "action: \(productionGapActionName(action))\nproject_id: \(project.id.uuidString)"
        appendPrompt(
            lines: lines,
            duplicateGuard: duplicateGuard,
            status: "已把\(productionGapActionLabel(action))动作发送到聊天输入框。"
        )
    }

    private func appendProductionNextActions(
        lines: inout [String],
        projectID: String,
        episodeID: String?,
        failedTaskCount: Int,
        openReviewCount: Int,
        missingImageCount: Int,
        missingVideoCount: Int,
        missingAssetReferenceCount: Int
    ) {
        var actions: [String] = []
        let baseArguments = episodeID.map { "project_id=\(projectID), episode_id=\($0)" } ?? "project_id=\(projectID)"
        if failedTaskCount > 0 {
            actions.append("action=retry_failed_media_tasks, priority=1, count=\(failedTaskCount), tool=short_drama_retry_failed_media_tasks, dry_run_arguments=\(baseArguments), scope=\(episodeID == nil ? "project" : "episode"), dry_run=true")
        }
        if openReviewCount > 0 {
            actions.append("action=review_open_items, priority=2, count=\(openReviewCount), tool=short_drama_open_media_tasks, arguments=\(baseArguments), scope=\(episodeID == nil ? "project" : "episode")")
        }
        if missingImageCount > 0 {
            actions.append("action=generate_missing_images, priority=3, count=\(missingImageCount), tool=short_drama_generate_batch_media, dry_run_arguments=\(baseArguments), kind=image_generation, target_filter=missing, dry_run=true")
        }
        if missingVideoCount > 0 {
            actions.append("action=generate_missing_videos, priority=4, count=\(missingVideoCount), tool=short_drama_generate_batch_media, dry_run_arguments=\(baseArguments), kind=video_generation, target_filter=missing, dry_run=true")
        }
        if missingAssetReferenceCount > 0 {
            actions.append("action=generate_missing_asset_references, priority=5, count=\(missingAssetReferenceCount), tool=short_drama_generate_asset_media, note=use_missing_asset_reference_queue_items")
        }
        if actions.isEmpty {
            actions.append("action=export_or_storyboard_review, priority=1, count=0, storyboard_tool=short_drama_show_storyboard_widget, export_tool=short_drama_export_production_package, arguments=\(baseArguments)")
        }
        lines.append("production_next_action_count: \(actions.count)")
        for (index, action) in actions.enumerated() {
            lines.append("production_next_action_\(index + 1): \(action)")
        }
    }

    func appendShotContextToChat(project: AgentShortDramaProject, episode: AgentShortDramaEpisode, shot: AgentShortDramaShot) {
        let shotTasks = mediaTasks(project: project, episode: episode, shot: shot)
        let taskSummary = shotTasks.reduce(into: [String: Int]()) { counts, task in
            counts[task.status.rawValue, default: 0] += 1
        }
        let selectedImagePath = shot.selectedArtifactPath.flatMap { isImagePath($0) ? $0 : nil }
        let videoPaths = shot.artifactPaths.filter(isVideoPath)
        let imagePaths = shot.artifactPaths.filter(isImagePath)
        let sceneName = shot.sceneID.flatMap { sceneID in project.scenes.first { $0.id == sceneID }?.name }
        let characterNames = shot.characterIDs.compactMap { characterID in project.characters.first { $0.id == characterID }?.name }
        let openReviewItems = shot.reviewItems.filter { $0.status != .resolved }
        var lines: [String] = [
            "<short-drama-shot-context>",
            "action: inspect_short_drama_shot_from_side_panel",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_order: \(shot.order)",
            "shot_title: \(shot.title)",
            "shot_status: \(shot.status.rawValue)",
            "artifact_count: \(shot.artifactPaths.count)",
            "image_count: \(imagePaths.count)",
            "video_count: \(videoPaths.count)",
            "has_selected_image: \(selectedImagePath != nil)",
            "open_review_count: \(openReviewItems.count)",
            "active_media_task_count: \(shotTasks.filter(\.isActive).count)",
            "failed_media_task_count: \(shotTasks.filter(\.needsAttention).count)",
            "open_shot_tasks_tool: short_drama_open_media_tasks",
            "open_shot_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=shot",
            "generate_shot_image_tool: short_drama_generate_shot_media",
            "generate_shot_image_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), kind=image_generation, dry_run=true",
            "generate_shot_image_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), kind=image_generation, dry_run=false",
            "generate_shot_video_tool: short_drama_generate_shot_media",
            "generate_shot_video_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), kind=video_generation, dry_run=true",
            "generate_shot_video_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), kind=video_generation, dry_run=false",
            "image_choice_widget_tool: short_drama_show_image_choice_widget",
            "image_choice_widget_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString)",
            "duplicate_shot_tool: short_drama_duplicate_shot",
            "duplicate_shot_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), source_shot_id=\(shot.id.uuidString), copy_artifacts=false",
            "move_shot_tool: short_drama_move_shot",
            "move_shot_arguments: project_id=\(project.id.uuidString), source_episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), target_episode_id=[目标 episode_id]",
            "update_shot_links_tool: short_drama_update_shot_links",
            "update_shot_links_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_ids=[\(shot.id.uuidString)], scene_id=[场景 id], character_ids=[人物 id], dry_run=true",
            "delete_shot_dry_run_tool: short_drama_delete_structure_item",
            "delete_shot_dry_run_arguments: project_id=\(project.id.uuidString), item_type=shot, episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), dry_run=true"
        ]
        if let summary = clean(shot.summary) { lines.append("shot_summary: \(summary)") }
        if let prompt = clean(shot.prompt) { lines.append("shot_prompt: \(prompt)") }
        if let sceneName { lines.append("scene: \(sceneName)") }
        if !characterNames.isEmpty { lines.append("characters: \(characterNames.joined(separator: ", "))") }
        if let selectedImagePath {
            lines.append("selected_image_path: \(selectedImagePath)")
            lines.append("video_from_selected_image_tool: generate_video_from_image")
            lines.append("video_from_selected_image_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), image_path=\(selectedImagePath)")
            lines.append("edit_selected_image_tool: short_drama_open_image_editor")
            lines.append("edit_selected_image_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), artifact_path=\(selectedImagePath), operation=inpaint")
            lines.append("erase_selected_image_tool: short_drama_open_image_editor")
            lines.append("erase_selected_image_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), artifact_path=\(selectedImagePath), operation=erase")
            lines.append("upscale_selected_image_tool: short_drama_upscale_shot_artifact")
            lines.append("upscale_selected_image_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), artifact_path=\(selectedImagePath)")
        }
        appendMediaTaskSummary(taskSummary, to: &lines)
        if !imagePaths.isEmpty { lines.append("image_paths: \(imagePaths.prefix(8).joined(separator: " | "))") }
        if !videoPaths.isEmpty { lines.append("video_paths: \(videoPaths.prefix(4).joined(separator: " | "))") }
        for item in openReviewItems.prefix(6) {
            lines.append("review_item: id=\(item.id.uuidString), kind=\(item.kind.rawValue), severity=\(item.severity.rawValue), title=\(item.title)")
        }
        lines.append("follow_up: 请只围绕这一条分镜推进；若缺主图先补图，已有主图可继续图生视频、蒙版重绘、擦除或放大，存在未解决检查项时优先按检查项修复并保留 review_item_id。")
        lines.append("</short-drama-shot-context>")
        appendPrompt(lines: lines, duplicateGuard: "shot_id: \(shot.id.uuidString)", status: "已把分镜结构发送到聊天输入框。")
    }

    func appendAssetContextToChat(project: AgentShortDramaProject, asset: ShortDramaAssetSummary) {
        let assetTasks = mediaTasks(project: project, asset: asset)
        let taskSummary = assetTasks.reduce(into: [String: Int]()) { counts, task in
            counts[task.status.rawValue, default: 0] += 1
        }
        let assetLabel = asset.assetKind == "scene" ? "场景" : "人物"
        let linkedShots = project.episodes.flatMap { episode in
            episode.shots.compactMap { shot -> String? in
                if asset.assetKind == "scene" {
                    guard shot.sceneID == asset.id else { return nil }
                } else {
                    guard shot.characterIDs.contains(asset.id) else { return nil }
                }
                return "episode_id=\(episode.id.uuidString), episode_title=\(episode.title), shot_id=\(shot.id.uuidString), shot_title=\(shot.title)"
            }
        }
        let linkedShotIDs = project.episodes.flatMap { episode in
            episode.shots.compactMap { shot -> String? in
                if asset.assetKind == "scene" {
                    guard shot.sceneID == asset.id else { return nil }
                } else {
                    guard shot.characterIDs.contains(asset.id) else { return nil }
                }
                return shot.id.uuidString
            }
        }
        let linkedShotIDArgument = linkedShotIDs.isEmpty ? "" : ", shot_ids=[\(linkedShotIDs.joined(separator: ","))]"
        let imageReferences = asset.referenceImagePaths.filter(isImagePath)
        var lines: [String] = [
            "<short-drama-asset-context>",
            "action: inspect_short_drama_asset_from_side_panel",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "asset_kind: \(asset.assetKind)",
            "asset_label: \(assetLabel)",
            "asset_id: \(asset.id.uuidString)",
            "asset_name: \(asset.name)",
            "reference_image_count: \(imageReferences.count)",
            "reference_artifact_count: \(asset.referenceImagePaths.count)",
            "linked_shot_count: \(linkedShots.count)",
            "active_media_task_count: \(assetTasks.filter(\.isActive).count)",
            "failed_media_task_count: \(assetTasks.filter(\.needsAttention).count)",
            "open_asset_tasks_tool: short_drama_open_media_tasks",
            "open_asset_tasks_arguments: project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString), scope=asset",
            "generate_asset_reference_tool: short_drama_generate_asset_media",
            "generate_asset_reference_dry_run_arguments: project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString), dry_run=true",
            "generate_asset_reference_arguments: project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString), dry_run=false",
            "apply_asset_to_shots_tool: short_drama_update_shot_links",
            "apply_asset_to_shots_dry_run_arguments: project_id=\(project.id.uuidString), \(asset.assetKind == "scene" ? "scene_id=\(asset.id.uuidString)" : "character_ids=[\(asset.id.uuidString)], append_character_ids=true"), shot_ids=[目标 shot_id], dry_run=true",
            "unlink_asset_from_shots_tool: short_drama_update_shot_links",
            "unlink_asset_from_shots_dry_run_arguments: project_id=\(project.id.uuidString), \(asset.assetKind == "scene" ? "clear_scene=true" : "remove_character_ids=[\(asset.id.uuidString)]"), shot_ids=[已关联 shot_id], dry_run=true",
            "generate_linked_shot_images_tool: short_drama_generate_batch_media",
            "generate_linked_shot_images_dry_run_arguments: project_id=\(project.id.uuidString)\(linkedShotIDArgument), kind=image_generation, target_filter=missing, dry_run=true",
            "generate_linked_shot_images_submit_arguments: project_id=\(project.id.uuidString)\(linkedShotIDArgument), kind=image_generation, target_filter=missing, dry_run=false",
            "generate_linked_shot_videos_tool: short_drama_generate_batch_media",
            "generate_linked_shot_videos_dry_run_arguments: project_id=\(project.id.uuidString)\(linkedShotIDArgument), kind=video_generation, target_filter=missing, dry_run=true",
            "generate_linked_shot_videos_submit_arguments: project_id=\(project.id.uuidString)\(linkedShotIDArgument), kind=video_generation, target_filter=missing, dry_run=false",
            "delete_asset_dry_run_tool: short_drama_delete_structure_item",
            "delete_asset_dry_run_arguments: project_id=\(project.id.uuidString), item_type=\(asset.assetKind), asset_id=\(asset.id.uuidString), dry_run=true"
        ]
        if let detail = clean(asset.detail) { lines.append("asset_detail: \(detail)") }
        if let firstReference = imageReferences.first {
            lines.append("primary_reference_image_path: \(firstReference)")
            lines.append("edit_reference_image_tool: open_image_editor")
            lines.append("edit_reference_image_arguments: image_path=\(firstReference), project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString), operation=inpaint")
            lines.append("erase_reference_image_tool: open_image_editor")
            lines.append("erase_reference_image_arguments: image_path=\(firstReference), project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString), operation=erase")
            lines.append("upscale_reference_image_tool: upscale_image")
            lines.append("upscale_reference_image_arguments: image_path=\(firstReference), project_id=\(project.id.uuidString), asset_kind=\(asset.assetKind), asset_id=\(asset.id.uuidString)")
        }
        appendMediaTaskSummary(taskSummary, to: &lines)
        if !imageReferences.isEmpty { lines.append("reference_image_paths: \(imageReferences.prefix(8).joined(separator: " | "))") }
        if !linkedShotIDs.isEmpty { lines.append("linked_shot_ids: \(linkedShotIDs.joined(separator: ","))") }
        lines.append(contentsOf: linkedShots.prefix(8).map { "linked_shot: \($0)" })
        lines.append("follow_up: 请只围绕这个\(assetLabel)资产推进；若缺参考图先生成参考图，已有参考图可继续蒙版重绘、擦除或放大，并确保后续分镜生成继续使用同一资产设定。")
        lines.append("</short-drama-asset-context>")
        appendPrompt(lines: lines, duplicateGuard: "asset_id: \(asset.id.uuidString)", status: "已把\(assetLabel)资产结构发送到聊天输入框。")
    }

    private func appendQueues(project: AgentShortDramaProject, episodes: [AgentShortDramaEpisode], to lines: inout [String], episodeID: String) {
        let reviewQueue = reviewQueueLines(project: project, episodes: episodes, limit: 8)
        if !reviewQueue.isEmpty {
            lines.append("review_queue_tool: short_drama_open_media_tasks")
            lines.append("review_queue_arguments: project_id=\(project.id.uuidString), episode_id=\(episodeID), scope=episode")
            lines.append(contentsOf: reviewQueue)
        }
        let mediaGapQueue = mediaGapQueueLines(episodes: episodes, limit: 12)
        if !mediaGapQueue.isEmpty {
            lines.append("media_gap_queue_tool: short_drama_generate_batch_media")
            lines.append("media_gap_image_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episodeID), kind=image_generation, target_filter=missing, dry_run=true")
            lines.append("media_gap_video_dry_run_arguments: project_id=\(project.id.uuidString), episode_id=\(episodeID), kind=video_generation, target_filter=missing, dry_run=true")
            lines.append(contentsOf: mediaGapQueue)
        }
    }

    private func appendMediaTaskSummary(_ taskSummary: [String: Int], to lines: inout [String]) {
        guard !taskSummary.isEmpty else { return }
        let compact = taskSummary
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        lines.append("media_task_status_counts: \(compact)")
    }

    private func productionGapActionName(_ action: AgentShortDramaProductionGapAction) -> String {
        switch action {
        case .missingImages: return "generate_missing_images_from_side_panel"
        case .missingVideos: return "generate_missing_videos_from_side_panel"
        case .openReviews: return "review_open_items_from_side_panel"
        }
    }

    private func productionGapActionLabel(_ action: AgentShortDramaProductionGapAction) -> String {
        switch action {
        case .missingImages: return "补主图"
        case .missingVideos: return "补视频"
        case .openReviews: return "审片"
        }
    }

    private func appendPrompt(lines: [String], duplicateGuard: String, status: String) {
        let prompt = lines.joined(separator: "\n")
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains(duplicateGuard) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
        statusMessage = status
    }
}
