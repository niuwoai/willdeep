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
    /// Runtime that's executing this tool — used by background-job
    /// tools to scope jobs to the originating session. Nil in
    /// non-conversational call paths (tests, ad-hoc skill harness).
    let runtimeID: UUID?
    /// Shared background-job registry. Nil in non-app call paths;
    /// when nil, `run_command` with `run_in_background: true` falls
    /// back to the foreground path so behavior is still defined.
    let jobRegistry: AgentJobRegistry?

    init(
        rootDirectory: URL?,
        runtimeID: UUID? = nil,
        jobRegistry: AgentJobRegistry? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.runtimeID = runtimeID
        self.jobRegistry = jobRegistry
    }
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

// MARK: - Tool call record (UI state)

/// How a write-tier tool call ended up running. `.user` covers both the
/// per-call Allow button and the legacy auto-allow path. `.alwaysAllowList`
/// means the user previously pinned this command signature. `.staticAllowlist`
/// means the SafeCommand classifier flagged it as read-only. `.llmJudge`
/// means the LLM judge classifier approved it. `.goalMode` means the
/// session was in Goal mode, which auto-approves write-tier calls
/// (danger-tier still gates on the user). nil = either pure read
/// (never gated) or still pending.
enum AgentToolApprovalSource: String, Equatable, Codable {
    case user
    case alwaysAllowList
    case staticAllowlist
    case llmJudge
    case goalMode
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
        case "claude_code":
            return try await claudeCode(arguments: arguments, context: context)
        case "list_jobs":
            return try await listJobs(arguments: arguments, context: context)
        case "get_job_output":
            return try await getJobOutput(arguments: arguments, context: context)
        case "kill_job":
            return try await killJob(arguments: arguments, context: context)
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

        // Background path: hand the Process off to the registry, return
        // immediately with the job handle, let the agent loop pull the
        // completion event at the top of a later turn.
        let wantsBackground = arguments["run_in_background"]?.boolValue() ?? false
        if wantsBackground, let registry = context.jobRegistry, let runtimeID = context.runtimeID {
            let bgTimeout: Double? = arguments["timeout_seconds"]?.intValue().map { Double(min(max($0, 1), 3600 * 6)) }
            let job: AgentBackgroundJob
            do {
                job = try await MainActor.run {
                    try registry.start(
                        command: command,
                        workingDirectory: root,
                        runtimeID: runtimeID,
                        timeoutSeconds: bgTimeout
                    )
                }
            } catch {
                throw AgentToolError.commandFailed(-1, error.localizedDescription)
            }
            let cwd = job.workingDirectoryPath ?? root.path
            let timeoutLine = bgTimeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            let payload = """
            Started background job \(job.displayHandle).
            Command: \(command)
            PID: \(job.pid)
            cwd: \(cwd)\(timeoutLine)

            The job is running. You will receive a `<background-task-notification>` system message at the start of a later turn when it finishes (or fails). Until then, call `get_job_output` to inspect partial output, `list_jobs` to see all alive jobs, or `kill_job` to stop it.
            """
            return AgentToolResult(
                summary: "▶ \(job.displayHandle) started",
                payload: payload
            )
        }

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

    // MARK: claude_code

    /// Permission modes we forward to `claude -p`. Deliberately NOT
    /// including `bypassPermissions` — headless full-bypass from a
    /// model-initiated tool call is an instruction-injection foot-gun.
    nonisolated static let claudeCodePermissionModes: Set<String> = ["plan", "acceptEdits", "default"]

