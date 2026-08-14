//
//  AgentToolsWidgets.swift
//  WillDeep
//
//  AgentToolRunner 的网页组件与工作流工具：show_widget 的 HTML 来源解析、
//  上下文行拼装，以及 run_workflow。自 AgentTools.swift 拆出，行为不变。
//

import Foundation

extension AgentToolRunner {
    // MARK: show_widget (1.84.0-rc1)

    // Widget HTML path boundary moved to AgentWidgetPathResolver.swift:
    // widgetTemporaryDirectories()
    // FileManager.default.temporaryDirectory
    // URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    // shortDramaExportsDirectory
    // WillDeep/short-drama/exports
    // isWidgetHTMLURLAllowed

    /// `show_widget` 工具 handler。把模型生成或本地脚本写出的 HTML 推到
    /// `AgentWidgetRegistry`，由 AppStateAgentLoop 在下一轮 turn 顶部
    /// drain 出来 append `.widget` 消息到 transcript。返回值只是 ack
    /// 字符串（"widget queued"），所以 LLM 不会看到 raw HTML 占用上下文。
    /// `html_path` 只允许读取当前 workspace、系统临时目录或 WillDeep
    /// 短剧导出目录内的 UTF-8 文件，供 Ruby skill 或第三方 API 脚本把
    /// 生成的网页直接嵌入右侧「网页组件」。
    static func showWidget(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let title = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw AgentToolError.missingArgument("title")
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "show_widget unavailable",
                payload: "show_widget is only available in conversational agent runtimes (no runtime id in this call context)."
            )
        }
        let sourceURL = try widgetHTMLSourceURL(arguments: arguments, context: context)
        let html = try widgetHTML(arguments: arguments, context: context, sourceURL: sourceURL)
        let contextLines = try widgetContextLines(arguments: arguments)
        let bytes = html.utf8.count
        if bytes > 1_048_576 {
            return AgentToolResult(
                summary: "Refused (>1 MB)",
                payload: "show_widget refused: html payload is \(bytes) bytes (>1 MB). Trim it down or split into multiple widgets."
            )
        }
        var widget = AgentWidget(title: title, html: html, contextLines: contextLines)
        widget.sourceBaseURL = sourceURL?.deletingLastPathComponent()
        await MainActor.run {
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
        }
        let kbLabel = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
        return AgentToolResult(
            summary: "Queued widget: \(title)",
            payload: """
            widget queued: "\(title)" (\(kbLabel)) — opened the Widget side panel and will appear in the transcript at the start of the next turn.
            <widget-follow-up>
            action: show_widget_follow_up
            widget_id: \(widget.id.uuidString)
            title: \(title)
            side_panel: widget
            source: \(arguments["html_path"]?.stringValue() == nil ? "inline_html" : "html_path")
            \(widget.contextBlock)
            </widget-follow-up>
            """
        )
    }

    private static func widgetContextLines(arguments: [String: AgentJSONValue]) throws -> [String] {
        let mappings: [(String, String)] = [
            ("html_path", "html_path"),
            ("source_label", "source_label"),
            ("source_path", "source_path"),
            ("package_directory", "package_directory"),
            ("widget_context", "widget_context"),
            ("recommended_tool", "recommended_tool"),
            ("recommended_arguments", "recommended_arguments"),
            ("project_id", "project_id"),
            ("episode_id", "episode_id"),
            ("shot_id", "shot_id"),
            ("asset_kind", "asset_kind"),
            ("asset_id", "asset_id"),
            ("review_item_id", "review_item_id")
        ]
        var lines: [String] = []
        for (argumentName, lineName) in mappings {
            guard let value = arguments[argumentName]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            guard value.utf8.count <= 2_000 else {
                throw AgentToolError.invalidArgument("\(argumentName) must be 2 KB or smaller.")
            }
            lines.append("\(lineName): \(value)")
        }
        lines.append(contentsOf: widgetShortDramaHandoffLines(arguments: arguments))
        if lines.joined(separator: "\n").utf8.count > 8_000 {
            throw AgentToolError.invalidArgument("show_widget context metadata must be 8 KB or smaller.")
        }
        return lines
    }

    private static func widgetShortDramaHandoffLines(arguments: [String: AgentJSONValue]) -> [String] {
        let projectID = widgetContextValue(arguments, "project_id")
        let episodeID = widgetContextValue(arguments, "episode_id")
        let shotID = widgetContextValue(arguments, "shot_id")
        let assetKind = widgetContextValue(arguments, "asset_kind")
        let assetID = widgetContextValue(arguments, "asset_id")
        let reviewItemID = widgetContextValue(arguments, "review_item_id")
        guard projectID != nil else { return [] }

        var lines: [String] = []
        if let projectID, let shotID {
            var pairs = ["project_id=\(projectID)"]
            if let episodeID { pairs.append("episode_id=\(episodeID)") }
            pairs.append("shot_id=\(shotID)")
            var scopeArguments = pairs.joined(separator: ", ")
            if let reviewItemID {
                scopeArguments += ", scope=review_item, review_item_id=\(reviewItemID)"
            } else {
                scopeArguments += ", scope=shot"
            }
            lines.append("open_widget_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_widget_tasks_arguments: \(scopeArguments)")
            lines.append("refresh_widget_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_widget_tasks_arguments: \(scopeArguments)")
            if let reviewItemID {
                let resolveArguments = (pairs + ["item_id=\(reviewItemID)"]).joined(separator: ", ")
                lines.append("resolve_widget_review_tool: short_drama_resolve_review_item")
                lines.append("resolve_widget_review_arguments: \(resolveArguments)")
            }
            return lines
        }

        if let projectID, let assetKind, let assetID {
            let arguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
            lines.append("open_widget_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_widget_tasks_arguments: \(arguments)")
            lines.append("refresh_widget_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_widget_tasks_arguments: \(arguments)")
            return lines
        }

        if let projectID {
            var pairs = ["project_id=\(projectID)"]
            if let episodeID { pairs.append("episode_id=\(episodeID)") }
            pairs.append("scope=\(episodeID == nil ? "project" : "episode")")
            let arguments = pairs.joined(separator: ", ")
            lines.append("open_widget_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_widget_tasks_arguments: \(arguments)")
            lines.append("refresh_widget_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_widget_tasks_arguments: \(arguments)")
        }
        return lines
    }

    private static func widgetContextValue(_ arguments: [String: AgentJSONValue], _ key: String) -> String? {
        guard let value = arguments[key]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func widgetHTML(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        sourceURL: URL? = nil
    ) throws -> String {
        if let html = arguments["html"]?.stringValue(), !html.isEmpty {
            return html
        }
        guard let url = sourceURL else {
            throw AgentToolError.missingArgument("html")
        }
        let rawPath = arguments["html_path"]?.stringValue() ?? url.path
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw AgentToolError.notFound(rawPath)
        }
        guard !isDirectory.boolValue else {
            throw AgentToolError.notRegular(rawPath)
        }
        guard ["html", "htm", "svg"].contains(url.pathExtension.lowercased()) else {
            throw AgentToolError.invalidArgument("html_path must point to a .html, .htm, or .svg file.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else {
            return String(decoding: data.prefix(1_048_577), as: UTF8.self)
        }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw AgentToolError.invalidArgument("html_path must contain non-empty UTF-8 HTML/SVG.")
        }
        return html
    }

    private static func widgetHTMLSourceURL(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> URL? {
        guard let rawPath = arguments["html_path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return try resolveWidgetHTMLURL(rawPath, context: context)
    }

    private static func resolveWidgetHTMLURL(_ rawPath: String, context: AgentToolContext) throws -> URL {
        let trimmed = AgentWidgetPathResolver.normalize(rawPath)
        let workspaceRoot = context.rootDirectory?.standardizedFileURL
        if !(trimmed as NSString).isAbsolutePath, workspaceRoot == nil {
            throw AgentToolError.noWorkspace
        }
        if let url = AgentWidgetPathResolver.resolve(trimmed, workspaceRoot: workspaceRoot) {
            return url
        }
        throw AgentToolError.pathOutsideWorkspace(rawPath)
    }

    // MARK: run_workflow (1.84.0-rc2)

    /// Agent 自己派 workflow（无需用户 slash 命令）。handler 通过
    /// `AppState.startWorkflow` 走和 composer slash 同款入口 ——
    /// AppState 创建 .workflowReport message + 起后台 Task 跑
    /// WorkflowEngine。本工具返回简短 ack；后续 turn 顶部 LLM 自然能在
    /// transcript 里读到 workflow card 的 summary。
    static func runWorkflow(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let name = arguments["workflow_name"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw AgentToolError.missingArgument("workflow_name")
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "run_workflow unavailable",
                payload: "run_workflow is only available in conversational agent runtimes."
            )
        }
        let normalizedName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard let workflow = await MainActor.run(body: {
            WorkflowRegistry.find(name: normalizedName)
                ?? WorkflowRegistry.find(slashCommand: "/\(normalizedName)")
        }) else {
            let known = await MainActor.run { WorkflowRegistry.all.map { $0.name }.joined(separator: ", ") }
            return AgentToolResult(
                summary: "Unknown workflow",
                payload: "Unknown workflow `\(name)`. Available: \(known)."
            )
        }
        let args = arguments["args"]?.stringValue() ?? ""
        let result = await MainActor.run { () -> WorkflowStartResult in
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return .rejected(reason: "No AppState owns runtime \(runtimeID).")
            }
            return appState.startWorkflow(
                slashCommand: workflow.slashCommand,
                args: args,
                runtimeID: runtimeID,
                notifyAgentOnCompletion: true
            )
        }
        switch result {
        case .started(let reportID):
            let argsHint = args.isEmpty ? "" : " with args: \(args)"
            return AgentToolResult(
                summary: "Started \(workflow.displayTitle)",
                payload: "workflow `\(workflow.name)` queued\(argsHint) as report `\(reportID.uuidString)`. The card will show live progress. When it finishes, the host will deliver the report back in a workflow-completion notice so you can continue the user's task."
            )
        case .rejected(let reason):
            return AgentToolResult(
                summary: "Failed to start \(workflow.displayTitle)",
                payload: "Could not start workflow `\(workflow.name)`: \(reason)"
            )
        case .notRecognized:
            return AgentToolResult(
                summary: "Failed to start \(workflow.displayTitle)",
                payload: "Workflow `\(workflow.name)` disappeared from the registry before dispatch."
            )
        }
    }
}
