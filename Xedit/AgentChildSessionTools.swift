//
//  AgentChildSessionTools.swift
//  WillDeep
//
//  Host-bound task delegation to a complete, independent conversation.
//
import Foundation

nonisolated enum AgentChildSessionTool {
    static let startName = "start_session"
    static let maximumBriefCharacters = 8_000
    static let maximumTitleCharacters = 120
    static let maximumActiveChildren = 4
    static let maximumResultCharacters = 2_000

    static let descriptor = AgentToolDescriptor(
        name: startName,
        description: "Start an independent WillDeep conversation for a bounded READ-ONLY task in the current local workspace. It has fresh history and its own model turn and chat. When called from a child, it creates a sibling under the same original parent, never a grandchild; sibling results go to that parent. Children cannot write files, run commands, use external integrations, or spawn workers. The host reports this assignment's outcome to its parent after it finishes. Use it only for work that benefits from a separate conversation; it does not inherit this chat history. Do not use it for a coding or deployment task until isolated writable worktrees are supported.",
        risk: .write,
        parameters: [
            AgentToolParameter(name: "title", type: .string, description: "Short title for the independent conversation (at most 120 characters).", required: true),
            AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task brief with goal, known facts, source references and expected report (at most 8000 characters).", required: true)
        ]
    )

    /// No permission-mode change can widen this host-enforced ceiling. In
    /// particular a tool marked `.read` by a plugin is not automatically safe.
    static let childAllowedToolNames: Set<String> = [
        AgentContextReadTool.name, AgentBundledRules.readerToolName,
        "search_files", "grep_files", "read_file", "list_directory", "git_status",
        "list_skills", "read_skill", "list_workspace_sessions", "update_plan", "ask_user",
        AgentToolPackCatalog.loaderToolName, startName
    ]

    static func permits(_ toolName: String) -> Bool {
        childAllowedToolNames.contains(toolName)
    }
}
