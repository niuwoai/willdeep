//
//  AgentToolAuthorization.swift
//  VeilWriter
//
//  Always-allow signature derivation for tool calls. Three pieces:
//   - `AgentAlwaysAllowedCommand`: the persisted "remember this command"
//     record (id + signature + createdAt) wired into AppState.
//   - `AgentCommandAuthorization`: derives a normalized signature like
//     "git status" / "yarn run build" / "ls" from a raw `run_command`
//     string, so the auto-allow comparison is structural rather than a
//     textual match. Holds its own private `shellTokens` (the conservative
//     no-pipeline tokenizer); the broader read-only-shell classifier in
//     AgentToolRegistry has a different, more permissive copy.
//   - `AgentToolAuthorization`: tool-level entry point that picks the
//     right signature scheme by tool name. `run_command` falls back to
//     AgentCommandAuthorization; `call_mcp_tool` returns
//     `mcp:<server>:<tool>` so pinning an MCP tool auto-approves every
//     future call to that exact server.tool pair regardless of
//     arguments. Returns nil for tools we don't know how to scope
//     (file_write, file_patch, …) — those still gate per-call.
//

import Foundation

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

    /// Trim once and check non-empty, used by MCP signature derivation.
    fileprivate static func cleaned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

/// Tool-level always-allow signature. Decides per tool name how to
/// scope the "remember this" rule:
///  - `run_command` → command-family signature ("git push") via
///    AgentCommandAuthorization.
///  - `call_mcp_tool` → "mcp:<server>:<tool>", so the same server.tool
///    pair auto-approves regardless of `arguments_json`. Arguments are
///    intentionally not part of the signature — the user pinning a
///    specific MCP tool means "I trust this tool, run it again", not
///    "exactly this query string".
///  - everything else → nil (the Always Allow button hides; the user
///    still has to click Allow per call). file_write / file_patch /
///    file_remove are deliberately not pinnable because their blast
///    radius depends entirely on the path argument.
enum AgentToolAuthorization {
    static func signature(toolName: String, arguments: [String: AgentJSONValue]) -> String? {
        switch toolName {
        case "run_command":
            guard let command = arguments["command"]?.stringValue() else { return nil }
            return AgentCommandAuthorization.signature(for: command)
        case "call_mcp_tool":
            guard let rawServer = arguments["server"]?.stringValue(),
                  let rawTool = arguments["tool"]?.stringValue(),
                  let server = AgentCommandAuthorization.cleaned(rawServer),
                  let tool = AgentCommandAuthorization.cleaned(rawTool) else {
                return nil
            }
            return "mcp:\(server.lowercased()):\(tool)"
        default:
            return nil
        }
    }

    static func signature(for call: AgentToolCall) -> String? {
        signature(toolName: call.toolName, arguments: call.arguments)
    }
}
