//
//  AgentChatToolSummaryFormatter.swift
//  WillDeep
//
//  Human-readable summaries for streamed tool calls in the TextKit Agent
//  chat history. Kept separate from AgentChatHistoryFormatter.swift so the
//  renderer can focus on attributed-string layout and chrome.
//

import Foundation

enum AgentChatToolSummaryFormatter {
    static func collapsedTitle(for toolCalls: [AgentMessageToolCall]) -> String {
        guard !toolCalls.isEmpty else { return "工具调用" }
        if let text = AgentCollapsedToolActivitySummary.text(for: toolCalls) {
            return text
        }
        return "执行了 \(toolCalls.count) 次工具调用"
    }

    static func toolCallSummary(for toolCalls: [AgentMessageToolCall], argumentLimit: Int = 160) -> String {
        toolCalls
            .map { call in
                let (arguments, isTruncated) = compactArgumentsWithTruncationFlag(for: call, limit: argumentLimit)
                // No args at all -> just the tool name; the old "0 B args"
                // tail was pure noise.
                if arguments.isEmpty {
                    return "tool  \(call.toolName)"
                }
                // Args fit in `argumentLimit` -> no tail. The compact form
                // (e.g. `path: deployment.md`) already shows everything.
                if !isTruncated {
                    return "tool  \(call.toolName)  \(arguments)"
                }
                // Truncated -> tell the user how much was hidden, in human
                // form ("共 1.4 KB · 已折叠"), not in "B" units that look
                // like a typo for Cmd+B.
                return "tool  \(call.toolName)  \(arguments)  · 完整参数 \(byteLabel(call.argumentsJSON.count))"
            }
            .joined(separator: "\n")
    }

    /// Adapter that wraps `compactArguments` and reports whether the
    /// returned string had to drop content to fit. Two truncation
    /// sources: `trimmedInline` slicing a long value with "...", or
    /// `compactArguments` itself picking only the first 2 preferred
    /// keys out of a dict that contains more. We detect the latter by
    /// comparing rendered key-count to dict.count.
    private nonisolated static func compactArgumentsWithTruncationFlag(
        for call: AgentMessageToolCall,
        limit: Int = 160
    ) -> (String, Bool) {
        let rendered = compactArguments(for: call, limit: limit)
        guard !rendered.isEmpty else { return ("", false) }

        if rendered.contains("...") {
            return (rendered, true)
        }

        if let data = call.argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any],
           dict.count > 2 {
            return (rendered, true)
        }

        return (rendered, false)
    }

    private nonisolated static func compactArguments(for call: AgentMessageToolCall, limit: Int = 160) -> String {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              !dict.isEmpty else {
            return trimmedInline(call.argumentsJSON, limit: limit)
        }

        let preferredKeys: [String]
        switch call.toolName {
        case "run_command":
            preferredKeys = ["label", "command", "cwd", "timeout_seconds", "run_in_background"]
        case "terminal_send_command":
            preferredKeys = ["command"]
        case "terminal_send_control":
            preferredKeys = ["control"]
        case "terminal_snapshot":
            preferredKeys = ["max_chars", "include_recent_commands"]
        case "terminal_select_tab":
            preferredKeys = ["terminal_tab_id"]
        case "grep_files":
            preferredKeys = ["pattern", "include", "path"]
        case "search_files":
            preferredKeys = ["query", "path"]
        case "read_file", "list_directory":
            preferredKeys = ["path", "limit", "offset"]
        case "ask_user":
            preferredKeys = ["question", "options"]
        case "read_skill":
            preferredKeys = ["skill", "name", "path"]
        case "list_mcp_tools", "call_mcp_tool":
            preferredKeys = ["server", "tool", "name"]
        case "spawn_agent":
            preferredKeys = ["label", "prompt"]
        case "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli":
            preferredKeys = ["prompt", "permission_mode"]
        case "create_file", "write_file":
            preferredKeys = ["path", "title"]
        case "apply_patch":
            preferredKeys = ["title", "diff"]
        case "edit_file":
            preferredKeys = ["path", "title"]
        default:
            preferredKeys = ["command", "path", "pattern", "query", "question", "url", "name"]
        }

        var parts: [String] = []
        for key in preferredKeys {
            guard let value = dict[key] else { continue }
            let text = compactJSONValue(value)
            guard !text.isEmpty else { continue }
            parts.append("\(key): \(trimmedInline(text, limit: limit))")
            if parts.count >= 2 { break }
        }

        if parts.isEmpty {
            for key in dict.keys.sorted().prefix(2) {
                guard let value = dict[key] else { continue }
                let text = compactJSONValue(value)
                guard !text.isEmpty else { continue }
                parts.append("\(key): \(trimmedInline(text, limit: max(72, limit / 2)))")
            }
        }
        return parts.joined(separator: "  ")
    }

    private nonisolated static func compactJSONValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let rendered = array.prefix(3).map(compactJSONValue).filter { !$0.isEmpty }
            let suffix = array.count > rendered.count ? ", ..." : ""
            return "[" + rendered.joined(separator: ", ") + suffix + "]"
        case let dict as [String: Any]:
            let rendered = dict.keys.sorted().prefix(3).compactMap { key -> String? in
                guard let value = dict[key] else { return nil }
                let text = compactJSONValue(value)
                guard !text.isEmpty else { return nil }
                return "\(key): \(text)"
            }
            let suffix = dict.count > rendered.count ? ", ..." : ""
            return "{" + rendered.joined(separator: ", ") + suffix + "}"
        default:
            return String(describing: value)
        }
    }

    private nonisolated static func byteLabel(_ count: Int) -> String {
        if count < 1_024 {
            return "\(count) B"
        }
        let kb = Double(count) / 1_024.0
        return String(format: "%.1f KB", kb)
    }

    private nonisolated static func trimmedInline(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "..."
    }
}

