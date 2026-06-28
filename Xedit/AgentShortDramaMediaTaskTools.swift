//
//  AgentShortDramaMediaTaskTools.swift
//  WillDeep
//
//  Media-task side-panel helpers for short-drama storyboard scopes.
//

import Foundation

enum AgentShortDramaMediaTaskTools {
    static func openMediaTasks(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let resolved = try await resolveScope(arguments: arguments, context: context)
        guard let runtimeID = context.runtimeID,
              let appState = await MainActor.run(body: { EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) }) else {
            return unavailableResult(tool: "short_drama_open_media_tasks")
        }
        let matchingCount = await MainActor.run {
            appState.agentMediaTaskPanelScope = resolved.scope
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: resolved.scope)
            return appState.agentMediaTaskRegistry.tasks.filter { resolved.scope.matches($0) }.count
        }
        return AgentToolResult(
            summary: "opened short-drama media tasks: \(resolved.scope.label)",
            payload: payloadHeader(resolved: resolved) + "\nMatching tasks: \(matchingCount)"
        )
    }

    static func refreshMediaTasks(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let resolved = try await resolveScope(arguments: arguments, context: context)
        guard let runtimeID = context.runtimeID,
              let appState = await MainActor.run(body: { EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) }) else {
            return unavailableResult(tool: "short_drama_refresh_media_tasks")
        }
        let taskIDs = await MainActor.run {
            appState.agentMediaTaskPanelScope = resolved.scope
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: resolved.scope)
            return appState.agentMediaTaskRegistry.tasks
                .filter {
                    resolved.scope.matches($0)
                        && $0.isActive
                        && (
                            $0.provider == .replicate
                                || $0.provider == .someIM
                                || AgentGenericMediaStatusClient.canPoll($0)
                        )
                }
                .map(\.id)
        }
        for taskID in taskIDs {
            await appState.agentMediaTaskPoller.refreshNow(taskID: taskID, registry: appState.agentMediaTaskRegistry)
        }
        let matchingCount = await MainActor.run {
            appState.agentMediaTaskRegistry.tasks.filter { resolved.scope.matches($0) }.count
        }
        return AgentToolResult(
            summary: "refreshed short-drama media tasks: \(resolved.scope.label)",
            payload: payloadHeader(resolved: resolved) + """

            Refreshable active tasks: \(taskIDs.count)
            Matching tasks after refresh: \(matchingCount)
            """
        )
    }

    static func retryMediaTask(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let taskHandle = try requiredString(arguments, "task_id")
        let allowSucceeded = arguments["allow_succeeded"]?.boolValue() ?? false
        let task = await MainActor.run {
            registry.task(matchingHandle: taskHandle, runtimeID: context.runtimeID)
        }
        guard let task else {
            throw AgentToolError.notFound(taskHandle)
        }
        guard !task.isActive else {
            throw AgentToolError.invalidArgument("Task \(task.displayHandle) is still active; refresh or cancel it before retrying.")
        }
        if task.status == .succeeded && !allowSucceeded {
            throw AgentToolError.invalidArgument("Task \(task.displayHandle) already succeeded. Pass allow_succeeded=true if you intentionally want another variation.")
        }
        if task.provider == .replicate {
            return try await retryReplicateMediaTask(task: task, context: context)
        }
        guard task.provider == .someIM else {
            throw AgentToolError.invalidArgument("Only some.im generation and reconstructable Replicate image edit/upscale tasks can be retried from stored task metadata right now.")
        }

        if let projectID = clean(task.projectID) ?? clean(task.projectPath),
           let episodeID = clean(task.episodeID),
           let shotID = clean(task.shotID),
           task.kind == .imageGeneration || task.kind == .videoGeneration {
            var retryArguments: [String: AgentJSONValue] = [
                "project_id": .string(projectID),
                "episode_id": .string(episodeID),
                "shot_id": .string(shotID),
                "kind": .string(task.kind.rawValue)
            ]
            if let prompt = clean(task.prompt) {
                retryArguments["prompt_override"] = .string(prompt)
            }
            if let model = clean(task.model) {
                retryArguments["model"] = .string(model)
            }
            if let endpointSuffix = clean(task.statusEndpointSuffix) ?? clean(task.cancelEndpointSuffix) {
                retryArguments["endpoint_suffix"] = .string(endpointSuffix)
            }
            if let reviewItemID = clean(task.reviewItemID) {
                retryArguments["review_item_id"] = .string(reviewItemID)
            }
            let result = try await AgentShortDramaTools.generateShotMedia(arguments: retryArguments, context: context)
            return AgentToolResult(
                summary: "retried short-drama media task: \(task.displayHandle)",
                payload: """
                Retried failed short-drama media task.

                Original task: \(task.displayHandle)
                Original status: \(task.status.displayName)
                Original provider: \(task.provider.displayName)
                Original kind: \(task.kind.displayName)

                \(result.payload)
                """
            )
        }

        if let projectID = clean(task.projectID) ?? clean(task.projectPath),
           task.kind == .imageErase || task.kind == .imageInpaint || task.kind == .imageEdit,
           let episodeID = clean(task.episodeID),
           let shotID = clean(task.shotID) {
            guard let sourceImagePath = clean(task.sourceImagePath) else {
                throw AgentToolError.invalidArgument("some.im image edit retry requires source_image_path.")
            }
            guard let maskPath = clean(task.maskPath) else {
                throw AgentToolError.invalidArgument("some.im image edit retry requires mask_path.")
            }
            var retryArguments: [String: AgentJSONValue] = [
                "provider": .string("some_im"),
                "project_id": .string(projectID),
                "episode_id": .string(episodeID),
                "shot_id": .string(shotID),
                "image_path": .string(sourceImagePath),
                "mask_path": .string(maskPath),
                "operation": .string(task.kind == .imageErase ? "erase" : "inpaint")
            ]
            if let prompt = clean(task.prompt) {
                retryArguments["prompt"] = .string(prompt)
            }
            if let model = clean(task.model) {
                retryArguments["model"] = .string(model)
            }
            if let endpointSuffix = clean(task.statusEndpointSuffix) ?? clean(task.cancelEndpointSuffix) {
                retryArguments["endpoint_suffix"] = .string(endpointSuffix)
            }
            if let reviewItemID = clean(task.reviewItemID) {
                retryArguments["review_item_id"] = .string(reviewItemID)
            }
            let result = try await AgentMediaTools.editImageWithMask(arguments: retryArguments, context: context)
            return retryResult(original: task, result: result)
        }

        if let projectID = clean(task.projectID) ?? clean(task.projectPath),
           task.kind == .imageErase || task.kind == .imageInpaint || task.kind == .imageEdit,
           let assetKind = clean(task.assetKind),
           let assetID = clean(task.assetID) {
            guard let sourceImagePath = clean(task.sourceImagePath) else {
                throw AgentToolError.invalidArgument("some.im asset image edit retry requires source_image_path.")
            }
            guard let maskPath = clean(task.maskPath) else {
                throw AgentToolError.invalidArgument("some.im asset image edit retry requires mask_path.")
            }
            var retryArguments: [String: AgentJSONValue] = [
                "provider": .string("some_im"),
                "project_id": .string(projectID),
                "asset_kind": .string(assetKind),
                "asset_id": .string(assetID),
                "image_path": .string(sourceImagePath),
                "mask_path": .string(maskPath),
                "operation": .string(task.kind == .imageErase ? "erase" : "inpaint")
            ]
            if let prompt = clean(task.prompt) {
                retryArguments["prompt"] = .string(prompt)
            }
            if let model = clean(task.model) {
                retryArguments["model"] = .string(model)
            }
            if let endpointSuffix = clean(task.statusEndpointSuffix) ?? clean(task.cancelEndpointSuffix) {
                retryArguments["endpoint_suffix"] = .string(endpointSuffix)
            }
            if let reviewItemID = clean(task.reviewItemID) {
                retryArguments["review_item_id"] = .string(reviewItemID)
            }
            let result = try await AgentMediaTools.editImageWithMask(arguments: retryArguments, context: context)
            return retryResult(original: task, result: result)
        }

        if let projectID = clean(task.projectID) ?? clean(task.projectPath),
           let assetKind = clean(task.assetKind),
           let assetID = clean(task.assetID),
           task.kind == .imageGeneration {
            var retryArguments: [String: AgentJSONValue] = [
                "project_id": .string(projectID),
                "asset_kind": .string(assetKind),
                "asset_id": .string(assetID)
            ]
            if let prompt = clean(task.prompt) {
                retryArguments["prompt_override"] = .string(prompt)
            }
            if let model = clean(task.model) {
                retryArguments["model"] = .string(model)
            }
            if let endpointSuffix = clean(task.statusEndpointSuffix) ?? clean(task.cancelEndpointSuffix) {
                retryArguments["endpoint_suffix"] = .string(endpointSuffix)
            }
            let result = try await AgentShortDramaTools.generateAssetMedia(arguments: retryArguments, context: context)
            return AgentToolResult(
                summary: "retried short-drama asset media task: \(task.displayHandle)",
                payload: """
                Retried failed short-drama asset media task.

                Original task: \(task.displayHandle)
                Original status: \(task.status.displayName)
                Original provider: \(task.provider.displayName)
                Original kind: \(task.kind.displayName)

                \(result.payload)
                """
            )
        }

        throw AgentToolError.invalidArgument("Task \(task.displayHandle) is not a retryable short-drama some.im generation/edit or Replicate image edit/upscale task.")
    }

    private static func retryReplicateMediaTask(task: AgentMediaTask, context: AgentToolContext) async throws -> AgentToolResult {
        guard let projectID = clean(task.projectID) ?? clean(task.projectPath) else {
            throw AgentToolError.invalidArgument("Replicate retry requires short-drama project_id anchor.")
        }
        let episodeID = clean(task.episodeID)
        let shotID = clean(task.shotID)
        let assetKind = clean(task.assetKind)
        let assetID = clean(task.assetID)
        let model = clean(task.model)
        let prompt = clean(task.prompt)
        let reviewItemID = clean(task.reviewItemID)
        switch task.kind {
        case .imageUpscale:
            guard let sourceImagePath = clean(task.sourceImagePath) else {
                throw AgentToolError.invalidArgument("Replicate upscale retry requires source_image_path.")
            }
            if let episodeID, let shotID {
                var retryArguments: [String: AgentJSONValue] = [
                    "project_id": .string(projectID),
                    "episode_id": .string(episodeID),
                    "shot_id": .string(shotID),
                    "artifact_path": .string(sourceImagePath)
                ]
                if let model { retryArguments["version"] = .string(model) }
                if let prompt { retryArguments["prompt"] = .string(prompt) }
                if let reviewItemID { retryArguments["review_item_id"] = .string(reviewItemID) }
                let result = try await AgentShortDramaImageTools.upscaleShotArtifact(arguments: retryArguments, context: context)
                return retryResult(original: task, result: result)
            }
            guard let assetKind, let assetID else {
                throw AgentToolError.invalidArgument("Replicate upscale retry requires either shot anchors or asset_kind and asset_id.")
            }
            var retryArguments: [String: AgentJSONValue] = [
                "project_id": .string(projectID),
                "asset_kind": .string(assetKind),
                "asset_id": .string(assetID),
                "image_path": .string(sourceImagePath)
            ]
            if let model { retryArguments["version"] = .string(model) }
            if let prompt { retryArguments["prompt"] = .string(prompt) }
            if let reviewItemID { retryArguments["review_item_id"] = .string(reviewItemID) }
            let result = try await AgentMediaTools.upscaleImage(arguments: retryArguments, context: context)
            return retryResult(original: task, result: result)
        case .imageErase, .imageInpaint, .imageEdit:
            guard let sourceImagePath = clean(task.sourceImagePath) else {
                throw AgentToolError.invalidArgument("Replicate image edit retry requires source_image_path.")
            }
            guard let maskPath = clean(task.maskPath) else {
                throw AgentToolError.invalidArgument("Replicate image edit retry requires mask_path.")
            }
            guard (episodeID != nil && shotID != nil) || (assetKind != nil && assetID != nil) else {
                throw AgentToolError.invalidArgument("Replicate image edit retry requires either shot anchors or asset_kind and asset_id.")
            }
            var retryArguments: [String: AgentJSONValue] = [
                "provider": .string("replicate"),
                "project_id": .string(projectID),
                "image_path": .string(sourceImagePath),
                "mask_path": .string(maskPath),
                "operation": .string(task.kind == .imageErase ? "erase" : "inpaint")
            ]
            if let episodeID { retryArguments["episode_id"] = .string(episodeID) }
            if let shotID { retryArguments["shot_id"] = .string(shotID) }
            if let assetKind { retryArguments["asset_kind"] = .string(assetKind) }
            if let assetID { retryArguments["asset_id"] = .string(assetID) }
            if let model { retryArguments["version"] = .string(model) }
            if let prompt { retryArguments["prompt"] = .string(prompt) }
            if let reviewItemID { retryArguments["review_item_id"] = .string(reviewItemID) }
            let result = try await AgentMediaTools.editImageWithMask(arguments: retryArguments, context: context)
            return retryResult(original: task, result: result)
        default:
            throw AgentToolError.invalidArgument("Task \(task.displayHandle) is not a retryable Replicate image edit or upscale task.")
        }
    }

    private static func retryResult(original task: AgentMediaTask, result: AgentToolResult) -> AgentToolResult {
        AgentToolResult(
            summary: "retried short-drama media task: \(task.displayHandle)",
            payload: """
            Retried failed short-drama media task.

            Original task: \(task.displayHandle)
            Original status: \(task.status.displayName)
            Original provider: \(task.provider.displayName)
            Original kind: \(task.kind.displayName)

            \(result.payload)
            """
        )
    }

    static func retryFailedMediaTasks(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let resolved = try await resolveScope(arguments: arguments, context: context)
        let maxTasks = max(1, min(arguments["max_tasks"]?.intValue() ?? 20, 50))
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let candidates = await MainActor.run {
            registry.tasks
                .filter { resolved.scope.matches($0) && isRetryableFailedTask($0) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        let selected = Array(candidates.prefix(maxTasks))
        if dryRun {
            return AgentToolResult(
                summary: "dry-run retry failed short-drama media tasks: \(selected.count)",
                payload: payloadHeader(resolved: resolved) + """

                Dry run: no media tasks were submitted.
                Retryable failed tasks: \(candidates.count)
                Selected by max_tasks=\(maxTasks): \(selected.count)
                \(taskList(selected))
                """
            )
        }
        guard !selected.isEmpty else {
            return AgentToolResult(
                summary: "no retryable failed short-drama media tasks",
                payload: payloadHeader(resolved: resolved) + "\nNo retryable failed or canceled some.im short-drama tasks found in this scope."
            )
        }

        var submitted: [String] = []
        var failures: [String] = []
        for task in selected {
            do {
                let result = try await retryMediaTask(
                    arguments: ["task_id": .string(task.displayHandle)],
                    context: context
                )
                submitted.append("- \(task.displayHandle): \(result.summary)")
            } catch {
                failures.append("- \(task.displayHandle): \(error.localizedDescription)")
            }
        }

        if let runtimeID = context.runtimeID {
            await MainActor.run {
                if let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                    appState.agentMediaTaskPanelScope = resolved.scope
                    appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: resolved.scope)
                }
            }
        }

        return AgentToolResult(
            summary: "retried failed short-drama media tasks: \(submitted.count)",
            payload: payloadHeader(resolved: resolved) + """

            Retryable failed tasks: \(candidates.count)
            Submitted retries: \(submitted.count)
            Failed retries: \(failures.count)

            Submitted:
            \(submitted.isEmpty ? "(none)" : submitted.joined(separator: "\n"))

            Failures:
            \(failures.isEmpty ? "(none)" : failures.joined(separator: "\n"))
            """
        )
    }

    private static func resolveScope(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> ResolvedScope {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let project = try await loadProject(store: store, projectID: projectID)
        let requestedScope = optionalString(arguments["scope"])?.lowercased()
        let episodeID = optionalUUID(arguments["episode_id"])
        let shotID = optionalUUID(arguments["shot_id"])
        let reviewItemID = optionalUUID(arguments["review_item_id"]) ?? optionalUUID(arguments["item_id"])
        let assetKind = normalizedAssetKind(optionalString(arguments["asset_kind"]) ?? requestedScope)
        let assetID = optionalUUID(arguments["asset_id"])
        let scopeKind: String
        if requestedScope == "review_item" || requestedScope == "review" || (requestedScope == nil && reviewItemID != nil) {
            scopeKind = "review_item"
        } else if requestedScope == "asset" || requestedScope == "character" || requestedScope == "scene" || (requestedScope == nil && assetID != nil) {
            scopeKind = "asset"
        } else if requestedScope == "shot" || (requestedScope == nil && shotID != nil) {
            scopeKind = "shot"
        } else if requestedScope == "episode" || (requestedScope == nil && episodeID != nil) {
            scopeKind = "episode"
        } else {
            scopeKind = "project"
        }

        let episode = episodeID.flatMap { id in project.episodes.first(where: { $0.id == id }) }
        if (scopeKind == "episode" || scopeKind == "shot"), episode == nil {
            throw AgentToolError.notFound(episodeID?.uuidString ?? "episode_id")
        }
        let shot = shotID.flatMap { id in episode?.shots.first(where: { $0.id == id }) }
        if scopeKind == "shot", shot == nil {
            throw AgentToolError.notFound(shotID?.uuidString ?? "shot_id")
        }
        let asset = try resolveAsset(project: project, scopeKind: scopeKind, assetKind: assetKind, assetID: assetID)
        let reviewItem = try resolveReviewItem(
            project: project,
            requestedEpisode: episode,
            requestedShot: shot,
            scopeKind: scopeKind,
            reviewItemID: reviewItemID
        )

        let scope: AgentMediaTaskScope
        let assetLabel: String?
        let reviewItemLabel: String?
        switch scopeKind {
        case "review_item":
            guard let reviewItem else { throw AgentToolError.missingArgument("review_item_id") }
            scope = AgentMediaTaskScope(
                label: "检查项：\(reviewItem.item.title)",
                projectID: project.id.uuidString,
                episodeID: reviewItem.episode.id.uuidString,
                shotID: reviewItem.shot.id.uuidString,
                reviewItemID: reviewItem.item.id.uuidString
            )
            assetLabel = nil
            reviewItemLabel = reviewItem.item.title
        case "shot":
            guard let episode, let shot else { throw AgentToolError.missingArgument("episode_id and shot_id") }
            scope = AgentMediaTaskScope(
                label: "分镜：\(shot.title)",
                projectID: project.id.uuidString,
                episodeID: episode.id.uuidString,
                shotID: shot.id.uuidString
            )
            assetLabel = nil
            reviewItemLabel = nil
        case "episode":
            guard let episode else { throw AgentToolError.missingArgument("episode_id") }
            scope = AgentMediaTaskScope(
                label: "分集：\(episode.title)",
                projectID: project.id.uuidString,
                episodeID: episode.id.uuidString
            )
            assetLabel = nil
            reviewItemLabel = nil
        case "asset":
            guard let asset else { throw AgentToolError.missingArgument("asset_kind and asset_id") }
            scope = AgentMediaTaskScope(
                label: "\(asset.displayKind)：\(asset.name)",
                projectID: project.id.uuidString,
                assetKind: asset.kind,
                assetID: asset.id.uuidString
            )
            assetLabel = "\(asset.displayKind)：\(asset.name)"
            reviewItemLabel = nil
        default:
            scope = AgentMediaTaskScope(label: "项目：\(project.title)", projectID: project.id.uuidString)
            assetLabel = nil
            reviewItemLabel = nil
        }

        return ResolvedScope(
            project: project,
            episode: reviewItem?.episode ?? episode,
            shot: reviewItem?.shot ?? shot,
            assetLabel: assetLabel,
            reviewItemLabel: reviewItemLabel,
            scope: scope
        )
    }

    private static func requireStore(_ context: AgentToolContext) throws -> AgentShortDramaStore {
        guard let store = context.shortDramaStore else {
            throw AgentToolError.invalidArgument("Short-drama store not available.")
        }
        return store
    }

    private static func resolveProjectID(arguments: [String: AgentJSONValue], store: AgentShortDramaStore) async throws -> UUID {
        if let projectID = optionalUUID(arguments["project_id"]) {
            return projectID
        }
        let active = await MainActor.run { store.activeProject?.id }
        guard let active else {
            throw AgentToolError.missingArgument("project_id")
        }
        return active
    }

    private static func loadProject(store: AgentShortDramaStore, projectID: UUID) async throws -> AgentShortDramaProject {
        let project = await MainActor.run { store.project(id: projectID) }
        guard let project else {
            throw AgentToolError.notFound(projectID.uuidString)
        }
        return project
    }

    private static func optionalString(_ value: AgentJSONValue?) -> String? {
        guard let string = value?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func requiredString(_ arguments: [String: AgentJSONValue], _ key: String) throws -> String {
        guard let value = optionalString(arguments[key]) else {
            throw AgentToolError.missingArgument(key)
        }
        return value
    }

    private static func optionalUUID(_ value: AgentJSONValue?) -> UUID? {
        optionalString(value).flatMap(UUID.init(uuidString:))
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedAssetKind(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "character", "characters", "person", "role":
            return "character"
        case "scene", "scenes", "location", "set":
            return "scene"
        default:
            return nil
        }
    }

    private static func unavailableResult(tool: String) -> AgentToolResult {
        AgentToolResult(
            summary: "short drama media task panel unavailable",
            payload: "\(tool) is only available in conversational agent runtimes."
        )
    }

    private static func payloadHeader(resolved: ResolvedScope) -> String {
        """
        Short-drama media task side panel opened.

        Scope: \(resolved.scope.label)
        Project: \(resolved.project.title)
        Episode: \(resolved.episode?.title ?? "(all)")
        Shot: \(resolved.shot?.title ?? "(all)")
        Asset: \(resolved.assetLabel ?? "(all)")
        Review item: \(resolved.reviewItemLabel ?? "(all)")
        """
    }

    private static func resolveReviewItem(
        project: AgentShortDramaProject,
        requestedEpisode: AgentShortDramaEpisode?,
        requestedShot: AgentShortDramaShot?,
        scopeKind: String,
        reviewItemID: UUID?
    ) throws -> ResolvedReviewItem? {
        guard scopeKind == "review_item" else { return nil }
        guard let reviewItemID else {
            throw AgentToolError.missingArgument("review_item_id")
        }
        let episodes = requestedEpisode.map { [$0] } ?? project.episodes
        for episode in episodes {
            let shots = requestedShot.map { [$0] } ?? episode.shots
            for shot in shots {
                if let item = shot.reviewItems.first(where: { $0.id == reviewItemID }) {
                    return ResolvedReviewItem(episode: episode, shot: shot, item: item)
                }
            }
        }
        throw AgentToolError.notFound(reviewItemID.uuidString)
    }

    private static func resolveAsset(
        project: AgentShortDramaProject,
        scopeKind: String,
        assetKind: String?,
        assetID: UUID?
    ) throws -> ResolvedAsset? {
        guard scopeKind == "asset" else { return nil }
        guard let assetKind else {
            throw AgentToolError.missingArgument("asset_kind")
        }
        guard let assetID else {
            throw AgentToolError.missingArgument("asset_id")
        }
        switch assetKind {
        case "character":
            guard let character = project.characters.first(where: { $0.id == assetID }) else {
                throw AgentToolError.notFound(assetID.uuidString)
            }
            return ResolvedAsset(id: character.id, kind: "character", displayKind: "人物", name: character.name)
        case "scene":
            guard let scene = project.scenes.first(where: { $0.id == assetID }) else {
                throw AgentToolError.notFound(assetID.uuidString)
            }
            return ResolvedAsset(id: scene.id, kind: "scene", displayKind: "场景", name: scene.name)
        default:
            throw AgentToolError.invalidArgument("asset_kind must be character or scene.")
        }
    }

    private static func isRetryableFailedTask(_ task: AgentMediaTask) -> Bool {
        guard task.status == .failed || task.status == .canceled else { return false }
        guard clean(task.projectID) != nil || clean(task.projectPath) != nil else { return false }
        if task.provider == .replicate {
            let hasShotAnchor = clean(task.episodeID) != nil && clean(task.shotID) != nil
            let hasAssetAnchor = clean(task.assetKind) != nil && clean(task.assetID) != nil
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
            let hasShotAnchor = clean(task.episodeID) != nil && clean(task.shotID) != nil
            let hasAssetAnchor = clean(task.assetKind) != nil && clean(task.assetID) != nil
            return (hasShotAnchor || hasAssetAnchor)
                && clean(task.sourceImagePath) != nil
                && clean(task.maskPath) != nil
        }
        if clean(task.assetKind) != nil, clean(task.assetID) != nil, task.kind == .imageGeneration {
            return true
        }
        guard clean(task.episodeID) != nil, clean(task.shotID) != nil else { return false }
        return task.kind == .imageGeneration || task.kind == .videoGeneration
    }

    private static func taskList(_ tasks: [AgentMediaTask]) -> String {
        guard !tasks.isEmpty else { return "(none)" }
        return tasks.map { task in
            "- \(task.displayHandle) · \(task.kind.displayName) · \(task.title)"
        }.joined(separator: "\n")
    }

    private struct ResolvedScope {
        let project: AgentShortDramaProject
        let episode: AgentShortDramaEpisode?
        let shot: AgentShortDramaShot?
        let assetLabel: String?
        let reviewItemLabel: String?
        let scope: AgentMediaTaskScope
    }

    private struct ResolvedReviewItem {
        let episode: AgentShortDramaEpisode
        let shot: AgentShortDramaShot
        let item: AgentShortDramaReviewItem
    }

    private struct ResolvedAsset {
        let id: UUID
        let kind: String
        let displayKind: String
        let name: String
    }
}
