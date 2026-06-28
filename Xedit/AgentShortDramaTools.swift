//
//  AgentShortDramaTools.swift
//  WillDeep
//
//  Built-in Agent tools for managing short-drama structure. Kept out of
//  AgentTools.swift so provider/media integrations do not push that
//  dispatcher past the file-size warning line.
//

import Foundation

enum AgentShortDramaTools {
    static func createProject(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let title = try requiredString(arguments, "title")
        let logline = optionalString(arguments["logline"])
        let project = await MainActor.run {
            store.createProject(title: title, logline: logline)
        }
        return AgentToolResult(
            summary: "short drama project: \(project.title)",
            payload: describe(project)
        )
    }

    static func importPlan(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let data = try planImportData(arguments: arguments)
        let project = try decodeImportedProject(from: data)
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        if dryRun {
            return AgentToolResult(
                summary: "dry-run short drama plan: \(project.title)",
                payload: """
                Short-drama plan dry-run. No project was created or updated.

                Project: \(project.title)
                Project id: \(project.id.uuidString)
                Characters: \(project.characters.count)
                Scenes: \(project.scenes.count)
                Episodes: \(project.episodes.count)
                Shots: \(project.episodes.reduce(0) { $0 + $1.shots.count })
                """
            )
        }
        let imported = await MainActor.run {
            store.importProject(project)
        }
        return AgentToolResult(
            summary: "imported short drama plan: \(imported.title)",
            payload: """
            Short-drama plan imported.

            Project: \(imported.title)
            Project id: \(imported.id.uuidString)
            Characters: \(imported.characters.count)
            Scenes: \(imported.scenes.count)
            Episodes: \(imported.episodes.count)
            Shots: \(imported.episodes.reduce(0) { $0 + $1.shots.count })
            Use short_drama_show_storyboard_widget to review it visually, then short_drama_generate_asset_media or short_drama_generate_shot_media to start media generation.
            """
        )
    }

