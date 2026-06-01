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

// MARK: - Tool call record (UI state)

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

    init(
        id: UUID = UUID(),
        messageID: UUID,
        externalID: String,
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        status: AgentToolCallStatus,
        result: AgentToolResult? = nil,
        errorMessage: String? = nil
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
            name: "ask_user",
            description: "Ask the user a clarifying question and wait for their answer before continuing. Use this whenever a required piece of information is missing or ambiguous; do not guess. Returns the user's typed answer as the tool result.",
            risk: .userInput,
            parameters: [
                AgentToolParameter(name: "question", type: .string, description: "The clarifying question to show the user.", required: true)
            ]
        )
    ]

    static func descriptor(for name: String) -> AgentToolDescriptor? {
        all.first { $0.name == name }
    }

    /// Classify a `run_command` invocation: bumps to .danger when the command
    /// matches a destructive pattern. All other tools use their declared risk.
    static func risk(for name: String, arguments: [String: AgentJSONValue]) -> AgentToolRisk {
        guard let descriptor = descriptor(for: name) else { return .danger }
        if descriptor.name == "run_command", let command = arguments["command"]?.stringValue() {
            if looksDangerous(command: command) {
                return .danger
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
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AgentToolError.notFound(rootPath)
        }

        var matches: [String] = []
        var scanned = 0

        for case let url as URL in enumerator {
            scanned += 1
            if scanned > maxScannedFiles { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
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
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AgentToolError.notFound(searchRoot.path)
        }

        var matches: [String] = []
        var scanned = 0

        for case let url as URL in enumerator {
            scanned += 1
            if scanned > maxScannedFiles { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
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

    private static let defaultCommandTimeout: TimeInterval = 20
    private static let maxCommandTimeout: TimeInterval = 120
    private static let maxCommandOutput = 32 * 1024

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

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return CommandOutcome(exitStatus: -1, stdout: "", stderr: error.localizedDescription, timedOut: false, launchFailed: true)
            }

            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            process.waitUntilExit()
            let didTimeout = timeoutWorkItem.isCancelled == false && process.terminationReason == .uncaughtSignal
            timeoutWorkItem.cancel()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            return CommandOutcome(
                exitStatus: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: didTimeout,
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
