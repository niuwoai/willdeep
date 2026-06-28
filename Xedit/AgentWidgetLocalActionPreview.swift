//
//  AgentWidgetLocalActionPreview.swift
//  WillDeep
//
//  Safe local UI previews for structured actions emitted by sandboxed widgets.
//  These helpers never submit paid/provider work or mutate review state; they
//  only open the relevant side panel or refresh already tracked media tasks.
//

import Foundation

@MainActor
extension AppState {
    func previewAgentWidgetToolActionLocally(_ action: AgentWidgetToolAction) {
        switch action.tool {
        case "short_drama_open_media_tasks", "short_drama_refresh_media_tasks", "list_media_tasks":
            previewWidgetMediaTasks(action)
        case "open_image_editor", "short_drama_open_image_editor":
            previewWidgetImageEditor(action)
        case "short_drama_show_storyboard_widget", "short_drama_show_image_choice_widget":
            previewShortDramaWidget(action)
        case "show_image_choice_widget":
            previewGenericImageChoiceWidget(action)
        case "show_widget":
            previewHTMLWidget(action)
        case "replicate_poll_prediction", "some_im_poll_media_task":
            previewRemoteTaskRefresh(action)
        case "replicate_cancel_prediction", "some_im_cancel_media_task":
            previewRemoteTaskInspect(action)
        default:
            break
        }
    }

    private func previewWidgetMediaTasks(_ action: AgentWidgetToolAction) {
        let fields = Self.widgetActionFields(action.arguments)
        let scope = Self.mediaTaskScope(from: fields)
        agentMediaTaskPanelScope = scope
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
        guard action.tool == "short_drama_refresh_media_tasks", let scope else { return }
        let taskIDs = agentMediaTaskRegistry.tasks(forRuntime: activeRuntime?.id)
            .filter { task in
                scope.matches(task)
                    && task.isActive
                    && (
                        task.provider == .replicate
                            || task.provider == .someIM
                            || AgentGenericMediaStatusClient.canPoll(task)
                    )
            }
            .map(\.id)
        guard !taskIDs.isEmpty else { return }
        Task {
            for taskID in taskIDs {
                await agentMediaTaskPoller.refreshNow(taskID: taskID, registry: agentMediaTaskRegistry)
            }
        }
    }

