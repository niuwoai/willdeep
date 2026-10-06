//
//  AgentToolPacks.swift
//  WillDeep
//
//  A compact, stable index over the native tool registry. The model always
//  sees the core tool surface plus `load_tool_pack`; optional schemas are
//  appended once per conversation and never removed or reordered. This pays
//  at most one prompt-cache invalidation for each newly activated pack while
//  keeping the ordinary request prefix much smaller than the full registry.
//

import Foundation

nonisolated enum AgentToolPackID: String, CaseIterable, Codable, Hashable, Sendable {
    case terminal
    case sessionAutomation = "session_automation"
    case knowledge
    case integrations
    case browserWeb = "browser_web"
    case computerUse = "computer_use"
    case media
    case plugins
    case shortDrama = "short_drama"
}

nonisolated struct AgentToolPack: Equatable, Sendable {
    let id: AgentToolPackID
    let title: String
    let summary: String
}

enum AgentToolPackCatalog {
    static let loaderToolName = "load_tool_pack"

    /// These tools cover the normal coding loop and the two existing lazy
    /// directories (Skills and jobs). Keeping them stable avoids an extra
    /// discovery round for almost every repository task.
    static let coreToolNames: Set<String> = [
        loaderToolName,
        AgentContextReadTool.name,
        "search_files", "grep_files", "read_file", AgentBundledRules.readerToolName,
        "list_directory", "git_status",
        "run_command", "create_file", "write_file", "edit_file", "apply_patch",
        "list_queued_tasks", "list_jobs", "get_job_output", "kill_job",
        AgentMonitorTool.name, "send_agent_message", "stop_agent",
        "list_skills", "read_skill", "activate_expert", "spawn_agent", "ask_user",
        "update_plan"
    ]

    static let packs: [AgentToolPack] = [
        AgentToolPack(
            id: .terminal,
            title: "Visible terminal",
            summary: "Inspect and operate the user-visible terminal tabs and saved terminal shortcuts."
        ),
        AgentToolPack(
            id: .sessionAutomation,
            title: "Sessions and automation",
            summary: "List projects and their sessions, search or rename sessions, preview and batch archive/delete sessions, change workspace, run workflows, and manage scheduled tasks."
        ),
        AgentToolPack(
            id: .knowledge,
            title: "Memory and user skills",
            summary: "Read/write memory and create, update, or remove user-authored Skills."
        ),
        AgentToolPack(
            id: .integrations,
            title: "Integrations and coding agents",
            summary: "Discover/call MCP or Lark integrations and delegate to installed coding-agent CLIs."
        ),
        AgentToolPack(
            id: .browserWeb,
            title: "Web and browsers",
            summary: "Search/fetch the public web and inspect or operate Chrome and WillDeep's embedded browser."
        ),
        AgentToolPack(
            id: .computerUse,
            title: "Computer Use",
            summary: "Inspect and operate native macOS applications through accessibility and screenshots."
        ),
        AgentToolPack(
            id: .media,
            title: "Media and visual QA",
            summary: "Generate, edit, upscale, import, track, inspect, and present images or videos."
        ),
        AgentToolPack(
            id: .plugins,
            title: "Plugin authoring",
            summary: "Create, edit, and inspect a WillDeep plugin draft."
        ),
        AgentToolPack(
            id: .shortDrama,
            title: "Short-drama production",
            summary: "Manage short-drama projects, storyboards, shots, review items, media, and exports."
        )
    ]

    /// 暂时卸下的工具包：不进模型的工具表、不进 `load_tool_pack` 的目录，专家激活也不再自动带上；
    /// 模型按名字直接调用时当未知工具处理（`AgentToolNameAliases.isDispatchable`）。
    /// 宿主页面里的按钮与小部件动作不经模型，仍走原来的分发，照常可用。
    ///
    /// 短剧（1.409.0-rc7）：短剧生产改由 willdeep-video-studio 插件的 MCP 工具承担
    /// （`mcp__video_studio__*`）。两套同时挂着时模型会挑宿主这套旧工具，写进另一份数据。
    static let unmountedPacks: Set<AgentToolPackID> = [.shortDrama]

    static var mountedPacks: [AgentToolPack] {
        packs.filter { !unmountedPacks.contains($0.id) }
    }

    static func isUnmounted(toolName: String) -> Bool {
        guard let packID = packID(for: toolName) else { return false }
        return unmountedPacks.contains(packID)
    }

    /// 模型调用了卸下的工具时给它的指路。
    static func unmountedToolMessage(for toolName: String) -> String? {
        guard let packID = packID(for: toolName), unmountedPacks.contains(packID) else { return nil }
        switch packID {
        case .shortDrama:
            return "The host's native short-drama tools are unmounted. Nothing was executed. Drive short-drama production through the WillDeep video-studio plugin's MCP tools (names start with `mcp__video_studio__`, e.g. `mcp__video_studio__drama_get`); call `list_mcp_tools` to see them if they are not in this session's tool list."
        default:
            return "The `\(packID.rawValue)` tool pack is unmounted in this build. Nothing was executed."
        }
    }

    static var loaderDescriptor: AgentToolDescriptor {
        let index = mountedPacks.map { "`\($0.id.rawValue)` — \($0.summary)" }.joined(separator: " ")
        return AgentToolDescriptor(
            name: loaderToolName,
            description: "Load one or more optional native-tool categories for this conversation. Use this compact index when the required tool is not already available. Loaded packs are session-sticky: schemas are appended in a deterministic order and never unloaded, preserving prompt-cache reuse after the one-time expansion. Categories: \(index)",
            risk: .read,
            parameters: [
                AgentToolParameter(
                    name: "pack_ids",
                    type: .stringArray,
                    description: "One or more category ids from this tool's index. Load related categories together when the task clearly needs them, avoiding repeated cache-prefix changes.",
                    required: true
                )
            ]
        )
    }