/// Collapsed tool rows deliberately expose only an aggregate activity label.
/// Paths, prompts, commands, queries, and raw tool identifiers stay hidden
/// until the user expands the row. Both the persisted TextKit history and the
/// live SwiftUI tool group use this formatter so privacy does not depend on
/// which rendering path happens to be active.
enum AgentCollapsedToolActivitySummary {
    struct Item: Equatable {
        let systemImage: String
        let text: String
    }

    private struct InputCall {
        let identity: String
        let toolName: String
        let arguments: [String: Any]
    }

    private struct PathCounter {
        private(set) var paths: Set<String> = []

        mutating func insert(path: String?, fallbackIdentity: String) {
            let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            paths.insert(normalized.isEmpty ? "call:\(fallbackIdentity)" : "path:\(normalized)")
        }

        var count: Int { paths.count }
    }

    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    static func text(for calls: [AgentMessageToolCall]) -> String? {
        text(for: items(for: calls))
    }

    static func items(for calls: [AgentMessageToolCall]) -> [Item] {
        items(for: calls.map { call in
            InputCall(
                identity: call.externalID,
                toolName: call.toolName,
                arguments: argumentsDictionary(from: call.argumentsJSON)
            )
        })
    }

    static func text(for calls: [AgentToolCall]) -> String? {
        text(for: items(for: calls))
    }

    static func items(for calls: [AgentToolCall]) -> [Item] {
        items(for: calls.map { call in
            InputCall(
                identity: call.id.uuidString,
                toolName: call.toolName,
                arguments: call.arguments.mapValues(\.rawAny)
            )
        })
    }

    private static func text(for items: [Item]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map(\.text).joined(separator: " · ")
    }

