//
//  AgentMediaArtifactThumbnail.swift
//  WillDeep
//
//  Interactive media artifact thumbnail actions for media task rows.
//

import AppKit
import SwiftUI

struct AgentMediaArtifactThumbnail: View {
    @EnvironmentObject var appState: AppState
    let artifact: AgentMediaArtifact
    let sourceTask: AgentMediaTask

    @State private var isSubmittingUpscale = false
    @State private var thumbnailImage: NSImage?
    private let tileSize = CGSize(width: 96, height: 78)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailContent
                    .frame(width: tileSize.width, height: tileSize.height)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelectedShotPrimary ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelectedShotPrimary ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture(perform: openArtifact)
                    .contextMenu {
                        AgentArtifactFileContextMenu(fileURL: fileURL)
                    }

                if isImageArtifact || canSendVideoArtifactToChat {
                    artifactActionButtons
                        .padding(4)
                }
            }
            .help("用默认 App 打开产物")
            .task(id: "\(fileURL.standardizedFileURL.path)-\(Int(tileSize.width))-\(Int(tileSize.height))") {
                guard isImageArtifact else {
                    thumbnailImage = nil
                    return
                }
                thumbnailImage = await AgentThumbnailImageCache.image(
                    forFileURL: fileURL,
                    targetPixels: max(tileSize.width, tileSize.height) * 2
                )
            }

            Text(displayTitle)
                .font(.caption2)
                .foregroundStyle(isSelectedShotPrimary ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: tileSize.width, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artifactActionButtons: some View {
        HStack(spacing: 3) {
            if isSelectedShotPrimary {
                Image(systemName: "star.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.yellow)
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
                    .help("当前分镜主图")
            }

            Menu {
                Button("打开产物") {
                    openArtifact()
                }
                if isImageArtifact {
                    Divider()
                    if isEditableImageArtifact {
                        Button("局部重绘") {
                            openImageEditor(operation: .inpaint)
                        }
                        Button("擦除蒙版") {
                            openImageEditor(operation: .erase)
                        }
                    }
                    Button("加入聊天附件") {
                        attachImageToChat()
                    }
                    Button("用 Replicate 放大") {
                        submitReplicateUpscale()
                    }
                    .disabled(isSubmittingUpscale || replicateUpscaleVersion == nil)
                    if canSelectAsShotPrimary {
                        Divider()
                        Button(isSelectedShotPrimary ? "当前分镜主图" : "设为分镜主图") {
                            selectAsShotPrimary()
                        }
                        .disabled(isSelectedShotPrimary)
                    }
                    if canAttachAsAssetReference {
                        Button(isSelectedAssetReference ? "已是资产参考图" : "设为人物/场景参考图") {
                            attachAsAssetReference()
                        }
                        .disabled(isSelectedAssetReference)
                    }
                } else if canSendVideoArtifactToChat {
                    Divider()
                    Button("把视频产物上下文发送到聊天") {
                        appendVideoArtifactContextToChat()
                    }
                }
                Divider()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .agentQuietMenuChrome(AgentComposerChrome.iconPrimary)
            .focusable(false)
            .help(isImageArtifact ? "打开蒙版编辑、放大及更多操作" : "更多媒体操作")
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if isImageArtifact, let image = thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: tileSize.width, height: tileSize.height)
                .clipped()
        } else {
            VStack(spacing: 6) {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(fileURL.pathExtension.uppercased().isEmpty ? "FILE" : fileURL.pathExtension.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: tileSize.width, height: tileSize.height)
        }
    }

    private var fileURL: URL {
        URL(fileURLWithPath: artifact.filePath)
    }

    private var displayTitle: String {
        artifact.title.isEmpty ? fileURL.lastPathComponent : artifact.title
    }

    private var fallbackSystemImage: String {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("video/") {
            return "film"
        }
        let ext = fileURL.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm"].contains(ext) {
            return "film"
        }
        return "doc"
    }

    private var isImageArtifact: Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }
        let ext = fileURL.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(ext)
    }

    private var isVideoArtifact: Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("video/") {
            return true
        }
        let ext = fileURL.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext)
    }

    private var isEditableImageArtifact: Bool {
        isImageArtifact
    }

    private var shotAnchor: (projectID: UUID?, episodeID: UUID?, shotID: UUID)? {
        guard let shotID = UUID(uuidString: sourceTask.shotID ?? "") else {
            return nil
        }
        return (
            projectID: UUID(uuidString: sourceTask.projectID ?? "") ?? UUID(uuidString: sourceTask.projectPath ?? ""),
            episodeID: UUID(uuidString: sourceTask.episodeID ?? ""),
            shotID: shotID
        )
    }

    private var assetAnchor: (projectID: UUID, assetKind: String, assetID: UUID)? {
        guard let projectID = UUID(uuidString: sourceTask.projectID ?? "") ?? UUID(uuidString: sourceTask.projectPath ?? ""),
              let assetKind = clean(sourceTask.assetKind),
              let assetID = UUID(uuidString: sourceTask.assetID ?? "") else {
            return nil
        }
        return (projectID: projectID, assetKind: assetKind, assetID: assetID)
    }

    private var canSelectAsShotPrimary: Bool {
        isImageArtifact && shotAnchor != nil
    }

    private var canAttachAsAssetReference: Bool {
        isImageArtifact && assetAnchor != nil
    }

    private var canSendVideoArtifactToChat: Bool {
        isVideoArtifact && shotAnchor != nil
    }

    private var isSelectedShotPrimary: Bool {
        guard let anchor = shotAnchor,
              let project = appState.agentShortDramaStore.project(id: anchor.projectID) else {
            return false
        }
        for episode in project.episodes {
            if let episodeID = anchor.episodeID, episode.id != episodeID {
                continue
            }
            if let shot = episode.shots.first(where: { $0.id == anchor.shotID }) {
                return shot.selectedArtifactPath == artifact.filePath
            }
        }
        return false
    }

    private var isSelectedAssetReference: Bool {
        guard let anchor = assetAnchor,
              let project = appState.agentShortDramaStore.project(id: anchor.projectID) else {
            return false
        }
        switch anchor.assetKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "character", "characters":
            return project.characters.first(where: { $0.id == anchor.assetID })?.referenceImagePaths.contains(artifact.filePath) ?? false
        case "scene", "scenes", "location", "locations":
            return project.scenes.first(where: { $0.id == anchor.assetID })?.referenceImagePaths.contains(artifact.filePath) ?? false
        default:
            return false
        }
    }

    private var replicateUpscaleVersion: String? {
        let version = ReplicateIntegrationStore.loadWorkflowSettings().upscaleVersion
        return version.isEmpty ? nil : version
    }

    private func openImageEditor(operation: AgentImageEditorOperationPreference) {
        appState.agentImageEditorPreferredOperation = operation
        appState.agentImageEditorContext = AgentImageEditorContext(
            projectID: sourceTask.projectID,
            episodeID: sourceTask.episodeID,
            shotID: sourceTask.shotID,
            assetKind: sourceTask.assetKind,
            assetID: sourceTask.assetID,
            reviewItemID: sourceTask.reviewItemID
        )
        appState.agentImageEditorImageURL = fileURL
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .imageEditor)
    }

    private func openArtifact() {
        AgentArtifactFileActions.openDefault(fileURL)
    }

    private func selectAsShotPrimary() {
        guard let anchor = shotAnchor else {
            NSSound.beep()
            return
        }
        let selected = appState.agentShortDramaStore.selectShotArtifact(
            projectID: anchor.projectID,
            episodeID: anchor.episodeID,
            shotID: anchor.shotID,
            artifactPath: artifact.filePath
        )
        guard selected != nil else {
            NSSound.beep()
            return
        }
        if let projectID = anchor.projectID {
            appState.agentShortDramaStore.setActiveProject(id: projectID)
        }
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
        appendPrimarySelectionFollowUp(anchor: anchor)
    }

    private func attachAsAssetReference() {
        guard let anchor = assetAnchor else {
            NSSound.beep()
            return
        }
        let didAttach = appState.agentShortDramaStore.attachReferenceImages(
            projectID: anchor.projectID,
            assetKind: anchor.assetKind,
            assetID: anchor.assetID,
            imagePaths: [artifact.filePath]
        )
        guard didAttach else {
            NSSound.beep()
            return
        }
        appState.agentShortDramaStore.setActiveProject(id: anchor.projectID)
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
        appendAssetReferenceFollowUp(anchor: anchor)
    }

    private func appendPrimarySelectionFollowUp(anchor: (projectID: UUID?, episodeID: UUID?, shotID: UUID)) {
        guard let episodeID = anchor.episodeID else { return }
        let projectID = anchor.projectID
        let projectValue = projectID?.uuidString ?? (sourceTask.projectID ?? sourceTask.projectPath ?? "")
        guard !projectValue.isEmpty else { return }
        var lines: [String] = [
            "已把这张媒体产物设为短剧分镜主图。后续可以继续生成视频，或在确认修复后关闭检查项。",
            "",
            "<short-drama-primary-artifact-selected>",
            "action: select_shot_primary_artifact",
            "image_path: \(artifact.filePath)",
            "artifact_path: \(artifact.filePath)",
            "project_id: \(projectValue)",
            "episode_id: \(episodeID.uuidString)",
            "shot_id: \(anchor.shotID.uuidString)"
        ]
        if let reviewItemID = clean(sourceTask.reviewItemID) {
            lines.append("review_item_id: \(reviewItemID)")
        }
        lines.append("video_from_image_tool: generate_video_from_image")
        lines.append("video_from_image_arguments: image_path=\(artifact.filePath), project_id=\(projectValue), episode_id=\(episodeID.uuidString), shot_id=\(anchor.shotID.uuidString)\(clean(sourceTask.reviewItemID).map { ", review_item_id=\($0)" } ?? "")")
        if let reviewItemID = clean(sourceTask.reviewItemID) {
            lines.append("resolve_review_tool: short_drama_resolve_review_item")
            lines.append("resolve_review_arguments: project_id=\(projectValue), episode_id=\(episodeID.uuidString), shot_id=\(anchor.shotID.uuidString), item_id=\(reviewItemID)")
        }
        lines.append("</short-drama-primary-artifact-selected>")

        let prompt = lines.joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains("<short-drama-primary-artifact-selected>") {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func appendAssetReferenceFollowUp(anchor: (projectID: UUID, assetKind: String, assetID: UUID)) {
        let projectID = anchor.projectID.uuidString
        let assetID = anchor.assetID.uuidString
        var lines: [String] = [
            "已把这张媒体产物设为短剧人物/场景参考图。后续可以继续生成关联分镜、编辑参考图，或查看这个资产的媒体任务。",
            "",
            "<short-drama-asset-reference-attached>",
            "action: attach_asset_reference_from_media_task",
            "task_id: \(sourceTask.displayHandle)",
            "task_uuid: \(sourceTask.id.uuidString)",
            "image_path: \(artifact.filePath)",
            "project_id: \(projectID)",
            "asset_kind: \(anchor.assetKind)",
            "asset_id: \(assetID)",
            "attach_reference_tool: short_drama_attach_asset_reference_image",
            "attach_reference_arguments: project_id=\(projectID), asset_kind=\(anchor.assetKind), asset_id=\(assetID), image_path=\(artifact.filePath)",
            "open_asset_tasks_tool: short_drama_open_media_tasks",
            "open_asset_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(anchor.assetKind), asset_id=\(assetID)",
            "generate_asset_reference_tool: short_drama_generate_asset_media",
            "generate_asset_reference_arguments: project_id=\(projectID), asset_kind=\(anchor.assetKind), asset_id=\(assetID)",
            "edit_reference_tool: open_image_editor",
            "edit_reference_arguments: image_path=\(artifact.filePath), operation=inpaint, project_id=\(projectID), asset_kind=\(anchor.assetKind), asset_id=\(assetID)",
            "erase_reference_tool: open_image_editor",
            "erase_reference_arguments: image_path=\(artifact.filePath), operation=erase, project_id=\(projectID), asset_kind=\(anchor.assetKind), asset_id=\(assetID)",
            "upscale_reference_tool: upscale_image",
            "upscale_reference_arguments: image_path=\(artifact.filePath), project_id=\(projectID), asset_kind=\(anchor.assetKind), asset_id=\(assetID)"
        ]
        if let reviewItemID = clean(sourceTask.reviewItemID) {
            lines.append("review_item_id: \(reviewItemID)")
        }
        lines.append("</short-drama-asset-reference-attached>")

        let prompt = lines.joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains("<short-drama-asset-reference-attached>") || !appState.agentInput.contains(artifact.filePath) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func appendVideoArtifactContextToChat() {
        guard let anchor = shotAnchor,
              let episodeID = anchor.episodeID else {
            NSSound.beep()
            return
        }
        let projectID = anchor.projectID
        let projectValue = projectID?.uuidString ?? (sourceTask.projectID ?? sourceTask.projectPath ?? "")
        guard !projectValue.isEmpty else {
            NSSound.beep()
            return
        }
        var lines: [String] = [
            "请基于这个短剧分镜视频产物继续审片和制作。",
            "",
            "<media-task-video-artifact-selected>",
            "action: continue_from_selected_video_artifact",
            "task_id: \(sourceTask.displayHandle)",
            "task_uuid: \(sourceTask.id.uuidString)",
            "video_path: \(artifact.filePath)",
            "project_id: \(projectValue)",
            "episode_id: \(episodeID.uuidString)",
            "shot_id: \(anchor.shotID.uuidString)",
            "open_shot_tasks_tool: short_drama_open_media_tasks",
            "open_shot_tasks_arguments: project_id=\(projectValue), episode_id=\(episodeID.uuidString), shot_id=\(anchor.shotID.uuidString), scope=shot",
            "refresh_shot_tasks_tool: short_drama_refresh_media_tasks",
            "refresh_shot_tasks_arguments: project_id=\(projectValue), episode_id=\(episodeID.uuidString), shot_id=\(anchor.shotID.uuidString), scope=shot",
            "storyboard_widget_tool: short_drama_show_storyboard_widget",
            "storyboard_widget_arguments: project_id=\(projectValue), episode_id=\(episodeID.uuidString)"
        ]
        if let reviewItemID = clean(sourceTask.reviewItemID) {
            lines.append("review_item_id: \(reviewItemID)")
            lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_review_tasks_arguments: project_id=\(projectValue), episode_id=\(episodeID.uuidString), shot_id=\(anchor.shotID.uuidString), scope=review_item, review_item_id=\(reviewItemID)")
            lines.append("resolve_review_tool: short_drama_resolve_review_item")
            lines.append("resolve_review_arguments: project_id=\(projectValue), episode_id=\(episodeID.uuidString), shot_id=\(anchor.shotID.uuidString), item_id=\(reviewItemID)")
        }
        lines.append("</media-task-video-artifact-selected>")

        let prompt = lines.joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains("<media-task-video-artifact-selected>") || !appState.agentInput.contains(artifact.filePath) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func submitReplicateUpscale() {
        guard !isSubmittingUpscale, let version = replicateUpscaleVersion else {
            NSSound.beep()
            return
        }
        isSubmittingUpscale = true
        Task {
            defer { isSubmittingUpscale = false }
            do {
                let inputJSON = try jsonString(from: ["image": dataURL(for: fileURL)])
                let prediction = try await ReplicateClient.createPrediction(version: version, inputJSON: inputJSON)
                let status = ReplicateClient.status(from: prediction.status)
                let title = "\(displayTitle) · Replicate 放大"
                let artifacts = status == .succeeded
                    ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
                    : []
                let task = appState.agentMediaTaskRegistry.create(
                    provider: .replicate,
                    kind: .imageUpscale,
                    title: title,
                    prompt: "Upscale image artifact: \(displayTitle)",
                    model: version,
                    remoteTaskID: prediction.id,
                    statusURL: prediction.urls?.get,
                    cancelURL: prediction.urls?.cancel,
                    sourceImagePath: fileURL.path,
                    reviewItemID: sourceTask.reviewItemID,
                    runtimeID: appState.activeRuntime?.id,
                    projectID: sourceTask.projectID,
                    episodeID: sourceTask.episodeID,
                    shotID: sourceTask.shotID,
                    status: status,
                    statusMessage: ReplicateClient.statusMessage(for: prediction)
                )
                if !artifacts.isEmpty {
                    appState.agentMediaTaskRegistry.update(id: task.id, progress: 1, artifacts: artifacts)
                }
                appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func attachImageToChat() {
        do {
            let data = try Data(contentsOf: fileURL)
            appState.addAgentImage(data: data, mimeType: imageMimeType)
            let prompt = "请基于这张媒体产物继续处理：\(displayTitle)"
            let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedInput.isEmpty {
                appState.agentInput = prompt
            } else if !appState.agentInput.contains(displayTitle) {
                appState.agentInput += "\n\n\(prompt)"
            }
        } catch {
            NSSound.beep()
        }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var imageMimeType: String {
        if let mimeType = artifact.mimeType, mimeType.lowercased().hasPrefix("image/") {
            return mimeType
        }
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }

    private func dataURL(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return "data:\(imageMimeType);base64,\(data.base64EncodedString())"
    }

    private func jsonString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("Could not encode Replicate input JSON.")
        }
        return string
    }
}
