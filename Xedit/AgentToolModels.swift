//
//  AgentToolModels.swift
//  WillDeep
//
//  Shared data model for built-in Agent tools. AgentTools.swift owns the
//  runner implementation; this file keeps the risk/status/value types
//  reusable by UI, remote runtimes, mobile gateway, and tests.
//

import Foundation

// MARK: - Risk model

enum AgentToolRisk: String, Codable {
    /// Pure read; safe to auto-allow.
    case read
    /// Touches the workspace or shell; needs explicit Allow/Deny.
    case write
    /// Destructive or escapes the workspace; needs typed "confirm".
    case danger
    /// Asks the user a question. Doesn't execute anything -- the AppState
    /// loop intercepts it, surfaces an input card, and feeds the typed
    /// answer back as the tool result.
    case userInput
}

enum AgentToolCallStatus: String, Codable {
    case pendingApproval
    case awaitingConfirm
    case awaitingUserAnswer
    case running
    case succeeded
    case failed
    case denied
}

extension AgentToolCallStatus {
    var isBlockingForUserDecision: Bool {
        switch self {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return true
        case .running, .succeeded, .failed, .denied:
            return false
        }
    }
}

struct AgentToolParameter: Codable, Equatable {
    enum ParameterType: String, Codable {
        case string
        case integer
        case boolean
        case stringArray
    }

    let name: String
    let type: ParameterType
    let description: String
    let required: Bool
}

struct AgentToolDescriptor: Equatable {
    let name: String
    let description: String
    let risk: AgentToolRisk
    let parameters: [AgentToolParameter]
}

struct AgentQueuedDispatchSnapshot: Equatable {
    let userMessageID: AgentMessage.ID
    let text: String
    let imageCount: Int
    let textAttachmentCount: Int
    let skillCount: Int
    let providerID: String
    let enqueuedAt: Date
}

struct AgentSessionQueueSnapshot: Equatable {
    let queuedMessages: [AgentQueuedMessage]
    let pendingDispatches: [AgentQueuedDispatchSnapshot]
}

struct AgentWorkspaceSessionSnapshot: Equatable {
    let id: AgentSession.ID
    let title: String
    let workspaceRootPath: String?
    let workspaceDisplayName: String
    let isActive: Bool
    let isPinned: Bool
    let isArchived: Bool
    let isResponding: Bool
    let isAwaitingProviderSlot: Bool
    let queuedMessageCount: Int
    let updatedAt: Date
    let lastActivityAt: Date
    let interactionMode: AgentInteractionMode
    let approvalMode: AgentApprovalMode
    let executionAgent: AgentExecutionAgent
    let titleIsUserSet: Bool
}

struct AgentSessionTitleSuggestionSnapshot: Equatable {
    let currentTitle: String
    let suggestedTitle: String?
    let modelID: String?
}

