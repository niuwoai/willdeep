//
//  AgentTools.swift
//  VeilWriter
//
//  Built-in tools exposed to the project agent: search, read, list,
//  run command, and git status. Each tool declares a risk tier so the
//  AppState can decide whether to auto-allow, prompt, or require an
//  explicit confirm word before executing.
//

import Foundation
import Darwin

// MARK: - Risk model

enum AgentToolRisk: String, Codable {
    /// Pure read; safe to auto-allow.
    case read
    /// Touches the workspace or shell; needs explicit Allow/Deny.
    case write
    /// Destructive or escapes the workspace; needs typed "confirm".
    case danger
    /// Asks the user a question. Doesn't execute anything — the AppState
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
}

struct AgentToolResult: Equatable {
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
        }
    }
}

enum AgentToolDecision {
    case approved
    case denied(reason: String)
    case answered(String)
}

struct AgentAlwaysAllowedCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let commandSignature: String
    let createdAt: Date

    init(id: UUID = UUID(), commandSignature: String, createdAt: Date = Date()) {
        self.id = id
        self.commandSignature = commandSignature
        self.createdAt = createdAt
    }
}

enum AgentCommandAuthorization {
    static func signature(for command: String) -> String? {
        guard let tokens = shellTokens(from: command) else { return nil }
        guard let executable = tokens.first?.lowercased(), !executable.isEmpty else {
            return nil
        }

        if executable == "git", tokens.count >= 2 {
            return "\(executable) \(tokens[1].lowercased())"
        }

        if ["npm", "pnpm"].contains(executable), tokens.count >= 3, tokens[1].lowercased() == "run" {
            return "\(executable) run \(tokens[2].lowercased())"
        }

        if executable == "yarn", tokens.count >= 3, tokens[1].lowercased() == "run" {
            return "\(executable) run \(tokens[2].lowercased())"
        }

        if tokenUsesSubcommand(executable), tokens.count >= 2 {
            return "\(executable) \(tokens[1].lowercased())"
        }

        return tokenAllowsBareSignature(executable) ? executable : nil
    }

