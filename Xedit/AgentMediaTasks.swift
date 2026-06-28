//
//  AgentMediaTasks.swift
//  WillDeep
//
//  Remote AI media generation/editing task tracking. This is intentionally
//  provider-neutral: some.im, Replicate, and future short-drama skills all
//  publish into the same registry so the side panel and chat loop can observe
//  one lifecycle instead of N custom polling surfaces.
//

import Foundation
import Combine
import AppKit
import SwiftUI

// Status filtering moved to AgentMediaTaskPanelSupport.swift:
// enum AgentMediaTaskStatusFilter
// Row-level refresh/cancel UI moved to AgentMediaTaskRow.swift:
// 立即刷新任务状态
// 取消远端任务
// await appState.agentMediaTaskPoller.cancel(
// AgentMediaTaskChoiceWidgetBuilder
// Label("候选图", systemImage: "rectangle.grid.2x2")
// 打开候选图选择器
// appState.agentShortDramaStore.anchor(for: task)
// appState.agentShortDramaStore.setActiveProject(id: anchor.projectID)
// AgentSidePanelOpenRequest(kind: .shortDrama)
// 打开对应短剧项目
// appendShortDramaAnchorContextToChat(anchor: anchor)
// <media-task-short-drama-anchor>
// action: inspect_media_task_short_drama_anchor
// open_scope_tool: short_drama_open_media_tasks
// shortDramaAnchorScopeArguments(anchor: anchor)
// 发送短剧锚点上下文到聊天
// appendTaskContextToChat()
// AgentMediaTaskChatHandoff.appendTaskContext(task: task, appState: appState)
// 发送任务上下文到聊天
// private var canContinueShotToVideo: Bool
// appendShotVideoContinuationToChat()
// Image(systemName: "film.stack")
// <short-drama-media-follow-up>
// action: generate_video_from_media_task
// selected_artifact_path: \(primaryImage)
// lines.append("review_item_id: \(reviewItemID)")
// 如果下面有 review_item_id，也必须一并传入
// short_drama_show_image_choice_widget
// short_drama_select_shot_artifact
// generate_video_from_image
// image_path 使用 selected_artifact_path
// canRetryViaChat
// AgentMediaTaskChatHandoff.isRetryableShortDramaTask(task)
// AgentMediaTaskChatHandoff.appendRetryContext(task: task, appState: appState)
// canResolveReviewItem
// linkedOpenReviewItem
// resolveLinkedReviewItem()
// checkmark.seal
// 把关联短剧检查项标记为已解决
// 这个任务缺少短剧项目锚点
// appState.agentShortDramaStore.resolveReviewItem

enum AgentMediaTaskProvider: String, Codable, CaseIterable, Identifiable {
    case someIM
    case replicate
    case skill
    case local
    case unknown

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .someIM: return "some.im"
        case .replicate: return "Replicate"
        case .skill: return "Skill"
        case .local: return "本地"
        case .unknown: return "未知"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .someIM: return "sparkles"
        case .replicate: return "arrow.triangle.2.circlepath"
        case .skill: return "puzzlepiece.extension"
        case .local: return "desktopcomputer"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum AgentMediaTaskKind: String, Codable, CaseIterable, Identifiable {
    case imageGeneration
    case imageEdit
    case imageUpscale
    case imageErase
    case imageInpaint
    case videoGeneration
    case shortDrama
    case unknown

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .imageGeneration: return "图片生成"
        case .imageEdit: return "图片编辑"
        case .imageUpscale: return "图片放大"
        case .imageErase: return "图片擦除"
        case .imageInpaint: return "蒙版重绘"
        case .videoGeneration: return "视频生成"
        case .shortDrama: return "短剧制作"
        case .unknown: return "媒体任务"
        }
    }

    nonisolated var systemImage: String {
        switch self {
        case .imageGeneration: return "photo.badge.plus"
        case .imageEdit: return "wand.and.stars"
        case .imageUpscale: return "arrow.up.left.and.arrow.down.right"
        case .imageErase: return "eraser"
        case .imageInpaint: return "paintbrush.pointed"
        case .videoGeneration: return "film.stack"
        case .shortDrama: return "rectangle.stack.badge.play"
        case .unknown: return "photo.on.rectangle"
        }
    }
}

enum AgentMediaTaskStatus: String, Codable, CaseIterable, Identifiable {
    case queued
    case submitted
    case starting
    case processing
    case succeeded
    case failed
    case canceled

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .submitted: return "已提交"
        case .starting: return "启动中"
        case .processing: return "处理中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .canceled: return "已取消"
        }
    }

    nonisolated var isActive: Bool {
        switch self {
        case .queued, .submitted, .starting, .processing:
            return true
        case .succeeded, .failed, .canceled:
            return false
        }
    }

    nonisolated var needsAttention: Bool {
        self == .failed
    }
}

struct AgentMediaArtifact: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var filePath: String
    var mimeType: String?
    var remoteURL: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        filePath: String,
        mimeType: String? = nil,
        remoteURL: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.mimeType = mimeType
        self.remoteURL = remoteURL
        self.createdAt = createdAt
    }
}

