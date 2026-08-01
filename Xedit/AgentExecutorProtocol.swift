//
//  AgentExecutorProtocol.swift
//  WillDeep
//
//  Structured execution boundary for external coding agents. Provider-specific
//  JSONL is normalized here so process transport, UI, persistence, and approval
//  code do not depend on one CLI's event schema.
//

import Foundation

nonisolated enum AgentExecutorEventKind: String, Codable, Equatable, Sendable {
    case sessionStarted = "session_started"
    case message
    case thinking
    case toolStarted = "tool_started"
    case toolUpdated = "tool_updated"
    case fileChanged = "file_changed"
    case permissionRequested = "permission_requested"
    case usage
    case warning
    case finished
    case raw
}

nonisolated enum AgentExecutorEventStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

nonisolated struct AgentExecutorUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var durationMilliseconds: Int?

    var isEmpty: Bool {
        inputTokens == nil
            && cachedInputTokens == nil
            && outputTokens == nil
            && costUSD == nil
            && durationMilliseconds == nil
    }
}

nonisolated struct AgentExecutorEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: AgentExecutorEventKind
    var timestamp: Date
    var sessionID: String?
    var itemID: String?
    var parentID: String?
    var title: String?
    var detail: String?
    var status: AgentExecutorEventStatus?
    var toolName: String?
    var filePath: String?
    var usage: AgentExecutorUsage?
    var rawJSON: String?

    init(
        id: UUID = UUID(),
        kind: AgentExecutorEventKind,
        timestamp: Date = Date(),
        sessionID: String? = nil,
        itemID: String? = nil,
        parentID: String? = nil,
        title: String? = nil,
        detail: String? = nil,
        status: AgentExecutorEventStatus? = nil,
        toolName: String? = nil,
        filePath: String? = nil,
        usage: AgentExecutorUsage? = nil,
        rawJSON: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.itemID = itemID
        self.parentID = parentID
        self.title = title
        self.detail = detail
        self.status = status
        self.toolName = toolName
        self.filePath = filePath
        self.usage = usage
        self.rawJSON = rawJSON
    }
}

nonisolated protocol AgentExecutorEventDecoding: AnyObject, Sendable {
    func decode(line: String) -> [AgentExecutorEvent]
}

nonisolated struct AgentExecutorProcessSpecification {
    let executor: AgentExecutionAgent
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?
    let environment: [String: String]
    let standardInput: Data
    let sandboxMode: AgentSandboxMode
    let displayCommand: String
    let decoder: any AgentExecutorEventDecoding
}

nonisolated enum AgentExecutorProcessFactory {
    static func claudeCode(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        sessionID: String? = nil,
        imagePaths: [String],
        workingDirectory: URL?,
        environment: [String: String],
        sandboxMode: AgentSandboxMode
    ) -> AgentExecutorProcessSpecification {
        var arguments: [String] = []
        let imageDirectories = Array(Set(imagePaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })).sorted()
        for directory in imageDirectories {
            arguments += ["--add-dir", directory]
        }
        arguments += [
            "-p",
            "--input-format", "text",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode,
        ]
        if let sessionID, !sessionID.isEmpty {
            arguments += ["--resume", sessionID]
        }
        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }
        return AgentExecutorProcessSpecification(
            executor: .claudeCode,
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: Data((prompt + "\n").utf8),
            sandboxMode: sandboxMode,
            displayCommand: "Claude Code",
            decoder: ClaudeCodeStreamEventDecoder()
        )
    }

    static func codexCLI(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        sessionID: String? = nil,
        workspacePath: String?,
        imagePaths: [String],
        workingDirectory: URL?,
        environment: [String: String],
        sandboxMode: AgentSandboxMode
    ) -> AgentExecutorProcessSpecification {
        let sandbox = permissionMode == "plan" ? "read-only" : "workspace-write"
        var arguments = [
            "-a", "never",
            "--sandbox", sandbox,
        ]
        if let workspacePath, !workspacePath.isEmpty {
            arguments += ["--cd", workspacePath]
        }
        arguments.append("exec")
        if let sessionID, !sessionID.isEmpty {
            arguments += ["resume", "--json", "--skip-git-repo-check"]
        } else {
            arguments += ["--json", "--color", "never", "--skip-git-repo-check"]
        }
        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }
        if !imagePaths.isEmpty {
            arguments.append("--image")
            arguments += imagePaths
            arguments.append("--")
        }
        if let sessionID, !sessionID.isEmpty {
            arguments.append(sessionID)
        }
        // A positional "-" keeps the complete prompt out of argv and asks
        // Codex to consume it from stdin.
        arguments.append("-")
        return AgentExecutorProcessSpecification(
            executor: .codexCLI,
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: Data((prompt + "\n").utf8),
            sandboxMode: sandboxMode,
            displayCommand: "Codex",
            decoder: CodexJSONLEventDecoder()
        )
    }
}

