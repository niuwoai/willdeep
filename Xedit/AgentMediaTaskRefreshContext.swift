//
//  AgentMediaTaskRefreshContext.swift
//  WillDeep
//
//  Runtime context for the most recent manual media-task refresh batch.
//

import Foundation

struct AgentMediaTaskRefreshContext: Equatable, Identifiable {
    let id: UUID
    var reason: String
    var scopeLabel: String
    var refreshedTaskCount: Int
    var activeCount: Int
    var failedCount: Int
    var completedCount: Int
    var taskLines: [String]
    var createdAt: Date

    init(reason: String, scopeLabel: String, tasks: [AgentMediaTask], createdAt: Date = Date()) {
        self.id = UUID()
        self.reason = reason
        self.scopeLabel = scopeLabel
        self.refreshedTaskCount = tasks.count
        self.activeCount = tasks.filter(\.isActive).count
        self.failedCount = tasks.filter(\.needsAttention).count
        self.completedCount = tasks.filter { $0.status == .succeeded }.count
        self.taskLines = tasks.prefix(20).map { task in
            var parts = [
                "- \(task.displayHandle)",
                "status=\(task.status.rawValue)",
                "provider=\(task.provider.rawValue)",
                "kind=\(task.kind.rawValue)",
                "title=\(task.title)"
            ]
            if let remoteTaskID = Self.clean(task.remoteTaskID) {
                parts.append("remote_task_id=\(remoteTaskID)")
            }
            if let statusURL = Self.clean(task.statusURL) {
                parts.append("status_url=\(statusURL)")
            }
            if !task.artifacts.isEmpty {
                parts.append("artifact_count=\(task.artifacts.count)")
            }
            return parts.joined(separator: " · ")
        }
        self.createdAt = createdAt
    }

    var systemPromptBlock: String {
        var lines = [
            "=== Latest Media Task Refresh ===",
            "<latest-media-task-refresh>",
            "reason: \(reason)",
            "scope_label: \(scopeLabel)",
            "refreshed_task_count: \(refreshedTaskCount)",
            "active_count: \(activeCount)",
            "failed_count: \(failedCount)",
            "completed_count: \(completedCount)"
        ]
        if !taskLines.isEmpty {
            lines.append("refreshed_tasks:")
            lines.append(contentsOf: taskLines)
        }
        lines.append("follow_up: use list_media_tasks or short_drama_open_media_tasks to inspect the same scope; for completed images/videos, continue through candidate selection, image edit, upscale, video generation, storyboard review, or production-package import as appropriate.")
        lines.append("</latest-media-task-refresh>")
        return lines.joined(separator: "\n")
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
extension AppState {
    func recordAgentMediaTaskRefresh(reason: String, scopeLabel: String, tasks: [AgentMediaTask], runtime: AgentRuntime? = nil) {
        guard !tasks.isEmpty else { return }
        (runtime ?? activeRuntime)?.latestMediaTaskRefresh = AgentMediaTaskRefreshContext(
            reason: reason,
            scopeLabel: scopeLabel,
            tasks: tasks
        )
    }
}