struct AgentToolContext {
    /// Workspace root. All filesystem tools must refuse paths outside this.
    let rootDirectory: URL?
    /// Canonical workspace binding. For local workspaces this mirrors
    /// `rootDirectory`; for remote workspaces it carries the runtime id
    /// plus remote root path.
    let workspaceLocation: WorkspaceLocation?
    /// Remote runtime descriptor resolved by the AppState loop. Nil for
    /// local sessions or stale/deleted remote runtime ids.
    let runtimeDescriptor: RuntimeDescriptor?
    /// Runtime that's executing this tool -- used by background-job
    /// tools to scope jobs to the originating session. Nil in
    /// non-conversational call paths (tests, ad-hoc skill harness).
    let runtimeID: UUID?
    /// Stable id of the Agent turn that initiated this tool call. Background
    /// work records it separately from `runtimeID` so a user Stop targets only
    /// work created by the latest turn.
    let turnID: UUID?
    /// Shared background-job registry. Nil in non-app call paths;
    /// when nil, `run_command` with `run_in_background: true` falls
    /// back to the foreground path so behavior is still defined.
    let jobRegistry: AgentJobRegistry?
    /// Shared remote media task registry. some.im / Replicate / skill
    /// orchestration tools use it to publish async image/video progress
    /// into the side panel and chat completion-notice pipeline.
    let mediaTaskRegistry: AgentMediaTaskRegistry?
    /// Shared short-drama structure store. Script/storyboard skills use
    /// it to organize projects, episodes, shots, characters, scenes, and
    /// generated media artifact paths outside the transient chat log.
    let shortDramaStore: AgentShortDramaStore?
    /// Current-session queued user work, plus provider-dispatch entries
    /// waiting for a concurrency slot. Used by read-only queue inspection
    /// tools so the model can decide whether to defer heavy compile/release
    /// work until later queued user messages have been handled.
    let sessionQueueSnapshotProvider: (@MainActor () -> AgentSessionQueueSnapshot)?
    /// Current-workspace session list for read-only session discovery tools.
    let workspaceSessionsSnapshotProvider: (@MainActor () -> [AgentWorkspaceSessionSnapshot])?
    /// Flash/title-summary-model backed title suggestion for the current
    /// session. The model can ask for a cheap candidate, then use
    /// rename_session when the title is stale.
    let sessionTitleSuggestionProvider: (@MainActor () async -> AgentSessionTitleSuggestionSnapshot)?
    /// Effective sandbox mode chosen by the AppState approval gateway.
    /// Read-only tools and auto-approved commands get a scrubbed local
    /// environment; user-approved write/network/credential commands run
    /// in the escalated/full-user environment.
    let sandboxMode: AgentSandboxMode
    /// Optional bridge for proposal-only patch tools. The tool submits a
    /// unified diff into the session's review UI; applying it to disk is
    /// still handled by the existing user-approved patch flow.
    let patchProposalSink: (@MainActor (String?, String, Bool) async throws -> AgentPatchProposal)?
    /// Returns the CURRENT editable content for a workspace file — the open
    /// tab's (possibly unsaved) buffer when the file is open in the editor,
    /// falling back to disk. `edit_file` matches old_string against this so
    /// the synthesized diff targets exactly what the patch applier will later
    /// match against. Nil in non-app call paths (tests, skill harness); tools
    /// then read straight from disk.
    let editableContentProvider: (@MainActor (URL) throws -> String)?
    /// Live Agent-mode terminal controller. Terminal tools are intentionally
    /// tied to the visible side-panel session instead of creating hidden SSH
    /// sessions on the model's behalf.
    let terminalController: AgentInteractiveTerminalController?
    /// Host-owned session actions. These closures are only installed by the
    /// interactive AppState loop; ad-hoc runners and subagents cannot rename
    /// or move a user's conversation behind the host's approval boundary.
    let sessionRenameSink: (@MainActor (String) throws -> String)?
    let workspaceChangeSink: (@MainActor (String) throws -> String)?
    /// When set, apply_patch should ask the host to immediately apply the
    /// queued proposal using the existing patch applier and audit status.
    let patchAutoApplySource: AgentToolApprovalSource?
    /// Plain secret values resolved for this local execution only. Tool
    /// implementations must use this solely to redact stdout/stderr/errors
    /// before anything is persisted or sent back to the model.
    let secretRedactionValues: [String]

