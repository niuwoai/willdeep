//
//  AgentShortDramaBatchTools.swift
//  WillDeep
//
//  Batch orchestration for short-drama media generation. The provider
//  submission still flows through AgentShortDramaTools.generateShotMedia
//  so prompt building, selected-image references, and media-task routing
//  stay consistent with the single-shot path.
//

import Foundation

enum AgentShortDramaBatchTools {
    static func generateBatchMedia(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeFilter = optionalUUID(arguments["episode_id"])
        let explicitShotIDs = try uuidArray(arguments["shot_ids"]?.stringArrayValue() ?? [], argumentName: "shot_ids")
        let kind = optionalString(arguments["kind"]) ?? "image_generation"
        let videoEngine = isVideoGeneration(kind) ? AgentVideoGenerationEngine.parse(arguments: arguments) : .seedance
        let targetFilter = normalizedTargetFilter(optionalString(arguments["target_filter"]) ?? optionalString(arguments["target_mode"]))
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let maxShots = max(1, min(arguments["max_shots"]?.intValue() ?? 200, 200))

        let project = try await loadProject(store: store, projectID: projectID)
        let selectedEpisodes = project.episodes
            .filter { episodeFilter == nil || $0.id == episodeFilter }
            .sorted { $0.order < $1.order }
        if let episodeFilter, selectedEpisodes.isEmpty {
            throw AgentToolError.notFound(episodeFilter.uuidString)
        }

        let targets = selectedEpisodes.flatMap { episode in
            episode.shots
                .sorted { $0.order < $1.order }
                .map { BatchTarget(episode: episode, shot: $0) }
                .filter { target in
                    explicitShotIDs.isEmpty || explicitShotIDs.contains(target.shot.id)
                }
                .filter { target in
                    matchesTargetFilter(target.shot, kind: kind, targetFilter: targetFilter)
                }
        }
        let limitedTargets = Array(targets.prefix(maxShots))
        guard !limitedTargets.isEmpty else {
            return AgentToolResult(
                summary: "short drama batch: no shots",
                payload: "No shots matched the requested project/episode scope."
            )
        }

        if dryRun {
            return AgentToolResult(
                summary: "dry-run short drama batch: \(limitedTargets.count) shots",
                payload: batchSummary(
                    project: project,
                    kind: kind,
                    videoEngine: videoEngine,
                    targetFilter: targetFilter,
                    dryRun: true,
                    targets: limitedTargets,
                    explicitShotIDs: explicitShotIDs,
                    submitted: [],
                    failures: []
                )
            )
        }

        var submitted: [String] = []
        var failures: [String] = []
        for target in limitedTargets {
            var shotArguments = arguments
            shotArguments["project_id"] = .string(projectID.uuidString)
            shotArguments["episode_id"] = .string(target.episode.id.uuidString)
            shotArguments["shot_id"] = .string(target.shot.id.uuidString)
            shotArguments["kind"] = .string(kind)
            shotArguments["dry_run"] = nil
            shotArguments["max_shots"] = nil
            do {
                let result = try await AgentShortDramaTools.generateShotMedia(arguments: shotArguments, context: context)
                submitted.append("第 \(target.episode.order) 集 / 镜 \(target.shot.order): \(result.summary)")
            } catch {
                failures.append("第 \(target.episode.order) 集 / 镜 \(target.shot.order) \(target.shot.title): \(error.localizedDescription)")
            }
        }

        if let runtimeID = context.runtimeID {
            await MainActor.run {
                if let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                    appState.agentSidePanelRequest = AgentSidePanelOpenRequest(
                        kind: .mediaTasks,
                        mediaTaskScope: AgentMediaTaskScope(
                            label: episodeFilter == nil ? "项目：\(project.title)" : "批量：\(project.title)",
                            projectID: projectID.uuidString,
                            episodeID: episodeFilter?.uuidString
                        )
                    )
                }
            }
        }