nonisolated final class ClaudeCodeStreamEventDecoder: AgentExecutorEventDecoding, @unchecked Sendable {
    func decode(line: String) -> [AgentExecutorEvent] {
        guard let object = AgentExecutorJSON.object(from: line),
              let type = object["type"] as? String else {
            return [AgentExecutorJSON.rawEvent(line)]
        }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else {
                return [AgentExecutorJSON.rawEvent(line)]
            }
            return [
                AgentExecutorEvent(
                    kind: .sessionStarted,
                    sessionID: AgentExecutorJSON.string(object["session_id"]),
                    title: AgentExecutorJSON.string(object["model"]),
                    detail: AgentExecutorJSON.stringArray(object["tools"]).joined(separator: ", "),
                    status: .running,
                    rawJSON: line
                )
            ]
        case "assistant":
            return contentEvents(
                object: object,
                defaultKind: .message,
                rawLine: line
            )
        case "user":
            return contentEvents(
                object: object,
                defaultKind: .toolUpdated,
                rawLine: line
            )
        case "result":
            return resultEvents(object: object, rawLine: line)
        case "stream_event":
            return partialEvents(object: object, rawLine: line)
        default:
            return [AgentExecutorJSON.rawEvent(line)]
        }
    }

    private func contentEvents(
        object: [String: Any],
        defaultKind: AgentExecutorEventKind,
        rawLine: String
    ) -> [AgentExecutorEvent] {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else {
            return [AgentExecutorJSON.rawEvent(rawLine)]
        }
        let sessionID = AgentExecutorJSON.string(object["session_id"])
        let parentID = AgentExecutorJSON.string(object["parent_tool_use_id"])
        var events: [AgentExecutorEvent] = []
        for block in blocks {
            let blockType = AgentExecutorJSON.string(block["type"]) ?? ""
            switch blockType {
            case "text":
                events.append(AgentExecutorEvent(
                    kind: .message,
                    sessionID: sessionID,
                    parentID: parentID,
                    detail: AgentExecutorJSON.string(block["text"]),
                    status: .completed,
                    rawJSON: rawLine
                ))
            case "thinking":
                events.append(AgentExecutorEvent(
                    kind: .thinking,
                    sessionID: sessionID,
                    parentID: parentID,
                    detail: AgentExecutorJSON.string(block["thinking"]),
                    status: .completed,
                    rawJSON: rawLine
                ))
            case "tool_use", "server_tool_use":
                let name = AgentExecutorJSON.string(block["name"])
                events.append(AgentExecutorEvent(
                    kind: .toolStarted,
                    sessionID: sessionID,
                    itemID: AgentExecutorJSON.string(block["id"]),
                    parentID: parentID,
                    title: name,
                    detail: AgentExecutorJSON.pretty(block["input"]),
                    status: .running,
                    toolName: name,
                    rawJSON: rawLine
                ))
            case "tool_result":
                let isError = AgentExecutorJSON.bool(block["is_error"]) ?? false
                events.append(AgentExecutorEvent(
                    kind: .toolUpdated,
                    sessionID: sessionID,
                    itemID: AgentExecutorJSON.string(block["tool_use_id"]),
                    parentID: parentID,
                    detail: AgentExecutorJSON.textContent(block["content"]),
                    status: isError ? .failed : .completed,
                    rawJSON: rawLine
                ))
            default:
                if defaultKind == .toolUpdated {
                    events.append(AgentExecutorEvent(
                        kind: defaultKind,
                        sessionID: sessionID,
                        parentID: parentID,
                        detail: AgentExecutorJSON.pretty(block),
                        status: .completed,
                        rawJSON: rawLine
                    ))
                }
            }
        }
        return events.isEmpty ? [AgentExecutorJSON.rawEvent(rawLine)] : events
    }

    private func resultEvents(
        object: [String: Any],
        rawLine: String
    ) -> [AgentExecutorEvent] {
        let usageObject = object["usage"] as? [String: Any] ?? [:]
        let usage = AgentExecutorUsage(
            inputTokens: AgentExecutorJSON.int(usageObject["input_tokens"]),
            cachedInputTokens: AgentExecutorJSON.sumInts(
                usageObject["cache_read_input_tokens"],
                usageObject["cache_creation_input_tokens"]
            ),
            outputTokens: AgentExecutorJSON.int(usageObject["output_tokens"]),
            costUSD: AgentExecutorJSON.double(object["total_cost_usd"]),
            durationMilliseconds: AgentExecutorJSON.int(object["duration_ms"])
        )
        var events: [AgentExecutorEvent] = []
        if !usage.isEmpty {
            events.append(AgentExecutorEvent(
                kind: .usage,
                sessionID: AgentExecutorJSON.string(object["session_id"]),
                usage: usage,
                rawJSON: rawLine
            ))
        }
        let failed = AgentExecutorJSON.bool(object["is_error"]) ?? false
        events.append(AgentExecutorEvent(
            kind: .finished,
            sessionID: AgentExecutorJSON.string(object["session_id"]),
            title: AgentExecutorJSON.string(object["subtype"]),
            detail: AgentExecutorJSON.string(object["result"]),
            status: failed ? .failed : .completed,
            usage: usage.isEmpty ? nil : usage,
            rawJSON: rawLine
        ))
        return events
    }

    private func partialEvents(
        object: [String: Any],
        rawLine: String
    ) -> [AgentExecutorEvent] {
        guard let event = object["event"] as? [String: Any],
              let delta = event["delta"] as? [String: Any],
              let deltaType = AgentExecutorJSON.string(delta["type"]) else {
            return [AgentExecutorJSON.rawEvent(rawLine)]
        }
        switch deltaType {
        case "text_delta":
            return [AgentExecutorEvent(
                kind: .message,
                sessionID: AgentExecutorJSON.string(object["session_id"]),
                detail: AgentExecutorJSON.string(delta["text"]),
                status: .running,
                rawJSON: rawLine
            )]
        case "thinking_delta":
            return [AgentExecutorEvent(
                kind: .thinking,
                sessionID: AgentExecutorJSON.string(object["session_id"]),
                detail: AgentExecutorJSON.string(delta["thinking"]),
                status: .running,
                rawJSON: rawLine
            )]
        default:
            return [AgentExecutorJSON.rawEvent(rawLine)]
        }
    }
}

