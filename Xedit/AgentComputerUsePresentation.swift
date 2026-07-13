//
//  AgentComputerUsePresentation.swift
//  WillDeep
//
//  Session-scoped presentation for the latest Computer Use screenshot.
//

import AppKit
import SwiftUI

nonisolated struct AgentComputerUseActivity: Equatable, Identifiable, Sendable {
    let image: AgentImageAttachment
    let toolName: String
    let capturedAt: Date

    var id: UUID { image.id }

    static func latest(in messages: [AgentMessage]) -> AgentComputerUseActivity? {
        var toolNamesByExternalID: [String: String] = [:]
        for message in messages where message.role == .assistant {
            for call in message.toolCalls where isStateProducingTool(call.toolName) {
                toolNamesByExternalID[call.externalID] = call.toolName
            }
        }

        for message in messages.reversed() where message.role == .tool {
            guard let toolCallID = message.toolCallID,
                  let toolName = toolNamesByExternalID[toolCallID],
                  let image = message.images.first else {
                continue
            }
            return AgentComputerUseActivity(
                image: image,
                toolName: toolName,
                capturedAt: image.createdAt ?? message.createdAt
            )
        }
        return nil
    }

    static func isStateProducingTool(_ toolName: String) -> Bool {
        toolName.hasPrefix("computer_use_")
    }
}

extension AgentRuntime {
    func recordComputerUseActivity(toolName: String, images: [AgentImageAttachment]) {
        guard AgentComputerUseActivity.isStateProducingTool(toolName),
              let image = images.first else {
            return
        }
        latestComputerUseActivity = AgentComputerUseActivity(
            image: image,
            toolName: toolName,
            capturedAt: image.createdAt ?? Date()
        )
    }
}

struct AgentComputerUsePresentationLayer: View {
    let activity: AgentComputerUseActivity?
    let isActive: Bool
    let sessionID: AgentSession.ID?
    let turnStartedAt: Date?
    let thumbnailTrailingInset: CGFloat
    @State private var isExpanded = false
    @FocusState private var isOverlayFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if isExpanded, let activity {
                    expandedPreview(activity, in: proxy.size)
                        .transition(.opacity)
                        .zIndex(2)
                } else if isActive, let activity {
                    thumbnail(activity, containerWidth: proxy.size.width)
                        .padding(.top, 62)
                        .padding(.trailing, 18 + thumbnailTrailingInset)
                        .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .animation(.easeOut(duration: 0.16), value: isExpanded)
        .animation(.easeOut(duration: 0.16), value: isActive)
        .onCompatibleChange(of: sessionID) { _, _ in
            isExpanded = false
        }
        .onCompatibleChange(of: turnStartedAt) { _, newValue in
            if newValue != nil {
                isExpanded = false
            }
        }
    }

    private func thumbnail(_ activity: AgentComputerUseActivity, containerWidth: CGFloat) -> some View {
        let size = containerWidth < 480
            ? CGSize(width: 132, height: 82)
            : CGSize(width: 176, height: 108)
        return Button {
            isExpanded = true
        } label: {
            AgentComputerUsePreviewImage(image: activity.image, targetPixels: 420, contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("computer-use-preview-thumbnail")
        .accessibilityLabel(L10n.ComputerUsePreview.open)
        .help(L10n.ComputerUsePreview.open)
    }

    private func expandedPreview(_ activity: AgentComputerUseActivity, in size: CGSize) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded = false }

            AgentComputerUsePreviewImage(image: activity.image, targetPixels: 2_400, contentMode: .fit)
                .frame(
                    maxWidth: max(200, size.width - 96),
                    maxHeight: max(160, size.height - 96)
                )
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            Button {
                isExpanded = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(18)
            .accessibilityIdentifier("computer-use-preview-close")
            .accessibilityLabel(L10n.ComputerUsePreview.close)
            .help(L10n.ComputerUsePreview.close)
        }
        .accessibilityIdentifier("computer-use-preview-overlay")
        .focusable()
        .focused($isOverlayFocused)
        .onAppear { isOverlayFocused = true }
        .onExitCommand { isExpanded = false }
    }
}

private struct AgentComputerUsePreviewImage: View {
    let image: AgentImageAttachment
    let targetPixels: CGFloat
    let contentMode: ContentMode
    @State private var decodedImage: NSImage?

    var body: some View {
        Group {
            if let decodedImage {
                Image(nsImage: decodedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: "\(image.thumbnailCacheKey)-\(Int(targetPixels))") {
            if let fileURL = image.fileURL {
                decodedImage = await AgentThumbnailImageCache.image(
                    forFileURL: fileURL,
                    targetPixels: targetPixels
                )
            } else {
                decodedImage = await AgentThumbnailImageCache.image(
                    forBase64: image.dataBase64,
                    cacheKey: image.thumbnailCacheKey,
                    targetPixels: targetPixels
                )
            }
        }
    }
}
