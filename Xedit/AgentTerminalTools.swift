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

        let snapshot: RedactedTerminalSnapshot
        do {
            snapshot = try await withTerminalSnapshotTimeout(seconds: 3) {
                // Cheap main-actor hop: metadata + the off-main mirror handle
                // only. No screen text is read on the main thread, so a busy
                // main thread can't make the snapshot stale — it can at worst
                // delay this tiny metadata hop, which the timeout still guards.
                let raw = try await MainActor.run { try controller.rawSnapshot() }
                // Square the mirror to the visible grid, then read the screen
                // and redact/trim — ALL off the main actor. The mirror is fed
                // on its own queue, so this reflects the latest PTY output even
                // while the UI is mid-render.
                raw.mirror.resize(cols: raw.cols, rows: raw.rows)
                let rawOutput = raw.mirror.captureViewport()
                let redacted = AgentTerminalRedactor.redact(rawOutput)
                let trimmed = String(redacted.suffix(max(1, maxCharacters)))
                return RedactedTerminalSnapshot(
                    isRunning: raw.isRunning,
                    runtimeName: raw.runtimeName,
                    runtimeTarget: raw.runtimeTarget,
                    output: trimmed,
                    recentCommands: raw.recentCommands
                )
            }
        } catch is TerminalSnapshotTimeout {
            throw AgentToolError.invalidArgument(
                "Timed out reading the Agent Terminal after 3s — the app's main thread is busy (usually mid-render while streaming a reply). Nothing was changed; call terminal_snapshot again in a moment."
            )
        }

        let statusLine: String
        if snapshot.isRunning {
            let target = snapshot.runtimeTarget.isEmpty ? "" : " (\(snapshot.runtimeTarget))"
            statusLine = "Agent Terminal: connected\nRuntime: \(snapshot.runtimeName)\(target)"
        } else {
            statusLine = "Agent Terminal: process has exited (showing its final visible screen)\nRuntime: \(snapshot.runtimeName)"
        }
        let recent = snapshot.recentCommands.isEmpty
            ? "none"
            : snapshot.recentCommands.joined(separator: "\n")
        let screen = snapshot.output.isEmpty
            ? (snapshot.isRunning ? "(no terminal output yet)" : "(terminal produced no output before exiting)")
            : snapshot.output
        let payload = """
        \(statusLine)

        Recent AI/auto commands:
        \(recent)

        --- latest visible screen ---
        \(screen)
        """
        let summary = snapshot.isRunning
            ? "terminal connected: \(snapshot.runtimeName)"
            : "terminal exited: \(snapshot.runtimeName)"
        return AgentToolResult(summary: summary, payload: payload)
    }

    // MARK: terminal_snapshot timeout plumbing

    /// Redacted, trimmed capture ready for the tool payload. Built off the
    /// main actor from `AgentTerminalRawSnapshot`.
    private struct RedactedTerminalSnapshot: Sendable {
        let isRunning: Bool
        let runtimeName: String
        let runtimeTarget: String
        let output: String
        let recentCommands: [String]
    }

    private struct TerminalSnapshotTimeout: Error {}

    /// Races `operation` against a deadline. If the deadline wins (e.g. the
    /// main actor is wedged mid-render), throws `TerminalSnapshotTimeout`
    /// instead of hanging the entire tool call — and the agent — forever.
    private static func withTerminalSnapshotTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TerminalSnapshotTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TerminalSnapshotTimeout()
            }
            return first
        }
    }

    static func sendCommand(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        guard let command = arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        let pathSelection = try zmodemPathSelection(arguments: arguments, rootDirectory: context.rootDirectory)
        return try await MainActor.run {
            try controller.sendApprovedCommand(
                command,
                zmodemPathSelection: pathSelection,
                secretRedactionValues: context.secretRedactionValues
            )
        }
    }

    static func hasZModemPathSelection(_ arguments: [String: AgentJSONValue]) -> Bool {
        arguments["zmodem_upload_paths"] != nil || arguments["zmodem_download_directory"] != nil
    }

    static func zmodemPathSelection(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?
    ) throws -> TerminalZModemPathSelection? {
        let uploadPaths = arguments["zmodem_upload_paths"]?.stringArrayValue()
        let rawDownloadDirectory = arguments["zmodem_download_directory"]?.stringValue()
        let hasUploadPaths = uploadPaths?.isEmpty == false
        let hasDownloadDirectory = rawDownloadDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        guard !(hasUploadPaths && hasDownloadDirectory) else {
            throw AgentToolError.invalidArgument(
                "Provide either zmodem_upload_paths or zmodem_download_directory, not both."
            )
        }
        if arguments["zmodem_upload_paths"] != nil, uploadPaths == nil {
            throw AgentToolError.invalidArgument("zmodem_upload_paths must be an array of local file paths.")
        }
        if let uploadPaths, !uploadPaths.isEmpty {
            guard uploadPaths.count <= 32 else {
                throw AgentToolError.invalidArgument("zmodem_upload_paths supports at most 32 files per transfer.")
            }
            let files = try uploadPaths.map { rawPath in
                let url = try resolveLocalPath(rawPath, rootDirectory: rootDirectory)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    throw AgentToolError.invalidArgument("ZMODEM upload file does not exist or is not a file: \(url.path)")
                }
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw AgentToolError.invalidArgument("ZMODEM upload file is not readable: \(url.path)")
                }
                return url
            }
            return .upload(files: files)
        }
        if let rawDownloadDirectory, hasDownloadDirectory {
            let directory = try resolveLocalPath(rawDownloadDirectory, rootDirectory: rootDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AgentToolError.invalidArgument(
                    "ZMODEM download directory does not exist or is not a directory: \(directory.path)"
                )
            }
            guard FileManager.default.isWritableFile(atPath: directory.path) else {
                throw AgentToolError.invalidArgument("ZMODEM download directory is not writable: \(directory.path)")
            }
            return .download(directory: directory)
        }
        return nil
    }

    private static func resolveLocalPath(_ rawPath: String, rootDirectory: URL?) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.invalidArgument("ZMODEM local paths cannot be empty.")
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        guard let rootDirectory else {
            throw AgentToolError.invalidArgument(
                "Relative ZMODEM local paths require an open workspace; otherwise provide an absolute path."
            )
        }
        return rootDirectory.appendingPathComponent(expanded).standardizedFileURL
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
