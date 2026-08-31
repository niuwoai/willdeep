//
//  AgentShortDramaArtifactTile.swift
//  WillDeep
//
//  Thumbnail actions for generated short-drama shot artifacts.
//

import AppKit
import SwiftUI

struct AgentShortDramaArtifactTile: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }
    let path: String
    let shotTitle: String
    let isSelected: Bool
    let editorContext: AgentImageEditorContext?
    let selectAction: () -> Void

    private let tileSize = CGSize(width: 72, height: 52)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(width: tileSize.width, height: tileSize.height)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture(perform: openArtifact)
                    .contextMenu {
                        AgentArtifactFileContextMenu(fileURL: fileURL)
                    }

                if isImageArtifact {
                    HStack(spacing: 3) {
                        Button {
                            selectAction()
                        } label: {
                            Image(systemName: isSelected ? "star.fill" : "star")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.yellow : Color.primary)
                                .frame(width: 18, height: 18)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help(isSelected ? "当前分镜主图" : "设为分镜主图")

                        Button {
                            attachImageToChat()
                        } label: {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 18, height: 18)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help("加入聊天附件")

                        Button {
                            panelScope.imageOperation = .inpaint
                            panelScope.imageContext = editorContext
                            panelScope.imageURL = fileURL
                            panelScope.request = AgentSidePanelOpenRequest(kind: .imageEditor)
                        } label: {
                            Image(systemName: "paintbrush.pointed")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 18, height: 18)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .help("打开蒙版编辑")
                    }
                    .padding(4)
                }
            }
            .help("用默认 App 打开产物")

            Text(displayTitle)
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: tileSize.width, alignment: .leading)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if isImageArtifact, let image = NSImage(contentsOf: fileURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: tileSize.width, height: tileSize.height)
                .clipped()
        } else {
            VStack(spacing: 4) {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(fileURL.pathExtension.uppercased().isEmpty ? "FILE" : fileURL.pathExtension.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: tileSize.width, height: tileSize.height)
        }
    }

    private var fileURL: URL {
        URL(fileURLWithPath: path)
    }

    private var displayTitle: String {
        fileURL.lastPathComponent
    }

    private var fallbackSystemImage: String {
        if isVideoArtifact {
            return "film"
        }
        return "doc"
    }

    private var isVideoArtifact: Bool {
        ["mp4", "mov", "m4v", "webm"].contains(fileURL.pathExtension.lowercased())
    }

    private var isImageArtifact: Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(fileURL.pathExtension.lowercased())
    }

    private func openArtifact() {
        AgentArtifactFileActions.openDefault(fileURL)
    }

    private func attachImageToChat() {
        do {
            let data = try Data(contentsOf: fileURL)
            appState.addAgentImage(data: data, mimeType: imageMimeType)
            let prompt = "请基于短剧分镜「\(shotTitle)」的这张产物继续处理：\(displayTitle)"
            let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedInput.isEmpty {
                panelScope.input = prompt
            } else if !panelScope.input.contains(displayTitle) {
                panelScope.input += "\n\n\(prompt)"
            }
            appState.agentComposerFocusRevision += 1
        } catch {
            NSSound.beep()
        }
    }

    private var imageMimeType: String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }
}
