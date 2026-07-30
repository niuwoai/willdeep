//
//  LocalAgentCLI.swift
//  WillDeep
//
//  Lightweight discovery catalog for local coding-agent CLIs shown in
//  Settings. Discovery only checks executable paths; it never launches
//  the external tools.
//

import Foundation

nonisolated struct LocalAgentCLIProfile: Identifiable, Equatable {
    nonisolated enum Configuration: Equatable {
        case codexConfig(name: String)
        case claudeAgent(name: String)
        case hermesProfile(name: String)
        case generic
    }

    let id: String
    let displayName: String
    let executor: AgentExecutionAgent
    let configuration: Configuration
    let modelID: String?
    let providerID: String?

    var argument: (name: String, value: String)? {
        switch configuration {
        case .codexConfig(let name):
            return name.isEmpty ? nil : ("profile", name)
        case .claudeAgent(let name):
            return name.isEmpty ? nil : ("agent", name)
        case .hermesProfile(let name):
            return ("hermes_profile", name.isEmpty ? "default" : name)
        case .generic:
            return nil
        }
    }

    var nativeProfileName: String? {
        switch configuration {
        case .codexConfig(let name), .claudeAgent(let name), .hermesProfile(let name):
            return name.isEmpty ? nil : name
        case .generic:
            return nil
        }
    }

    init(
        id: String,
        displayName: String,
        executor: AgentExecutionAgent,
        configuration: Configuration,
        modelID: String? = nil,
        providerID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.executor = executor
        self.configuration = configuration
        self.modelID = modelID
        self.providerID = providerID
    }

    nonisolated static func discover(
        workspacePath: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexHomeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [LocalAgentCLIProfile] {
        let codexDirectory = codexHomeDirectory
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let codexProfiles = namedFiles(
            in: codexDirectory,
            suffix: ".config.toml",
            fileManager: fileManager
        ).map { name in
            LocalAgentCLIProfile(
                id: "codex:\(name)",
                displayName: name,
                executor: .codexCLI,
                configuration: .codexConfig(name: name),
                modelID: modelValue(
                    in: codexDirectory.appendingPathComponent("\(name).config.toml"),
                    key: "model",
                    fileManager: fileManager
                )
            )
        }

        var claudeDirectories = [
            homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true),
        ]
        if let workspacePath, !workspacePath.isEmpty {
            claudeDirectories.append(
                URL(fileURLWithPath: workspacePath, isDirectory: true)
                    .appendingPathComponent(".claude", isDirectory: true)
                    .appendingPathComponent("agents", isDirectory: true)
            )
        }
        var seenClaudeNames: Set<String> = []
        let claudeProfiles = claudeDirectories.flatMap {
            namedFiles(in: $0, suffix: ".md", fileManager: fileManager)
        }
        .filter { seenClaudeNames.insert($0).inserted }
        .sorted()
        .map { name in
            LocalAgentCLIProfile(
                id: "claude-agent:\(name)",
                displayName: name,
                executor: .claudeCode,
                configuration: .claudeAgent(name: name)
            )
        }

        let hermesRoot = homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
        let hermesProfileNames = ["default"] + (
            (try? fileManager.contentsOfDirectory(
                atPath: hermesRoot.appendingPathComponent("profiles", isDirectory: true).path
            )) ?? []
        )
        let hermesProfiles = Array(Set(hermesProfileNames))
            .filter(profileNameIsSafe)
            .sorted()
            .map { name in
                let profileRoot = name == "default"
                    ? hermesRoot
                    : hermesRoot
                        .appendingPathComponent("profiles", isDirectory: true)
                        .appendingPathComponent(name, isDirectory: true)
                return LocalAgentCLIProfile(
                    id: "hermes:\(name)",
                    displayName: name,
                    executor: .hermesCLI,
                    configuration: .hermesProfile(name: name),
                    modelID: yamlModelValue(
                        in: profileRoot.appendingPathComponent("config.yaml"),
                        fileManager: fileManager
                    )
                )
            }

        return codexProfiles + claudeProfiles + hermesProfiles
    }

    nonisolated private static func namedFiles(
        in directory: URL,
        suffix: String,
        fileManager: FileManager
    ) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.compactMap { fileName in
            guard fileName.hasSuffix(suffix), fileName.count > suffix.count else {
                return nil
            }
            let name = String(fileName.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return profileNameIsSafe(name) ? name : nil
        }
        .sorted()
    }

    nonisolated static func profileNameIsSafe(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    nonisolated private static func modelValue(
        in url: URL,
        key: String,
        fileManager: FileManager
    ) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let prefix = "\(key) ="
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(prefix) else { continue }
            return quotedValue(String(line.dropFirst(prefix.count)))
        }
        return nil
    }

    nonisolated private static func yamlModelValue(
        in url: URL,
        fileManager: FileManager
    ) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var insideModel = false
        for rawLine in content.components(separatedBy: .newlines) {
            if !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t") {
                insideModel = rawLine.trimmingCharacters(in: .whitespaces) == "model:"
                continue
            }
            guard insideModel else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("default:") else { continue }
            return quotedValue(String(line.dropFirst("default:".count)))
        }
        return nil
    }

    nonisolated private static func quotedValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct LocalAgentCLI: Identifiable, Equatable {
    nonisolated enum Integration: Equatable, Sendable {
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
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "\(NSHomeDirectory())/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ],
            integration: .directTool("codex_cli")
        ),
        LocalAgentCLI(
            id: "hermes-cli",
            displayName: "Hermes",
            commandName: "hermes",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/hermes",
                "/opt/homebrew/bin/hermes",
                "/usr/local/bin/hermes"
            ],
            integration: .directTool("hermes_cli")
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
            // Prefer the standalone `cursor-agent` (its own installer drops it
            // in ~/.local/bin and ships no `cursor` command); fall back to the
            // `cursor` editor launcher, which forwards `agent` to the same CLI.
            commandName: "cursor-agent",
            commonPaths: [
                "\(NSHomeDirectory())/.local/bin/cursor-agent",
                "/opt/homebrew/bin/cursor-agent",
                "/usr/local/bin/cursor-agent",
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