    init(
        rootDirectory: URL?,
        workspaceLocation: WorkspaceLocation? = nil,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        runtimeID: UUID? = nil,
        turnID: UUID? = nil,
        jobRegistry: AgentJobRegistry? = nil,
        mediaTaskRegistry: AgentMediaTaskRegistry? = nil,
        shortDramaStore: AgentShortDramaStore? = nil,
        sessionQueueSnapshotProvider: (@MainActor () -> AgentSessionQueueSnapshot)? = nil,
        workspaceSessionsSnapshotProvider: (@MainActor () -> [AgentWorkspaceSessionSnapshot])? = nil,
        sessionTitleSuggestionProvider: (@MainActor () async -> AgentSessionTitleSuggestionSnapshot)? = nil,
        sandboxMode: AgentSandboxMode = .readOnly,
        patchProposalSink: (@MainActor (String?, String, Bool) async throws -> AgentPatchProposal)? = nil,
        editableContentProvider: (@MainActor (URL) throws -> String)? = nil,
        patchAutoApplySource: AgentToolApprovalSource? = nil,
        terminalController: AgentInteractiveTerminalController? = nil,
        sessionRenameSink: (@MainActor (String) throws -> String)? = nil,
        workspaceChangeSink: (@MainActor (String) throws -> String)? = nil,
        secretRedactionValues: [String] = []
    ) {
        self.rootDirectory = rootDirectory
        self.workspaceLocation = workspaceLocation ?? rootDirectory.map { .local(path: $0.standardizedFileURL.path) }
        self.runtimeDescriptor = runtimeDescriptor
        self.runtimeID = runtimeID
        self.turnID = turnID
        self.jobRegistry = jobRegistry
        self.mediaTaskRegistry = mediaTaskRegistry
        self.shortDramaStore = shortDramaStore
        self.sessionQueueSnapshotProvider = sessionQueueSnapshotProvider
        self.workspaceSessionsSnapshotProvider = workspaceSessionsSnapshotProvider
        self.sessionTitleSuggestionProvider = sessionTitleSuggestionProvider
        self.sandboxMode = sandboxMode
        self.patchProposalSink = patchProposalSink
        self.editableContentProvider = editableContentProvider
        self.patchAutoApplySource = patchAutoApplySource
        self.terminalController = terminalController
        self.sessionRenameSink = sessionRenameSink
        self.workspaceChangeSink = workspaceChangeSink
        self.secretRedactionValues = Self.uniqueNonEmpty(secretRedactionValues)
    }

    var sshBackend: SSHRuntimeBackend? {
        guard let runtimeDescriptor,
              runtimeDescriptor.transport == .ssh,
              case .remote = workspaceLocation else {
            return nil
        }
        return SSHRuntimeBackend(descriptor: runtimeDescriptor)
    }

    var daemonBackend: DaemonRuntimeBackend? {
        guard let runtimeDescriptor,
              runtimeDescriptor.transport == .daemon,
              case .remote = workspaceLocation else {
            return nil
        }
        return DaemonRuntimeBackend(descriptor: runtimeDescriptor)
    }

    var remoteBackend: AgentRemoteRuntimeBackend? {
        if let sshBackend { return sshBackend }
        if let daemonBackend { return daemonBackend }
        return nil
    }