    private func previewWidgetImageEditor(_ action: AgentWidgetToolAction) {
        let fields = Self.widgetActionFields(action.arguments)
        guard let imagePath = fields["image_path"] ?? fields["artifact_path"] else { return }
        agentImageEditorPreferredOperation = fields["operation"] == "erase" ? .erase : .inpaint
        agentImageEditorContext = AgentImageEditorContext(
            projectID: fields["project_id"],
            episodeID: fields["episode_id"],
            shotID: fields["shot_id"],
            assetKind: fields["asset_kind"],
            assetID: fields["asset_id"],
            reviewItemID: fields["review_item_id"]
        )
        agentImageEditorMaskURL = fields["mask_path"].map { URL(fileURLWithPath: $0) }
        agentImageEditorImageURL = URL(fileURLWithPath: imagePath)
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .imageEditor)
    }

    private func previewShortDramaWidget(_ action: AgentWidgetToolAction) {
        guard let runtimeID = activeRuntime?.id else { return }
        let fields = Self.widgetActionFields(action.arguments)
        guard let projectID = Self.uuidField("project_id", in: fields),
              let project = agentShortDramaStore.project(id: projectID) else {
            return
        }
        let mediaTasks = agentMediaTaskRegistry.tasks(forRuntime: runtimeID)
        let widget: AgentWidget?
        if action.tool == "short_drama_show_image_choice_widget" {
            guard let episodeID = Self.uuidField("episode_id", in: fields),
                  let shotID = Self.uuidField("shot_id", in: fields),
                  let episode = project.episodes.first(where: { $0.id == episodeID }),
                  let shot = episode.shots.first(where: { $0.id == shotID }) else {
                return
            }
            widget = AgentShortDramaStoryboardWidgetBuilder.imageChoiceWidget(
                project: project,
                episode: episode,
                shot: shot,
                reviewItemID: fields["review_item_id"]
            )
        } else if let episodeID = Self.uuidField("episode_id", in: fields),
                  let episode = project.episodes.first(where: { $0.id == episodeID }) {
            widget = AgentShortDramaStoryboardWidgetBuilder.widget(for: project, episode: episode, mediaTasks: mediaTasks)
        } else {
            widget = AgentShortDramaStoryboardWidgetBuilder.widget(for: project, mediaTasks: mediaTasks)
        }
        guard let widget else { return }
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func previewGenericImageChoiceWidget(_ action: AgentWidgetToolAction) {
        guard let runtimeID = activeRuntime?.id else { return }
        let fields = Self.widgetActionFields(action.arguments)
        let imagePaths = Self.widgetImageChoicePaths(from: fields)
        guard !imagePaths.isEmpty else { return }
        let anchor = AgentImageChoiceWidgetBuilder.AnchorContext(
            projectID: fields["project_id"],
            episodeID: fields["episode_id"],
            shotID: fields["shot_id"],
            assetKind: fields["asset_kind"],
            assetID: fields["asset_id"],
            reviewItemID: fields["review_item_id"]
        )
        let widget = AgentImageChoiceWidgetBuilder.widget(
            title: fields["title"] ?? "图片候选选择",
            note: fields["note"],
            imagePaths: imagePaths,
            anchor: anchor,
            contextLines: [
                "<widget-tool-action-image-choice>",
                "action: show_image_choice_widget_from_send_tool_action",
                "source_tool: \(action.tool)",
                "image_count: \(imagePaths.count)",
                "widget_action_id: \(action.id.uuidString)",
                "</widget-tool-action-image-choice>"
            ]
        )
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func previewHTMLWidget(_ action: AgentWidgetToolAction) {
        guard let runtimeID = activeRuntime?.id else { return }
        let fields = Self.widgetActionFields(action.arguments)
        guard let rawPath = fields["html_path"],
              let url = AgentWidgetPathResolver.resolve(rawPath, workspaceRoot: widgetPreviewWorkspaceRoot()) else {
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              ["html", "htm", "svg"].contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url),
              data.count <= 1_048_576,
              let html = String(data: data, encoding: .utf8),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let widget = AgentWidget(
            title: fields["title"] ?? url.deletingPathExtension().lastPathComponent,
            html: html,
            contextLines: [
                "<widget-tool-action-html>",
                "action: show_widget_from_send_tool_action",
                "source_tool: \(action.tool)",
                "html_path: \(url.path)",
                "widget_action_id: \(action.id.uuidString)",
                "</widget-tool-action-html>"
            ]
        )
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func previewRemoteTaskRefresh(_ action: AgentWidgetToolAction) {
        let provider: AgentMediaTaskProvider = action.tool == "replicate_poll_prediction" ? .replicate : .someIM
        guard let task = widgetMediaTask(from: Self.widgetActionFields(action.arguments), provider: provider) else {
            agentMediaTaskPanelScope = nil
            agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            return
        }
        let scope = widgetMediaTaskScope(for: task)
        agentMediaTaskPanelScope = scope
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
        Task {
            await agentMediaTaskPoller.refreshNow(taskID: task.id, registry: agentMediaTaskRegistry)
        }
    }

    private func previewRemoteTaskInspect(_ action: AgentWidgetToolAction) {
        let provider: AgentMediaTaskProvider = action.tool == "replicate_cancel_prediction" ? .replicate : .someIM
        guard let task = widgetMediaTask(from: Self.widgetActionFields(action.arguments), provider: provider) else {
            agentMediaTaskPanelScope = nil
            agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            return
        }
        let scope = widgetMediaTaskScope(for: task)
        agentMediaTaskPanelScope = scope
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
    }

    private func widgetMediaTask(from fields: [String: String], provider: AgentMediaTaskProvider) -> AgentMediaTask? {
        let runtimeID = activeRuntime?.id
        for key in ["task_id", "media_task_id"] {
            if let handle = fields[key],
               let task = agentMediaTaskRegistry.task(matchingHandle: handle, runtimeID: runtimeID) {
                return task
            }
        }
        let remoteValues = ["prediction_id", "remote_task_id", "status_url", "cancel_url"]
            .compactMap { fields[$0].map(Self.cleanWidgetLookupValue) }
            .filter { !$0.isEmpty }
        guard !remoteValues.isEmpty else { return nil }
        return agentMediaTaskRegistry.tasks(forRuntime: runtimeID).first { task in
            guard task.provider == provider else { return false }
            let taskValues = [
                task.remoteTaskID,
                task.statusURL,
                task.cancelURL
            ].compactMap { $0.map(Self.cleanWidgetLookupValue) }
            return remoteValues.contains { value in
                taskValues.contains(value)
            }
        }
    }

    private func widgetMediaTaskScope(for task: AgentMediaTask) -> AgentMediaTaskScope? {
        if let projectID = task.projectID ?? task.projectPath, let reviewItemID = task.reviewItemID {
            return AgentMediaTaskScope(label: "检查项媒体任务", projectID: projectID, episodeID: task.episodeID, shotID: task.shotID, reviewItemID: reviewItemID)
        }
        if let projectID = task.projectID ?? task.projectPath, let assetKind = task.assetKind, let assetID = task.assetID {
            return AgentMediaTaskScope(label: "资产媒体任务", projectID: projectID, assetKind: assetKind, assetID: assetID)
        }
        if let projectID = task.projectID ?? task.projectPath, let episodeID = task.episodeID, let shotID = task.shotID {
            return AgentMediaTaskScope(label: "分镜媒体任务", projectID: projectID, episodeID: episodeID, shotID: shotID)
        }
        if let projectID = task.projectID ?? task.projectPath, let episodeID = task.episodeID {
            return AgentMediaTaskScope(label: "分集媒体任务", projectID: projectID, episodeID: episodeID)
        }
        if let projectID = task.projectID ?? task.projectPath {
            return AgentMediaTaskScope(label: "项目媒体任务", projectID: projectID)
        }
        return nil
    }

    private func widgetPreviewWorkspaceRoot() -> URL? {
        if let path = activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return rootDirectory?.standardizedFileURL
    }

    private static func mediaTaskScope(from fields: [String: String]) -> AgentMediaTaskScope? {
        let scopeKind = fields["scope"] ?? (fields["project_id"] == nil ? "all" : "project")
        switch scopeKind {
        case "all":
            return AgentMediaTaskScope(label: "全部媒体任务")
        case "review_item":
            guard let projectID = fields["project_id"], let reviewItemID = fields["review_item_id"] else { return nil }
            return AgentMediaTaskScope(label: "检查项媒体任务", projectID: projectID, episodeID: fields["episode_id"], shotID: fields["shot_id"], reviewItemID: reviewItemID)
        case "asset":
            guard let projectID = fields["project_id"], let assetKind = fields["asset_kind"], let assetID = fields["asset_id"] else { return nil }
            return AgentMediaTaskScope(label: "资产媒体任务", projectID: projectID, assetKind: assetKind, assetID: assetID)
        case "shot":
            guard let projectID = fields["project_id"], let episodeID = fields["episode_id"], let shotID = fields["shot_id"] else { return nil }
            return AgentMediaTaskScope(label: "分镜媒体任务", projectID: projectID, episodeID: episodeID, shotID: shotID)
        case "episode":
            guard let projectID = fields["project_id"], let episodeID = fields["episode_id"] else { return nil }
            return AgentMediaTaskScope(label: "分集媒体任务", projectID: projectID, episodeID: episodeID)
        default:
            guard let projectID = fields["project_id"] else { return nil }
            return AgentMediaTaskScope(label: "项目媒体任务", projectID: projectID)
        }
    }

    private static func widgetActionFields(_ arguments: String?) -> [String: String] {
        let raw = arguments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != "无额外参数" else { return [:] }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.reduce(into: [:]) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
        }
        var fields: [String: String] = [:]
        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") ?? trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    private static func widgetImageChoicePaths(from fields: [String: String]) -> [String] {
        let raw = fields["image_paths"] ?? fields["candidate_image_paths"] ?? fields["image_path"] ?? ""
        let separator: Character = raw.contains("|") ? "|" : ";"
        return raw
            .split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func uuidField(_ key: String, in fields: [String: String]) -> UUID? {
        fields[key].flatMap(UUID.init(uuidString:))
    }

    private static func cleanWidgetLookupValue(_ rawValue: String) -> String {
        AgentWidgetPathResolver.normalize(rawValue)
    }
}
