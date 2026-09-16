//
//  AgentTerminalTools.swift
//  WillDeep
//
//  Built-in tools for the visible Agent-mode interactive terminal.
//

import Foundation

/// Host-side boundary for Agent-driven terminal automation.
///
/// Saved recordings deliberately have no runnable Agent tool. Playback may
/// contain protected input and can represent a long sequence of side effects,
/// so only the human-facing play button may start it. Ordinary audited
/// terminal primitives remain automatable, but their panel must be visible
/// while they mutate terminal state.
nonisolated enum AgentTerminalAutomationPolicy {
    private static let visibleMutationToolNames: Set<String> = [
        "terminal_send_command",
        "terminal_send_control",
        "terminal_select_tab",
        "terminal_create_shortcut",
        "terminal_edit_shortcut",
    ]

    private static let forbiddenShortcutReplayToolNames: Set<String> = [
        "terminal_play_shortcut",
        "terminal_replay_shortcut",
        "terminal_run_shortcut",
    ]

    static let userOnlyShortcutPlaybackRule =
        "Never run or replay a saved Terminal recording shortcut for the user. Only the user may start saved shortcut playback from the visible Terminal UI."

    static func requiresVisiblePanel(toolName: String) -> Bool {
        visibleMutationToolNames.contains(toolName)
    }

    static func forbidsShortcutReplay(toolName: String) -> Bool {
        forbiddenShortcutReplayToolNames.contains(toolName)
    }
}

enum AgentTerminalTools {
    /// Ordinary visible-terminal commands receive a bounded, best-effort
    /// follow-up screen read. This is long enough for quick shell commands to
    /// produce useful output without making interactive/long-running commands
    /// block the agent turn.
    private static let commandFollowUpSnapshotDelayNanoseconds: UInt64 = 600_000_000

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

    /// 在读这个 tab 之前先把「它现在连在哪」弄清楚。
    ///
    /// 这是模型判断「该不该把这条命令发进去」的唯一可靠依据，所以宁可花
    /// 三秒探一次。探针只在 shell 空闲时发，前台有交互程序时直接跳过。
    @MainActor
    private static func resolveHost(controller: AgentInteractiveTerminalController, tabID: UUID?) async {
        let tab = tabID.flatMap { id in controller.tabs.first { $0.id == id } } ?? controller.activeTab
        guard let tab, tab.isRunning else { return }
        _ = await tab.resolveHostIdentity()
    }

    static func snapshot(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        includeRecentCommands: Bool = true
    ) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        let maxCharacters = min(max(arguments["max_characters"]?.intValue() ?? 6_000, 500), 12_000)
        let targetTabID = try terminalTabID(arguments)
        await resolveHost(controller: controller, tabID: targetTabID)