    func withAdditionalSecretRedactionValues(_ values: [String]) -> AgentToolContext {
        AgentToolContext(
            rootDirectory: rootDirectory,
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor,
            runtimeID: runtimeID,
            turnID: turnID,
            jobRegistry: jobRegistry,
            mediaTaskRegistry: mediaTaskRegistry,
            shortDramaStore: shortDramaStore,
            sessionQueueSnapshotProvider: sessionQueueSnapshotProvider,
            workspaceSessionsSnapshotProvider: workspaceSessionsSnapshotProvider,
            sessionTitleSuggestionProvider: sessionTitleSuggestionProvider,
            sandboxMode: sandboxMode,
            patchProposalSink: patchProposalSink,
            editableContentProvider: editableContentProvider,
            patchAutoApplySource: patchAutoApplySource,
            terminalController: terminalController,
            sessionRenameSink: sessionRenameSink,
            workspaceChangeSink: workspaceChangeSink,
            secretRedactionValues: secretRedactionValues + values
        )
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}

nonisolated struct AgentSourceReference: Equatable, Sendable, Identifiable {
    var id: String { url }
    let title: String?
    let url: String
    let toolName: String

    var host: String {
        guard let url = URL(string: url), let host = url.host, !host.isEmpty else {
            return self.url
        }
        return host
    }
}

nonisolated struct AgentToolResult: Equatable, Sendable {
    /// Short one-liner for the UI status row.
    let summary: String
    /// Full payload returned to the model as the tool message content.
    let payload: String
    /// Structured public references surfaced by research tools. The
    /// model still receives `payload`; UI uses this compact list for
    /// clickable source affordances after the turn.
    let references: [AgentSourceReference]
    /// Images the tool produced (e.g. `capture_screenshot`). These ride
    /// along on the resulting `role == .tool` message so vision-capable
    /// providers see the pixels directly (Anthropic attaches them as
    /// `tool_result` image blocks); text-only providers ignore them and
    /// fall back to `payload`. Downscaled at capture time to keep context
    /// and memory bounded — never store an unscaled retina screenshot here.
    let images: [AgentImageAttachment]

    init(
        summary: String,
        payload: String,
        references: [AgentSourceReference] = [],
        images: [AgentImageAttachment] = []
    ) {
        self.summary = summary
        self.payload = payload
        self.references = references
        self.images = images
    }
}

enum AgentToolError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case noWorkspace
    case pathOutsideWorkspace(String)
    case notFound(String)
    case notRegular(String)
    case binaryFile(String)
    case fileTooLarge(String)
    case commandFailed(Int32, String)
    case commandTimeout
    case unknownTool(String)
    case invalidRegex(String)
    case httpFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing argument: \(name)"
        case .invalidArgument(let detail):
            return "Invalid argument: \(detail)"
        case .noWorkspace:
            return "Open a project folder before using this tool."
        case .pathOutsideWorkspace(let path):
            return "Path is outside the workspace: \(path)"
        case .notFound(let path):
            return "Path does not exist: \(path)"
        case .notRegular(let path):
            return "Path is not a regular file: \(path)"
        case .binaryFile(let path):
            return "File looks binary, refusing to read: \(path)"
        case .fileTooLarge(let path):
            return "File is too large to read inline: \(path)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command exited with status \(code)."
            }
            return "Command exited with status \(code): \(trimmed)"
        case .commandTimeout:
            return "Command timed out."
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidRegex(let detail):
            return "Invalid regular expression: \(detail)"
        case .httpFailed(let status, let detail):
            return "HTTP \(status): \(detail)"
        }
    }

    func redacted(secretValues: [String]) -> AgentToolError {
        guard !secretValues.isEmpty else { return self }
        switch self {
        case .missingArgument(let name):
            return .missingArgument(AgentSecretStore.redact(name, secretValues: secretValues))
        case .invalidArgument(let detail):
            return .invalidArgument(AgentSecretStore.redact(detail, secretValues: secretValues))
        case .noWorkspace:
            return .noWorkspace
        case .pathOutsideWorkspace(let path):
            return .pathOutsideWorkspace(AgentSecretStore.redact(path, secretValues: secretValues))
        case .notFound(let path):
            return .notFound(AgentSecretStore.redact(path, secretValues: secretValues))
        case .notRegular(let path):
            return .notRegular(AgentSecretStore.redact(path, secretValues: secretValues))
        case .binaryFile(let path):
            return .binaryFile(AgentSecretStore.redact(path, secretValues: secretValues))
        case .fileTooLarge(let path):
            return .fileTooLarge(AgentSecretStore.redact(path, secretValues: secretValues))
        case .commandFailed(let code, let stderr):
            return .commandFailed(code, AgentSecretStore.redact(stderr, secretValues: secretValues))
        case .commandTimeout:
            return .commandTimeout
        case .unknownTool(let name):
            return .unknownTool(AgentSecretStore.redact(name, secretValues: secretValues))
        case .invalidRegex(let detail):
            return .invalidRegex(AgentSecretStore.redact(detail, secretValues: secretValues))
        case .httpFailed(let status, let detail):
            return .httpFailed(status, AgentSecretStore.redact(detail, secretValues: secretValues))
        }
    }
}

enum AgentToolDecision {
    case approved
    case denied(reason: String)
    case answered(String)
}

// MARK: - Tool call record (UI state)

/// How a write-tier tool call ended up running. `.user` covers both the
/// per-call Allow button and the legacy auto-allow path. `.alwaysAllowList`
/// means the user previously pinned this command signature. `.staticAllowlist`
/// means a static safety policy flagged it as low-risk, including validated
/// public web fetches used for Plan research. `.llmJudge`
/// means the LLM judge classifier approved it as non-malicious work. `.goalMode` means the
/// session was in Goal mode, which auto-approves write-tier calls
/// (danger-tier still gates on the user). `.workspaceAccess` means the
/// current session's composer approval mode grants write-tier access
/// inside the active workspace. nil = either pure read (never gated) or
/// still pending.
enum AgentToolApprovalSource: String, Equatable, Codable {
    case user
    case alwaysAllowList
    case staticAllowlist
    case llmJudge
    case goalMode
    case workspaceAccess
    /// The user approved a call that requires access outside the default
    /// sandbox boundary (network, credentials/keychain, system paths, or
    /// destructive shell syntax).
    case escalated
    /// The user marked this MCP server as fully trusted ("my own MCP")
    /// in MCP settings -- every call to it auto-runs, writes included.
    case trustedServer
}

