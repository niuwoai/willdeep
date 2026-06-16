//
//  AgentToolModels.swift
//  WillDeep
//
//  Shared data model for built-in Agent tools. AgentTools.swift owns the
//  runner implementation; this file keeps the risk/status/value types
//  reusable by UI, remote runtimes, mobile gateway, and tests.
//

import Foundation

// MARK: - Risk model

enum AgentToolRisk: String, Codable {
    /// Pure read; safe to auto-allow.
    case read
    /// Touches the workspace or shell; needs explicit Allow/Deny.
    case write
    /// Destructive or escapes the workspace; needs typed "confirm".
    case danger
    /// Asks the user a question. Doesn't execute anything -- the AppState
    /// loop intercepts it, surfaces an input card, and feeds the typed
    /// answer back as the tool result.
    case userInput
}

enum AgentToolCallStatus: String, Codable {
    case pendingApproval
    case awaitingConfirm
    case awaitingUserAnswer
    case running
    case succeeded
    case failed
    case denied
}

struct AgentToolParameter: Codable, Equatable {
    enum ParameterType: String, Codable {
        case string
        case integer
        case boolean
        case stringArray
    }

    let name: String
    let type: ParameterType
    let description: String
    let required: Bool
}

struct AgentToolDescriptor: Equatable {
    let name: String
    let description: String
    let risk: AgentToolRisk
    let parameters: [AgentToolParameter]
}

struct AgentToolContext {
    /// Workspace root. All filesystem tools must refuse paths outside this.
    let rootDirectory: URL?
    /// Canonical workspace binding. For local workspaces this mirrors
    /// `rootDirectory`; for remote workspaces it carries the runtime id
    /// plus remote root path.
    let workspaceLocation: WorkspaceLocation?
    /// Remote runtime descriptor resolved by the AppState loop. Nil for
    /// local sessions or stale/deleted remote runtime ids.
    let runtimeDescriptor: RuntimeDescriptor?
    /// Runtime that's executing this tool -- used by background-job
    /// tools to scope jobs to the originating session. Nil in
    /// non-conversational call paths (tests, ad-hoc skill harness).
    let runtimeID: UUID?
    /// Shared background-job registry. Nil in non-app call paths;
    /// when nil, `run_command` with `run_in_background: true` falls
    /// back to the foreground path so behavior is still defined.
    let jobRegistry: AgentJobRegistry?
    /// Effective sandbox mode chosen by the AppState approval gateway.
    /// Read-only tools and auto-approved commands get a scrubbed local
    /// environment; user-approved write/network/credential commands run
    /// in the escalated/full-user environment.
    let sandboxMode: AgentSandboxMode

    init(
        rootDirectory: URL?,
        workspaceLocation: WorkspaceLocation? = nil,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        runtimeID: UUID? = nil,
        jobRegistry: AgentJobRegistry? = nil,
        sandboxMode: AgentSandboxMode = .readOnly
    ) {
        self.rootDirectory = rootDirectory
        self.workspaceLocation = workspaceLocation ?? rootDirectory.map { .local(path: $0.standardizedFileURL.path) }
        self.runtimeDescriptor = runtimeDescriptor
        self.runtimeID = runtimeID
        self.jobRegistry = jobRegistry
        self.sandboxMode = sandboxMode
    }

    var sshBackend: SSHRuntimeBackend? {
        guard let runtimeDescriptor,
              runtimeDescriptor.transport == .ssh,
              case .remote = workspaceLocation else {
            return nil
        }
        return SSHRuntimeBackend(descriptor: runtimeDescriptor)
    }

    var daemonBackend: DaemonRuntimeBackend? {
        guard let runtimeDescriptor,
              runtimeDescriptor.transport == .daemon,
              case .remote = workspaceLocation else {
            return nil
        }
        return DaemonRuntimeBackend(descriptor: runtimeDescriptor)
    }

    var remoteBackend: AgentRemoteRuntimeBackend? {
        if let sshBackend { return sshBackend }
        if let daemonBackend { return daemonBackend }
        return nil
    }
}

nonisolated struct AgentToolResult: Equatable, Sendable {
    /// Short one-liner for the UI status row.
    let summary: String
    /// Full payload returned to the model as the tool message content.
    let payload: String
}

enum AgentToolError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case noWorkspace
    case pathOutsideWorkspace(String)
    case notFound(String)
    case notRegular(String)
    case binaryFile(String)
    case fileTooLarge(String)
    case commandFailed(Int32, String)
    case commandTimeout
    case unknownTool(String)
    case invalidRegex(String)
    case httpFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing argument: \(name)"
        case .invalidArgument(let detail):
            return "Invalid argument: \(detail)"
        case .noWorkspace:
            return "Open a project folder before using this tool."
        case .pathOutsideWorkspace(let path):
            return "Path is outside the workspace: \(path)"
        case .notFound(let path):
            return "Path does not exist: \(path)"
        case .notRegular(let path):
            return "Path is not a regular file: \(path)"
        case .binaryFile(let path):
            return "File looks binary, refusing to read: \(path)"
        case .fileTooLarge(let path):
            return "File is too large to read inline: \(path)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command exited with status \(code)."
            }
            return "Command exited with status \(code): \(trimmed)"
        case .commandTimeout:
            return "Command timed out."
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidRegex(let detail):
            return "Invalid regular expression: \(detail)"
        case .httpFailed(let status, let detail):
            return "HTTP \(status): \(detail)"
        }
    }
}