        let snapshot: RedactedTerminalSnapshot
        do {
            snapshot = try await withTerminalSnapshotTimeout(seconds: 3) {
                // Cheap main-actor hop: metadata + the off-main mirror handle
                // only. No screen text is read on the main thread, so a busy
                // main thread can't make the snapshot stale — it can at worst
                // delay this tiny metadata hop, which the timeout still guards.
                let raw = try await MainActor.run {
                    try controller.rawSnapshot(
                        targetTabID: targetTabID,
                        sessionID: context.runtimeID
                    )
                }
                // Square the mirror to the visible grid, then read the screen
                // and redact/trim — ALL off the main actor. The mirror is fed
                // on its own queue, so this reflects the latest PTY output even
                // while the UI is mid-render.
                raw.mirror.resize(cols: raw.cols, rows: raw.rows)
                let rawCapture = raw.mirror.capture()
                let redactedOutput = AgentTerminalRedactor.redact(rawCapture.viewport)
                let redactedMarkedOutput = AgentTerminalRedactor.redact(rawCapture.markedViewport)
                let redactedCursorLine = AgentTerminalRedactor.redact(rawCapture.cursorLine)
                let redactedScrollback = AgentTerminalRedactor.redact(rawCapture.scrollback)
                let trimmed = String(redactedOutput.suffix(max(1, maxCharacters)))
                let trimmedMarked = String(redactedMarkedOutput.suffix(max(1, maxCharacters)))
                // Keep the newest history: the tail is what leads into the
                // visible screen, so trim from the front like the screen does.
                let trimmedScrollback = String(redactedScrollback.suffix(max(1, maxCharacters)))
                return RedactedTerminalSnapshot(
                    tabID: raw.tabID,
                    isRunning: raw.isRunning,
                    inputState: raw.inputState,
                    isZModemTransferActive: raw.isZModemTransferActive,
                    runtimeName: raw.runtimeName,
                    runtimeTarget: raw.runtimeTarget,
                    hostLine: raw.hostLine,
                    output: trimmed,
                    markedOutput: trimmedMarked,
                    scrollback: trimmedScrollback,
                    cursorLine: redactedCursorLine,
                    cursorRow: rawCapture.cursorRow,
                    cursorColumn: rawCapture.cursorColumn,
                    rows: rawCapture.rows,
                    cols: rawCapture.cols,
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
            statusLine = "Agent Terminal: connected\nTab ID: \(snapshot.tabID.uuidString)\nRuntime: \(snapshot.runtimeName)\(target)\nHost: \(snapshot.hostLine)"
        } else {
            statusLine = "Agent Terminal: process has exited (showing its final visible screen)\nTab ID: \(snapshot.tabID.uuidString)\nRuntime: \(snapshot.runtimeName)"
        }
        // 跟着命令派发自动附带的快照不带这一段：派发回执第一行已经是完整命令。
        let recentSection = includeRecentCommands
            ? "\nRecent AI/auto commands:\n\(recentCommandsSummary(snapshot.recentCommands))\n"
            : ""
        let zmodemState = snapshot.isZModemTransferActive
            ? "active — the local file may exist but is still partial; do not claim transfer completion or inspect it as final data"
            : "inactive"
        let screen = snapshot.output.isEmpty
            ? (snapshot.isRunning ? "(no terminal output yet)" : "(terminal produced no output before exiting)")
            : snapshot.output
        let markedScreen = snapshot.markedOutput.isEmpty
            ? screen
            : snapshot.markedOutput
        let cursorLine = snapshot.cursorLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(cursor is on a blank line)"
            : snapshot.cursorLine
        // The visible screen is one narrow window. Anything that already
        // scrolled past it is still what the operator means by "the output",
        // so carry a bounded tail of it instead of reporting nothing.
        let earlierSection = snapshot.scrollback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : """

            --- earlier output (scrolled above the visible screen, oldest first) ---
            \(snapshot.scrollback)
            """
        let payload = """
        \(statusLine)
        Input state: \(snapshot.inputState.rawValue)
        ZMODEM transfer: \(zmodemState)

        Cursor:
        row \(snapshot.cursorRow + 1)/\(snapshot.rows), column \(snapshot.cursorColumn + 1)/\(snapshot.cols)

        Current cursor line:
        \(cursorLine)
        \(recentSection)\(earlierSection)
        --- latest visible screen (=> marks current cursor line) ---
        \(markedScreen)
        """
        let summary = snapshot.isRunning
            ? "terminal \(snapshot.inputState.rawValue): \(snapshot.runtimeName)"
            : "terminal exited: \(snapshot.runtimeName)"
        return AgentToolResult(summary: summary, payload: payload)
    }

    /// 快照里「最近命令」一段的上限。它每次快照都整段重发：2026-09-14 一次
    /// k8s 发版回合里，这一段占了终端工具返回总量的 40%（13.4 万字符 / 26 次快照），
    /// 长 kubectl 命令原样重复，把每轮请求越推越大。
    nonisolated static let recentCommandsSnapshotLimit = 3
    nonisolated static let recentCommandSnapshotCharacterLimit = 160

    /// 只留最近几条、每条截断；宿主自己发的主机识别探针不是模型关心的命令，剔掉。
    nonisolated static func recentCommandsSummary(_ commands: [String]) -> String {
        let visible = commands.filter { $0 != AgentTerminalTab.hostIdentityProbeCommand }
        guard !visible.isEmpty else { return "none" }
        var lines = visible.prefix(recentCommandsSnapshotLimit).map { command -> String in
            guard command.count > recentCommandSnapshotCharacterLimit else { return command }
            return String(command.prefix(recentCommandSnapshotCharacterLimit))
                + " …[\(command.count) chars]"
        }
        let omitted = visible.count - recentCommandsSnapshotLimit
        if omitted > 0 {
            lines.append("(\(omitted) older omitted)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: terminal_snapshot timeout plumbing

    /// Redacted, trimmed capture ready for the tool payload. Built off the
    /// main actor from `AgentTerminalRawSnapshot`.
    private struct RedactedTerminalSnapshot: Sendable {
        let tabID: UUID
        let isRunning: Bool
        let inputState: AgentTerminalInputState
        let isZModemTransferActive: Bool
        let runtimeName: String
        let runtimeTarget: String
        let hostLine: String
        let output: String
        let markedOutput: String
        let scrollback: String
        let cursorLine: String
        let cursorRow: Int
        let cursorColumn: Int
        let rows: Int
        let cols: Int
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
        let targetTabID = try terminalTabID(arguments)
        await resolveHost(controller: controller, tabID: targetTabID)
        let dispatch = try await MainActor.run {
            try controller.sendApprovedCommandDispatch(
                command,
                targetTabID: targetTabID,
                sessionID: context.runtimeID,
                zmodemPathSelection: pathSelection,
                secretRedactionValues: context.secretRedactionValues
            )
        }
        guard let ticket = dispatch.zmodemTicket else {
            return await resultWithAutomaticFollowUpSnapshot(
                dispatch: dispatch,
                context: context
            )
        }
        let outcome = await ticket.waitForCompletion()
        guard outcome.succeeded else {
            throw AgentToolError.invalidArgument(
                "ZMODEM transfer did not complete successfully. \(outcome.message) Do not treat a destination file that appeared during transfer as complete."
            )
        }
        let direction = outcome.direction == .downloadFromRemote ? "download" : "upload"
        let transferred = ByteCountFormatter.string(
            fromByteCount: Int64(outcome.transferredByteCount),
            countStyle: .file
        )
        return AgentToolResult(
            summary: "zmodem \(direction) complete: \(transferred)",
            payload: """
            \(dispatch.result.payload)

            ZMODEM protocol completion confirmed after the local lrzsz process exited and final protocol output was drained.
            \(outcome.message)
            """
        )
    }

    private static func resultWithAutomaticFollowUpSnapshot(
        dispatch: AgentTerminalCommandDispatch,
        context: AgentToolContext
    ) async -> AgentToolResult {
        do {
            try await Task.sleep(nanoseconds: commandFollowUpSnapshotDelayNanoseconds)
            let followUp = try await snapshot(
                arguments: [
                    "terminal_tab_id": .string(dispatch.terminalTabID.uuidString),
                    "max_characters": .number(6_000)
                ],
                context: context,
                includeRecentCommands: false
            )
            return AgentToolResult(
                summary: dispatch.result.summary,
                payload: """
                \(dispatch.result.payload)

                Automatic follow-up snapshot (captured shortly after dispatch; long-running or interactive commands may still be producing output):

                \(followUp.payload)

                If the expected output or a returned prompt is not visible yet, wait briefly and call terminal_snapshot again for this same tab. Do not infer that terminal output is unstable from this bounded first read.
                """
            )
        } catch {
            // The command has already been sent. Treating a follow-up read
            // failure as a failed tool call could make the model execute the
            // command twice, which is unsafe for non-idempotent commands.
            return AgentToolResult(
                summary: dispatch.result.summary,
                payload: """
                \(dispatch.result.payload)

                The automatic follow-up snapshot was unavailable: \(error.localizedDescription)
                The command was already sent; do not send it again. Wait briefly, then call terminal_snapshot for tab \(dispatch.terminalTabID.uuidString) to read its output.
                """
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
        let targetTabID = try terminalTabID(arguments)
        return try await MainActor.run {
            try controller.sendApprovedControl(
                control,
                targetTabID: targetTabID,
                sessionID: context.runtimeID
            )
        }
    }

    static func listTabs(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        let sessionID = context.runtimeID
        // 刻意只探活跃 tab：对每一个 tab 都发探针会往用户所有终端里打字，
        // 而模型下一步要用的几乎总是活跃那个。其余 tab 报 unknown。
        await resolveHost(controller: controller, tabID: UUID?.none)
        let summaries = await MainActor.run {
            controller.tabs.map { tab in
                tab.refreshInputState()
                return tabSummary(tab, isActive: controller.activeTabID == tab.id, sessionID: sessionID)
            }
        }
        let payload = try jsonString(summaries)
        return AgentToolResult(
            summary: "terminal tabs: \(summaries.count)",
            payload: payload
        )
    }

    static func selectTab(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let controller = context.terminalController else {
            throw AgentToolError.invalidArgument("Agent Terminal is not available in this context.")
        }
        guard let tabID = try terminalTabID(arguments) else {
            throw AgentToolError.missingArgument("terminal_tab_id")
        }
        let selectedTitle = try await MainActor.run {
            try controller.selectTab(id: tabID).title
        }
        return AgentToolResult(
            summary: "terminal tab activated: \(selectedTitle)",
            payload: "Activated Agent Terminal tab \"\(selectedTitle)\" (\(tabID.uuidString)). Terminal tools without terminal_tab_id now target this tab, and the user sees it in the side panel."
        )
    }

    /// 这个 tab 当前实际连在哪台机器上。
    ///
    /// `kind` 只说明 tab 是怎么创建的：用户在一个 local tab 里手敲 `ssh`
    /// 之后它永远还是 `local`。所以判本地还是远端只能靠往活着的 shell 里
    /// 探一次 hostname，再和本机比。探不到就是 `unknown`——刻意不回落成
    /// `local`：拿着错的身份批准一条命令，比承认不知道危险得多。
    @MainActor
    static func hostDescriptor(_ tab: AgentTerminalTab) -> [String: Any] {
        var descriptor: [String: Any] = [:]
        if case .ssh(_, _, let target) = tab.kind {
            // 从 SSH profile 开的 tab，目标是清楚的，但它里面仍可能再跳一层。
            descriptor["configured_ssh_target"] = target
        }
        switch tab.hostState {
        case .unknown:
            descriptor["host_kind"] = "unknown"
        case .local(let identity), .remote(let identity):
            descriptor["host"] = identity.hostname
            descriptor["host_kind"] = isLocalHostname(identity.hostname) ? "local" : "remote"
            if !identity.operatingSystem.isEmpty { descriptor["host_os"] = identity.operatingSystem }
            if !identity.ipAddress.isEmpty { descriptor["host_ip"] = identity.ipAddress }
        case .changed(let previous):
            descriptor["host_kind"] = "unknown"
            descriptor["host_note"] = "a shell-switching command ran since the last measurement"
            if let previous { descriptor["last_known_host"] = previous.hostname }
        case .disconnected(let previous):
            descriptor["host_kind"] = "unknown"
            descriptor["host_note"] = "the terminal reported a closed connection"
            if let previous { descriptor["last_known_host"] = previous.hostname }
        }
        return descriptor
    }

    /// 和本机比对。macOS 的 `hostname` 常带 `.local` 后缀，Bonjour 改名也
    /// 会变，所以两边都剥掉后缀再比，并且大小写不敏感。
    nonisolated static func isLocalHostname(_ hostname: String) -> Bool {
        func normalized(_ value: String) -> String {
            var token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for suffix in [".local", ".lan", ".home", ".localdomain"] where token.hasSuffix(suffix) {
                token = String(token.dropLast(suffix.count))
            }
            return token
        }
        let candidate = normalized(hostname)
        guard !candidate.isEmpty else { return false }
        if candidate == normalized(ProcessInfo.processInfo.hostName) { return true }
        return candidate == normalized(Host.current().localizedName ?? "")
    }

    @MainActor
    private static func tabSummary(
        _ tab: AgentTerminalTab,
        isActive: Bool,
        sessionID: UUID?
    ) -> [String: Any] {
        let kind: String
        switch tab.kind {
        case .localShell: kind = "local"
        case .delegatedShell: kind = "delegated"
        case .ssh: kind = "ssh"
        }
        var summary: [String: Any] = [
            "terminal_tab_id": tab.id.uuidString,
            "title": tab.title,
            "kind": kind,
            "target": tab.runtimeTarget,
            "is_active": isActive,
            "is_running": tab.isRunning,
            "input_state": tab.inputState.rawValue,
            "is_automation_busy": tab.isAutomationBusy,
            "opened_by_this_conversation": sessionID != nil && tab.originAgentSessionID == sessionID
        ]
        summary.merge(hostDescriptor(tab)) { current, _ in current }
        return summary
    }

    private static func terminalTabID(_ arguments: [String: AgentJSONValue]) throws -> UUID? {
        guard let raw = arguments["terminal_tab_id"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let id = UUID(uuidString: raw) else {
            throw AgentToolError.invalidArgument("terminal_tab_id must be a terminal tab UUID.")
        }
        return id
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