        return AgentToolResult(
            summary: "short drama batch \(kind): \(submitted.count) submitted, \(failures.count) failed",
            payload: batchSummary(
                project: project,
                kind: kind,
                videoEngine: videoEngine,
                targetFilter: targetFilter,
                dryRun: false,
                targets: limitedTargets,
                explicitShotIDs: explicitShotIDs,
                submitted: submitted,
                failures: failures
            )
        )
    }

    private struct BatchTarget {
        var episode: AgentShortDramaEpisode
        var shot: AgentShortDramaShot
    }

    private static func batchSummary(
        project: AgentShortDramaProject,
        kind: String,
        videoEngine: AgentVideoGenerationEngine,
        targetFilter: String,
        dryRun: Bool,
        targets: [BatchTarget],
        explicitShotIDs: Set<UUID>,
        submitted: [String],
        failures: [String]
    ) -> String {
        let targetLines = targets.map { target in
            "- 第 \(target.episode.order) 集 / 镜 \(target.shot.order): \(target.shot.title) — episode_id=\(target.episode.id.uuidString), shot_id=\(target.shot.id.uuidString)"
        }.joined(separator: "\n")
        let submittedLines = submitted.isEmpty ? "(none)" : submitted.map { "- \($0)" }.joined(separator: "\n")
        let failureLines = failures.isEmpty ? "(none)" : failures.map { "- \($0)" }.joined(separator: "\n")
        let scopeArguments = batchScopeArguments(project: project, targets: targets)
        let shotIDsArgument = explicitShotIDs.isEmpty ? "" : ", shot_ids=[\(explicitShotIDs.map(\.uuidString).sorted().joined(separator: ","))]"
        let videoEngineArgument = isVideoGeneration(kind) ? ", video_engine=\(videoEngine.rawValue)" : ""
        let submitArguments = "\(scopeArguments)\(shotIDsArgument), kind=\(kind)\(videoEngineArgument), target_filter=\(targetFilter), dry_run=false, max_shots=\(targets.count)"
        let dryRunArguments = "\(scopeArguments)\(shotIDsArgument), kind=\(kind)\(videoEngineArgument), target_filter=\(targetFilter), dry_run=true, max_shots=\(targets.count)"
        let targetIDs = targets.map { target in
            "episode_id=\(target.episode.id.uuidString), shot_id=\(target.shot.id.uuidString)"
        }.joined(separator: " | ")
        return """
        Short-drama batch media generation \(dryRun ? "dry-run" : "submitted").

        Project: \(project.title)
        Project id: \(project.id.uuidString)
        Kind: \(kind)
        Video engine: \(isVideoGeneration(kind) ? videoEngine.displayName : "(n/a)")
        Target filter: \(targetFilter)
        Target shots: \(targets.count)

        Targets:
        \(targetLines)

        Submitted:
        \(submittedLines)

        Failures:
        \(failureLines)

        <short-drama-batch-media-handoff>
        action: short_drama_batch_media_\(dryRun ? "dry_run" : "submitted")
        project_id: \(project.id.uuidString)
        kind: \(kind)
        video_engine: \(isVideoGeneration(kind) ? videoEngine.rawValue : "")
        target_filter: \(targetFilter)
        dry_run: \(dryRun)
        explicit_shot_filter_count: \(explicitShotIDs.count)
        target_count: \(targets.count)
        submitted_count: \(submitted.count)
        failure_count: \(failures.count)
        target_shots: \(targetIDs)
        open_tasks_tool: short_drama_open_media_tasks
        open_tasks_arguments: \(scopeArguments)
        refresh_tasks_tool: short_drama_refresh_media_tasks
        refresh_tasks_arguments: \(scopeArguments)
        dry_run_tool: short_drama_generate_batch_media
        dry_run_arguments: \(dryRunArguments)
        submit_tool: short_drama_generate_batch_media
        submit_arguments: \(submitArguments)
        retry_failed_tool: short_drama_retry_failed_media_tasks
        retry_failed_dry_run_arguments: \(scopeArguments), dry_run=true
        </short-drama-batch-media-handoff>
        """
    }

    private static func batchScopeArguments(project: AgentShortDramaProject, targets: [BatchTarget]) -> String {
        let episodeIDs = Set(targets.map(\.episode.id))
        if episodeIDs.count == 1, let episodeID = episodeIDs.first {
            return "project_id=\(project.id.uuidString), episode_id=\(episodeID.uuidString), scope=episode"
        }
        return "project_id=\(project.id.uuidString), scope=project"
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

    private static func optionalUUID(_ value: AgentJSONValue?) -> UUID? {
        optionalString(value).flatMap(UUID.init(uuidString:))
    }

    private static func uuidArray(_ values: [String], argumentName: String) throws -> Set<UUID> {
        var result: Set<UUID> = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let uuid = UUID(uuidString: trimmed) else {
                throw AgentToolError.invalidArgument("\(argumentName) contains invalid UUID: \(value)")
            }
            result.insert(uuid)
        }
        return result
    }

    nonisolated private static func normalizedTargetFilter(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "missing", "missing_only", "gaps", "gaps_only":
            return "missing"
        case "missing_images", "missing_image":
            return "missing_images"
        case "missing_videos", "missing_video":
            return "missing_videos"
        default:
            return "all"
        }
    }

    nonisolated private static func matchesTargetFilter(_ shot: AgentShortDramaShot, kind: String, targetFilter: String) -> Bool {
        switch targetFilter {
        case "missing":
            return isImageGeneration(kind) ? selectedImagePath(for: shot) == nil : !hasVideoArtifact(shot)
        case "missing_images":
            return selectedImagePath(for: shot) == nil
        case "missing_videos":
            return !hasVideoArtifact(shot)
        default:
            return true
        }
    }

    nonisolated private static func isImageGeneration(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") != "video_generation"
    }

    nonisolated private static func isVideoGeneration(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") == "video_generation"
    }

    nonisolated private static func selectedImagePath(for shot: AgentShortDramaShot) -> String? {
        if let selected = shot.selectedArtifactPath?.trimmingCharacters(in: .whitespacesAndNewlines), isImagePath(selected) {
            return selected
        }
        return nil
    }

    nonisolated private static func hasVideoArtifact(_ shot: AgentShortDramaShot) -> Bool {
        shot.artifactPaths.contains(where: isVideoPath)
    }

    nonisolated private static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    nonisolated private static func isVideoPath(_ path: String) -> Bool {
        ["mp4", "mov", "m4v", "webm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