    static func displayName(for command: String) -> String {
        signature(for: command) ?? command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenUsesSubcommand(_ token: String) -> Bool {
        [
            "cargo", "go", "swift", "xcodebuild", "make",
            "ruby", "python", "python3", "node",
            "npm", "pnpm", "yarn"
        ].contains(token)
    }

    private static func tokenAllowsBareSignature(_ token: String) -> Bool {
        ["ls", "pwd"].contains(token)
    }

    private static func shellTokens(from command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                activeQuote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            if "|&;<>".contains(character) {
                return nil
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

// MARK: - Tool call record (UI state)

/// How a write-tier tool call ended up running. `.user` covers both the
/// per-call Allow button and the legacy auto-allow path. `.alwaysAllowList`
/// means the user previously pinned this command signature. `.staticAllowlist`
/// means the SafeCommand classifier flagged it as read-only. `.llmJudge`
/// means the LLM judge classifier approved it. nil = either pure read
/// (never gated) or still pending.
enum AgentToolApprovalSource: String, Equatable, Codable {
    case user
    case alwaysAllowList
    case staticAllowlist
    case llmJudge
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

    var displaySummary: String {
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

    static func decode(from data: Data) throws -> AgentJSONValue {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return wrap(parsed)
    }

    static func decode(from string: String) -> AgentJSONValue {
        guard let data = string.data(using: .utf8) else { return .string(string) }
        do {
            return try decode(from: data)
        } catch {
            return .string(string)
        }
    }

    static func wrap(_ value: Any) -> AgentJSONValue {
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

    var rawAny: Any {
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

    func stringValue() -> String? {
        if case .string(let value) = self { return value }
        return nil
    }

    func intValue() -> Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    func boolValue() -> Bool? {
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

    func stringArrayValue() -> [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap { $0.stringValue() }
        // Only treat the array as "string array" when every element was
        // a string — partial matches are ambiguous enough to skip.
        guard strings.count == values.count else { return nil }
        return strings
    }
}

// MARK: - Tool registry

enum AgentToolRegistry {
    static let all: [AgentToolDescriptor] = [
        AgentToolDescriptor(
            name: "search_files",
            description: "Search workspace files for a literal text query and return matching lines with paths and line numbers. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "query", type: .string, description: "Literal text to search for. Case-insensitive.", required: true),
                AgentToolParameter(name: "max_results", type: .integer, description: "Maximum matches to return. Defaults to 60.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "grep_files",
            description: "Search workspace files with a regular expression (ICU/NSRegularExpression syntax) and return matching lines with paths and line numbers. Prefer this over search_files when you need character classes, anchors, alternation, or backreferences. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "pattern", type: .string, description: "Regular expression pattern (ICU syntax, e.g. `func\\s+\\w+`).", required: true),
                AgentToolParameter(name: "path", type: .string, description: "Optional workspace-relative directory to limit the search to. Empty or omitted means the workspace root.", required: false),
                AgentToolParameter(name: "include", type: .string, description: "Optional filename glob to filter which files are searched (e.g. `*.swift`, `*.{ts,tsx}`). Matches just the filename.", required: false),
                AgentToolParameter(name: "case_sensitive", type: .boolean, description: "Match case-sensitively. Defaults to false.", required: false),
                AgentToolParameter(name: "max_results", type: .integer, description: "Maximum matches to return. Defaults to 60, capped at 200.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "read_file",
            description: "Read a UTF-8 text file inside the workspace. Returns the file content with line numbers.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Workspace-relative path to read.", required: true),
                AgentToolParameter(name: "max_bytes", type: .integer, description: "Maximum bytes to return. Defaults to 64KB.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "list_directory",
            description: "List the immediate entries of a workspace directory. Returns names and whether each entry is a directory.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Workspace-relative directory path. Empty string means workspace root.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "git_status",
            description: "Return the current git branch and porcelain status for the workspace. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "run_command",
            description: "Run a shell command in the workspace root. Requires user approval. Refuses commands that escape the workspace.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "command", type: .string, description: "Shell command line. Runs through /bin/sh -c.", required: true),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Hard timeout in seconds. Defaults to 20, max 120.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "list_skills",
            description: "List installed Codex skills from CODEX_HOME so the agent can choose a specialized workflow before acting. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "query", type: .string, description: "Optional case-insensitive text filter for skill name or description.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "read_skill",
            description: "Read one installed Codex skill's SKILL.md by skill name or identifier. Use after list_skills when a skill matches the task. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "name", type: .string, description: "Skill name or identifier returned by list_skills.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "list_mcp_servers",
            description: "List configured MCP servers from Codex config with sensitive environment values redacted. Does not start servers. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "list_mcp_tools",
            description: "Start a configured MCP server and list its available MCP tools via JSON-RPC. Read-only discovery.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "server", type: .string, description: "MCP server name from list_mcp_servers.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "call_mcp_tool",
            description: "Call a tool on a configured MCP server with JSON arguments. Requires user approval because MCP tools may perform writes or network actions.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "server", type: .string, description: "MCP server name from list_mcp_servers.", required: true),
                AgentToolParameter(name: "tool", type: .string, description: "MCP tool name from list_mcp_tools.", required: true),
                AgentToolParameter(name: "arguments_json", type: .string, description: "JSON object string to pass as the MCP tool arguments. Defaults to {}.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "ask_user",
            description: "Ask the user a clarifying question and wait for their answer before continuing. Use this whenever a required piece of information is missing or ambiguous; do not guess. Returns the user's answer as the tool result. When the question has a small, well-defined set of valid answers, pass them as `options` so the user can click instead of type.",
            risk: .userInput,
            parameters: [
                AgentToolParameter(name: "question", type: .string, description: "The clarifying question to show the user.", required: true),
                AgentToolParameter(name: "options", type: .stringArray, description: "Optional list of preset answers. When provided, the UI renders them as buttons (single-choice) or checkboxes (multi-choice). The user can still type a free-form answer.", required: false),
                AgentToolParameter(name: "multi_select", type: .boolean, description: "When true, the user can pick multiple options; the tool result is a comma-separated list. Defaults to false (single choice).", required: false)
            ]
        )
    ]

    static func descriptor(for name: String) -> AgentToolDescriptor? {
        all.first { $0.name == name }
    }

    /// Classify a `run_command` invocation: bumps to .danger when the command
    /// matches a destructive pattern. Pure read-only shell chains can be
    /// auto-run when every directory hop stays inside the current workspace.
    static func risk(
        for name: String,
        arguments: [String: AgentJSONValue],
        rootDirectory: URL? = nil
    ) -> AgentToolRisk {
        guard let descriptor = descriptor(for: name) else { return .danger }
        if descriptor.name == "run_command", let command = arguments["command"]?.stringValue() {
            if looksDangerous(command: command) {
                return .danger
            }
            if isReadOnlyShellCommand(command, rootDirectory: rootDirectory) {
                return .read
            }
        }
        return descriptor.risk
    }

    private static let dangerousPatterns: [String] = [
        "rm -rf", "rm -fr", "rm -r ", "sudo ",
        ":(){:|:&};:",
        "git push --force", "git push -f", "git reset --hard",
        "git clean -f", "git checkout -- .",
        "mkfs", "dd if=", "shutdown", "reboot", "halt",
        "chmod -R 777", "chown -R",
        "> /dev/sda", "curl ", "wget "
    ]

    private static func looksDangerous(command: String) -> Bool {
        let lower = command.lowercased()
        return dangerousPatterns.contains { lower.contains($0) }
    }

    private static func isReadOnlyShellCommand(_ command: String, rootDirectory: URL?) -> Bool {
        guard let segments = splitSimpleShellChain(command), !segments.isEmpty else {
            return false
        }
        let normalizedRoot = rootDirectory?.standardizedFileURL
        var workingDirectory = normalizedRoot

        for segment in segments {
            guard let tokens = shellTokens(from: segment), let executable = tokens.first?.lowercased() else {
                return false
            }
            if executable == "cd" {
                guard let resolved = resolvedSafeCD(tokens, workingDirectory: workingDirectory, rootDirectory: normalizedRoot) else {
                    return false
                }
                workingDirectory = resolved
                continue
            }
            guard isReadOnlyCommand(tokens, workingDirectory: workingDirectory, rootDirectory: normalizedRoot) else {
                return false
            }
        }
        return true
    }

    private static func splitSimpleShellChain(_ command: String) -> [String]? {
        var segments: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaped = false
        var index = command.startIndex

        while index < command.endIndex {
            let character = command[index]
            if isEscaped {
                current.append(character)
                isEscaped = false
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                isEscaped = true
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                }
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                activeQuote = character
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if character == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                segments.append(trimmed)
                current = ""
                index = command.index(after: index)
                continue
            }
            if character == "&" {
                let next = command.index(after: index)
                guard next < command.endIndex, command[next] == "&" else { return nil }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                segments.append(trimmed)
                current = ""
                index = command.index(after: next)
                continue
            }
            if "|<>`$(){}".contains(character) {
                return nil
            }
            current.append(character)
            index = command.index(after: index)
        }

        guard activeQuote == nil, !isEscaped else { return nil }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(trimmed)
        }
        return segments
    }

    private static func shellTokens(from command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                activeQuote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            if "&;|<>`$(){}".contains(character) {
                return nil
            }
            current.append(character)
        }
        guard activeQuote == nil, !isEscaped else { return nil }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func resolvedSafeCD(_ tokens: [String], workingDirectory: URL?, rootDirectory: URL?) -> URL? {
        guard tokens.count <= 2 else { return nil }
        guard let path = tokens.dropFirst().first else {
            return rootDirectory == nil ? workingDirectory : nil
        }
        return resolvedSafePath(path, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
    }

    private static func isReadOnlyCommand(_ tokens: [String], workingDirectory: URL?, rootDirectory: URL?) -> Bool {
        guard let rawExecutable = tokens.first else { return false }
        let executable = URL(fileURLWithPath: rawExecutable).lastPathComponent.lowercased()

        switch executable {
        case "git":
            return isReadOnlyGitCommand(tokens, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        case "pwd", "ls", "cat", "head", "tail", "wc", "grep", "rg", "tree", "du", "df", "file", "sort", "uniq":
            return !containsUnsafePathToken(tokens.dropFirst(), workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        case "sed":
            let args = Array(tokens.dropFirst())
            guard !args.contains(where: { $0 == "-i" || $0.hasPrefix("-i.") || $0.hasPrefix("-i") }) else {
                return false
            }
            return !containsUnsafePathToken(args, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        case "find":
            let args = Array(tokens.dropFirst())
            guard !args.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) }) else {
                return false
            }
            return !containsUnsafePathToken(args, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        default:
            return false
        }
    }

    private static func isReadOnlyGitCommand(_ tokens: [String], workingDirectory: URL?, rootDirectory: URL?) -> Bool {
        var index = 1
        var commandDirectory = workingDirectory
        while index < tokens.count {
            let token = tokens[index]
            if token == "-C" {
                guard index + 1 < tokens.count,
                      let resolved = resolvedSafePath(
                        tokens[index + 1],
                        workingDirectory: commandDirectory,
                        rootDirectory: rootDirectory
                      ) else {
                    return false
                }
                commandDirectory = resolved
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                return false
            }
            break
        }
        guard index < tokens.count else { return false }

        let subcommand = tokens[index].lowercased()
        let args = Array(tokens.dropFirst(index + 1))
        let readOnlySubcommands: Set<String> = [
            "status", "diff", "log", "show", "rev-parse",
            "ls-files", "grep", "describe", "blame"
        ]
        guard readOnlySubcommands.contains(subcommand) else { return false }

        if subcommand == "diff" {
            guard !args.contains(where: { $0 == "--output" || $0.hasPrefix("--output=") }) else {
                return false
            }
        }

        return !containsUnsafePathToken(args, workingDirectory: commandDirectory, rootDirectory: rootDirectory)
    }

    private static func containsUnsafePathToken<S: Sequence>(
        _ tokens: S,
        workingDirectory: URL?,
        rootDirectory: URL?
    ) -> Bool where S.Element == String {
        tokens.contains { token in
            guard !token.hasPrefix("-"), token != "--" else { return false }
            if rootDirectory != nil {
                return resolvedSafePath(token, workingDirectory: workingDirectory, rootDirectory: rootDirectory) == nil
            }
            return !isSafeRelativePathToken(token)
        }
    }

    private static func resolvedSafePath(_ token: String, workingDirectory: URL?, rootDirectory: URL?) -> URL? {
        guard isSafePathTokenSyntax(token, allowAbsolute: rootDirectory != nil) else {
            return nil
        }

        guard let rootDirectory else {
            guard isSafeRelativePathToken(token) else { return nil }
            return workingDirectory?.appendingPathComponent(token).standardizedFileURL
                ?? URL(fileURLWithPath: token).standardizedFileURL
        }

        let candidate: URL
        if token.hasPrefix("/") {
            candidate = URL(fileURLWithPath: token)
        } else {
            candidate = (workingDirectory ?? rootDirectory).appendingPathComponent(token)
        }
        let standardized = candidate.standardizedFileURL
        return isPath(standardized, inside: rootDirectory) ? standardized : nil
    }

    private static func isSafePathTokenSyntax(_ token: String, allowAbsolute: Bool) -> Bool {
        guard !token.isEmpty,
              !token.hasPrefix("~"),
              token != "-",
              !token.contains("*"),
              !token.contains("?") else {
            return false
        }
        if token.hasPrefix("/") {
            guard allowAbsolute else { return false }
        }
        return token
            .split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                component != ".."
            }
    }

    private static func isPath(_ url: URL, inside rootDirectory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootDirectory.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func isSafeRelativePathToken(_ token: String) -> Bool {
        guard !token.isEmpty,
              !token.hasPrefix("/"),
              !token.hasPrefix("~"),
              token != "-",
              !token.contains("*"),
              !token.contains("?") else {
            return false
        }
        return token
            .split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                component != ".."
            }
    }
}

// MARK: - Codex skills

private enum AgentSkillCatalog {
    static func listSkills(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let query = arguments["query"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let skills = AgentSkillDirectory.list(includeDisabled: false).filter { record in
            guard let query, !query.isEmpty else { return true }
            return record.identifier.lowercased().contains(query)
                || record.name.lowercased().contains(query)
                || record.description.lowercased().contains(query)
        }

        let lines = skills.map { record in
            "- \(record.identifier) | name=\(record.name) | \(record.description)"
        }
        let payload = lines.isEmpty
            ? "No installed Codex skills found."
            : lines.joined(separator: "\n")
        return AgentToolResult(summary: "\(skills.count) skills", payload: payload)
    }

    static func readSkill(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        guard let rawName = arguments["name"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            throw AgentToolError.missingArgument("name")
        }

        guard let record = AgentSkillDirectory.list(includeDisabled: false).first(where: {
            $0.identifier == rawName || $0.name == rawName
        }) else {
            throw AgentToolError.notFound(rawName)
        }

        guard let data = try? Data(contentsOf: record.url),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.notFound(record.url.path)
        }

        let limited = limit(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 48_000)
        return AgentToolResult(
            summary: record.name,
            payload: "Skill: \(record.identifier)\nPath: \(record.url.path)\n\n\(limited)"
        )
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<index])\n\n[truncated]"
    }
}

/// Public skill record + discovery surface for UI consumers (the `@skill`
/// composer popover). Mirrors `AgentSkillCatalog.SkillRecord` but exposed
/// outside the private enum so views and AppState helpers can list and
/// inline skills without going through the LLM tool-call round-trip.
struct AgentSkillEntry: Identifiable, Equatable {
    let identifier: String
    let name: String
    let description: String
    let url: URL
    let source: AgentSkillSource
    let isEnabled: Bool

    var id: String { identifier }
}

enum AgentSkillDirectory {
    private struct SkillRoot {
        let url: URL
        let source: AgentSkillSource
    }

    /// Discovers built-in skills, user skills under ~/.codex/skills,
    /// and plugin-cache skills. Returns up to ~300 records sorted by
    /// source and identifier.
    static func list(includeDisabled: Bool = false) -> [AgentSkillEntry] {
        let settings = AgentSkillSettingsStore.load()
        var records: [AgentSkillEntry] = []

        for root in skillRoots() {
            records.append(contentsOf: discover(in: root, settings: settings))
            if records.count >= 300 { break }
        }

        let deduped = dedupe(records)
        let filtered = includeDisabled ? deduped : deduped.filter(\.isEnabled)
        return filtered.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return sourceOrder(lhs.source) < sourceOrder(rhs.source)
            }
            return lhs.identifier < rhs.identifier
        }
    }

    static var userSkillsRoot: URL {
        AgentSkillFileManager.userSkillsRoot
    }

    private static func skillRoots() -> [SkillRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [SkillRoot] = bundledSkillRoots().map {
            SkillRoot(url: $0, source: .bundled)
        }
        roots.append(SkillRoot(url: home.appendingPathComponent(".codex/skills"), source: .user))
        roots.append(SkillRoot(url: home.appendingPathComponent(".codex/plugins/cache"), source: .plugin))
        return roots
    }

    private static func bundledSkillRoots() -> [URL] {
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("BundledSkills")
            if FileManager.default.fileExists(atPath: bundled.path) {
                roots.append(bundled)
            }
        }
        let sourceTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("BundledSkills")
        if FileManager.default.fileExists(atPath: sourceTree.path),
           !roots.contains(where: { $0.standardizedFileURL.path == sourceTree.standardizedFileURL.path }) {
            roots.append(sourceTree)
        }
        return roots
    }

    private static func discover(in root: SkillRoot, settings: AgentSkillSettings) -> [AgentSkillEntry] {
        guard FileManager.default.fileExists(atPath: root.url.path),
              let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
              ) else {
            return []
        }

        var records: [AgentSkillEntry] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "SKILL.md",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }

            let metadata = parseMetadata(from: text)
            let fallbackName = url.deletingLastPathComponent().lastPathComponent
            let name = metadata.name.isEmpty ? fallbackName : metadata.name
            let identifier = identifier(for: url, root: root.url, fallback: name, source: root.source)
            records.append(AgentSkillEntry(
                identifier: identifier,
                name: name,
                description: metadata.description.isEmpty ? "(no description)" : metadata.description,
                url: url,
                source: root.source,
                isEnabled: settings.isEnabled(identifier: identifier)
            ))

            if records.count >= 300 { break }
        }
        return records
    }

    /// Reads the full SKILL.md body, capped at `maxCharacters` to keep
    /// any single skill from blowing the context budget. Returns nil if
    /// the file is unreadable.
    static func loadBody(for entry: AgentSkillEntry, maxCharacters: Int = 24_000) -> String? {
        guard let data = try? Data(contentsOf: entry.url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxCharacters { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return "\(trimmed[..<idx])\n\n[truncated]"
    }

    private static func parseMetadata(from text: String) -> (name: String, description: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---" else { return ("", "") }

        var name = ""
        var description = ""
        for line in lines.dropFirst() {
            if line == "---" { break }
            if let value = yamlValue(line, key: "name") {
                name = value
            } else if let value = yamlValue(line, key: "description") {
                description = value
            }
        }
        return (name, description)
    }

    private static func yamlValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func identifier(for url: URL, root: URL, fallback: String, source: AgentSkillSource) -> String {
        let rootPath = root.standardizedFileURL.path
        let skillPath = url.deletingLastPathComponent().standardizedFileURL.path
        guard skillPath.hasPrefix(rootPath) else { return fallback }
        let relative = String(skillPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = relative.split(separator: "/").map(String.init)
        if let skillsIndex = parts.lastIndex(of: "skills"), skillsIndex + 1 < parts.count {
            return parts[(skillsIndex + 1)...].joined(separator: ":")
        }
        return parts.joined(separator: ":")
    }

    private static func dedupe(_ records: [AgentSkillEntry]) -> [AgentSkillEntry] {
        var seen = Set<String>()
        var result: [AgentSkillEntry] = []
        for record in records.sorted(by: { sourceOrder($0.source) < sourceOrder($1.source) }) {
            guard seen.insert(record.identifier).inserted else { continue }
            result.append(record)
        }
        return result
    }

    private static func sourceOrder(_ source: AgentSkillSource) -> Int {
        switch source {
        case .bundled:
            return 0
        case .user:
            return 1
        case .plugin:
            return 2
        }
    }
}

// MARK: - MCP bridge

private enum AgentLegacyMCPBridge {
    private struct ServerConfig: Sendable {
        var name: String
        var command: String = ""
        var args: [String] = []
        var env: [String: String] = [:]
        var startupTimeout: TimeInterval = 30
    }

    static func listServers() throws -> AgentToolResult {
        let servers = try loadServers()
        guard !servers.isEmpty else {
            return AgentToolResult(summary: "0 MCP servers", payload: "No MCP servers found in ~/.codex/config.toml.")
        }

        let lines = servers.map { server in
            let envKeys = server.env.keys.sorted()
            let envSummary = envKeys.isEmpty
                ? "env=[]"
                : "env=[" + envKeys.map { "\($0)=[redacted]" }.joined(separator: ", ") + "]"
            return "- \(server.name): command=\(server.command), args=\(server.args), timeout=\(Int(server.startupTimeout))s, \(envSummary)"
        }
        return AgentToolResult(summary: "\(servers.count) MCP servers", payload: lines.joined(separator: "\n"))
    }

    static func listTools(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let server = try server(named: requiredString("server", in: arguments))
        let result = try await runRequest(server: server, method: "tools/list", params: [:])
        return AgentToolResult(
            summary: "tools from \(server.name)",
            payload: result
        )
    }

    static func callTool(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let server = try server(named: requiredString("server", in: arguments))
        let toolName = try requiredString("tool", in: arguments)
        let rawArguments = arguments["arguments_json"]?.stringValue() ?? "{}"
        let toolArguments = try parseJSONObject(rawArguments)
        let params: [String: Any] = [
            "name": toolName,
            "arguments": toolArguments
        ]
        let result = try await runRequest(server: server, method: "tools/call", params: params)
        return AgentToolResult(
            summary: "\(server.name).\(toolName)",
            payload: result
        )
    }

    private static func requiredString(_ name: String, in arguments: [String: AgentJSONValue]) throws -> String {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }

    private static func server(named name: String) throws -> ServerConfig {
        let servers = try loadServers()
        guard let server = servers.first(where: { $0.name == name }) else {
            throw AgentToolError.notFound("MCP server \(name)")
        }
        return server
    }

    private static func loadServers() throws -> [ServerConfig] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return parseServers(from: text)
    }

    private static func parseServers(from text: String) -> [ServerConfig] {
        var serversByName: [String: ServerConfig] = [:]
        var currentName: String?
        var currentIsEnv = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let body = String(line.dropFirst().dropLast())
                if let section = parseMCPSection(body) {
                    currentName = section.name
                    currentIsEnv = section.isEnv
                    if serversByName[section.name] == nil {
                        serversByName[section.name] = ServerConfig(name: section.name)
                    }
                } else {
                    currentName = nil
                    currentIsEnv = false
                }
                continue
            }

            guard let currentName,
                  let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if currentIsEnv {
                serversByName[currentName]?.env[key] = parseString(value) ?? ""
                continue
            }

            switch key {
            case "command":
                serversByName[currentName]?.command = parseString(value) ?? ""
            case "args":
                serversByName[currentName]?.args = parseStringArray(value)
            case "startup_timeout_sec":
                if let timeout = Double(value) {
                    serversByName[currentName]?.startupTimeout = min(max(timeout, 1), 180)
                }
            default:
                continue
            }
        }

        return serversByName.values
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name < $1.name }
    }

    private static func parseMCPSection(_ body: String) -> (name: String, isEnv: Bool)? {
        let prefix = "mcp_servers."
        guard body.hasPrefix(prefix) else { return nil }
        var remainder = String(body.dropFirst(prefix.count))
        let isEnv = remainder.hasSuffix(".env")
        if isEnv {
            remainder.removeLast(".env".count)
        }
        if remainder.hasPrefix("\""), remainder.hasSuffix("\""), remainder.count >= 2 {
            remainder.removeFirst()
            remainder.removeLast()
        }
        return remainder.isEmpty ? nil : (remainder, isEnv)
    }

    private static func parseString(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func parseStringArray(_ raw: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inString = false
        var isEscaped = false

        for character in raw {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                if inString {
                    values.append(current)
                    current = ""
                }
                inString.toggle()
                continue
            }
            if inString {
                current.append(character)
            }
        }
        return values
    }

    private static func parseJSONObject(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8) else {
            throw AgentToolError.invalidArgument("arguments_json is not UTF-8")
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw AgentToolError.invalidArgument("arguments_json must be a JSON object")
        }
        return dict
    }

