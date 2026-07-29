//
//  AgentToolCallGrouping.swift
//  WillDeep
//
//  Codex-style collapsing of consecutive same-kind tool calls into a
//  single transcript row ("已运行 3 条命令" / "已读取 2 个文件"). The
//  Agent-mode transcript renders one card per group instead of one
//  card per tool call so a busy turn doesn't drown the chat.
//

import Foundation

/// Recognizes terse provider-authored status headlines (for example
/// `Planning font size clamping implementation`). Settled history keeps the
/// stable localized phase title, while the active SwiftUI surface may show the
/// complete one-line action so users can see exactly what is moving forward.
nonisolated struct AgentActivityHeadlinePresentation: Equatable {
    let title: String
    let liveTitle: String
    let systemImage: String

    static var analyzing: Self {
        Self(
            title: L10n.AgentActivity.analyzing,
            liveTitle: L10n.AgentActivity.analyzing,
            systemImage: "sparkles"
        )
    }

    static func make(from content: String) -> Self? {
        let normalized = content
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 180,
              normalized.split(whereSeparator: \.isNewline).count == 1,
              ![".", "!", "?", "。", "！", "？"].contains(where: { normalized.hasSuffix($0) }) else {
            return nil
        }

        let firstWord = normalized
            .split(whereSeparator: { $0.isWhitespace || $0 == ":" })
            .first
            .map(String.init)?
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—"))

        switch firstWord {
        case "planning", "plan":
            return Self(
                title: L10n.AgentActivity.planning,
                liveTitle: liveTitle(normalized, fallback: L10n.AgentActivity.planning),
                systemImage: "list.bullet.clipboard"
            )
        case "inspecting", "examining", "reviewing", "analyzing", "analysing":
            return Self(
                title: L10n.AgentActivity.inspecting,
                liveTitle: liveTitle(normalized, fallback: L10n.AgentActivity.inspecting),
                systemImage: "doc.text.magnifyingglass"
            )
        case "searching", "locating", "finding", "reading":
            return Self(
                title: L10n.AgentActivity.searching,
                liveTitle: liveTitle(normalized, fallback: L10n.AgentActivity.searching),
                systemImage: "magnifyingglass"
            )
        case "editing", "implementing", "updating", "fixing", "refactoring":
            return Self(
                title: L10n.AgentActivity.editing,
                liveTitle: liveTitle(normalized, fallback: L10n.AgentActivity.editing),
                systemImage: "square.and.pencil"
            )
        case "testing", "verifying", "validating", "checking":
            return Self(
                title: L10n.AgentActivity.verifying,
                liveTitle: liveTitle(normalized, fallback: L10n.AgentActivity.verifying),
                systemImage: "checkmark.circle"
            )
        case "building", "compiling", "packaging":
            return Self(
                title: L10n.AgentActivity.building,
                liveTitle: liveTitle(normalized, fallback: L10n.AgentActivity.building),
                systemImage: "hammer"
            )
        case "running", "executing":
            return Self(
                title: L10n.AgentActivity.running,
                liveTitle: liveTitle(normalized, fallback: L10n.AgentActivity.running),
                systemImage: "terminal"
            )
        default:
            return nil
        }
    }

    private static func liveTitle(_ normalized: String, fallback: String) -> String {
        let wordCount = normalized.split(whereSeparator: {
            $0.isWhitespace || $0 == ":"
        }).count
        return wordCount > 1 ? normalized : fallback
    }

    /// Codex 式实时状态:从 reasoning 流里取最新一行非空文本作为当前
    /// 动作。先尝试严格的阶段动词识别(拿到语义图标和本地化阶段名);
    /// 识别不出时宽松兜底——模型自己的原话就是最好的"正在做什么",
    /// 不再因为不匹配英文动词表而整行消失。
    ///
    /// 只允许喂 reasoning 预览:正文首个 token 到达后调用方的预览即为
    /// nil,可见回复文本永远不会被当成状态行扫光。
    static func makeLive(fromReasoning reasoning: String) -> Self? {
        guard let line = latestStatusLine(in: reasoning) else { return nil }
        if let recognized = make(from: line) { return recognized }
        return Self(
            title: L10n.AgentActivity.thinking,
            liveTitle: line,
            systemImage: "ellipsis.bubble"
        )
    }

    private static func latestStatusLine(in reasoning: String) -> String? {
        let line = reasoning
            .split(whereSeparator: \.isNewline)
            .reversed()
            .lazy
            .map { candidate in
                candidate
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#>*-–—•`"))
                    .trimmingCharacters(in: .whitespaces)
            }
            .first(where: { $0.count >= 4 })
        guard var candidate = line else { return nil }
        if candidate.count > 140 {
            candidate = String(candidate.prefix(140)) + "…"
        }
        return candidate
    }
}