struct AgentMediaTask: Codable, Equatable, Identifiable {
    let id: UUID
    let shortID: String
    var provider: AgentMediaTaskProvider
    var kind: AgentMediaTaskKind
    var title: String
    var prompt: String?
    var model: String?
    var remoteTaskID: String?
    var statusURL: String?
    var cancelURL: String?
    var statusEndpointSuffix: String?
    var cancelEndpointSuffix: String?
    var sourceImagePath: String?
    var maskPath: String?
    var reviewItemID: String?
    var runtimeID: UUID?
    var projectID: String?
    var projectPath: String?
    var episodeID: String?
    var shotID: String?
    var assetKind: String?
    var assetID: String?
    var progress: Double?
    var status: AgentMediaTaskStatus
    var statusMessage: String?
    var artifacts: [AgentMediaArtifact]
    let createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?

    nonisolated var displayHandle: String { "media_\(shortID)" }
    nonisolated var isActive: Bool { status.isActive }
    nonisolated var needsAttention: Bool { status.needsAttention }
    nonisolated static let staleActiveUpdateInterval: TimeInterval = 30 * 60

    init(
        id: UUID = UUID(),
        provider: AgentMediaTaskProvider,
        kind: AgentMediaTaskKind,
        title: String,
        prompt: String? = nil,
        model: String? = nil,
        remoteTaskID: String? = nil,
        statusURL: String? = nil,
        cancelURL: String? = nil,
        statusEndpointSuffix: String? = nil,
        cancelEndpointSuffix: String? = nil,
        sourceImagePath: String? = nil,
        maskPath: String? = nil,
        reviewItemID: String? = nil,
        runtimeID: UUID? = nil,
        projectID: String? = nil,
        projectPath: String? = nil,
        episodeID: String? = nil,
        shotID: String? = nil,
        assetKind: String? = nil,
        assetID: String? = nil,
        progress: Double? = nil,
        status: AgentMediaTaskStatus = .queued,
        statusMessage: String? = nil,
        artifacts: [AgentMediaArtifact] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.shortID = String(id.uuidString.prefix(6)).lowercased()
        self.provider = provider
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.model = model
        self.remoteTaskID = remoteTaskID
        self.statusURL = statusURL
        self.cancelURL = cancelURL
        self.statusEndpointSuffix = statusEndpointSuffix
        self.cancelEndpointSuffix = cancelEndpointSuffix
        self.sourceImagePath = sourceImagePath
        self.maskPath = maskPath
        self.reviewItemID = reviewItemID
        self.runtimeID = runtimeID
        self.projectID = projectID
        self.projectPath = projectPath
        self.episodeID = episodeID
        self.shotID = shotID
        self.assetKind = assetKind
        self.assetID = assetID
        self.progress = progress
        self.status = status
        self.statusMessage = statusMessage
        self.artifacts = artifacts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }

    nonisolated func isStaleActive(now: Date = Date()) -> Bool {
        isActive && now.timeIntervalSince(updatedAt) >= Self.staleActiveUpdateInterval
    }

    nonisolated func staleActiveMinutes(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(updatedAt) / 60))
    }
}

@MainActor
final class AgentMediaTaskRegistry: ObservableObject {
    @Published private(set) var tasks: [AgentMediaTask]

    private static let historyLimit = 100
    private let fileURL: URL
    private var pendingCompletionEvents: [UUID: [UUID]] = [:]
    weak var shortDramaStore: AgentShortDramaStore?

    init(fileURL: URL = AgentMediaTaskRegistry.defaultFileURL()) {
        self.fileURL = fileURL
        self.tasks = Self.load(from: fileURL)
        trimHistory(saveAfterTrim: false)
    }

    @discardableResult
    func create(
        provider: AgentMediaTaskProvider,
        kind: AgentMediaTaskKind,
        title: String,
        prompt: String? = nil,
        model: String? = nil,
        remoteTaskID: String? = nil,
        statusURL: String? = nil,
        cancelURL: String? = nil,
        statusEndpointSuffix: String? = nil,
        cancelEndpointSuffix: String? = nil,
        sourceImagePath: String? = nil,
        maskPath: String? = nil,
        reviewItemID: String? = nil,
        runtimeID: UUID? = nil,
        projectID: String? = nil,
        projectPath: String? = nil,
        episodeID: String? = nil,
        shotID: String? = nil,
        assetKind: String? = nil,
        assetID: String? = nil,
        status: AgentMediaTaskStatus = .queued,
        statusMessage: String? = nil
    ) -> AgentMediaTask {
        let task = AgentMediaTask(
            provider: provider,
            kind: kind,
            title: title,
            prompt: prompt,
            model: model,
            remoteTaskID: remoteTaskID,
            statusURL: statusURL,
            cancelURL: cancelURL,
            statusEndpointSuffix: statusEndpointSuffix,
            cancelEndpointSuffix: cancelEndpointSuffix,
            sourceImagePath: sourceImagePath,
            maskPath: maskPath,
            reviewItemID: reviewItemID,
            runtimeID: runtimeID,
            projectID: projectID,
            projectPath: projectPath,
            episodeID: episodeID,
            shotID: shotID,
            assetKind: assetKind,
            assetID: assetID,
            status: status,
            statusMessage: statusMessage
        )
        insertOrUpdate(task)
        syncShortDramaLinks(for: task)
        return task
    }