struct AgentToolCall: Identifiable, Equatable {
    let id: UUID
    let messageID: UUID
    /// Provider-issued tool_call id (used to thread results back).
    let externalID: String
    let toolName: String
    var arguments: [String: AgentJSONValue]
    let risk: AgentToolRisk
    var status: AgentToolCallStatus
    var result: AgentToolResult?
    var errorMessage: String?
    /// Set when a write-tier tool call was auto-approved. Used by the UI
    /// to surface a small "Auto-approved" note so the user can audit
    /// what slipped through.
    var approvalSource: AgentToolApprovalSource?
    /// For `spawn_agent`: the effective model the child loop actually
    /// runs on (parent model, or the `model` override). Stamped when the
    /// spawn starts so the card can answer "用的哪个子代理" — previously
    /// this was collected in the registry but never surfaced in the UI.
    var subagentModel: String?
    /// For `spawn_agent`: a short live-progress line for the child loop
    /// ("第 3/12 轮 · 5 次工具"), refreshed each round so the card shows
    /// forward motion instead of an opaque "委派中" spinner.
    var subagentProgress: String?

    init(
        id: UUID = UUID(),
        messageID: UUID,
        externalID: String,
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        status: AgentToolCallStatus,
        result: AgentToolResult? = nil,
        errorMessage: String? = nil,
        approvalSource: AgentToolApprovalSource? = nil,
        subagentModel: String? = nil,
        subagentProgress: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.externalID = externalID
        self.toolName = toolName
        self.arguments = arguments
        self.risk = risk
        self.status = status
        self.result = result
        self.errorMessage = errorMessage
        self.approvalSource = approvalSource
        self.subagentModel = subagentModel
        self.subagentProgress = subagentProgress
    }
}

// MARK: - JSON helpers

/// Lightweight JSON value type so we can round-trip arbitrary tool arguments
/// without depending on Foundation's `Any`-based JSON serialization.
enum AgentJSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    nonisolated var displaySummary: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            let trimmed = value.replacingOccurrences(of: "\n", with: " ")
            if trimmed.count > 80 {
                return String(trimmed.prefix(80)) + "…"
            }
            return trimmed
        case .array(let values):
            return "[\(values.count) items]"
        case .object(let dict):
            return "{\(dict.count) keys}"
        }
    }

    nonisolated static func decode(from data: Data) throws -> AgentJSONValue {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return wrap(parsed)
    }

    nonisolated static func decode(from string: String) -> AgentJSONValue {
        guard let data = string.data(using: .utf8) else { return .string(string) }
        do {
            return try decode(from: data)
        } catch {
            return .string(string)
        }
    }

    nonisolated static func wrap(_ value: Any) -> AgentJSONValue {
        if value is NSNull { return .null }
        if let boolean = value as? Bool { return .bool(boolean) }
        if let number = value as? NSNumber {
            if CFNumberGetType(number) == .charType { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] { return .array(array.map { wrap($0) }) }
        if let dict = value as? [String: Any] {
            var converted: [String: AgentJSONValue] = [:]
            for (key, raw) in dict {
                converted[key] = wrap(raw)
            }
            return .object(converted)
        }
        return .null
    }

    nonisolated var rawAny: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.rawAny)
        case .object(let dict):
            var result: [String: Any] = [:]
            for (key, value) in dict {
                result[key] = value.rawAny
            }
            return result
        }
    }

    nonisolated func stringValue() -> String? {
        if case .string(let value) = self { return value }
        return nil
    }

    nonisolated func intValue() -> Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    nonisolated func boolValue() -> Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    nonisolated func stringArrayValue() -> [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap { $0.stringValue() }
        // Only treat the array as "string array" when every element was
        // a string -- partial matches are ambiguous enough to skip.
        guard strings.count == values.count else { return nil }
        return strings
    }
}