struct AgentToolActivityRowPresentation: Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String?
    let systemImage: String
    let status: AgentToolCallStatus

    init(call: AgentToolCall) {
        id = call.id
        status = call.status
        systemImage = Self.systemImage(for: call)
        title = Self.statusTitle(for: call)
        detail = Self.detail(for: call)
    }

    private static func statusTitle(for call: AgentToolCall) -> String {
        let operation = operationName(for: call)
        switch call.status {
        case .running:
            return "正在\(operation)"
        case .succeeded:
            return "已\(operation)"
        case .failed:
            return "\(operation)失败"
        case .denied:
            return "已跳过\(operation)"
        case .pendingApproval, .awaitingConfirm:
            return "等待确认：\(operation)"
        case .awaitingUserAnswer:
            return "等待你的回复"
        }
    }

    private static func operationName(for call: AgentToolCall) -> String {
        switch call.toolName {
        case "read_file": return "读取文件"
        case "list_directory": return "浏览目录"
        case "grep_files", "search_files": return "搜索代码"
        case "git_status": return "查看 Git 状态"
        case "run_command":
            if let label = compact(call.arguments["label"]?.stringValue()) {
                return label.count > 60 ? String(label.prefix(60)) + "…" : label
            }
            if let command = call.arguments["command"]?.stringValue(),
               let inferred = AgentRunCommandExecutionPolicy.inferredActivityKind(for: command) {
                return inferred.operationName
            }
            return "运行命令"
        case "terminal_snapshot": return "读取终端快照"
        case "terminal_send_command": return "发送终端命令"
        case "terminal_send_control": return "发送终端控制键"
        case "terminal_list_tabs": return "列出终端标签"
        case "terminal_select_tab": return "切换终端标签"
        case "edit_file": return "编辑文件"
        case "create_file": return "创建文件"
        case "apply_patch": return "应用补丁"
        default: return AgentToolDisplay.name(for: call.toolName)
        }
    }

    private static func systemImage(for call: AgentToolCall) -> String {
        switch call.toolName {
        case "read_file": return "book.pages"
        case "list_directory": return "folder"
        case "grep_files", "search_files": return "magnifyingglass"
        case "edit_file", "create_file", "apply_patch": return "pencil"
        default: return AgentToolKind.of(call).groupIcon
        }
    }

    private static func detail(for call: AgentToolCall) -> String? {
        switch call.toolName {
        case "read_file", "list_directory", "edit_file", "create_file":
            return fileName(call.arguments["path"]?.stringValue())
        case "grep_files":
            return compact(call.arguments["pattern"]?.stringValue())
                ?? fileName(call.arguments["path"]?.stringValue())
        case "search_files":
            return compact(call.arguments["query"]?.stringValue())
                ?? fileName(call.arguments["path"]?.stringValue())
        case "run_command":
            return fileName(call.arguments["cwd"]?.stringValue()).map { "\($0) 工作区" }
        case "terminal_send_control":
            return call.arguments["control"]?.stringValue().map(AgentToolDisplay.controlLabel(for:))
        case "web_fetch":
            guard let rawURL = call.arguments["url"]?.stringValue(),
                  let host = URL(string: rawURL)?.host else { return nil }
            return host
        case "spawn_agent":
            return compact(call.arguments["label"]?.stringValue())
        default:
            return nil
        }
    }

    private static func fileName(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? compact(trimmed) : name
    }

    private static func compact(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = AgentSecretStore.redactPlaceholders(in: value)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > 90 else { return normalized }
        return String(normalized.prefix(90)) + "…"
    }
}