    func update(
        id: UUID,
        status: AgentMediaTaskStatus? = nil,
        progress: Double? = nil,
        statusMessage: String? = nil,
        remoteTaskID: String? = nil,
        statusURL: String? = nil,
        cancelURL: String? = nil,
        statusEndpointSuffix: String? = nil,
        cancelEndpointSuffix: String? = nil,
        sourceImagePath: String? = nil,
        maskPath: String? = nil,
        reviewItemID: String? = nil,
        artifacts: [AgentMediaArtifact]? = nil
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = tasks[index]
        let previousStatus = task.status
        if let status { task.status = status }
        if let progress { task.progress = max(0, min(1, progress)) }
        if let statusMessage { task.statusMessage = statusMessage }
        if let remoteTaskID { task.remoteTaskID = remoteTaskID }
        if let statusURL { task.statusURL = statusURL }
        if let cancelURL { task.cancelURL = cancelURL }
        if let statusEndpointSuffix { task.statusEndpointSuffix = statusEndpointSuffix }
        if let cancelEndpointSuffix { task.cancelEndpointSuffix = cancelEndpointSuffix }
        if let sourceImagePath { task.sourceImagePath = sourceImagePath }
        if let maskPath { task.maskPath = maskPath }
        if let reviewItemID { task.reviewItemID = reviewItemID }
        if let artifacts { task.artifacts = artifacts }
        task.updatedAt = Date()
        if !task.status.isActive, task.finishedAt == nil {
            task.finishedAt = task.updatedAt
        }
        tasks[index] = task
        if previousStatus.isActive, !task.status.isActive, let runtimeID = task.runtimeID {
            pendingCompletionEvents[runtimeID, default: []].append(task.id)
        }
        syncShortDramaLinks(for: task)
        trimHistory()
    }

    func appendArtifact(_ artifact: AgentMediaArtifact, to taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var task = tasks[index]
        task.artifacts.append(artifact)
        task.updatedAt = Date()
        tasks[index] = task
        syncShortDramaLinks(for: task)
        save()
    }

    func moveShortDramaShotAnchors(projectID: UUID, shotID: UUID, episodeID: UUID) -> Int {
        var updated = 0
        let projectValue = projectID.uuidString
        let shotValue = shotID.uuidString
        let episodeValue = episodeID.uuidString
        for index in tasks.indices {
            guard (tasks[index].projectID == projectValue || tasks[index].projectPath == projectValue),
                  tasks[index].shotID == shotValue,
                  tasks[index].episodeID != episodeValue else {
                continue
            }
            tasks[index].episodeID = episodeValue
            tasks[index].updatedAt = Date()
            updated += 1
        }
        if updated > 0 {
            save()
        }
        return updated
    }

    func tasks(forRuntime runtimeID: UUID?) -> [AgentMediaTask] {
        guard let runtimeID else { return tasks }
        let scoped = tasks.filter { $0.runtimeID == runtimeID || $0.runtimeID == nil }
        return scoped.sorted { $0.updatedAt > $1.updatedAt }
    }

    func task(matchingHandle handle: String, runtimeID: UUID?) -> AgentMediaTask? {
        let clean = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }
        return tasks(forRuntime: runtimeID).first { task in
            task.id.uuidString.lowercased() == clean
                || task.shortID == clean
                || task.displayHandle.lowercased() == clean
        }
    }

    func consumePendingCompletions(forRuntime runtimeID: UUID) -> [AgentMediaTask] {
        guard let ids = pendingCompletionEvents.removeValue(forKey: runtimeID), !ids.isEmpty else {
            return []
        }
        return ids.compactMap { id in tasks.first(where: { $0.id == id }) }
    }

    private func insertOrUpdate(_ task: AgentMediaTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
        trimHistory()
    }

    private func trimHistory(saveAfterTrim: Bool = true) {
        let alive = tasks.filter(\.isActive)
        let finished = tasks.filter { !$0.isActive }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.historyLimit)
        tasks = (alive + finished).sorted { $0.updatedAt > $1.updatedAt }
        if saveAfterTrim {
            save()
        }
    }

    private func syncShortDramaLinks(for task: AgentMediaTask) {
        syncShortDramaShot(for: task)
        syncShortDramaAsset(for: task)
        syncShortDramaReviewItem(for: task)
    }

    private func syncShortDramaShot(for task: AgentMediaTask) {
        guard let store = shortDramaStore,
              let shotID = cleanUUID(task.shotID) else {
            return
        }
        let projectID = cleanUUID(task.projectID) ?? cleanUUID(task.projectPath)
        let episodeID = cleanUUID(task.episodeID)
        let status: AgentShortDramaShotStatus?
        switch task.status {
        case .queued, .submitted, .starting, .processing:
            status = .generating
        case .succeeded:
            status = .ready
        case .failed, .canceled:
            status = .needsReview
        }
        _ = store.attachArtifactsToShot(
            projectID: projectID,
            episodeID: episodeID,
            shotID: shotID,
            artifactPaths: task.artifacts.map(\.filePath),
            status: status
        )
    }

    private func syncShortDramaAsset(for task: AgentMediaTask) {
        guard let store = shortDramaStore,
              task.status == .succeeded,
              !task.artifacts.isEmpty,
              let projectID = cleanUUID(task.projectID) ?? cleanUUID(task.projectPath),
              let assetID = cleanUUID(task.assetID),
              let assetKind = clean(task.assetKind) else {
            return
        }
        _ = store.attachReferenceImages(
            projectID: projectID,
            assetKind: assetKind,
            assetID: assetID,
            imagePaths: task.artifacts.map(\.filePath)
        )
    }

    private func syncShortDramaReviewItem(for task: AgentMediaTask) {
        guard let store = shortDramaStore,
              let reviewItemID = cleanUUID(task.reviewItemID),
              let shotID = cleanUUID(task.shotID) else {
            return
        }
        let projectID = cleanUUID(task.projectID) ?? cleanUUID(task.projectPath)
        let episodeID = cleanUUID(task.episodeID)
        let reviewStatus: AgentShortDramaReviewItemStatus
        switch task.status {
        case .queued, .submitted, .starting, .processing, .succeeded:
            reviewStatus = .doing
        case .failed, .canceled:
            reviewStatus = .open
        }
        _ = store.updateReviewItemStatus(
            projectID: projectID,
            episodeID: episodeID,
            shotID: shotID,
            itemID: reviewItemID,
            status: reviewStatus
        )
    }

    private func cleanUUID(_ value: String?) -> UUID? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("AgentMediaTaskRegistry: failed to save tasks: \(error)")
        }
    }

    private static func load(from url: URL) -> [AgentMediaTask] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AgentMediaTask].self, from: data)) ?? []
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("WillDeep/media-tasks/tasks.json", isDirectory: false)
    }
}