    static func exportPlanTemplate(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let outputURL: URL
        if let outputPath = optionalString(arguments["output_path"]) {
            outputURL = URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath)
        } else {
            outputURL = AgentShortDramaPlanTemplate.defaultOutputURL()
        }
        let writtenURL = try AgentShortDramaPlanTemplate.write(to: outputURL)
        return AgentToolResult(
            summary: "short drama plan template: \(writtenURL.path)",
            payload: """
            Short-drama plan template exported.

            JSON: \(writtenURL.path)
            This file can be copied by a short-drama skill or Ruby script, filled with real characters/scenes/episodes/shots, then imported with short_drama_import_plan or the Short Drama side-panel import button.
            """
        )
    }

    static func upsertEpisode(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = optionalUUID(arguments["episode_id"])
        let title = try requiredString(arguments, "title")
        let summary = optionalString(arguments["summary"])
        let order = arguments["order"]?.intValue()
        let episode = await MainActor.run {
            store.upsertEpisode(projectID: projectID, episodeID: episodeID, title: title, summary: summary, order: order)
        }
        guard let episode else { throw AgentToolError.notFound(projectID.uuidString) }
        return AgentToolResult(
            summary: "episode \(episode.order): \(episode.title)",
            payload: describe(episode)
        )
    }

    static func upsertCharacter(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let name = try requiredString(arguments, "name")
        let character = await MainActor.run {
            store.upsertCharacter(
                projectID: projectID,
                characterID: optionalUUID(arguments["character_id"]),
                name: name,
                description: optionalString(arguments["description"]),
                visualPrompt: optionalString(arguments["visual_prompt"]),
                referenceImagePaths: arguments["reference_image_paths"]?.stringArrayValue() ?? []
            )
        }
        guard let character else { throw AgentToolError.notFound(projectID.uuidString) }
        return AgentToolResult(summary: "character: \(character.name)", payload: describe(character))
    }

    static func upsertScene(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let name = try requiredString(arguments, "name")
        let scene = await MainActor.run {
            store.upsertScene(
                projectID: projectID,
                sceneID: optionalUUID(arguments["scene_id"]),
                name: name,
                description: optionalString(arguments["description"]),
                visualPrompt: optionalString(arguments["visual_prompt"]),
                referenceImagePaths: arguments["reference_image_paths"]?.stringArrayValue() ?? []
            )
        }
        guard let scene else { throw AgentToolError.notFound(projectID.uuidString) }
        return AgentToolResult(summary: "scene: \(scene.name)", payload: describe(scene))
    }

    static func attachAssetReferenceImage(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let assetKind = parseAssetKind(try requiredString(arguments, "asset_kind"))
        let assetID = try requiredUUID(arguments, "asset_id")
        var imagePaths = arguments["image_paths"]?.stringArrayValue() ?? []
        if let imagePath = optionalString(arguments["image_path"]) {
            imagePaths.append(imagePath)
        }
        imagePaths = imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !imagePaths.isEmpty else {
            throw AgentToolError.missingArgument("image_path or image_paths")
        }
        let didAttach = await MainActor.run {
            store.attachReferenceImages(
                projectID: projectID,
                assetKind: assetKind,
                assetID: assetID,
                imagePaths: imagePaths
            )
        }
        guard didAttach else { throw AgentToolError.notFound(assetID.uuidString) }
        await MainActor.run {
            store.setActiveProject(id: projectID)
            if let runtimeID = context.runtimeID,
               let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
            }
        }
        let primaryImagePath = imagePaths.first ?? ""
        var followUp = [
            "<short-drama-asset-reference-attached>",
            "action: attach_asset_reference_image",
            "project_id: \(projectID.uuidString)",
            "asset_kind: \(assetKind)",
            "asset_id: \(assetID.uuidString)",
            "reference_count: \(imagePaths.count)",
            "open_asset_tasks_tool: short_drama_open_media_tasks",
            "open_asset_tasks_arguments: project_id=\(projectID.uuidString), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID.uuidString)",
            "generate_related_shots_tool: short_drama_generate_batch_media",
            "generate_related_shots_arguments: project_id=\(projectID.uuidString), kind=image_generation, dry_run=true"
        ]
        if !primaryImagePath.isEmpty {
            followUp.append("primary_image_path: \(primaryImagePath)")
            followUp.append("edit_tool: open_image_editor")
            followUp.append("edit_arguments: image_path=\(primaryImagePath), operation=inpaint, project_id=\(projectID.uuidString), asset_kind=\(assetKind), asset_id=\(assetID.uuidString)")
            followUp.append("erase_tool: open_image_editor")
            followUp.append("erase_arguments: image_path=\(primaryImagePath), operation=erase, project_id=\(projectID.uuidString), asset_kind=\(assetKind), asset_id=\(assetID.uuidString)")
            followUp.append("upscale_tool: upscale_image")
            followUp.append("upscale_arguments: image_path=\(primaryImagePath), project_id=\(projectID.uuidString), asset_kind=\(assetKind), asset_id=\(assetID.uuidString)")
        }
        followUp.append("reference_image_paths:")
        followUp.append(contentsOf: imagePaths.map { "- \($0)" })
        followUp.append("</short-drama-asset-reference-attached>")
        return AgentToolResult(
            summary: "attached \(imagePaths.count) reference image\(imagePaths.count == 1 ? "" : "s")",
            payload: """
            Attached reference images.

            Project id: \(projectID.uuidString)
            Asset kind: \(assetKind)
            Asset id: \(assetID.uuidString)
            Images:
            \(imagePaths.joined(separator: "\n"))

            Follow-up:
            \(followUp.joined(separator: "\n"))
            """
        )
    }

    static func upsertShot(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let title = try requiredString(arguments, "title")
        let shot = await MainActor.run {
            store.upsertShot(
                projectID: projectID,
                episodeID: episodeID,
                shotID: optionalUUID(arguments["shot_id"]),
                title: title,
                summary: optionalString(arguments["summary"]),
                prompt: optionalString(arguments["prompt"]),
                status: optionalString(arguments["status"]).map(parseShotStatus),
                order: arguments["order"]?.intValue(),
                sceneID: optionalUUID(arguments["scene_id"]),
                characterIDs: (arguments["character_ids"]?.stringArrayValue() ?? []).compactMap(UUID.init(uuidString:)),
                artifactPaths: arguments["artifact_paths"]?.stringArrayValue() ?? []
            )
        }
        guard let shot else { throw AgentToolError.notFound(episodeID.uuidString) }
        return AgentToolResult(summary: "shot \(shot.order): \(shot.title)", payload: describe(shot))
    }

    static func duplicateShot(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let sourceShotID = try requiredUUID(arguments, keys: ["source_shot_id", "shot_id"])
        let copyArtifacts = arguments["copy_artifacts"]?.boolValue() ?? false
        let copyReviewItems = arguments["copy_review_items"]?.boolValue() ?? false
        let shot = await MainActor.run {
            store.duplicateShot(
                projectID: projectID,
                episodeID: episodeID,
                sourceShotID: sourceShotID,
                title: optionalString(arguments["title"]),
                summary: optionalString(arguments["summary"]),
                prompt: optionalString(arguments["prompt"]),
                order: arguments["order"]?.intValue(),
                copyArtifacts: copyArtifacts,
                copyReviewItems: copyReviewItems
            )
        }
        guard let shot else { throw AgentToolError.notFound(sourceShotID.uuidString) }
        await MainActor.run {
            store.setActiveProject(id: projectID)
            if let runtimeID = context.runtimeID,
               let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
            }
        }
        let followUp = [
            "<short-drama-shot-duplicated>",
            "action: duplicate_shot",
            "project_id: \(projectID.uuidString)",
            "episode_id: \(episodeID.uuidString)",
            "source_shot_id: \(sourceShotID.uuidString)",
            "new_shot_id: \(shot.id.uuidString)",
            "new_shot_title: \(shot.title)",
            "new_shot_order: \(shot.order)",
            "copy_artifacts: \(copyArtifacts)",
            "copy_review_items: \(copyReviewItems)",
            "open_new_shot_tasks_tool: short_drama_open_media_tasks",
            "open_new_shot_tasks_arguments: project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shot.id.uuidString), scope=shot",
            "generate_new_shot_image_tool: short_drama_generate_shot_media",
            "generate_new_shot_image_arguments: project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shot.id.uuidString), kind=image_generation",
            "update_new_shot_tool: short_drama_upsert_shot",
            "update_new_shot_arguments: project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shot.id.uuidString), title=\(shot.title)",
            "</short-drama-shot-duplicated>"
        ]
        return AgentToolResult(
            summary: "duplicated shot \(shot.order): \(shot.title)",
            payload: """
            \(describe(shot))

            Follow-up:
            \(followUp.joined(separator: "\n"))
            """
        )
    }

    static func moveShot(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let sourceEpisodeID = optionalUUID(arguments["source_episode_id"]) ?? optionalUUID(arguments["episode_id"])
        let targetEpisodeID = try requiredUUID(arguments, "target_episode_id")
        let shotID = try requiredUUID(arguments, "shot_id")
        let shot = await MainActor.run {
            store.moveShot(
                projectID: projectID,
                sourceEpisodeID: sourceEpisodeID,
                targetEpisodeID: targetEpisodeID,
                shotID: shotID,
                order: arguments["order"]?.intValue()
            )
        }
        guard let shot else { throw AgentToolError.notFound(shotID.uuidString) }
        let updatedTaskCount = await MainActor.run {
            context.mediaTaskRegistry?.moveShortDramaShotAnchors(
                projectID: projectID,
                shotID: shotID,
                episodeID: targetEpisodeID
            ) ?? 0
        }
        await MainActor.run {
            store.setActiveProject(id: projectID)
            if let runtimeID = context.runtimeID,
               let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
            }
        }
        let followUp = [
            "<short-drama-shot-moved>",
            "action: move_shot",
            "project_id: \(projectID.uuidString)",
            sourceEpisodeID.map { "source_episode_id: \($0.uuidString)" } ?? "source_episode_id: (auto)",
            "target_episode_id: \(targetEpisodeID.uuidString)",
            "shot_id: \(shot.id.uuidString)",
            "shot_title: \(shot.title)",
            "new_shot_order: \(shot.order)",
            "updated_media_task_count: \(updatedTaskCount)",
            "open_moved_shot_tasks_tool: short_drama_open_media_tasks",
            "open_moved_shot_tasks_arguments: project_id=\(projectID.uuidString), episode_id=\(targetEpisodeID.uuidString), shot_id=\(shot.id.uuidString), scope=shot",
            "reorder_target_episode_tool: short_drama_reorder_structure_items",
            "reorder_target_episode_arguments: project_id=\(projectID.uuidString), item_type=shot, episode_id=\(targetEpisodeID.uuidString), ordered_ids=[按目标顺序填 shot_id], dry_run=true",
            "generate_moved_shot_image_tool: short_drama_generate_shot_media",
            "generate_moved_shot_image_arguments: project_id=\(projectID.uuidString), episode_id=\(targetEpisodeID.uuidString), shot_id=\(shot.id.uuidString), kind=image_generation",
            "</short-drama-shot-moved>"
        ]
        return AgentToolResult(
            summary: "moved shot \(shot.order): \(shot.title)",
            payload: """
            \(describe(shot))

            Moved to episode id: \(targetEpisodeID.uuidString)
            Updated media task anchors: \(updatedTaskCount)

            Follow-up:
            \(followUp.joined(separator: "\n"))
            """
        )
    }

    static func deleteStructureItem(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let itemType = try requiredString(arguments, "item_type")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let project = try await loadProject(store: store, projectID: projectID)
        let registry = context.mediaTaskRegistry
        let deletion: StructureDeletionPlan
        switch itemType {
        case "episode":
            let episodeID = try requiredUUID(arguments, "episode_id")
            guard let episode = project.episodes.first(where: { $0.id == episodeID }) else {
                throw AgentToolError.notFound(episodeID.uuidString)
            }
            deletion = StructureDeletionPlan(
                itemType: "episode",
                itemID: episodeID,
                title: episode.title,
                affectedShots: episode.shots.count,
                linkedMediaTasks: relatedMediaTasks(registry: registry, projectID: projectID, episodeID: episodeID)
            )
            if !dryRun {
                guard await MainActor.run(body: { store.deleteEpisode(projectID: projectID, episodeID: episodeID) }) != nil else {
                    throw AgentToolError.notFound(episodeID.uuidString)
                }
            }
        case "shot":
            let shotID = try requiredUUID(arguments, "shot_id")
            let episodeID = optionalUUID(arguments["episode_id"]) ?? project.episodes.first { episode in
                episode.shots.contains { $0.id == shotID }
            }?.id
            guard let episodeID,
                  let episode = project.episodes.first(where: { $0.id == episodeID }),
                  let shot = episode.shots.first(where: { $0.id == shotID }) else {
                throw AgentToolError.notFound(shotID.uuidString)
            }
            deletion = StructureDeletionPlan(
                itemType: "shot",
                itemID: shotID,
                title: shot.title,
                affectedShots: 1,
                linkedMediaTasks: relatedMediaTasks(registry: registry, projectID: projectID, episodeID: episodeID, shotID: shotID)
            )
            if !dryRun {
                guard await MainActor.run(body: { store.deleteShot(projectID: projectID, episodeID: episodeID, shotID: shotID) }) != nil else {
                    throw AgentToolError.notFound(shotID.uuidString)
                }
            }
        case "character", "scene":
            let assetKind = itemType
            let assetID = try requiredUUID(arguments, keys: ["asset_id", "\(assetKind)_id"])
            let asset = try assetSummary(project: project, kind: assetKind, id: assetID)
            let linkedShotCount = linkedShotCount(project: project, assetKind: assetKind, assetID: assetID)
            deletion = StructureDeletionPlan(
                itemType: assetKind,
                itemID: assetID,
                title: asset.name,
                affectedShots: linkedShotCount,
                linkedMediaTasks: relatedMediaTasks(registry: registry, projectID: projectID, assetKind: assetKind, assetID: assetID)
            )
            if !dryRun {
                if assetKind == "character" {
                    guard await MainActor.run(body: { store.deleteCharacter(projectID: projectID, characterID: assetID) }) != nil else {
                        throw AgentToolError.notFound(assetID.uuidString)
                    }
                } else {
                    guard await MainActor.run(body: { store.deleteScene(projectID: projectID, sceneID: assetID) }) != nil else {
                        throw AgentToolError.notFound(assetID.uuidString)
                    }
                }
            }
        default:
            throw AgentToolError.invalidArgument("item_type must be episode, shot, character, or scene.")
        }

        if !dryRun {
            await MainActor.run {
                store.setActiveProject(id: projectID)
                if let runtimeID = context.runtimeID,
                   let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                    appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
                }
            }
        }
        let action = dryRun ? "dry-run" : "deleted"
        return AgentToolResult(
            summary: "\(action) short drama \(deletion.itemType): \(deletion.title)",
            payload: """
            Short-drama structure delete \(dryRun ? "preview" : "completed").

            Project id: \(projectID.uuidString)
            Item type: \(deletion.itemType)
            Item id: \(deletion.itemID.uuidString)
            Title: \(deletion.title)
            Affected shots: \(deletion.affectedShots)
            Linked media tasks: \(deletion.linkedMediaTasks.count)

            Linked task handles:
            \(deletion.linkedMediaTasks.isEmpty ? "(none)" : deletion.linkedMediaTasks.map(\.displayHandle).joined(separator: "\n"))

            <short-drama-structure-delete>
            action: \(dryRun ? "preview_delete_structure_item" : "delete_structure_item")
            project_id: \(projectID.uuidString)
            item_type: \(deletion.itemType)
            item_id: \(deletion.itemID.uuidString)
            title: \(deletion.title)
            affected_shot_count: \(deletion.affectedShots)
            linked_media_task_count: \(deletion.linkedMediaTasks.count)
            dry_run: \(dryRun)
            refresh_project_tool: short_drama_list_projects
            open_project_tasks_tool: short_drama_open_media_tasks
            open_project_tasks_arguments: project_id=\(projectID.uuidString), scope=project
            </short-drama-structure-delete>
            """
        )
    }

    static func reorderStructureItems(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let itemType = try requiredString(arguments, "item_type")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let orderedIDs = try requiredStringArray(arguments, "ordered_ids")
            .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !orderedIDs.isEmpty else {
            throw AgentToolError.invalidArgument("ordered_ids must include at least one valid UUID.")
        }
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let project = try await loadProject(store: store, projectID: projectID)
        let result: ReorderStructureResult
        switch itemType {
        case "episode":
            let current = project.episodes.sorted { $0.order < $1.order }
            let currentIDs = Set(current.map(\.id))
            let unknownIDs = orderedIDs.filter { !currentIDs.contains($0) }
            guard unknownIDs.isEmpty else {
                throw AgentToolError.notFound(unknownIDs.map(\.uuidString).joined(separator: ", "))
            }
            let preview = reorderedItems(current.map { ($0.id, $0.title) }, orderedIDs: orderedIDs)
            if !dryRun {
                guard await MainActor.run(body: { store.reorderEpisodes(projectID: projectID, orderedIDs: orderedIDs) }) != nil else {
                    throw AgentToolError.notFound(projectID.uuidString)
                }
            }
            result = ReorderStructureResult(itemType: "episode", episodeID: nil, current: current.map { ($0.id, $0.title) }, preview: preview)
        case "shot":
            let episodeID = try requiredUUID(arguments, "episode_id")
            guard let episode = project.episodes.first(where: { $0.id == episodeID }) else {
                throw AgentToolError.notFound(episodeID.uuidString)
            }
            let current = episode.shots.sorted { $0.order < $1.order }
            let currentIDs = Set(current.map(\.id))
            let unknownIDs = orderedIDs.filter { !currentIDs.contains($0) }
            guard unknownIDs.isEmpty else {
                throw AgentToolError.notFound(unknownIDs.map(\.uuidString).joined(separator: ", "))
            }
            let preview = reorderedItems(current.map { ($0.id, $0.title) }, orderedIDs: orderedIDs)
            if !dryRun {
                guard await MainActor.run(body: { store.reorderShots(projectID: projectID, episodeID: episodeID, orderedIDs: orderedIDs) }) != nil else {
                    throw AgentToolError.notFound(episodeID.uuidString)
                }
            }
            result = ReorderStructureResult(itemType: "shot", episodeID: episodeID, current: current.map { ($0.id, $0.title) }, preview: preview)
        default:
            throw AgentToolError.invalidArgument("item_type must be episode or shot.")
        }

        if !dryRun {
            await MainActor.run {
                store.setActiveProject(id: projectID)
                if let runtimeID = context.runtimeID,
                   let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                    appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
                }
            }
        }
        let currentLines = enumeratedOrderLines(result.current)
        let nextLines = enumeratedOrderLines(result.preview)
        return AgentToolResult(
            summary: "\(dryRun ? "dry-run" : "reordered") short drama \(result.itemType)s",
            payload: """
            Short-drama structure reorder \(dryRun ? "preview" : "completed").

            Project id: \(projectID.uuidString)
            Item type: \(result.itemType)
            \(result.episodeID.map { "Episode id: \($0.uuidString)" } ?? "")

            Current order:
            \(currentLines)

            New order:
            \(nextLines)

            <short-drama-structure-reorder>
            action: \(dryRun ? "preview_reorder_structure_items" : "reorder_structure_items")
            project_id: \(projectID.uuidString)
            item_type: \(result.itemType)
            \(result.episodeID.map { "episode_id: \($0.uuidString)" } ?? "")
            ordered_ids: \(result.preview.map(\.0.uuidString).joined(separator: ","))
            dry_run: \(dryRun)
            refresh_project_tool: short_drama_list_projects
            </short-drama-structure-reorder>
            """
        )
    }

    static func generateShotMedia(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let shotID = try requiredUUID(arguments, "shot_id")
        let kind = parseMediaKind(optionalString(arguments["kind"]) ?? "image_generation")
        guard kind == .imageGeneration || kind == .videoGeneration else {
            throw AgentToolError.invalidArgument("kind must be image_generation or video_generation.")
        }

        let project = try await loadProject(store: store, projectID: projectID)
        guard let episode = project.episodes.first(where: { $0.id == episodeID }),
              let shot = episode.shots.first(where: { $0.id == shotID }) else {
            throw AgentToolError.notFound(shotID.uuidString)
        }

        let settings = SomeIMIntegrationStore.loadSettings()
        if kind == .videoGeneration, settings.normalized.preferredVideoModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentToolError.invalidArgument("Please configure Settings -> some.im preferred video model first.")
        }
        let prompt = AgentShortDramaPromptBuilder.prompt(
            project: project,
            shot: shot,
            override: optionalString(arguments["prompt_override"])
        )
        let model = optionalString(arguments["model"]) ?? SomeIMAsyncMediaClient.defaultModel(for: kind, settings: settings)
        let endpointSuffix = optionalString(arguments["endpoint_suffix"]) ?? SomeIMAsyncMediaClient.defaultEndpointSuffix(for: kind)
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
        ]
        var referencePathForDryRun: String?
        if kind == .imageGeneration {
            body["size"] = optionalString(arguments["size"]) ?? "1024x1024"
            body["response_format"] = "b64_json"
        } else if kind == .videoGeneration {
            let shouldUseReference = arguments["use_selected_artifact"]?.boolValue() ?? true
            let referencePath = optionalString(arguments["reference_image_path"]) ?? (shouldUseReference ? shot.selectedArtifactPath : nil)
            referencePathForDryRun = referencePath
            if let referencePath,
               isImagePath(referencePath),
               let imageDataURL = try? dataURL(for: URL(fileURLWithPath: referencePath)) {
                body["image"] = imageDataURL
            }
        }
        if dryRun {
            let baseArguments = "project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shotID.uuidString)"
            let submitArguments = "\(baseArguments), kind=\(kind.rawValue), dry_run=false"
            var lines = [
                "Short-drama media task dry-run.",
                "",
                "Project id: \(projectID.uuidString)",
                "Episode id: \(episodeID.uuidString)",
                "Shot id: \(shotID.uuidString)",
                "Shot title: \(shot.title)",
                "Kind: \(kind.rawValue)",
                "Model: \(model)",
                "Endpoint suffix: \(endpointSuffix)",
                "Prompt:",
                prompt
            ]
            if kind == .imageGeneration {
                lines.append("Size: \(body["size"] as? String ?? "1024x1024")")
            }
            if kind == .videoGeneration {
                lines.append("Reference image path: \(referencePathForDryRun ?? "(none)")")
                lines.append("Reference image attached: \(body["image"] == nil ? "false" : "true")")
            }
            lines += [
                "",
                "open_tasks_tool: short_drama_open_media_tasks",
                "open_tasks_arguments: \(baseArguments), scope=shot",
                "refresh_tasks_tool: short_drama_refresh_media_tasks",
                "refresh_tasks_arguments: \(baseArguments), scope=shot",
                "submit_tool: short_drama_generate_shot_media",
                "submit_arguments: \(submitArguments)"
            ]
            if let reviewItemID = optionalString(arguments["review_item_id"]) {
                lines.append("review_item_id: \(reviewItemID)")
            }
            return AgentToolResult(
                summary: "dry-run short drama \(kind.displayName): \(shot.title)",
                payload: lines.joined(separator: "\n")
            )
        }

        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }

        let response = try await SomeIMAsyncMediaClient.submit(
            endpointSuffix: endpointSuffix,
            body: body,
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let title = "\(shot.title) · \(kind.displayName)\(body["image"] == nil ? "" : " · 参考主图")"
        let artifacts = status == .succeeded
            ? try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title).map(\.mediaArtifact)
            : []
        let reviewItemID = optionalString(arguments["review_item_id"])
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
                reviewItemID: reviewItemID,
                runtimeID: context.runtimeID,
                projectID: projectID.uuidString,
                episodeID: episodeID.uuidString,
                shotID: shotID.uuidString,
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
            summary: "short drama \(kind.displayName): \(updated.displayHandle)",
            payload: """
            Short-drama media task submitted.

            Project id: \(projectID.uuidString)
            Episode id: \(episodeID.uuidString)
            Shot id: \(shotID.uuidString)
            Endpoint suffix: \(endpointSuffix)
            \(describe(mediaTask: updated))
            \(mediaSubmissionFollowUp(task: updated, action: "short_drama_generate_shot_media_follow_up"))
            """
        )
    }

    static func generateAssetMedia(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let assetKind = parseAssetKind(try requiredString(arguments, "asset_kind"))
        let assetID = try requiredUUID(arguments, "asset_id")
        let project = try await loadProject(store: store, projectID: projectID)
        let asset = try assetSummary(project: project, kind: assetKind, id: assetID)
        let dryRun = arguments["dry_run"]?.boolValue() ?? false

        let settings = SomeIMIntegrationStore.loadSettings()
        let prompt = optionalString(arguments["prompt_override"]) ?? asset.prompt
        let model = optionalString(arguments["model"]) ?? SomeIMAsyncMediaClient.defaultModel(for: .imageGeneration, settings: settings)
        let endpointSuffix = optionalString(arguments["endpoint_suffix"]) ?? SomeIMAsyncMediaClient.defaultEndpointSuffix(for: .imageGeneration)
        let size = optionalString(arguments["size"]) ?? "1024x1024"
        if dryRun {
            let taskArguments = "project_id=\(projectID.uuidString), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID.uuidString)"
            let submitArguments = "project_id=\(projectID.uuidString), asset_kind=\(assetKind), asset_id=\(assetID.uuidString), dry_run=false"
            return AgentToolResult(
                summary: "dry-run short drama \(asset.kindDisplayName) reference",
                payload: """
                Short-drama asset reference media task dry-run.

                Project id: \(projectID.uuidString)
                Asset kind: \(assetKind)
                Asset id: \(assetID.uuidString)
                Asset name: \(asset.name)
                Model: \(model)
                Size: \(size)
                Endpoint suffix: \(endpointSuffix)
                Prompt:
                \(prompt)

                open_tasks_tool: short_drama_open_media_tasks
                open_tasks_arguments: \(taskArguments)
                refresh_tasks_tool: short_drama_refresh_media_tasks
                refresh_tasks_arguments: \(taskArguments)
                submit_tool: short_drama_generate_asset_media
                submit_arguments: \(submitArguments)
                """
            )
        }

        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "size": size,
            "response_format": "b64_json",
        ]

        let response = try await SomeIMAsyncMediaClient.submit(
            endpointSuffix: endpointSuffix,
            body: body,
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let title = "\(asset.name) · \(asset.kindDisplayName)参考图"
        let artifacts = status == .succeeded
            ? try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: title).map(\.mediaArtifact)
            : []
        let task = await MainActor.run {
            registry.create(
                provider: .someIM,
                kind: .imageGeneration,
                title: title,
                prompt: prompt,
                model: model,
                remoteTaskID: response.id,
                statusURL: response.statusURL,
                cancelURL: response.cancelURL,
                statusEndpointSuffix: endpointSuffix,
                cancelEndpointSuffix: endpointSuffix,
                runtimeID: context.runtimeID,
                projectID: projectID.uuidString,
                assetKind: assetKind,
                assetID: assetID.uuidString,
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
            summary: "short drama \(asset.kindDisplayName) reference: \(updated.displayHandle)",
            payload: """
            Short-drama asset reference media task submitted.

            Project id: \(projectID.uuidString)
            Asset kind: \(assetKind)
            Asset id: \(assetID.uuidString)
            Asset name: \(asset.name)
            Endpoint suffix: \(endpointSuffix)
            \(describe(mediaTask: updated))
            \(mediaSubmissionFollowUp(task: updated, action: "short_drama_generate_asset_media_follow_up"))
            """
        )
    }

    static func upsertReviewItem(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let shotID = try requiredUUID(arguments, "shot_id")
        let title = try requiredString(arguments, "title")
        let item = await MainActor.run {
            store.upsertReviewItem(
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID,
                itemID: optionalUUID(arguments["item_id"]),
                kind: parseReviewKind(optionalString(arguments["kind"]) ?? "note"),
                severity: parseReviewSeverity(optionalString(arguments["severity"]) ?? "medium"),
                status: parseReviewStatus(optionalString(arguments["status"]) ?? "open"),
                title: title,
                detail: optionalString(arguments["detail"]),
                suggestedAction: optionalString(arguments["suggested_action"]),
                artifactPaths: arguments["artifact_paths"]?.stringArrayValue() ?? []
            )
        }
        guard let item else { throw AgentToolError.notFound(shotID.uuidString) }
        return AgentToolResult(
            summary: "review item: \(item.title)",
            payload: describe(item)
        )
    }

    static func importReviewCSV(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let csv = try reviewCSVString(arguments: arguments)
        let rows = try parseCSV(csv)
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let defaultKind = parseReviewKind(optionalString(arguments["kind"]) ?? "note")
        let defaultSeverity = parseReviewSeverity(optionalString(arguments["severity"]) ?? "medium")
        let defaultStatus = parseReviewStatus(optionalString(arguments["status"]) ?? "open")
        let project = try await loadProject(store: store, projectID: projectID)
        let existingShotIDs = Set(project.episodes.flatMap { $0.shots.map(\.id) })

        var imported: [String] = []
        var skipped: [String] = []
        for (offset, row) in rows.enumerated() {
            let rowNumber = offset + 2
            guard let shotID = uuidField(row, keys: ["shot_id", "shot id", "shotId"]) else {
                skipped.append("row \(rowNumber): missing shot_id")
                continue
            }
            guard existingShotIDs.contains(shotID) else {
                skipped.append("row \(rowNumber): unknown shot_id \(shotID.uuidString)")
                continue
            }
            guard let title = firstNonEmpty(row, keys: ["review_title", "title", "issue", "problem", "检查项", "问题"]) else {
                skipped.append("row \(rowNumber): missing review_title/title/issue")
                continue
            }
            let episodeID = uuidField(row, keys: ["episode_id", "episode id", "episodeId"])
            let kind = firstNonEmpty(row, keys: ["kind", "type", "类别"]).map(parseReviewKind) ?? defaultKind
            let explicitItemID = uuidField(row, keys: ["review_item_id", "item_id", "item id", "itemId"])
            let itemID = explicitItemID ?? existingReviewItemID(in: project, shotID: shotID, title: title, kind: kind)
            let severity = firstNonEmpty(row, keys: ["severity", "priority", "级别"]).map(parseReviewSeverity) ?? defaultSeverity
            let status = firstNonEmpty(row, keys: ["review_status", "status", "状态"]).map(parseReviewStatus) ?? defaultStatus
            let detail = firstNonEmpty(row, keys: ["detail", "notes", "note", "evidence", "说明", "备注"])
            let suggestedAction = firstNonEmpty(row, keys: ["suggested_action", "action", "fix", "建议动作", "处理建议"])
            let artifactPaths = splitPathList(firstNonEmpty(row, keys: ["artifact_paths", "artifact_path", "selected_image_path", "video_paths", "image_paths"]))

            let updateSuffix = itemID.map { " · update \($0.uuidString)" } ?? ""
            imported.append("row \(rowNumber): \(shotID.uuidString) · \(title)\(updateSuffix)")
            if dryRun { continue }
            let item = await MainActor.run {
                store.upsertReviewItem(
                    projectID: projectID,
                    episodeID: episodeID,
                    shotID: shotID,
                    itemID: itemID,
                    kind: kind,
                    severity: severity,
                    status: status,
                    title: title,
                    detail: detail,
                    suggestedAction: suggestedAction,
                    artifactPaths: artifactPaths
                )
            }
            if item == nil {
                skipped.append("row \(rowNumber): failed to attach review item to \(shotID.uuidString)")
            }
        }

        let action = dryRun ? "dry-run review CSV" : "imported review CSV"
        return AgentToolResult(
            summary: "\(action): \(imported.count) item\(imported.count == 1 ? "" : "s")",
            payload: """
            Short-drama review CSV \(dryRun ? "checked" : "imported").

            Project id: \(projectID.uuidString)
            Rows: \(rows.count)
            Imported: \(imported.count)
            Skipped: \(skipped.count)

            Imported items:
            \(imported.isEmpty ? "(none)" : imported.joined(separator: "\n"))

            Skipped rows:
            \(skipped.isEmpty ? "(none)" : skipped.joined(separator: "\n"))
            """
        )
    }

    static func resolveReviewItem(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let shotID = try requiredUUID(arguments, "shot_id")
        let itemID = try requiredUUID(arguments, keys: ["item_id", "review_item_id"])
        let item = await MainActor.run {
            store.resolveReviewItem(projectID: projectID, episodeID: episodeID, shotID: shotID, itemID: itemID)
        }
        guard let item else { throw AgentToolError.notFound(itemID.uuidString) }
        return AgentToolResult(
            summary: "resolved review item: \(item.title)",
            payload: describe(item)
        )
    }

    static func updateShotStatuses(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = optionalUUID(arguments["episode_id"])
        let status = parseShotStatus(try requiredString(arguments, "status"))
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let shotIDs = (arguments["shot_ids"]?.stringArrayValue() ?? [])
            .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let project = try await loadProject(store: store, projectID: projectID)
        let requestedIDs = Set(shotIDs)
        let matched = project.episodes.flatMap { episode -> [AgentShortDramaShot] in
            if let episodeID, episode.id != episodeID {
                return []
            }
            return episode.shots.filter { shot in
                requestedIDs.isEmpty || requestedIDs.contains(shot.id)
            }
        }
        guard !matched.isEmpty else {
            throw AgentToolError.notFound(episodeID?.uuidString ?? projectID.uuidString)
        }
        let updated: [AgentShortDramaShot]
        if dryRun {
            updated = matched
        } else {
            updated = await MainActor.run {
                store.updateShotStatuses(
                    projectID: projectID,
                    episodeID: episodeID,
                    shotIDs: shotIDs,
                    status: status
                ) ?? []
            }
            await MainActor.run {
                store.setActiveProject(id: projectID)
                if let runtimeID = context.runtimeID,
                   let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                    appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
                }
            }
        }
        let scope = episodeID == nil ? "project" : "episode"
        let updatedLines = updated
            .prefix(40)
            .map { "- \($0.id.uuidString) · \($0.order). \($0.title)" }
            .joined(separator: "\n")
        return AgentToolResult(
            summary: "\(dryRun ? "dry-run" : "updated") \(updated.count) short drama shot status\(updated.count == 1 ? "" : "es")",
            payload: """
            Short-drama shot status batch \(dryRun ? "preview" : "completed").

            Project id: \(projectID.uuidString)
            \(episodeID.map { "Episode id: \($0.uuidString)" } ?? "Episode id: (all)")
            Status: \(status.rawValue)
            Scope: \(scope)
            Matched shots: \(matched.count)
            Updated shots: \(updated.count)

            Shots:
            \(updatedLines.isEmpty ? "(none)" : updatedLines)

            <short-drama-shot-status-batch>
            action: \(dryRun ? "preview_update_shot_statuses" : "update_shot_statuses")
            project_id: \(projectID.uuidString)
            \(episodeID.map { "episode_id: \($0.uuidString)" } ?? "")
            status: \(status.rawValue)
            shot_ids: \(updated.map(\.id.uuidString).joined(separator: ","))
            dry_run: \(dryRun)
            open_tasks_tool: short_drama_open_media_tasks
            open_tasks_arguments: project_id=\(projectID.uuidString)\(episodeID.map { ", episode_id=\($0.uuidString), scope=episode" } ?? ", scope=project")
            batch_image_dry_run_tool: short_drama_generate_batch_media
            batch_image_dry_run_arguments: project_id=\(projectID.uuidString)\(episodeID.map { ", episode_id=\($0.uuidString)" } ?? ""), kind=image_generation, dry_run=true
            </short-drama-shot-status-batch>
            """
        )
    }

    static func updateShotLinks(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = optionalUUID(arguments["episode_id"])
        let dryRun = arguments["dry_run"]?.boolValue() ?? false
        let clearScene = arguments["clear_scene"]?.boolValue() ?? false
        let sceneID = optionalUUID(arguments["scene_id"])
        if clearScene, sceneID != nil {
            throw AgentToolError.invalidArgument("Use either scene_id or clear_scene, not both.")
        }
        let rawCharacterIDs = arguments["character_ids"]?.stringArrayValue()
        let characterIDs = try rawCharacterIDs.map { try uuidArray($0, argumentName: "character_ids") }
        let appendCharacterIDs = arguments["append_character_ids"]?.boolValue() ?? false
        let removeCharacterIDs = try uuidArray(arguments["remove_character_ids"]?.stringArrayValue() ?? [], argumentName: "remove_character_ids")
        let updateScene = sceneID != nil || clearScene
        guard updateScene || characterIDs != nil || !removeCharacterIDs.isEmpty else {
            throw AgentToolError.invalidArgument("Provide scene_id, clear_scene, character_ids, or remove_character_ids.")
        }
        let shotIDs = try uuidArray(arguments["shot_ids"]?.stringArrayValue() ?? [], argumentName: "shot_ids")
        let project = try await loadProject(store: store, projectID: projectID)
        if let episodeID, !project.episodes.contains(where: { $0.id == episodeID }) {
            throw AgentToolError.notFound(episodeID.uuidString)
        }
        if let sceneID, !project.scenes.contains(where: { $0.id == sceneID }) {
            throw AgentToolError.notFound(sceneID.uuidString)
        }
        let knownCharacterIDs = Set(project.characters.map(\.id))
        let requestedCharacterIDs = (characterIDs ?? []) + removeCharacterIDs
        let missingCharacterID = requestedCharacterIDs
            .first { !knownCharacterIDs.contains($0) }
        if let missingCharacterID {
            throw AgentToolError.notFound(missingCharacterID.uuidString)
        }
        let requestedIDs = Set(shotIDs)
        let matched = project.episodes.flatMap { episode -> [AgentShortDramaShot] in
            if let episodeID, episode.id != episodeID {
                return []
            }
            return episode.shots.filter { shot in
                requestedIDs.isEmpty || requestedIDs.contains(shot.id)
            }
        }
        guard !matched.isEmpty else {
            throw AgentToolError.notFound(episodeID?.uuidString ?? projectID.uuidString)
        }
        let updated: [AgentShortDramaShot]
        if dryRun {
            updated = matched
        } else {
            updated = await MainActor.run {
                store.updateShotLinks(
                    projectID: projectID,
                    episodeID: episodeID,
                    shotIDs: shotIDs,
                    updateScene: updateScene,
                    sceneID: sceneID,
                    characterIDs: characterIDs,
                    appendCharacterIDs: appendCharacterIDs,
                    removeCharacterIDs: removeCharacterIDs
                ) ?? []
            }
            await MainActor.run {
                store.setActiveProject(id: projectID)
                if let runtimeID = context.runtimeID,
                   let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                    appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
                }
            }
        }
        let updatedLines = updated
            .prefix(40)
            .map { shot in
                "- \(shot.id.uuidString) · \(shot.order). \(shot.title) · scene=\(shot.sceneID?.uuidString ?? "(none)") · characters=\(shot.characterIDs.map(\.uuidString).joined(separator: ","))"
            }
            .joined(separator: "\n")
        return AgentToolResult(
            summary: "\(dryRun ? "dry-run" : "updated") \(updated.count) short drama shot link\(updated.count == 1 ? "" : "s")",
            payload: """
            Short-drama shot link batch \(dryRun ? "preview" : "completed").

            Project id: \(projectID.uuidString)
            \(episodeID.map { "Episode id: \($0.uuidString)" } ?? "Episode id: (all)")
            Scene: \(updateScene ? (sceneID?.uuidString ?? "(cleared)") : "(unchanged)")
            Character mode: \(characterIDs == nil ? "(unchanged)" : (appendCharacterIDs ? "append" : "replace"))
            Characters: \((characterIDs ?? []).map(\.uuidString).joined(separator: ","))
            Remove characters: \(removeCharacterIDs.map(\.uuidString).joined(separator: ","))
            Matched shots: \(matched.count)
            Updated shots: \(updated.count)

            Shots:
            \(updatedLines.isEmpty ? "(none)" : updatedLines)

            <short-drama-shot-links-batch>
            action: \(dryRun ? "preview_update_shot_links" : "update_shot_links")
            project_id: \(projectID.uuidString)
            \(episodeID.map { "episode_id: \($0.uuidString)" } ?? "")
            scene_id: \(sceneID?.uuidString ?? "")
            clear_scene: \(clearScene)
            character_ids: \((characterIDs ?? []).map(\.uuidString).joined(separator: ","))
            append_character_ids: \(appendCharacterIDs)
            remove_character_ids: \(removeCharacterIDs.map(\.uuidString).joined(separator: ","))
            shot_ids: \(updated.map(\.id.uuidString).joined(separator: ","))
            dry_run: \(dryRun)
            open_tasks_tool: short_drama_open_media_tasks
            open_tasks_arguments: project_id=\(projectID.uuidString)\(episodeID.map { ", episode_id=\($0.uuidString), scope=episode" } ?? ", scope=project")
            batch_image_dry_run_tool: short_drama_generate_batch_media
            batch_image_dry_run_arguments: project_id=\(projectID.uuidString)\(episodeID.map { ", episode_id=\($0.uuidString)" } ?? ""), kind=image_generation, dry_run=true
            </short-drama-shot-links-batch>
            """
        )
    }

    static func selectShotArtifact(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let shotID = try requiredUUID(arguments, "shot_id")
        let artifactPath = try requiredString(arguments, "artifact_path")
        let reviewItemID = optionalString(arguments["review_item_id"])
        let shot = await MainActor.run {
            store.selectShotArtifact(
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID,
                artifactPath: artifactPath
            )
        }
        guard let shot else { throw AgentToolError.notFound(shotID.uuidString) }
        await MainActor.run {
            store.setActiveProject(id: projectID)
            if let runtimeID = context.runtimeID,
               let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
            }
        }
        var followUp = [
            "<short-drama-primary-artifact-selected>",
            "action: select_shot_primary_artifact",
            "image_path: \(artifactPath)",
            "artifact_path: \(artifactPath)",
            "project_id: \(projectID.uuidString)",
            "episode_id: \(episodeID.uuidString)",
            "shot_id: \(shotID.uuidString)",
            "Selected artifact: \(artifactPath)",
            "edit_tool: short_drama_open_image_editor",
            "edit_arguments: project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shotID.uuidString), artifact_path=\(artifactPath), operation=inpaint\(reviewItemID.map { ", review_item_id=\($0)" } ?? "")",
            "erase_tool: short_drama_open_image_editor",
            "erase_arguments: project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shotID.uuidString), artifact_path=\(artifactPath), operation=erase\(reviewItemID.map { ", review_item_id=\($0)" } ?? "")",
            "upscale_tool: short_drama_upscale_shot_artifact",
            "upscale_arguments: project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shotID.uuidString), artifact_path=\(artifactPath)\(reviewItemID.map { ", review_item_id=\($0)" } ?? "")",
            "video_from_image_tool: generate_video_from_image",
            "video_from_image_arguments: image_path=\(artifactPath), project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shotID.uuidString)\(reviewItemID.map { ", review_item_id=\($0)" } ?? "")"
        ]
        if let reviewItemID {
            followUp.insert("review_item_id: \(reviewItemID)", at: 7)
            followUp.append("resolve_review_tool: short_drama_resolve_review_item")
            followUp.append("resolve_review_arguments: project_id=\(projectID.uuidString), episode_id=\(episodeID.uuidString), shot_id=\(shotID.uuidString), item_id=\(reviewItemID)")
        }
        followUp.append("</short-drama-primary-artifact-selected>")
        return AgentToolResult(
            summary: "selected shot artifact: \(shot.title)",
            payload: """
            \(describe(shot))

            Follow-up:
            \(followUp.joined(separator: "\n"))
            """
        )
    }

    static func listProjects(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projects = await MainActor.run { store.projects }
        guard !projects.isEmpty else {
            return AgentToolResult(summary: "no short drama projects", payload: "No short drama projects yet.")
        }
        let payload = projects.map(describe).joined(separator: "\n\n")
        return AgentToolResult(summary: "\(projects.count) short drama project\(projects.count == 1 ? "" : "s")", payload: payload)
    }

    static func showStoryboardWidget(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let project = try await loadProject(store: store, projectID: projectID)
        let episodeID = optionalUUID(arguments["episode_id"])
        let episode = episodeID.flatMap { id in project.episodes.first(where: { $0.id == id }) }
        if let episodeID, episode == nil {
            throw AgentToolError.notFound(episodeID.uuidString)
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "short drama widget unavailable",
                payload: "short_drama_show_storyboard_widget is only available in conversational agent runtimes."
            )
        }
        let mediaTasks = context.mediaTaskRegistry?.tasks(forRuntime: runtimeID) ?? []
        let widget = episode.map { AgentShortDramaStoryboardWidgetBuilder.widget(for: project, episode: $0, mediaTasks: mediaTasks) }
            ?? AgentShortDramaStoryboardWidgetBuilder.widget(for: project, mediaTasks: mediaTasks)
        let bytes = widget.html.utf8.count
        await MainActor.run {
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            if let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
            }
        }
        let kbLabel = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
        return AgentToolResult(
            summary: "Queued short-drama storyboard widget: \(project.title)",
            payload: """
            Short-drama storyboard widget queued.

            Project: \(project.title)
            Project id: \(project.id.uuidString)
            Episode: \(episode.map { "\($0.title) (\($0.id.uuidString))" } ?? "(all)")
            Episodes: \(episode == nil ? project.episodes.count : 1)
            Shots: \(episode?.shots.count ?? project.episodes.reduce(0) { $0 + $1.shots.count })
            Widget size: \(kbLabel)
            The widget will appear in the transcript at the start of the next turn and the right-side Widget panel has been requested when available.
            """
        )
    }

    static func showImageChoiceWidget(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let shotID = try requiredUUID(arguments, "shot_id")
        let reviewItemID = optionalString(arguments["review_item_id"])
        let project = try await loadProject(store: store, projectID: projectID)
        guard let episode = project.episodes.first(where: { $0.id == episodeID }),
              let shot = episode.shots.first(where: { $0.id == shotID }) else {
            throw AgentToolError.notFound(shotID.uuidString)
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "short drama image choice widget unavailable",
                payload: "short_drama_show_image_choice_widget is only available in conversational agent runtimes."
            )
        }
        let widget = AgentShortDramaStoryboardWidgetBuilder.imageChoiceWidget(
            project: project,
            episode: episode,
            shot: shot,
            reviewItemID: reviewItemID
        )
        let bytes = widget.html.utf8.count
        await MainActor.run {
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            if let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
            }
        }
        let kbLabel = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
        return AgentToolResult(
            summary: "Queued short-drama image choice widget: \(shot.title)",
            payload: """
            Short-drama image choice widget queued.

            Project: \(project.title)
            Episode: \(episode.title)
            Shot: \(shot.title)
            Project id: \(project.id.uuidString)
            Episode id: \(episode.id.uuidString)
            Shot id: \(shot.id.uuidString)
            Review item id: \(reviewItemID ?? "(none)")
            Candidates: \(shot.artifactPaths.count)
            Widget size: \(kbLabel)
            The widget lets the user choose one artifact and asks the agent to call short_drama_select_shot_artifact with the selected path.
            """
        )
    }

    static func exportProductionPackage(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = optionalUUID(arguments["episode_id"])
        let includeResolved = arguments["include_resolved_review_items"]?.boolValue() ?? false
        let project = try await loadProject(store: store, projectID: projectID)
        let export = try AgentShortDramaProductionExporter.export(
            project: project,
            episodeID: episodeID,
            includeResolvedReviewItems: includeResolved
        )
        let widgetStatus = await queueProductionPackageWidgetIfAvailable(export: export, context: context)
        return AgentToolResult(
            summary: "Exported short-drama production package: \(export.directory.path)",
            payload: """
            Short-drama production package exported.

            Project: \(project.title)
            Project id: \(project.id.uuidString)
            Episode id: \(episodeID?.uuidString ?? "(all)")
            JSON: \(export.jsonURL.path)
            Markdown: \(export.markdownURL.path)
            Production timeline: \(export.timelineURL.path)
            Production gap report: \(export.gapReportURL.path)
            Production shot list CSV: \(export.shotListCSVURL.path)
            Production review template CSV: \(export.reviewTemplateCSVURL.path)
            Production review queue CSV: \(export.reviewQueueCSVURL.path)
            Media import manifest template: \(export.mediaManifestTemplateURL.path)
            Ruby script template: \(export.rubyScriptTemplateURL.path)
            Media API env example: \(export.envExampleURL.path)
            Widget preview HTML: \(export.widgetPreviewURL.path)
            Output directory: \(export.outputDirectory.path)
            Directory: \(export.directory.path)
            Widget panel: \(widgetStatus)

            <production-package-handoff>
            action: short_drama_export_production_package
            package_directory: \(export.directory.path)
            manifest_path: \(export.mediaManifestTemplateURL.path)
            widget_preview_path: \(export.widgetPreviewURL.path)
            review_template_path: \(export.reviewTemplateCSVURL.path)
            review_queue_path: \(export.reviewQueueCSVURL.path)
            gap_report_path: \(export.gapReportURL.path)
            timeline_path: \(export.timelineURL.path)
            shot_list_path: \(export.shotListCSVURL.path)
            dry_run_import_tool: import_media_manifest
            dry_run_import_arguments: package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true
            submit_import_tool: import_media_manifest
            submit_import_arguments: package_directory=\(export.directory.path), dry_run=false, import_pending_tasks=true
            review_template_import_tool: short_drama_import_review_csv
            review_template_import_arguments: package_directory=\(export.directory.path), dry_run=true
            review_queue_import_tool: short_drama_import_review_csv
            review_queue_import_arguments: file_path=\(export.reviewQueueCSVURL.path), dry_run=true
            widget_tool: show_widget
            widget_arguments: title=短剧制作预览, html_path=\(export.widgetPreviewURL.path)
            </production-package-handoff>
            """
        )
    }

    private static func queueProductionPackageWidgetIfAvailable(
        export: AgentShortDramaProductionExporter.ExportResult,
        context: AgentToolContext
    ) async -> String {
        guard let runtimeID = context.runtimeID else {
            return "not queued (no conversational runtime)"
        }
        guard let html = try? String(contentsOf: export.widgetPreviewURL, encoding: .utf8),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "not queued (widget-preview.html unavailable)"
        }
        let contextLines = [
            "<production-package-handoff>",
            "action: short_drama_export_production_package_widget",
            "source_label: short_drama_export_production_package",
            "source_path: \(export.widgetPreviewURL.path)",
            "package_directory: \(export.directory.path)",
            "manifest_path: \(export.mediaManifestTemplateURL.path)",
            "widget_preview_path: \(export.widgetPreviewURL.path)",
            "review_template_path: \(export.reviewTemplateCSVURL.path)",
            "review_queue_path: \(export.reviewQueueCSVURL.path)",
            "gap_report_path: \(export.gapReportURL.path)",
            "timeline_path: \(export.timelineURL.path)",
            "shot_list_path: \(export.shotListCSVURL.path)",
            "dry_run_import_tool: import_media_manifest",
            "dry_run_import_arguments: package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true",
            "submit_import_tool: import_media_manifest",
            "submit_import_arguments: package_directory=\(export.directory.path), dry_run=false, import_pending_tasks=true",
            "review_template_import_tool: short_drama_import_review_csv",
            "review_template_import_arguments: package_directory=\(export.directory.path), dry_run=true",
            "review_queue_import_tool: short_drama_import_review_csv",
            "review_queue_import_arguments: file_path=\(export.reviewQueueCSVURL.path), dry_run=true",
            "widget_tool: show_widget",
            "widget_arguments: title=短剧制作预览, html_path=\(export.widgetPreviewURL.path)",
            "recommended_tool: import_media_manifest",
            "recommended_arguments: package_directory=\(export.directory.path), dry_run=true, import_pending_tasks=true",
            "widget_context: production_package_preview",
            "</production-package-handoff>"
        ]
        let widget = AgentWidget(title: "短剧制作预览", html: html, contextLines: contextLines)
        await MainActor.run {
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            if let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) {
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
            }
        }
        return "queued in right-side Widget panel"
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

    private static func requiredString(_ arguments: [String: AgentJSONValue], _ key: String) throws -> String {
        guard let value = optionalString(arguments[key]) else {
            throw AgentToolError.missingArgument(key)
        }
        return value
    }

    private static func requiredStringArray(_ arguments: [String: AgentJSONValue], _ key: String) throws -> [String] {
        guard let values = arguments[key]?.stringArrayValue(), !values.isEmpty else {
            throw AgentToolError.missingArgument(key)
        }
        return values
    }

    private static func uuidArray(_ values: [String], argumentName: String) throws -> [UUID] {
        try values.map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: trimmed) else {
                throw AgentToolError.invalidArgument("\(argumentName) contains invalid UUID: \(raw)")
            }
            return uuid
        }
    }

    private static func requiredUUID(_ arguments: [String: AgentJSONValue], _ key: String) throws -> UUID {
        guard let uuid = optionalUUID(arguments[key]) else {
            throw AgentToolError.missingArgument(key)
        }
        return uuid
    }

    private static func requiredUUID(_ arguments: [String: AgentJSONValue], keys: [String]) throws -> UUID {
        for key in keys {
            if let uuid = optionalUUID(arguments[key]) {
                return uuid
            }
        }
        throw AgentToolError.missingArgument(keys.joined(separator: "/"))
    }

    private static func loadProject(store: AgentShortDramaStore, projectID: UUID) async throws -> AgentShortDramaProject {
        let project = await MainActor.run {
            store.project(id: projectID)
        }
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

    private static func planImportData(arguments: [String: AgentJSONValue]) throws -> Data {
        if let json = optionalString(arguments["json"]) ?? optionalString(arguments["plan_json"]) {
            guard let data = json.data(using: .utf8) else {
                throw AgentToolError.invalidArgument("json must be valid UTF-8.")
            }
            return data
        }
        if let filePath = optionalString(arguments["file_path"]) ?? optionalString(arguments["plan_path"]) {
            let url = URL(fileURLWithPath: NSString(string: filePath).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw AgentToolError.notFound(url.path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard fileSize <= 2_000_000 else {
                throw AgentToolError.fileTooLarge(url.path)
            }
            return try Data(contentsOf: url)
        }
        throw AgentToolError.missingArgument("json or file_path")
    }

    private static func reviewCSVString(arguments: [String: AgentJSONValue]) throws -> String {
        if let csv = optionalString(arguments["csv"]) {
            return csv
        }
        if let filePath = optionalString(arguments["file_path"]) ?? optionalString(arguments["csv_path"]) {
            let url = URL(fileURLWithPath: NSString(string: filePath).expandingTildeInPath)
            return try reviewCSVFileString(url)
        }
        if let packageDirectory = optionalString(arguments["package_directory"]) {
            let url = URL(fileURLWithPath: NSString(string: packageDirectory).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("production-review-template.csv", isDirectory: false)
            return try reviewCSVFileString(url)
        }
        throw AgentToolError.missingArgument("csv, file_path, or package_directory")
    }

    private static func reviewCSVFileString(_ url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AgentToolError.notFound(url.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= 2_000_000 else {
            throw AgentToolError.fileTooLarge(url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func parseCSV(_ text: String) throws -> [[String: String]] {
        let rows = csvRows(text)
        guard let header = rows.first else { return [] }
        let keys = header.map(normalizeCSVHeader)
        guard keys.contains("shot_id") || keys.contains("shot id") || keys.contains("shotid") else {
            throw AgentToolError.invalidArgument("CSV must include a shot_id column.")
        }
        return rows.dropFirst().compactMap { row in
            var record: [String: String] = [:]
            for (index, key) in keys.enumerated() where !key.isEmpty {
                guard index < row.count else { continue }
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    record[key] = value
                }
            }
            return record.isEmpty ? nil : record
        }
    }

    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var iterator = Array(text).makeIterator()
        var inQuotes = false
        while let character = iterator.next() {
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                row.append(field)
                                field = ""
                            } else if next == "\n" {
                                row.append(field)
                                rows.append(row)
                                row = []
                                field = ""
                            } else if next != "\r" {
                                field.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { fields in
            fields.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    nonisolated private static func normalizeCSVHeader(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func firstNonEmpty(_ row: [String: String], keys: [String]) -> String? {
        for key in keys {
            let normalized = normalizeCSVHeader(key)
            if let value = row[normalized]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func uuidField(_ row: [String: String], keys: [String]) -> UUID? {
        firstNonEmpty(row, keys: keys).flatMap(UUID.init(uuidString:))
    }

    private static func existingReviewItemID(
        in project: AgentShortDramaProject,
        shotID: UUID,
        title: String,
        kind: AgentShortDramaReviewItemKind
    ) -> UUID? {
        let normalizedTitle = normalizeReviewTitle(title)
        guard !normalizedTitle.isEmpty else { return nil }
        for episode in project.episodes {
            guard let shot = episode.shots.first(where: { $0.id == shotID }) else { continue }
            return shot.reviewItems.first { item in
                item.status != .resolved &&
                    item.kind == kind &&
                    normalizeReviewTitle(item.title) == normalizedTitle
            }?.id
        }
        return nil
    }

    nonisolated private static func normalizeReviewTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func splitPathList(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.components(separatedBy: CharacterSet(charactersIn: "\n;|"))
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func decodeImportedProject(from data: Data) throws -> AgentShortDramaProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let package = try? decoder.decode(AgentShortDramaProductionExporter.Package.self, from: data) {
            return package.project
        }
        if let project = try? decoder.decode(AgentShortDramaProject.self, from: data) {
            return project
        }
        do {
            return try decoder.decode(ShortDramaPlanDocument.self, from: data).project()
        } catch {
            throw AgentToolError.invalidArgument("Could not decode short-drama plan JSON: \(error.localizedDescription)")
        }
    }

    nonisolated private static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    nonisolated private static func preferredSelectedArtifact(in paths: [String]) -> String? {
        paths.first(where: isImagePath) ?? paths.first
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

    private static func parseShotStatus(_ raw: String) -> AgentShortDramaShotStatus {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "planned", "plan": return .planned
        case "scripting", "writing": return .scripting
        case "generating", "generation", "rendering": return .generating
        case "ready", "done", "complete", "completed": return .ready
        case "needs_review", "review", "needsreview": return .needsReview
        default: return .planned
        }
    }

    private static func parseMediaKind(_ raw: String) -> AgentMediaTaskKind {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "image", "image_generation", "imagegeneration":
            return .imageGeneration
        case "video", "video_generation", "videogeneration":
            return .videoGeneration
        default:
            return .imageGeneration
        }
    }

    private static func parseAssetKind(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "scene", "scenes", "location", "locations":
            return "scene"
        default:
            return "character"
        }
    }

    private static func assetSummary(project: AgentShortDramaProject, kind: String, id: UUID) throws -> AssetGenerationSummary {
        switch kind {
        case "scene":
            guard let scene = project.scenes.first(where: { $0.id == id }) else {
                throw AgentToolError.notFound(id.uuidString)
            }
            let prompt = [
                scene.visualPrompt,
                scene.description,
                project.logline.map { "Project logline: \($0)" },
            ]
                .compactMap(optionalPromptSection)
                .joined(separator: "\n\n")
            return AssetGenerationSummary(kindDisplayName: "场景", name: scene.name, prompt: prompt.isEmpty ? scene.name : prompt)
        default:
            guard let character = project.characters.first(where: { $0.id == id }) else {
                throw AgentToolError.notFound(id.uuidString)
            }
            let prompt = [
                character.visualPrompt,
                character.description,
                project.logline.map { "Project logline: \($0)" },
            ]
                .compactMap(optionalPromptSection)
                .joined(separator: "\n\n")
            return AssetGenerationSummary(kindDisplayName: "人物", name: character.name, prompt: prompt.isEmpty ? character.name : prompt)
        }
    }

    nonisolated private static func optionalPromptSection(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func parseReviewKind(_ raw: String) -> AgentShortDramaReviewItemKind {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "continuity", "consistent", "consistency": return .continuity
        case "prompt", "prompt_fix": return .prompt
        case "redraw", "inpaint", "repaint": return .redraw
        case "erase", "remove": return .erase
        case "upscale", "enhance": return .upscale
        case "reshoot", "regenerate", "shoot": return .reshoot
        default: return .note
        }
    }

    private static func parseReviewSeverity(_ raw: String) -> AgentShortDramaReviewItemSeverity {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low", "minor": return .low
        case "high", "critical", "major": return .high
        default: return .medium
        }
    }

    private static func parseReviewStatus(_ raw: String) -> AgentShortDramaReviewItemStatus {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "doing", "in_progress", "processing": return .doing
        case "resolved", "done", "fixed", "closed": return .resolved
        default: return .open
        }
    }

    private static func describe(mediaTask task: AgentMediaTask) -> String {
        """
        Task: \(task.displayHandle)
        Provider: \(task.provider.displayName)
        Kind: \(task.kind.displayName)
        Status: \(task.status.displayName)
        Prompt: \(task.prompt ?? "(none)")
        Model: \(task.model ?? "(none)")
        Remote task id: \(task.remoteTaskID ?? "(none)")
        Status URL: \(task.statusURL ?? "(none)")
        Cancel URL: \(task.cancelURL ?? "(none)")
        Status endpoint suffix: \(task.statusEndpointSuffix ?? "(none)")
        Cancel endpoint suffix: \(task.cancelEndpointSuffix ?? "(none)")
        Source image: \(task.sourceImagePath ?? "(none)")
        Mask: \(task.maskPath ?? "(none)")
        Asset kind: \(task.assetKind ?? "(none)")
        Asset id: \(task.assetID ?? "(none)")
        Artifacts: \(task.artifacts.isEmpty ? "(none)" : task.artifacts.map(\.filePath).joined(separator: "\n"))
        """
    }

    private static func mediaSubmissionFollowUp(task: AgentMediaTask, action: String) -> String {
        guard let scopeArguments = mediaTaskScopeArguments(task: task) else { return "" }
        var lines = [
            "<short-drama-media-submission-follow-up>",
            "action: \(action)",
            "task_id: \(task.displayHandle)",
            "open_tasks_tool: short_drama_open_media_tasks",
            "open_tasks_arguments: \(scopeArguments)",
            "refresh_tasks_tool: short_drama_refresh_media_tasks",
            "refresh_tasks_arguments: \(scopeArguments)"
        ]
        appendCleanLine("project_id", task.projectID, to: &lines)
        appendCleanLine("episode_id", task.episodeID, to: &lines)
        appendCleanLine("shot_id", task.shotID, to: &lines)
        appendCleanLine("asset_kind", task.assetKind, to: &lines)
        appendCleanLine("asset_id", task.assetID, to: &lines)
        appendCleanLine("review_item_id", task.reviewItemID, to: &lines)
        if task.status == .succeeded {
            lines.append(contentsOf: completedMediaSubmissionLines(task: task))
        }
        lines.append("</short-drama-media-submission-follow-up>")
        return lines.joined(separator: "\n")
    }

    private static func completedMediaSubmissionLines(task: AgentMediaTask) -> [String] {
        let imageArtifacts = task.artifacts.filter { isImagePath($0.filePath) }
        guard !imageArtifacts.isEmpty else { return [] }
        if mediaClean(task.episodeID) != nil, mediaClean(task.shotID) != nil {
            let shotArguments = mediaTaskShotArguments(task: task)
            if imageArtifacts.count > 1 {
                return [
                    "image_choice_tool: short_drama_show_image_choice_widget",
                    "image_choice_arguments: \(shotArguments)"
                ]
            }
            guard let artifact = imageArtifacts.first else { return [] }
            return [
                "select_primary_tool: short_drama_select_shot_artifact",
                "select_primary_arguments: \(shotArguments), artifact_path=\(artifact.filePath)",
                "video_from_image_tool: generate_video_from_image",
                "video_from_image_arguments: \(shotArguments), image_path=\(artifact.filePath)"
            ]
        }
        if mediaClean(task.assetKind) != nil, mediaClean(task.assetID) != nil,
           let artifact = imageArtifacts.first {
            let assetArguments = mediaTaskAssetArguments(task: task)
            return [
                "attach_reference_tool: short_drama_attach_asset_reference_image",
                "attach_reference_arguments: \(assetArguments), image_path=\(artifact.filePath)",
                "edit_tool: open_image_editor",
                "edit_arguments: \(assetArguments), image_path=\(artifact.filePath), operation=inpaint",
                "erase_tool: open_image_editor",
                "erase_arguments: \(assetArguments), image_path=\(artifact.filePath), operation=erase",
                "upscale_tool: upscale_image",
                "upscale_arguments: \(assetArguments), image_path=\(artifact.filePath)"
            ]
        }
        return []
    }

    private static func mediaTaskScopeArguments(task: AgentMediaTask) -> String? {
        guard let projectID = mediaClean(task.projectID) ?? mediaClean(task.projectPath) else { return nil }
        var pairs = ["project_id=\(projectID)"]
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        if let assetKind = mediaClean(task.assetKind), let assetID = mediaClean(task.assetID) {
            pairs.append("asset_kind=\(assetKind)")
            pairs.append("asset_id=\(assetID)")
            pairs.append("scope=asset")
        } else if let reviewItemID = mediaClean(task.reviewItemID) {
            pairs.append("review_item_id=\(reviewItemID)")
            pairs.append("scope=review_item")
        } else if mediaClean(task.shotID) != nil {
            pairs.append("scope=shot")
        } else if mediaClean(task.episodeID) != nil {
            pairs.append("scope=episode")
        } else {
            pairs.append("scope=project")
        }
        return pairs.joined(separator: ", ")
    }

    private static func mediaTaskShotArguments(task: AgentMediaTask) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("episode_id", task.episodeID, to: &pairs)
        appendCleanPair("shot_id", task.shotID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func mediaTaskAssetArguments(task: AgentMediaTask) -> String {
        var pairs: [String] = []
        appendCleanPair("project_id", task.projectID, to: &pairs)
        appendCleanPair("asset_kind", task.assetKind, to: &pairs)
        appendCleanPair("asset_id", task.assetID, to: &pairs)
        appendCleanPair("review_item_id", task.reviewItemID, to: &pairs)
        return pairs.joined(separator: ", ")
    }

    private static func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = mediaClean(value) else { return }
        lines.append("\(key): \(value)")
    }

    private static func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [String]) {
        guard let value = mediaClean(value) else { return }
        pairs.append("\(key)=\(value)")
    }

    private static func mediaClean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private struct StructureDeletionPlan {
        var itemType: String
        var itemID: UUID
        var title: String
        var affectedShots: Int
        var linkedMediaTasks: [AgentMediaTask]
    }

    private struct ReorderStructureResult {
        var itemType: String
        var episodeID: UUID?
        var current: [(UUID, String)]
        var preview: [(UUID, String)]
    }

    private static func reorderedItems(_ current: [(UUID, String)], orderedIDs: [UUID]) -> [(UUID, String)] {
        let requested = orderedIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) {
                result.append(id)
            }
        }
        var result: [(UUID, String)] = []
        for id in requested {
            if let item = current.first(where: { $0.0 == id }) {
                result.append(item)
            }
        }
        result.append(contentsOf: current.filter { item in !requested.contains(item.0) })
        return result
    }

    private static func enumeratedOrderLines(_ items: [(UUID, String)]) -> String {
        guard !items.isEmpty else { return "(none)" }
        return items.enumerated()
            .map { index, item in "\(index + 1). \(item.1) · \(item.0.uuidString)" }
            .joined(separator: "\n")
    }

    private static func relatedMediaTasks(
        registry: AgentMediaTaskRegistry?,
        projectID: UUID,
        episodeID: UUID? = nil,
        shotID: UUID? = nil,
        assetKind: String? = nil,
        assetID: UUID? = nil
    ) -> [AgentMediaTask] {
        guard let registry else { return [] }
        let projectValue = projectID.uuidString
        return registry.tasks.filter { task in
            guard task.projectID == projectValue || task.projectPath == projectValue else {
                return false
            }
            if let shotID {
                return task.shotID == shotID.uuidString
            }
            if let episodeID {
                return task.episodeID == episodeID.uuidString
            }
            if let assetKind, let assetID {
                return task.assetKind == assetKind && task.assetID == assetID.uuidString
            }
            return true
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func linkedShotCount(project: AgentShortDramaProject, assetKind: String, assetID: UUID) -> Int {
        project.episodes.reduce(0) { total, episode in
            total + episode.shots.filter { shot in
                if assetKind == "scene" {
                    return shot.sceneID == assetID
                }
                return shot.characterIDs.contains(assetID)
            }.count
        }
    }

    private static func describe(_ item: AgentShortDramaReviewItem) -> String {
        """
        Review item: \(item.title)
        Review item id: \(item.id.uuidString)
        Kind: \(item.kind.rawValue)
        Severity: \(item.severity.rawValue)
        Status: \(item.status.rawValue)
        Detail: \(item.detail ?? "(none)")
        Suggested action: \(item.suggestedAction ?? "(none)")
        Artifacts: \(item.artifactPaths.isEmpty ? "(none)" : item.artifactPaths.joined(separator: "\n"))
        """
    }

    private static func describe(_ project: AgentShortDramaProject) -> String {
        """
        Project: \(project.title)
        Project id: \(project.id.uuidString)
        Logline: \(project.logline ?? "(none)")
        Episodes: \(project.episodes.count)
        Shots: \(project.episodes.reduce(0) { $0 + $1.shots.count })
        Characters: \(project.characters.count)
        Scenes: \(project.scenes.count)
        """
    }

    private static func describe(_ episode: AgentShortDramaEpisode) -> String {
        """
        Episode: \(episode.title)
        Episode id: \(episode.id.uuidString)
        Order: \(episode.order)
        Summary: \(episode.summary ?? "(none)")
        Shots: \(episode.shots.count)
        """
    }

    private static func describe(_ character: AgentShortDramaCharacter) -> String {
        """
        Character: \(character.name)
        Character id: \(character.id.uuidString)
        Description: \(character.description ?? "(none)")
        Visual prompt: \(character.visualPrompt ?? "(none)")
        Reference images: \(character.referenceImagePaths.isEmpty ? "(none)" : character.referenceImagePaths.joined(separator: "\n"))
        """
    }

    private static func describe(_ scene: AgentShortDramaScene) -> String {
        """
        Scene: \(scene.name)
        Scene id: \(scene.id.uuidString)
        Description: \(scene.description ?? "(none)")
        Visual prompt: \(scene.visualPrompt ?? "(none)")
        Reference images: \(scene.referenceImagePaths.isEmpty ? "(none)" : scene.referenceImagePaths.joined(separator: "\n"))
        """
    }

    private static func describe(_ shot: AgentShortDramaShot) -> String {
        """
        Shot: \(shot.title)
        Shot id: \(shot.id.uuidString)
        Order: \(shot.order)
        Status: \(shot.status.rawValue)
        Summary: \(shot.summary ?? "(none)")
        Prompt: \(shot.prompt ?? "(none)")
        Scene id: \(shot.sceneID?.uuidString ?? "(none)")
        Character ids: \(shot.characterIDs.isEmpty ? "(none)" : shot.characterIDs.map(\.uuidString).joined(separator: ", "))
        Selected artifact: \(shot.selectedArtifactPath ?? "(none)")
        Artifacts: \(shot.artifactPaths.isEmpty ? "(none)" : shot.artifactPaths.joined(separator: "\n"))
        Review items: \(shot.reviewItems.isEmpty ? "(none)" : shot.reviewItems.map { "[\($0.status.rawValue)/\($0.kind.rawValue)/\($0.severity.rawValue)] \($0.title)" }.joined(separator: "\n"))
        """
    }

    private struct AssetGenerationSummary {
        var kindDisplayName: String
        var name: String
        var prompt: String
    }

    private struct ShortDramaPlanDocument: Decodable {
        var projectID: String?
        var title: String
        var logline: String?
        var characters: [Asset]?
        var scenes: [Asset]?
        var episodes: [Episode]

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case title
            case logline
            case characters
            case scenes
            case episodes
        }

        func project() -> AgentShortDramaProject {
            let projectUUID = UUID(uuidString: projectID ?? "") ?? UUID()
            let normalizedCharacters = (characters ?? []).map(\.character)
            let normalizedScenes = (scenes ?? []).map(\.scene)
            let characterLookup = Self.lookup(from: characters ?? [], ids: normalizedCharacters.map(\.id))
            let sceneLookup = Self.lookup(from: scenes ?? [], ids: normalizedScenes.map(\.id))
            let normalizedEpisodes = episodes.enumerated().map { index, episode in
                episode.normalized(
                    fallbackOrder: index + 1,
                    characterLookup: characterLookup,
                    sceneLookup: sceneLookup
                )
            }
            return AgentShortDramaProject(
                id: projectUUID,
                title: title,
                logline: logline,
                characters: normalizedCharacters,
                scenes: normalizedScenes,
                episodes: normalizedEpisodes,
                createdAt: Date(),
                updatedAt: Date()
            )
        }

        private static func lookup(from assets: [Asset], ids: [UUID]) -> [String: UUID] {
            var result: [String: UUID] = [:]
            for (asset, uuid) in zip(assets, ids) {
                for key in asset.lookupKeys {
                    result[key] = uuid
                }
            }
            return result
        }

        struct Asset: Decodable {
            var id: String?
            var name: String
            var description: String?
            var visualPrompt: String?
            var referenceImagePaths: [String]?

            enum CodingKeys: String, CodingKey {
                case id
                case name
                case description
                case visualPrompt = "visual_prompt"
                case referenceImagePaths = "reference_image_paths"
            }

            var generatedID: UUID {
                UUID(uuidString: id ?? "") ?? UUID()
            }

            var character: AgentShortDramaCharacter {
                AgentShortDramaCharacter(
                    id: generatedID,
                    name: name,
                    description: description,
                    visualPrompt: visualPrompt,
                    referenceImagePaths: referenceImagePaths ?? []
                )
            }

            var scene: AgentShortDramaScene {
                AgentShortDramaScene(
                    id: generatedID,
                    name: name,
                    description: description,
                    visualPrompt: visualPrompt,
                    referenceImagePaths: referenceImagePaths ?? []
                )
            }

            var lookupKeys: [String] {
                ([id, name] + [ShortDramaPlanDocument.slug(name)]).compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            }
        }

        struct Episode: Decodable {
            var id: String?
            var title: String
            var summary: String?
            var order: Int?
            var shots: [Shot]?

            func normalized(
                fallbackOrder: Int,
                characterLookup: [String: UUID],
                sceneLookup: [String: UUID]
            ) -> AgentShortDramaEpisode {
                let episodeID = UUID(uuidString: id ?? "") ?? UUID()
                let normalizedShots = (shots ?? []).enumerated().map { index, shot in
                    shot.normalized(
                        fallbackOrder: index + 1,
                        characterLookup: characterLookup,
                        sceneLookup: sceneLookup
                    )
                }.sorted { $0.order < $1.order }
                return AgentShortDramaEpisode(
                    id: episodeID,
                    title: title,
                    summary: summary,
                    order: order ?? fallbackOrder,
                    shots: normalizedShots,
                    updatedAt: Date()
                )
            }
        }

        struct Shot: Decodable {
            var id: String?
            var title: String
            var summary: String?
            var prompt: String?
            var status: String?
            var order: Int?
            var sceneID: String?
            var scene: String?
            var characterIDs: [String]?
            var characters: [String]?
            var artifactPaths: [String]?
            var selectedArtifactPath: String?

            enum CodingKeys: String, CodingKey {
                case id
                case title
                case summary
                case prompt
                case status
                case order
                case sceneID = "scene_id"
                case scene
                case characterIDs = "character_ids"
                case characters
                case artifactPaths = "artifact_paths"
                case selectedArtifactPath = "selected_artifact_path"
            }

            func normalized(
                fallbackOrder: Int,
                characterLookup: [String: UUID],
                sceneLookup: [String: UUID]
            ) -> AgentShortDramaShot {
                let artifactPaths = artifactPaths ?? []
                let selected = selectedArtifactPath.flatMap { artifactPaths.contains($0) ? $0 : nil } ?? preferredSelectedArtifact(in: artifactPaths)
                return AgentShortDramaShot(
                    id: UUID(uuidString: id ?? "") ?? UUID(),
                    title: title,
                    summary: summary,
                    prompt: prompt,
                    status: AgentShortDramaTools.parseShotStatus(status ?? "planned"),
                    order: order ?? fallbackOrder,
                    sceneID: Self.resolve((sceneID ?? scene), lookup: sceneLookup),
                    characterIDs: (characterIDs ?? characters ?? []).compactMap { Self.resolve($0, lookup: characterLookup) },
                    artifactPaths: artifactPaths,
                    selectedArtifactPath: selected,
                    reviewItems: [],
                    updatedAt: Date()
                )
            }

            private static func resolve(_ raw: String?, lookup: [String: UUID]) -> UUID? {
                guard let raw else { return nil }
                if let uuid = UUID(uuidString: raw) { return uuid }
                return lookup[raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                    ?? lookup[ShortDramaPlanDocument.slug(raw)]
            }
        }

        private static func slug(_ value: String) -> String {
            value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
        }
    }
}

enum AgentShortDramaPlanTemplate {
    static let fileName = "short-drama-plan-template.json"

    static func defaultOutputURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("WillDeep/short-drama/templates", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    @discardableResult
    static func write(to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonString().data(using: .utf8)?.write(to: url, options: [.atomic])
        return url
    }

    static func jsonString() -> String {
        """
        {
          "project_id": "optional-stable-project-uuid-or-empty",
          "title": "短剧项目标题",
          "logline": "一句话说明主角、目标、反转和短剧钩子。",
          "characters": [
            {
              "id": "lead",
              "name": "林夏",
              "description": "女主，外表冷静，行动果断，隐藏真实身份。",
              "visual_prompt": "young Chinese woman, sharp bob haircut, ivory trench coat, calm but intense expression, cinematic short drama style",
              "reference_image_paths": []
            },
            {
              "id": "rival",
              "name": "周启",
              "description": "商业对手，精致、傲慢，善于操控局面。",
              "visual_prompt": "Chinese man in tailored black suit, confident smirk, luxury office lighting, cinematic short drama style",
              "reference_image_paths": []
            }
          ],
          "scenes": [
            {
              "id": "office",
              "name": "顶层会议室",
              "description": "玻璃幕墙、高楼夜景、长会议桌，权力感强。",
              "visual_prompt": "luxury high-rise boardroom, glass curtain wall, night city skyline, dramatic rim light",
              "reference_image_paths": []
            }
          ],
          "episodes": [
            {
              "id": "ep1",
              "title": "第1集 反击开场",
              "summary": "女主在签约现场识破陷阱，用隐藏证据反制对手。",
              "order": 1,
              "shots": [
                {
                  "id": "ep1-shot1",
                  "title": "签约前的沉默",
                  "summary": "女主站在会议桌尽头，所有人等她签字。",
                  "prompt": "wide shot, luxury boardroom, heroine standing at the end of a long table, tense silence before signing, cinematic lighting",
                  "status": "planned",
                  "order": 1,
                  "scene": "office",
                  "characters": ["lead", "rival"],
                  "artifact_paths": [],
                  "selected_artifact_path": null
                },
                {
                  "id": "ep1-shot2",
                  "title": "证据亮出",
                  "summary": "女主把录音笔推到桌面中央，对手表情失控。",
                  "prompt": "close-up, recorder sliding across polished table, rival losing composure, heroine calm in background, cinematic short drama",
                  "status": "planned",
                  "order": 2,
                  "scene": "office",
                  "characters": ["lead", "rival"],
                  "artifact_paths": [],
                  "selected_artifact_path": null
                }
              ]
            }
          ]
        }
        """
    }
}

enum AgentShortDramaPromptBuilder {
    static func prompt(project: AgentShortDramaProject, shot: AgentShortDramaShot, override: String? = nil) -> String {
        var sections: [String] = []
        let base = mediaClean(override) ?? mediaClean(shot.prompt) ?? mediaClean(shot.summary) ?? shot.title
        sections.append(base)

        if let logline = mediaClean(project.logline) {
            sections.append("Project logline: \(logline)")
        }
        if let scene = project.scenes.first(where: { $0.id == shot.sceneID }) {
            let sceneText = mediaClean(scene.visualPrompt) ?? mediaClean(scene.description)
            if let sceneText {
                sections.append("Scene consistency: \(scene.name). \(sceneText)")
            }
        }

        let characters = project.characters.filter { shot.characterIDs.contains($0.id) }
        if !characters.isEmpty {
            let characterLines = characters.compactMap { character -> String? in
                let text = mediaClean(character.visualPrompt) ?? mediaClean(character.description)
                guard let text else { return nil }
                return "- \(character.name): \(text)"
            }
            if !characterLines.isEmpty {
                sections.append("Character consistency:\n\(characterLines.joined(separator: "\n"))")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private static func mediaClean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