    private static func runRequest(
        server: ServerConfig,
        method: String,
        params: [String: Any]
    ) async throws -> String {
        let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
        return try await Task.detached(priority: .userInitiated) {
            try runRequestSync(server: server, method: method, paramsData: paramsData)
        }.value
    }

    nonisolated private static func runRequestSync(
        server: ServerConfig,
        method: String,
        paramsData: Data
    ) throws -> String {
        let params = try JSONSerialization.jsonObject(with: paramsData, options: [.fragmentsAllowed])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server.command)
        process.arguments = server.args

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in server.env {
            environment[key] = value
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let inbox = MCPLineInbox()
        let stderrCollector = MCPDataCollector(limit: 32_000)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            inbox.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw AgentToolError.commandFailed(-1, error.localizedDescription)
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "VeilWriter", "version": "1"]
            ]
        ], to: stdinPipe)
        _ = try waitForResponse(id: 1, inbox: inbox, timeout: server.startupTimeout, stderr: stderrCollector, process: process)

        try send([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:]
        ], to: stdinPipe)

        try send([
            "jsonrpc": "2.0",
            "id": 2,
            "method": method,
            "params": params
        ], to: stdinPipe)
        let response = try waitForResponse(id: 2, inbox: inbox, timeout: server.startupTimeout, stderr: stderrCollector, process: process)
        if let result = response["result"] {
            return prettyJSON(result)
        }
        return prettyJSON(response)
    }

    nonisolated private static func send(_ object: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.write(Data([0x0A]))
    }

    nonisolated private static func waitForResponse(
        id: Int,
        inbox: MCPLineInbox,
        timeout: TimeInterval,
        stderr: MCPDataCollector,
        process: Process
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = inbox.nextLine(until: deadline) else { break }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let dict = object as? [String: Any] else {
                continue
            }
            guard let responseID = dict["id"] as? NSNumber, responseID.intValue == id else {
                continue
            }
            if let error = dict["error"] {
                throw AgentToolError.commandFailed(-1, prettyJSON(error))
            }
            return dict
        }

        if process.isRunning {
            process.terminate()
        }
        let stderrText = stderr.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderrText.isEmpty {
            throw AgentToolError.commandTimeout
        }
        throw AgentToolError.commandFailed(-1, stderrText)
    }

    nonisolated private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        if text.count > 48_000 {
            let index = text.index(text.startIndex, offsetBy: 48_000)
            return "\(text[..<index])\n\n[truncated]"
        }
        return text
    }

    private nonisolated final class MCPLineInbox: @unchecked Sendable {
        private let condition = NSCondition()
        private var buffer = Data()
        private var lines: [String] = []

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            condition.lock()
            buffer.append(data)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8),
                   !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(line)
                }
            }
            condition.signal()
            condition.unlock()
        }

        func nextLine(until deadline: Date) -> String? {
            condition.lock()
            defer { condition.unlock() }

            while lines.isEmpty {
                guard condition.wait(until: deadline) else { return nil }
            }
            return lines.removeFirst()
        }
    }

    private nonisolated final class MCPDataCollector: @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private let lock = NSLock()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
        }

        var stringValue: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