@MainActor
final class AgentMediaTaskPoller {
    private let tickSeconds: UInt64 = 2
    private let pollInterval: TimeInterval = 8

    private var loopTask: Task<Void, Never>?
    private var inFlightTaskIDs: Set<UUID> = []
    private var lastPollAt: [UUID: Date] = [:]

    func start(registry: AgentMediaTaskRegistry) {
        guard loopTask == nil else { return }
        let tickNanoseconds = tickSeconds * 1_000_000_000
        loopTask = Task { [weak self, weak registry] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tickNanoseconds)
                guard let self, let registry else { continue }
                self.pollDueTasks(in: registry)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        inFlightTaskIDs.removeAll()
        lastPollAt.removeAll()
    }

    func refreshNow(taskID: UUID, registry: AgentMediaTaskRegistry) async {
        guard let task = registry.tasks.first(where: { $0.id == taskID }) else { return }
        guard supportsPolling(task) else {
            registry.update(id: taskID, statusMessage: "此任务来源暂不支持手动刷新。")
            return
        }
        guard pollHandle(for: task) != nil else {
            registry.update(id: taskID, statusMessage: "缺少远端任务 ID 或状态 URL，无法刷新。")
            return
        }
        guard !inFlightTaskIDs.contains(taskID) else { return }
        inFlightTaskIDs.insert(taskID)
        lastPollAt[taskID] = Date()
        await poll(task, registry: registry)
    }

    func cancel(taskID: UUID, registry: AgentMediaTaskRegistry) async {
        guard let task = registry.tasks.first(where: { $0.id == taskID }) else { return }
        guard task.isActive else { return }
        do {
            switch task.provider {
            case .replicate:
                try await cancelReplicate(task, registry: registry)
            case .someIM:
                try await cancelSomeIM(task, registry: registry)
            case .skill, .local, .unknown:
                if AgentGenericMediaStatusClient.canCancel(task) {
                    try await cancelGeneric(task, registry: registry)
                } else {
                    registry.update(id: task.id, statusMessage: "此任务来源缺少 HTTPS cancel_url，无法远端取消。")
                }
            }
        } catch {
            registry.update(id: task.id, statusMessage: "取消失败：\(error.localizedDescription)")
        }
    }

    private func pollDueTasks(in registry: AgentMediaTaskRegistry) {
        let now = Date()
        for task in registry.tasks where shouldPoll(task, now: now) {
            inFlightTaskIDs.insert(task.id)
            lastPollAt[task.id] = now
            Task { [weak self, weak registry] in
                guard let self, let registry else { return }
                await self.poll(task, registry: registry)
            }
        }
    }

    private func shouldPoll(_ task: AgentMediaTask, now: Date) -> Bool {
        guard task.isActive, !inFlightTaskIDs.contains(task.id) else { return false }
        guard pollHandle(for: task) != nil else { return false }
        guard supportsPolling(task) else { return false }
        if let last = lastPollAt[task.id], now.timeIntervalSince(last) < pollInterval {
            return false
        }
        return true
    }

    private func poll(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry) async {
        defer { inFlightTaskIDs.remove(task.id) }
        do {
            switch task.provider {
            case .replicate:
                try await pollReplicate(task, registry: registry)
            case .someIM:
                try await pollSomeIM(task, registry: registry)
            case .skill, .local, .unknown:
                try await pollGenericStatusURL(task, registry: registry)
            }
        } catch {
            registry.update(
                id: task.id,
                statusMessage: "自动刷新失败：\(error.localizedDescription)"
            )
        }
    }

    private func pollReplicate(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry) async throws {
        guard let handle = pollHandle(for: task) else { return }
        let prediction = try await ReplicateClient.getPrediction(idOrURL: handle)
        let status = ReplicateClient.status(from: prediction.status)
        let artifacts = try await artifactsIfComplete(
            status: status,
            existingArtifacts: task.artifacts,
            download: {
                try await ReplicateClient.downloadArtifacts(from: prediction, title: task.title).map(\.mediaArtifact)
            }
        )
        registry.update(
            id: task.id,
            status: status,
            progress: progress(for: status),
            statusMessage: ReplicateClient.statusMessage(for: prediction),
            remoteTaskID: prediction.id,
            statusURL: prediction.urls?.get,
            cancelURL: prediction.urls?.cancel,
            artifacts: artifacts
        )
    }

