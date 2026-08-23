//
//  AgentShortDramaProductionExporterWidgetHTML.swift
//  WillDeep
//
//  Production package widget preview HTML: timeline / episode / asset
//  summary sections and the chat handoff prompts wired into its buttons.
//

import Foundation

extension AgentShortDramaProductionExporter {
    static func widgetPreviewHTML(for package: Package, directory: URL, generated: [String], skipped: [String]) -> String {
        let project = package.project
        let totalShots = project.episodes.reduce(0) { $0 + $1.shots.count }
        let openReviewItems = package.openReviewItemCount
        let generatedItems = generated.prefix(80).map { path in
            "<li><code>\(escapeHTML(path))</code></li>"
        }.joined(separator: "\n")
        let skippedItems = skipped.prefix(80).map { path in
            "<li><code>\(escapeHTML(path))</code></li>"
        }.joined(separator: "\n")
        let timelineItems = timelineSummaryHTML(for: project)
        let batchActions = batchTimelineActionsHTML(for: project)
        let episodeItems = episodeSummaryHTML(for: project)
        let assetItems = assetSummaryHTML(for: project)
        let reviewQueueActions = reviewQueueActionItemsHTML(for: project)
        let packageDirectory = directory.path
        let manifestURL = directory.appendingPathComponent("media-import-manifest-template.json", isDirectory: false)
        let widgetPreviewURL = directory.appendingPathComponent("widget-preview.html", isDirectory: false)
        let reviewTemplateURL = directory.appendingPathComponent("production-review-template.csv", isDirectory: false)
        let reviewQueueURL = directory.appendingPathComponent("production-review-queue.csv", isDirectory: false)
        let gapReportURL = directory.appendingPathComponent("production-gap-report.json", isDirectory: false)
        let timelineURL = directory.appendingPathComponent("production-timeline.json", isDirectory: false)
        let shotListURL = directory.appendingPathComponent("production-shot-list.csv", isDirectory: false)
        let handoffContext = [
            "<production-package-handoff>",
            "action: production_package_widget_preview",
            "package_directory: \(packageDirectory)",
            "manifest_path: \(manifestURL.path)",
            "widget_preview_path: \(widgetPreviewURL.path)",
            "review_template_path: \(reviewTemplateURL.path)",
            "review_queue_path: \(reviewQueueURL.path)",
            "gap_report_path: \(gapReportURL.path)",
            "timeline_path: \(timelineURL.path)",
            "shot_list_path: \(shotListURL.path)",
            "dry_run_import_tool: import_media_manifest",
            "dry_run_import_arguments: package_directory=\(packageDirectory), dry_run=true, import_pending_tasks=true",
            "submit_import_tool: import_media_manifest",
            "submit_import_arguments: package_directory=\(packageDirectory), dry_run=false, import_pending_tasks=true",
            "gap_report_tool: short_drama_generate_batch_media",
            "gap_report_follow_up: read gap_report_path and use batch_actions for dry_run before submit",
            "review_template_import_tool: short_drama_import_review_csv",
            "review_template_import_arguments: package_directory=\(packageDirectory), dry_run=true",
            "review_queue_import_tool: short_drama_import_review_csv",
            "review_queue_import_arguments: file_path=\(reviewQueueURL.path), dry_run=true",
            "</production-package-handoff>"
        ].joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(project.title)) · 制作预览</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            body { margin: 0; padding: 18px; background: var(--bg, #111); color: var(--fg, #f8f8f8); }
            .wrap { max-width: 980px; margin: 0 auto; }
            h1 { margin: 0 0 6px; font-size: 24px; line-height: 1.2; }
            .muted { color: var(--secondary, #8f8f8f); font-size: 13px; }
            .grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin: 16px 0; }
            .card { border: 1px solid color-mix(in srgb, var(--fg, #fff) 14%, transparent); border-radius: 8px; padding: 12px; background: color-mix(in srgb, var(--fg, #fff) 6%, transparent); }
            .num { font-size: 24px; font-weight: 700; }
            .label { color: var(--secondary, #aaa); font-size: 12px; margin-top: 4px; }
            .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
            .timeline { display: grid; gap: 8px; margin-top: 10px; }
            .shot-row { border: 1px solid color-mix(in srgb, var(--fg, #fff) 10%, transparent); border-radius: 6px; padding: 8px; background: color-mix(in srgb, var(--fg, #fff) 4%, transparent); }
            .shot-title { font-weight: 600; font-size: 13px; }
            .badges { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
            .actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
            .badge { border-radius: 999px; padding: 2px 7px; font-size: 11px; background: color-mix(in srgb, var(--fg, #fff) 10%, transparent); }
            .badge.warn { background: rgba(245, 166, 35, 0.22); }
            .badge.ok { background: rgba(52, 199, 89, 0.20); }
            ul { margin: 8px 0 0; padding-left: 18px; }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; overflow-wrap: anywhere; }
            button { border: 0; border-radius: 6px; padding: 8px 10px; background: var(--accent, #3478f6); color: white; cursor: pointer; }
            @media (max-width: 720px) { .grid, .cols { grid-template-columns: 1fr; } }
          </style>
        </head>
        <body>
          <div class="wrap">
            <h1>\(escapeHTML(project.title))</h1>
            <div class="muted">WillDeep 短剧制作包预览 · \(escapeHTML(package.scope)) · \(ISO8601DateFormatter().string(from: package.exportedAt))</div>
            <div class="grid">
              <div class="card"><div class="num">\(project.episodes.count)</div><div class="label">Episodes</div></div>
              <div class="card"><div class="num">\(totalShots)</div><div class="label">Shots</div></div>
              <div class="card"><div class="num">\(generated.count)</div><div class="label">Generated outputs</div></div>
              <div class="card"><div class="num">\(openReviewItems)</div><div class="label">Open review items</div></div>
            </div>
            <div class="card">
              <strong>下一步</strong>
              <p class="muted">生成或轮询完成后，在 WillDeep Agent 里先 dry-run，再正式调用 <code>import_media_manifest</code> 导回媒体任务和短剧分镜。</p>
              <button onclick="sendPrompt(\(jsonStringLiteral("请读取这个制作包，优先使用下面 <production-package-handoff> 中的 dry_run_import_arguments 先 dry-run；确认无误后使用 submit_import_arguments 导入 outputs 和 pending 远端任务，并打开短剧媒体任务侧栏。\n\n\(handoffContext)")))">交给 Agent 导回</button>
            </div>
            <div class="card">
              <strong>剪辑时间线</strong>
              <p class="muted"><code>production-timeline.json</code> 已按集和分镜顺序整理主图、视频、图片、prompt 和未解决检查项，可交给短剧 Skill、Ruby 脚本或剪辑脚本继续装配成片。</p>
              <button onclick="sendPrompt(\(jsonStringLiteral("请读取这个制作包的 production-timeline.json，按集和分镜顺序检查主图、视频产物、缺失镜头和未解决检查项，并给出下一步剪辑/补图/补视频计划；请优先使用下面 <production-package-handoff> 中的 timeline_path、gap_report_path、dry_run_import_arguments 和 submit_import_arguments。\n\n\(handoffContext)")))">按时间线继续</button>
              <p class="muted"><code>production-gap-report.json</code> 按项目、资产、分集和分镜列出缺参考图、缺主图、缺视频、未解决检查项，并给出补缺工具参数。</p>
              <button onclick="sendPrompt(\(jsonStringLiteral("请读取这个制作包的 production-gap-report.json，按 missing_asset_reference_count、missing_image_count、missing_video_count 和 open_review_item_count 排出资产参考图、补图、补视频和检查项处理顺序；资产条目里的 linked_shot_ids、linked_shot_image_dry_run_arguments、linked_shot_image_submit_arguments、linked_shot_video_dry_run_arguments、linked_shot_video_submit_arguments 可用于补完人物/场景参考图后优先推进相关分镜；如需提交资产参考图任务，请先使用 assets[].generate_reference_dry_run_arguments 预检，再确认是否使用 assets[].generate_reference_arguments 正式提交；如需提交关联分镜媒体任务，请优先使用对应 linked_shot_*_dry_run_arguments 预检，再确认 submit 参数；如需全局补齐，请使用 batch_actions 里的 dry-run 参数，再确认是否正式调用 short_drama_generate_batch_media。\n\n\(handoffContext)")))">按缺口报告排产</button>
              <p class="muted"><code>production-shot-list.csv</code> 是一镜一行的平面清单；<code>production-review-template.csv</code> 预留审片回写列；<code>production-review-queue.csv</code> 将未解决检查项展开成一条 reviewItem 一行的修复队列。</p>
              <button onclick="sendPrompt(\(jsonStringLiteral("请读取这个制作包的 production-shot-list.csv、production-review-template.csv 和 production-review-queue.csv，按一镜一行检查主图、视频路径、未解决检查项、summary 和 prompt，输出可执行的审片/剪辑准备清单；如果 production-review-template.csv 已填写，请优先使用 <production-package-handoff> 中的 review_template_import_arguments 先 dry-run；如果 production-review-queue.csv 里有未解决项，请按 kind/severity/suggested_action 排出修复顺序，并使用 review_queue_import_arguments 预检回写。\n\n\(handoffContext)")))">按 CSV 审片</button>
              <div class="actions">\(batchActions)</div>
              <div class="timeline">\(timelineItems)</div>
            </div>
            <div class="card">
              <strong>修复队列推荐动作</strong>
              <p class="muted"><code>production-review-queue.csv</code> 中每个未解决检查项都带 recommended_tool、recommended_arguments、open_review_tasks_arguments 和 resolve_review_arguments，可直接交给聊天窗口继续处理。</p>
              <ul>\(reviewQueueActions.isEmpty ? "<li class=\"muted\">暂无待处理推荐动作</li>" : reviewQueueActions)</ul>
            </div>
            <div class="card">
              <strong>分集管理</strong>
              <p class="muted">按集查看分镜数量、主图/视频缺口和未解决检查项；需要集中处理某一集时，可直接把本集 scope 交回聊天窗口。</p>
              <div class="timeline">\(episodeItems)</div>
            </div>
            <div class="card">
              <strong>参考资产</strong>
              <p class="muted">人物和场景参考图用于保持多分镜角色、服装、道具与空间连续性；缺参考图时可先生成，再继续分镜图或视频。</p>
              <div class="timeline">\(assetItems)</div>
            </div>
            <div class="cols">
              <div class="card">
                <strong>Generated</strong>
                <ul>\(generatedItems.isEmpty ? "<li class=\"muted\">暂无生成产物</li>" : generatedItems)</ul>
              </div>
              <div class="card">
                <strong>Skipped / Pending</strong>
                <ul>\(skippedItems.isEmpty ? "<li class=\"muted\">暂无跳过项</li>" : skippedItems)</ul>
              </div>
            </div>
          </div>
        </body>
        </html>
        """
    }

    private static func timelineSummaryHTML(for project: AgentShortDramaProject) -> String {
        let rows = project.episodes
            .sorted(by: { $0.order < $1.order })
            .flatMap { episode in
                episode.shots.sorted(by: { $0.order < $1.order }).map { shot in
                    let selected = selectedImagePath(for: shot)
                    let videoPath = shot.artifactPaths.first(where: isVideoPath)
                    let imageCount = shot.artifactPaths.filter(isImagePath).count
                    let videoCount = shot.artifactPaths.filter(isVideoPath).count
                    let openReviewCount = shot.reviewItems.filter { $0.status != .resolved }.count
                    let imageBadge = selected == nil
                        ? "<span class=\"badge warn\">缺主图</span>"
                        : "<span class=\"badge ok\">主图就绪</span>"
                    let videoBadge = videoCount == 0
                        ? "<span class=\"badge warn\">缺视频</span>"
                        : "<span class=\"badge ok\">视频 \(videoCount)</span>"
                    let reviewBadge = openReviewCount == 0
                        ? "<span class=\"badge ok\">检查项清零</span>"
                        : "<span class=\"badge warn\">未解决 \(openReviewCount)</span>"
                    let actions = [
                        sendPromptButton(
                            label: "查看任务",
                            prompt: "请打开这个短剧分镜的媒体任务侧栏，并优先刷新同一范围的异步任务状态。请调用 short_drama_open_media_tasks，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString)、scope=shot；如果需要拉取最新 some.im / Replicate / 第三方异步状态，请随后调用 short_drama_refresh_media_tasks，参数相同。"
                        ),
                        sendPromptButton(
                            label: "检查连续性",
                            prompt: "请审查这个短剧分镜现有产物是否符合连续性和分镜意图。请读取 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString) 的分镜上下文，重点检查人物设定、服装道具、场景空间、画风、主图/视频产物和 prompt 是否一致；发现具体问题时调用 short_drama_upsert_review_item 写回这个分镜，kind 可用 continuity、prompt、redraw、erase、upscale、reshoot 或 note。"
                        ),
                        imageCount > 1 ? sendPromptButton(
                            label: "选主图",
                            prompt: productionImageChoicePrompt(project: project, episode: episode, shot: shot)
                        ) : nil,
                        selected.map { selectedPath in
                            sendPromptButton(
                                label: "蒙版编辑",
                                prompt: "请打开这个短剧分镜主图做蒙版重绘。请调用 short_drama_open_image_editor，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString)、operation=inpaint、artifact_path=\(selectedPath)。打开后我会在右侧图片蒙版面板框选区域并提交 Replicate 或 some.im 编辑任务。"
                            )
                        },
                        selected.map { selectedPath in
                            sendPromptButton(
                                label: "擦除区域",
                                prompt: "请打开这个短剧分镜主图做蒙版擦除。请调用 short_drama_open_image_editor，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString)、operation=erase、artifact_path=\(selectedPath)。打开后我会在右侧图片蒙版面板框选需要擦除的区域并提交 Replicate 或 some.im 编辑任务。"
                            )
                        },
                        selected.map { selectedPath in
                            sendPromptButton(
                                label: "放大主图",
                                prompt: "请放大这个短剧分镜主图。请调用 short_drama_upscale_shot_artifact，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString)、artifact_path=\(selectedPath)。提交后请打开或提示我查看媒体任务侧栏。"
                            )
                        },
                        videoPath.map { path in
                            sendPromptButton(
                                label: "审片视频",
                                prompt: productionVideoReviewPrompt(project: project, episode: episode, shot: shot, videoPath: path)
                            )
                        },
                        selected == nil ? sendPromptButton(
                            label: "补主图",
                            prompt: "请为这个短剧分镜补主图。请先调用 short_drama_generate_shot_media，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString)、kind=image_generation、dry_run=true 预检；确认 prompt/model/endpoint 合理后，再用 dry_run=false 正式提交。提交后打开媒体任务侧栏。"
                        ) : nil,
                        videoCount == 0 ? sendPromptButton(
                            label: "补视频",
                            prompt: "请为这个短剧分镜补视频。请先调用 short_drama_generate_shot_media，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString)、kind=video_generation、dry_run=true 预检；如果缺少主图，请先补主图。确认参考图、prompt/model/endpoint 合理后，再用 dry_run=false 正式提交。提交后打开媒体任务侧栏。"
                        ) : nil,
                        reviewItemActionButton(project: project, episode: episode, shot: shot, selectedPath: selected),
                    ]
                        .compactMap { $0 }
                        .joined(separator: "")
                    let actionHTML = actions.isEmpty ? "" : "<div class=\"actions\">\(actions)</div>"
                    return """
                    <div class="shot-row">
                      <div class="shot-title">EP\(episode.order) · S\(shot.order) \(escapeHTML(shot.title))</div>
                      <div class="muted">\(escapeHTML(shot.status.displayName)) · \(escapeHTML(shot.summary ?? "无摘要"))</div>
                      <div class="badges">\(imageBadge)\(videoBadge)\(reviewBadge)</div>
                      \(actionHTML)
                    </div>
                    """
                }
            }
        return rows.prefix(80).joined(separator: "\n").isEmpty
            ? "<div class=\"muted\">暂无分镜时间线</div>"
            : rows.prefix(80).joined(separator: "\n")
    }

    private static func batchTimelineActionsHTML(for project: AgentShortDramaProject) -> String {
        let episodes = project.episodes.sorted(by: { $0.order < $1.order })
        let shots = episodes.flatMap { $0.shots }
        let missingImages = shots.filter { selectedImagePath(for: $0) == nil }.count
        let missingVideos = shots.filter { $0.artifactPaths.filter(isVideoPath).isEmpty }.count
        let episodeClause = episodes.count == 1 ? "、episode_id=\(episodes[0].id.uuidString)" : ""
        let scopeLabel = episodes.count == 1 ? "这一集" : "这个制作包范围"
        let reviewButton = sendPromptButton(
            label: "批量检查连续性",
            prompt: "请审查\(scopeLabel)内所有分镜的连续性和产物一致性。请读取 project_id=\(project.id.uuidString)\(episodeClause) 的短剧上下文，重点检查人物设定、服装道具、场景空间、镜头衔接、画风、主图/视频产物和 prompt 是否一致；发现具体问题时调用 short_drama_upsert_review_item 写回对应分镜，kind 可用 continuity、prompt、redraw、erase、upscale、reshoot 或 note；已经确认无问题的分镜不用写入。"
        )
        let imageButton = missingImages > 0 ? sendPromptButton(
            label: "批量补主图 \(missingImages)",
            prompt: "请为\(scopeLabel)批量补齐缺主图分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=\(project.id.uuidString)\(episodeClause)、kind=image_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，提交后打开媒体任务侧栏。"
        ) : ""
        let videoButton = missingVideos > 0 ? sendPromptButton(
            label: "批量补视频 \(missingVideos)",
            prompt: "请为\(scopeLabel)批量补齐缺视频分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=\(project.id.uuidString)\(episodeClause)、kind=video_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，视频生成应优先复用分镜主图作为首帧参考，提交后打开媒体任务侧栏。"
        ) : ""
        return reviewButton + imageButton + videoButton
    }

    private static func episodeSummaryHTML(for project: AgentShortDramaProject) -> String {
        let rows = project.episodes.sorted(by: { $0.order < $1.order }).map { episode in
            let shots = episode.shots.sorted(by: { $0.order < $1.order })
            let missingImages = shots.filter { selectedImagePath(for: $0) == nil }.count
            let missingVideos = shots.filter { $0.artifactPaths.filter(isVideoPath).isEmpty }.count
            let openReviewCount = shots.reduce(0) { total, shot in
                total + shot.reviewItems.filter { $0.status != .resolved }.count
            }
            let imageBadge = missingImages == 0
                ? "<span class=\"badge ok\">主图齐备</span>"
                : "<span class=\"badge warn\">缺主图 \(missingImages)</span>"
            let videoBadge = missingVideos == 0
                ? "<span class=\"badge ok\">视频齐备</span>"
                : "<span class=\"badge warn\">缺视频 \(missingVideos)</span>"
            let reviewBadge = openReviewCount == 0
                ? "<span class=\"badge ok\">检查项清零</span>"
                : "<span class=\"badge warn\">未解决 \(openReviewCount)</span>"
            let actions = [
                sendPromptButton(
                    label: "查看任务",
                    prompt: "请打开这一集的短剧媒体任务侧栏，并优先刷新同一范围的异步任务状态。请调用 short_drama_open_media_tasks，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、scope=episode；如果需要拉取最新 some.im / Replicate / 第三方异步状态，请随后调用 short_drama_refresh_media_tasks，参数相同。"
                ),
                sendPromptButton(
                    label: "本集分镜板",
                    prompt: "请打开这一集的短剧网页分镜板。请调用 short_drama_show_storyboard_widget，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)。"
                ),
                sendPromptButton(
                    label: "检查连续性",
                    prompt: "请审查这一集所有分镜的连续性和产物一致性。请读取 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString) 的短剧上下文，重点检查人物设定、服装道具、场景空间、镜头衔接、画风、主图/视频产物和 prompt 是否一致；发现具体问题时调用 short_drama_upsert_review_item 写回对应分镜。"
                ),
                missingImages > 0 ? sendPromptButton(
                    label: "补主图 \(missingImages)",
                    prompt: "请为这一集批量补齐缺主图分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、kind=image_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，提交后打开媒体任务侧栏。"
                ) : nil,
                missingVideos > 0 ? sendPromptButton(
                    label: "补视频 \(missingVideos)",
                    prompt: "请为这一集批量补齐缺视频分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、kind=video_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，视频生成应优先复用分镜主图作为首帧参考，提交后打开媒体任务侧栏。"
                ) : nil,
            ]
                .compactMap { $0 }
                .joined(separator: "")
            return """
            <div class="shot-row">
              <div class="shot-title">EP\(episode.order) · \(escapeHTML(episode.title))</div>
              <div class="muted">\(shots.count) 个分镜 · \(escapeHTML(episode.summary ?? "无摘要"))</div>
              <div class="badges"><span class="badge">分镜 \(shots.count)</span>\(imageBadge)\(videoBadge)\(reviewBadge)</div>
              <div class="actions">\(actions)</div>
            </div>
            """
        }
        let html = rows.prefix(80).joined(separator: "\n")
        return html.isEmpty ? "<div class=\"muted\">暂无分集</div>" : html
    }

    private static func assetSummaryHTML(for project: AgentShortDramaProject) -> String {
        let characterRows = project.characters.map { character in
            assetRowHTML(
                projectID: project.id.uuidString,
                kind: "character",
                kindLabel: "人物",
                id: character.id.uuidString,
                name: character.name,
                summary: character.description ?? character.visualPrompt,
                referenceImagePaths: character.referenceImagePaths
            )
        }
        let sceneRows = project.scenes.map { scene in
            assetRowHTML(
                projectID: project.id.uuidString,
                kind: "scene",
                kindLabel: "场景",
                id: scene.id.uuidString,
                name: scene.name,
                summary: scene.description ?? scene.visualPrompt,
                referenceImagePaths: scene.referenceImagePaths
            )
        }
        let rows = (characterRows + sceneRows).prefix(80).joined(separator: "\n")
        return rows.isEmpty ? "<div class=\"muted\">暂无人物或场景资产</div>" : rows
    }

    private static func assetRowHTML(
        projectID: String,
        kind: String,
        kindLabel: String,
        id: String,
        name: String,
        summary: String?,
        referenceImagePaths: [String]
    ) -> String {
        let referenceCount = referenceImagePaths.count
        let referenceBadge = referenceCount == 0
            ? "<span class=\"badge warn\">缺参考图</span>"
            : "<span class=\"badge ok\">参考图 \(referenceCount)</span>"
        let actions = [
            sendPromptButton(
                label: "查看任务",
                prompt: assetTasksPrompt(
                    projectID: projectID,
                    kind: kind,
                    kindLabel: kindLabel,
                    id: id,
                    name: name
                )
            ),
            referenceCount == 0 ? sendPromptButton(
                label: "生成参考图",
                prompt: "请为这个短剧\(kindLabel)资产生成参考图。请先调用 short_drama_generate_asset_media，并传入 project_id=\(projectID)、asset_kind=\(kind)、asset_id=\(id)、dry_run=true 预检；确认 prompt/model/endpoint 合理后，再用 dry_run=false 正式提交。提交后打开媒体任务侧栏，完成后参考图应回填到该资产。"
            ) : nil,
            referenceImagePaths.first.map { path in
                sendPromptButton(
                    label: "编辑参考图",
                    prompt: assetReferencePrompt(
                        action: "open_asset_reference_editor",
                        instruction: "请打开这个短剧\(kindLabel)资产的参考图做蒙版重绘。请调用 open_image_editor，并传入 image_path=\(path)、operation=inpaint、project_id=\(projectID)、asset_kind=\(kind)、asset_id=\(id)。打开后我会在右侧图片蒙版面板框选区域并提交 Replicate 或 some.im 编辑任务，完成产物应继续绑定到该资产参考图。",
                        projectID: projectID,
                        kind: kind,
                        kindLabel: kindLabel,
                        id: id,
                        name: name,
                        imagePath: path
                    )
                )
            },
            referenceImagePaths.first.map { path in
                sendPromptButton(
                    label: "擦除区域",
                    prompt: assetReferencePrompt(
                        action: "erase_asset_reference",
                        instruction: "请打开这个短剧\(kindLabel)资产的参考图做蒙版擦除。请调用 open_image_editor，并传入 image_path=\(path)、operation=erase、project_id=\(projectID)、asset_kind=\(kind)、asset_id=\(id)。打开后我会在右侧图片蒙版面板框选需要移除的区域并提交 Replicate 或 some.im 擦除任务，完成产物应继续绑定到该资产参考图。",
                        projectID: projectID,
                        kind: kind,
                        kindLabel: kindLabel,
                        id: id,
                        name: name,
                        imagePath: path
                    )
                )
            },
            referenceImagePaths.first.map { path in
                sendPromptButton(
                    label: "放大参考图",
                    prompt: assetReferencePrompt(
                        action: "upscale_asset_reference",
                        instruction: "请放大这个短剧\(kindLabel)资产的参考图。请调用 upscale_image，并传入 image_path=\(path)、project_id=\(projectID)、asset_kind=\(kind)、asset_id=\(id)。提交后打开或提示我查看该资产媒体任务侧栏，完成产物应继续绑定到该资产参考图。",
                        projectID: projectID,
                        kind: kind,
                        kindLabel: kindLabel,
                        id: id,
                        name: name,
                        imagePath: path
                    )
                )
            },
        ]
            .compactMap { $0 }
            .joined(separator: "")
        return """
        <div class="shot-row">
          <div class="shot-title">\(escapeHTML(kindLabel)) · \(escapeHTML(name))</div>
          <div class="muted">\(escapeHTML(summary ?? "无描述"))</div>
          <div class="badges">\(referenceBadge)</div>
          <div class="actions">\(actions)</div>
        </div>
        """
    }

    private static func assetReferencePrompt(
        action: String,
        instruction: String,
        projectID: String,
        kind: String,
        kindLabel: String,
        id: String,
        name: String,
        imagePath: String
    ) -> String {
        """
        \(instruction)

        <short-drama-asset-widget-action>
        action: \(action)
        project_id: \(projectID)
        asset_kind: \(kind)
        asset_kind_label: \(kindLabel)
        asset_id: \(id)
        asset_name: \(name)
        image_path: \(imagePath)
        open_tasks_tool: short_drama_open_media_tasks
        open_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(kind), asset_id=\(id)
        refresh_tasks_tool: short_drama_refresh_media_tasks
        refresh_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(kind), asset_id=\(id)
        generate_asset_reference_tool: short_drama_generate_asset_media
        generate_asset_reference_dry_run_arguments: project_id=\(projectID), asset_kind=\(kind), asset_id=\(id), dry_run=true
        generate_asset_reference_arguments: project_id=\(projectID), asset_kind=\(kind), asset_id=\(id), dry_run=false
        </short-drama-asset-widget-action>
        """
    }

    private static func assetTasksPrompt(
        projectID: String,
        kind: String,
        kindLabel: String,
        id: String,
        name: String
    ) -> String {
        """
        请打开这个短剧\(kindLabel)资产的媒体任务侧栏，并刷新同一资产的异步任务状态。请先调用 short_drama_open_media_tasks，再按需调用 short_drama_refresh_media_tasks，两个工具都使用 project_id=\(projectID)、scope=asset、asset_kind=\(kind)、asset_id=\(id)。如果参考图不足，也可以继续调用 short_drama_generate_asset_media 为该资产生成更多参考图。

        <short-drama-asset-widget-action>
        action: inspect_asset_media_tasks
        project_id: \(projectID)
        asset_kind: \(kind)
        asset_kind_label: \(kindLabel)
        asset_id: \(id)
        asset_name: \(name)
        open_tasks_tool: short_drama_open_media_tasks
        open_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(kind), asset_id=\(id)
        refresh_tasks_tool: short_drama_refresh_media_tasks
        refresh_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(kind), asset_id=\(id)
        generate_asset_reference_tool: short_drama_generate_asset_media
        generate_asset_reference_dry_run_arguments: project_id=\(projectID), asset_kind=\(kind), asset_id=\(id), dry_run=true
        generate_asset_reference_arguments: project_id=\(projectID), asset_kind=\(kind), asset_id=\(id), dry_run=false
        </short-drama-asset-widget-action>
        """
    }

    private static func productionImageChoicePrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot
    ) -> String {
        let baseArguments = "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString)"
        return """
        请打开这个短剧分镜的候选图选择器。请调用 short_drama_show_image_choice_widget，并传入 project_id=\(project.id.uuidString)、episode_id=\(episode.id.uuidString)、shot_id=\(shot.id.uuidString)。打开后我会在网页组件里选择主图；选择完成后请读取候选图组件输出的 post_select_* 字段继续衔接视频、蒙版重绘、擦除、放大或检查项关闭。

        <short-drama-production-image-choice>
        action: show_image_choice_widget
        project_id: \(project.id.uuidString)
        episode_id: \(episode.id.uuidString)
        shot_id: \(shot.id.uuidString)
        artifact_count: \(shot.artifactPaths.count)
        recommended_tool: short_drama_show_image_choice_widget
        recommended_arguments: \(baseArguments)
        post_select_video_tool: generate_video_from_image
        post_select_video_arguments: \(baseArguments), image_path=...
        post_select_edit_tool: short_drama_open_image_editor
        post_select_edit_arguments: \(baseArguments), artifact_path=..., operation=inpaint
        post_select_erase_tool: short_drama_open_image_editor
        post_select_erase_arguments: \(baseArguments), artifact_path=..., operation=erase
        post_select_upscale_tool: short_drama_upscale_shot_artifact
        post_select_upscale_arguments: \(baseArguments), artifact_path=...
        post_select_resolve_review_tool: short_drama_resolve_review_item
        post_select_resolve_review_arguments: \(baseArguments), item_id=...
        </short-drama-production-image-choice>
        """
    }

    static func sendPromptButton(label: String, prompt: String) -> String {
        let encodedPrompt = jsonStringLiteral(prompt)
        return "<button onclick=\"sendPrompt(\(encodedPrompt))\">\(escapeHTML(label))</button>"
    }

    private static func productionVideoReviewPrompt(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        videoPath: String
    ) -> String {
        let context = """
        <short-drama-production-video-action>
        action: review_shot_video_artifact
        project_id: \(project.id.uuidString)
        project_title: \(project.title)
        episode_id: \(episode.id.uuidString)
        episode_order: \(episode.order)
        episode_title: \(episode.title)
        shot_id: \(shot.id.uuidString)
        shot_order: \(shot.order)
        shot_title: \(shot.title)
        video_path: \(videoPath)
        open_shot_tasks_tool: short_drama_open_media_tasks
        open_shot_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=shot
        refresh_shot_tasks_tool: short_drama_refresh_media_tasks
        refresh_shot_tasks_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), scope=shot
        storyboard_widget_tool: short_drama_show_storyboard_widget
        storyboard_widget_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString)
        </short-drama-production-video-action>
        """
        return """
        请基于这个制作包分镜视频产物继续审片。请检查视频是否符合分镜提示词、人物/服装/场景连续性、运动节奏、镜头衔接和画面稳定性；若发现问题，请调用 short_drama_upsert_review_item 写回这个分镜。需要查看任务流水时，请优先使用下面的 open/refresh 结构化参数。

        \(context)
        """
    }

    private static func reviewItemActionButton(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        selectedPath: String?
    ) -> String? {
        guard let item = shot.reviewItems.first(where: { $0.status != .resolved }) else { return nil }
        let imagePath = selectedPath ?? selectedImagePath(for: shot) ?? ""
        let suggestedAction = item.suggestedAction ?? item.detail ?? ""
        let recommendation = productionReviewItemRecommendation(
            project: project,
            episode: episode,
            shot: shot,
            item: item,
            selectedPath: imagePath
        )
        var context = [
            "<short-drama-review-item-action>",
            "action: fix_production_review_item",
            "project_id: \(project.id.uuidString)",
            "episode_id: \(episode.id.uuidString)",
            "shot_id: \(shot.id.uuidString)",
            "shot_title: \(shot.title)",
            "selected_artifact_path: \(imagePath)",
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
            "resolve_review_arguments: project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString), item_id=\(item.id.uuidString)",
        ]
        if let secondary = recommendation.secondaryArguments {
            context.append("secondary_tool: \(recommendation.secondaryTool ?? recommendation.tool)")
            context.append("secondary_arguments: \(secondary)")
        }
        context.append("</short-drama-review-item-action>")
        let prompt = """
        请处理这个制作包分镜的具体检查项，并把后续媒体任务锚定到同一个 review_item_id。
        \(recommendation.hint)
        任务完成并确认修复后，请调用 short_drama_resolve_review_item，并传入 item_id 或 review_item_id。
        如需查看这条检查项的任务流水，请先调用 short_drama_open_media_tasks(scope=review_item, review_item_id=...)，需要同步最新异步状态时再调用 short_drama_refresh_media_tasks，参数相同。

        \(context.joined(separator: "\n"))
        """
        return sendPromptButton(label: "处理检查项", prompt: prompt)
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}
