//
//  AgentShortDramaAssetViews.swift
//  WillDeep
//
//  Compact asset cards for the short-drama side panel. Kept separate from
//  AgentShortDrama.swift so project, episode, and shot logic stay readable.
//

import AppKit
import SwiftUI

struct ShortDramaAssetSummary: Identifiable {
    var id: UUID
    var projectID: UUID
    var assetKind: String
    var name: String
    var detail: String?
    var referenceImagePaths: [String]
}

extension AgentShortDramaPanel {
    func assetSection(
        title: String,
        systemImage: String,
        items: [ShortDramaAssetSummary],
        generateReference: @escaping (ShortDramaAssetSummary) -> Void,
        isGeneratingReference: @escaping (ShortDramaAssetSummary) -> Bool,
        mediaTasks: @escaping (ShortDramaAssetSummary) -> [AgentMediaTask],
        mediaTaskScope: @escaping (ShortDramaAssetSummary) -> AgentMediaTaskScope,
        appendContext: @escaping (ShortDramaAssetSummary) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(items.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        if !item.referenceImagePaths.isEmpty {
                            Text("\(item.referenceImagePaths.count) 参考图")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        mediaTaskBadge(tasks: mediaTasks(item), scope: mediaTaskScope(item), compact: true)
                        Spacer(minLength: 4)
                        Button {
                            appendContext(item)
                        } label: {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help("发送资产结构到聊天")

                        Button {
                            generateReference(item)
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .disabled(isGeneratingReference(item))
                        .help("生成参考图")
                    }
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !item.referenceImagePaths.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(item.referenceImagePaths.prefix(5)), id: \.self) { path in
                                    AgentShortDramaReferenceTile(path: path, asset: item)
                                }
                            }
                        }
                        .frame(height: 50)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.028)))
            }
        }
    }
}

private struct AgentShortDramaReferenceTile: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }
    let path: String
    let asset: ShortDramaAssetSummary

    private let tileSize = CGSize(width: 58, height: 40)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
                .frame(width: tileSize.width, height: tileSize.height)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onTapGesture(perform: openReference)
            if isImage {
                HStack(spacing: 3) {
                    Button {
                        openImageEditor(operation: .inpaint)
                    } label: {
                        Image(systemName: "paintbrush.pointed")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(4)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("编辑参考图蒙版")

                    Button {
                        openImageEditor(operation: .erase)
                    } label: {
                        Image(systemName: "eraser")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(4)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("擦除参考图区域")

                    Button {
                        submitReplicateUpscale()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(4)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(isSubmittingUpscale || replicateUpscaleVersion == nil)
                    .help(replicateUpscaleVersion == nil ? "请先在 Settings → Integrations → Replicate 配置图片放大 version" : "放大参考图")
                }
            }
        }
        .help("打开参考图：\(asset.name)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if isImage, let image = NSImage(contentsOf: fileURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: tileSize.width, height: tileSize.height)
                .clipped()
        } else {
            VStack(spacing: 2) {
                Image(systemName: isVideo ? "film" : "doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(fileURL.pathExtension.uppercased().isEmpty ? "FILE" : fileURL.pathExtension.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fileURL: URL {
        URL(fileURLWithPath: path)
    }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(fileURL.pathExtension.lowercased())
    }

    private var isVideo: Bool {
        ["mp4", "mov", "m4v", "webm"].contains(fileURL.pathExtension.lowercased())
    }

    @State private var isSubmittingUpscale = false

    private var replicateUpscaleVersion: String? {
        let version = ReplicateIntegrationStore.loadWorkflowSettings().upscaleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private func openReference() {
        if isImage {
            appState.openImagePreview(fileURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private func openImageEditor(operation: AgentImageEditorOperationPreference) {
        guard isImage else { return }
        panelScope.imageOperation = operation
        panelScope.imageContext = AgentImageEditorContext(
            projectID: asset.projectID.uuidString,
            assetKind: asset.assetKind,
            assetID: asset.id.uuidString
        )
        panelScope.imageURL = fileURL
        panelScope.request = AgentSidePanelOpenRequest(kind: .imageEditor)
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
                let title = "\(asset.name) · 参考图放大"
                let artifacts = status == .succeeded
                    ? try await ReplicateClient.downloadArtifacts(from: prediction, title: title).map(\.mediaArtifact)
                    : []
                let task = appState.agentMediaTaskRegistry.create(
                    provider: .replicate,
                    kind: .imageUpscale,
                    title: title,
                    prompt: "Upscale short-drama \(asset.assetKind) reference image: \(asset.name)",
                    model: version,
                    remoteTaskID: prediction.id,
                    statusURL: prediction.urls?.get,
                    cancelURL: prediction.urls?.cancel,
                    sourceImagePath: fileURL.path,
                    runtimeID: panelScope.runtime?.id,
                    projectID: asset.projectID.uuidString,
                    assetKind: asset.assetKind,
                    assetID: asset.id.uuidString,
                    status: status,
                    statusMessage: ReplicateClient.statusMessage(for: prediction)
                )
                if !artifacts.isEmpty {
                    appState.agentMediaTaskRegistry.update(id: task.id, progress: 1, artifacts: artifacts)
                }
                panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func dataURL(for url: URL) throws -> String {
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

    private func jsonString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("Could not encode Replicate input JSON.")
        }
        return string
    }
}
