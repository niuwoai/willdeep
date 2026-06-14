//
//  LocalAgentCLI.swift
//  WillDeep
//
//  Lightweight discovery catalog for local coding-agent CLIs shown in
//  Settings. Discovery only checks executable paths; it never launches
//  the external tools.
//

import Foundation

struct LocalAgentCLI: Identifiable, Equatable {
    enum Integration: Equatable {
        case directTool(String)
        case discoveryOnly

        var isDirectlyCallable: Bool {
            switch self {
            case .directTool: return true
            case .discoveryOnly: return false
            }
        }
    }

    struct Discovery: Identifiable, Equatable {
        let cli: LocalAgentCLI
        let path: String?

        var id: String { cli.id }
        var isInstalled: Bool { path != nil }
    }

    let id: String
    let displayName: String
    let commandName: String
    let commonPaths: [String]
    let integration: Integration

    static let catalog: [LocalAgentCLI] = [
        LocalAgentCLI(
            id: "claude-code",
            displayName: "Claude Code",
            commandName: "claude",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/claude",
                "\(NSHomeDirectory())/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ],
            integration: .directTool("claude_code")
        ),
        LocalAgentCLI(
            id: "codex-cli",
            displayName: "Codex CLI",
            commandName: "codex",
            commonPaths: [
                "/Applications/Codex.app/Contents/Resources/codex",
                "\(NSHomeDirectory())/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ],
            integration: .directTool("codex_cli")
        ),
        LocalAgentCLI(
            id: "opencode",
            displayName: "OpenCode",
            commandName: "opencode",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode"
            ],
            integration: .discoveryOnly
        ),
        LocalAgentCLI(
            id: "aider",
            displayName: "Aider",
            commandName: "aider",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/aider",
                "/opt/homebrew/bin/aider",
                "/usr/local/bin/aider"
            ],
            integration: .discoveryOnly
        ),
        LocalAgentCLI(
            id: "gemini-cli",
            displayName: "Gemini CLI",
            commandName: "gemini",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/gemini",
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini"
            ],
            integration: .discoveryOnly
        ),
        LocalAgentCLI(
            id: "qwen-code",
            displayName: "Qwen Code",
            commandName: "qwen",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/qwen",
                "/opt/homebrew/bin/qwen",
                "/usr/local/bin/qwen"
            ],
            integration: .discoveryOnly
        ),
        LocalAgentCLI(
            id: "cursor-cli",
            displayName: "Cursor CLI",
            commandName: "cursor",
            commonPaths: [
                "/usr/local/bin/cursor",
                "/opt/homebrew/bin/cursor"
            ],
            integration: .directTool("cursor_agent")
        ),
        LocalAgentCLI(
            id: "cline-cli",
            displayName: "Cline CLI",
            commandName: "cline",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/cline",
                "/opt/homebrew/bin/cline",
                "/usr/local/bin/cline"
            ],
            integration: .directTool("cline_cli")
        ),
        LocalAgentCLI(
            id: "goose",
            displayName: "Goose",
            commandName: "goose",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/goose",
                "/opt/homebrew/bin/goose",
                "/usr/local/bin/goose"
            ],
            integration: .discoveryOnly
        ),
        LocalAgentCLI(
            id: "amp",
            displayName: "Amp",
            commandName: "amp",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/amp",
                "/opt/homebrew/bin/amp",
                "/usr/local/bin/amp"
            ],
            integration: .discoveryOnly
        ),
        LocalAgentCLI(
            id: "crush",
            displayName: "Crush",
            commandName: "crush",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/crush",
                "/opt/homebrew/bin/crush",
                "/usr/local/bin/crush"
            ],
            integration: .discoveryOnly
        )
    ]

    static func discoverAll(
        environment: [String: String] = AgentToolRunner.shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [Discovery] {
        catalog.map { cli in
            Discovery(cli: cli, path: executablePath(for: cli, environment: environment, isExecutable: isExecutable))
        }
    }

    private static func executablePath(
        for cli: LocalAgentCLI,
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> String? {
        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            candidates.append(path)
        }

        cli.commonPaths.forEach(append)
        for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            append("\(entry)/\(cli.commandName)")
        }

        return candidates.first(where: isExecutable)
    }
}
