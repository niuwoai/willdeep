//
//  AgentTerminalTools.swift
//  WillDeep
//
//  Built-in tools for the visible Agent-mode interactive terminal.
//

import Foundation

enum AgentTerminalTools {
    static func createShortcut(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        guard let title = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw AgentToolError.missingArgument("title")
        }
        let events = try parseCreateEvents(arguments)
        let created = try await MainActor.run {
            try controller.createShortcut(title: title, events: events)
        }
        let payload = try jsonString(shortcutSummary(created, maxTextCharacters: 600))
        return AgentToolResult(
            summary: "terminal shortcut created: \(created.title)",
            payload: payload
        )
    }

    static func listShortcuts(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        let maxTextCharacters = min(max(arguments["max_text_characters"]?.intValue() ?? 400, 80), 4_000)
        let requestedID = arguments["shortcut_id"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortcuts = await MainActor.run {
            controller.shortcuts
        }
        let filtered = shortcuts.filter { shortcut in
            guard let requestedID, !requestedID.isEmpty else { return true }
            return shortcut.id.uuidString == requestedID
        }
        let payload = try jsonString(
            filtered.map { shortcut in
                shortcutSummary(shortcut, maxTextCharacters: maxTextCharacters)
            }
        )
        return AgentToolResult(
            summary: "terminal shortcuts: \(filtered.count)",
            payload: payload
        )
    }

    static func editShortcut(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        guard let rawID = arguments["shortcut_id"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let shortcutID = UUID(uuidString: rawID) else {
            throw AgentToolError.invalidArgument("shortcut_id must be a terminal shortcut UUID from terminal_list_shortcuts.")
        }
        let title = arguments["title"]?.stringValue()
        let operations = try parseEditOperations(arguments)
        guard !operations.isEmpty || title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentToolError.invalidArgument("Provide title or at least one terminal shortcut edit operation.")
        }

        let updated = try await MainActor.run {
            try controller.editShortcut(id: shortcutID, title: title, operations: operations)
        }
        let payload = try jsonString(shortcutSummary(updated, maxTextCharacters: 600))
        return AgentToolResult(
            summary: "terminal shortcut edited: \(updated.title)",
            payload: payload
        )
    }

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

    private static func parseCreateEvents(_ arguments: [String: AgentJSONValue]) throws -> [TerminalShortcutCreateEvent] {
        let rawEvents: AgentJSONValue
        if let value = arguments["events"] {
            rawEvents = value
        } else if let json = arguments["events_json"]?.stringValue() {
            rawEvents = AgentJSONValue.decode(from: json)
        } else {
            throw AgentToolError.missingArgument("events_json")
        }

        guard case .array(let values) = rawEvents else {
            throw AgentToolError.invalidArgument("events_json must be a JSON array.")
        }
        guard values.count <= 512 else {
            throw AgentToolError.invalidArgument("terminal_create_shortcut supports at most 512 events.")
        }

        var totalBytes = 0
        return try values.map { value in
            guard case .object(let object) = value else {
                throw AgentToolError.invalidArgument("Each terminal shortcut create event must be a JSON object.")
            }
            if object["protected_text"] != nil ||
                object["password"] != nil ||
                object["secret"] != nil ||
                object["requires_echo_off"]?.boolValue() == true ||
                object["requiresEchoOff"]?.boolValue() == true {
                throw AgentToolError.invalidArgument("terminal_create_shortcut cannot accept plaintext protected/password events. Use protected_placeholder for labels such as \"密码 1\"; WillDeep will ask the user for the real value in the chat card.")
            }

            let delay = object["delay_ms"]?.intValue()
                ?? object["delayMilliseconds"]?.intValue()
                ?? 0
            let event: TerminalShortcutCreateEvent
            if let placeholder = object["protected_placeholder"]?.stringValue()
                ?? object["protectedPlaceholder"]?.stringValue() {
                event = TerminalShortcutCreateEvent(kind: .protectedPlaceholder, delayMilliseconds: delay, value: placeholder)
            } else if let command = object["command"]?.stringValue() {
                event = TerminalShortcutCreateEvent(kind: .command, delayMilliseconds: delay, value: command)
                totalBytes += command.utf8.count + 1
            } else if let text = object["text"]?.stringValue() {
                event = TerminalShortcutCreateEvent(kind: .text, delayMilliseconds: delay, value: text)
                totalBytes += TerminalShortcutTextCodec.bytes(fromEscapedText: text).count
            } else if let control = object["control"]?.stringValue() {
                event = TerminalShortcutCreateEvent(kind: .control, delayMilliseconds: delay, value: control)
                totalBytes += 1
            } else {
                throw AgentToolError.invalidArgument("Each create event must include command, text, control, or protected_placeholder.")
            }
            guard totalBytes <= 64 * 1024 else {
                throw AgentToolError.invalidArgument("terminal_create_shortcut events exceed the 64 KiB recording limit.")
            }
            return event
        }
    }

    private static func parseEditOperations(_ arguments: [String: AgentJSONValue]) throws -> [TerminalShortcutEditOperation] {
        let rawOperations: AgentJSONValue
        if let value = arguments["operations"] {
            rawOperations = value
        } else if let json = arguments["operations_json"]?.stringValue() {
            rawOperations = AgentJSONValue.decode(from: json)
        } else {
            rawOperations = .array([])
        }

        guard case .array(let values) = rawOperations else {
            throw AgentToolError.invalidArgument("operations_json must be a JSON array.")
        }
        return try values.map { value in
            guard case .object(let object) = value else {
                throw AgentToolError.invalidArgument("Each terminal shortcut edit operation must be a JSON object.")
            }
            guard let rawKind = object["op"]?.stringValue(),
                  let kind = TerminalShortcutEditOperation.Kind(rawValue: rawKind) else {
                throw AgentToolError.invalidArgument("operation op must be one of: set_delay, delete_event, replace_visible_text, set_visible_text, delete_visible_text.")
            }
            guard let eventIndex = object["event_index"]?.intValue() ?? object["eventIndex"]?.intValue() else {
                throw AgentToolError.missingArgument("event_index")
            }
            return TerminalShortcutEditOperation(
                kind: kind,
                eventIndex: eventIndex,
                delayMilliseconds: object["delay_ms"]?.intValue() ?? object["delayMilliseconds"]?.intValue(),
                text: object["text"]?.stringValue(),
                find: object["find"]?.stringValue(),
                replacement: object["replace"]?.stringValue() ?? object["replacement"]?.stringValue()
            )
        }
    }

    private static func shortcutSummary(_ shortcut: TerminalShortcut, maxTextCharacters: Int) -> [String: Any] {
        [
            "id": shortcut.id.uuidString,
            "title": shortcut.title,
            "duration_ms": shortcut.durationMilliseconds,
            "playback_duration_ms": shortcut.playbackDurationMilliseconds,
            "event_count": shortcut.eventCount,
            "has_protected_input": shortcut.hasProtectedInput,
            "has_pending_protected_input": shortcut.hasPendingProtectedInput,
            "pending_protected_input_count": shortcut.pendingProtectedInputCount,
            "events": shortcut.events.enumerated().map { index, event in
                eventSummary(index: index, event: event, maxTextCharacters: maxTextCharacters)
            }
        ]
    }

    private static func eventSummary(
        index: Int,
        event: TerminalShortcutEvent,
        maxTextCharacters: Int
    ) -> [String: Any] {
        if event.requiresEchoOff {
            if event.needsProtectedInputValue {
                return [
                    "index": index,
                    "delay_ms": event.delayMilliseconds,
                    "kind": "protected_placeholder",
                    "placeholder": event.protectedPlaceholder ?? "Protected input \(index + 1)",
                    "needs_value": true,
                    "editable": false,
                    "protected_reference_present": false
                ]
            }
            return [
                "index": index,
                "delay_ms": event.delayMilliseconds,
                "kind": "protected_echo_off_input",
                "byte_count": event.transientProtectedBytes.count,
                "needs_value": false,
                "editable": false,
                "protected_reference_present": event.protectedBytesReference?.isEmpty == false
            ]
        }

        let text = String(decoding: event.bytes, as: UTF8.self)
        return [
            "index": index,
            "delay_ms": event.delayMilliseconds,
            "kind": "visible_input",
            "byte_count": event.bytes.count,
            "editable": true,
            "visible_text": String(text.prefix(maxTextCharacters)),
            "visible_text_truncated": text.count > maxTextCharacters
        ]
    }

    private static func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
