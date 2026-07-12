//
//  AgentShortDramaStoryboardWidgetBuilder.swift
//  WillDeep
//
//  Sandboxed HTML widgets for short-drama storyboard review and image choice.
//

import AppKit
import Foundation

enum AgentShortDramaStoryboardWidgetBuilder {
    static func widget(for project: AgentShortDramaProject, mediaTasks: [AgentMediaTask] = []) -> AgentWidget {
        AgentWidget(title: "短剧分镜板", html: html(for: project, mediaTasks: mediaTasks))
    }

    static func widget(
        for project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        mediaTasks: [AgentMediaTask] = []
    ) -> AgentWidget {
        var scopedProject = project
        scopedProject.episodes = [episode]
        return AgentWidget(title: "短剧分镜板 · 第 \(episode.order) 集", html: html(for: scopedProject, mediaTasks: mediaTasks))
    }

    static func imageChoiceWidget(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        reviewItemID: String? = nil
    ) -> AgentWidget {
        AgentWidget(title: "分镜候选图选择", html: imageChoiceHTML(project: project, episode: episode, shot: shot, reviewItemID: reviewItemID))
    }

    private static func imageChoiceHTML(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        reviewItemID: String?
    ) -> String {
        let candidates = orderedArtifactPaths(for: shot)
        let items = candidates.enumerated().map { index, path in
            imageChoiceItemHTML(
                project: project,
                episode: episode,
                shot: shot,
                path: path,
                index: index,
                reviewItemID: reviewItemID
            )
        }.joined(separator: "\n")
        let empty = candidates.isEmpty ? "<div class=\"empty\">这个分镜还没有候选产物。</div>" : ""
        return """
        <style>
          .wd-choice { display: grid; gap: 12px; }
          .head { display: flex; justify-content: space-between; gap: 12px; align-items: flex-start; border-bottom: 1px solid color-mix(in srgb, var(--secondary) 22%, transparent); padding-bottom: 10px; }
          .title { font-size: 17px; font-weight: 750; line-height: 1.25; }
          .meta { color: var(--secondary); margin-top: 4px; line-height: 1.4; }
          .pill { border: 1px solid color-mix(in srgb, var(--secondary) 24%, transparent); border-radius: 999px; padding: 4px 8px; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 7%, transparent); white-space: nowrap; }
          .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
          .candidate { border: 1px solid color-mix(in srgb, var(--secondary) 18%, transparent); border-radius: 8px; padding: 8px; display: grid; gap: 7px; background: color-mix(in srgb, var(--secondary) 5%, transparent); }
          .candidate.selected { border-color: var(--accent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 22%, transparent); }
          .preview { width: 100%; aspect-ratio: 16 / 10; object-fit: cover; border-radius: 6px; background: color-mix(in srgb, var(--secondary) 8%, transparent); }
          .file { width: 100%; aspect-ratio: 16 / 10; border-radius: 6px; display: grid; place-items: center; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 8%, transparent); font-weight: 700; }
          .path { color: var(--secondary); font-size: 10px; font-family: ui-monospace, "SF Mono", Menlo, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .badge { color: var(--accent); font-size: 11px; font-weight: 650; min-height: 14px; }
          button { appearance: none; border: 1px solid color-mix(in srgb, var(--accent) 36%, transparent); background: color-mix(in srgb, var(--accent) 10%, transparent); color: var(--accent); border-radius: 6px; padding: 5px 8px; font: inherit; font-size: 12px; cursor: pointer; }
          button:hover { background: color-mix(in srgb, var(--accent) 18%, transparent); }
          .empty { color: var(--secondary); border: 1px dashed color-mix(in srgb, var(--secondary) 28%, transparent); border-radius: 8px; padding: 16px; text-align: center; }
        </style>
        <div class="wd-choice">
          <div class="head">
            <div>
              <div class="title">选择主图：\(escape(shot.title))</div>
              <div class="meta">\(escape(project.title)) · 第 \(episode.order) 集 · 第 \(shot.order) 镜</div>
            </div>
            <div class="pill">\(candidates.count) 个候选</div>
          </div>
          \(empty)
          <div class="grid">\(items)</div>
        </div>
        """
    }

    private static func imageChoiceItemHTML(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        path: String,
        index: Int,
        reviewItemID: String?
    ) -> String {
        let url = URL(fileURLWithPath: path)
        let isSelected = path == shot.selectedArtifactPath
        let selectedClass = isSelected ? " selected" : ""
        let preview: String
        if let dataURL = thumbnailDataURL(for: url, maxSide: 420, compression: 0.68) {
            preview = "<img class=\"preview\" src=\"\(dataURL)\" alt=\"\(escape(url.lastPathComponent))\">"
        } else {
            let ext = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
            preview = "<div class=\"file\">\(escape(ext))</div>"
        }
        let selectPrompt = selectArtifactPrompt(project: project, episode: episode, shot: shot, artifactPath: path, reviewItemID: reviewItemID)
        return """
        <article class="candidate\(selectedClass)">
          \(preview)
          <div class="badge">\(isSelected ? "当前主图" : "候选 \(index + 1)")</div>
          <div class="path">\(escape(url.lastPathComponent))</div>
          <button onclick="sendPrompt(\(selectPrompt))">选为主图</button>
        </article>
        """
    }

