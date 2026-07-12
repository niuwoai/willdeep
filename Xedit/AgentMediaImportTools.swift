//
//  AgentMediaImportTools.swift
//  WillDeep
//
//  Tools that bridge local script output directories into the media task
//  registry. Useful for Ruby skills and third-party API scripts that download
//  images/videos before handing results back to WillDeep.
//

import Foundation

enum AgentMediaImportTools {
    static func importDirectory(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let directoryPath = try requiredString(arguments, "directory_path")
        let directoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentToolError.notFound(directoryURL.path)
        }

        let recursive = arguments["recursive"]?.boolValue() ?? false
        let maxFiles = min(max(arguments["max_files"]?.intValue() ?? 200, 1), 500)
        let artifacts = try mediaFiles(in: directoryURL, recursive: recursive, maxFiles: maxFiles)
        guard !artifacts.isEmpty else {
            return AgentToolResult(
                summary: "no media files imported",
                payload: "No supported image/video files found in \(directoryURL.path)."
            )
        }

        let kind = optionalString(arguments["kind"]).map(parseMediaKind) ?? inferredKind(for: artifacts)
        let provider = optionalString(arguments["provider"]).map(parseProvider) ?? .local
        let title = optionalString(arguments["title"]) ?? "Imported media: \(directoryURL.lastPathComponent)"
        let task = await MainActor.run {
            let created = registry.create(
                provider: provider,
                kind: kind,
                title: title,
                prompt: optionalString(arguments["prompt"]),
                model: optionalString(arguments["model"]),
                remoteTaskID: optionalString(arguments["remote_task_id"]),
                statusURL: optionalString(arguments["status_url"]),
                cancelURL: optionalString(arguments["cancel_url"]),
                statusEndpointSuffix: optionalString(arguments["status_endpoint_suffix"]),
                cancelEndpointSuffix: optionalString(arguments["cancel_endpoint_suffix"]),
                sourceImagePath: optionalString(arguments["source_image_path"]),
                maskPath: optionalString(arguments["mask_path"]),
                reviewItemID: optionalString(arguments["review_item_id"]),
                runtimeID: context.runtimeID,
                projectID: optionalString(arguments["project_id"]),
                projectPath: optionalString(arguments["project_path"]),
                episodeID: optionalString(arguments["episode_id"]),
                shotID: optionalString(arguments["shot_id"]),
                assetKind: optionalString(arguments["asset_kind"]),
                assetID: optionalString(arguments["asset_id"]),
                status: .submitted,
                statusMessage: "本地目录产物已导入。"
            )
            registry.update(id: created.id, status: .succeeded, progress: 1, artifacts: artifacts)
            return registry.task(matchingHandle: created.displayHandle, runtimeID: context.runtimeID) ?? created
        }

