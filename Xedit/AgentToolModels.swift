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

/// Runtime-only marker for a manual approval that belongs to the current
/// provider round but has not reached its serial execution slot yet. Queued
/// calls stay non-interactive until the preceding tool has settled, so the
/// user can never submit a decision into a future continuation.
nonisolated enum AgentSerialToolApprovalQueue {
    static let argumentKey = "_serial_approval_queued"

    static func contains(_ call: AgentToolCall) -> Bool {
        call.arguments[argumentKey]?.boolValue() == true
    }
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
    let presentationScope: AgentSessionPresentationScope
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
    let goalStatement: String?
    let goalCompletedItemCount: Int
    let goalTotalItemCount: Int
    let goalIsComplete: Bool
    let goalPlanningPhase: AgentGoalPlanningState.Phase?
    let dispatchParentProjectID: UUID?
    let dispatchTaskID: UUID?
    let isDispatchProject: Bool
    let isDispatchPaused: Bool

    /// The session belongs to the dispatch console — either a project created
    /// there or one of its task sessions. The console is a separate surface
    /// with its own lifecycle, so ordinary chat must not offer to walk the
    /// user into it; a goal that was never created there must not be filed
    /// under it either.
    var isDispatchOwned: Bool {
        presentationScope == .dispatchBoard || dispatchParentProjectID != nil
    }
}

struct AgentSessionTitleSuggestionSnapshot: Equatable {
    let currentTitle: String
    let suggestedTitle: String?
    let modelID: String?
}

nonisolated enum AgentDelegatedApprovalKind: String, Sendable {
    case command
    case fileChange
    case permissions
}

nonisolated struct AgentDelegatedApprovalRequest: Sendable {
    let id: String
    let executor: AgentExecutionAgent
    let kind: AgentDelegatedApprovalKind
    let command: String?
    let cwd: String?
    let reason: String?
    let filePaths: [String]
    let requestedPermissions: String?
    let allowsSessionApproval: Bool
}

nonisolated enum AgentDelegatedApprovalDecision: Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