    private func pollSomeIM(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry) async throws {
        guard let handle = pollHandle(for: task) else { return }
        let settings = SomeIMIntegrationStore.loadSettings()
        let response = try await SomeIMAsyncMediaClient.poll(
            idOrURL: handle,
            endpointSuffix: endpointSuffix(for: task),
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        let artifacts = try await artifactsIfComplete(
            status: status,
            existingArtifacts: task.artifacts,
            download: {
                try await SomeIMAsyncMediaClient.downloadArtifacts(from: response, title: task.title).map(\.mediaArtifact)
            }
        )
        registry.update(
            id: task.id,
            status: status,
            progress: progress(for: status),
            statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response),
            remoteTaskID: response.id,
            statusURL: response.statusURL,
            cancelURL: response.cancelURL,
            statusEndpointSuffix: task.statusEndpointSuffix,
            cancelEndpointSuffix: task.cancelEndpointSuffix,
            artifacts: artifacts
        )
    }

    private func pollGenericStatusURL(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry) async throws {
        guard AgentGenericMediaStatusClient.canPoll(task) else { return }
        let response = try await AgentGenericMediaStatusClient.poll(task: task)
        let status = AgentGenericMediaStatusClient.status(from: response.status)
        let artifacts = try await artifactsIfComplete(
            status: status,
            existingArtifacts: task.artifacts,
            download: {
                try await AgentGenericMediaStatusClient.downloadArtifacts(from: response, title: task.title)
            }
        )
        registry.update(
            id: task.id,
            status: status,
            progress: progress(for: status),
            statusMessage: AgentGenericMediaStatusClient.statusMessage(for: response),
            remoteTaskID: response.remoteTaskID ?? task.remoteTaskID,
            statusURL: response.statusURL ?? task.statusURL,
            cancelURL: response.cancelURL ?? task.cancelURL,
            artifacts: artifacts
        )
    }

    private func cancelReplicate(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry) async throws {
        guard let handle = clean(task.cancelURL) ?? clean(task.remoteTaskID) else {
            registry.update(id: task.id, statusMessage: "缺少 Replicate cancel URL 或远端任务 ID。")
            return
        }
        let prediction = try await ReplicateClient.cancelPrediction(idOrURL: handle)
        let status = ReplicateClient.status(from: prediction.status)
        registry.update(
            id: task.id,
            status: status,
            progress: progress(for: status),
            statusMessage: ReplicateClient.statusMessage(for: prediction),
            remoteTaskID: prediction.id,
            statusURL: prediction.urls?.get,
            cancelURL: prediction.urls?.cancel
        )
    }

    private func cancelSomeIM(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry) async throws {
        guard let handle = clean(task.cancelURL) ?? clean(task.remoteTaskID) else {
            registry.update(id: task.id, statusMessage: "缺少 some.im cancel URL 或远端任务 ID。")
            return
        }
        let settings = SomeIMIntegrationStore.loadSettings()
        let response = try await SomeIMAsyncMediaClient.cancel(
            idOrURL: handle,
            endpointSuffix: cancelEndpointSuffix(for: task),
            settings: settings,
            apiKey: SomeIMIntegrationStore.loadAPIKey()
        )
        let status = SomeIMAsyncMediaClient.status(from: response.status)
        registry.update(
            id: task.id,
            status: status,
            progress: progress(for: status),
            statusMessage: SomeIMAsyncMediaClient.statusMessage(for: response),
            remoteTaskID: response.id,
            statusURL: response.statusURL ?? task.statusURL,
            cancelURL: response.cancelURL ?? task.cancelURL,
            statusEndpointSuffix: task.statusEndpointSuffix,
            cancelEndpointSuffix: task.cancelEndpointSuffix
        )
    }

    private func cancelGeneric(_ task: AgentMediaTask, registry: AgentMediaTaskRegistry) async throws {
        let response = try await AgentGenericMediaStatusClient.cancel(task: task)
        let status = AgentGenericMediaStatusClient.status(from: response.status)
        registry.update(
            id: task.id,
            status: status,
            progress: progress(for: status),
            statusMessage: AgentGenericMediaStatusClient.statusMessage(for: response),
            remoteTaskID: response.remoteTaskID ?? task.remoteTaskID,
            statusURL: response.statusURL ?? task.statusURL,
            cancelURL: response.cancelURL ?? task.cancelURL
        )
    }

    private func artifactsIfComplete(
        status: AgentMediaTaskStatus,
        existingArtifacts: [AgentMediaArtifact],
        download: () async throws -> [AgentMediaArtifact]
    ) async throws -> [AgentMediaArtifact]? {
        guard status == .succeeded, existingArtifacts.isEmpty else { return nil }
        let downloaded = try await download()
        return downloaded.isEmpty ? nil : downloaded
    }

    private func pollHandle(for task: AgentMediaTask) -> String? {
        clean(task.statusURL) ?? clean(task.remoteTaskID)
    }

    private func supportsPolling(_ task: AgentMediaTask) -> Bool {
        task.provider == .replicate || task.provider == .someIM || AgentGenericMediaStatusClient.canPoll(task)
    }

    private func endpointSuffix(for task: AgentMediaTask) -> String? {
        if let statusURL = clean(task.statusURL),
           URL(string: statusURL)?.scheme?.hasPrefix("http") == true {
            return nil
        }
        if let statusEndpointSuffix = clean(task.statusEndpointSuffix) {
            return statusEndpointSuffix
        }
        return SomeIMAsyncMediaClient.defaultEndpointSuffix(for: task.kind)
    }

    private func cancelEndpointSuffix(for task: AgentMediaTask) -> String? {
        if let cancelURL = clean(task.cancelURL),
           URL(string: cancelURL)?.scheme?.hasPrefix("http") == true {
            return nil
        }
        if let cancelEndpointSuffix = clean(task.cancelEndpointSuffix) {
            return cancelEndpointSuffix
        }
        if let statusEndpointSuffix = clean(task.statusEndpointSuffix) {
            return statusEndpointSuffix
        }
        return SomeIMAsyncMediaClient.defaultEndpointSuffix(for: task.kind)
    }

