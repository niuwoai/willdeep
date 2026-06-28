//
//  AgentShortDramaProductionReviewQueue.swift
//  WillDeep
//
//  CSV export for unresolved short-drama review items with executable handoff fields.
//

import Foundation

extension AgentShortDramaProductionExporter {
    static func reviewQueueCSV(for package: Package) -> String {
        let header = [
            "project_id",
            "project_title",
            "episode_id",
            "episode_order",
            "episode_title",
            "shot_id",
            "shot_order",
            "shot_title",
            "selected_image_path",
            "review_item_id",
            "kind",
            "severity",
            "review_status",
            "review_title",
            "detail",
            "suggested_action",
            "artifact_paths",
            "recommended_tool",
            "recommended_arguments",
            "secondary_tool",
            "secondary_arguments",
            "open_review_tasks_arguments",
            "refresh_review_tasks_arguments",
            "resolve_review_arguments",
            "shot_summary",
            "shot_prompt"
        ]
        var rows = [csvRow(header)]
        let project = package.project
        for episode in project.episodes.sorted(by: { $0.order < $1.order }) {
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                for item in shot.reviewItems where item.status != .resolved {
                    rows.append(reviewQueueRow(project: project, episode: episode, shot: shot, item: item))
                }
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func reviewQueueRow(
        project: AgentShortDramaProject,
        episode: AgentShortDramaEpisode,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) -> String {
        let selectedPath = selectedImagePath(for: shot) ?? ""
        let recommendation = productionReviewItemRecommendation(
            project: project,
            episode: episode,
            shot: shot,
            item: item,
            selectedPath: selectedPath
        )
        let baseArguments = "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString)"
        let reviewTasksArguments = "\(baseArguments), scope=review_item, review_item_id=\(item.id.uuidString)"
        return csvRow([
            project.id.uuidString,
            project.title,
            episode.id.uuidString,
            String(episode.order),
            episode.title,
            shot.id.uuidString,
            String(shot.order),
            shot.title,
            selectedPath,
            item.id.uuidString,
            item.kind.rawValue,
            item.severity.rawValue,
            item.status.rawValue,
            item.title,
            item.detail ?? "",
            item.suggestedAction ?? "",
            item.artifactPaths.joined(separator: "\n"),
            recommendation.tool,
            recommendation.arguments,
            recommendation.secondaryTool ?? "",
            recommendation.secondaryArguments ?? "",
            reviewTasksArguments,
            reviewTasksArguments,
            "\(baseArguments), item_id=\(item.id.uuidString)",
            shot.summary ?? "",
            shot.prompt ?? ""
        ])
    }

    static func reviewQueueActionItemsHTML(for project: AgentShortDramaProject) -> String {
        let rows = project.episodes
            .sorted(by: { $0.order < $1.order })
            .flatMap { episode in
                episode.shots.sorted(by: { $0.order < $1.order }).flatMap { shot in
                    shot.reviewItems
                        .filter { $0.status != .resolved }
                        .map { item in
                            let selectedPath = selectedImagePath(for: shot) ?? ""
                            let recommendation = productionReviewItemRecommendation(
                                project: project,
                                episode: episode,
                                shot: shot,
                                item: item,
                                selectedPath: selectedPath
                            )
                            let baseArguments = "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString)"
                            let reviewTasksArguments = "\(baseArguments), scope=review_item, review_item_id=\(item.id.uuidString)"
                            let resolveArguments = "\(baseArguments), item_id=\(item.id.uuidString)"
                            let prompt = """
                            请处理这个制作包修复队列检查项。请优先调用 recommended_tool 与 recommended_arguments；如果需要确认同一检查项的异步任务状态，先调用 open_review_tasks_tool；确认产物已经修复问题后，再调用 resolve_review_tool 关闭检查项。

                            <short-drama-review-queue-action>
                            action: fix_production_review_queue_item
                            project_id: \(project.id.uuidString)
                            episode_id: \(episode.id.uuidString)
                            shot_id: \(shot.id.uuidString)
                            review_item_id: \(item.id.uuidString)
                            review_kind: \(item.kind.rawValue)
                            review_severity: \(item.severity.rawValue)
                            review_title: \(item.title)
                            selected_artifact_path: \(selectedPath)
                            recommended_tool: \(recommendation.tool)
                            recommended_arguments: \(recommendation.arguments)
                            open_review_tasks_tool: short_drama_open_media_tasks
                            open_review_tasks_arguments: \(reviewTasksArguments)
                            resolve_review_tool: short_drama_resolve_review_item
                            resolve_review_arguments: \(resolveArguments)
                            </short-drama-review-queue-action>
                            """
                            return """
                            <li>
                              <strong>EP\(episode.order) · S\(shot.order) · \(escapeHTML(item.kind.rawValue)) / \(escapeHTML(item.severity.rawValue))</strong>
                              <div><code>recommended_tool=\(escapeHTML(recommendation.tool))</code></div>
                              <div><code>recommended_arguments=\(escapeHTML(recommendation.arguments))</code></div>
                              <div><code>open_review_tasks_arguments=\(escapeHTML(reviewTasksArguments))</code></div>
                              <div><code>resolve_review_arguments=\(escapeHTML(resolveArguments))</code></div>
                              <div class="actions">\(sendPromptButton(label: "交给聊天处理", prompt: prompt))</div>
                            </li>
                            """
                        }
                }
            }
            .prefix(20)
        return rows.joined(separator: "\n")
    }
}
