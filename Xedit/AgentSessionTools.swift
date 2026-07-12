//
//  AgentSessionTools.swift
//  WillDeep
//
//  User-approved tools that mutate the current conversation itself.
//

import Foundation

enum AgentSessionTools {
    private static let maximumTitleCharacters = 120

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

    private static func jsonPayload(_ object: [String: String]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }
}