    private func progress(for status: AgentMediaTaskStatus) -> Double {
        switch status {
        case .queued: return 0.08
        case .submitted: return 0.18
        case .starting: return 0.28
        case .processing: return 0.56
        case .succeeded: return 1
        case .failed, .canceled: return 0
        }
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AgentMediaTaskScope: Equatable {
    var label: String
    var projectID: String?
    var episodeID: String?
    var shotID: String?
    var assetKind: String?
    var assetID: String?
    var reviewItemID: String?

    func matches(_ task: AgentMediaTask) -> Bool {
        if let projectID,
           task.projectID != projectID,
           task.projectPath != projectID {
            return false
        }
        if let episodeID, task.episodeID != episodeID {
            return false
        }
        if let shotID, task.shotID != shotID {
            return false
        }
        if let assetKind, task.assetKind != assetKind {
            return false
        }
        if let assetID, task.assetID != assetID {
            return false
        }
        if let reviewItemID, task.reviewItemID != reviewItemID {
            return false
        }
        return true
    }
}

struct AgentMediaTasksPanel: View {
    @EnvironmentObject var appState: AppState
    var width: CGFloat = 320
    @State private var scope: AgentMediaTaskScope?
    @State private var statusFilter: AgentMediaTaskStatusFilter = .all
    @State private var isRefreshingVisible = false

    private var allTasks: [AgentMediaTask] {
        appState.agentMediaTaskRegistry.tasks(forRuntime: appState.activeRuntime?.id)
    }

    private var scopedTasks: [AgentMediaTask] {
        guard let scope else { return allTasks }
        return allTasks.filter { scope.matches($0) }
    }

    private var tasks: [AgentMediaTask] {
        scopedTasks.filter { statusFilter.matches($0) }
    }

    private var refreshableScopedTasks: [AgentMediaTask] {
        scopedTasks.filter { task in
            task.isActive && (
                task.provider == .replicate
                    || task.provider == .someIM
                    || AgentGenericMediaStatusClient.canPoll(task)
            )
        }
    }

    private var staleRefreshableScopedTasks: [AgentMediaTask] {
        refreshableScopedTasks.filter { $0.isStaleActive() }
    }

    private var retryableScopedTasks: [AgentMediaTask] {
        scopedTasks.filter(AgentMediaTaskChatHandoff.isRetryableShortDramaTask)
    }

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summarySection
                if tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(tasks) { task in
                        AgentMediaTaskRow(task: task)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(width: width)
        .background(palette.panelFill)
        .onAppear {
            scope = appState.agentMediaTaskPanelScope
        }
        .onCompatibleChange(of: appState.agentMediaTaskPanelScope) { _, newScope in
            scope = newScope
        }
    }

    private var summarySection: some View {
        let active = scopedTasks.filter(\.isActive).count
        let stale = scopedTasks.filter { $0.isStaleActive() }.count
        let failed = scopedTasks.filter(\.needsAttention).count
        let finished = scopedTasks.filter { !$0.isActive && !$0.needsAttention }.count
        let completedImages = scopedTasks.filter(AgentMediaTaskChatHandoff.hasCompletedImageArtifact).count
        let completedVideos = scopedTasks.filter(AgentMediaTaskChatHandoff.hasCompletedVideoArtifact).count
        return AgentMediaPanelSection(title: "媒体任务", systemImage: "photo.stack") {
            if let scope {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Text(scope.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        appState.agentMediaTaskPanelScope = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("清除媒体任务筛选")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.08)))
            }

            Picker("任务状态", selection: $statusFilter) {
                ForEach(AgentMediaTaskStatusFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("按任务状态筛选")

            AgentMediaMetaRow(label: "当前显示", value: "\(tasks.count)")
            if scope != nil || statusFilter != .all {
                AgentMediaMetaRow(label: "筛选前", value: "\(scopedTasks.count)")
            }
            AgentMediaMetaRow(label: "运行中", value: "\(active)")
            if stale > 0 {
                AgentMediaMetaRow(label: "可能卡住", value: "\(stale)")
            }
            if failed > 0 {
                AgentMediaMetaRow(label: "需要处理", value: "\(failed)")
            }
            if finished > 0 {
                AgentMediaMetaRow(label: "已完成", value: "\(finished)")
            }
            if completedImages > 0 {
                AgentMediaMetaRow(label: "完成图片", value: "\(completedImages)")
            }
            if completedVideos > 0 {
                AgentMediaMetaRow(label: "完成视频", value: "\(completedVideos)")
            }
            mediaTaskQuickFilters(active: active, stale: stale, failed: failed, finished: finished)
            if !staleRefreshableScopedTasks.isEmpty {
                Button {
                    refreshStaleActiveTasks()
                } label: {
                    Label(
                        isRefreshingVisible ? "刷新中" : "刷新卡住",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingVisible)
                .help("立即刷新当前筛选范围内长时间未更新的运行中任务")
            }
            if !refreshableScopedTasks.isEmpty {
                Button {
                    refreshVisibleActiveTasks()
                } label: {
                    Label(
                        isRefreshingVisible ? "刷新中" : "刷新运行中",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingVisible)
                .help("立即刷新当前筛选范围内的运行中任务")
            }
            if !scopedTasks.isEmpty {
                Button {
                    appendScopedStatusToChat()
                } label: {
                    Label("发送状态到聊天", systemImage: "text.bubble")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("把当前筛选范围内的媒体任务状态摘要发送到聊天")
            }
            if scope != nil, !retryableScopedTasks.isEmpty {
                Button {
                    appendScopedRetryToChat()
                } label: {
                    Label("重试失败任务", systemImage: "arrow.counterclockwise.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("把当前筛选范围内失败任务的批量重试请求发送到聊天")
            }
        }
    }

    private func mediaTaskQuickFilters(active: Int, stale: Int, failed: Int, finished: Int) -> some View {
        HStack(spacing: 6) {
            if active > 0 {
                mediaTaskFilterButton("运行中", filter: .active)
            }
            if stale > 0 {
                mediaTaskFilterButton("卡住", filter: .stale)
            }
            if failed > 0 {
                mediaTaskFilterButton("需处理", filter: .attention)
            }
            if finished > 0 {
                mediaTaskFilterButton("已完成", filter: .finished)
            }
            if statusFilter != .all {
                mediaTaskFilterButton("全部", filter: .all)
            }
        }
    }

    private func mediaTaskFilterButton(_ title: String, filter: AgentMediaTaskStatusFilter) -> some View {
        Button {
            statusFilter = filter
        } label: {
            Text(title)
                .font(.caption2.weight(statusFilter == filter ? .semibold : .regular))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(statusFilter == filter ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("只看\(title)媒体任务")
    }

    private func refreshVisibleActiveTasks() {
        refreshTaskIDs(refreshableScopedTasks.map(\.id), reason: "refresh_visible_active_tasks")
    }

    private func refreshStaleActiveTasks() {
        refreshTaskIDs(staleRefreshableScopedTasks.map(\.id), reason: "refresh_stale_active_tasks")
    }

    private func refreshTaskIDs(_ taskIDs: [UUID], reason: String) {
        guard !isRefreshingVisible else { return }
        guard !taskIDs.isEmpty else { return }
        isRefreshingVisible = true
        Task {
            for taskID in taskIDs {
                await appState.agentMediaTaskPoller.refreshNow(
                    taskID: taskID,
                    registry: appState.agentMediaTaskRegistry
                )
            }
            let refreshedIDSet = Set(taskIDs)
            let refreshedTasks = appState.agentMediaTaskRegistry.tasks(forRuntime: appState.activeRuntime?.id)
                .filter { refreshedIDSet.contains($0.id) }
            appState.recordAgentMediaTaskRefresh(
                reason: reason,
                scopeLabel: scope?.label ?? "全部媒体任务",
                tasks: refreshedTasks
            )
            isRefreshingVisible = false
        }
    }

    private func appendScopedStatusToChat() {
        let active = scopedTasks.filter(\.isActive)
        let staleActive = active.filter { $0.isStaleActive() }
        let failed = scopedTasks.filter(\.needsAttention)
        let finished = scopedTasks.filter { !$0.isActive && !$0.needsAttention }
        let completedImageTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedImageArtifact)
        let completedVideoTasks = finished.filter(AgentMediaTaskChatHandoff.hasCompletedVideoArtifact)
        var lines = [
            "请基于当前媒体任务筛选范围继续推进制作。",
            "",
            "<media-task-scope-status>",
            "action: inspect_media_task_scope",
            "scope_label: \(scope?.label ?? "全部媒体任务")",
            "total_count: \(scopedTasks.count)",
            "active_count: \(active.count)",
            "stale_active_count: \(staleActive.count)",
            "failed_count: \(failed.count)",
            "finished_count: \(finished.count)",
            "completed_image_task_count: \(completedImageTasks.count)",
            "completed_video_task_count: \(completedVideoTasks.count)",
            "open_tasks_tool: short_drama_open_media_tasks"
        ]
        if let scope {
            appendScopeLines(scope, to: &lines)
            lines.append("open_tasks_arguments: \(scopedRetryArguments(scope: scope))")
            if !active.isEmpty {
                lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_tasks_arguments: \(scopedRetryArguments(scope: scope))")
            }
            if !retryableScopedTasks.isEmpty {
                let retryArguments = scopedRetryArguments(scope: scope)
                lines.append("retry_failed_tool: short_drama_retry_failed_media_tasks")
                lines.append("retry_failed_dry_run_arguments: \(retryArguments), dry_run=true")
                lines.append("retry_failed_submit_arguments: \(retryArguments), dry_run=false")
            }
        } else {
            lines.append("open_tasks_arguments: scope=all")
        }
        if !active.isEmpty {
            lines.append("active_tasks:")
            lines.append(contentsOf: active.prefix(12).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
            lines.append("active_task_actions:")
            lines.append(contentsOf: active.prefix(12).compactMap(AgentMediaTaskChatHandoff.activeTaskScopeSummaryLine))
            lines.append("active_task_follow_up: active_task_actions 已包含可直接调用的 provider 轮询/取消参数；也可先用 refresh_tasks_tool 刷新当前范围。")
        }
        if !staleActive.isEmpty {
            lines.append("stale_active_tasks:")
            lines.append(contentsOf: staleActive.prefix(12).compactMap(AgentMediaTaskChatHandoff.staleActiveTaskScopeSummaryLine))
            lines.append("stale_active_follow_up: stale_active_tasks 表示运行中但超过 30 分钟未更新；优先刷新同一范围，若仍无变化再询问用户是否取消、重试或等待外部回导。")
        }
        if !failed.isEmpty {
            lines.append("failed_tasks:")
            lines.append(contentsOf: failed.prefix(12).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
        }
        if !finished.isEmpty {
            lines.append("finished_tasks:")
            lines.append(contentsOf: finished.prefix(12).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
        }
        if !completedImageTasks.isEmpty {
            lines.append("completed_image_tasks:")
            lines.append(contentsOf: completedImageTasks.prefix(12).compactMap(AgentMediaTaskChatHandoff.completedImageScopeSummaryLine))
            lines.append("completed_image_follow_up: completed_image_tasks 已包含可直接调用的后续工具参数；对单个任务调用“发送任务上下文到聊天”还会展开完整 <media-task-completed-artifact-actions>。")
        }
        if !completedVideoTasks.isEmpty {
            lines.append("completed_video_tasks:")
            lines.append(contentsOf: completedVideoTasks.prefix(12).compactMap(AgentMediaTaskChatHandoff.completedVideoScopeSummaryLine))
            lines.append("completed_video_follow_up: completed_video_tasks 已包含可直接调用的审片、分镜板和任务范围参数；对单个任务调用“发送任务上下文到聊天”还会展开完整 <media-task-completed-video-actions>。")
        }
        lines.append("</media-task-scope-status>")
        appendPromptToChat(lines.joined(separator: "\n"), duplicateGuard: "<media-task-scope-status>")
    }

    private func appendScopeLines(_ scope: AgentMediaTaskScope, to lines: inout [String]) {
        lines.append("scope: \(retryScopeKind(scope))")
        if let projectID = scope.projectID {
            lines.append("project_id: \(projectID)")
        }
        if let episodeID = scope.episodeID {
            lines.append("episode_id: \(episodeID)")
        }
        if let shotID = scope.shotID {
            lines.append("shot_id: \(shotID)")
        }
        if let assetKind = scope.assetKind {
            lines.append("asset_kind: \(assetKind)")
        }
        if let assetID = scope.assetID {
            lines.append("asset_id: \(assetID)")
        }
        if let reviewItemID = scope.reviewItemID {
            lines.append("review_item_id: \(reviewItemID)")
        }
    }

    private func appendScopedRetryToChat() {
        guard let scope else { return }
        var lines = [
            "请批量重试当前媒体任务筛选范围内的失败短剧任务。请先调用 short_drama_retry_failed_media_tasks，使用 dry_run=true 预检；如果预检结果合理，再提交正式重试。",
            "",
            "<short-drama-media-task-retry-scope>",
            "action: retry_failed_media_tasks",
            "scope: \(retryScopeKind(scope))",
            "scope_label: \(scope.label)",
            "retryable_count: \(retryableScopedTasks.count)",
            "retry_failed_tool: short_drama_retry_failed_media_tasks"
        ]
        appendScopeLines(scope, to: &lines)
        let retryArguments = scopedRetryArguments(scope: scope)
        lines.append("retry_failed_dry_run_arguments: \(retryArguments), dry_run=true")
        lines.append("retry_failed_submit_arguments: \(retryArguments), dry_run=false")
        lines.append("tasks:")
        lines.append(contentsOf: retryableScopedTasks.prefix(20).map { "- \($0.displayHandle) · \($0.kind.rawValue) · \($0.title)" })
        if retryableScopedTasks.count > 20 {
            lines.append("- ... \(retryableScopedTasks.count - 20) more")
        }
        lines.append("</short-drama-media-task-retry-scope>")

        appendPromptToChat(lines.joined(separator: "\n"), duplicateGuard: "retry_failed_media_tasks")
    }

    private func appendPromptToChat(_ prompt: String, duplicateGuard: String) {
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else if !appState.agentInput.contains(duplicateGuard) {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func scopedRetryArguments(scope: AgentMediaTaskScope) -> String {
        var pairs: [(String, String)] = [("scope", retryScopeKind(scope))]
        appendCleanPair("project_id", scope.projectID, to: &pairs)
        appendCleanPair("episode_id", scope.episodeID, to: &pairs)
        appendCleanPair("shot_id", scope.shotID, to: &pairs)
        appendCleanPair("asset_kind", scope.assetKind, to: &pairs)
        appendCleanPair("asset_id", scope.assetID, to: &pairs)
        appendCleanPair("review_item_id", scope.reviewItemID, to: &pairs)
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private func appendCleanPair(_ key: String, _ value: String?, to pairs: inout [(String, String)]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        pairs.append((key, value))
    }

    private func retryScopeKind(_ scope: AgentMediaTaskScope) -> String {
        if scope.assetID != nil {
            return "asset"
        }
        if scope.reviewItemID != nil {
            return "review_item"
        }
        if scope.shotID != nil {
            return "shot"
        }
        if scope.episodeID != nil {
            return "episode"
        }
        return "project"
    }

    private var emptyState: some View {
        let isFilteredEmpty = !scopedTasks.isEmpty && statusFilter != .all
        return VStack(spacing: 10) {
            Spacer(minLength: 32)
            Image(systemName: "photo.stack")
                .font(.system(size: 26))
                .foregroundStyle(.secondary.opacity(0.65))
            Text(isFilteredEmpty ? "当前筛选暂无任务" : "暂无媒体任务")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(isFilteredEmpty ? "这个范围里有媒体任务，但没有符合当前状态筛选的条目。" : "some.im、Replicate 和短剧 Skill 的异步图片/视频任务会显示在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if isFilteredEmpty {
                Button {
                    statusFilter = .all
                } label: {
                    Label("查看全部任务", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("清除任务状态筛选")
            }
            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
    }
}