    static func requestedPackIDs(
        from arguments: [String: AgentJSONValue]
    ) throws -> [AgentToolPackID] {
        guard let rawIDs = arguments["pack_ids"]?.stringArrayValue(), !rawIDs.isEmpty else {
            throw AgentToolError.invalidArgument("load_tool_pack requires a non-empty pack_ids array")
        }
        var result: [AgentToolPackID] = []
        var seen = Set<AgentToolPackID>()
        for rawID in rawIDs {
            guard let id = AgentToolPackID(rawValue: rawID), seen.insert(id).inserted else {
                if AgentToolPackID(rawValue: rawID) == nil {
                    let allowed = mountedPacks.map(\.id.rawValue).joined(separator: ", ")
                    throw AgentToolError.invalidArgument("Unknown tool pack `\(rawID)`. Allowed: \(allowed)")
                }
                continue
            }
            if unmountedPacks.contains(id) {
                let hint = id == .shortDrama ? " Use the video-studio plugin's MCP tools (`mcp__video_studio__*`) instead." : ""
                throw AgentToolError.invalidArgument("Tool pack `\(rawID)` is unmounted.\(hint)")
            }
            result.append(id)
        }
        return result
    }

    static func activationResult(
        requested: [AgentToolPackID],
        loaded: Set<AgentToolPackID>
    ) -> AgentToolResult {
        let requestedNames = requested.map(\.rawValue).joined(separator: ", ")
        let loadedNames = AgentToolPackID.allCases
            .filter { loaded.contains($0) }
            .map(\.rawValue)
            .joined(separator: ", ")
        var activatedToolNames: [String] = []
        for packID in requested {
            activatedToolNames.append(contentsOf: toolNames(in: packID))
        }
        let toolNames = activatedToolNames.joined(separator: ", ")
        return AgentToolResult(
            summary: "Loaded native tool pack: \(requestedNames)",
            payload: "Loaded: \(requestedNames). Active optional packs: \(loadedNames). The following detailed tool schemas are available on the next model round in stable registry order: \(toolNames)"
        )
    }

    static func effectiveLoadedPacks(
        explicit: Set<AgentToolPackID>,
        activeExperts: Set<AgentExpert>,
        delegationPolicy: AgentDelegationPolicy
    ) -> Set<AgentToolPackID> {
        var result = explicit
        if activeExperts.contains(.shortDrama) {
            result.insert(.shortDrama)
            result.insert(.media)
        }
        result.subtract(unmountedPacks)
        if activeExperts.contains(.browserOps) || activeExperts.contains(.webCoding) {
            result.insert(.browserWeb)
        }
        if delegationPolicy == .required {
            result.insert(.integrations)
        }
        return result
    }

    static func toolNames(in requestedPackID: AgentToolPackID) -> [String] {
        AgentToolRegistry.all
            .map(\.name)
            .filter { packID(for: $0) == requestedPackID }
    }

    static func packID(for toolName: String) -> AgentToolPackID? {
        if coreToolNames.contains(toolName) {
            return nil
        }
        if toolName.hasPrefix("terminal_") {
            return .terminal
        }
        if toolName.hasPrefix("short_drama_") {
            return .shortDrama
        }
        if toolName.hasPrefix("computer_use_") {
            return .computerUse
        }
        if toolName.hasPrefix("chrome_") || toolName.hasPrefix("embedded_browser_")
            || toolName == "web_search" || toolName == "web_fetch" {
            return .browserWeb
        }
        if mediaToolNames.contains(toolName) {
            return .media
        }
        if pluginToolNames.contains(toolName) {
            return .plugins
        }
        if knowledgeToolNames.contains(toolName) {
            return .knowledge
        }
        if integrationToolNames.contains(toolName) {
            return .integrations
        }
        if sessionAutomationToolNames.contains(toolName) {
            return .sessionAutomation
        }
        return nil
    }

    private static let pluginToolNames: Set<String> = [
        "create_plugin_draft", "write_plugin_draft_file", "inspect_plugin_draft"
    ]

    private static let knowledgeToolNames: Set<String> = [
        "add_memory", "read_memory", "create_user_skill", "create_user_skills",
        "update_user_skill", "delete_user_skill"
    ]

    private static let integrationToolNames: Set<String> = [
        "search_mcp_servers", "suggest_mcp_server", "configure_mcp_server",
        "list_mcp_servers", "list_mcp_tools", "call_mcp_tool", "lark_cli",
        "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli", "opencode_cli"
    ]

    private static let sessionAutomationToolNames: Set<String> = [
        "list_projects", "list_project_sessions", "manage_sessions",
        "list_workspace_sessions", "send_session_message", "search_sessions", "suggest_session_title",
        "rename_session", "change_workspace", "run_workflow", "schedule_task",
        "declare_environment_trust", "complete_scheduled_task"
    ]

    private static let mediaToolNames: Set<String> = [
        "create_media_task", "open_image_editor", "edit_image_with_mask", "upscale_image",
        "show_image_choice_widget", "generate_video_from_image", "import_media_directory",
        "import_media_manifest", "update_media_task", "list_media_tasks",
        "replicate_create_prediction", "replicate_poll_prediction", "replicate_cancel_prediction",
        "some_im_create_media_task", "some_im_poll_media_task", "some_im_cancel_media_task",
        "generate_image", "edit_generated_image", "visual_qa_screenshot",
        "design_to_code_acceptance", "capture_screenshot", "show_widget"
    ]
}
