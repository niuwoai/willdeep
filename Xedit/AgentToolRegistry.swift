//
//  AgentToolRegistry.swift
//  VeilWriter
//
//  Tool catalog + per-call risk classifier, split out of
//  AgentTools.swift in rc42. Two responsibilities:
//   - `static let all`: the descriptor list (name, description, risk
//     tier, parameter schema) the LLM sees as the available tool surface.
//   - `risk(for:arguments:rootDirectory:)`: per-call risk override. The
//     declared risk in `all` is the upper bound; this method downgrades
//     a `run_command` to .read when the classifier proves the shell
//     chain is read-only inside the workspace, or bumps to .danger on
//     destructive patterns. The classifier carries its own shell
//     tokenizer / chain splitter / per-executable allowlist (git
//     subcommands, sed without -i, find without -exec, etc.) — kept
//     private here because it's tightly coupled to the read-only
//     auto-allow decision and has no other consumers.
//

import Foundation

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
            description: "Run a shell command in the workspace root. Requires user approval. Refuses commands that escape the workspace. Pass `run_in_background: true` for long-running tasks (dev servers, watchers, big builds, test suites that take minutes) — the call returns immediately with a job handle and you receive a system notification when the job finishes; meanwhile inspect partial output with `get_job_output` or stop it with `kill_job`.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "command", type: .string, description: "Shell command line. Runs through /bin/sh -c.", required: true),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Hard timeout in seconds. Foreground default 20s (max 120). Background default unlimited (max 21600 = 6h).", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "When true, do not block on the command. Returns a job handle (job_xxxxxx); the host injects a system message when the job finishes. Use for tasks expected to take more than ~30 seconds. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "list_jobs",
            description: "List background shell jobs spawned via `run_command` with `run_in_background: true` in this session, including their status and short handles. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "only_alive", type: .boolean, description: "When true, only return jobs whose status is still `running`. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "get_job_output",
            description: "Read the captured stdout/stderr buffer for a background job. Pass the short handle (e.g. `job_ab12cd`) or full UUID. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "job_id", type: .string, description: "Job handle from `list_jobs` or the `run_command` response (e.g. `job_ab12cd`).", required: true),
                AgentToolParameter(name: "tail_lines", type: .integer, description: "Only return the last N lines of output. Omit to return the full buffer.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "kill_job",
            description: "Send SIGTERM (then SIGKILL after 2s) to a background job spawned via `run_command`. Returns immediately; the actual exit notice arrives via the usual completion system message.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "job_id", type: .string, description: "Job handle from `list_jobs` or the `run_command` response (e.g. `job_ab12cd`).", required: true)
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
            description: "Call a tool on a configured MCP server with JSON arguments. Read-style calls (get_/list_/search_… tool names, or calls an LLM judge certifies as read-only) auto-run on trusted servers; other calls require user approval because MCP tools may perform writes or network actions.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "server", type: .string, description: "MCP server name from list_mcp_servers.", required: true),
                AgentToolParameter(name: "tool", type: .string, description: "MCP tool name from list_mcp_tools.", required: true),
                AgentToolParameter(name: "arguments_json", type: .string, description: "JSON object string to pass as the MCP tool arguments. Defaults to {}.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "claude_code",
            description: "Delegate a complex coding task to the locally installed Claude Code CLI (headless `claude -p`). Unlike spawn_agent, Claude Code CAN edit files, run builds/tests, and work multi-step inside the workspace — use it for self-contained implementation tasks you want done end-to-end. Requires user approval. The prompt must be fully self-contained: Claude Code sees the workspace files but not this conversation. Prefer `permission_mode: \"plan\"` when you only want an implementation plan without any file changes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task description. Include relevant file paths, acceptance criteria, and constraints — Claude Code cannot ask follow-up questions in headless mode.", required: true),
                AgentToolParameter(name: "permission_mode", type: .string, description: "One of `plan` (read-only, returns a plan), `acceptEdits` (may create/edit files in the workspace), `default` (permission-needing actions are auto-denied). Defaults to acceptEdits.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional Claude model alias forwarded as `--model` (e.g. `sonnet`, `opus`, `haiku`).", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "Defaults to true: returns a job handle (job_xxxxxx) and the result arrives as a background-task notification; inspect progress with get_job_output. Set false only for quick questions (120s foreground ceiling).", required: false),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Hard timeout. Background default 1800 (max 21600); foreground capped at 120.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "spawn_agent",
            description: "Spawn a read-only subagent to work on a self-contained task (codebase exploration, research, summarizing many files) and return its findings. The subagent runs its own tool loop against the same workspace but can only read — search/grep/read/list plus read-only shell commands; it cannot write files, ask the user, or spawn further agents. Use it to keep large exploration out of your own context. The prompt must be self-contained: the subagent does not see this conversation.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task description for the subagent. Include all needed context — it cannot see the parent conversation or ask questions.", required: true),
                AgentToolParameter(name: "label", type: .string, description: "Short display label for the UI (e.g. `explore-auth-flow`). Defaults to a prompt prefix.", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "When true, return immediately with an agent handle (agent_xxxxxx); the report is injected as a system message when the subagent finishes. Up to 3 subagents may run in parallel per session. Defaults to false (wait for the report inline).", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional model id override for the subagent (same provider). Use a cheaper/faster model for broad exploration.", required: false)
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