    /// Locate the Claude Code CLI. Checks the native-installer location
    /// (`~/.local/bin`) and the legacy alias first, then every PATH
    /// entry from the augmented shell environment. Returns an absolute
    /// path so the composed command doesn't depend on PATH at run time.
    nonisolated static func claudeCodeExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(entry)/claude")
        }
        return candidates.first(where: isExecutable)
    }

    /// POSIX single-quote escaping: safe to embed arbitrary text
    /// (including the task prompt) into a `/bin/sh -c` command line.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func claudeCodeCommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?
    ) -> String {
        var parts = [
            shellQuoted(executable),
            "-p", shellQuoted(prompt),
            "--output-format", "text",
            "--permission-mode", permissionMode,
        ]
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        return parts.joined(separator: " ")
    }

    /// Delegate a task to the Claude Code CLI in headless mode. Thin
    /// composer over `runCommand`: builds the `claude -p …` command
    /// line, then rides the exact same foreground/background plumbing
    /// (job registry, output buffers, kill, completion notifications).
    private static func claudeCode(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }

        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "acceptEdits"
        guard claudeCodePermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(claudeCodePermissionModes.sorted().joined(separator: ", "))"
            )
        }

        guard let executable = claudeCodeExecutablePath() else {
            throw AgentToolError.commandFailed(
                127,
                "Claude Code CLI not found on this Mac. Install it first (e.g. `npm install -g @anthropic-ai/claude-code` or the native installer from https://claude.com/claude-code), then retry. Tell the user instead of retrying blindly."
            )
        }

        let command = claudeCodeCommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue()
        )

        // Claude Code tasks routinely run for minutes — default to the
        // background path so the parent turn isn't pinned to the 120s
        // foreground ceiling. Callers can still force foreground for
        // genuinely quick questions.
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? true
        var forwarded: [String: AgentJSONValue] = [
            "command": .string(command),
            "run_in_background": .bool(runInBackground),
        ]
        if let timeout = arguments["timeout_seconds"]?.intValue() {
            forwarded["timeout_seconds"] = .number(Double(timeout))
        } else if runInBackground {
            forwarded["timeout_seconds"] = .number(1800)
        }
        return try await runCommand(arguments: forwarded, context: context)
    }

    // MARK: list_jobs / get_job_output / kill_job

    /// Snapshot of background jobs for the current runtime. Returns a
    /// stable text format (one job per line) so the model can quote
    /// handles back into `get_job_output` / `kill_job` without parsing
    /// JSON.
    private static func listJobs(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            return AgentToolResult(summary: "no jobs", payload: "Background job registry not available in this context.")
        }
        let onlyAlive = arguments["only_alive"]?.boolValue() ?? false
        let allJobs = await MainActor.run { registry.jobs(forRuntime: runtimeID) }
        let filtered = onlyAlive ? allJobs.filter { $0.isAlive } : allJobs
        guard !filtered.isEmpty else {
            return AgentToolResult(
                summary: "no jobs",
                payload: onlyAlive ? "No alive background jobs." : "No background jobs in this session."
            )
        }
        let lines = filtered.map { describe(job: $0) }
        let payload = lines.joined(separator: "\n")
        let aliveCount = filtered.filter { $0.isAlive }.count
        let summary = "\(filtered.count) job\(filtered.count == 1 ? "" : "s") (\(aliveCount) alive)"
        return AgentToolResult(summary: summary, payload: payload)
    }

    private static func getJobOutput(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let tailLines = arguments["tail_lines"]?.intValue()
        let snapshot: (job: AgentBackgroundJob, output: String)? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            return (job, registry.output(id: job.id, tailLines: tailLines))
        }
        guard let snapshot else {
            throw AgentJobError.jobNotFound(handle)
        }
        let header = describe(job: snapshot.job)
        let body = snapshot.output.isEmpty ? "(no output captured yet)" : snapshot.output
        return AgentToolResult(
            summary: "\(snapshot.job.displayHandle): \(snapshot.job.status.rawValue)",
            payload: "\(header)\n--- output ---\n\(body)"
        )
    }

    private static func killJob(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let result: (job: AgentBackgroundJob, didSignal: Bool)? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            let signaled = registry.kill(id: job.id)
            return (job, signaled)
        }
        guard let result else {
            throw AgentJobError.jobNotFound(handle)
        }
        if result.didSignal {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) killed",
                payload: "Sent SIGTERM to \(result.job.displayHandle) (pid \(result.job.pid)). A completion notice will arrive on the next turn."
            )
        } else {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) not running",
                payload: "\(result.job.displayHandle) was already \(result.job.status.rawValue); nothing to kill."
            )
        }
    }

    private static func describe(job: AgentBackgroundJob) -> String {
        let exit = job.exitCode.map { "exit=\($0)" } ?? "exit=…"
        let durationText = formatDuration(job.duration)
        let trimmedCommand = job.command.count > 100
            ? String(job.command.prefix(100)) + "…"
            : job.command
        return "\(job.displayHandle) [\(job.status.rawValue)] \(exit) · \(durationText) · pid=\(job.pid) · \(trimmedCommand)"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        if m < 60 { return "\(m)m\(s)s" }
        let h = m / 60
        let mm = m % 60
        return "\(h)h\(mm)m"
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