// MARK: - Tool runner

enum AgentToolRunner {
    static func run(
        name: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        switch name {
        case "search_files":
            return try searchFiles(arguments: arguments, context: context)
        case "grep_files":
            return try grepFiles(arguments: arguments, context: context)
        case "read_file":
            return try readFile(arguments: arguments, context: context)
        case "list_directory":
            return try listDirectory(arguments: arguments, context: context)
        case "git_status":
            return try gitStatus(context: context)
        case "run_command":
            return try await runCommand(arguments: arguments, context: context)
        case "list_skills":
            return try AgentSkillCatalog.listSkills(arguments: arguments)
        case "read_skill":
            return try AgentSkillCatalog.readSkill(arguments: arguments)
        case "list_mcp_servers":
            return try AgentMCPBridge.listServers()
        case "list_mcp_tools":
            return try await AgentMCPBridge.listTools(arguments: arguments)
        case "call_mcp_tool":
            return try await AgentMCPBridge.callTool(arguments: arguments)
        default:
            throw AgentToolError.unknownTool(name)
        }
    }

    // MARK: search_files

    private static let maxFileSizeForSearch: Int = 512 * 1024
    private static let maxSearchResults = 200
    private static let maxScannedFiles = 4_000

    private static func searchFiles(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> AgentToolResult {
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        guard let query = arguments["query"]?.stringValue(),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("query")
        }
        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), maxSearchResults)

        let rootPath = root.standardizedFileURL.path
        let needle = query.lowercased()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AgentToolError.notFound(rootPath)
        }

        var matches: [String] = []
        var scanned = 0

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            scanned += 1
            if scanned > maxScannedFiles { break }
            if let size = values.fileSize, size > maxFileSizeForSearch { continue }
            if AppState.isBinaryFile(at: url) { continue }

            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            let relativePath = relativePath(of: url, root: root)
            var lineNumber = 0
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNumber += 1
                if line.lowercased().contains(needle) {
                    let snippet = line.prefix(200)
                    matches.append("\(relativePath):\(lineNumber): \(snippet)")
                    if matches.count >= limit { break }
                }
            }
            if matches.count >= limit { break }
        }

        let summary = "\(matches.count) match\(matches.count == 1 ? "" : "es") for \"\(query)\""
        let payload: String
        if matches.isEmpty {
            payload = "No matches found for \"\(query)\"."
        } else {
            payload = matches.joined(separator: "\n")
        }
        return AgentToolResult(summary: summary, payload: payload)
    }

    // MARK: grep_files

    private static func grepFiles(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> AgentToolResult {
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        guard let pattern = arguments["pattern"]?.stringValue(),
              !pattern.isEmpty else {
            throw AgentToolError.missingArgument("pattern")
        }

        var options: NSRegularExpression.Options = []
        if arguments["case_sensitive"]?.rawAny as? Bool != true {
            options.insert(.caseInsensitive)
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw AgentToolError.invalidRegex(error.localizedDescription)
        }

        let searchRoot: URL
        if let raw = arguments["path"]?.stringValue(), !raw.isEmpty {
            searchRoot = try resolveWorkspaceURL(raw, root: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: searchRoot.path, isDirectory: &isDirectory) else {
                throw AgentToolError.notFound(raw)
            }
            guard isDirectory.boolValue else {
                throw AgentToolError.notRegular(raw)
            }
        } else {
            searchRoot = root
        }

        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), maxSearchResults)
        let includeGlob = arguments["include"]?.stringValue().flatMap { $0.isEmpty ? nil : $0 }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AgentToolError.notFound(searchRoot.path)
        }

        var matches: [String] = []
        var scanned = 0

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            scanned += 1
            if scanned > maxScannedFiles { break }
            if let size = values.fileSize, size > maxFileSizeForSearch { continue }
            if let includeGlob, !globMatches(includeGlob, name: url.lastPathComponent) { continue }
            if AppState.isBinaryFile(at: url) { continue }

            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            let relativePath = relativePath(of: url, root: root)
            var lineNumber = 0
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNumber += 1
                let lineString = String(line)
                let range = NSRange(lineString.startIndex..<lineString.endIndex, in: lineString)
                if regex.firstMatch(in: lineString, options: [], range: range) != nil {
                    let snippet = lineString.prefix(200)
                    matches.append("\(relativePath):\(lineNumber): \(snippet)")
                    if matches.count >= limit { break }
                }
            }
            if matches.count >= limit { break }
        }

        let summary = "\(matches.count) match\(matches.count == 1 ? "" : "es") for /\(pattern)/"
        let payload: String
        if matches.isEmpty {
            payload = "No matches found for /\(pattern)/."
        } else {
            payload = matches.joined(separator: "\n")
        }
        return AgentToolResult(summary: summary, payload: payload)
    }

    /// Minimal shell-style glob matching against a single filename. Supports
    /// `*`, `?`, `[...]` character classes, and brace expansion (`{a,b}`).
    /// Used by `grep_files`'s `include` filter — intentionally narrow.
    private static func globMatches(_ pattern: String, name: String) -> Bool {
        for expanded in expandBraces(pattern) {
            if fnmatch(expanded, name) { return true }
        }
        return false
    }

    private static func expandBraces(_ pattern: String) -> [String] {
        guard let openIndex = pattern.firstIndex(of: "{") else { return [pattern] }
        var depth = 0
        var closeIndex: String.Index?
        var index = openIndex
        while index < pattern.endIndex {
            let ch = pattern[index]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { closeIndex = index; break }
            }
            index = pattern.index(after: index)
        }
        guard let closeIndex else { return [pattern] }
        let prefix = String(pattern[..<openIndex])
        let suffix = String(pattern[pattern.index(after: closeIndex)...])
        let body = pattern[pattern.index(after: openIndex)..<closeIndex]
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var results: [String] = []
        for part in parts {
            for nested in expandBraces(prefix + part + suffix) {
                results.append(nested)
            }
        }
        return results
    }

    private static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let s = Array(name)
        return fnmatchRecursive(p, 0, s, 0)
    }

    private static func fnmatchRecursive(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        var pi = pi
        var si = si
        while pi < p.count {
            let pc = p[pi]
            if pc == "*" {
                while pi + 1 < p.count, p[pi + 1] == "*" { pi += 1 }
                if pi == p.count - 1 { return true }
                for k in si...s.count where fnmatchRecursive(p, pi + 1, s, k) { return true }
                return false
            }
            if si >= s.count { return false }
            if pc == "?" {
                pi += 1; si += 1; continue
            }
            if pc == "[" {
                guard let end = p[pi...].firstIndex(of: "]") else { return false }
                let group = Array(p[(pi + 1)..<end])
                var matched = false
                var negated = false
                var i = 0
                if !group.isEmpty, group[0] == "!" { negated = true; i = 1 }
                while i < group.count {
                    if i + 2 < group.count, group[i + 1] == "-" {
                        if s[si] >= group[i], s[si] <= group[i + 2] { matched = true }
                        i += 3
                    } else {
                        if s[si] == group[i] { matched = true }
                        i += 1
                    }
                }
                if matched == negated { return false }
                pi = end + 1; si += 1; continue
            }
            if pc != s[si] { return false }
            pi += 1; si += 1
        }
        return si == s.count
    }

    // MARK: read_file

    private static let defaultMaxReadBytes = 64 * 1024
    private static let absoluteMaxReadBytes = 256 * 1024

    private static func readFile(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> AgentToolResult {
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        guard let path = arguments["path"]?.stringValue(),
              !path.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }

        let resolved = try resolveWorkspaceURL(path, root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw AgentToolError.notFound(path)
        }
        guard !isDirectory.boolValue else {
            throw AgentToolError.notRegular(path)
        }
        if AppState.isBinaryFile(at: resolved) {
            throw AgentToolError.binaryFile(path)
        }

        let requested = arguments["max_bytes"]?.intValue() ?? defaultMaxReadBytes
        let limit = max(1, min(requested, absoluteMaxReadBytes))

        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit + 1)
        let truncated = data.count > limit
        let usable = truncated ? data.prefix(limit) : data
        let text = String(data: usable, encoding: .utf8) ?? AppState.decodeText(from: Data(usable))

        var numbered: [String] = []
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            numbered.append(String(format: "%5d  %@", lineNumber, String(line)))
        }
        if truncated {
            numbered.append("...[truncated, read \(limit) bytes]")
        }

        let summary = "\(path) (\(lineNumber) line\(lineNumber == 1 ? "" : "s"))"
        return AgentToolResult(summary: summary, payload: numbered.joined(separator: "\n"))
    }

    // MARK: list_directory

    private static let maxDirectoryEntries = 400

    private static func listDirectory(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> AgentToolResult {
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        let rawPath = arguments["path"]?.stringValue() ?? ""
        let target: URL
        if rawPath.isEmpty {
            target = root
        } else {
            target = try resolveWorkspaceURL(rawPath, root: root)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw AgentToolError.notFound(rawPath.isEmpty ? "." : rawPath)
        }
        guard isDirectory.boolValue else {
            throw AgentToolError.notRegular(rawPath)
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sorted = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var lines: [String] = []
        for (index, url) in sorted.enumerated() {
            if index >= maxDirectoryEntries {
                lines.append("...[truncated, \(sorted.count - maxDirectoryEntries) more entries]")
                break
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let label = isDir ? "[dir]" : "[file]"
            let size = values?.fileSize.map { " \($0)B" } ?? ""
            lines.append("\(label) \(url.lastPathComponent)\(isDir ? "/" : size)")
        }

        let summary = "\(rawPath.isEmpty ? "." : rawPath) (\(sorted.count) entr\(sorted.count == 1 ? "y" : "ies"))"
        return AgentToolResult(summary: summary, payload: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"))
    }

    // MARK: git_status

    private static func gitStatus(context: AgentToolContext) throws -> AgentToolResult {
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        let status = AppState.loadGitStatus(for: root.standardizedFileURL)
        guard status.isRepository else {
            return AgentToolResult(summary: "not a git repository", payload: "The workspace is not inside a git repository.")
        }

        let branch = status.branchName ?? "detached"
        if status.entries.isEmpty {
            return AgentToolResult(
                summary: "branch \(branch), clean",
                payload: "Branch: \(branch)\nWorking tree clean."
            )
        }

        let lines = status.entries
            .sorted { $0.key < $1.key }
            .map { "\($0.value.rawValue) \($0.key)" }

        return AgentToolResult(
            summary: "branch \(branch), \(status.entries.count) change\(status.entries.count == 1 ? "" : "s")",
            payload: "Branch: \(branch)\n\(lines.joined(separator: "\n"))"
        )
    }

    // MARK: run_command

    nonisolated private static let defaultCommandTimeout: TimeInterval = 20
    nonisolated private static let maxCommandTimeout: TimeInterval = 120
    nonisolated private static let maxCommandOutput = 32 * 1024
    nonisolated static let supplementalCommandPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    nonisolated static func shellEnvironment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in supplementalCommandPathEntries where !pathEntries.contains(entry) {
            pathEntries.append(entry)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }

    private static func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        guard let command = arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        let timeoutArg = arguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultCommandTimeout
        let timeout = min(max(timeoutArg, 1), maxCommandTimeout)

        let outcome = await Task.detached(priority: .userInitiated) { () -> CommandOutcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = root
            process.environment = shellEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let outputLimit = maxCommandOutput
            let stdoutCollector = CommandOutputCollector(limit: outputLimit)
            let stderrCollector = CommandOutputCollector(limit: outputLimit)
            let runState = CommandRunState()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdoutCollector.append(data) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrCollector.append(data) }
            }
            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                return CommandOutcome(exitStatus: -1, stdout: "", stderr: error.localizedDescription, timedOut: false, launchFailed: true)
            }

            let timeoutWorkItem = DispatchWorkItem {
                runState.markTimedOut()
                if process.isRunning {
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            process.waitUntilExit()
            timeoutWorkItem.cancel()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutCollector.append(stdoutPipe.fileHandleForReading.availableData)
            stderrCollector.append(stderrPipe.fileHandleForReading.availableData)

            return CommandOutcome(
                exitStatus: process.terminationStatus,
                stdout: stdoutCollector.stringValue,
                stderr: stderrCollector.stringValue,
                timedOut: runState.didTimeout,
                launchFailed: false
            )
        }.value

        if outcome.launchFailed {
            throw AgentToolError.commandFailed(-1, outcome.stderr)
        }
        if outcome.timedOut {
            throw AgentToolError.commandTimeout
        }
        let stdout = outcome.stdout
        let stderr = outcome.stderr
        let status = outcome.exitStatus

        let combined = "exit=\(status)\n--- stdout ---\n\(stdout)\n--- stderr ---\n\(stderr)"
        let trimmed: String
        if combined.count > maxCommandOutput {
            let prefix = combined.prefix(maxCommandOutput)
            trimmed = String(prefix) + "\n...[truncated]"
        } else {
            trimmed = combined
        }

        if status != 0 {
            throw AgentToolError.commandFailed(status, trimmed)
        }

        let firstLine = stdout.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let summary = "exit 0\(firstLine.isEmpty ? "" : ": " + firstLine.prefix(60))"
        return AgentToolResult(summary: summary, payload: trimmed)
    }

    // MARK: helpers

    private struct CommandOutcome: Sendable {
        let exitStatus: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let launchFailed: Bool
    }

    private nonisolated final class CommandOutputCollector: @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private var truncated = false
        private let lock = NSLock()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        var stringValue: String {
            lock.lock()
            let snapshot = data
            let didTruncate = truncated
            lock.unlock()

            var text = String(data: snapshot, encoding: .utf8) ?? AppState.decodeText(from: snapshot)
            if didTruncate {
                text += "\n...[truncated]"
            }
            return text
        }
    }

    private nonisolated final class CommandRunState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var didTimeout: Bool {
            lock.lock()
            let value = timedOut
            lock.unlock()
            return value
        }
    }

    private static func resolveWorkspaceURL(_ path: String, root: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let url: URL
        if (trimmed as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else {
            url = root.appendingPathComponent(trimmed).standardizedFileURL
        }
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw AgentToolError.pathOutsideWorkspace(path)
        }
        return url
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