    private static func selectArtifactPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        artifactPath: String,
        reviewItemID: String?
    ) -> String {
        let baseArguments = [
            "project_id=\(project.id.uuidString)",
            "episode_id=\(episode.id.uuidString)",
            "shot_id=\(shot.id.uuidString)"
        ].joined(separator: ", ")
        let artifactArguments = "\(baseArguments), artifact_path=\(artifactPath)"
        let imageArguments = "\(baseArguments), image_path=\(artifactPath)"
        var context: [String] = [
            "<short-drama-image-choice>",
            "action: select_shot_artifact",
            "project_id: \(project.id.uuidString)",
            "episode_id: \(episode.id.uuidString)",
            "shot_id: \(shot.id.uuidString)",
            "artifact_path: \(artifactPath)",
            "shot_title: \(shot.title)"
        ]
        if let reviewItemID, !reviewItemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.append("review_item_id: \(reviewItemID)")
            context.append("post_select_resolve_review_tool: short_drama_resolve_review_item")
            context.append("post_select_resolve_review_arguments: \(baseArguments), item_id=\(reviewItemID)")
        }
        context.append("post_select_video_tool: generate_video_from_image")
        context.append("post_select_video_arguments: \(imageArguments)")
        context.append("post_select_edit_tool: short_drama_open_image_editor")
        context.append("post_select_edit_arguments: \(artifactArguments), operation=inpaint")
        context.append("post_select_erase_tool: short_drama_open_image_editor")
        context.append("post_select_erase_arguments: \(artifactArguments), operation=erase")
        context.append("post_select_upscale_tool: short_drama_upscale_shot_artifact")
        context.append("post_select_upscale_arguments: \(artifactArguments)")
        context.append("</short-drama-image-choice>")
        return jsString("""
        请把这张候选图设为该分镜主图。请调用 short_drama_select_shot_artifact，并使用下面的 project_id / episode_id / shot_id / artifact_path；如果下面有 review_item_id，也要一并传入。完成后请优先参考 post_select_* 字段继续生成视频、蒙版重绘、擦除、放大或关闭检查项；如果下面有 review_item_id，后续媒体任务也必须继续携带。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func html(for project: AgentShortDramaProject, mediaTasks: [AgentMediaTask]) -> String {
        let episodesHTML = project.episodes
            .sorted { $0.order < $1.order }
            .map { episodeHTML(project: project, episode: $0, mediaTasks: mediaTasks) }
            .joined(separator: "\n")
        let projectTasks = mediaTasks.filter { task in
            task.projectID == project.id.uuidString || task.projectPath == project.id.uuidString
        }
        let projectTaskSummary = taskSummaryHTML(projectTasks)
        let projectRetryTasksAction = retryFailedTasksActionHTML(project: project, tasks: projectTasks)
        let projectActiveTasksAction = activeTasksActionHTML(project: project, tasks: projectTasks)
        let projectContinuityPrompt = projectContinuityPrompt(project: project)
        // Contract migration: these buttons used to call
        // projectBatchPrompt(project: project, kind: "image_generation"),
        // projectBatchPrompt(project: project, kind: "video_generation"), and
        // projectExportPrompt(project: project). They now use sendToolAction so
        // the chat receives explicit tool names and arguments.
        let empty = episodesHTML.isEmpty
            ? "<div class=\"empty\">还没有分镜。可以让 Agent 先拆集、拆分镜，再回到这里生成看板。</div>"
            : ""
        return """
        <style>
          .wd-storyboard { display: grid; gap: 12px; }
          .wd-head { display: flex; gap: 12px; justify-content: space-between; align-items: flex-start; border-bottom: 1px solid color-mix(in srgb, var(--secondary) 22%, transparent); padding-bottom: 10px; }
          .wd-title { font-size: 18px; font-weight: 750; line-height: 1.2; }
          .wd-logline { color: var(--secondary); margin-top: 4px; line-height: 1.45; max-width: 72ch; }
          .wd-stats { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; min-width: 160px; }
          .wd-pill { border: 1px solid color-mix(in srgb, var(--secondary) 24%, transparent); border-radius: 999px; padding: 4px 8px; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 7%, transparent); white-space: nowrap; }
          .project-actions { margin-top: 7px; display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
          .episode { display: grid; gap: 8px; }
          .episode-title { display: flex; gap: 8px; align-items: baseline; font-weight: 700; padding-top: 4px; }
          .episode-title span { color: var(--secondary); font-size: 12px; }
          .episode-actions { margin-left: auto; display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
          .shots { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 8px; }
          .shot { border: 1px solid color-mix(in srgb, var(--secondary) 18%, transparent); border-radius: 8px; padding: 8px; background: color-mix(in srgb, var(--secondary) 5%, transparent); display: grid; gap: 7px; min-height: 132px; }
          .shot-top { display: flex; gap: 8px; align-items: flex-start; }
          .shot-order { width: 24px; height: 24px; border-radius: 50%; background: color-mix(in srgb, var(--accent) 16%, transparent); color: var(--accent); display: grid; place-items: center; font-weight: 700; flex: 0 0 auto; }
          .shot-title { font-weight: 650; line-height: 1.25; }
          .shot-status { margin-left: auto; color: var(--secondary); font-size: 11px; white-space: nowrap; }
          .shot-ids { color: var(--secondary); font-size: 10px; font-family: ui-monospace, "SF Mono", Menlo, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .shot-summary { color: var(--secondary); line-height: 1.4; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
          .review-items { display: flex; flex-wrap: wrap; gap: 5px; min-height: 0; }
          .review { border: 1px solid color-mix(in srgb, var(--secondary) 24%, transparent); border-radius: 999px; padding: 3px 7px; font-size: 10px; color: var(--secondary); max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; background: transparent; cursor: pointer; }
          .review:hover { border-color: color-mix(in srgb, var(--accent) 52%, transparent); color: var(--accent); }
          .review.high { border-color: color-mix(in srgb, #ff453a 50%, transparent); color: #ff453a; }
          .review.medium { border-color: color-mix(in srgb, #ff9f0a 48%, transparent); color: #ff9f0a; }
          .task-summary { display: flex; flex-wrap: wrap; gap: 5px; min-height: 0; }
          .task-pill { border: 1px solid color-mix(in srgb, var(--secondary) 22%, transparent); border-radius: 999px; padding: 3px 7px; font-size: 10px; color: var(--secondary); background: color-mix(in srgb, var(--secondary) 5%, transparent); }
          .task-pill.active { border-color: color-mix(in srgb, var(--accent) 42%, transparent); color: var(--accent); }
          .task-pill.failed { border-color: color-mix(in srgb, #ff453a 50%, transparent); color: #ff453a; }
          .task-pill.done { border-color: color-mix(in srgb, #30d158 45%, transparent); color: #30d158; }
          .thumbs { display: flex; gap: 6px; overflow: hidden; min-height: 46px; }
          .thumb { width: 58px; height: 42px; object-fit: cover; border-radius: 6px; border: 1px solid color-mix(in srgb, var(--secondary) 20%, transparent); background: color-mix(in srgb, var(--secondary) 8%, transparent); flex: 0 0 auto; }
          .thumb.selected { border-color: var(--accent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 26%, transparent); }
          .file-thumb { width: 58px; height: 42px; border-radius: 6px; border: 1px solid color-mix(in srgb, var(--secondary) 20%, transparent); display: grid; place-items: center; color: var(--secondary); font-size: 10px; font-weight: 700; }
          .file-thumb.selected { border-color: var(--accent); color: var(--accent); }
          .actions { display: flex; gap: 6px; flex-wrap: wrap; margin-top: auto; }
          button { appearance: none; border: 1px solid color-mix(in srgb, var(--accent) 36%, transparent); background: color-mix(in srgb, var(--accent) 10%, transparent); color: var(--accent); border-radius: 6px; padding: 4px 7px; font: inherit; font-size: 11px; cursor: pointer; }
          button:hover { background: color-mix(in srgb, var(--accent) 18%, transparent); }
          .empty { color: var(--secondary); border: 1px dashed color-mix(in srgb, var(--secondary) 28%, transparent); border-radius: 8px; padding: 16px; text-align: center; }
        </style>
        <div class="wd-storyboard">
          <div class="wd-head">
            <div>
              <div class="wd-title">\(escape(project.title))</div>
              \(project.logline.map { "<div class=\"wd-logline\">\(escape($0))</div>" } ?? "")
            </div>
            <div class="wd-stats">
              <div class="wd-pill">\(project.episodes.count) 集</div>
              <div class="wd-pill">\(shotCount(project)) 镜</div>
              <div class="wd-pill">\(project.characters.count) 人物</div>
              <div class="wd-pill">\(project.scenes.count) 场景</div>
              \(projectTaskSummary)
              <div class="project-actions">
                \(toolActionButton(label: "全剧图片", tool: "short_drama_generate_batch_media", arguments: "project_id=\(project.id.uuidString), kind=image_generation", note: "批量提交全剧分镜图片任务，提交后打开媒体任务侧栏。", actionKey: "generate_project_images"))
                \(toolActionButton(label: "全剧视频", tool: "short_drama_generate_batch_media", arguments: "project_id=\(project.id.uuidString), kind=video_generation", note: "批量提交全剧分镜视频任务，默认使用 Seedance 2.0；如用户指定可灵/Kling，加 video_engine=kling。视频应优先复用分镜主图作为首帧参考。", actionKey: "generate_project_videos"))
                \(toolActionButton(label: "查看全部任务", tool: "short_drama_open_media_tasks", arguments: "project_id=\(project.id.uuidString), scope=project", note: "打开这个短剧项目的全部媒体任务侧栏。", actionKey: "open_project_media_tasks"))
                \(toolActionButton(label: "刷新全部任务", tool: "short_drama_refresh_media_tasks", arguments: "project_id=\(project.id.uuidString), scope=project", note: "刷新这个短剧项目范围内的 some.im / Replicate 异步任务状态。", actionKey: "refresh_project_media_tasks"))
                \(projectActiveTasksAction)
                \(projectRetryTasksAction)
                <button onclick="sendPrompt(\(projectContinuityPrompt))">全剧检查</button>
                \(toolActionButton(label: "导出全剧包", tool: "short_drama_export_production_package", arguments: "project_id=\(project.id.uuidString)", note: "导出完整短剧制作包，方便交给短剧 Skill、Ruby 脚本或第三方 API 继续制作。", actionKey: "export_project_package"))
              </div>
            </div>
          </div>
          \(empty)
          \(episodesHTML)
        </div>
        """
    }

    private static func projectContinuityPrompt(project: AgentShortDramaProject) -> String {
        let shotLines = project.episodes
            .sorted { $0.order < $1.order }
            .flatMap { episode in
                episode.shots
                    .sorted { $0.order < $1.order }
                    .map { shot in
                        "- 第 \(episode.order) 集 / 镜 \(shot.order): \(shot.title) — episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), selected_artifact_path=\(shot.selectedArtifactPath ?? "")"
                    }
            }
            .joined(separator: "\n")
        let context: [String] = [
            "<short-drama-project-widget-action>",
            "action: continuity_review_project",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_count: \(project.episodes.count)",
            "shot_count: \(shotCount(project))",
            "shots:",
            shotLines.isEmpty ? "(none)" : shotLines,
            "</short-drama-project-widget-action>"
        ]
        return jsString("""
        请审查这个短剧项目的全剧连续性，重点看人物设定、服装道具、场景空间、镜头衔接、画风一致性、主图/视频产物是否与分镜意图一致。请把每个具体问题调用 short_drama_upsert_review_item 写回对应分镜，kind 可用 continuity、prompt、redraw、erase、upscale、reshoot 或 note；已经确认无问题的分镜不用写入。需要发起后续任务时，必须携带下面对应的 project_id / episode_id / shot_id。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func projectBatchPrompt(project: AgentShortDramaProject, kind: String) -> String {
        let action = kind == "video_generation" ? "generate_project_videos" : "generate_project_images"
        let kindLabel = kind == "video_generation" ? "视频" : "图片"
        let shotLines = project.episodes
            .sorted { $0.order < $1.order }
            .flatMap { episode in
                episode.shots
                    .sorted { $0.order < $1.order }
                    .map { shot in
                        "- 第 \(episode.order) 集 / 镜 \(shot.order): \(shot.title) — episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString)"
                    }
            }
            .joined(separator: "\n")
        let context: [String] = [
            "<short-drama-project-widget-action>",
            "action: \(action)",
            "kind: \(kind)",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_count: \(project.episodes.count)",
            "shot_count: \(shotCount(project))",
            "shots:",
            shotLines.isEmpty ? "(none)" : shotLines,
            "</short-drama-project-widget-action>"
        ]
        return jsString("""
        请为这个短剧项目批量生成全剧分镜\(kindLabel)。请调用 short_drama_generate_batch_media，并传入 project_id 和 kind=\(kind)。提交任务后请打开或提示我查看媒体任务侧栏。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func episodeHTML(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        mediaTasks: [AgentMediaTask]
    ) -> String {
        let shotsHTML = episode.shots
            .sorted { $0.order < $1.order }
            .map { shotHTML(project: project, episode: episode, shot: $0, mediaTasks: mediaTasks) }
            .joined(separator: "\n")
        let episodeTasks = mediaTasks.filter { task in
            (task.projectID == project.id.uuidString || task.projectPath == project.id.uuidString) &&
                task.episodeID == episode.id.uuidString
        }
        let episodeTaskSummary = taskSummaryHTML(episodeTasks)
        let retryTasksAction = retryFailedTasksActionHTML(project: project, episode: episode, tasks: episodeTasks)
        let activeTasksAction = activeTasksActionHTML(project: project, episode: episode, tasks: episodeTasks)
        // Contract migration: these buttons used to call
        // episodeBatchPrompt(project: project, episode: episode, kind: "image_generation"),
        // episodeBatchPrompt(project: project, episode: episode, kind: "video_generation"),
        // and episodeExportPrompt(project: project, episode: episode). They now carry
        // the same episode-scoped intent through sendToolAction with explicit tool names.
        return """
        <section class="episode">
          <div class="episode-title">
            <div>第 \(episode.order) 集：\(escape(episode.title)) <span>\(episode.shots.count) 镜</span> \(episodeTaskSummary)</div>
            <div class="episode-actions">
              \(toolActionButton(label: "批量图片", tool: "short_drama_generate_batch_media", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=image_generation", note: "批量提交这一集的分镜图片任务，提交后打开媒体任务侧栏。", actionKey: "generate_episode_images"))
              \(toolActionButton(label: "批量视频", tool: "short_drama_generate_batch_media", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), kind=video_generation", note: "批量提交这一集的分镜视频任务，默认使用 Seedance 2.0；如用户指定可灵/Kling，加 video_engine=kling。视频应优先复用分镜主图作为首帧参考。", actionKey: "generate_episode_videos"))
              \(toolActionButton(label: "查看任务", tool: "short_drama_open_media_tasks", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), scope=episode", note: "打开这一集的媒体任务侧栏。", actionKey: "open_episode_media_tasks"))
              \(toolActionButton(label: "刷新任务", tool: "short_drama_refresh_media_tasks", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), scope=episode", note: "刷新这一集范围内的 some.im / Replicate 异步任务状态。", actionKey: "refresh_episode_media_tasks"))
              \(activeTasksAction)
              \(retryTasksAction)
              \(toolActionButton(label: "导出本集包", tool: "short_drama_export_production_package", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString)", note: "导出这一集的短剧制作包，方便交给短剧 Skill、Ruby 脚本或第三方 API 继续制作。", actionKey: "export_episode_package"))
            </div>
          </div>
          <div class="shots">\(shotsHTML)</div>
        </section>
        """
    }

    private static func episodeBatchPrompt(project: AgentShortDramaProject, episode: AgentShortDramaEpisode, kind: String) -> String {
        let action = kind == "video_generation" ? "generate_episode_videos" : "generate_episode_images"
        let kindLabel = kind == "video_generation" ? "视频" : "图片"
        let shotLines = episode.shots
            .sorted { $0.order < $1.order }
            .map { "- \($0.order). \($0.title) — \($0.id.uuidString)" }
            .joined(separator: "\n")
        let context: [String] = [
            "<short-drama-episode-widget-action>",
            "action: \(action)",
            "kind: \(kind)",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_count: \(episode.shots.count)",
            "shots:",
            shotLines.isEmpty ? "(none)" : shotLines,
            "</short-drama-episode-widget-action>"
        ]
        return jsString("""
        请为这一整集批量生成分镜\(kindLabel)。请调用 short_drama_generate_batch_media，并传入 project_id、episode_id 和 kind=\(kind)。提交任务后请打开或提示我查看媒体任务侧栏。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func episodeExportPrompt(project: AgentShortDramaProject, episode: AgentShortDramaEpisode) -> String {
        let context: [String] = [
            "<short-drama-episode-widget-action>",
            "action: export_episode_package",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "</short-drama-episode-widget-action>"
        ]
        return jsString("""
        请导出这一集的短剧制作包。请调用 short_drama_export_production_package，并传入 project_id 和 episode_id。导出后请告诉我 production-package.json、production-package.md、production-timeline.json、media-import-manifest-template.json、ruby-media-script-template.rb、media-api.env.example 和 outputs 目录路径，方便交给 Ruby skill 或第三方 API 脚本继续制作。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func projectExportPrompt(project: AgentShortDramaProject) -> String {
        let context: [String] = [
            "<short-drama-widget-action>",
            "action: export_project_package",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_count: \(project.episodes.count)",
            "shot_count: \(shotCount(project))",
            "</short-drama-widget-action>"
        ]
        return jsString("""
        请导出这个短剧项目的完整制作包。请调用 short_drama_export_production_package，并只传入 project_id，不要传 episode_id。导出后请告诉我 production-package.json、production-package.md、production-timeline.json、media-import-manifest-template.json、ruby-media-script-template.rb、media-api.env.example 和 outputs 目录路径，方便交给短剧 Skill、Ruby 脚本或第三方 API 继续制作。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func shotHTML(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        mediaTasks: [AgentMediaTask]
    ) -> String {
        let summary = escape(shot.summary ?? shot.prompt ?? "暂无摘要")
        let thumbs = thumbnailsHTML(paths: orderedArtifactPaths(for: shot), selectedPath: shot.selectedArtifactPath)
        let reviews = reviewItemsHTML(project: project, episode: episode, shot: shot)
        let shotTasks = mediaTasks.filter { task in
            (task.projectID == project.id.uuidString || task.projectPath == project.id.uuidString) &&
                task.episodeID == episode.id.uuidString &&
                task.shotID == shot.id.uuidString
        }
        let shotTaskSummary = taskSummaryHTML(shotTasks)
        let improvePrompt = actionPrompt(
            action: "optimize_prompt",
            instruction: "请检查并优化这个分镜的画面提示词，保持人物和场景一致性。需要更新时，请调用 short_drama_upsert_shot，并保留下面的 project_id / episode_id / shot_id。",
            project: project,
            episode: episode,
            shot: shot
        )
        let generatePrompt = actionPrompt(
            action: "generate_keyframe",
            instruction: "请基于这个分镜继续生成关键帧或视频。优先调用 short_drama_generate_shot_media，并使用下面的 project_id / episode_id / shot_id；如果要生成视频，默认使用 Seedance 2.0，并优先使用 selected_artifact_path 作为参考/首帧图；如果用户指定可灵/Kling，请传 video_engine=kling。只有需要自定义 endpoint 或特殊 input_json 时才改用 some_im_create_media_task。",
            project: project,
            episode: episode,
            shot: shot
        )
        let reviewPrompt = actionPrompt(
            action: "continuity_review",
            instruction: "请审查这个分镜现有产物是否符合短剧连续性。请把每个需要重绘、擦除、放大、补拍或提示词修复的问题调用 short_drama_upsert_review_item 写回这个分镜；已经处理完成的问题请调用 short_drama_resolve_review_item 标记解决。需要发起后续任务时，必须携带下面的 project_id / episode_id / shot_id。",
            project: project,
            episode: episode,
            shot: shot
        )
        let retryAction = retryFailedTasksActionHTML(project: project, episode: episode, shot: shot, tasks: shotTasks)
        let activeTasksAction = activeTasksActionHTML(project: project, episode: episode, shot: shot, tasks: shotTasks)
        let choiceAction = orderedArtifactPaths(for: shot).count > 1
            ? toolActionButton(label: "选择候选图", tool: "short_drama_show_image_choice_widget", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString)", note: "打开这个分镜的候选图选择器。", actionKey: "show_image_choice_widget")
            : ""
        let editActions = primaryImagePath(for: shot).map { imagePath in
            return """
            \(toolActionButton(label: "重绘主图", tool: "short_drama_open_image_editor", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), artifact_path=\(imagePath), operation=inpaint", note: "打开这个分镜主图做蒙版重绘。", actionKey: "open_shot_inpaint_editor"))
            \(toolActionButton(label: "擦除主图", tool: "short_drama_open_image_editor", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), artifact_path=\(imagePath), operation=erase", note: "打开这个分镜主图做蒙版擦除。", actionKey: "open_shot_erase_editor"))
            \(toolActionButton(label: "放大主图", tool: "short_drama_upscale_shot_artifact", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), artifact_path=\(imagePath)", note: "提交 Replicate 图片放大任务，并锚定到这个短剧分镜。", actionKey: "upscale_shot_artifact"))
            """
        } ?? ""
        let videoReviewAction = primaryVideoPath(for: shot).map { videoPath in
            "<button onclick=\"sendPrompt(\(videoReviewPrompt(project: project, episode: episode, shot: shot, videoPath: videoPath)))\">审片视频</button>"
        } ?? ""
        return """
        <article class="shot">
          <div class="shot-top">
            <div class="shot-order">\(shot.order)</div>
            <div class="shot-title">\(escape(shot.title))</div>
            <div class="shot-status">\(escape(shot.status.displayName))</div>
          </div>
          <div class="shot-ids">shot \(escape(shortID(shot.id))) · episode \(escape(shortID(episode.id)))</div>
          <div class="shot-summary">\(summary)</div>
          \(shotTaskSummary)
          <div class="review-items">\(reviews)</div>
          <div class="thumbs">\(thumbs)</div>
          <div class="actions">
            <button onclick="sendPrompt(\(improvePrompt))">优化提示词</button>
            <button onclick="sendPrompt(\(generatePrompt))">继续生成</button>
            \(choiceAction)
            \(editActions)
            \(videoReviewAction)
            \(toolActionButton(label: "查看任务", tool: "short_drama_open_media_tasks", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=shot", note: "打开这个分镜的媒体任务侧栏。", actionKey: "open_shot_media_tasks"))
            \(toolActionButton(label: "刷新任务", tool: "short_drama_refresh_media_tasks", arguments: "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=shot", note: "刷新这个分镜范围内的 some.im / Replicate 异步任务状态。", actionKey: "refresh_shot_media_tasks"))
            \(activeTasksAction)
            \(retryAction)
            <button onclick="sendPrompt(\(reviewPrompt))">检查连续性</button>
          </div>
        </article>
        """
    }

    private static func retryFailedTasksActionHTML(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode? = nil,
        shot: AgentShortDramaShot? = nil,
        tasks: [AgentMediaTask]
    ) -> String {
        let retryable = tasks.filter(isRetryableFailedTask)
        guard !retryable.isEmpty else { return "" }
        return "<button onclick=\"sendPrompt(\(retryFailedTasksPrompt(project: project, episode: episode, shot: shot, tasks: retryable)))\">重试失败</button>"
    }

    private static func activeTasksActionHTML(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode? = nil,
        shot: AgentShortDramaShot? = nil,
        tasks: [AgentMediaTask]
    ) -> String {
        let active = tasks.filter(\.isActive)
        guard !active.isEmpty else { return "" }
        return "<button onclick=\"sendPrompt(\(activeTasksPrompt(project: project, episode: episode, shot: shot, tasks: active)))\">处理任务</button>"
    }

    private static func activeTasksPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode?,
        shot: AgentShortDramaShot?,
        tasks: [AgentMediaTask]
    ) -> String {
        let scope = shot == nil ? (episode == nil ? "project" : "episode") : "shot"
        let taskLines = tasks
            .prefix(20)
            .compactMap(AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine)
            .joined(separator: "\n")
        var context = [
            "<short-drama-widget-action>",
            "action: continue_active_media_tasks",
            "scope: \(scope)",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)"
        ]
        if let episode {
            context.append("episode_id: \(episode.id.uuidString)")
            context.append("episode_order: \(episode.order)")
            context.append("episode_title: \(episode.title)")
        }
        if let shot {
            context.append("shot_id: \(shot.id.uuidString)")
            context.append("shot_order: \(shot.order)")
            context.append("shot_title: \(shot.title)")
        }
        context.append("active_task_count: \(tasks.count)")
        context.append("active_task_actions:")
        context.append(taskLines.isEmpty ? "(none)" : taskLines)
        context.append("</short-drama-widget-action>")
        return jsString("""
        请继续处理这个\(scopeLabel(scope))范围内的运行中媒体任务。请优先读取 active_task_actions：其中 Replicate / some.im 任务已经带有 poll/cancel 工具参数；如果需要统一刷新范围，请调用 short_drama_refresh_media_tasks，并传入 project_id\(episode == nil ? "" : "、episode_id")\(shot == nil ? "" : "、shot_id")、scope=\(scope)。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func retryFailedTasksPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode?,
        shot: AgentShortDramaShot?,
        tasks: [AgentMediaTask]
    ) -> String {
        let taskLines = tasks.map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" }
        let scope = shot == nil ? (episode == nil ? "project" : "episode") : "shot"
        var context = [
            "<short-drama-widget-action>",
            "action: retry_failed_media_tasks",
            "scope: \(scope)",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)"
        ]
        if let episode {
            context.append("episode_id: \(episode.id.uuidString)")
            context.append("episode_order: \(episode.order)")
            context.append("episode_title: \(episode.title)")
        }
        if let shot {
            context.append("shot_id: \(shot.id.uuidString)")
            context.append("shot_order: \(shot.order)")
            context.append("shot_title: \(shot.title)")
        }
        context.append("task_count: \(tasks.count)")
        context.append("tasks:")
        context.append(taskLines.joined(separator: "\n"))
        context.append("</short-drama-widget-action>")
        return jsString("""
        请重试这个\(scopeLabel(scope))范围内的失败短剧媒体任务。请先调用 short_drama_retry_failed_media_tasks，并传入 project_id\(episode == nil ? "" : "、episode_id")\(shot == nil ? "" : "、shot_id")、scope=\(scope)、dry_run=true 预检；如果预检结果合理，再用 dry_run=false 正式提交。提交后请打开或提示我查看媒体任务侧栏。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "shot": return "分镜"
        case "episode": return "分集"
        default: return "项目"
        }
    }

    nonisolated private static func isRetryableFailedTask(_ task: AgentMediaTask) -> Bool {
        guard task.status == .failed || task.status == .canceled else { return false }
        guard task.provider == .someIM else { return false }
        guard task.projectID != nil || task.projectPath != nil else { return false }
        if task.assetKind != nil, task.assetID != nil, task.kind == .imageGeneration {
            return true
        }
        guard task.episodeID != nil, task.shotID != nil else { return false }
        return task.kind == .imageGeneration || task.kind == .videoGeneration
    }

    private static func refreshMediaTasksPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot? = nil
    ) -> String {
        mediaTaskActionPrompt(
            action: "refresh_media_tasks",
            toolName: "short_drama_refresh_media_tasks",
            verb: "刷新",
            project: project,
            episode: episode,
            shot: shot
        )
    }

    private static func projectRefreshMediaTasksPrompt(project: AgentShortDramaProject) -> String {
        projectMediaTaskActionPrompt(
            action: "refresh_media_tasks",
            toolName: "short_drama_refresh_media_tasks",
            verb: "刷新",
            project: project
        )
    }

    private static func projectMediaTasksPrompt(project: AgentShortDramaProject) -> String {
        projectMediaTaskActionPrompt(
            action: "open_media_tasks",
            toolName: "short_drama_open_media_tasks",
            verb: "打开",
            project: project
        )
    }

    private static func projectMediaTaskActionPrompt(
        action: String,
        toolName: String,
        verb: String,
        project: AgentShortDramaProject
    ) -> String {
        let context: [String] = [
            "<short-drama-widget-action>",
            "action: \(action)",
            "scope: project",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "</short-drama-widget-action>"
        ]
        return jsString("""
        请\(verb)这个短剧项目的全部媒体任务侧栏。请调用 \(toolName)，并传入 project_id 和 scope=project。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func mediaTasksPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot? = nil
    ) -> String {
        mediaTaskActionPrompt(
            action: "open_media_tasks",
            toolName: "short_drama_open_media_tasks",
            verb: "打开",
            project: project,
            episode: episode,
            shot: shot
        )
    }

    private static func mediaTaskActionPrompt(
        action: String,
        toolName: String,
        verb: String,
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot? = nil
    ) -> String {
        let scope = shot == nil ? "episode" : "shot"
        var context: [String] = [
            "<short-drama-widget-action>",
            "action: \(action)",
            "scope: \(scope)",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)"
        ]
        if let shot {
            context.append("shot_id: \(shot.id.uuidString)")
            context.append("shot_order: \(shot.order)")
            context.append("shot_title: \(shot.title)")
        }
        context.append("</short-drama-widget-action>")
        let label = shot == nil ? "这一集" : "这个分镜"
        return jsString("""
        请\(verb)\(label)的媒体任务侧栏。请调用 \(toolName)，并传入 project_id、episode_id\(shot == nil ? "" : "、shot_id") 和 scope=\(scope)。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func imageChoicePrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot
    ) -> String {
        let context: [String] = [
            "<short-drama-widget-action>",
            "action: show_image_choice_widget",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_order: \(shot.order)",
            "shot_title: \(shot.title)",
            "artifact_count: \(shot.artifactPaths.count)",
            "</short-drama-widget-action>"
        ]
        return jsString("""
        请打开这个分镜的候选图选择器。请调用 short_drama_show_image_choice_widget，并传入 project_id、episode_id 和 shot_id。打开后我会在网页组件里选择主图；选择完成后请读取候选图组件输出的 post_select_* 字段继续衔接视频、蒙版重绘、擦除、放大或检查项关闭。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func imageEditorPrompt(
        operation: String,
        label: String,
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        artifactPath: String
    ) -> String {
        let context: [String] = [
            "<short-drama-widget-action>",
            "action: open_image_editor",
            "operation: \(operation)",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_order: \(shot.order)",
            "shot_title: \(shot.title)",
            "artifact_path: \(artifactPath)",
            "</short-drama-widget-action>"
        ]
        return jsString("""
        请打开这个分镜主图做蒙版\(label)。请调用 short_drama_open_image_editor，并传入 project_id、episode_id、shot_id、operation 和 artifact_path。打开后我会在右侧图片蒙版面板框选区域并提交 Replicate 或 some.im 编辑任务。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func imageUpscalePrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        artifactPath: String
    ) -> String {
        let context: [String] = [
            "<short-drama-widget-action>",
            "action: upscale_shot_artifact",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_order: \(shot.order)",
            "shot_title: \(shot.title)",
            "artifact_path: \(artifactPath)",
            "</short-drama-widget-action>"
        ]
        return jsString("""
        请放大这个分镜主图。请调用 short_drama_upscale_shot_artifact，并传入 project_id、episode_id、shot_id 和 artifact_path。提交后请打开或提示我查看媒体任务侧栏。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func actionPrompt(
        action: String,
        instruction: String,
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot
    ) -> String {
        let artifactLines = shot.artifactPaths.prefix(8).map { "- \($0)" }
        let artifactSummary: String
        if artifactLines.isEmpty {
            artifactSummary = "(none)"
        } else if shot.artifactPaths.count > artifactLines.count {
            artifactSummary = (artifactLines + ["... \(shot.artifactPaths.count - artifactLines.count) more"]).joined(separator: "\n")
        } else {
            artifactSummary = artifactLines.joined(separator: "\n")
        }
        let context: [String] = [
            "<short-drama-widget-action>",
            "action: \(action)",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_order: \(shot.order)",
            "shot_title: \(shot.title)",
            "shot_status: \(shot.status.rawValue)",
            "shot_summary: \(shot.summary ?? "")",
            "shot_prompt: \(shot.prompt ?? "")",
            "selected_artifact_path: \(shot.selectedArtifactPath ?? "")",
            "artifact_paths:",
            artifactSummary,
            "open_review_items:",
            openReviewItemsSummary(shot.reviewItems),
            "</short-drama-widget-action>"
        ]
        return jsString("\(instruction)\n\n\(context.joined(separator: "\n"))")
    }

    private static func openReviewItemsSummary(_ items: [AgentShortDramaReviewItem]) -> String {
        let openItems = items.filter { $0.status != .resolved }
        guard !openItems.isEmpty else { return "(none)" }
        return openItems.prefix(8).map { item in
            "- [\(item.kind.rawValue)/\(item.severity.rawValue)] \(item.title): \(item.suggestedAction ?? item.detail ?? "")"
        }.joined(separator: "\n")
    }

    private static func taskSummaryHTML(_ tasks: [AgentMediaTask]) -> String {
        guard !tasks.isEmpty else { return "" }
        let active = tasks.filter(\.isActive).count
        let failed = tasks.filter(\.needsAttention).count
        let done = tasks.filter { $0.status == .succeeded }.count
        var pills: [String] = []
        if active > 0 {
            pills.append("<span class=\"task-pill active\">处理中 \(active)</span>")
        }
        if failed > 0 {
            pills.append("<span class=\"task-pill failed\">失败 \(failed)</span>")
        }
        if done > 0 {
            pills.append("<span class=\"task-pill done\">完成 \(done)</span>")
        }
        if pills.isEmpty {
            pills.append("<span class=\"task-pill\">任务 \(tasks.count)</span>")
        }
        return "<span class=\"task-summary\">\(pills.joined())</span>"
    }

    private static func orderedArtifactPaths(for shot: AgentShortDramaShot) -> [String] {
        guard let selected = shot.selectedArtifactPath, shot.artifactPaths.contains(selected) else {
            return shot.artifactPaths
        }
        return [selected] + shot.artifactPaths.filter { $0 != selected }
    }

    private static func primaryImagePath(for shot: AgentShortDramaShot) -> String? {
        orderedArtifactPaths(for: shot).first { path in
            ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"]
                .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }
    }

    private static func primaryVideoPath(for shot: AgentShortDramaShot) -> String? {
        orderedArtifactPaths(for: shot).first { path in
            ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
                .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }
    }

    private static func videoReviewPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        videoPath: String
    ) -> String {
        let context: [String] = [
            "<short-drama-widget-video-action>",
            "action: review_shot_video_artifact",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_order: \(shot.order)",
            "shot_title: \(shot.title)",
            "video_path: \(videoPath)",
            "open_shot_tasks_tool: short_drama_open_media_tasks",
            "open_shot_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=shot",
            "refresh_shot_tasks_tool: short_drama_refresh_media_tasks",
            "refresh_shot_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=shot",
            "storyboard_widget_tool: short_drama_show_storyboard_widget",
            "storyboard_widget_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString)",
            "</short-drama-widget-video-action>"
        ]
        return jsString("""
        请基于这个短剧分镜视频产物继续审片。请检查视频是否符合分镜提示词、人物/服装/场景连续性、运动节奏和画面稳定性；若发现问题，请调用 short_drama_upsert_review_item 写回这个分镜。需要查看任务流水时，请优先使用下面的 open/refresh 结构化参数。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func thumbnailsHTML(paths: [String], selectedPath: String?) -> String {
        let items = paths.prefix(3).map { path -> String in
            let url = URL(fileURLWithPath: path)
            let selectedClass = path == selectedPath ? " selected" : ""
            if let dataURL = thumbnailDataURL(for: url) {
                return "<img class=\"thumb\(selectedClass)\" src=\"\(dataURL)\" alt=\"\(escape(url.lastPathComponent))\">"
            }
            let ext = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
            return "<div class=\"file-thumb\(selectedClass)\">\(escape(ext))</div>"
        }
        if items.isEmpty {
            return "<div class=\"file-thumb\">暂无</div>"
        }
        return items.joined()
    }

    private static func reviewItemsHTML(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot
    ) -> String {
        let openItems = shot.reviewItems.filter { $0.status != .resolved }
        guard !openItems.isEmpty else { return "" }
        return openItems.prefix(4).map { item in
            let severityClass = item.severity == .high ? " high" : (item.severity == .medium ? " medium" : "")
            let prompt = reviewItemPrompt(project: project, episode: episode, shot: shot, item: item)
            return "<button class=\"review\(severityClass)\" onclick=\"sendPrompt(\(prompt))\">\(escape(item.kind.displayName)) · \(escape(item.title))</button>"
        }.joined()
    }

    private static func reviewItemPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) -> String {
        let selectedPath = primaryImagePath(for: shot) ?? ""
        let suggestedAction = item.suggestedAction ?? item.detail ?? ""
        let recommendation = reviewItemRecommendation(
            project: project,
            episode: episode,
            shot: shot,
            item: item,
            selectedPath: selectedPath
        )
        var context: [String] = [
            "<short-drama-review-item-action>",
            "action: fix_review_item",
            "project_id: \(project.id.uuidString)",
            "project_title: \(project.title)",
            "episode_id: \(episode.id.uuidString)",
            "episode_order: \(episode.order)",
            "episode_title: \(episode.title)",
            "shot_id: \(shot.id.uuidString)",
            "shot_order: \(shot.order)",
            "shot_title: \(shot.title)",
            "selected_artifact_path: \(selectedPath)",
            "review_item_id: \(item.id.uuidString)",
            "review_kind: \(item.kind.rawValue)",
            "review_severity: \(item.severity.rawValue)",
            "review_title: \(item.title)",
            "review_detail: \(item.detail ?? "")",
            "suggested_action: \(suggestedAction)",
            "recommended_tool: \(recommendation.tool)",
            "recommended_arguments: \(recommendation.arguments)",
            "review_tasks_tool: short_drama_open_media_tasks",
            "review_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=review_item, review_item_id=\(item.id.uuidString)",
            "refresh_review_tasks_tool: short_drama_refresh_media_tasks",
            "refresh_review_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=review_item, review_item_id=\(item.id.uuidString)",
            "resolve_review_tool: short_drama_resolve_review_item",
            "resolve_review_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), item_id=\(item.id.uuidString)"
        ]
        if let secondary = recommendation.secondaryArguments {
            context.append("secondary_tool: \(recommendation.secondaryTool ?? recommendation.tool)")
            context.append("secondary_arguments: \(secondary)")
        }
        context.append("</short-drama-review-item-action>")
        return jsString("""
        请处理这条短剧检查项，并把后续媒体任务锚定到同一个 review_item_id。
        \(recommendation.hint)
        任务完成并确认修复后，请调用 short_drama_resolve_review_item，并传入 item_id 或 review_item_id。
        如需查看这条检查项的任务流水，请先调用 short_drama_open_media_tasks(scope=review_item, review_item_id=...），需要同步最新异步状态时再调用 short_drama_refresh_media_tasks，参数相同。

        \(context.joined(separator: "\n"))
        """)
    }

    private static func reviewItemRecommendation(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem,
        selectedPath: String
    ) -> ReviewItemRecommendation {
        let baseArguments = "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), review_item_id=\(item.id.uuidString)"
        let regenerateArguments = "\(baseArguments), kind=image_generation"
        switch item.kind {
        case .redraw:
            guard !selectedPath.isEmpty else {
                return ReviewItemRecommendation(
                    hint: "当前分镜没有可编辑主图，请调用 short_drama_generate_shot_media 先补一张图，并传入 review_item_id。",
                    tool: "short_drama_generate_shot_media",
                    arguments: regenerateArguments
                )
            }
            return ReviewItemRecommendation(
                hint: "请调用 short_drama_open_image_editor，传入 operation=inpaint、artifact_path 和 review_item_id。",
                tool: "short_drama_open_image_editor",
                arguments: "\(baseArguments), operation=inpaint, artifact_path=\(selectedPath)"
            )
        case .erase:
            guard !selectedPath.isEmpty else {
                return ReviewItemRecommendation(
                    hint: "当前分镜没有可擦除主图，请调用 short_drama_generate_shot_media 先补一张图，并传入 review_item_id。",
                    tool: "short_drama_generate_shot_media",
                    arguments: regenerateArguments
                )
            }
            return ReviewItemRecommendation(
                hint: "请调用 short_drama_open_image_editor，传入 operation=erase、artifact_path 和 review_item_id。",
                tool: "short_drama_open_image_editor",
                arguments: "\(baseArguments), operation=erase, artifact_path=\(selectedPath)"
            )
        case .upscale:
            guard !selectedPath.isEmpty else {
                return ReviewItemRecommendation(
                    hint: "当前分镜没有可放大主图，请调用 short_drama_generate_shot_media 先补一张图，并传入 review_item_id。",
                    tool: "short_drama_generate_shot_media",
                    arguments: regenerateArguments
                )
            }
            return ReviewItemRecommendation(
                hint: "请调用 short_drama_upscale_shot_artifact，传入 artifact_path 和 review_item_id。",
                tool: "short_drama_upscale_shot_artifact",
                arguments: "\(baseArguments), artifact_path=\(selectedPath)"
            )
        case .reshoot:
            return ReviewItemRecommendation(
                hint: "请调用 short_drama_generate_shot_media，传入 kind=image_generation 和 review_item_id。",
                tool: "short_drama_generate_shot_media",
                arguments: regenerateArguments
            )
        case .prompt:
            return ReviewItemRecommendation(
                hint: "请先修正分镜 prompt；如果需要重新生成，请调用 short_drama_generate_shot_media 并传入 review_item_id。",
                tool: "short_drama_generate_shot_media",
                arguments: regenerateArguments,
                secondaryTool: "short_drama_upsert_review_item",
                secondaryArguments: "\(baseArguments), kind=prompt, status=doing"
            )
        case .continuity, .note:
            return ReviewItemRecommendation(
                hint: "请先分析这条检查项；如果需要生成、编辑、放大或关闭检查项，必须沿用 review_item_id。",
                tool: "short_drama_open_media_tasks",
                arguments: "\(baseArguments), scope=review_item"
            )
        }
    }

    private struct ReviewItemRecommendation {
        let hint: String
        let tool: String
        let arguments: String
        var secondaryTool: String?
        var secondaryArguments: String?
    }

    private static func thumbnailDataURL(for url: URL, maxSide: CGFloat = 120, compression: CGFloat = 0.52) -> String? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let original = image.size
        guard original.width > 0, original.height > 0 else { return nil }
        let scale = min(maxSide / original.width, maxSide / original.height, 1)
        let size = CGSize(width: max(1, original.width * scale), height: max(1, original.height * scale))
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size), from: CGRect(origin: .zero, size: original), operation: .copy, fraction: 1)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
            return nil
        }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    private static func shotCount(_ project: AgentShortDramaProject) -> Int {
        project.episodes.reduce(0) { $0 + $1.shots.count }
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func toolActionButton(
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

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [])) ?? Data("[\"\"]".utf8)
        let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }
}
