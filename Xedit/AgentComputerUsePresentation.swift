//
//  AgentComputerUsePresentation.swift
//  WillDeep
//
//  Global control-session status and latest Computer Use screenshot.
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

nonisolated struct AgentComputerUsePresentationActions: Equatable, Sendable {
    let showsPause: Bool
    let showsTakeover: Bool
    let showsResume: Bool
    let showsStop: Bool
}

nonisolated enum AgentComputerUsePresentationPolicy {
    static func actions(
        for phase: AgentComputerUseControlPhase
    ) -> AgentComputerUsePresentationActions {
        switch phase {
        case .observing, .controlling:
            return AgentComputerUsePresentationActions(
                showsPause: true,
                showsTakeover: true,
                showsResume: false,
                showsStop: true
            )
        case .paused, .userTakeover:
            return AgentComputerUsePresentationActions(
                showsPause: false,
                showsTakeover: false,
                showsResume: true,
                showsStop: true
            )
        case .failed:
            return AgentComputerUsePresentationActions(
                showsPause: false,
                showsTakeover: false,
                showsResume: false,
                showsStop: true
            )
        case .idle, .stopping:
            return AgentComputerUsePresentationActions(
                showsPause: false,
                showsTakeover: false,
                showsResume: false,
                showsStop: false
            )
        }
    }

    /// The full-window background is interactive only while the user has
    /// explicitly expanded a screenshot. In compact mode, transparent space
    /// around the status card must pass pointer events to the conversation.
    static func interceptsTransparentRegion(isExpanded: Bool) -> Bool {
        isExpanded
    }
}

struct AgentComputerUsePresentationLayer: View {
    @ObservedObject var coordinator: AgentComputerUseCoordinator
    let thumbnailTrailingInset: CGFloat
    @State private var isExpanded = false
    @FocusState private var isOverlayFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                // Keep the layout full-window without installing an invisible
                // hit-test shield over the transcript.
                Color.clear
                    .allowsHitTesting(false)

                if isExpanded, let activity = coordinator.state.lease?.latestActivity {
                    expandedPreview(activity, in: proxy.size)
                        .transition(.opacity)
                        .zIndex(2)
                } else if coordinator.state.isPresented {
                    statusCard(containerWidth: proxy.size.width)
                        .padding(.top, 62)
                        .padding(.trailing, 18 + thumbnailTrailingInset)
                        .transition(
                            .scale(scale: 0.96, anchor: .topTrailing)
                                .combined(with: .opacity)
                        )
                        .zIndex(1)
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )
        }
        .animation(.easeOut(duration: 0.16), value: isExpanded)
        .animation(.easeOut(duration: 0.16), value: coordinator.state.phase)
        .onCompatibleChange(of: coordinator.state.phase) { _, newPhase in
            if newPhase == .idle {
                isExpanded = false
            }
        }
        .onCompatibleChange(of: coordinator.state.lease?.id) { oldID, newID in
            if oldID != newID {
                isExpanded = false
            }
        }
    }

    private func statusCard(containerWidth: CGFloat) -> some View {
        let state = coordinator.state
        let lease = state.lease
        let width = min(340, max(272, containerWidth - 52 - thumbnailTrailingInset))
        let actions = AgentComputerUsePresentationPolicy.actions(for: state.phase)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: phaseSymbol(for: state.phase))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(phaseTint(for: state.phase))
                    .frame(width: 22, height: 22)
                    .background(
                        phaseTint(for: state.phase).opacity(0.12),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseTitle(for: state.phase))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(phaseTint(for: state.phase))

                    Text(lease?.target.applicationName ?? L10n.ComputerUsePreview.unknownTarget)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if state.phase == .stopping {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let lease {
                Text(L10n.ComputerUsePreview.owningTask(lease.owner.sessionTitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let windowTitle = lease.target.windowTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !windowTitle.isEmpty,
                   windowTitle != lease.target.applicationName {
                    Text(windowTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let failureMessage = state.failureMessage {
                Text(failureMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let activity = lease?.latestActivity {
                thumbnail(activity)
            }

            if state.phase == .stopping {
                Text(L10n.ComputerUsePreview.stoppingDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if actions.showsPause
                || actions.showsTakeover
                || actions.showsResume
                || actions.showsStop {
                actionRow(actions: actions, leaseID: lease?.id)
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("computer-use-control-card")
        .accessibilityLabel(L10n.ComputerUsePreview.statusAccessibility)
    }

    private func thumbnail(_ activity: AgentComputerUseActivity) -> some View {
        Button {
            isExpanded = true
        } label: {
            AgentComputerUsePreviewImage(
                image: activity.image,
                targetPixels: 640,
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("computer-use-preview-thumbnail")
        .accessibilityLabel(L10n.ComputerUsePreview.open)
        .help(L10n.ComputerUsePreview.open)
    }

    @ViewBuilder
    private func actionRow(
        actions: AgentComputerUsePresentationActions,
        leaseID: AgentComputerUseLease.ID?
    ) -> some View {
        HStack(spacing: 8) {
            if actions.showsPause {
                controlButton(
                    title: L10n.ComputerUsePreview.pause,
                    symbol: "pause.fill"
                ) {
                    coordinator.pause(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-pause")
            }

            if actions.showsTakeover {
                controlButton(
                    title: L10n.ComputerUsePreview.takeOver,
                    symbol: "hand.raised.fill"
                ) {
                    coordinator.takeover(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-takeover")
            }

            if actions.showsResume {
                controlButton(
                    title: L10n.ComputerUsePreview.resume,
                    symbol: "play.fill"
                ) {
                    coordinator.resume(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-resume")
            }

            Spacer(minLength: 0)

            if actions.showsStop {
                controlButton(
                    title: L10n.ComputerUsePreview.stop,
                    symbol: "stop.fill",
                    tint: .red
                ) {
                    coordinator.stop(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-stop")
            }
        }
    }

    private func controlButton(
        title: String,
        symbol: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
    }

    private func phaseTitle(
        for phase: AgentComputerUseControlPhase
    ) -> String {
        switch phase {
        case .idle: return L10n.ComputerUsePreview.idle
        case .observing: return L10n.ComputerUsePreview.observing
        case .controlling: return L10n.ComputerUsePreview.controlling
        case .paused: return L10n.ComputerUsePreview.paused
        case .userTakeover: return L10n.ComputerUsePreview.userTakeover
        case .stopping: return L10n.ComputerUsePreview.stopping
        case .failed: return L10n.ComputerUsePreview.failed
        }
    }

    private func phaseSymbol(
        for phase: AgentComputerUseControlPhase
    ) -> String {
        switch phase {
        case .idle: return "circle"
        case .observing: return "eye.fill"
        case .controlling: return "cursorarrow.motionlines"
        case .paused: return "pause.fill"
        case .userTakeover: return "hand.raised.fill"
        case .stopping: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func phaseTint(
        for phase: AgentComputerUseControlPhase
    ) -> Color {
        switch phase {
        case .idle: return .secondary
        case .observing: return .blue
        case .controlling: return .accentColor
        case .paused: return .orange
        case .userTakeover: return .green
        case .stopping: return .secondary
        case .failed: return .red
        }
    }

    private func expandedPreview(
        _ activity: AgentComputerUseActivity,
        in size: CGSize
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .allowsHitTesting(
                    AgentComputerUsePresentationPolicy.interceptsTransparentRegion(
                        isExpanded: isExpanded
                    )
                )
                .onTapGesture { isExpanded = false }

            AgentComputerUsePreviewImage(
                image: activity.image,
                targetPixels: 2_400,
                contentMode: .fit
            )
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