    private static func items(for calls: [InputCall]) -> [Item] {
        guard !calls.isEmpty else { return [] }

        var createdFiles = PathCounter()
        var editedFiles = PathCounter()
        var readFiles = PathCounter()
        var readImages = PathCounter()
        var listedDirectories = PathCounter()
        var generatedImageCount = 0
        var editedImageCount = 0
        var screenshotCount = 0
        var searchCount = 0
        var gitStatusCount = 0
        var commandCount = 0
        var terminalOperationCount = 0
        var fallbackCallCount = 0

        for call in calls {
            let path = path(in: call.arguments)
            switch call.toolName {
            case "create_file":
                createdFiles.insert(path: path, fallbackIdentity: call.identity)
            case "write_file":
                let overwrite = call.arguments["overwrite"]
                    .map(AgentJSONValue.wrap)
                    .flatMap { $0.boolValue() }
                if overwrite == true {
                    editedFiles.insert(path: path, fallbackIdentity: call.identity)
                } else {
                    createdFiles.insert(path: path, fallbackIdentity: call.identity)
                }
            case "edit_file":
                editedFiles.insert(path: path, fallbackIdentity: call.identity)
            case "read_file":
                if isImagePath(path) {
                    readImages.insert(path: path, fallbackIdentity: call.identity)
                } else {
                    readFiles.insert(path: path, fallbackIdentity: call.identity)
                }
            case "view_image", "read_image", "load_image":
                readImages.insert(path: path, fallbackIdentity: call.identity)
            case "list_directory":
                listedDirectories.insert(path: path, fallbackIdentity: call.identity)
            case "grep_files", "search_files", "glob":
                searchCount += 1
            case "git_status":
                gitStatusCount += 1
            case "run_command":
                commandCount += 1
            case "generate_image":
                generatedImageCount += 1
            case "edit_generated_image", "edit_image_with_mask", "upscale_image":
                editedImageCount += 1
            case "design_to_code_acceptance":
                screenshotCount += 1
            case "visual_qa_screenshot", "capture_screenshot", "embedded_browser_capture_screenshot", "chrome_capture_tab":
                screenshotCount += 1
            case _ where AgentTerminalToolNames.isVisibleTerminalOperation(call.toolName):
                terminalOperationCount += 1
            default:
                fallbackCallCount += 1
            }
        }

        var items: [Item] = []
        appendCount(
            createdFiles.count,
            systemImage: "doc.badge.plus",
            singular: "生成了1个文件",
            plural: "生成了%d个文件",
            to: &items
        )
        appendCount(
            editedFiles.count,
            systemImage: "pencil",
            singular: "修改了1个文件",
            plural: "修改了%d个文件",
            to: &items
        )
        appendCount(
            readImages.count,
            systemImage: "photo.on.rectangle",
            singular: "读取了1张图片",
            plural: "读取了%d张图片",
            to: &items
        )
        appendCount(
            readFiles.count,
            systemImage: "book.pages",
            singular: "已读取1个文件",
            plural: "已读取%d个文件",
            to: &items
        )
        appendCount(
            listedDirectories.count,
            systemImage: "folder",
            singular: "已浏览1个目录",
            plural: "已浏览%d个目录",
            to: &items
        )
        if searchCount > 0 {
            items.append(Item(
                systemImage: "magnifyingglass",
                text: searchCount == 1 ? "已搜索代码" : "已搜索代码\(searchCount)次"
            ))
        }
        if gitStatusCount > 0 {
            items.append(Item(
                systemImage: "arrow.triangle.branch",
                text: gitStatusCount == 1 ? "已查看 Git 状态" : "已查看 Git 状态\(gitStatusCount)次"
            ))
        }
        appendCount(
            commandCount,
            systemImage: "terminal",
            singular: "已运行1条命令",
            plural: "已运行%d条命令",
            to: &items
        )
        appendCount(
            terminalOperationCount,
            systemImage: "terminal",
            singular: "已执行1次终端操作",
            plural: "已执行%d次终端操作",
            to: &items
        )
        appendCount(
            generatedImageCount,
            systemImage: "photo.badge.plus",
            singular: "生成了1张图片",
            plural: "生成了%d张图片",
            to: &items
        )
        appendCount(
            editedImageCount,
            systemImage: "slider.horizontal.3",
            singular: "处理了1张图片",
            plural: "处理了%d张图片",
            to: &items
        )
        appendCount(
            screenshotCount,
            systemImage: "camera",
            singular: "截取了1张图片",
            plural: "截取了%d张图片",
            to: &items
        )

        if fallbackCallCount > 0 {
            let fallback = "执行了\(fallbackCallCount)次工具调用"
            items.append(Item(
                systemImage: "wrench.and.screwdriver",
                text: items.isEmpty ? fallback : "另\(fallback)"
            ))
        }
        return items
    }

    private static func appendCount(
        _ count: Int,
        systemImage: String,
        singular: String,
        plural: String,
        to items: inout [Item]
    ) {
        guard count > 0 else { return }
        items.append(Item(
            systemImage: systemImage,
            text: count == 1 ? singular : String(format: plural, count)
        ))
    }

    private static func argumentsDictionary(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private static func path(in arguments: [String: Any]) -> String? {
        for key in ["path", "image_path", "file_path", "artifact_path"] {
            if let path = arguments[key] as? String, !path.isEmpty {
                return path
            }
        }
        return nil
    }

    private static func isImagePath(_ path: String?) -> Bool {
        guard let path else { return false }
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return imageExtensions.contains(pathExtension)
    }
}
