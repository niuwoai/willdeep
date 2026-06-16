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
        if let text = ToolHistoryActivitySummary(toolCalls: toolCalls).text {
            return text
        }
        if toolCalls.count == 1, let first = toolCalls.first {
            return "已调用 \(readableToolName(first.toolName))"
        }
        return "已调用 \(toolCalls.count) 个工具"
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

    private static func readableToolName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ToolHistoryActivitySummary {
        var readFileCount = 0
        var listedDirectoryCount = 0
        var searchCount = 0
        var gitStatusCount = 0
        var commandCount = 0

        init(toolCalls: [AgentMessageToolCall]) {
            var readFiles = Set<String>()
            var listedDirectories = Set<String>()

            for call in toolCalls {
                let arguments = Self.argumentsDictionary(from: call.argumentsJSON)
                switch call.toolName {
                case "read_file":
                    readFiles.insert(Self.path(in: arguments))
                case "list_directory":
                    listedDirectories.insert(Self.path(in: arguments))
                case "grep_files", "search_files":
                    searchCount += 1
                case "git_status":
                    gitStatusCount += 1
                case "run_command":
                    commandCount += 1
                default:
                    break
                }
            }

            readFileCount = readFiles.count
            listedDirectoryCount = listedDirectories.count
        }

        var text: String? {
            var parts: [String] = []
            if readFileCount > 0 {
                parts.append("已读取 \(readFileCount) 个文件")
            }
            if listedDirectoryCount > 0 {
                parts.append("已浏览 \(listedDirectoryCount) 个目录")
            }
            if searchCount > 0 {
                parts.append(searchCount == 1 ? "已搜索代码" : "已搜索代码 \(searchCount) 次")
            }
            if gitStatusCount > 0 {
                parts.append(gitStatusCount == 1 ? "已查看 Git 状态" : "已查看 Git 状态 \(gitStatusCount) 次")
            }
            if commandCount > 0 {
                parts.append("已运行 \(commandCount) 条命令")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        private static func argumentsDictionary(from json: String) -> [String: Any] {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any] else {
                return [:]
            }
            return dict
        }

        private static func path(in arguments: [String: Any]) -> String {
            guard let path = arguments["path"] as? String, !path.isEmpty else { return "." }
            return path
        }
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
            preferredKeys = ["command", "cwd", "timeout"]
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
        case "claude_code", "codex_cli", "cursor_agent":
            preferredKeys = ["prompt", "permission_mode"]
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
