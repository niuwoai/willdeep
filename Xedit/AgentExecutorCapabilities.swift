//
//  AgentExecutorCapabilities.swift
//  WillDeep
//
//  Explicit transport selection for delegated coding agents.
//

import Foundation

nonisolated enum AgentExecutorTransport: String, Codable, Equatable, Sendable {
    case agentClientProtocol = "agent_client_protocol"
    case codexAppServer = "codex_app_server"
    case structuredProcess = "structured_process"
    case daemonProcess = "daemon_process"
    case visibleTerminal = "visible_terminal"
    case shellCompatibility = "shell_compatibility"
}

nonisolated struct AgentExecutorCapabilities: Codable, Equatable, Sendable {
    let transport: AgentExecutorTransport
    let structuredEvents: Bool
    let promptViaStandardInput: Bool
    let resumableSession: Bool
    let persistentSession: Bool
    let hostApprovals: Bool
    let reverseFileSystem: Bool
    let reverseTerminal: Bool
}

nonisolated enum AgentExecutorCapabilityResolver {
    static func select(
        executor: AgentExecutionAgent,
        isRemote: Bool,
        usesDaemon: Bool,
        usesVisibleTerminal: Bool,
        hasHostApproval: Bool,
        hasACPAdapter: Bool
    ) -> AgentExecutorCapabilities {
        if usesVisibleTerminal {
            return profile(
                transport: .visibleTerminal,
                structured: false,
                stdin: false,
                resumable: false
            )
        }
        if isRemote {
            if usesDaemon,
               executor == .claudeCode || executor == .codexCLI {
                return profile(
                    transport: .daemonProcess,
                    structured: true,
                    stdin: true,
                    resumable: true
                )
            }
            return profile(
                transport: .shellCompatibility,
                structured: false,
                stdin: false,
                resumable: false
            )
        }

        switch executor {
        case .claudeCode where hasHostApproval && hasACPAdapter:
            return AgentExecutorCapabilities(
                transport: .agentClientProtocol,
                structuredEvents: true,
                promptViaStandardInput: true,
                resumableSession: true,
                persistentSession: true,
                hostApprovals: true,
                reverseFileSystem: true,
                reverseTerminal: true
            )
        case .codexCLI where hasHostApproval:
            return AgentExecutorCapabilities(
                transport: .codexAppServer,
                structuredEvents: true,
                promptViaStandardInput: true,
                resumableSession: true,
                persistentSession: false,
                hostApprovals: true,
                reverseFileSystem: false,
                reverseTerminal: false
            )
        case .claudeCode, .codexCLI:
            return profile(
                transport: .structuredProcess,
                structured: true,
                stdin: true,
                resumable: true
            )
        case .hermesCLI, .cursorAgent, .clineCLI, .willDeep:
            return profile(
                transport: .shellCompatibility,
                structured: false,
                stdin: false,
                resumable: false
            )
        }
    }

    private static func profile(
        transport: AgentExecutorTransport,
        structured: Bool,
        stdin: Bool,
        resumable: Bool
    ) -> AgentExecutorCapabilities {
        AgentExecutorCapabilities(
            transport: transport,
            structuredEvents: structured,
            promptViaStandardInput: stdin,
            resumableSession: resumable,
            persistentSession: false,
            hostApprovals: false,
            reverseFileSystem: false,
            reverseTerminal: false
        )
    }
}

extension AgentToolRunner {
    nonisolated static func claudeCodeCLIPermissionMode(
        _ requestedMode: String
    ) -> String {
        requestedMode == "default" ? "dontAsk" : requestedMode
    }

    nonisolated static func claudeCodeACPExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> String? {
        executablePath(
            commandName: "claude-code-acp",
            preferredPaths: [
                "/opt/homebrew/bin/claude-code-acp",
                "/usr/local/bin/claude-code-acp",
                "\(NSHomeDirectory())/.local/bin/claude-code-acp",
            ],
            environment: environment,
            isExecutable: isExecutable
        )
    }

    nonisolated static func executablePath(
        commandName: String,
        preferredPaths: [String],
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

        preferredPaths.forEach(append)
        for entry in (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init) {
            append("\(entry)/\(commandName)")
        }
        return candidates.first(where: isExecutable)
    }

    nonisolated static func structuredUsageSummary(
        _ usage: AgentExecutorUsage?
    ) -> String {
        guard let usage else { return "" }
        var parts: [String] = []
        if let input = usage.inputTokens {
            parts.append("in \(input)")
        }
        if let output = usage.outputTokens {
            parts.append("out \(output)")
        }
        if let cost = usage.costUSD {
            parts.append(String(format: "$%.4f", cost))
        }
        return parts.isEmpty
            ? ""
            : " · " + parts.joined(separator: " · ")
    }

    nonisolated static func delegatedAgentSessionID(
        _ arguments: [String: AgentJSONValue]
    ) -> String? {
        guard let value = arguments["session_id"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated static func delegatedImagePaths(
        _ arguments: [String: AgentJSONValue],
        fileManager: FileManager = .default
    ) -> [String] {
        guard let candidates = arguments["image_paths"]?
            .stringArrayValue() else {
            return []
        }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL.path + "/"
        return candidates.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let directory = url.deletingLastPathComponent()
            guard url.path.hasPrefix(temporaryRoot),
                  directory.lastPathComponent.hasPrefix(
                    AgentDelegatedImageBundle.directoryPrefix
                  ),
                  fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            return url.path
        }
    }
}
