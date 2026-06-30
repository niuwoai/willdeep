//
//  AgentTerminalTools.swift
//  WillDeep
//
//  Built-in tools for the visible Agent-mode interactive terminal.
//

import Foundation

enum AgentTerminalTools {
    static func snapshot(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        let maxCharacters = min(max(arguments["max_characters"]?.intValue() ?? 6_000, 500), 12_000)
        let snapshot = await MainActor.run {
            controller.snapshot(maxCharacters: maxCharacters)
        }
        let running = snapshot.isRunning ? "connected" : "disconnected"
        let target = snapshot.runtimeTarget.isEmpty ? "" : " (\(snapshot.runtimeTarget))"
        let pending = snapshot.pendingCommands.isEmpty
            ? "none"
            : snapshot.pendingCommands.joined(separator: "\n")
        let recent = snapshot.recentCommands.isEmpty
            ? "none"
            : snapshot.recentCommands.joined(separator: "\n")
        let payload = """
        Agent Terminal: \(running)
        Runtime: \(snapshot.runtimeName)\(target)
        Pending auto commands:
        \(pending)

        Recent AI/auto commands:
        \(recent)

        --- latest visible screen ---
        \(snapshot.output.isEmpty ? "(no terminal output captured)" : snapshot.output)
        """
        return AgentToolResult(summary: "terminal \(running): \(snapshot.runtimeName)", payload: payload)
    }

    static func sendCommand(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        guard let command = arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        return try await MainActor.run {
            try controller.sendApprovedCommand(command, secretRedactionValues: context.secretRedactionValues)
        }
    }

    static func sendControl(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        guard let raw = arguments["control"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let control = AgentTerminalControl(rawValue: raw) else {
            throw AgentToolError.invalidArgument("control must be one of: \(AgentTerminalControl.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return try await MainActor.run {
            try controller.sendApprovedControl(control)
        }
    }
}
