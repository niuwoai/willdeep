//
//  AgentMediaTaskRow.swift
//  WillDeep
//
//  Single media task row UI and row-level chat handoff actions.
//

import AppKit
import SwiftUI

struct AgentMediaTaskRow: View {
    @EnvironmentObject var appState: AppState
    let task: AgentMediaTask
    @State private var isRefreshing = false
    @State private var isCanceling = false
    @State private var reviewResolveMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: task.kind.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text("\(task.displayHandle) · \(task.provider.displayName) · \(task.kind.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(taskTimingText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if canRefresh {
                    Button {
                        refreshTask()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(isRefreshing)
                    .help("立即刷新任务状态")
                }
                if canCancel {
                    Button {
                        cancelTask()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(isCanceling)
                    .help("取消远端任务")
                }
                if canRetryViaChat {
                    Button {
                        appendRetryTaskToChat()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("把重试请求发送到聊天")
                }
                if canContinueShotToVideo {
                    Button {
                        appendShotVideoContinuationToChat()
                    } label: {
                        Image(systemName: "film.stack")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("基于分镜图片继续生成视频")
                }
                if canResolveReviewItem {
                    Button {
                        resolveLinkedReviewItem()
                    } label: {
                        Image(systemName: "checkmark.seal")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("把关联短剧检查项标记为已解决")
                }
                Button {
                    appendTaskContextToChat()
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("发送任务上下文到聊天")
                Text(task.status.displayName)
                    .font(.caption2)
                    .foregroundStyle(statusTint)
            }

            if let prompt = task.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if task.isActive {
                ProgressView(value: task.progress ?? fallbackProgress)
                    .controlSize(.small)
            }

            if let message = task.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(task.needsAttention ? .red : .secondary)
                    .lineLimit(3)
            }

            if task.isStaleActive() {
                HStack(spacing: 5) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                    Text("超过 \(task.staleActiveMinutes()) 分钟未更新，建议刷新或核对远端状态")
                        .font(.caption2)
                        .lineLimit(2)
                }
                .foregroundStyle(.orange)
            }

            if let reviewResolveMessage {
                Text(reviewResolveMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let anchor = appState.agentShortDramaStore.anchor(for: task) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text(anchor.displayLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        appendShortDramaAnchorContextToChat(anchor: anchor)
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("发送短剧锚点上下文到聊天")
                    Button {
                        appState.agentShortDramaStore.setActiveProject(id: anchor.projectID)
                        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("打开对应短剧项目")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.07)))
            }

            if !task.artifacts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("产物")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if imageArtifacts.count > 1 {
                            Button {
                                showArtifactChoiceWidget()
                            } label: {
                                Label("候选图", systemImage: "rectangle.grid.2x2")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .focusable(false)
                            .help("打开候选图选择器")
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(task.artifacts) { artifact in
                                AgentMediaArtifactThumbnail(artifact: artifact, sourceTask: task)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    if task.artifacts.count > 1 {
                        Text("点击缩略图预览；图片可进入蒙版编辑")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusTint.opacity(task.needsAttention ? 0.45 : 0.16), lineWidth: 1)
        )
    }

    private var fallbackProgress: Double {
        switch task.status {
        case .queued: return 0.08
        case .submitted: return 0.18
        case .starting: return 0.28
        case .processing: return 0.56
        case .succeeded: return 1
        case .failed, .canceled: return 0
        }
    }

    private var imageArtifacts: [AgentMediaArtifact] {
        task.artifacts.filter(isImageArtifact)
    }

    private var statusTint: Color {
        switch task.status {
        case .queued, .submitted, .starting:
            return .accentColor
        case .processing:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .secondary
        }
    }

    private var taskTimingText: String {
        let updated = Self.timeFormatter.string(from: task.updatedAt)
        if let finishedAt = task.finishedAt {
            return "完成 \(Self.timeFormatter.string(from: finishedAt)) · 更新 \(updated)"
        }
        return "创建 \(Self.timeFormatter.string(from: task.createdAt)) · 更新 \(updated)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var canRefresh: Bool {
        task.isActive && (
            task.provider == .replicate
                || task.provider == .someIM
                || AgentGenericMediaStatusClient.canPoll(task)
        )
    }

    private var canCancel: Bool {
        task.isActive && (
            task.provider == .replicate
                || task.provider == .someIM
                || AgentGenericMediaStatusClient.canCancel(task)
        )
    }

    private var canRetryViaChat: Bool {
        AgentMediaTaskChatHandoff.isRetryableShortDramaTask(task)
    }

    private var canContinueShotToVideo: Bool {
        guard !task.isActive, task.status == .succeeded, task.kind != .videoGeneration else { return false }
        guard clean(task.projectID) ?? clean(task.projectPath) != nil,
              clean(task.episodeID) != nil,
              clean(task.shotID) != nil else {
            return false
        }
        return !imageArtifacts.isEmpty
    }

    private var canResolveReviewItem: Bool {
        task.status == .succeeded && linkedOpenReviewItem != nil
    }

    private var linkedOpenReviewItem: AgentShortDramaReviewItem? {
        guard let reviewItemID = UUID(uuidString: clean(task.reviewItemID) ?? ""),
              let shotID = UUID(uuidString: clean(task.shotID) ?? "") else {
            return nil
        }
        guard let projectID = UUID(uuidString: clean(task.projectID) ?? "") ?? UUID(uuidString: clean(task.projectPath) ?? "") else {
            return nil
        }
        guard let project = appState.agentShortDramaStore.project(id: projectID) else { return nil }
        let episodeID = UUID(uuidString: clean(task.episodeID) ?? "")
        for episode in project.episodes {
            if let episodeID, episode.id != episodeID {
                continue
            }
            guard let shot = episode.shots.first(where: { $0.id == shotID }),
                  let item = shot.reviewItems.first(where: { $0.id == reviewItemID }) else {
                continue
            }
            return item.status == .resolved ? nil : item
        }
        return nil
    }

    private func refreshTask() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            await appState.agentMediaTaskPoller.refreshNow(
                taskID: task.id,
                registry: appState.agentMediaTaskRegistry
            )
        }
    }

    private func cancelTask() {
        guard !isCanceling else { return }
        isCanceling = true
        Task {
            defer { isCanceling = false }
            await appState.agentMediaTaskPoller.cancel(
                taskID: task.id,
                registry: appState.agentMediaTaskRegistry
            )
        }
    }

    private func resolveLinkedReviewItem() {
        guard let reviewItemID = UUID(uuidString: clean(task.reviewItemID) ?? ""),
              let shotID = UUID(uuidString: clean(task.shotID) ?? "") else {
            NSSound.beep()
            reviewResolveMessage = "这个任务缺少可关闭的检查项锚点。"
            return
        }
        guard let projectID = UUID(uuidString: clean(task.projectID) ?? "") ?? UUID(uuidString: clean(task.projectPath) ?? "") else {
            NSSound.beep()
            reviewResolveMessage = "这个任务缺少短剧项目锚点。"
            return
        }
        let episodeID = UUID(uuidString: clean(task.episodeID) ?? "")
        guard let resolved = appState.agentShortDramaStore.resolveReviewItem(
            projectID: projectID,
            episodeID: episodeID,
            shotID: shotID,
            itemID: reviewItemID
        ) else {
            NSSound.beep()
            reviewResolveMessage = "未找到关联检查项，可能已被移动或关闭。"
            return
        }
        appState.agentShortDramaStore.setActiveProject(id: projectID)
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .shortDrama)
        reviewResolveMessage = "已解决检查项：\(resolved.title)"
    }

    private func showArtifactChoiceWidget() {
        guard let runtimeID = appState.activeRuntime?.id else {
            NSSound.beep()
            return
        }
        let widget = AgentMediaTaskChoiceWidgetBuilder.widget(for: task, artifacts: imageArtifacts)
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func appendTaskContextToChat() {
        AgentMediaTaskChatHandoff.appendTaskContext(task: task, appState: appState)
    }

    private func appendShortDramaAnchorContextToChat(anchor: AgentShortDramaTaskAnchor) {
        var lines: [String] = [
            "请基于这个媒体任务关联的短剧锚点继续协作。",
            "",
            "<media-task-short-drama-anchor>",
            "action: inspect_media_task_short_drama_anchor",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "task_status: \(task.status.rawValue)",
            "anchor_label: \(anchor.displayLabel)",
            "project_id: \(anchor.projectID.uuidString)"
        ]
        appendCleanLine("episode_id", task.episodeID, to: &lines)
        appendCleanLine("shot_id", task.shotID, to: &lines)
        appendCleanLine("asset_kind", task.assetKind, to: &lines)
        appendCleanLine("asset_id", task.assetID, to: &lines)
        appendCleanLine("review_item_id", task.reviewItemID, to: &lines)
        lines.append("open_scope_tool: short_drama_open_media_tasks")
        lines.append("open_scope_arguments: \(shortDramaAnchorScopeArguments(anchor: anchor))")
        lines.append("open_short_drama_panel: 点击任务行锚点箭头可回到短剧侧栏。")
        lines.append("</media-task-short-drama-anchor>")

        let prompt = lines.joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains("<media-task-short-drama-anchor>") || !appState.agentInput.contains(task.id.uuidString) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func shortDramaAnchorScopeArguments(anchor: AgentShortDramaTaskAnchor) -> String {
        var pairs = ["project_id=\(anchor.projectID.uuidString)"]
        if let episodeID = clean(task.episodeID) {
            pairs.append("episode_id=\(episodeID)")
        }
        if let shotID = clean(task.shotID) {
            pairs.append("shot_id=\(shotID)")
        }
        if let assetKind = clean(task.assetKind), let assetID = clean(task.assetID) {
            pairs.append("scope=asset")
            pairs.append("asset_kind=\(assetKind)")
            pairs.append("asset_id=\(assetID)")
        }
        if let reviewItemID = clean(task.reviewItemID) {
            pairs.append("scope=review_item")
            pairs.append("review_item_id=\(reviewItemID)")
        }
        return pairs.joined(separator: ", ")
    }

    private func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = clean(value) else { return }
        lines.append("\(key): \(value)")
    }

    private func appendRetryTaskToChat() {
        AgentMediaTaskChatHandoff.appendRetryContext(task: task, appState: appState)
    }

    private func appendShotVideoContinuationToChat() {
        let images = imageArtifacts
        let primaryImage = images.first?.filePath ?? ""
        var lines: [String] = [
            "请基于这个短剧分镜图片继续生成视频。",
            "",
            "<short-drama-media-follow-up>",
            "action: generate_video_from_media_task",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "provider: \(task.provider.rawValue)",
            "source_kind: \(task.kind.rawValue)",
            "artifact_count: \(images.count)"
        ]
        if let projectID = clean(task.projectID) ?? clean(task.projectPath) {
            lines.append("project_id: \(projectID)")
        }
        if let episodeID = clean(task.episodeID) {
            lines.append("episode_id: \(episodeID)")
        }
        if let shotID = clean(task.shotID) {
            lines.append("shot_id: \(shotID)")
        }
        if !primaryImage.isEmpty {
            lines.append("selected_artifact_path: \(primaryImage)")
        }
        if let reviewItemID = clean(task.reviewItemID) {
            lines.append("review_item_id: \(reviewItemID)")
        }
        if images.count > 1 {
            lines.append("candidate_artifacts:")
            lines.append(contentsOf: images.prefix(12).map { "- \($0.filePath)" })
            if images.count > 12 {
                lines.append("- ... \(images.count - 12) more")
            }
        }
        lines.append("</short-drama-media-follow-up>")

        let instruction: String
        if images.count > 1 {
            instruction = "这个任务有多张候选图。请先调用 short_drama_show_image_choice_widget 让我确认主图；我选定后，优先调用 generate_video_from_image，并携带所选 image_path 与同一组 project_id / episode_id / shot_id；如果下面有 review_item_id，也必须一并传入。"
        } else {
            instruction = "请先调用 short_drama_select_shot_artifact 把 selected_artifact_path 设为该分镜主图，然后调用 generate_video_from_image，image_path 使用 selected_artifact_path，并携带同一组 project_id / episode_id / shot_id；如果下面有 review_item_id，也必须一并传入。"
        }
        let prompt = ([instruction, ""] + lines).joined(separator: "\n")
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains("generate_video_from_media_task") {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isImageArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }
        let ext = URL(fileURLWithPath: artifact.filePath).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(ext)
    }
}
