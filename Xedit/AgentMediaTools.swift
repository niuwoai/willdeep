//
//  AgentMediaTools.swift
//  WillDeep
//
//  Provider-neutral media task tools plus Replicate and some.im async media
//  adapters used by the Agent tool runner. Split out of AgentTools.swift so
//  media production workflows can grow without pushing the main dispatcher
//  past the repository line-count guardrails.
//

import Foundation

enum AgentMediaTools {
    // MARK: media tasks

    static func openImageEditor(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = cleanOptionalString(arguments["image_path"]) else {
            throw AgentToolError.missingArgument("image_path")
        }
        let imageURL = try resolveImageURL(rawPath, rootDirectory: context.rootDirectory)
        let maskURL = try cleanOptionalString(arguments["mask_path"]).map {
            try resolveImageURL($0, rootDirectory: context.rootDirectory)
        }
        let operation = parseImageEditorOperation(cleanOptionalString(arguments["operation"]) ?? "inpaint")
        guard let runtimeID = context.runtimeID,
              let appState = await MainActor.run(body: { EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) }) else {
            return AgentToolResult(
                summary: "image editor unavailable",
                payload: "open_image_editor is only available in conversational agent runtimes."
            )
        }
        await MainActor.run {
            appState.agentImageEditorPreferredOperation = operation
            appState.agentImageEditorContext = AgentImageEditorContext(
                projectID: cleanOptionalString(arguments["project_id"]),
                episodeID: cleanOptionalString(arguments["episode_id"]),
                shotID: cleanOptionalString(arguments["shot_id"]),
                assetKind: cleanOptionalString(arguments["asset_kind"]),
                assetID: cleanOptionalString(arguments["asset_id"]),
                reviewItemID: cleanOptionalString(arguments["review_item_id"])
            )
            appState.agentImageEditorMaskURL = maskURL
            appState.agentImageEditorImageURL = imageURL
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .imageEditor)
        }
        return AgentToolResult(
            summary: "opened image editor: \(imageURL.lastPathComponent)",
            payload: """
            Image editor opened.

            Image: \(imageURL.path)
            Seed mask: \(maskURL?.path ?? "(none)")
            Operation: \(operation == .erase ? "erase" : "inpaint")
            Optional short-drama anchors, when provided, will be preserved on submitted Replicate or some.im edit tasks.
            """
        )
    }

    static func upscaleImage(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        guard let rawPath = cleanOptionalString(arguments["image_path"]) else {
            throw AgentToolError.missingArgument("image_path")
        }
        let imageURL = try resolveImageURL(rawPath, rootDirectory: context.rootDirectory)
        let version = cleanOptionalString(arguments["version"]) ?? ReplicateIntegrationStore.loadWorkflowSettings().upscaleVersion
        guard !version.isEmpty else {
            throw AgentToolError.invalidArgument("Replicate upscale version is not configured. Set it in Settings -> Integrations -> Replicate or pass version.")
        }
        let prompt = cleanOptionalString(arguments["prompt"]) ?? "Upscale image: \(imageURL.lastPathComponent)"
        let inputJSON = try jsonString(from: ["image": dataURL(for: imageURL)])
        let prediction = try await ReplicateClient.createPrediction(version: version, inputJSON: inputJSON)
        let status = ReplicateClient.status(from: prediction.status)
        let title = "\(imageURL.deletingPathExtension().lastPathComponent) · Replicate 放大"
        let artifacts = status == .succeeded
            ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
            : []
        let task = await MainActor.run {
            registry.create(
                provider: .replicate,
                kind: .imageUpscale,
                title: title,
                prompt: prompt,
                model: version,
                remoteTaskID: prediction.id,
                statusURL: prediction.urls?.get,
                cancelURL: prediction.urls?.cancel,
                sourceImagePath: imageURL.path,
                reviewItemID: cleanOptionalString(arguments["review_item_id"]),
                runtimeID: context.runtimeID,
                projectID: cleanOptionalString(arguments["project_id"]),
                episodeID: cleanOptionalString(arguments["episode_id"]),
                shotID: cleanOptionalString(arguments["shot_id"]),
                assetKind: cleanOptionalString(arguments["asset_kind"]),
                assetID: cleanOptionalString(arguments["asset_id"]),
                status: status,
                statusMessage: ReplicateClient.statusMessage(for: prediction)
            )
        }
        if !artifacts.isEmpty {
            await MainActor.run {
                registry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
        }
        let updated = await MainActor.run {
            registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID) ?? task
        }
        if let runtimeID = context.runtimeID {
            await MainActor.run {
                EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            }
        }
        return AgentToolResult(
            summary: "submitted image upscale: \(updated.displayHandle)",
            payload: """
            Image upscale submitted.

            Source image: \(imageURL.path)
            Task: \(updated.displayHandle)
            Provider: Replicate
            Status: \(status.displayName)
            Remote task id: \(prediction.id)
            Status URL: \(prediction.urls?.get ?? "(none)")
            Cancel URL: \(prediction.urls?.cancel ?? "(none)")
            \(mediaTaskToolFollowUp(task: updated, action: "upscale_image_follow_up"))
            """
        )
    }

    static func editImageWithMask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        guard let rawImagePath = cleanOptionalString(arguments["image_path"]) else {
            throw AgentToolError.missingArgument("image_path")
        }
        guard let rawMaskPath = cleanOptionalString(arguments["mask_path"]) else {
            throw AgentToolError.missingArgument("mask_path")
        }
        let imageURL = try resolveImageURL(rawImagePath, rootDirectory: context.rootDirectory)
        let maskURL = try resolveImageURL(rawMaskPath, rootDirectory: context.rootDirectory)
        let operation = parseImageEditorOperation(cleanOptionalString(arguments["operation"]) ?? "inpaint")
        let prompt = try maskEditPrompt(arguments: arguments, operation: operation)
        let provider = normalizedMediaToken(cleanOptionalString(arguments["provider"]) ?? "replicate")
        switch provider {
        case "some_im", "someim", "some":
            return try await submitSomeIMMaskEdit(
                arguments: arguments,
                context: context,
                registry: registry,
                imageURL: imageURL,
                maskURL: maskURL,
                operation: operation,
                prompt: prompt
            )
        case "replicate", "":
            return try await submitReplicateMaskEdit(
                arguments: arguments,
                context: context,
                registry: registry,
                imageURL: imageURL,
                maskURL: maskURL,
                operation: operation,
                prompt: prompt
            )
        default:
            throw AgentToolError.invalidArgument("provider must be replicate or some_im.")
        }
    }

    static func generateVideoFromImage(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = cleanOptionalString(arguments["image_path"]) else {
            throw AgentToolError.missingArgument("image_path")
        }
        let imageURL = try resolveImageURL(rawPath, rootDirectory: context.rootDirectory)
        let prompt = cleanOptionalString(arguments["prompt"]) ?? "Generate a short video from this keyframe image."
        let engine = AgentVideoGenerationEngine.parse(arguments: arguments)
        if engine == .kling {
            return klingVideoFromImageHandoff(
                arguments: arguments,
                context: context,
                imageURL: imageURL,
                prompt: prompt
            )
        }
        var mediaArguments: [String: AgentJSONValue] = [
            "kind": .string("video_generation"),
            "prompt": .string(prompt),
            "reference_image_path": .string(imageURL.path),
            "source_image_path": .string(imageURL.path),
            "title": .string(cleanOptionalString(arguments["title"]) ?? "\(imageURL.deletingPathExtension().lastPathComponent) · some.im 图生视频")
        ]
        if cleanOptionalString(arguments["model"]) == nil {
            mediaArguments["model"] = .string(AgentVideoGenerationEngine.defaultSeedanceModel)
        }
        for key in ["model", "endpoint_suffix", "project_id", "episode_id", "shot_id", "asset_kind", "asset_id", "review_item_id"] {
            if let value = arguments[key] {
                mediaArguments[key] = value
            }
        }
        return try await someIMCreateMediaTask(arguments: mediaArguments, context: context)
    }

    static func editGeneratedImage(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let rawPath = cleanOptionalString(arguments["image_path"])
            ?? cleanOptionalString(arguments["reference_image_path"])
            ?? cleanOptionalString(arguments["source_image_path"])
            ?? cleanOptionalString(arguments["reference_marker"]).flatMap { marker in
                AgentGeneratedImageReference.path(from: marker)
            }
        guard let rawPath else {
            throw AgentToolError.missingArgument("image_path")
        }
        guard let prompt = cleanOptionalString(arguments["prompt"]) else {
            throw AgentToolError.missingArgument("prompt")
        }
        let imageURL = try resolveImageURL(rawPath, rootDirectory: context.rootDirectory)
        var mediaArguments = arguments
        mediaArguments["kind"] = .string("image_edit")
        mediaArguments["prompt"] = .string(prompt)
        mediaArguments["reference_image_path"] = .string(imageURL.path)
        mediaArguments["source_image_path"] = .string(imageURL.path)
        mediaArguments["endpoint_suffix"] = .string(cleanOptionalString(arguments["endpoint_suffix"]) ?? "images/edits")
        if cleanOptionalString(arguments["model"]) == nil {
            mediaArguments["model"] = .string(SomeIMIntegrationSettings.defaultImageModel)
        }
        if cleanOptionalString(arguments["title"]) == nil {
            mediaArguments["title"] = .string("\(imageURL.deletingPathExtension().lastPathComponent) · some.im 图片编辑")
        }
        return try await someIMCreateMediaTask(arguments: mediaArguments, context: context)
    }

    private static func submitReplicateMaskEdit(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        registry: AgentMediaTaskRegistry,
        imageURL: URL,
        maskURL: URL,
        operation: AgentImageEditorOperationPreference,
        prompt: String
    ) async throws -> AgentToolResult {
        let version = cleanOptionalString(arguments["version"]) ?? replicateMaskEditVersion(for: operation)
        guard let version, !version.isEmpty else {
            let label = operation == .erase ? "图片擦除" : "蒙版重绘"
            throw AgentToolError.invalidArgument("Replicate \(label) version is not configured. Set it in Settings -> Integrations -> Replicate or pass version.")
        }
        let inputJSON = try jsonString(from: [
            "image": dataURL(for: imageURL),
            "mask": dataURL(for: maskURL),
            "prompt": prompt,
        ])
        let prediction = try await ReplicateClient.createPrediction(version: version, inputJSON: inputJSON)
        let status = ReplicateClient.status(from: prediction.status)
        let title = cleanOptionalString(arguments["title"]) ?? "\(imageURL.deletingPathExtension().lastPathComponent) · Replicate \(maskEditTitle(for: operation))"
        let artifacts = status == .succeeded
            ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
            : []
        let task = await MainActor.run {
            registry.create(
                provider: .replicate,
                kind: maskEditKind(for: operation),
                title: title,
                prompt: prompt,
                model: version,
                remoteTaskID: prediction.id,
                statusURL: prediction.urls?.get,
                cancelURL: prediction.urls?.cancel,
                sourceImagePath: imageURL.path,
                maskPath: maskURL.path,
                reviewItemID: cleanOptionalString(arguments["review_item_id"]),
                runtimeID: context.runtimeID,
                projectID: cleanOptionalString(arguments["project_id"]),
                episodeID: cleanOptionalString(arguments["episode_id"]),
                shotID: cleanOptionalString(arguments["shot_id"]),
                assetKind: cleanOptionalString(arguments["asset_kind"]),
                assetID: cleanOptionalString(arguments["asset_id"]),
                status: status,
                statusMessage: ReplicateClient.statusMessage(for: prediction)
            )
        }
        if !artifacts.isEmpty {
            await MainActor.run {
                registry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
        }
        let updated = await MainActor.run {
            registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID) ?? task
        }
        await recordImageEditSubmission(task: updated, context: context)
        await openMediaTaskPanelIfPossible(context: context)
        return AgentToolResult(
            summary: "submitted masked image edit: \(updated.displayHandle)",
            payload: maskEditResultPayload(
                task: updated,
                provider: "Replicate",
                status: status,
                imageURL: imageURL,
                maskURL: maskURL,
                remoteTaskID: prediction.id,
                statusURL: prediction.urls?.get,
                cancelURL: prediction.urls?.cancel,
                followUpAction: "edit_image_with_mask_follow_up"
            )
        )
    }

    private static func submitSomeIMMaskEdit(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        registry: AgentMediaTaskRegistry,
        imageURL: URL,
        maskURL: URL,
        operation: AgentImageEditorOperationPreference,
        prompt: String
    ) async throws -> AgentToolResult {
        let settings = SomeIMIntegrationStore.loadSettings()
        let model = cleanOptionalString(arguments["model"])
            ?? SomeIMAsyncMediaClient.defaultModel(for: maskEditKind(for: operation), settings: settings)
        let endpointSuffix = cleanOptionalString(arguments["endpoint_suffix"]) ?? "images/edits"
        let response = try await SomeIMAsyncMediaClient.submit(
            endpointSuffix: endpointSuffix,
            body: [
                "model": model,
                "prompt": prompt,
                "image": try dataURL(for: imageURL),
                "mask": try dataURL(for: maskURL),
                "response_format": "b64_json",
            ],
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let title = cleanOptionalString(arguments["title"]) ?? "\(imageURL.deletingPathExtension().lastPathComponent) · some.im \(maskEditTitle(for: operation))"
        let outputDirectory = try mediaOutputDirectory(arguments: arguments, rootDirectory: context.rootDirectory)
        let artifacts = status == .succeeded
            ? try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title, outputDirectory: outputDirectory).map(\.mediaArtifact)
            : []
        let task = await MainActor.run {
            registry.create(
                provider: .someIM,
                kind: maskEditKind(for: operation),
                title: title,
                prompt: prompt,
                model: model,
                remoteTaskID: response.id,
                statusURL: response.statusURL,
                cancelURL: response.cancelURL,
                statusEndpointSuffix: endpointSuffix,
                cancelEndpointSuffix: endpointSuffix,
                sourceImagePath: imageURL.path,
                maskPath: maskURL.path,
                reviewItemID: cleanOptionalString(arguments["review_item_id"]),
                runtimeID: context.runtimeID,
                projectID: cleanOptionalString(arguments["project_id"]),
                episodeID: cleanOptionalString(arguments["episode_id"]),
                shotID: cleanOptionalString(arguments["shot_id"]),
                assetKind: cleanOptionalString(arguments["asset_kind"]),
                assetID: cleanOptionalString(arguments["asset_id"]),
                status: status,
                statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response)
            )
        }
        if !artifacts.isEmpty {
            await MainActor.run {
                registry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
        }
        let updated = await MainActor.run {
            registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID) ?? task
        }
        await recordImageEditSubmission(task: updated, context: context)
        await openMediaTaskPanelIfPossible(context: context)
        let resultImages = AgentGeneratedImageAttachmentFactory.attachments(
            from: updated.artifacts,
            model: model,
            prompt: prompt
        )
        return AgentToolResult(
            summary: "submitted masked image edit: \(updated.displayHandle)",
            payload: maskEditResultPayload(
                task: updated,
                provider: "some.im",
                status: status,
                imageURL: imageURL,
                maskURL: maskURL,
                remoteTaskID: response.id,
                statusURL: response.statusURL,
                cancelURL: response.cancelURL,
                followUpAction: "edit_image_with_mask_follow_up"
            ),
            images: resultImages
        )
    }

    private static func recordImageEditSubmission(task: AgentMediaTask, context: AgentToolContext) async {
        guard let runtimeID = context.runtimeID else { return }
        await MainActor.run {
            EditorAppStateRegistry.shared
                .appState(forRuntime: runtimeID)?
                .recordAgentImageEditSubmission(task: task)
        }
    }

    static func showImageChoiceWidget(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "image choice widget unavailable",
                payload: "show_image_choice_widget is only available in conversational agent runtimes."
            )
        }
        let rawPaths = arguments["image_paths"]?.stringArrayValue() ?? []
        let imagePaths = try rawPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { try resolveImageURL($0, rootDirectory: context.rootDirectory).path }
        guard !imagePaths.isEmpty else {
            throw AgentToolError.missingArgument("image_paths")
        }
        let title = cleanOptionalString(arguments["title"]) ?? "图片候选选择"
        let note = cleanOptionalString(arguments["note"])
        let anchor = AgentImageChoiceWidgetBuilder.AnchorContext(
            projectID: cleanOptionalString(arguments["project_id"]),
            episodeID: cleanOptionalString(arguments["episode_id"]),
            shotID: cleanOptionalString(arguments["shot_id"]),
            assetKind: cleanOptionalString(arguments["asset_kind"]),
            assetID: cleanOptionalString(arguments["asset_id"]),
            reviewItemID: cleanOptionalString(arguments["review_item_id"])
        )
        let contextLines = try imageChoiceWidgetContextLines(arguments: arguments, imageCount: imagePaths.count)
        let widget = AgentImageChoiceWidgetBuilder.widget(
            title: title,
            note: note,
            imagePaths: imagePaths,
            anchor: anchor,
            contextLines: contextLines
        )
        await MainActor.run {
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
        }
        return AgentToolResult(
            summary: "queued image choice widget: \(imagePaths.count) images",
            payload: """
            Image choice widget queued.

            Title: \(title)
            Image count: \(imagePaths.count)
            \(widget.contextBlock)
            The user can click a candidate; the widget will send an <image-choice> block with image_path plus recommended_tool / recommended_arguments and post_select_* follow-up actions back to chat when available. Prefer post_select_action_keys and the structured post_select_* fields for follow-up editing, erasing, upscaling, video generation, task refresh/open actions, review resolution, or short-drama shot/asset selection.
            """
        )
    }

    private static func imageChoiceWidgetContextLines(
        arguments: [String: AgentJSONValue],
        imageCount: Int
    ) throws -> [String] {
        let mappings: [(String, String)] = [
            ("source_label", "source_label"),
            ("source_path", "source_path"),
            ("package_directory", "package_directory"),
            ("widget_context", "widget_context"),
            ("recommended_tool", "recommended_tool"),
            ("recommended_arguments", "recommended_arguments"),
            ("project_id", "project_id"),
            ("episode_id", "episode_id"),
            ("shot_id", "shot_id"),
            ("asset_kind", "asset_kind"),
            ("asset_id", "asset_id"),
            ("review_item_id", "review_item_id")
        ]
        var lines: [String] = ["image_count: \(imageCount)"]
        for (argumentName, lineName) in mappings {
            guard let value = cleanOptionalString(arguments[argumentName]) else { continue }
            guard value.utf8.count <= 2_000 else {
                throw AgentToolError.invalidArgument("\(argumentName) must be 2 KB or smaller.")
            }
            lines.append("\(lineName): \(value)")
        }
        if lines.joined(separator: "\n").utf8.count > 8_000 {
            throw AgentToolError.invalidArgument("show_image_choice_widget context metadata must be 8 KB or smaller.")
        }
        return lines
    }

    static func createMediaTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        guard let rawProvider = arguments["provider"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawProvider.isEmpty else {
            throw AgentToolError.missingArgument("provider")
        }
        guard let rawKind = arguments["kind"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKind.isEmpty else {
            throw AgentToolError.missingArgument("kind")
        }
        guard let title = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw AgentToolError.missingArgument("title")
        }
        let requestedStatus = cleanOptionalString(arguments["status"]).map(parseMediaStatus)
        let artifactPaths = arguments["artifact_paths"]?.stringArrayValue() ?? []
        let artifacts = artifactPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { path in
                AgentMediaArtifact(
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    filePath: path
                )
            }
        let task = await MainActor.run {
            let created = registry.create(
                provider: parseMediaProvider(rawProvider),
                kind: parseMediaKind(rawKind),
                title: title,
                prompt: cleanOptionalString(arguments["prompt"]),
                model: cleanOptionalString(arguments["model"]),
                remoteTaskID: cleanOptionalString(arguments["remote_task_id"]),
                statusURL: cleanOptionalString(arguments["status_url"]),
                cancelURL: cleanOptionalString(arguments["cancel_url"]),
                statusEndpointSuffix: cleanOptionalString(arguments["status_endpoint_suffix"]),
                cancelEndpointSuffix: cleanOptionalString(arguments["cancel_endpoint_suffix"]),
                sourceImagePath: cleanOptionalString(arguments["source_image_path"]),
                maskPath: cleanOptionalString(arguments["mask_path"]),
                reviewItemID: cleanOptionalString(arguments["review_item_id"]),
                runtimeID: context.runtimeID,
                projectID: cleanOptionalString(arguments["project_id"]),
                projectPath: cleanOptionalString(arguments["project_path"]),
                episodeID: cleanOptionalString(arguments["episode_id"]),
                shotID: cleanOptionalString(arguments["shot_id"]),
                assetKind: cleanOptionalString(arguments["asset_kind"]),
                assetID: cleanOptionalString(arguments["asset_id"]),
                status: .submitted,
                statusMessage: artifacts.isEmpty ? "任务已登记，等待 provider 进度更新。" : "本地产物已登记。"
            )
            if !artifacts.isEmpty || requestedStatus != nil {
                registry.update(
                    id: created.id,
                    status: requestedStatus ?? (artifacts.isEmpty ? .submitted : .succeeded),
                    progress: artifacts.isEmpty ? nil : 1,
                    artifacts: artifacts.isEmpty ? nil : artifacts
                )
                return registry.task(matchingHandle: created.displayHandle, runtimeID: context.runtimeID) ?? created
            }
            return created
        }
        return AgentToolResult(
            summary: "media task registered: \(task.displayHandle)",
            payload: mediaTaskToolPayload(task: task, action: "create_media_task_follow_up")
        )
    }

    static func updateMediaTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        guard let handle = arguments["task_id"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else {
            throw AgentToolError.missingArgument("task_id")
        }
        let status = cleanOptionalString(arguments["status"]).map(parseMediaStatus)
        let progress = parseProgress(arguments["progress"])
        let artifactPaths = arguments["artifact_paths"]?.stringArrayValue() ?? []
        let artifacts = artifactPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { path in
                AgentMediaArtifact(
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    filePath: path
                )
            }

        let updated: AgentMediaTask? = await MainActor.run {
            guard let task = registry.task(matchingHandle: handle, runtimeID: context.runtimeID) else {
                return nil
            }
            registry.update(
                id: task.id,
                status: status,
                progress: progress,
                statusMessage: cleanOptionalString(arguments["status_message"]),
                remoteTaskID: cleanOptionalString(arguments["remote_task_id"]),
                statusURL: cleanOptionalString(arguments["status_url"]),
                cancelURL: cleanOptionalString(arguments["cancel_url"]),
                statusEndpointSuffix: cleanOptionalString(arguments["status_endpoint_suffix"]),
                cancelEndpointSuffix: cleanOptionalString(arguments["cancel_endpoint_suffix"]),
                sourceImagePath: cleanOptionalString(arguments["source_image_path"]),
                maskPath: cleanOptionalString(arguments["mask_path"]),
                reviewItemID: cleanOptionalString(arguments["review_item_id"]),
                artifacts: artifacts.isEmpty ? nil : task.artifacts + artifacts
            )
            return registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID)
        }
        guard let updated else {
            throw AgentToolError.notFound(handle)
        }
        return AgentToolResult(
            summary: "\(updated.displayHandle): \(updated.status.displayName)",
            payload: mediaTaskToolPayload(task: updated, action: "update_media_task_follow_up")
        )
    }

    static func listMediaTasks(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            return AgentToolResult(summary: "no media tasks", payload: "Media task registry not available in this context.")
        }
        let onlyActive = arguments["only_active"]?.boolValue() ?? false
        let tasks = await MainActor.run {
            registry.tasks(forRuntime: context.runtimeID)
        }
        let filtered = onlyActive ? tasks.filter(\.isActive) : tasks
        guard !filtered.isEmpty else {
            return AgentToolResult(
                summary: "no media tasks",
                payload: onlyActive ? "No active media tasks." : "No media tasks in this session."
            )
        }
        let payload = filtered.map(describe(mediaTask:)).joined(separator: "\n\n")
        let activeCount = filtered.filter(\.isActive).count
        return AgentToolResult(
            summary: "\(filtered.count) media task\(filtered.count == 1 ? "" : "s") (\(activeCount) active)",
            payload: payload
        )
    }

    static func replicateCreatePrediction(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        guard let version = cleanOptionalString(arguments["version"]) else {
            throw AgentToolError.missingArgument("version")
        }
        guard let inputJSON = cleanOptionalString(arguments["input_json"]) else {
            throw AgentToolError.missingArgument("input_json")
        }
        let title = cleanOptionalString(arguments["title"]) ?? "Replicate 任务"
        let kind = cleanOptionalString(arguments["kind"]).map(parseMediaKind) ?? .imageEdit
        let model = cleanOptionalString(arguments["model"]) ?? version
        let prompt = replicatePromptSummary(from: inputJSON)
        let sourceImagePath = cleanOptionalString(arguments["source_image_path"])
        let maskPath = cleanOptionalString(arguments["mask_path"])

        let prediction = try await ReplicateClient.createPrediction(
            version: version,
            inputJSON: inputJSON,
            webhook: cleanOptionalString(arguments["webhook"])
        )
        let artifacts = prediction.status == "succeeded"
            ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
            : []
        let status = ReplicateClient.status(from: prediction.status)
        let task = await MainActor.run {
            registry.create(
                provider: .replicate,
                kind: kind,
                title: title,
                prompt: prompt,
                model: model,
                remoteTaskID: prediction.id,
                statusURL: prediction.urls?.get,
                cancelURL: prediction.urls?.cancel,
                sourceImagePath: sourceImagePath,
                maskPath: maskPath,
                reviewItemID: cleanOptionalString(arguments["review_item_id"]),
                runtimeID: context.runtimeID,
                projectID: cleanOptionalString(arguments["project_id"]),
                episodeID: cleanOptionalString(arguments["episode_id"]),
                shotID: cleanOptionalString(arguments["shot_id"]),
                assetKind: cleanOptionalString(arguments["asset_kind"]),
                assetID: cleanOptionalString(arguments["asset_id"]),
                status: status,
                statusMessage: ReplicateClient.statusMessage(for: prediction)
            )
        }
        if !artifacts.isEmpty {
            await MainActor.run {
                registry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
        }
        let updated = await MainActor.run {
            registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID) ?? task
        }
        return AgentToolResult(
            summary: "Replicate \(prediction.status): \(updated.displayHandle)",
            payload: """
            Replicate prediction submitted.

            \(mediaTaskToolPayload(task: updated, action: "replicate_create_prediction_follow_up"))
            """
        )
    }

    static func replicatePollPrediction(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let existingTask = try await mediaTaskForReplicate(arguments: arguments, context: context)
        let predictionID = existingTask?.statusURL ?? existingTask?.remoteTaskID ?? cleanOptionalString(arguments["prediction_id"])
        guard let predictionID else {
            throw AgentToolError.missingArgument("prediction_id")
        }
        let prediction = try await ReplicateClient.getPrediction(idOrURL: predictionID)
        let status = ReplicateClient.status(from: prediction.status)
        let title = existingTask?.title ?? cleanOptionalString(arguments["title"]) ?? "Replicate 任务"
        let artifacts = status == .succeeded
            ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
            : []

        let updated = await MainActor.run {
            if let task = existingTask {
                let existingRemoteURLs = Set(task.artifacts.compactMap(\.remoteURL))
                let newArtifacts = artifacts.filter { artifact in
                    guard let remoteURL = artifact.remoteURL else { return true }
                    return !existingRemoteURLs.contains(remoteURL)
                }
                registry.update(
                    id: task.id,
                    status: status,
                    progress: status.isActive ? nil : (status == .succeeded ? 1 : task.progress),
                    statusMessage: ReplicateClient.statusMessage(for: prediction),
                    remoteTaskID: prediction.id,
                    statusURL: prediction.urls?.get,
                    cancelURL: prediction.urls?.cancel,
                    artifacts: newArtifacts.isEmpty ? nil : task.artifacts + newArtifacts
                )
                return registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID)
            }
            return nil
        }

        if let updated {
            return AgentToolResult(
                summary: "Replicate \(prediction.status): \(updated.displayHandle)",
                payload: mediaTaskToolPayload(task: updated, action: "replicate_poll_prediction_follow_up")
            )
        }

        let urls = ReplicateClient.collectOutputURLs(from: prediction.output)
        return AgentToolResult(
            summary: "Replicate \(prediction.status): \(prediction.id)",
            payload: """
            Prediction: \(prediction.id)
            Status: \(prediction.status)
            Output URLs: \(urls.isEmpty ? "(none)" : urls.joined(separator: "\n"))
            """
        )
    }

    static func replicateCancelPrediction(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let existingTask = try await mediaTaskForReplicate(arguments: arguments, context: context)
        let predictionID = existingTask?.cancelURL ?? existingTask?.remoteTaskID ?? cleanOptionalString(arguments["prediction_id"])
        guard let predictionID else {
            throw AgentToolError.missingArgument("prediction_id")
        }
        let prediction = try await ReplicateClient.cancelPrediction(idOrURL: predictionID)
        let status = ReplicateClient.status(from: prediction.status)

        let updated = await MainActor.run {
            if let task = existingTask {
                registry.update(
                    id: task.id,
                    status: status,
                    statusMessage: ReplicateClient.statusMessage(for: prediction),
                    remoteTaskID: prediction.id,
                    statusURL: prediction.urls?.get,
                    cancelURL: prediction.urls?.cancel
                )
                return registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID)
            }
            return nil
        }

        if let updated {
            return AgentToolResult(
                summary: "Replicate canceled: \(updated.displayHandle)",
                payload: mediaTaskToolPayload(task: updated, action: "replicate_cancel_prediction_follow_up")
            )
        }
        return AgentToolResult(
            summary: "Replicate canceled: \(prediction.id)",
            payload: "Prediction: \(prediction.id)\nStatus: \(prediction.status)"
        )
    }

    private static func mediaTaskForReplicate(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentMediaTask? {
        guard let handle = cleanOptionalString(arguments["task_id"]) else {
            return nil
        }
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let task = await MainActor.run {
            registry.task(matchingHandle: handle, runtimeID: context.runtimeID)
        }
        guard let task else {
            throw AgentToolError.notFound(handle)
        }
        return task
    }

    private static func replicatePromptSummary(from inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["prompt", "text", "instruction"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    static func someIMCreateMediaTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let settings = SomeIMIntegrationStore.loadSettings()
        let kind = cleanOptionalString(arguments["kind"]).map(parseMediaKind) ?? .imageGeneration
        let title = cleanOptionalString(arguments["title"]) ?? someIMDefaultTitle(for: kind)
        let model = cleanOptionalString(arguments["model"]) ?? SomeIMAsyncMediaClient.defaultModel(for: kind, settings: settings)
        let endpointSuffix = cleanOptionalString(arguments["endpoint_suffix"]) ?? SomeIMAsyncMediaClient.defaultEndpointSuffix(for: kind)
        let sourceImageURL = try optionalSourceImageURL(arguments: arguments, rootDirectory: context.rootDirectory)
        let outputDirectory = try mediaOutputDirectory(arguments: arguments, rootDirectory: context.rootDirectory)
        let body = try someIMRequestBody(arguments: arguments, model: model, kind: kind, sourceImageURL: sourceImageURL)
        let prompt = cleanOptionalString(arguments["prompt"]) ?? someIMPromptSummary(from: body)

        let response = try await SomeIMAsyncMediaClient.submit(
            endpointSuffix: endpointSuffix,
            body: body,
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let artifacts = status == .succeeded
            ? try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title, outputDirectory: outputDirectory).map(\.mediaArtifact)
            : []
        let task = await MainActor.run {
            registry.create(
                provider: .someIM,
                kind: kind,
                title: title,
                prompt: prompt,
                model: model,
                remoteTaskID: response.id,
                statusURL: response.statusURL,
                cancelURL: response.cancelURL,
                statusEndpointSuffix: endpointSuffix,
                cancelEndpointSuffix: endpointSuffix,
                sourceImagePath: sourceImageURL?.path,
                reviewItemID: cleanOptionalString(arguments["review_item_id"]),
                runtimeID: context.runtimeID,
                projectID: cleanOptionalString(arguments["project_id"]),
                episodeID: cleanOptionalString(arguments["episode_id"]),
                shotID: cleanOptionalString(arguments["shot_id"]),
                assetKind: cleanOptionalString(arguments["asset_kind"]),
                assetID: cleanOptionalString(arguments["asset_id"]),
                status: status,
                statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response)
            )
        }
        if !artifacts.isEmpty {
            await MainActor.run {
                registry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
        }
        let updated = await MainActor.run {
            registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID) ?? task
        }
        return AgentToolResult(
            summary: "some.im \(response.status): \(updated.displayHandle)",
            payload: """
            some.im media task submitted.

            Endpoint suffix: \(endpointSuffix)
            Source image: \(sourceImageURL?.path ?? "(none)")
            \(mediaTaskToolPayload(task: updated, action: "some_im_create_media_task_follow_up"))
            """,
            images: AgentGeneratedImageAttachmentFactory.attachments(
                from: updated.artifacts,
                model: model,
                prompt: prompt
            )
        )
    }

    static func someIMPollMediaTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let existingTask = try await mediaTaskForProvider(arguments: arguments, context: context)
        let taskID = existingTask?.statusURL ?? existingTask?.remoteTaskID ?? cleanOptionalString(arguments["remote_task_id"])
        guard let taskID else {
            throw AgentToolError.missingArgument("remote_task_id")
        }
        let response = try await SomeIMAsyncMediaClient.poll(
            idOrURL: taskID,
            endpointSuffix: cleanOptionalString(arguments["status_endpoint_suffix"]) ?? existingTask?.statusEndpointSuffix,
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let statusEndpointSuffix = cleanOptionalString(arguments["status_endpoint_suffix"]) ?? existingTask?.statusEndpointSuffix
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let title = existingTask?.title ?? cleanOptionalString(arguments["title"]) ?? someIMDefaultTitle(for: .unknown)
        let outputDirectory = try mediaOutputDirectory(arguments: arguments, rootDirectory: context.rootDirectory)
        let artifacts = status == .succeeded
            ? try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title, outputDirectory: outputDirectory).map(\.mediaArtifact)
            : []

        let updated = await MainActor.run {
            if let task = existingTask {
                let existingRemoteURLs = Set(task.artifacts.compactMap(\.remoteURL))
                let newArtifacts = artifacts.filter { artifact in
                    guard let remoteURL = artifact.remoteURL else { return true }
                    return !existingRemoteURLs.contains(remoteURL)
                }
                registry.update(
                    id: task.id,
                    status: status,
                    progress: status.isActive ? nil : (status == .succeeded ? 1 : task.progress),
                    statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response),
                    remoteTaskID: response.id ?? task.remoteTaskID,
                    statusURL: response.statusURL ?? task.statusURL,
                    cancelURL: response.cancelURL ?? task.cancelURL,
                    statusEndpointSuffix: statusEndpointSuffix,
                    cancelEndpointSuffix: task.cancelEndpointSuffix,
                    artifacts: newArtifacts.isEmpty ? nil : task.artifacts + newArtifacts
                )
                return registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID)
            }
            return nil
        }

        if let updated {
            return AgentToolResult(
                summary: "some.im \(response.status): \(updated.displayHandle)",
                payload: mediaTaskToolPayload(task: updated, action: "some_im_poll_media_task_follow_up"),
                images: AgentGeneratedImageAttachmentFactory.attachments(
                    from: updated.artifacts,
                    model: updated.model,
                    prompt: updated.prompt
                )
            )
        }

        let urls = SomeIMAsyncMediaClient.collectOutputURLs(from: response)
        return AgentToolResult(
            summary: "some.im \(response.status): \(response.id ?? taskID)",
            payload: """
            Remote task: \(response.id ?? taskID)
            Status: \(response.status)
            Output URLs: \(urls.isEmpty ? "(none)" : urls.joined(separator: "\n"))
            """
        )
    }

    static func someIMCancelMediaTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let existingTask = try await mediaTaskForProvider(arguments: arguments, context: context)
        let taskID = existingTask?.cancelURL ?? existingTask?.remoteTaskID ?? cleanOptionalString(arguments["remote_task_id"])
        guard let taskID else {
            throw AgentToolError.missingArgument("remote_task_id")
        }
        let response = try await SomeIMAsyncMediaClient.cancel(
            idOrURL: taskID,
            endpointSuffix: cleanOptionalString(arguments["cancel_endpoint_suffix"]) ?? existingTask?.cancelEndpointSuffix ?? existingTask?.statusEndpointSuffix,
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let cancelEndpointSuffix = cleanOptionalString(arguments["cancel_endpoint_suffix"]) ?? existingTask?.cancelEndpointSuffix ?? existingTask?.statusEndpointSuffix

        let updated = await MainActor.run {
            if let task = existingTask {
                registry.update(
                    id: task.id,
                    status: status,
                    statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response),
                    remoteTaskID: response.id ?? task.remoteTaskID,
                    statusURL: response.statusURL ?? task.statusURL,
                    cancelURL: response.cancelURL ?? task.cancelURL,
                    statusEndpointSuffix: task.statusEndpointSuffix,
                    cancelEndpointSuffix: cancelEndpointSuffix
                )
                return registry.task(matchingHandle: task.displayHandle, runtimeID: context.runtimeID)
            }
            return nil
        }

        if let updated {
            return AgentToolResult(
                summary: "some.im canceled: \(updated.displayHandle)",
                payload: mediaTaskToolPayload(task: updated, action: "some_im_cancel_media_task_follow_up")
            )
        }
        return AgentToolResult(
            summary: "some.im canceled: \(response.id ?? taskID)",
            payload: "Remote task: \(response.id ?? taskID)\nStatus: \(response.status)"
        )
    }

    private static func mediaTaskForProvider(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentMediaTask? {
        guard let handle = cleanOptionalString(arguments["task_id"]) else {
            return nil
        }
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let task = await MainActor.run {
            registry.task(matchingHandle: handle, runtimeID: context.runtimeID)
        }
        guard let task else {
            throw AgentToolError.notFound(handle)
        }
        return task
    }

    static func mediaOutputDirectory(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?,
        requiresWorkspace: Bool = false
    ) throws -> URL? {
        if let rawDirectory = cleanOptionalString(arguments["output_directory"]) {
            guard let rootDirectory else {
                throw AgentToolError.noWorkspace
            }
            let root = rootDirectory.standardizedFileURL
            let expanded = NSString(string: rawDirectory).expandingTildeInPath
            let candidate = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : root.appendingPathComponent(expanded)
            let standardized = candidate.standardizedFileURL
            guard standardized.path == root.path || standardized.path.hasPrefix(root.path + "/") else {
                throw AgentToolError.pathOutsideWorkspace(rawDirectory)
            }
            try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
            return standardized
        }

        if let rootDirectory {
            return rootDirectory.standardizedFileURL
        }
        if requiresWorkspace {
            throw AgentToolError.noWorkspace
        }
        return nil
    }

    private static func someIMRequestBody(
        arguments: [String: AgentJSONValue],
        model: String,
        kind: AgentMediaTaskKind,
        sourceImageURL: URL?
    ) throws -> [String: Any] {
        if let inputJSON = cleanOptionalString(arguments["input_json"]) {
            guard let data = inputJSON.data(using: .utf8) else {
                throw AgentToolError.invalidArgument("input_json is not UTF-8.")
            }
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard var object = parsed as? [String: Any] else {
                throw AgentToolError.invalidArgument("input_json must be a JSON object.")
            }
            if object["model"] == nil {
                object["model"] = model
            }
            if object["image"] == nil, let sourceImageURL {
                object["image"] = try dataURL(for: sourceImageURL)
            }
            return object
        }

        guard let prompt = cleanOptionalString(arguments["prompt"]) else {
            throw AgentToolError.missingArgument("prompt")
        }
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
        ]
        if let sourceImageURL {
            body["image"] = try dataURL(for: sourceImageURL)
        }
        if let size = cleanOptionalString(arguments["size"]), kind != .videoGeneration {
            body["size"] = size
        }
        if kind != .videoGeneration {
            body["response_format"] = "b64_json"
        }
        return body
    }

    private static func optionalSourceImageURL(arguments: [String: AgentJSONValue], rootDirectory: URL?) throws -> URL? {
        guard let rawPath = cleanOptionalString(arguments["reference_image_path"]) ?? cleanOptionalString(arguments["source_image_path"]) else {
            return nil
        }
        return try resolveImageURL(rawPath, rootDirectory: rootDirectory)
    }

    private static func someIMPromptSummary(from body: [String: Any]) -> String? {
        for key in ["prompt", "text", "instruction"] {
            if let value = body[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func someIMDefaultTitle(for kind: AgentMediaTaskKind) -> String {
        switch kind {
        case .videoGeneration: return "some.im 视频生成"
        case .imageUpscale: return "some.im 图片放大"
        case .imageErase: return "some.im 图片擦除"
        case .imageInpaint: return "some.im 蒙版重绘"
        case .imageEdit: return "some.im 图片编辑"
        case .shortDrama: return "some.im 短剧媒体任务"
        case .imageGeneration, .unknown: return "some.im 图片生成"
        }
    }

    private static func klingVideoFromImageHandoff(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        imageURL: URL,
        prompt: String
    ) -> AgentToolResult {
        let model = cleanOptionalString(arguments["model"])
            ?? AgentVideoGenerationEngine.defaultModel(for: .kling, hasReferenceImage: true)
        let duration = cleanOptionalString(arguments["duration"]) ?? "5"
        let aspectRatio = cleanOptionalString(arguments["aspect_ratio"]) ?? "16:9"
        let title = cleanOptionalString(arguments["title"]) ?? "\(imageURL.deletingPathExtension().lastPathComponent) · Kling 图生视频"
        let importArguments = klingImportArguments(arguments: arguments, title: title, prompt: prompt, model: model)
        let taskArguments = klingPendingTaskArguments(arguments: arguments, title: title, prompt: prompt, model: model)
        return AgentToolResult(
            summary: "kling image-to-video handoff: \(imageURL.lastPathComponent)",
            payload: """
            Kling image-to-video handoff prepared.

            This tool did not submit a paid Kling job inside WillDeep. To use Kling, call the Kling MCP tools in this order:
            1. mcp__kling.who_am_i
            2. mcp__kling.file_upload for the local first-frame image
            3. mcp__kling.image_to_video with the uploaded URL
            4. mcp__kling.query_tasks until the video URL is ready
            5. Download the final video, then import it back to WillDeep.

            Engine: \(AgentVideoGenerationEngine.kling.displayName)
            Recommended MCP tool: mcp__kling.image_to_video
            Recommended model: \(model)
            Duration: \(duration)
            Aspect ratio: \(aspectRatio)
            First frame image path: \(imageURL.path)
            Prompt:
            \(prompt)

            <kling-video-generation-handoff>
            action: generate_video_from_image_with_kling
            provider: kling
            video_engine: kling
            kling_tool: image_to_video
            kling_model: \(model)
            kling_arguments: prompt=\(prompt), duration=\(duration), imageCount=1, resolution=720p
            kling_inputs: first_image=<url returned by mcp__kling.file_upload>
            local_first_image_path: \(imageURL.path)
            import_completed_tool: import_media_manifest
            import_completed_note: Save the Kling video into a local outputs directory and import it as a video_generation artifact.
            pending_import_tool: import_media_manifest
            pending_import_arguments: create a media manifest item with \(taskArguments), remote_task_id=<Kling generation_id>, then call import_media_manifest(import_pending_tasks=true)
            import_completed_arguments: \(importArguments)
            </kling-video-generation-handoff>
            """,
            images: []
        )
    }

    private static func maskEditPrompt(
        arguments: [String: AgentJSONValue],
        operation: AgentImageEditorOperationPreference
    ) throws -> String {
        if let prompt = cleanOptionalString(arguments["prompt"]) {
            return prompt
        }
        if operation == .erase {
            return "Erase the selected area and naturally reconstruct the background."
        }
        throw AgentToolError.missingArgument("prompt")
    }

    private static func maskEditKind(for operation: AgentImageEditorOperationPreference) -> AgentMediaTaskKind {
        operation == .erase ? .imageErase : .imageInpaint
    }

    private static func maskEditTitle(for operation: AgentImageEditorOperationPreference) -> String {
        operation == .erase ? "图片擦除" : "蒙版重绘"
    }

    private static func replicateMaskEditVersion(for operation: AgentImageEditorOperationPreference) -> String? {
        let settings = ReplicateIntegrationStore.loadWorkflowSettings()
        switch operation {
        case .inpaint:
            return cleanOptionalString(.string(settings.inpaintVersion))
        case .erase:
            return cleanOptionalString(.string(settings.eraseVersion))
        }
    }

    private static func openMediaTaskPanelIfPossible(context: AgentToolContext) async {
        guard let runtimeID = context.runtimeID else { return }
        await MainActor.run {
            EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
        }
    }

    private static func maskEditResultPayload(
        task: AgentMediaTask,
        provider: String,
        status: AgentMediaTaskStatus,
        imageURL: URL,
        maskURL: URL,
        remoteTaskID: String?,
        statusURL: String?,
        cancelURL: String?,
        followUpAction: String
    ) -> String {
        let followUp = mediaTaskToolFollowUp(task: task, action: followUpAction)
        return """
        Masked image edit submitted.

        Source image: \(imageURL.path)
        Mask: \(maskURL.path)
        Task: \(task.displayHandle)
        Provider: \(provider)
        Kind: \(task.kind.displayName)
        Status: \(status.displayName)
        Remote task id: \(remoteTaskID ?? "(none)")
        Status URL: \(statusURL ?? "(none)")
        Cancel URL: \(cancelURL ?? "(none)")
        \(followUp)
        """
    }

    private static func klingPendingTaskArguments(
        arguments: [String: AgentJSONValue],
        title: String,
        prompt: String,
        model: String
    ) -> String {
        var parts = [
            "provider=kling",
            "kind=video_generation",
            "title=\(title)",
            "prompt=\(prompt)",
            "model=\(model)",
            "status=processing"
        ]
        appendAnchorArguments(from: arguments, to: &parts)
        return parts.joined(separator: ", ")
    }

    private static func klingImportArguments(
        arguments: [String: AgentJSONValue],
        title: String,
        prompt: String,
        model: String
    ) -> String {
        var parts = [
            "provider=kling",
            "kind=video_generation",
            "title=\(title)",
            "prompt=\(prompt)",
            "model=\(model)"
        ]
        appendAnchorArguments(from: arguments, to: &parts)
        return parts.joined(separator: ", ")
    }

    private static func appendAnchorArguments(from arguments: [String: AgentJSONValue], to parts: inout [String]) {
        for key in ["project_id", "episode_id", "shot_id", "asset_kind", "asset_id", "review_item_id"] {
            guard let value = cleanOptionalString(arguments[key]) else { continue }
            parts.append("\(key)=\(value)")
        }
    }

    private static func describe(mediaTask task: AgentMediaTask) -> String {
        var lines = [
            "\(task.displayHandle) [\(task.status.rawValue)] \(task.provider.displayName) · \(task.kind.displayName)",
            "Title: \(task.title)"
        ]
        if let model = task.model, !model.isEmpty { lines.append("Model: \(model)") }
        if let remoteTaskID = task.remoteTaskID, !remoteTaskID.isEmpty { lines.append("Remote task id: \(remoteTaskID)") }
        if let statusURL = task.statusURL, !statusURL.isEmpty { lines.append("Status URL: \(statusURL)") }
        if let cancelURL = task.cancelURL, !cancelURL.isEmpty { lines.append("Cancel URL: \(cancelURL)") }
        if let statusEndpointSuffix = task.statusEndpointSuffix, !statusEndpointSuffix.isEmpty { lines.append("Status endpoint suffix: \(statusEndpointSuffix)") }
        if let cancelEndpointSuffix = task.cancelEndpointSuffix, !cancelEndpointSuffix.isEmpty { lines.append("Cancel endpoint suffix: \(cancelEndpointSuffix)") }
        if let sourceImagePath = task.sourceImagePath, !sourceImagePath.isEmpty { lines.append("Source image: \(sourceImagePath)") }
        if let maskPath = task.maskPath, !maskPath.isEmpty { lines.append("Mask: \(maskPath)") }
        if let reviewItemID = task.reviewItemID, !reviewItemID.isEmpty { lines.append("Short-drama review item id: \(reviewItemID)") }
        if let projectID = task.projectID, !projectID.isEmpty { lines.append("Short-drama project id: \(projectID)") }
        if let episodeID = task.episodeID, !episodeID.isEmpty { lines.append("Short-drama episode id: \(episodeID)") }
        if let shotID = task.shotID, !shotID.isEmpty { lines.append("Short-drama shot id: \(shotID)") }
        if let assetKind = task.assetKind, !assetKind.isEmpty { lines.append("Short-drama asset kind: \(assetKind)") }
        if let assetID = task.assetID, !assetID.isEmpty { lines.append("Short-drama asset id: \(assetID)") }
        if let progress = task.progress {
            lines.append("Progress: \(Int((progress * 100).rounded()))%")
        }
        if let message = task.statusMessage, !message.isEmpty {
            lines.append("Status message: \(message)")
        }
        if let prompt = task.prompt, !prompt.isEmpty {
            let trimmed = prompt.count > 300 ? String(prompt.prefix(300)) + "…" : prompt
            lines.append("Prompt: \(trimmed)")
        }
        if !task.artifacts.isEmpty {
            lines.append("Artifacts:")
            for artifact in task.artifacts {
                lines.append("- \(artifact.title): \(artifact.filePath)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func mediaTaskToolPayload(task: AgentMediaTask, action: String) -> String {
        let followUp = mediaTaskToolFollowUp(task: task, action: action)
        if followUp.isEmpty {
            return describe(mediaTask: task)
        }
        return """
        \(describe(mediaTask: task))

        \(followUp)
        """
    }

    private static func mediaTaskToolFollowUp(task: AgentMediaTask, action: String) -> String {
        var lines = [
            "<media-task-tool-follow-up>",
            "action: \(action)",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)"
        ]
        appendCleanLine("review_item_id", task.reviewItemID, to: &lines)
        appendCleanLine("project_id", task.projectID ?? task.projectPath, to: &lines)
        appendCleanLine("episode_id", task.episodeID, to: &lines)
        appendCleanLine("shot_id", task.shotID, to: &lines)
        appendCleanLine("asset_kind", task.assetKind, to: &lines)
        appendCleanLine("asset_id", task.assetID, to: &lines)
        var appendedAction = false
        let imageArtifacts = task.artifacts.filter { isEditableImagePath($0.filePath) }
        if task.status == .succeeded, !imageArtifacts.isEmpty {
            if imageArtifacts.count > 1, let choice = mediaTaskChoiceFollowUp(task: task, imageArtifacts: imageArtifacts) {
                lines.append("image_choice_tool: \(choice.tool)")
                lines.append("image_choice_arguments: \(choice.arguments)")
                appendedAction = true
            } else if let artifact = imageArtifacts.first {
                lines.append(contentsOf: singleImageFollowUpLines(task: task, artifact: artifact))
                appendedAction = true
            }
        }
        if let scopeArguments = mediaTaskScopeArguments(task: task) {
            lines.append("open_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_tasks_arguments: \(scopeArguments)")
            lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_tasks_arguments: \(scopeArguments)")
            appendedAction = true
        } else if task.isActive || task.needsAttention {
            lines.append("list_tasks_tool: list_media_tasks")
            lines.append("list_tasks_arguments: only_active=\(task.isActive)")
            appendedAction = true
        }
        guard appendedAction else {
            return ""
        }
        lines.append("</media-task-tool-follow-up>")
        return lines.joined(separator: "\n")
    }

    private static func mediaTaskChoiceFollowUp(
        task: AgentMediaTask,
        imageArtifacts: [AgentMediaArtifact]
    ) -> (tool: String, arguments: String)? {
        if cleanString(task.projectID ?? task.projectPath) != nil,
           cleanString(task.episodeID) != nil,
           cleanString(task.shotID) != nil {
            return ("short_drama_show_image_choice_widget", mediaTaskShotArguments(task: task))
        }
        let imagePaths = imageArtifacts.map(\.filePath).joined(separator: " | ")
        var pairs = ["image_paths=\(imagePaths)"]
        appendCleanPair("title", task.title, to: &pairs)
        appendCleanPair("project_id", task.projectID ?? task.projectPath, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return ("show_image_choice_widget", pairs.joined(separator: ", "))
    }

    private static func singleImageFollowUpLines(task: AgentMediaTask, artifact: AgentMediaArtifact) -> [String] {
        if cleanString(task.projectID ?? task.projectPath) != nil,
           cleanString(task.episodeID) != nil,
           cleanString(task.shotID) != nil {
            let shotArguments = mediaTaskShotArguments(task: task)
            let artifactArguments = "\(shotArguments), artifact_path=\(artifact.filePath)"
            var lines = [
                "select_primary_tool: short_drama_select_shot_artifact",
                "select_primary_arguments: \(artifactArguments)",
                "video_from_image_tool: generate_video_from_image",
                "video_from_image_arguments: \(mediaTaskVideoArguments(task: task, artifact: artifact))",
                "edit_tool: short_drama_open_image_editor",
                "edit_arguments: \(artifactArguments), operation=inpaint",
                "erase_tool: short_drama_open_image_editor",
                "erase_arguments: \(artifactArguments), operation=erase",
                "upscale_tool: short_drama_upscale_shot_artifact",
                "upscale_arguments: \(artifactArguments)"
            ]
            if let reviewItemID = cleanString(task.reviewItemID) {
                if let reviewTaskArguments = mediaTaskScopeArguments(task: task) {
                    lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                    lines.append("open_review_tasks_arguments: \(reviewTaskArguments)")
                }
                lines.append("resolve_review_tool: short_drama_resolve_review_item")
                lines.append("resolve_review_arguments: \(shotArguments), item_id=\(reviewItemID)")
            }
            return lines
        }
        if cleanString(task.projectID ?? task.projectPath) != nil,
           cleanString(task.assetKind) != nil,
           cleanString(task.assetID) != nil {
            return [
                "attach_reference_tool: short_drama_attach_asset_reference_image",
                "attach_reference_arguments: \(mediaTaskAssetArguments(task: task)), image_path=\(artifact.filePath)"
            ]
        }
        return [
            "edit_tool: open_image_editor",
            "edit_arguments: image_path=\(artifact.filePath), operation=inpaint",
            "erase_tool: open_image_editor",
            "erase_arguments: image_path=\(artifact.filePath), operation=erase",
            "upscale_tool: upscale_image",
            "upscale_arguments: image_path=\(artifact.filePath)",
            "video_from_image_tool: generate_video_from_image",
            "video_from_image_arguments: image_path=\(artifact.filePath)"
        ]
    }

    private static func mediaTaskShotArguments(task: AgentMediaTask) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID ?? task.projectPath, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func mediaTaskAssetArguments(task: AgentMediaTask) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID ?? task.projectPath, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func mediaTaskScopeArguments(task: AgentMediaTask) -> String? {
        guard let projectID = cleanString(task.projectID ?? task.projectPath) else { return nil }
        var pairs = ["project_id=\(projectID)"]
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        if let assetKind = cleanString(task.assetKind), let assetID = cleanString(task.assetID) {
            pairs.append("asset_kind=\(assetKind)")
            pairs.append("asset_id=\(assetID)")
            pairs.append("scope=asset")
        } else if let reviewItemID = cleanString(task.reviewItemID) {
            pairs.append("review_item_id=\(reviewItemID)")
            pairs.append("scope=review_item")
        } else if cleanString(task.shotID) != nil {
            pairs.append("scope=shot")
        } else if cleanString(task.episodeID) != nil {
            pairs.append("scope=episode")
        } else {
            pairs.append("scope=project")
        }
        return pairs.joined(separator: ", ")
    }

    private static func mediaTaskVideoArguments(task: AgentMediaTask, artifact: AgentMediaArtifact) -> String {
        var pairs = ["image_path=\(artifact.filePath)"]
        appendCleanPair("project_id", task.projectID ?? task.projectPath, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = cleanString(value) else { return }
        lines.append("\(key): \(value)")
    }

    private static func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [String]) {
        guard let value = cleanString(value) else { return }
        pairs.append("\(key)=\(value)")
    }

    private static func cleanString(_ value: String?) -> String? {
        guard let string = value?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func cleanOptionalString(_ value: AgentJSONValue?) -> String? {
        guard let string = value?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func resolveImageURL(_ rawPath: String, rootDirectory: URL?) throws -> URL {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let url: URL
        if expandedPath.hasPrefix("/") {
            url = URL(fileURLWithPath: expandedPath)
        } else if let rootDirectory {
            url = rootDirectory.appendingPathComponent(expandedPath)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expandedPath)
        }
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw AgentToolError.invalidArgument("Image file does not exist: \(standardized.path)")
        }
        guard isEditableImagePath(standardized.path) else {
            throw AgentToolError.invalidArgument("Unsupported image file type: \(standardized.path)")
        }
        return standardized
    }

    private static func isEditableImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(ext)
    }

    private static func parseImageEditorOperation(_ raw: String) -> AgentImageEditorOperationPreference {
        switch normalizedMediaToken(raw) {
        case "erase", "remove", "clean":
            return .erase
        default:
            return .inpaint
        }
    }

    private static func dataURL(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let mimeType: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "webp": mimeType = "image/webp"
        case "gif": mimeType = "image/gif"
        case "tif", "tiff": mimeType = "image/tiff"
        case "heic": mimeType = "image/heic"
        default: mimeType = "image/png"
        }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private static func jsonString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("Could not encode Replicate input JSON.")
        }
        return string
    }

    private static func normalizedMediaToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func parseMediaProvider(_ raw: String) -> AgentMediaTaskProvider {
        switch normalizedMediaToken(raw) {
        case "some_im", "someim", "some": return .someIM
        case "replicate": return .replicate
        case "kling", "kling_ai", "klingai", "可灵", "keling": return .kling
        case "skill", "skills": return .skill
        case "local": return .local
        default: return .unknown
        }
    }

    private static func parseMediaKind(_ raw: String) -> AgentMediaTaskKind {
        switch normalizedMediaToken(raw) {
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

    private static func parseMediaStatus(_ raw: String) -> AgentMediaTaskStatus {
        switch normalizedMediaToken(raw) {
        case "queued", "queue": return .queued
        case "submitted", "submit": return .submitted
        case "starting", "start": return .starting
        case "processing", "running", "in_progress": return .processing
        case "succeeded", "success", "completed", "complete", "done": return .succeeded
        case "failed", "failure", "error": return .failed
        case "canceled", "cancelled", "cancel": return .canceled
        default: return .processing
        }
    }

    private static func parseProgress(_ value: AgentJSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .number(let number):
            return max(0, min(1, number))
        case .string(let string):
            guard let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return max(0, min(1, number))
        default:
            return nil
        }
    }

}