struct AgentToolContext {
    /// Workspace root. All filesystem tools must refuse paths outside this.
    let rootDirectory: URL?
    /// Every local folder explicitly attached to the owning Project. The
    /// session root remains first/default; absolute paths may target any root.
    let workspaceRoots: [URL]
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
    /// Active Goal phase. Nil outside a phased Goal or while its roadmap is
    /// still being planned. Dev servers inherit this ownership automatically.
    let goalPhaseID: String?
    let isGoalMode: Bool
    /// User-visible title of the conversation that owns a native Computer Use
    /// lease. Kept separate from runtimeID so the global control indicator can
    /// identify a background task without reaching back into AppState.
    let computerUseSessionTitle: String?
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
    /// Synchronous persistence barrier used immediately before a helper may
    /// trigger a macOS system permission prompt. The interactive host installs
    /// this closure so the current transcript is on disk even if macOS asks the
    /// user to restart a permissioned process.
    let sessionPersistenceBarrier: (@MainActor () -> Void)?
    /// Resolved environment for commands executed on this Mac. App-owned
    /// contexts merge Settings → Terminal variables into the normal command
    /// PATH before installing this value. Remote backends intentionally ignore
    /// it and resolve their environment on the remote runtime.
    let localCommandEnvironment: [String: String]?
    /// Effective sandbox mode chosen by the AppState approval gateway.
    /// Read-only tools and auto-approved commands get a scrubbed local
    /// environment; user-approved write/network/credential commands run
    /// in the escalated/full-user environment.
    let sandboxMode: AgentSandboxMode
    /// When non-nil, a background `run_command` may replay exactly once
    /// outside seatbelt after a positively identified sandbox denial. The
    /// source is host-derived from Smart Approval / Always Allow / dispatch;
    /// model arguments can never opt into this capability.
    let automaticBackgroundSandboxRetryApprovalSource: AgentToolApprovalSource?
    /// True when the calling loop can spawn subagents (the main session).
    /// Child loops share this tool runner but cannot spawn, so hints that end
    /// in "spawn_agent" are suppressed for them — a recipe the caller cannot
    /// execute is pure noise in a small window.
    let canSpawnSubagents: Bool
    /// True only for scheduler-owned dispatch child sessions. External agent
    /// adapters use this host-derived bit to select their non-interactive
    /// permission mode; it is intentionally not accepted from model arguments.
    let isUnattendedDispatchTask: Bool
    /// Optional bridge for proposal-only patch tools. The tool submits a
    /// unified diff into the session's review UI; applying it to disk is
    /// still handled by the existing user-approved patch flow.
    let patchProposalSink: (@MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal)?
    /// Returns the CURRENT editable content for a workspace file — the open
    /// tab's (possibly unsaved) buffer when the file is open in the editor,
    /// falling back to disk. `edit_file` matches old_string against this so
    /// the synthesized diff targets exactly what the patch applier will later
    /// match against. Nil in non-app call paths (tests, skill harness); tools
    /// then read straight from disk.
    let editableContentProvider: (@MainActor (URL) throws -> String)?
    /// Applies an ACP reverse-file write through the host editor and disk
    /// bookkeeping after the protocol driver has enforced workspace bounds
    /// and obtained delegated approval.
    let delegatedFileWriteHandler: (@MainActor (URL, String) throws -> Void)?
    /// Live Agent-mode terminal controller. Terminal tools are intentionally
    /// tied to the visible side-panel session instead of creating hidden SSH
    /// sessions on the model's behalf.
    let terminalController: AgentInteractiveTerminalController?
    /// Receives throttled, bounded and already-redacted output from a visible
    /// delegated CLI terminal. Nil for ordinary tools and non-app harnesses.
    let delegatedProgressSink: (@MainActor (AgentDelegatedTerminalProgressUpdate) -> Void)?
    /// Host-owned session actions. These closures are only installed by the
    /// interactive AppState loop; ad-hoc runners and subagents cannot rename
    /// or move a user's conversation behind the host's approval boundary.
    let sessionRenameSink: (@MainActor (String) throws -> String)?
    let workspaceChangeSink: (@MainActor (String) throws -> String)?
    /// Nested approval requests from bidirectional coding-agent transports.
    /// Interactive AppState contexts route these through the same cards and
    /// decision waiter as first-party WillDeep tools.
    let delegatedApprovalHandler: (@MainActor (AgentDelegatedApprovalRequest) async -> AgentDelegatedApprovalDecision)?
    /// Main-session bridge for the read-only `load_tool_pack` router. Ad-hoc
    /// harnesses and child agents leave this nil and cannot mutate a parent
    /// conversation's prompt surface.
    let toolPackActivationSink: (@MainActor ([AgentToolPackID]) -> Set<AgentToolPackID>)?
    /// When set, apply_patch should ask the host to immediately apply the
    /// queued proposal using the existing patch applier and audit status.
    let patchAutoApplySource: AgentToolApprovalSource?
    /// Plain secret values resolved for this local execution only. Tool
    /// implementations must use this solely to redact stdout/stderr/errors
    /// before anything is persisted or sent back to the model.
    let secretRedactionValues: [String]