enum AgentToolDecision {
    case approved
    case denied(reason: String)
    case answered(String)
}

// MARK: - Tool call record (UI state)

/// How a write-tier tool call ended up running. `.user` covers both the
/// per-call Allow button and the legacy auto-allow path. `.alwaysAllowList`
/// means the user previously pinned this command signature. `.staticAllowlist`
/// means the SafeCommand classifier flagged it as read-only. `.llmJudge`
/// means the LLM judge classifier approved it. `.goalMode` means the
/// session was in Goal mode, which auto-approves write-tier calls
/// (danger-tier still gates on the user). `.workspaceAccess` means the
/// current session's composer approval mode grants write-tier access
/// inside the active workspace. nil = either pure read (never gated) or
/// still pending.
enum AgentToolApprovalSource: String, Equatable, Codable {
    case user
    case alwaysAllowList
    case staticAllowlist
    case llmJudge
    case goalMode
    case workspaceAccess
    /// The user approved a call that requires access outside the default
    /// sandbox boundary (network, credentials/keychain, system paths, or
    /// destructive shell syntax).
    case escalated
    /// The user marked this MCP server as fully trusted ("my own MCP")
    /// in MCP settings -- every call to it auto-runs, writes included.
    case trustedServer
}

struct AgentToolCall: Identifiable, Equatable {
    let id: UUID
    let messageID: UUID
    /// Provider-issued tool_call id (used to thread results back).
    let externalID: String
    let toolName: String
    let arguments: [String: AgentJSONValue]
    let risk: AgentToolRisk
    var status: AgentToolCallStatus
    var result: AgentToolResult?
    var errorMessage: String?
    /// Set when a write-tier tool call was auto-approved. Used by the UI
    /// to surface a small "Auto-approved" note so the user can audit
    /// what slipped through.
    var approvalSource: AgentToolApprovalSource?

    init(
        id: UUID = UUID(),
        messageID: UUID,
        externalID: String,
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        status: AgentToolCallStatus,
        result: AgentToolResult? = nil,
        errorMessage: String? = nil,
        approvalSource: AgentToolApprovalSource? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.externalID = externalID
        self.toolName = toolName
        self.arguments = arguments
        self.risk = risk
        self.status = status
        self.result = result
        self.errorMessage = errorMessage
        self.approvalSource = approvalSource
    }
}

// MARK: - JSON helpers

/// Lightweight JSON value type so we can round-trip arbitrary tool arguments
/// without depending on Foundation's `Any`-based JSON serialization.
enum AgentJSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    nonisolated var displaySummary: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            let trimmed = value.replacingOccurrences(of: "\n", with: " ")
            if trimmed.count > 80 {
                return String(trimmed.prefix(80)) + "…"
            }
            return trimmed
        case .array(let values):
            return "[\(values.count) items]"
        case .object(let dict):
            return "{\(dict.count) keys}"
        }
    }

    nonisolated static func decode(from data: Data) throws -> AgentJSONValue {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return wrap(parsed)
    }

    nonisolated static func decode(from string: String) -> AgentJSONValue {
        guard let data = string.data(using: .utf8) else { return .string(string) }
        do {
            return try decode(from: data)
        } catch {
            return .string(string)
        }
    }

    nonisolated static func wrap(_ value: Any) -> AgentJSONValue {
        if value is NSNull { return .null }
        if let boolean = value as? Bool { return .bool(boolean) }
        if let number = value as? NSNumber {
            if CFNumberGetType(number) == .charType { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] { return .array(array.map { wrap($0) }) }
        if let dict = value as? [String: Any] {
            var converted: [String: AgentJSONValue] = [:]
            for (key, raw) in dict {
                converted[key] = wrap(raw)
            }
            return .object(converted)
        }
        return .null
    }

    nonisolated var rawAny: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.rawAny)
        case .object(let dict):
            var result: [String: Any] = [:]
            for (key, value) in dict {
                result[key] = value.rawAny
            }
            return result
        }
    }

    nonisolated func stringValue() -> String? {
        if case .string(let value) = self { return value }
        return nil
    }

    nonisolated func intValue() -> Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    nonisolated func boolValue() -> Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    nonisolated func stringArrayValue() -> [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap { $0.stringValue() }
        // Only treat the array as "string array" when every element was
        // a string -- partial matches are ambiguous enough to skip.
        guard strings.count == values.count else { return nil }
        return strings
    }
}