nonisolated struct AgentFailedCommandDetailPresentation: Equatable {
    let command: String?
    let workingDirectory: String?
    let output: String?
    let error: String?

    init(call: AgentToolCall) {
        command = Self.nonEmpty(call.arguments["command"]?.stringValue())
            .map(AgentSecretStore.redactPlaceholders(in:))
        workingDirectory = Self.nonEmpty(call.arguments["cwd"]?.stringValue())
        output = Self.nonEmpty(call.result?.payload)
        error = Self.nonEmpty(call.errorMessage)
    }

    var hasDetails: Bool {
        command != nil || workingDirectory != nil || output != nil || error != nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AgentLiveActivityTimelinePresentation {
    /// The live transcript should show just enough recent work to explain
    /// what is happening now. A longer execution log is still represented by
    /// the quiet earlier-operations summary instead of being expanded inline.
    static let maximumDetailedRows = 3

    let hiddenOperationCount: Int
    let visibleCalls: [AgentToolCall]

    var disclosureCall: AgentToolCall? {
        visibleCalls.last(where: { !$0.status.isBlockingForUserDecision })
    }

    var hasExpandableDetails: Bool {
        hiddenOperationCount > 0
            || visibleCalls.filter { !$0.status.isBlockingForUserDecision }.count > 1
    }

    func detailCalls(isExpanded: Bool) -> [AgentToolCall] {
        let nonBlockingCalls = visibleCalls.filter { !$0.status.isBlockingForUserDecision }
        return isExpanded ? nonBlockingCalls : Array(nonBlockingCalls.suffix(1))
    }

    init(calls: [AgentToolCall], maximumDetailedRows: Int = Self.maximumDetailedRows) {
        let boundedMaximum = max(1, maximumDetailedRows)
        let displayCalls = Self.hidingRecoveredFileEditFailures(in: calls)
        let recentIDs = Set(displayCalls.suffix(boundedMaximum).map(\.id))
        let interactiveIDs = Set(displayCalls.lazy.filter { $0.status.isBlockingForUserDecision }.map(\.id))
        let visibleIDs = recentIDs.union(interactiveIDs)
        visibleCalls = displayCalls.filter { visibleIDs.contains($0.id) }
        hiddenOperationCount = calls.count - visibleCalls.count
    }

    /// A failed exact-string edit is useful while it is unresolved. Once a
    /// later successful edit (or an explicit mutation command) touches the
    /// same path, keeping the failed attempt in the live rows only makes a
    /// recovered turn look broken. It remains counted in the compact earlier
    /// summary and in the persisted transcript for auditability.
    private static func hidingRecoveredFileEditFailures(
        in calls: [AgentToolCall]
    ) -> [AgentToolCall] {
        calls.enumerated().compactMap { index, call in
            guard call.status == .failed,
                  call.toolName == "edit_file",
                  let path = normalizedPath(call.arguments["path"]?.stringValue()) else {
                return call
            }
            let wasRecovered = calls.dropFirst(index + 1).contains { laterCall in
                successfulMutation(laterCall, touches: path)
            }
            return wasRecovered ? nil : call
        }
    }

    private static func successfulMutation(
        _ call: AgentToolCall,
        touches path: String
    ) -> Bool {
        guard call.status == .succeeded else { return false }
        switch call.toolName {
        case "edit_file", "create_file":
            return normalizedPath(call.arguments["path"]?.stringValue()) == path
        case "apply_patch":
            return call.arguments["diff"]?.stringValue()?.contains(path) == true
        case "run_command":
            guard let command = call.arguments["command"]?.stringValue(),
                  command.contains(path) else { return false }
            let normalizedCommand = command.lowercased()
            return ["sed ", "perl ", "ruby ", "python ", "apply_patch", "git apply"]
                .contains(where: normalizedCommand.contains)
        default:
            return false
        }
    }

    private static func normalizedPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        return path.isEmpty ? nil : path
    }
}

/// Coarse category used purely for grouping. ask_user and patch
/// proposals are intentionally outside the grouped families — they
/// need explicit user interaction and must always render full-size.
nonisolated enum AgentToolKind: Equatable, Sendable {
    case runCommand
    case terminalOperation
    case fileExploration
    case subagent
    case claudeCode
    case codexCLI
    case cursorAgent
    case clineCLI
    case fileMutation
    case applyPatch
    case askUser
    case other(String)

    static func of(_ call: AgentToolCall) -> AgentToolKind {
        switch call.toolName {
        case "run_command":
            return .runCommand
        case _ where AgentTerminalToolNames.isVisibleTerminalOperation(call.toolName):
            return .terminalOperation
        case "read_file", "list_directory",
             "grep_files", "search_files",
             "git_status":
            return .fileExploration
        case "spawn_agent":
            return .subagent
        case "claude_code":
            return .claudeCode
        case "codex_cli":
            return .codexCLI
        case "cursor_agent":
            return .cursorAgent
        case "cline_cli":
            return .clineCLI
        case "edit_file", "create_file":
            return .fileMutation
        case "apply_patch":
            return .applyPatch
        case "ask_user":
            return .askUser
        default:
            return .other(call.toolName)
        }
    }

    /// Whether two adjacent calls of this kind are allowed to merge.
    /// `.askUser` always stands alone; everything else can group with a
    /// peer of the same kind.
    var isGroupable: Bool {
        switch self {
        case .askUser, .applyPatch: return false
        default: return true
        }
    }

    func groupTitle(_ count: Int) -> String {
        switch self {
        case .runCommand:
            return "已运行 \(count) 条命令"
        case .terminalOperation:
            return "已执行 \(count) 次终端操作"
        case .fileExploration:
            return "已探索 \(count) 个文件"
        case .subagent:
            return "已派出 \(count) 个子 agent"
        case .claudeCode:
            return "已委派 \(count) 个 Claude Code 任务"
        case .codexCLI:
            return "已委派 \(count) 个 Codex CLI 任务"
        case .cursorAgent:
            return "已委派 \(count) 个 Cursor Agent 任务"
        case .clineCLI:
            return "已委派 \(count) 个 Cline 任务"
        case .fileMutation:
            return "已写入 \(count) 个文件"
        case .applyPatch:
            return "已提交 Patch"
        case .other(let name):
            return "已调用 \(count) 次 \(name)"
        case .askUser:
            return "向你提问"
        }
    }

    func groupTitle(for calls: [AgentToolCall]) -> String {
        switch self {
        case .fileExploration:
            return AgentToolActivitySummary(calls: calls).explorationText ?? groupTitle(calls.count)
        case .runCommand:
            return "已运行 \(calls.count) 条命令"
        case .terminalOperation:
            return "已执行 \(calls.count) 次终端操作"
        default:
            return groupTitle(calls.count)
        }
    }

    var groupIcon: String {
        switch self {
        case .runCommand: return "terminal"
        case .terminalOperation: return "terminal"
        case .fileExploration: return "doc.text.magnifyingglass"
        case .subagent: return "person.2"
        case .claudeCode: return "sparkles.rectangle.stack"
        case .codexCLI: return "terminal.fill"
        case .cursorAgent: return "cursorarrow.rays"
        case .clineCLI: return "chevron.left.forwardslash.chevron.right"
        case .fileMutation: return "square.and.pencil"
        case .applyPatch: return "square.and.pencil"
        case .askUser: return "bubble.left.and.text.bubble.right"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

extension AgentToolKind {
    var delegatedActivityBaseLabel: String? {
        switch self {
        case .subagent:
            return "委派给子代理"
        case .claudeCode:
            return "委派给 Claude Code"
        case .codexCLI:
            return "委派给 Codex"
        case .cursorAgent:
            return "委派给 Cursor Agent"
        case .clineCLI:
            return "委派给 Cline"
        default:
            return nil
        }
    }

    func delegatedActivityLabel(progress: String?) -> String? {
        guard let base = delegatedActivityBaseLabel else { return nil }
        let cleanProgress = progress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanProgress.isEmpty ? base : "\(base) · \(cleanProgress)"
    }
}

nonisolated enum AgentTerminalToolNames {
    static func isVisibleTerminalOperation(_ toolName: String) -> Bool {
        switch toolName {
        case "terminal_snapshot", "terminal_send_command", "terminal_send_control",
             "terminal_list_tabs", "terminal_select_tab":
            return true
        default:
            return false
        }
    }
}

/// Either a single call (rendered as the existing AgentToolCallCard)
/// or a merged run of N adjacent calls (rendered as the new compact
/// row). Single tool calls in groupable kinds still arrive here as a
/// group of size 1 — the renderer decides to fall back to the full
/// card in that case, so the user sees the rich UI when there's only
/// one call but the dense row when there are many.
/// Renamed from `AgentToolCallGroup` to avoid colliding with the view
/// type of the same name in AgentPanelView. This is the model layer —
/// the view consumes `segments[i].calls` directly.
struct AgentToolCallSegment: Identifiable, Equatable {
    let id: UUID
    let kind: AgentToolKind
    let calls: [AgentToolCall]

    init(kind: AgentToolKind, calls: [AgentToolCall]) {
        // Stable id derived from the first call so SwiftUI keeps the
        // same view identity as the group grows during streaming.
        self.id = calls.first?.id ?? UUID()
        self.kind = kind
        self.calls = calls
    }

    var count: Int { calls.count }

    var title: String {
        kind.groupTitle(for: calls)
    }
}

enum AgentToolCallGrouping {
    /// Walk the given (already-filtered) tool calls in order and
    /// produce a flat list of segments. Adjacent calls of the same
    /// groupable kind merge; everything else lands as a singleton
    /// segment of size 1.
    static func group(_ calls: [AgentToolCall]) -> [AgentToolCallSegment] {
        var result: [AgentToolCallSegment] = []
        var pendingKind: AgentToolKind?
        var pending: [AgentToolCall] = []

        func flush() {
            guard let kind = pendingKind, !pending.isEmpty else { return }
            result.append(AgentToolCallSegment(kind: kind, calls: pending))
            pendingKind = nil
            pending = []
        }

        for call in calls {
            let kind = AgentToolKind.of(call)
            if kind.isGroupable, pendingKind == kind {
                pending.append(call)
            } else {
                flush()
                pendingKind = kind
                pending = [call]
                if !kind.isGroupable {
                    // Non-groupable kinds (.askUser) flush themselves
                    // immediately so the next call starts a fresh group.
                    flush()
                }
            }
        }
        flush()
        return result
    }

    /// The live transcript already shows a compact inline summary for a
    /// completed terminal interaction. Keeping the full-width working card
    /// below it repeats the same information while the Agent continues
    /// thinking. Terminal cards therefore disappear once every operation in
    /// that segment succeeds, but remain visible for running, interactive,
    /// failed, or denied states where the details still matter.
    static func livePresentationSegments(_ calls: [AgentToolCall]) -> [AgentToolCallSegment] {
        let commandCalls = calls.filter { AgentToolKind.of($0) == .runCommand }
        var emittedCommandGroup = false
        return group(calls).compactMap { segment in
            if segment.kind == .runCommand {
                guard !emittedCommandGroup else { return nil }
                emittedCommandGroup = true
                return AgentToolCallSegment(kind: .runCommand, calls: commandCalls)
            }
            guard segment.kind == .terminalOperation else { return segment }
            return segment.calls.contains { $0.status != .succeeded } ? segment : nil
        }
    }
}

/// One presentation model for all tool calls emitted after the latest user
/// input. Providers may split a single assistant turn into several messages
/// (and a model-switch notice can land between those messages). The transcript
/// should still show one growing activity group instead of repeating
/// "已运行 N 条命令" for every provider chunk.
struct AgentActiveTurnToolCallPresentation: Equatable {
    let messageIDs: [AgentMessage.ID]
    let calls: [AgentToolCall]

    var anchorMessageID: AgentMessage.ID? {
        messageIDs.first
    }

    private var messageIDSet: Set<AgentMessage.ID> {
        Set(messageIDs)
    }

    static func make(
        messages: [AgentMessage],
        toolCalls: [AgentToolCall],
        isResponding: Bool
    ) -> AgentActiveTurnToolCallPresentation? {
        let turnStart = messages.lastIndex(where: { $0.role == .user })
            .map { messages.index(after: $0) }
            ?? messages.startIndex
        let assistantMessageIDs = Set(messages[turnStart...].lazy.compactMap { message in
            message.role == .assistant ? message.id : nil
        })
        let activeCalls = toolCalls.filter { assistantMessageIDs.contains($0.messageID) }
        guard !activeCalls.isEmpty else { return nil }
        guard isResponding || activeCalls.contains(where: { isWorking($0.status) }) else {
            return nil
        }

        var seenMessageIDs = Set<AgentMessage.ID>()
        let orderedMessageIDs = activeCalls.compactMap { call -> AgentMessage.ID? in
            seenMessageIDs.insert(call.messageID).inserted ? call.messageID : nil
        }
        return AgentActiveTurnToolCallPresentation(
            messageIDs: orderedMessageIDs,
            calls: activeCalls
        )
    }

    /// Keep prose and event notices in TextKit history while removing only the
    /// tool-call payloads now owned by the single live SwiftUI activity group.
    func hidingToolCalls(in message: AgentMessage) -> AgentMessage {
        guard messageIDSet.contains(message.id), !message.toolCalls.isEmpty else {
            return message
        }
        var copy = message
        copy.toolCalls = []
        return copy
    }

    private static func isWorking(_ status: AgentToolCallStatus) -> Bool {
        switch status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer, .running:
            return true
        case .succeeded, .failed, .denied:
            return false
        }
    }
}

nonisolated struct AgentToolActivitySummary: Equatable {
    var readFileCount: Int
    var listedDirectoryCount: Int
    var searchCount: Int
    var gitStatusCount: Int
    var commandCount: Int
    var terminalOperationCount: Int

    init(calls: [AgentToolCall]) {
        var readFiles = Set<String>()
        var listedDirectories = Set<String>()
        var searches = 0
        var gitStatuses = 0
        var commands = 0
        var terminalOperations = 0

        for call in calls {
            switch call.toolName {
            case "read_file":
                if let path = call.arguments["path"]?.stringValue() {
                    readFiles.insert(path.isEmpty ? "." : path)
                } else {
                    readFiles.insert(".")
                }
            case "list_directory":
                if let path = call.arguments["path"]?.stringValue() {
                    listedDirectories.insert(path.isEmpty ? "." : path)
                } else {
                    listedDirectories.insert(".")
                }
            case "grep_files", "search_files":
                searches += 1
            case "git_status":
                gitStatuses += 1
            case "run_command":
                commands += 1
            case _ where AgentTerminalToolNames.isVisibleTerminalOperation(call.toolName):
                terminalOperations += 1
            default:
                break
            }
        }

        readFileCount = readFiles.count
        listedDirectoryCount = listedDirectories.count
        searchCount = searches
        gitStatusCount = gitStatuses
        commandCount = commands
        terminalOperationCount = terminalOperations
    }

    var exploredPathCount: Int {
        readFileCount + listedDirectoryCount
    }

    var hasActivity: Bool {
        readFileCount > 0 || listedDirectoryCount > 0 || searchCount > 0 || gitStatusCount > 0 || commandCount > 0 || terminalOperationCount > 0
    }

    var explorationText: String? {
        var parts: [String] = []
        if readFileCount > 0 {
            parts.append("已读取 \(readFileCount) 个文件")
        }
        if listedDirectoryCount > 0 {
            parts.append("已浏览 \(listedDirectoryCount) 个目录")
        }
        if searchCount > 0 {
            parts.append(searchCount == 1 ? "已搜索代码" : "已搜索代码 \(searchCount) 次")
        }
        if gitStatusCount > 0 {
            parts.append(gitStatusCount == 1 ? "已查看 Git 状态" : "已查看 Git 状态 \(gitStatusCount) 次")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    var commandText: String? {
        guard commandCount > 0 else { return nil }
        return "已运行 \(commandCount) 条命令"
    }

    var terminalText: String? {
        guard terminalOperationCount > 0 else { return nil }
        return "已执行 \(terminalOperationCount) 次终端操作"
    }

    var activityText: String? {
        let parts = [explorationText, commandText, terminalText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
