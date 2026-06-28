//
//  AgentShortDramaImageTools.swift
//  WillDeep
//
//  Image-editing and enhancement tools for short-drama storyboard shots.
//

import Foundation

enum AgentShortDramaImageTools {
    static func openImageEditor(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let resolved = try await resolveShot(arguments: arguments, context: context)
        let imagePath = try editableImagePath(arguments: arguments, shot: resolved.shot)
        let maskPath = optionalString(arguments["mask_path"])
        let operation = parseImageEditorOperation(optionalString(arguments["operation"]) ?? "inpaint")
        guard let runtimeID = context.runtimeID,
              let appState = await MainActor.run(body: { EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) }) else {
            return AgentToolResult(
                summary: "short drama image editor unavailable",
                payload: "short_drama_open_image_editor is only available in conversational agent runtimes."
            )
        }
        await MainActor.run {
            appState.agentImageEditorPreferredOperation = operation
            appState.agentImageEditorContext = AgentImageEditorContext(
                projectID: resolved.projectID.uuidString,
                episodeID: resolved.episodeID.uuidString,
                shotID: resolved.shotID.uuidString,
                reviewItemID: optionalString(arguments["review_item_id"])
            )
            appState.agentImageEditorMaskURL = maskPath.map { URL(fileURLWithPath: $0) }
            appState.agentImageEditorImageURL = URL(fileURLWithPath: imagePath)
            appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .imageEditor)
        }
        return AgentToolResult(
            summary: "opened short-drama image editor: \(resolved.shot.title)",
            payload: """
            Short-drama image editor opened.

            Project: \(resolved.project.title)
            Episode: \(resolved.episode.title)
            Shot: \(resolved.shot.title)
            Operation: \(operation == .erase ? "erase" : "inpaint")
            Image: \(imagePath)
            Seed mask: \(maskPath ?? "(none)")
            The image editor side panel is anchored to this project / episode / shot, so submitted Replicate or some.im edit tasks will return to the same storyboard shot.
            """
        )
    }

    static func upscaleShotArtifact(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let registry = context.mediaTaskRegistry else {
            throw AgentToolError.invalidArgument("Media task registry not available.")
        }
        let resolved = try await resolveShot(arguments: arguments, context: context)
        let imagePath = try editableImagePath(arguments: arguments, shot: resolved.shot)
        let version = optionalString(arguments["version"]) ?? ReplicateIntegrationStore.loadWorkflowSettings().upscaleVersion
        guard !version.isEmpty else {
            throw AgentToolError.invalidArgument("Replicate upscale version is not configured. Set it in Settings -> Integrations -> Replicate or pass version.")
        }
        let imageURL = URL(fileURLWithPath: imagePath)
        let prompt = optionalString(arguments["prompt"])
            ?? "Upscale short-drama keyframe: \(resolved.shot.title)"
        let inputJSON = try jsonString(from: ["image": dataURL(for: imageURL)])
        let prediction = try await ReplicateClient.createPrediction(version: version, inputJSON: inputJSON)
        let status = ReplicateClient.status(from: prediction.status)
        let title = "\(resolved.shot.title) · Replicate 放大"
        let artifacts = status == .succeeded
            ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
            : []
        let reviewItemID = optionalString(arguments["review_item_id"])
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
                sourceImagePath: imagePath,
                reviewItemID: reviewItemID,
                runtimeID: context.runtimeID,
                projectID: resolved.projectID.uuidString,
                episodeID: resolved.episodeID.uuidString,
                shotID: resolved.shotID.uuidString,
                status: status,
                statusMessage: ReplicateClient.statusMessage(for: prediction)
            )
        }
        if !artifacts.isEmpty {
            await MainActor.run {
                registry.update(id: task.id, progress: 1, artifacts: artifacts)
            }
        }
        if let runtimeID = context.runtimeID {
            await MainActor.run {
                EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            }
        }
        return AgentToolResult(
            summary: "submitted short-drama image upscale: \(task.displayHandle)",
            payload: """
            Short-drama image upscale submitted.

            Project: \(resolved.project.title)
            Episode: \(resolved.episode.title)
            Shot: \(resolved.shot.title)
            Source image: \(imagePath)
            Review item id: \(reviewItemID ?? "(none)")
            Task: \(task.displayHandle)
            Provider: Replicate
            Status: \(status.displayName)
            Remote task id: \(prediction.id)
            Status URL: \(prediction.urls?.get ?? "(none)")
            """
        )
    }

    private static func resolveShot(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> ResolvedShot {
        let store = try requireStore(context)
        let projectID = try await resolveProjectID(arguments: arguments, store: store)
        let episodeID = try requiredUUID(arguments, "episode_id")
        let shotID = try requiredUUID(arguments, "shot_id")
        let project = try await loadProject(store: store, projectID: projectID)
        guard let episode = project.episodes.first(where: { $0.id == episodeID }),
              let shot = episode.shots.first(where: { $0.id == shotID }) else {
            throw AgentToolError.notFound(shotID.uuidString)
        }
        return ResolvedShot(projectID: projectID, episodeID: episodeID, shotID: shotID, project: project, episode: episode, shot: shot)
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

    private static func requiredUUID(_ arguments: [String: AgentJSONValue], _ key: String) throws -> UUID {
        guard let uuid = optionalUUID(arguments[key]) else {
            throw AgentToolError.missingArgument(key)
        }
        return uuid
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

    private static func editableImagePath(arguments: [String: AgentJSONValue], shot: AgentShortDramaShot) throws -> String {
        let candidates = [
            optionalString(arguments["artifact_path"]),
            optionalString(arguments["image_path"]),
            shot.selectedArtifactPath
        ]
            .compactMap { $0 } + shot.artifactPaths
        guard let imagePath = candidates.first(where: isImagePath) else {
            throw AgentToolError.invalidArgument("No editable image artifact found for shot \(shot.id.uuidString).")
        }
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw AgentToolError.invalidArgument("Image artifact does not exist: \(imagePath)")
        }
        return imagePath
    }

    nonisolated private static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func parseImageEditorOperation(_ raw: String) -> AgentImageEditorOperationPreference {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
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

    private struct ResolvedShot {
        let projectID: UUID
        let episodeID: UUID
        let shotID: UUID
        let project: AgentShortDramaProject
        let episode: AgentShortDramaEpisode
        let shot: AgentShortDramaShot
    }
}