    init(
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = [],
        workspaceLocation: WorkspaceLocation? = nil,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        runtimeID: UUID? = nil,
        turnID: UUID? = nil,
        goalPhaseID: String? = nil,
        isGoalMode: Bool = false,
        computerUseSessionTitle: String? = nil,
        jobRegistry: AgentJobRegistry? = nil,
        mediaTaskRegistry: AgentMediaTaskRegistry? = nil,
        shortDramaStore: AgentShortDramaStore? = nil,
        sessionQueueSnapshotProvider: (@MainActor () -> AgentSessionQueueSnapshot)? = nil,
        workspaceSessionsSnapshotProvider: (@MainActor () -> [AgentWorkspaceSessionSnapshot])? = nil,
        sessionTitleSuggestionProvider: (@MainActor () async -> AgentSessionTitleSuggestionSnapshot)? = nil,
        sessionPersistenceBarrier: (@MainActor () -> Void)? = nil,
        localCommandEnvironment: [String: String]? = nil,
        sandboxMode: AgentSandboxMode = .readOnly,
        automaticBackgroundSandboxRetryApprovalSource: AgentToolApprovalSource? = nil,
        canSpawnSubagents: Bool = false,
        isUnattendedDispatchTask: Bool = false,
        patchProposalSink: (@MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal)? = nil,
        editableContentProvider: (@MainActor (URL) throws -> String)? = nil,
        delegatedFileWriteHandler: (@MainActor (URL, String) throws -> Void)? = nil,
        patchAutoApplySource: AgentToolApprovalSource? = nil,
        terminalController: AgentInteractiveTerminalController? = nil,
        delegatedProgressSink: (@MainActor (AgentDelegatedTerminalProgressUpdate) -> Void)? = nil,
        sessionRenameSink: (@MainActor (String) throws -> String)? = nil,
        workspaceChangeSink: (@MainActor (String) throws -> String)? = nil,
        delegatedApprovalHandler: (@MainActor (AgentDelegatedApprovalRequest) async -> AgentDelegatedApprovalDecision)? = nil,
        toolPackActivationSink: (@MainActor ([AgentToolPackID]) -> Set<AgentToolPackID>)? = nil,
        secretRedactionValues: [String] = []
    ) {
        self.rootDirectory = rootDirectory
        self.workspaceRoots = Self.uniqueWorkspaceRoots(
            [rootDirectory].compactMap { $0 } + additionalWorkspaceRoots
        )
        self.workspaceLocation = workspaceLocation ?? rootDirectory.map { .local(path: $0.standardizedFileURL.path) }
        self.runtimeDescriptor = runtimeDescriptor
        self.runtimeID = runtimeID
        self.turnID = turnID
        self.goalPhaseID = goalPhaseID
        self.isGoalMode = isGoalMode
        self.computerUseSessionTitle = computerUseSessionTitle
        self.jobRegistry = jobRegistry
        self.mediaTaskRegistry = mediaTaskRegistry
        self.shortDramaStore = shortDramaStore
        self.sessionQueueSnapshotProvider = sessionQueueSnapshotProvider
        self.workspaceSessionsSnapshotProvider = workspaceSessionsSnapshotProvider
        self.sessionTitleSuggestionProvider = sessionTitleSuggestionProvider
        self.sessionPersistenceBarrier = sessionPersistenceBarrier
        self.localCommandEnvironment = localCommandEnvironment
        self.sandboxMode = sandboxMode
        self.automaticBackgroundSandboxRetryApprovalSource = automaticBackgroundSandboxRetryApprovalSource
        self.canSpawnSubagents = canSpawnSubagents
        self.isUnattendedDispatchTask = isUnattendedDispatchTask
        self.patchProposalSink = patchProposalSink
        self.editableContentProvider = editableContentProvider
        self.delegatedFileWriteHandler = delegatedFileWriteHandler
        self.patchAutoApplySource = patchAutoApplySource
        self.terminalController = terminalController
        self.delegatedProgressSink = delegatedProgressSink
        self.sessionRenameSink = sessionRenameSink
        self.workspaceChangeSink = workspaceChangeSink
        self.delegatedApprovalHandler = delegatedApprovalHandler
        self.toolPackActivationSink = toolPackActivationSink
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
            additionalWorkspaceRoots: Array(workspaceRoots.dropFirst()),
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor,
            runtimeID: runtimeID,
            turnID: turnID,
            goalPhaseID: goalPhaseID,
            isGoalMode: isGoalMode,
            computerUseSessionTitle: computerUseSessionTitle,
            jobRegistry: jobRegistry,
            mediaTaskRegistry: mediaTaskRegistry,
            shortDramaStore: shortDramaStore,
            sessionQueueSnapshotProvider: sessionQueueSnapshotProvider,
            workspaceSessionsSnapshotProvider: workspaceSessionsSnapshotProvider,
            sessionTitleSuggestionProvider: sessionTitleSuggestionProvider,
            sessionPersistenceBarrier: sessionPersistenceBarrier,
            localCommandEnvironment: localCommandEnvironment,
            sandboxMode: sandboxMode,
            automaticBackgroundSandboxRetryApprovalSource: automaticBackgroundSandboxRetryApprovalSource,
            canSpawnSubagents: canSpawnSubagents,
            isUnattendedDispatchTask: isUnattendedDispatchTask,
            patchProposalSink: patchProposalSink,
            editableContentProvider: editableContentProvider,
            delegatedFileWriteHandler: delegatedFileWriteHandler,
            patchAutoApplySource: patchAutoApplySource,
            terminalController: terminalController,
            delegatedProgressSink: delegatedProgressSink,
            sessionRenameSink: sessionRenameSink,
            workspaceChangeSink: workspaceChangeSink,
            delegatedApprovalHandler: delegatedApprovalHandler,
            toolPackActivationSink: toolPackActivationSink,
            secretRedactionValues: secretRedactionValues + values
        )
    }

    func withSandboxMode(_ mode: AgentSandboxMode) -> AgentToolContext {
        AgentToolContext(
            rootDirectory: rootDirectory,
            additionalWorkspaceRoots: Array(workspaceRoots.dropFirst()),
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor,
            runtimeID: runtimeID,
            turnID: turnID,
            goalPhaseID: goalPhaseID,
            isGoalMode: isGoalMode,
            computerUseSessionTitle: computerUseSessionTitle,
            jobRegistry: jobRegistry,
            mediaTaskRegistry: mediaTaskRegistry,
            shortDramaStore: shortDramaStore,
            sessionQueueSnapshotProvider: sessionQueueSnapshotProvider,
            workspaceSessionsSnapshotProvider: workspaceSessionsSnapshotProvider,
            sessionTitleSuggestionProvider: sessionTitleSuggestionProvider,
            sessionPersistenceBarrier: sessionPersistenceBarrier,
            localCommandEnvironment: localCommandEnvironment,
            sandboxMode: mode,
            automaticBackgroundSandboxRetryApprovalSource: automaticBackgroundSandboxRetryApprovalSource,
            canSpawnSubagents: canSpawnSubagents,
            isUnattendedDispatchTask: isUnattendedDispatchTask,
            patchProposalSink: patchProposalSink,
            editableContentProvider: editableContentProvider,
            delegatedFileWriteHandler: delegatedFileWriteHandler,
            patchAutoApplySource: patchAutoApplySource,
            terminalController: terminalController,
            delegatedProgressSink: delegatedProgressSink,
            sessionRenameSink: sessionRenameSink,
            workspaceChangeSink: workspaceChangeSink,
            delegatedApprovalHandler: delegatedApprovalHandler,
            toolPackActivationSink: toolPackActivationSink,
            secretRedactionValues: secretRedactionValues
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

    nonisolated private static func uniqueWorkspaceRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    /// Resolve a tool path against the Project's authorized folder set.
    /// Relative paths intentionally keep their historical meaning and use the
    /// session root; callers use absolute paths to address another folder.
    nonisolated func resolveWorkspaceURL(_ rawPath: String) throws -> (url: URL, root: URL) {
        guard let primaryRoot = rootDirectory?.standardizedFileURL else {
            throw AgentToolError.noWorkspace
        }
        let candidate: URL
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        } else {
            candidate = primaryRoot.appendingPathComponent(rawPath).standardizedFileURL
        }
        guard let matchedRoot = workspaceRoots
            .filter({ candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) else {
            throw AgentToolError.pathOutsideWorkspace(rawPath)
        }
        // The lexical match above says the *spelling* is inside a root. A
        // symlink can still send the real write somewhere the user never
        // authorized, so resolve before accepting — otherwise the folder set
        // the user approved stops being the boundary it claims to be.
        guard AgentWorkspacePathGuard.containingRoot(for: candidate, roots: workspaceRoots) != nil else {
            throw AgentToolError.symlinkOutsideWorkspace(
                path: rawPath,
                resolved: AgentWorkspacePathGuard.resolvedPath(of: candidate)
            )
        }
        return (candidate, matchedRoot)
    }
}

nonisolated struct AgentSourceReference: Codable, Equatable, Sendable, Identifiable {
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
    case symlinkOutsideWorkspace(path: String, resolved: String)
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
        case .symlinkOutsideWorkspace(let path, let resolved):
            return """
            Path \(path) is a symbolic link (or sits behind one) that resolves to \(resolved), \
            which is outside every folder authorized for this project. Symbolic links do not \
            widen the authorized folder set — shell commands are blocked at the same boundary \
            by the sandbox, so the native file tools refuse it too. Tell the user to add \
            \(resolved) as a project folder (this app supports multiple folders per project), \
            then use its real path.
            """
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
            return "Command timed out before completing. Do not retry the same command unchanged: for long-running work (builds, test suites, servers) re-run it with run_in_background=true, or pass a larger timeout_seconds."
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidRegex(let detail):
            return "Invalid regular expression: \(detail)"
        case .httpFailed(let status, let detail):
            return "HTTP \(status): \(detail)"
        }
    }

    /// Exit status when the command actually ran and returned non-zero, i.e.
    /// the process started, did its job, and reported an ordinary negative
    /// answer (`corepack --version` → 127 on a machine without corepack,
    /// `grep` → 1 for "no match"). nil for everything else, including the
    /// `-1` sentinel `runCommand` throws when the process could not be
    /// launched at all — that one is a genuine malfunction.
    var completedCommandExitCode: Int32? {
        guard case .commandFailed(let code, _) = self, code > 0 else { return nil }
        return code
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
        case .symlinkOutsideWorkspace(let path, let resolved):
            return .symlinkOutsideWorkspace(
                path: AgentSecretStore.redact(path, secretValues: secretValues),
                resolved: AgentSecretStore.redact(resolved, secretValues: secretValues)
            )
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
/// means a static safety policy flagged it as low-risk, including bounded
/// local metadata changes. `.llmJudge`
/// means the LLM judge classifier approved it as non-malicious work. `.goalMode` means the
/// session was in Goal mode, which auto-approves write-tier calls
/// (danger-tier still gates on the user). `.workspaceAccess` means the
/// current session's composer approval mode grants write-tier access
/// inside the active workspace. `.controlLease` means the same runtime,
/// turn, and target already owns a live Computer Use controlling lease.
/// nil = either pure read (never gated) or still pending.
enum AgentToolApprovalSource: String, Equatable, Codable {
    case user
    case alwaysAllowList
    case staticAllowlist
    case llmJudge
    case goalMode
    /// A scheduler-owned dispatch child is running without an attached
    /// operator, so its tool call bypassed interactive approval.
    case dispatchTask
    case workspaceAccess
    /// 静默模式：命令没命中恶意黑名单，AI 裁判也说不出具体的恶意效果，
    /// 于是直接放行。刻意单列一档而不是借用 `.staticAllowlist` —— 转录里
    /// 的徽标得说实话：这不是"命中了安全白名单"，是"没找到不放行的理由"。
    case silentMode
    /// A reversible Computer Use action was authorized by the current
    /// runtime- and target-bound in-memory control lease.
    case controlLease
    /// The user approved a call that requires access outside the default
    /// sandbox boundary (network, credentials/keychain, system paths, or
    /// destructive shell syntax).
    case escalated
    /// The user marked this MCP server as fully trusted ("my own MCP")
    /// in MCP settings -- every call to it auto-runs, writes included.
    case trustedServer
    /// An editor-trade subagent patching the single file the user approved
    /// when the spawn itself was confirmed. The approval is per-file and
    /// granted up front, so its patches apply without re-asking per hunk.
    case subagentEditor
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
    /// Exit status of a command that actually ran to completion and returned
    /// non-zero. Only set for `AgentToolError.commandFailed` with a real
    /// (positive) status — a probe like `corepack --version` on a machine
    /// without corepack exits 127, which is an ordinary answer, not a
    /// malfunction. Stays nil when the process never ran (launch failure,
    /// which uses -1), timed out, or when the failure is anything else, so
    /// the UI can keep alarming colors for failures that need attention.
    var commandExitCode: Int32?
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
    /// For `spawn_agent`: stable id of the child run, used to look its
    /// per-round transcript up in `AgentSubagentTranscriptStore` when the
    /// user opens the inspector from this card.
    var subagentRunID: UUID?
    /// For Claude Code / Codex CLI / Cursor Agent / Cline CLI: host-owned
    /// phase, attempt and bounded redacted output tail. Render-only; the
    /// durable acceptance state lives in `AgentDelegatedTaskRun`.
    var delegatedProgress: AgentDelegatedLiveProgress?

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
        commandExitCode: Int32? = nil,
        approvalSource: AgentToolApprovalSource? = nil,
        subagentModel: String? = nil,
        subagentProgress: String? = nil,
        subagentRunID: UUID? = nil,
        delegatedProgress: AgentDelegatedLiveProgress? = nil
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
        self.commandExitCode = commandExitCode
        self.approvalSource = approvalSource
        self.subagentModel = subagentModel
        self.subagentProgress = subagentProgress
        self.subagentRunID = subagentRunID
        self.delegatedProgress = delegatedProgress
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
            // Some providers escape GitHub Actions expressions as `\${{ ... }}`
            // while streaming tool arguments. `\$` is not a legal JSON escape,
            // so JSONSerialization rejects the entire call before create_file /
            // edit_file can write the otherwise ordinary text. Repair only this
            // narrow, unambiguous provider mistake; valid JSON is always decoded
            // above without modification.
            let repaired = string.replacingOccurrences(of: #"\${{"#, with: "${{")
            if repaired != string,
               let repairedData = repaired.data(using: .utf8),
               let decoded = try? decode(from: repairedData) {
                return decoded
            }
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
