//
//  AgentSessionTools.swift
//  WillDeep
//
//  User-approved tools that mutate the current conversation itself.
//

import Foundation

enum AgentSessionTools {
    private static let maximumTitleCharacters = 120

    static func listWorkspaceSessions(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let provider = context.workspaceSessionsSnapshotProvider else {
            return AgentToolResult(
                summary: "no workspace sessions",
                payload: "Workspace session snapshot is not available in this context."
            )
        }
        let includeArchived = arguments["include_archived"]?.boolValue() ?? false
        let rawLimit = arguments["limit"]?.intValue() ?? 20
        let limit = max(1, min(rawLimit, 100))
        let snapshots = await MainActor.run { provider() }
            .filter { includeArchived || !$0.isArchived }
            .sorted {
                if $0.isActive != $1.isActive { return $0.isActive && !$1.isActive }
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.lastActivityAt > $1.lastActivityAt
            }
            .prefix(limit)

        guard !snapshots.isEmpty else {
            return AgentToolResult(
                summary: "no sessions",
                payload: includeArchived
                    ? "No sessions found for the current workspace."
                    : "No non-archived sessions found for the current workspace."
            )
        }

        var lines: [String] = [
            "workspace_sessions: \(snapshots.count)",
            "include_archived: \(includeArchived)"
        ]
        for (offset, session) in snapshots.enumerated() {
            var flags: [String] = []
            if session.isActive { flags.append("active") }
            if session.isPinned { flags.append("pinned") }
            if session.isArchived { flags.append("archived") }
            if session.isResponding { flags.append("responding") }
            if session.isAwaitingProviderSlot { flags.append("provider-queued") }
            if session.queuedMessageCount > 0 { flags.append("queued_messages=\(session.queuedMessageCount)") }
            if session.titleIsUserSet { flags.append("title_locked") }
            let flagText = flags.isEmpty ? "normal" : flags.joined(separator: ",")
            lines.append("- #\(offset + 1) \(session.title) [\(flagText)] id=\(session.id.uuidString) updated=\(isoString(session.updatedAt)) mode=\(session.interactionMode.rawValue)")
        }

        let jsonObject: [String: Any] = [
            "sessions": snapshots.map { session in
                [
                    "id": session.id.uuidString,
                    "title": session.title,
                    "workspace_root_path": session.workspaceRootPath ?? NSNull(),
                    "workspace_display_name": session.workspaceDisplayName,
                    "is_active": session.isActive,
                    "is_pinned": session.isPinned,
                    "is_archived": session.isArchived,
                    "is_responding": session.isResponding,
                    "is_awaiting_provider_slot": session.isAwaitingProviderSlot,
                    "queued_message_count": session.queuedMessageCount,
                    "updated_at": isoString(session.updatedAt),
                    "last_activity_at": isoString(session.lastActivityAt),
                    "interaction_mode": session.interactionMode.rawValue,
                    "approval_mode": session.approvalMode.rawValue,
                    "execution_agent": session.executionAgent.rawValue,
                    "title_is_user_set": session.titleIsUserSet
                ] as [String: Any]
            }
        ]
        if let json = jsonPayload(jsonObject) {
            lines.append("json:")
            lines.append(json)
        }

        return AgentToolResult(
            summary: "\(snapshots.count) workspace session\(snapshots.count == 1 ? "" : "s")",
            payload: lines.joined(separator: "\n")
        )
    }

    static func suggestSessionTitle(
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let provider = context.sessionTitleSuggestionProvider else {
            return AgentToolResult(
                summary: "no title suggestion",
                payload: "Session title suggestion is not available in this context."
            )
        }
        let snapshot = await provider()
        let title = snapshot.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let jsonObject: [String: Any] = [
            "current_title": snapshot.currentTitle,
            "suggested_title": title.isEmpty ? NSNull() : title,
            "model": snapshot.modelID ?? NSNull(),
            "rename_recommended": !title.isEmpty && title != snapshot.currentTitle
        ]
        return AgentToolResult(
            summary: title.isEmpty ? "no title suggestion" : "suggested title: \(title)",
            payload: jsonPayload(jsonObject) ?? "{}"
        )
    }

    static func renameSession(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawTitle = arguments["title"]?.stringValue() else {
            throw AgentToolError.missingArgument("title")
        }
        let title = rawTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !title.isEmpty else {
            throw AgentToolError.invalidArgument("title must not be empty")
        }
        guard title.count <= maximumTitleCharacters else {
            throw AgentToolError.invalidArgument("title must be at most \(maximumTitleCharacters) characters")
        }
        guard let sink = context.sessionRenameSink else {
            throw AgentToolError.invalidArgument("rename_session is only available in an interactive WillDeep session")
        }

        let appliedTitle = try sink(title)
        return AgentToolResult(
            summary: "Renamed session",
            payload: jsonPayload([
                "status": "renamed",
                "title": appliedTitle,
            ])
        )
    }

    static func changeWorkspace(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = arguments["path"]?.stringValue() else {
            throw AgentToolError.missingArgument("path")
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw AgentToolError.invalidArgument("path must not be empty")
        }
        guard path.hasPrefix("/") else {
            throw AgentToolError.invalidArgument("path must be an absolute local directory path")
        }
        guard let sink = context.workspaceChangeSink else {
            throw AgentToolError.invalidArgument("change_workspace is only available in an interactive WillDeep session")
        }

        let appliedPath = try sink(path)
        return AgentToolResult(
            summary: "Changed workspace",
            payload: jsonPayload([
                "status": "changed",
                "workspace": appliedPath,
                "next_step": "Stop this turn. Continue with workspace tools only after the user's next message.",
            ])
        )
    }

    private static func jsonPayload(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func jsonPayload(_ object: [String: String]) -> String {
        jsonPayload(object as [String: Any]) ?? "{}"
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