nonisolated final class CodexJSONLEventDecoder: AgentExecutorEventDecoding, @unchecked Sendable {
    func decode(line: String) -> [AgentExecutorEvent] {
        guard let object = AgentExecutorJSON.object(from: line),
              let type = AgentExecutorJSON.string(object["type"]) else {
            return [AgentExecutorJSON.rawEvent(line)]
        }

        switch type {
        case "thread.started":
            return [AgentExecutorEvent(
                kind: .sessionStarted,
                sessionID: AgentExecutorJSON.string(object["thread_id"]),
                status: .running,
                rawJSON: line
            )]
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else {
                return [AgentExecutorJSON.rawEvent(line)]
            }
            return itemEvents(
                item: item,
                envelopeType: type,
                rawLine: line
            )
        case "turn.completed":
            return completedTurnEvents(object: object, rawLine: line)
        case "turn.failed":
            return [
                AgentExecutorEvent(
                    kind: .warning,
                    detail: AgentExecutorJSON.pretty(object["error"]),
                    status: .failed,
                    rawJSON: line
                ),
                AgentExecutorEvent(
                    kind: .finished,
                    detail: AgentExecutorJSON.pretty(object["error"]),
                    status: .failed,
                    rawJSON: line
                )
            ]
        case "error":
            return [AgentExecutorEvent(
                kind: .warning,
                detail: AgentExecutorJSON.string(object["message"]) ?? AgentExecutorJSON.pretty(object),
                status: .failed,
                rawJSON: line
            )]
        default:
            return [AgentExecutorJSON.rawEvent(line)]
        }
    }

    private func itemEvents(
        item: [String: Any],
        envelopeType: String,
        rawLine: String
    ) -> [AgentExecutorEvent] {
        let itemType = AgentExecutorJSON.string(item["type"]) ?? ""
        let itemID = AgentExecutorJSON.string(item["id"])
        let terminal = envelopeType == "item.completed"
        let status = terminal ? AgentExecutorEventStatus.completed : .running

        switch itemType {
        case "agent_message":
            return [AgentExecutorEvent(
                kind: .message,
                itemID: itemID,
                detail: AgentExecutorJSON.string(item["text"]),
                status: status,
                rawJSON: rawLine
            )]
        case "reasoning":
            return [AgentExecutorEvent(
                kind: .thinking,
                itemID: itemID,
                detail: AgentExecutorJSON.string(item["text"])
                    ?? AgentExecutorJSON.textContent(item["summary"]),
                status: status,
                rawJSON: rawLine
            )]
        case "command_execution":
            let command = AgentExecutorJSON.string(item["command"])
                ?? AgentExecutorJSON.stringArray(item["command"]).joined(separator: " ")
            let failed = terminal && AgentExecutorJSON.int(item["exit_code"]).map { $0 != 0 } == true
            return [AgentExecutorEvent(
                kind: terminal ? .toolUpdated : .toolStarted,
                itemID: itemID,
                title: command,
                detail: AgentExecutorJSON.string(item["aggregated_output"]),
                status: failed ? .failed : status,
                toolName: "command_execution",
                rawJSON: rawLine
            )]
        case "file_change":
            return fileChangeEvents(item: item, rawLine: rawLine)
        case "mcp_tool_call", "collab_tool_call":
            let name = AgentExecutorJSON.string(item["tool"])
                ?? AgentExecutorJSON.string(item["name"])
            let failed = AgentExecutorJSON.string(item["status"]) == "failed"
            return [AgentExecutorEvent(
                kind: terminal ? .toolUpdated : .toolStarted,
                itemID: itemID,
                title: name,
                detail: AgentExecutorJSON.pretty(item["result"] ?? item["arguments"]),
                status: failed ? .failed : status,
                toolName: name,
                rawJSON: rawLine
            )]
        case "error":
            return [AgentExecutorEvent(
                kind: .warning,
                itemID: itemID,
                detail: AgentExecutorJSON.string(item["message"]),
                status: .failed,
                rawJSON: rawLine
            )]
        default:
            return [AgentExecutorJSON.rawEvent(rawLine)]
        }
    }

    private func fileChangeEvents(
        item: [String: Any],
        rawLine: String
    ) -> [AgentExecutorEvent] {
        let itemID = AgentExecutorJSON.string(item["id"])
        if let changes = item["changes"] as? [[String: Any]] {
            let events = changes.compactMap { change -> AgentExecutorEvent? in
                guard let path = AgentExecutorJSON.string(change["path"]) else { return nil }
                return AgentExecutorEvent(
                    kind: .fileChanged,
                    itemID: itemID,
                    title: AgentExecutorJSON.string(change["kind"]),
                    status: .completed,
                    filePath: path,
                    rawJSON: rawLine
                )
            }
            if !events.isEmpty {
                return events
            }
        }
        return [AgentExecutorEvent(
            kind: .fileChanged,
            itemID: itemID,
            title: AgentExecutorJSON.string(item["kind"]),
            status: .completed,
            filePath: AgentExecutorJSON.string(item["path"]),
            rawJSON: rawLine
        )]
    }

    private func completedTurnEvents(
        object: [String: Any],
        rawLine: String
    ) -> [AgentExecutorEvent] {
        let usageObject = object["usage"] as? [String: Any] ?? [:]
        let usage = AgentExecutorUsage(
            inputTokens: AgentExecutorJSON.int(usageObject["input_tokens"]),
            cachedInputTokens: AgentExecutorJSON.int(usageObject["cached_input_tokens"]),
            outputTokens: AgentExecutorJSON.int(usageObject["output_tokens"]),
            costUSD: AgentExecutorJSON.double(usageObject["cost_usd"]),
            durationMilliseconds: AgentExecutorJSON.int(object["duration_ms"])
        )
        var events: [AgentExecutorEvent] = []
        if !usage.isEmpty {
            events.append(AgentExecutorEvent(
                kind: .usage,
                usage: usage,
                rawJSON: rawLine
            ))
        }
        events.append(AgentExecutorEvent(
            kind: .finished,
            status: .completed,
            usage: usage.isEmpty ? nil : usage,
            rawJSON: rawLine
        ))
        return events
    }
}

nonisolated enum AgentExecutorJSON {
    static func object(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return value as? [String: Any]
    }

    static func rawEvent(_ line: String) -> AgentExecutorEvent {
        AgentExecutorEvent(
            kind: .raw,
            detail: line,
            rawJSON: line
        )
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["true", "1", "yes"].contains(value.lowercased())
        default:
            return nil
        }
    }

    static func sumInts(_ lhs: Any?, _ rhs: Any?) -> Int? {
        let values = [int(lhs), int(rhs)].compactMap { $0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    static func stringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap(string)
        }
        return string(value).map { [$0] } ?? []
    }

    static func textContent(_ value: Any?) -> String? {
        if let text = string(value) {
            return text
        }
        guard let values = value as? [Any] else {
            return pretty(value)
        }
        let texts = values.compactMap { entry -> String? in
            if let string = string(entry) {
                return string
            }
            guard let object = entry as? [String: Any] else { return nil }
            return string(object["text"])
                ?? string(object["content"])
                ?? pretty(object)
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func pretty(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
              ) else {
            return "\(value)"
        }
        return String(data: data, encoding: .utf8)
    }
}