        let followUp = mediaDirectoryImportFollowUpLines(task: task)
        return AgentToolResult(
            summary: "imported \(artifacts.count) media artifact\(artifacts.count == 1 ? "" : "s"): \(task.displayHandle)",
            payload: """
            Imported media directory.

            Directory: \(directoryURL.path)
            Recursive: \(recursive)
            Imported files: \(artifacts.count)
            Task: \(task.displayHandle)
            Artifacts:
            \(artifacts.map(\.filePath).joined(separator: "\n"))
            \(followUp)
            """
        )
    }

    static func importManifest(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let manifestPath = try manifestPath(arguments)
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AgentToolError.notFound(manifestURL.path)
        }
        let widgetPreviewURL = widgetPreviewURL(arguments: arguments, manifestURL: manifestURL)
        let widgetPreviewHint = widgetPreviewHint(for: widgetPreviewURL)
        let gapReportURL = productionGapReportURL(arguments: arguments, manifestURL: manifestURL)
        let gapReportFollowUp = manifestImportFollowUpLines(tasks: [], pendingTasks: [], gapReportURL: gapReportURL)

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(MediaImportManifest.self, from: data)
        let baseURL = optionalString(arguments["base_directory"])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? manifest.baseDirectoryURL(relativeTo: manifestURL)
            ?? manifestURL.deletingLastPathComponent()
        let maxItems = min(max(arguments["max_items"]?.intValue() ?? 500, 1), 1000)
        let skipMissing = arguments["skip_missing"]?.boolValue() ?? true
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let importPendingTasks = arguments["import_pending_tasks"]?.boolValue() ?? false
        var skippedMissing: [String] = []
        var importedItems: [ManifestImportedItem] = []
        var pendingItems: [ManifestPendingItem] = []
        var failedItems: [ManifestFailedItem] = []
        for item in manifest.allItems.prefix(maxItems) {
            do {
                importedItems.append(
                    try importedManifestItem(
                        item,
                        manifest: manifest,
                        manifestURL: manifestURL,
                        baseURL: baseURL,
                        arguments: arguments
                    )
                )
            } catch AgentToolError.notFound(let path) where skipMissing {
                if importPendingTasks,
                   let pending = pendingManifestItem(
                    item,
                    manifest: manifest,
                    manifestURL: manifestURL,
                    missingPath: path,
                    arguments: arguments
                   ) {
                    pendingItems.append(pending)
                } else if let failed = failedManifestItem(
                    item,
                    manifest: manifest,
                    manifestURL: manifestURL,
                    missingPath: path,
                    arguments: arguments
                ) {
                    failedItems.append(failed)
                } else {
                    skippedMissing.append(path)
                }
            }
        }
        guard !importedItems.isEmpty || !pendingItems.isEmpty || !failedItems.isEmpty else {
            return AgentToolResult(
                summary: "no manifest media imported",
                payload: """
                No importable artifact files found in \(manifestURL.path).

                Base directory: \(baseURL.path)
                Missing files skipped: \(skippedMissing.count)
                \(widgetPreviewHint)
                \(gapReportFollowUp)
                \(skippedMissing.joined(separator: "\n"))
                """
            )
        }

        let grouped = Dictionary(grouping: importedItems, by: \.group)
        let pendingGrouped = Dictionary(grouping: pendingItems, by: \.group)
        let failedGrouped = Dictionary(grouping: failedItems, by: \.group)
        let previewLines = grouped
            .sorted { $0.key.sortKey < $1.key.sortKey }
            .map { group, items in
                "\(group.title): \(items.count) artifact\(items.count == 1 ? "" : "s") · provider=\(group.provider.displayName) · kind=\(group.kind.displayName) · project=\(group.projectID ?? "(none)") · episode=\(group.episodeID ?? "(none)") · shot=\(group.shotID ?? "(none)") · asset=\(group.assetKind ?? "(none)")/\(group.assetID ?? "(none)")"
            }
        let pendingPreviewLines = pendingGrouped
            .sorted { $0.key.sortKey < $1.key.sortKey }
            .map { group, items in
                "\(group.title): \(items.count) pending artifact\(items.count == 1 ? "" : "s") · provider=\(group.provider.displayName) · kind=\(group.kind.displayName) · remote=\(group.remoteTaskID ?? group.statusURL ?? "(none)") · project=\(group.projectID ?? "(none)") · episode=\(group.episodeID ?? "(none)") · shot=\(group.shotID ?? "(none)") · asset=\(group.assetKind ?? "(none)")/\(group.assetID ?? "(none)")"
            }
        let failedPreviewLines = failedGrouped
            .sorted { $0.key.sortKey < $1.key.sortKey }
            .map { group, items in
                "\(group.title): \(items.count) failed artifact\(items.count == 1 ? "" : "s") · provider=\(group.provider.displayName) · kind=\(group.kind.displayName) · error=\(group.lastError ?? "(none)") · project=\(group.projectID ?? "(none)") · episode=\(group.episodeID ?? "(none)") · shot=\(group.shotID ?? "(none)") · asset=\(group.assetKind ?? "(none)")/\(group.assetID ?? "(none)")"
            }
        let failedDryRunRecovery = failedManifestDryRunRecoveryLines(
            failedGrouped: failedGrouped,
            manifestURL: manifestURL
        )
        if dryRun {
            return AgentToolResult(
                summary: "dry-run manifest import: \(importedItems.count) artifact\(importedItems.count == 1 ? "" : "s"), \(pendingItems.count) pending task\(pendingItems.count == 1 ? "" : "s"), \(failedItems.count) failed task\(failedItems.count == 1 ? "" : "s"), \(grouped.count + pendingGrouped.count + failedGrouped.count) group\(grouped.count + pendingGrouped.count + failedGrouped.count == 1 ? "" : "s")",
                payload: """
                Dry-run media manifest import. No media tasks were created.

                Manifest: \(manifestURL.path)
                Base directory: \(baseURL.path)
                Importable files: \(importedItems.count)
                Pending remote tasks: \(pendingItems.count)
                Failed manifest tasks: \(failedItems.count)
                Missing files skipped: \(skippedMissing.count)
                \(widgetPreviewHint)
                \(gapReportFollowUp)
                \(failedDryRunRecovery)
                Groups:
                \(previewLines.joined(separator: "\n"))
                \(pendingPreviewLines.isEmpty ? "" : "\nPending remote task groups:\n\(pendingPreviewLines.joined(separator: "\n"))")
                \(failedPreviewLines.isEmpty ? "" : "\nFailed manifest task groups:\n\(failedPreviewLines.joined(separator: "\n"))")
                \(skippedMissing.isEmpty ? "" : "\nSkipped missing files:\n\(skippedMissing.joined(separator: "\n"))")
                """
            )
        }
        let completedTasks = await MainActor.run {
            grouped
                .sorted { $0.key.sortKey < $1.key.sortKey }
                .map { group, items in
                    let created = existingTask(for: group, registry: registry, runtimeID: context.runtimeID)
                        ?? registry.create(
                            provider: group.provider,
                            kind: group.kind,
                            title: group.title,
                            prompt: group.prompt,
                            model: group.model,
                            remoteTaskID: group.remoteTaskID,
                            statusURL: group.statusURL,
                            cancelURL: group.cancelURL,
                            statusEndpointSuffix: group.statusEndpointSuffix,
                            cancelEndpointSuffix: group.cancelEndpointSuffix,
                            sourceImagePath: group.sourceImagePath,
                            maskPath: group.maskPath,
                            reviewItemID: group.reviewItemID,
                            runtimeID: context.runtimeID,
                            projectID: group.projectID,
                            projectPath: group.projectPath,
                            episodeID: group.episodeID,
                            shotID: group.shotID,
                            assetKind: group.assetKind,
                            assetID: group.assetID,
                            status: .submitted,
                            statusMessage: "Manifest 产物已导入。"
                        )
                    registry.update(
                        id: created.id,
                        status: .succeeded,
                        progress: 1,
                        statusMessage: "Manifest 产物已导入。",
                        remoteTaskID: group.remoteTaskID,
                        statusURL: group.statusURL,
                        cancelURL: group.cancelURL,
                        statusEndpointSuffix: group.statusEndpointSuffix,
                        cancelEndpointSuffix: group.cancelEndpointSuffix,
                        sourceImagePath: group.sourceImagePath,
                        maskPath: group.maskPath,
                        reviewItemID: group.reviewItemID,
                        artifacts: items.map(\.artifact)
                    )
                    return registry.task(matchingHandle: created.displayHandle, runtimeID: context.runtimeID) ?? created
                }
        }
        let pendingTasks = await MainActor.run {
            pendingGrouped
                .sorted { $0.key.sortKey < $1.key.sortKey }
                .map { group, items in
                    if let existing = existingTask(for: group, registry: registry, runtimeID: context.runtimeID) {
                        registry.update(
                            id: existing.id,
                            statusMessage: "Manifest 远端异步任务已登记，等待产物生成。缺失占位文件 \(items.count) 个。",
                            remoteTaskID: group.remoteTaskID,
                            statusURL: group.statusURL,
                            cancelURL: group.cancelURL,
                            statusEndpointSuffix: group.statusEndpointSuffix,
                            cancelEndpointSuffix: group.cancelEndpointSuffix,
                            sourceImagePath: group.sourceImagePath,
                            maskPath: group.maskPath,
                            reviewItemID: group.reviewItemID
                        )
                        return registry.task(matchingHandle: existing.displayHandle, runtimeID: context.runtimeID) ?? existing
                    }
                    let created = registry.create(
                            provider: group.provider,
                            kind: group.kind,
                            title: group.title,
                            prompt: group.prompt,
                            model: group.model,
                            remoteTaskID: group.remoteTaskID,
                            statusURL: group.statusURL,
                            cancelURL: group.cancelURL,
                            statusEndpointSuffix: group.statusEndpointSuffix,
                            cancelEndpointSuffix: group.cancelEndpointSuffix,
                            sourceImagePath: group.sourceImagePath,
                            maskPath: group.maskPath,
                            reviewItemID: group.reviewItemID,
                            runtimeID: context.runtimeID,
                            projectID: group.projectID,
                            projectPath: group.projectPath,
                            episodeID: group.episodeID,
                            shotID: group.shotID,
                            assetKind: group.assetKind,
                            assetID: group.assetID,
                            status: .submitted,
                            statusMessage: "Manifest 远端异步任务已登记，等待产物生成。缺失占位文件 \(items.count) 个。"
                        )
                    return registry.task(matchingHandle: created.displayHandle, runtimeID: context.runtimeID) ?? created
                }
        }
        let failedTasks = await MainActor.run {
            failedGrouped
                .sorted { $0.key.sortKey < $1.key.sortKey }
                .map { group, items in
                    let statusMessage = failedStatusMessage(for: group, missingCount: items.count)
                    if let existing = existingTask(for: group, registry: registry, runtimeID: context.runtimeID) {
                        registry.update(
                            id: existing.id,
                            status: .failed,
                            statusMessage: statusMessage,
                            remoteTaskID: group.remoteTaskID,
                            statusURL: group.statusURL,
                            cancelURL: group.cancelURL,
                            statusEndpointSuffix: group.statusEndpointSuffix,
                            cancelEndpointSuffix: group.cancelEndpointSuffix,
                            sourceImagePath: group.sourceImagePath,
                            maskPath: group.maskPath,
                            reviewItemID: group.reviewItemID
                        )
                        return registry.task(matchingHandle: existing.displayHandle, runtimeID: context.runtimeID) ?? existing
                    }
                    let created = registry.create(
                        provider: group.provider,
                        kind: group.kind,
                        title: group.title,
                        prompt: group.prompt,
                        model: group.model,
                        remoteTaskID: group.remoteTaskID,
                        statusURL: group.statusURL,
                        cancelURL: group.cancelURL,
                        statusEndpointSuffix: group.statusEndpointSuffix,
                        cancelEndpointSuffix: group.cancelEndpointSuffix,
                        sourceImagePath: group.sourceImagePath,
                        maskPath: group.maskPath,
                        reviewItemID: group.reviewItemID,
                        runtimeID: context.runtimeID,
                        projectID: group.projectID,
                        projectPath: group.projectPath,
                        episodeID: group.episodeID,
                        shotID: group.shotID,
                        assetKind: group.assetKind,
                        assetID: group.assetID,
                        status: .failed,
                        statusMessage: statusMessage
                    )
                    return registry.task(matchingHandle: created.displayHandle, runtimeID: context.runtimeID) ?? created
                }
        }

        let tasks = completedTasks + pendingTasks + failedTasks
        let taskLines = tasks.map { "\($0.displayHandle): \($0.title) (\($0.artifacts.count) artifact\($0.artifacts.count == 1 ? "" : "s"), \($0.status.displayName))" }
        let followUp = manifestImportFollowUpLines(tasks: tasks, pendingTasks: pendingTasks, gapReportURL: gapReportURL)
        let widgetPreviewStatus = await queueWidgetPreviewIfAvailable(
            url: widgetPreviewURL,
            manifestURL: manifestURL,
            tasks: tasks,
            pendingTasks: pendingTasks,
            context: context
        )
        if let runtimeID = context.runtimeID {
            await MainActor.run {
                EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.recordAgentMediaImport(
                    manifestPath: manifestURL.path,
                    baseDirectory: baseURL.path,
                    packageDirectory: manifestURL.deletingLastPathComponent().path,
                    widgetPreviewPath: widgetPreviewURL?.path,
                    gapReportPath: gapReportURL?.path,
                    importedFileCount: importedItems.count,
                    pendingRemoteTaskCount: pendingItems.count,
                    failedManifestTaskCount: failedItems.count,
                    skippedMissingCount: skippedMissing.count,
                    tasks: tasks
                )
            }
        }
        return AgentToolResult(
            summary: "imported \(importedItems.count) manifest artifact\(importedItems.count == 1 ? "" : "s") and \(pendingItems.count) pending remote task\(pendingItems.count == 1 ? "" : "s") into \(tasks.count) media task\(tasks.count == 1 ? "" : "s")",
            payload: """
            Imported media manifest.

            Manifest: \(manifestURL.path)
            Base directory: \(baseURL.path)
            Imported files: \(importedItems.count)
            Pending remote tasks: \(pendingItems.count)
            Failed manifest tasks: \(failedItems.count)
            Missing files skipped: \(skippedMissing.count)
            Widget panel: \(widgetPreviewStatus)
            \(widgetPreviewHint)
            Tasks:
            \(taskLines.joined(separator: "\n"))
            \(followUp)
            \(skippedMissing.isEmpty ? "" : "\nSkipped missing files:\n\(skippedMissing.joined(separator: "\n"))")
            """
        )
    }

    private static func queueWidgetPreviewIfAvailable(
        url: URL?,
        manifestURL: URL,
        tasks: [AgentMediaTask],
        pendingTasks: [AgentMediaTask],
        context: AgentToolContext
    ) async -> String {
        guard let url else { return "not found" }
        guard let runtimeID = context.runtimeID else {
            return "not queued: no conversational runtime id"
        }
        do {
            let html = try String(contentsOf: url, encoding: .utf8)
            let byteCount = html.utf8.count
            guard byteCount <= 1_048_576 else {
                return "not queued: widget-preview.html is larger than 1 MB"
            }
            let packageDirectory = url.deletingLastPathComponent().path
            let packageURL = url.deletingLastPathComponent()
            let timelineURL = packageURL.appendingPathComponent("production-timeline.json", isDirectory: false)
            let gapReportURL = packageURL.appendingPathComponent("production-gap-report.json", isDirectory: false)
            let shotListURL = packageURL.appendingPathComponent("production-shot-list.csv", isDirectory: false)
            let reviewTemplateURL = packageURL.appendingPathComponent("production-review-template.csv", isDirectory: false)
            let reviewQueueURL = packageURL.appendingPathComponent("production-review-queue.csv", isDirectory: false)
            let failedTasks = tasks.filter { $0.status == .failed || $0.status == .canceled }
            let completedTasks = tasks.filter { $0.status == .succeeded }
            let projectScope = sharedProjectScope(for: tasks)
            let contextLines = [
                "<media-import-widget-handoff>",
                "action: import_media_manifest_widget_preview",
                "source_label: import-media-manifest",
                "source_path: \(url.path)",
                "package_directory: \(packageDirectory)",
                "manifest_path: \(manifestURL.path)",
                "task_count: \(tasks.count)",
                "pending_task_count: \(pendingTasks.count)",
                "failed_task_count: \(failedTasks.count)",
                "completed_task_count: \(completedTasks.count)",
                "task_ids: \(tasks.isEmpty ? "(none)" : tasks.map(\.displayHandle).joined(separator: ", "))",
                "pending_task_ids: \(pendingTasks.isEmpty ? "(none)" : pendingTasks.map(\.displayHandle).joined(separator: ", "))",
                "failed_task_ids: \(failedTasks.isEmpty ? "(none)" : failedTasks.map(\.displayHandle).joined(separator: ", "))",
                "media_task_status_tool: list_media_tasks",
                "media_task_status_arguments: only_active=false",
                "active_media_task_status_arguments: only_active=true",
                "widget_preview_path: \(url.path)",
                "timeline_path: \(timelineURL.path)",
                "gap_report_path: \(gapReportURL.path)",
                "shot_list_path: \(shotListURL.path)",
                "review_template_path: \(reviewTemplateURL.path)",
                "review_queue_path: \(reviewQueueURL.path)",
                "recommended_tool: import_media_manifest",
                "recommended_arguments: package_directory=\(packageDirectory), dry_run=true, import_pending_tasks=true",
                "submit_import_tool: import_media_manifest",
                "submit_import_arguments: package_directory=\(packageDirectory), dry_run=false, import_pending_tasks=true",
                "review_queue_import_tool: short_drama_import_review_csv",
                "review_queue_import_arguments: file_path=\(reviewQueueURL.path), dry_run=true",
            ] + projectMediaTaskHandoffLines(for: projectScope) + [
                "</media-import-widget-handoff>"
            ]
            let widget = AgentWidget(title: "短剧制作预览", html: html, contextLines: contextLines)
            await MainActor.run {
                AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
                let openMediaTasks = !pendingTasks.isEmpty || !failedTasks.isEmpty
                let mediaTaskScope = openMediaTasks ? projectScope : nil
                EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: openMediaTasks ? .mediaTasks : .widget, mediaTaskScope: mediaTaskScope)
            }
            let kbLabel = byteCount >= 1024 ? "\(byteCount / 1024) KB" : "\(byteCount) B"
            if !pendingTasks.isEmpty || !failedTasks.isEmpty {
                return "queued right-side widget (\(kbLabel)); opened media task side panel for pending/failed tasks"
            }
            return "queued right-side widget (\(kbLabel)); opened widget side panel"
        } catch {
            return "not queued: \(error.localizedDescription)"
        }
    }

    private static func sharedProjectScope(for tasks: [AgentMediaTask]) -> AgentMediaTaskScope? {
        let projectIDs = Set(tasks.compactMap { clean($0.projectID) ?? clean($0.projectPath) })
        guard projectIDs.count == 1, let projectID = projectIDs.first else {
            return nil
        }
        return AgentMediaTaskScope(label: "导回短剧项目任务", projectID: projectID)
    }

    private static func projectMediaTaskHandoffLines(for scope: AgentMediaTaskScope?) -> [String] {
        guard let projectID = clean(scope?.projectID), UUID(uuidString: projectID) != nil else {
            return []
        }
        return [
            "project_media_tasks_tool: short_drama_open_media_tasks",
            "project_media_tasks_arguments: project_id=\(projectID), scope=project",
            "refresh_project_media_tasks_tool: short_drama_refresh_media_tasks",
            "refresh_project_media_tasks_arguments: project_id=\(projectID), scope=project",
            "project_media_tasks_scope_label: \(scope?.label ?? "导回短剧项目任务")"
        ]
    }

    private static func manifestImportFollowUpLines(tasks: [AgentMediaTask], pendingTasks: [AgentMediaTask], gapReportURL: URL?) -> String {
        mediaImportFollowUpLines(
            action: "import_media_manifest_follow_up",
            tasks: tasks,
            pendingTasks: pendingTasks,
            gapReportURL: gapReportURL
        )
    }

    private static func failedManifestDryRunRecoveryLines(
        failedGrouped: [ManifestImportGroup: [ManifestFailedItem]],
        manifestURL: URL
    ) -> String {
        guard !failedGrouped.isEmpty else { return "" }
        let packageDirectory = manifestURL.deletingLastPathComponent().path
        let artifactCount = failedGrouped.values.reduce(0) { $0 + $1.count }
        let groupLines = failedGrouped
            .sorted { $0.key.sortKey < $1.key.sortKey }
            .prefix(12)
            .map { group, items in
                "- title=\(group.title) provider=\(group.provider.displayName) kind=\(group.kind.displayName) expected_missing=\(items.count) project=\(group.projectID ?? "(none)") episode=\(group.episodeID ?? "(none)") shot=\(group.shotID ?? "(none)") error=\(group.lastError ?? "(none)")"
            }
        return """

        <failed-manifest-dry-run-recovery>
        action: import_media_manifest_failed_dry_run_recovery
        failed_group_count: \(failedGrouped.count)
        failed_artifact_count: \(artifactCount)
        import_failed_tasks_tool: import_media_manifest
        import_failed_tasks_arguments: package_directory=\(packageDirectory), dry_run=false, import_pending_tasks=true
        failed_only_rerun_script: ruby-media-script-template.rb
        failed_only_rerun_env: WILLDEEP_MEDIA_ONLY_FAILED=1
        failed_only_rerun_follow_up: dry-run 阶段尚未创建侧栏失败任务；如要在侧栏中看到失败状态，先执行 import_failed_tasks_arguments。若外部 Ruby/Skill 脚本已修复，请用 failed_only_rerun_env 重跑失败项，再用 import_media_manifest(package_directory=\(packageDirectory), dry_run=true, import_pending_tasks=true) 预检。
        failed_manifest_groups:
        \(groupLines.joined(separator: "\n"))
        </failed-manifest-dry-run-recovery>
        """
    }

    private static func mediaDirectoryImportFollowUpLines(task: AgentMediaTask) -> String {
        mediaImportFollowUpLines(
            action: "import_media_directory_follow_up",
            tasks: [task],
            pendingTasks: [],
            gapReportURL: nil
        )
    }

    private static func mediaImportFollowUpLines(
        action: String,
        tasks: [AgentMediaTask],
        pendingTasks: [AgentMediaTask],
        gapReportURL: URL?
    ) -> String {
        guard !tasks.isEmpty || gapReportURL != nil else { return "" }
        var lines: [String] = [
            "",
            "<media-import-follow-up>",
            "action: \(action)",
            "task_ids: \(tasks.isEmpty ? "(none)" : tasks.map(\.displayHandle).joined(separator: ", "))"
        ]
        lines.append(contentsOf: projectMediaTaskHandoffLines(for: sharedProjectScope(for: tasks)))
        if !pendingTasks.isEmpty {
            lines.append("pending_task_ids: \(pendingTasks.map(\.displayHandle).joined(separator: ", "))")
            lines.append("pending_active_task_actions:")
            lines.append(contentsOf: pendingTasks.prefix(12).compactMap(AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine))
            lines.append("pending_active_task_follow_up: pending_active_task_actions 已包含可直接调用的 provider 轮询/取消参数；也可先用 scoped_pending_task_actions 中的 refresh_tasks_tool 刷新当前短剧范围。")
        }
        let failedTasks = tasks.filter { $0.status == .failed || $0.status == .canceled }
        if !failedTasks.isEmpty {
            lines.append("failed_task_ids: \(failedTasks.map(\.displayHandle).joined(separator: ", "))")
            lines.append("failed_task_recovery_actions:")
            lines.append(contentsOf: failedTasks.prefix(12).compactMap(AgentMediaTaskChatHandoff.failedTaskScopeSummaryLine))
            lines.append("failed_task_follow_up: failed_task_recovery_actions 已包含打开任务范围、可重试任务参数或 manifest/Ruby/Skill 失败项的 failed-only 重跑提示；处理前请先查看 status_message。")
        }
        if let gapReportURL {
            lines.append("production_gap_report_path: \(gapReportURL.path)")
            lines.append("production_gap_report_tool: short_drama_generate_batch_media")
            lines.append("production_gap_report_follow_up: 请先读取 production_gap_report_path，按 missing_image_count、missing_video_count 和 open_review_item_count 排序；正式提交补缺前先用 gap report 的 batch_actions 或 short_drama_generate_batch_media(target_filter=missing, dry_run=true) 预检。")
        }
        let scoped = pendingTasks.compactMap { task -> (AgentMediaTask, String)? in
            guard let arguments = shortDramaMediaTaskScopeArguments(for: task) else { return nil }
            return (task, arguments)
        }
        if !scoped.isEmpty {
            lines.append("scoped_pending_task_actions:")
            for (task, arguments) in scoped {
                lines.append("- task_id: \(task.displayHandle)")
                lines.append("  open_tasks_tool: short_drama_open_media_tasks")
                lines.append("  open_tasks_arguments: \(arguments)")
                lines.append("  refresh_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("  refresh_tasks_arguments: \(arguments)")
            }
        }
        let completedImageChoices = tasks.compactMap { task -> (AgentMediaTask, String, String)? in
            guard task.status == .succeeded else { return nil }
            let imagePaths = imageArtifactPaths(for: task)
            guard imagePaths.count > 1, let action = imageChoiceAction(for: task, imagePaths: imagePaths) else {
                return nil
            }
            return (task, action.tool, action.arguments)
        }
        if !completedImageChoices.isEmpty {
            lines.append("completed_image_choice_actions:")
            for (task, tool, arguments) in completedImageChoices {
                lines.append("- task_id: \(task.displayHandle)")
                lines.append("  image_choice_tool: \(tool)")
                lines.append("  image_choice_arguments: \(arguments)")
            }
        }
        let completedImageFollowUps = tasks.compactMap { task -> (AgentMediaTask, [String])? in
            guard task.status == .succeeded,
                  let imagePath = imageArtifactPaths(for: task).first else {
                return nil
            }
            let actions = completedImageFollowUpActions(for: task, imagePath: imagePath)
            return actions.isEmpty ? nil : (task, actions)
        }
        if !completedImageFollowUps.isEmpty {
            lines.append("completed_image_follow_up_actions:")
            for (task, actions) in completedImageFollowUps {
                lines.append("- task_id: \(task.displayHandle)")
                lines.append(contentsOf: actions.map { "  \($0)" })
            }
        }
        lines.append("</media-import-follow-up>")
        return lines.joined(separator: "\n")
    }

    private static func completedImageFollowUpActions(for task: AgentMediaTask, imagePath: String) -> [String] {
        let reopenActions = reopenImageEditorActions(for: task)
        if clean(task.projectID) != nil, clean(task.episodeID) != nil, clean(task.shotID) != nil {
            let artifactArguments = shortDramaArtifactArguments(for: task, pathKey: "artifact_path", imagePath: imagePath)
            let imageArguments = shortDramaArtifactArguments(for: task, pathKey: "image_path", imagePath: imagePath)
            let taskArguments = shortDramaShotTaskArguments(for: task)
            var actions = [
                "open_shot_tasks_tool: short_drama_open_media_tasks",
                "open_shot_tasks_arguments: \(taskArguments)",
                "select_primary_tool: short_drama_select_shot_artifact",
                "select_primary_arguments: \(artifactArguments)",
                "video_from_image_tool: generate_video_from_image",
                "video_from_image_arguments: \(imageArguments)",
                "edit_tool: short_drama_open_image_editor",
                "edit_arguments: \(artifactArguments), operation=inpaint",
                "erase_tool: short_drama_open_image_editor",
                "erase_arguments: \(artifactArguments), operation=erase",
                "upscale_tool: short_drama_upscale_shot_artifact",
                "upscale_arguments: \(artifactArguments)"
            ] + reopenActions
            if let reviewItemID = clean(task.reviewItemID) {
                actions.append("open_review_tasks_tool: short_drama_open_media_tasks")
                actions.append("open_review_tasks_arguments: \(shortDramaReviewTaskArguments(for: task, reviewItemID: reviewItemID))")
                actions.append("resolve_review_tool: short_drama_resolve_review_item")
                actions.append("resolve_review_arguments: \(shortDramaReviewArguments(for: task, reviewItemID: reviewItemID))")
            }
            return actions
        }
        if clean(task.projectID) != nil, clean(task.assetKind) != nil, clean(task.assetID) != nil {
            let imageArguments = shortDramaArtifactArguments(for: task, pathKey: "image_path", imagePath: imagePath)
            let taskArguments = assetTaskArguments(for: task)
            return [
                "open_asset_tasks_tool: short_drama_open_media_tasks",
                "open_asset_tasks_arguments: \(taskArguments)",
                "attach_reference_tool: short_drama_attach_asset_reference_image",
                "attach_reference_arguments: \(imageArguments)",
                "edit_tool: open_image_editor",
                "edit_arguments: \(imageArguments), operation=inpaint",
                "erase_tool: open_image_editor",
                "erase_arguments: \(imageArguments), operation=erase",
                "upscale_tool: upscale_image",
                "upscale_arguments: \(imageArguments)"
            ] + reopenActions
        }
        let imageArguments = genericImageArguments(for: task, imagePath: imagePath)
        return [
            "edit_tool: open_image_editor",
            "edit_arguments: \(imageArguments), operation=inpaint",
            "erase_tool: open_image_editor",
            "erase_arguments: \(imageArguments), operation=erase",
            "upscale_tool: upscale_image",
            "upscale_arguments: \(imageArguments)",
            "video_from_image_tool: generate_video_from_image",
            "video_from_image_arguments: \(imageArguments)"
        ] + reopenActions
    }

    private static func reopenImageEditorActions(for task: AgentMediaTask) -> [String] {
        guard isImageEditTask(task),
              let sourceImagePath = clean(task.sourceImagePath),
              let maskPath = clean(task.maskPath) else {
            return []
        }
        let operation = task.kind == .imageErase ? "erase" : "inpaint"
        if clean(task.projectID) != nil, clean(task.episodeID) != nil, clean(task.shotID) != nil {
            return [
                "reopen_editor_tool: short_drama_open_image_editor",
                "reopen_editor_arguments: \(shortDramaArtifactArguments(for: task, pathKey: "artifact_path", imagePath: sourceImagePath)), mask_path=\(maskPath), operation=\(operation)"
            ]
        }
        var pairs = [
            "image_path=\(sourceImagePath)",
            "mask_path=\(maskPath)",
            "operation=\(operation)"
        ]
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return [
            "reopen_editor_tool: open_image_editor",
            "reopen_editor_arguments: \(pairs.joined(separator: ", "))"
        ]
    }

    private static func isImageEditTask(_ task: AgentMediaTask) -> Bool {
        task.kind == .imageEdit || task.kind == .imageInpaint || task.kind == .imageErase
    }

    private static func shortDramaMediaTaskScopeArguments(for task: AgentMediaTask) -> String? {
        guard let projectID = clean(task.projectID) ?? clean(task.projectPath) else { return nil }
        var pairs = ["project_id=\(projectID)"]
        if let episodeID = clean(task.episodeID) {
            pairs.append("episode_id=\(episodeID)")
        }
        if let shotID = clean(task.shotID) {
            pairs.append("shot_id=\(shotID)")
        }
        if let assetKind = clean(task.assetKind), let assetID = clean(task.assetID) {
            pairs.append("asset_kind=\(assetKind)")
            pairs.append("asset_id=\(assetID)")
            pairs.append("scope=asset")
        } else if let reviewItemID = clean(task.reviewItemID) {
            pairs.append("review_item_id=\(reviewItemID)")
            pairs.append("scope=review_item")
        } else if clean(task.shotID) != nil {
            pairs.append("scope=shot")
        } else if clean(task.episodeID) != nil {
            pairs.append("scope=episode")
        } else {
            pairs.append("scope=project")
        }
        return pairs.joined(separator: ", ")
    }

    private static func imageChoiceAction(for task: AgentMediaTask, imagePaths: [String]) -> (tool: String, arguments: String)? {
        if clean(task.projectID) != nil, clean(task.episodeID) != nil, clean(task.shotID) != nil {
            return ("short_drama_show_image_choice_widget", shortDramaImageChoiceArguments(for: task))
        }
        var pairs = [
            "title=\(task.title)",
            "image_paths=\(imagePaths.joined(separator: " | "))"
        ]
        if let prompt = clean(task.prompt) {
            pairs.append("note=\(prompt)")
        }
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return ("show_image_choice_widget", pairs.joined(separator: ", "))
    }

    private static func shortDramaImageChoiceArguments(for task: AgentMediaTask) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func shortDramaArtifactArguments(for task: AgentMediaTask, pathKey: String, imagePath: String) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        pairs.append("\(pathKey)=\(imagePath)")
        return pairs.joined(separator: ", ")
    }

    private static func assetTaskArguments(for task: AgentMediaTask) -> String {
        var pairs = ["scope=asset"]
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func shortDramaShotTaskArguments(for task: AgentMediaTask) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        pairs.append("scope=shot")
        return pairs.joined(separator: ", ")
    }

    private static func shortDramaReviewTaskArguments(for task: AgentMediaTask, reviewItemID: String) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        pairs.append("scope=review_item")
        pairs.append("review_item_id=\(reviewItemID)")
        return pairs.joined(separator: ", ")
    }

    private static func shortDramaReviewArguments(for task: AgentMediaTask, reviewItemID: String) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        pairs.append("item_id=\(reviewItemID)")
        return pairs.joined(separator: ", ")
    }

    private static func genericImageArguments(for task: AgentMediaTask, imagePath: String) -> String {
        var pairs = ["image_path=\(imagePath)"]
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func imageArtifactPaths(for task: AgentMediaTask) -> [String] {
        task.artifacts
            .map(\.filePath)
            .filter { isImagePath($0) }
    }

    private static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [String]) {
        guard let value = clean(value) else { return }
        pairs.append("\(key)=\(value)")
    }

    private static func mediaFiles(in directoryURL: URL, recursive: Bool, maxFiles: Int) throws -> [AgentMediaArtifact] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let urls: [URL]
        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            urls = (enumerator?.compactMap { $0 as? URL } ?? [])
        } else {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        }

        return urls
            .filter { isSupportedMedia($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(maxFiles)
            .map { url in
                AgentMediaArtifact(
                    title: url.lastPathComponent,
                    filePath: url.standardizedFileURL.path,
                    mimeType: mimeType(for: url)
                )
            }
    }

    @MainActor
    private static func existingTask(
        for group: ManifestImportGroup,
        registry: AgentMediaTaskRegistry,
        runtimeID: UUID?
    ) -> AgentMediaTask? {
        let remoteKeys = [
            group.remoteTaskID,
            group.statusURL,
            group.cancelURL
        ].compactMap(normalizedRemoteKey)
        return registry.tasks(forRuntime: runtimeID).first { task in
            guard task.provider == group.provider,
                  task.kind == group.kind,
                  matchesAnchors(task, group: group) else {
                return false
            }
            if !remoteKeys.isEmpty {
                let taskKeys = [
                    task.remoteTaskID,
                    task.statusURL,
                    task.cancelURL
                ].compactMap(normalizedRemoteKey)
                return taskKeys.contains { remoteKeys.contains($0) }
            }
            return clean(task.title) == clean(group.title)
        }
    }

    private static func matchesAnchors(_ task: AgentMediaTask, group: ManifestImportGroup) -> Bool {
        clean(task.projectID) == clean(group.projectID)
            && clean(task.projectPath) == clean(group.projectPath)
            && clean(task.episodeID) == clean(group.episodeID)
            && clean(task.shotID) == clean(group.shotID)
            && clean(task.assetKind) == clean(group.assetKind)
            && clean(task.assetID) == clean(group.assetID)
    }

    private static func normalizedRemoteKey(_ value: String?) -> String? {
        clean(value)?.lowercased()
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func importedManifestItem(
        _ item: MediaImportManifest.Item,
        manifest: MediaImportManifest,
        manifestURL: URL,
        baseURL: URL,
        arguments: [String: AgentJSONValue]
    ) throws -> ManifestImportedItem {
        let filePath = try item.resolvedFilePath(baseURL: baseURL)
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentToolError.notFound(fileURL.path)
        }
        guard isSupportedMedia(fileURL) else {
            throw AgentToolError.invalidArgument("Unsupported media file in manifest \(manifestURL.path): \(fileURL.path)")
        }

        let artifact = AgentMediaArtifact(
            title: item.trimmedTitle ?? fileURL.lastPathComponent,
            filePath: fileURL.path,
            mimeType: item.trimmedMimeType ?? mimeType(for: fileURL),
            remoteURL: item.trimmedRemoteURL
        )
        let group = manifestImportGroup(
            item,
            manifest: manifest,
            manifestURL: manifestURL,
            arguments: arguments,
            fallbackKind: inferredKind(for: [artifact])
        )
        return ManifestImportedItem(group: group, artifact: artifact)
    }

    private static func pendingManifestItem(
        _ item: MediaImportManifest.Item,
        manifest: MediaImportManifest,
        manifestURL: URL,
        missingPath: String,
        arguments: [String: AgentJSONValue]
    ) -> ManifestPendingItem? {
        let group = manifestImportGroup(
            item,
            manifest: manifest,
            manifestURL: manifestURL,
            arguments: arguments,
            fallbackKind: inferredKind(forPath: missingPath)
        )
        guard group.remoteTaskID != nil || group.statusURL != nil else {
            return nil
        }
        return ManifestPendingItem(group: group, expectedFilePath: missingPath)
    }

    private static func failedManifestItem(
        _ item: MediaImportManifest.Item,
        manifest: MediaImportManifest,
        manifestURL: URL,
        missingPath: String,
        arguments: [String: AgentJSONValue]
    ) -> ManifestFailedItem? {
        let group = manifestImportGroup(
            item,
            manifest: manifest,
            manifestURL: manifestURL,
            arguments: arguments,
            fallbackKind: inferredKind(forPath: missingPath)
        )
        guard group.lastError != nil else {
            return nil
        }
        return ManifestFailedItem(group: group, expectedFilePath: missingPath)
    }

    private static func manifestImportGroup(
        _ item: MediaImportManifest.Item,
        manifest: MediaImportManifest,
        manifestURL: URL,
        arguments: [String: AgentJSONValue],
        fallbackKind: AgentMediaTaskKind
    ) -> ManifestImportGroup {
        let provider = optionalString(arguments["provider"]).map(parseProvider)
            ?? item.trimmedProvider.map(parseProvider)
            ?? manifest.trimmedProvider.map(parseProvider)
            ?? .skill
        let kind = optionalString(arguments["kind"]).map(parseMediaKind)
            ?? item.trimmedKind.map(parseMediaKind)
            ?? manifest.trimmedKind.map(parseMediaKind)
            ?? fallbackKind
        let taskTitle = item.trimmedTaskTitle
            ?? manifest.trimmedTitle
            ?? "Imported manifest: \(manifestURL.deletingPathExtension().lastPathComponent)"
        return ManifestImportGroup(
            provider: provider,
            kind: kind,
            title: taskTitle,
            prompt: item.trimmedPrompt ?? manifest.trimmedPrompt ?? optionalString(arguments["prompt"]),
            model: item.trimmedModel ?? manifest.trimmedModel ?? optionalString(arguments["model"]),
            remoteTaskID: item.trimmedRemoteTaskID ?? manifest.trimmedRemoteTaskID ?? optionalString(arguments["remote_task_id"]),
            statusURL: item.trimmedStatusURL ?? manifest.trimmedStatusURL ?? optionalString(arguments["status_url"]),
            cancelURL: item.trimmedCancelURL ?? manifest.trimmedCancelURL ?? optionalString(arguments["cancel_url"]),
            statusEndpointSuffix: item.trimmedStatusEndpointSuffix ?? manifest.trimmedStatusEndpointSuffix ?? optionalString(arguments["status_endpoint_suffix"]),
            cancelEndpointSuffix: item.trimmedCancelEndpointSuffix ?? manifest.trimmedCancelEndpointSuffix ?? optionalString(arguments["cancel_endpoint_suffix"]),
            sourceImagePath: item.trimmedSourceImagePath ?? manifest.trimmedSourceImagePath ?? optionalString(arguments["source_image_path"]),
            maskPath: item.trimmedMaskPath ?? manifest.trimmedMaskPath ?? optionalString(arguments["mask_path"]),
            reviewItemID: item.trimmedReviewItemID ?? manifest.trimmedReviewItemID ?? optionalString(arguments["review_item_id"]),
            lastError: item.trimmedLastError ?? manifest.trimmedLastError ?? optionalString(arguments["last_error"]),
            projectID: item.trimmedProjectID ?? manifest.trimmedProjectID ?? optionalString(arguments["project_id"]),
            projectPath: item.trimmedProjectPath ?? manifest.trimmedProjectPath ?? optionalString(arguments["project_path"]),
            episodeID: item.trimmedEpisodeID ?? manifest.trimmedEpisodeID ?? optionalString(arguments["episode_id"]),
            shotID: item.trimmedShotID ?? manifest.trimmedShotID ?? optionalString(arguments["shot_id"]),
            assetKind: item.trimmedAssetKind ?? manifest.trimmedAssetKind ?? optionalString(arguments["asset_kind"]),
            assetID: item.trimmedAssetID ?? manifest.trimmedAssetID ?? optionalString(arguments["asset_id"])
        )
    }

    private static func requiredString(_ arguments: [String: AgentJSONValue], _ key: String) throws -> String {
        guard let value = optionalString(arguments[key]) else {
            throw AgentToolError.missingArgument(key)
        }
        return value
    }

    private static func manifestPath(_ arguments: [String: AgentJSONValue]) throws -> String {
        if let manifestPath = optionalString(arguments["manifest_path"]) {
            return manifestPath
        }
        if let packageDirectory = optionalString(arguments["package_directory"]) {
            return URL(fileURLWithPath: packageDirectory)
                .standardizedFileURL
                .appendingPathComponent("media-import-manifest-template.json", isDirectory: false)
                .path
        }
        throw AgentToolError.missingArgument("manifest_path")
    }

    private static func widgetPreviewURL(arguments: [String: AgentJSONValue], manifestURL: URL) -> URL? {
        let candidate: URL
        if let packageDirectory = optionalString(arguments["package_directory"]) {
            candidate = URL(fileURLWithPath: packageDirectory)
                .standardizedFileURL
                .appendingPathComponent("widget-preview.html", isDirectory: false)
        } else {
            candidate = manifestURL.deletingLastPathComponent()
                .appendingPathComponent("widget-preview.html", isDirectory: false)
                .standardizedFileURL
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    private static func widgetPreviewHint(for url: URL?) -> String {
        guard let url else { return "" }
        let packageDirectory = url.deletingLastPathComponent().path
        return """
        Widget preview: \(url.path)
        To open it in WillDeep with import context, call show_widget with:
        {"tool":"show_widget","arguments":{"title":"短剧制作预览","html_path":"\(url.path)","source_label":"import-media-manifest","source_path":"\(url.path)","package_directory":"\(packageDirectory)","recommended_tool":"import_media_manifest","recommended_arguments":"package_directory=\(packageDirectory), dry_run=true, import_pending_tasks=true"}}
        """
    }

    private static func failedStatusMessage(for group: ManifestImportGroup, missingCount: Int) -> String {
        let error = group.lastError ?? "unknown error"
        return "Manifest 外部脚本失败：\(error)。缺失占位文件 \(missingCount) 个。"
    }

    private static func productionGapReportURL(arguments: [String: AgentJSONValue], manifestURL: URL) -> URL? {
        let candidate: URL
        if let packageDirectory = optionalString(arguments["package_directory"]) {
            candidate = URL(fileURLWithPath: packageDirectory)
                .standardizedFileURL
                .appendingPathComponent("production-gap-report.json", isDirectory: false)
        } else {
            candidate = manifestURL.deletingLastPathComponent()
                .appendingPathComponent("production-gap-report.json", isDirectory: false)
                .standardizedFileURL
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    private static func optionalString(_ value: AgentJSONValue?) -> String? {
        guard let string = value?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }

    nonisolated private static func isSupportedMedia(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased()) || videoExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static func inferredKind(for artifacts: [AgentMediaArtifact]) -> AgentMediaTaskKind {
        let paths = artifacts.map(\.filePath)
        let hasImages = paths.contains { imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        let hasVideos = paths.contains { videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        if hasVideos && !hasImages { return .videoGeneration }
        if hasImages && !hasVideos { return .imageGeneration }
        return .unknown
    }

    nonisolated private static func inferredKind(forPath path: String) -> AgentMediaTaskKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .imageGeneration }
        if videoExtensions.contains(ext) { return .videoGeneration }
        return .unknown
    }

    nonisolated private static func parseProvider(_ raw: String) -> AgentMediaTaskProvider {
        switch normalize(raw) {
        case "some_im", "someim", "some": return .someIM
        case "replicate": return .replicate
        case "kling", "kling_ai", "klingai", "可灵", "keling": return .kling
        case "skill", "skills": return .skill
        case "local": return .local
        default: return .unknown
        }
    }

    nonisolated private static func parseMediaKind(_ raw: String) -> AgentMediaTaskKind {
        switch normalize(raw) {
        case "image_generation", "image_generate", "generate_image": return .imageGeneration
        case "image_edit", "edit_image": return .imageEdit
        case "image_upscale", "upscale": return .imageUpscale
        case "image_erase", "erase", "remove": return .imageErase
        case "image_inpaint", "inpaint", "mask", "mask_edit": return .imageInpaint
        case "video_generation", "video_generate", "generate_video": return .videoGeneration
        case "short_drama", "shortdrama", "drama": return .shortDrama
        default: return .unknown
        }
    }

    nonisolated private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    nonisolated private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        default: return nil
        }
    }

    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"]
    nonisolated private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
}

private struct MediaImportManifest: Decodable {
    var title: String?
    var baseDirectory: String?
    var provider: String?
    var kind: String?
    var prompt: String?
    var model: String?
    var remoteTaskID: String?
    var statusURL: String?
    var cancelURL: String?
    var statusEndpointSuffix: String?
    var cancelEndpointSuffix: String?
    var sourceImagePath: String?
    var maskPath: String?
    var reviewItemID: String?
    var lastError: String?
    var projectID: String?
    var projectPath: String?
    var episodeID: String?
    var shotID: String?
    var assetKind: String?
    var assetID: String?
    var items: [Item]?
    var artifacts: [Item]?

    var allItems: [Item] { items ?? artifacts ?? [] }

    var trimmedTitle: String? { title.trimmedNonEmpty }
    var trimmedProvider: String? { provider.trimmedNonEmpty }
    var trimmedKind: String? { kind.trimmedNonEmpty }
    var trimmedPrompt: String? { prompt.trimmedNonEmpty }
    var trimmedModel: String? { model.trimmedNonEmpty }
    var trimmedRemoteTaskID: String? { remoteTaskID.trimmedNonEmpty }
    var trimmedStatusURL: String? { statusURL.trimmedNonEmpty }
    var trimmedCancelURL: String? { cancelURL.trimmedNonEmpty }
    var trimmedStatusEndpointSuffix: String? { statusEndpointSuffix.trimmedNonEmpty }
    var trimmedCancelEndpointSuffix: String? { cancelEndpointSuffix.trimmedNonEmpty }
    var trimmedSourceImagePath: String? { sourceImagePath.trimmedNonEmpty }
    var trimmedMaskPath: String? { maskPath.trimmedNonEmpty }
    var trimmedReviewItemID: String? { reviewItemID.trimmedNonEmpty }
    var trimmedLastError: String? { lastError.trimmedNonEmpty }
    var trimmedProjectID: String? { projectID.trimmedNonEmpty }
    var trimmedProjectPath: String? { projectPath.trimmedNonEmpty }
    var trimmedEpisodeID: String? { episodeID.trimmedNonEmpty }
    var trimmedShotID: String? { shotID.trimmedNonEmpty }
    var trimmedAssetKind: String? { assetKind.trimmedNonEmpty }
    var trimmedAssetID: String? { assetID.trimmedNonEmpty }

    func baseDirectoryURL(relativeTo manifestURL: URL) -> URL? {
        guard let baseDirectory = baseDirectory.trimmedNonEmpty else { return nil }
        if baseDirectory.hasPrefix("/") {
            return URL(fileURLWithPath: baseDirectory).standardizedFileURL
        }
        return manifestURL.deletingLastPathComponent().appendingPathComponent(baseDirectory).standardizedFileURL
    }

    enum CodingKeys: String, CodingKey {
        case title
        case baseDirectory = "base_directory"
        case provider, kind, prompt, model
        case remoteTaskID = "remote_task_id"
        case statusURL = "status_url"
        case cancelURL = "cancel_url"
        case statusEndpointSuffix = "status_endpoint_suffix"
        case cancelEndpointSuffix = "cancel_endpoint_suffix"
        case sourceImagePath = "source_image_path"
        case maskPath = "mask_path"
        case reviewItemID = "review_item_id"
        case lastError = "last_error"
        case projectID = "project_id"
        case projectPath = "project_path"
        case episodeID = "episode_id"
        case shotID = "shot_id"
        case assetKind = "asset_kind"
        case assetID = "asset_id"
        case items, artifacts
    }

    struct Item: Decodable {
        var filePath: String?
        var path: String?
        var title: String?
        var taskTitle: String?
        var mimeType: String?
        var remoteURL: String?
        var provider: String?
        var kind: String?
        var prompt: String?
        var model: String?
        var remoteTaskID: String?
        var statusURL: String?
        var cancelURL: String?
        var statusEndpointSuffix: String?
        var cancelEndpointSuffix: String?
        var sourceImagePath: String?
        var maskPath: String?
        var reviewItemID: String?
        var lastError: String?
        var projectID: String?
        var projectPath: String?
        var episodeID: String?
        var shotID: String?
        var assetKind: String?
        var assetID: String?

        var trimmedTitle: String? { title.trimmedNonEmpty }
        var trimmedTaskTitle: String? { taskTitle.trimmedNonEmpty }
        var trimmedMimeType: String? { mimeType.trimmedNonEmpty }
        var trimmedRemoteURL: String? { remoteURL.trimmedNonEmpty }
        var trimmedProvider: String? { provider.trimmedNonEmpty }
        var trimmedKind: String? { kind.trimmedNonEmpty }
        var trimmedPrompt: String? { prompt.trimmedNonEmpty }
        var trimmedModel: String? { model.trimmedNonEmpty }
        var trimmedRemoteTaskID: String? { remoteTaskID.trimmedNonEmpty }
        var trimmedStatusURL: String? { statusURL.trimmedNonEmpty }
        var trimmedCancelURL: String? { cancelURL.trimmedNonEmpty }
        var trimmedStatusEndpointSuffix: String? { statusEndpointSuffix.trimmedNonEmpty }
        var trimmedCancelEndpointSuffix: String? { cancelEndpointSuffix.trimmedNonEmpty }
        var trimmedSourceImagePath: String? { sourceImagePath.trimmedNonEmpty }
        var trimmedMaskPath: String? { maskPath.trimmedNonEmpty }
        var trimmedReviewItemID: String? { reviewItemID.trimmedNonEmpty }
        var trimmedLastError: String? { lastError.trimmedNonEmpty }
        var trimmedProjectID: String? { projectID.trimmedNonEmpty }
        var trimmedProjectPath: String? { projectPath.trimmedNonEmpty }
        var trimmedEpisodeID: String? { episodeID.trimmedNonEmpty }
        var trimmedShotID: String? { shotID.trimmedNonEmpty }
        var trimmedAssetKind: String? { assetKind.trimmedNonEmpty }
        var trimmedAssetID: String? { assetID.trimmedNonEmpty }

        func resolvedFilePath(baseURL: URL) throws -> String {
            guard let rawPath = filePath.trimmedNonEmpty ?? path.trimmedNonEmpty else {
                throw AgentToolError.missingArgument("file_path")
            }
            if rawPath.hasPrefix("/") {
                return URL(fileURLWithPath: rawPath).standardizedFileURL.path
            }
            let base = baseURL.standardizedFileURL
            let resolved = base.appendingPathComponent(rawPath).standardizedFileURL
            guard resolved.isInsideDirectory(base) else {
                throw AgentToolError.invalidArgument("Manifest file_path escapes base_directory: \(rawPath)")
            }
            return resolved.path
        }

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path"
            case path, title
            case taskTitle = "task_title"
            case mimeType = "mime_type"
            case remoteURL = "remote_url"
            case provider, kind, prompt, model
            case remoteTaskID = "remote_task_id"
            case statusURL = "status_url"
            case cancelURL = "cancel_url"
            case statusEndpointSuffix = "status_endpoint_suffix"
            case cancelEndpointSuffix = "cancel_endpoint_suffix"
            case sourceImagePath = "source_image_path"
            case maskPath = "mask_path"
            case reviewItemID = "review_item_id"
            case lastError = "last_error"
            case projectID = "project_id"
            case projectPath = "project_path"
            case episodeID = "episode_id"
            case shotID = "shot_id"
            case assetKind = "asset_kind"
            case assetID = "asset_id"
        }
    }
}

private struct ManifestImportGroup: Hashable {
    var provider: AgentMediaTaskProvider
    var kind: AgentMediaTaskKind
    var title: String
    var prompt: String?
    var model: String?
    var remoteTaskID: String?
    var statusURL: String?
    var cancelURL: String?
    var statusEndpointSuffix: String?
    var cancelEndpointSuffix: String?
    var sourceImagePath: String?
    var maskPath: String?
    var reviewItemID: String?
    var lastError: String?
    var projectID: String?
    var projectPath: String?
    var episodeID: String?
    var shotID: String?
    var assetKind: String?
    var assetID: String?

    var sortKey: String {
        [
            title,
            projectID,
            episodeID,
            shotID,
            reviewItemID,
            assetKind,
            assetID
        ].compactMap { $0 }.joined(separator: "|")
    }
}

private struct ManifestImportedItem {
    var group: ManifestImportGroup
    var artifact: AgentMediaArtifact
}

private struct ManifestPendingItem {
    var group: ManifestImportGroup
    var expectedFilePath: String
}

private struct ManifestFailedItem {
    var group: ManifestImportGroup
    var expectedFilePath: String
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension URL {
    func isInsideDirectory(_ directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let filePath = standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }
}
