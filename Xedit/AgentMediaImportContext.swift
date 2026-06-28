//
//  AgentMediaImportContext.swift
//  WillDeep
//
//  Runtime context for the most recent media manifest import. This keeps
//  Ruby/Skill/third-party API package handoff visible after the tool turn.
//

import Foundation

struct AgentMediaImportContext: Equatable, Identifiable {
    let id: UUID
    var manifestPath: String
    var baseDirectory: String
    var packageDirectory: String?
    var widgetPreviewPath: String?
    var gapReportPath: String?
    var importedFileCount: Int
    var pendingRemoteTaskCount: Int
    var failedManifestTaskCount: Int
    var skippedMissingCount: Int
    var taskCount: Int
    var pendingTaskIDs: [String]
    var failedTaskIDs: [String]
    var completedTaskIDs: [String]
    var taskLines: [String]
    var createdAt: Date

    init(
        manifestPath: String,
        baseDirectory: String,
        packageDirectory: String?,
        widgetPreviewPath: String?,
        gapReportPath: String?,
        importedFileCount: Int,
        pendingRemoteTaskCount: Int,
        failedManifestTaskCount: Int,
        skippedMissingCount: Int,
        tasks: [AgentMediaTask],
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.manifestPath = manifestPath
        self.baseDirectory = baseDirectory
        self.packageDirectory = Self.clean(packageDirectory)
        self.widgetPreviewPath = Self.clean(widgetPreviewPath)
        self.gapReportPath = Self.clean(gapReportPath)
        self.importedFileCount = importedFileCount
        self.pendingRemoteTaskCount = pendingRemoteTaskCount
        self.failedManifestTaskCount = failedManifestTaskCount
        self.skippedMissingCount = skippedMissingCount
        self.taskCount = tasks.count
        self.pendingTaskIDs = tasks.filter(\.isActive).map(\.displayHandle)
        self.failedTaskIDs = tasks.filter(\.needsAttention).map(\.displayHandle)
        self.completedTaskIDs = tasks.filter { $0.status == .succeeded }.map(\.displayHandle)
        self.taskLines = tasks.prefix(20).map(Self.taskSummaryLine)
        self.createdAt = createdAt
    }

    var systemPromptBlock: String {
        var lines = [
            "=== Latest Media Import ===",
            "<latest-media-import>",
            "manifest_path: \(manifestPath)",
            "base_directory: \(baseDirectory)",
            "imported_file_count: \(importedFileCount)",
            "pending_remote_task_count: \(pendingRemoteTaskCount)",
            "failed_manifest_task_count: \(failedManifestTaskCount)",
            "skipped_missing_count: \(skippedMissingCount)",
            "task_count: \(taskCount)"
        ]
        Self.appendCleanLine("package_directory", packageDirectory, to: &lines)
        Self.appendCleanLine("widget_preview_path", widgetPreviewPath, to: &lines)
        Self.appendCleanLine("production_gap_report_path", gapReportPath, to: &lines)
        Self.appendList("pending_task_ids", pendingTaskIDs, to: &lines)
        Self.appendList("failed_task_ids", failedTaskIDs, to: &lines)
        Self.appendList("completed_task_ids", completedTaskIDs, to: &lines)
        if !taskLines.isEmpty {
            lines.append("imported_tasks:")
            lines.append(contentsOf: taskLines)
        }
        lines.append("follow_up: if pending_task_ids is non-empty, open or refresh the media task side panel before continuing; if completed_task_ids contains image outputs, continue through candidate selection, primary-image selection, mask edit, upscale, or image-to-video; if failed_task_ids is non-empty, inspect status_message and use retry or failed-only Ruby rerun guidance.")
        lines.append("</latest-media-import>")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func taskSummaryLine(_ task: AgentMediaTask) -> String {
        var parts = [
            "- \(task.displayHandle)",
            "status=\(task.status.rawValue)",
            "provider=\(task.provider.rawValue)",
            "kind=\(task.kind.rawValue)",
            "title=\(task.title)"
        ]
        appendCleanPart("project_id", task.projectID ?? task.projectPath, to: &parts)
        appendCleanPart("episode_id", task.episodeID, to: &parts)
        appendCleanPart("shot_id", task.shotID, to: &parts)
        appendCleanPart("asset_kind", task.assetKind, to: &parts)
        appendCleanPart("asset_id", task.assetID, to: &parts)
        appendCleanPart("review_item_id", task.reviewItemID, to: &parts)
        appendCleanPart("remote_task_id", task.remoteTaskID, to: &parts)
        appendCleanPart("status_url", task.statusURL, to: &parts)
        if !task.artifacts.isEmpty {
            parts.append("artifact_count=\(task.artifacts.count)")
        }
        return parts.joined(separator: " · ")
    }

    nonisolated private static func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = clean(value) else { return }
        lines.append("\(key): \(value)")
    }

    nonisolated private static func appendList(_ key: String, _ values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(key): \(values.joined(separator: ", "))")
    }

    nonisolated private static func appendCleanPart(_ key: String, _ value: String?, to parts: inout [String]) {
        guard let value = clean(value) else { return }
        parts.append("\(key)=\(value)")
    }

    nonisolated private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
extension AppState {
    func recordAgentMediaImport(
        manifestPath: String,
        baseDirectory: String,
        packageDirectory: String?,
        widgetPreviewPath: String?,
        gapReportPath: String?,
        importedFileCount: Int,
        pendingRemoteTaskCount: Int,
        failedManifestTaskCount: Int,
        skippedMissingCount: Int,
        tasks: [AgentMediaTask]
    ) {
        guard !tasks.isEmpty else { return }
        activeRuntime?.latestMediaImport = AgentMediaImportContext(
            manifestPath: manifestPath,
            baseDirectory: baseDirectory,
            packageDirectory: packageDirectory,
            widgetPreviewPath: widgetPreviewPath,
            gapReportPath: gapReportPath,
            importedFileCount: importedFileCount,
            pendingRemoteTaskCount: pendingRemoteTaskCount,
            failedManifestTaskCount: failedManifestTaskCount,
            skippedMissingCount: skippedMissingCount,
            tasks: tasks
        )
    }
}
