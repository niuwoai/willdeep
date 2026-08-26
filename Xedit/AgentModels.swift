//
//  AgentModels.swift
//  WillDeep
//
//  Lightweight models for the built-in project agent.
//

import Foundation

/// Durable marker for a Goal-backed model turn that was live when the app
/// process stopped. It is armed before provider dispatch and cleared only
/// after the turn reaches a normal terminal path or the user explicitly
/// stops it. A surviving marker therefore authorizes one safe launch-time
/// continuation without treating every merely-incomplete Plan as runnable.
nonisolated struct AgentGoalTurnRecoveryCheckpoint: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date

    init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
    }
}

/// Durable Responses API cursor metadata for one conversation.
///
/// Only opaque response ids and SHA-256 request signatures are persisted.
/// Prompt text, tool schemas, credentials, and duplicate message bodies are
/// deliberately excluded from this snapshot.
nonisolated struct AgentOpenAIResponsesContinuationSnapshot: Codable, Equatable {
    let responseID: String
    let contextSignature: Data
    let inputItemSignatures: [Data]
    let updatedAt: Date
    /// Start of the relay-managed hard retention epoch. Nil for native
    /// OpenAI cursors and for snapshots written before the WillDeep relay
    /// state protocol existed.
    let stateEpochStartedAt: Date?

    init(
        responseID: String,
        contextSignature: Data,
        inputItemSignatures: [Data],
        updatedAt: Date,
        stateEpochStartedAt: Date? = nil
    ) {
        self.responseID = responseID
        self.contextSignature = contextSignature
        self.inputItemSignatures = inputItemSignatures
        self.updatedAt = updatedAt
        self.stateEpochStartedAt = stateEpochStartedAt
    }
}

/// The product surface that owns a persisted session. Dedicated workflow
/// sessions still reuse AgentSessionStore, but must not leak into the ordinary
/// workspace conversation list.
nonisolated enum AgentSessionPresentationScope: String, Codable, Equatable {
    case workspace
    case dispatchBoard
    case roundtable
}

/// A persisted Agent conversation. Lives as one JSON file under the app's
/// Application Support directory. `workspaceLocation` is the canonical
/// workspace binding; `workspaceRootPath` remains for local legacy sessions.
// The persisted model graph is `nonisolated`: the project compiles with
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which would otherwise make
// these types' synthesized Codable conformances main-actor-isolated —
// and AgentSessionStore encodes them on a background write queue. Pure
// value types with no main-actor state; keep new members that way.
nonisolated struct AgentSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// Optional — sessions started before a folder was picked have no root.
    var workspaceRootPath: String?
    /// Canonical workspace binding. Remote sessions persist here while
    /// `workspaceRootPath` remains as the local-only compatibility slot.
    var workspaceLocation: WorkspaceLocation?
    /// Optional sidebar grouping root when this conversation executes in a
    /// Git worktree. The tools use `workspaceLocation`; the sidebar continues
    /// to group the conversation under the original project workspace.
    var sidebarWorkspaceRootPath: String?
    /// Complete restore recipe for a WillDeep-managed Git worktree. Nil for
    /// primary workspaces, remote workspaces, and legacy/external worktrees
    /// that cannot be recreated without guessing.
    var worktreeRecoveryInfo: AgentWorktreeRecoveryInfo?
    /// Explicit project ownership, once resolved. Nil means "not in a managed
    /// project" and falls back to the path-based grouping below, which is
    /// what every session predating projects decodes to.
    ///
    /// Resolution is persisted rather than recomputed: a folder may belong to
    /// several projects, so leaving it dynamic would let adding a project
    /// silently move old conversations into a different group.
    var projectID: UUID?
    /// Dedicated workflow sessions are persisted like conversations, but are
    /// presented only by their owning surface.
    var presentationScope: AgentSessionPresentationScope
    /// Dispatch task conversations belong to one top-level project. Keeping
    /// this ownership on the session prevents task runtimes from being
    /// projected back into the dispatch sidebar as duplicate projects.
    var dispatchParentProjectID: UUID?
    var dispatchTaskID: UUID?
    /// Best-effort local folder identity for recovering from Finder moves
    /// or renames. Tools do not poll this on the happy path; it is consulted
    /// only after the recorded path appears to have failed.
    var localWorkspaceIdentity: LocalWorkspaceIdentity?
    /// Model id captured at the time the session was last sent (so changing
    /// the global model later doesn't silently switch what an old chat used).
    var modelID: String?
    /// Provider snapshot captured alongside `modelID` so usage analytics
    /// can group historical sessions by the actual configured provider.
    /// `providerEntryID` identifies the exact library entry. `providerID`
    /// alone is insufficient because multiple custom providers share it.
    var providerEntryID: UUID?
    var providerID: String?
    var providerDisplayName: String?
    /// Server-side Responses continuation cursor and stable request hashes.
    /// Optional for backwards compatibility and cleared automatically when
    /// the upstream reports that the stored response no longer exists.
    var openAIResponsesContinuation: AgentOpenAIResponsesContinuationSnapshot?
    /// Per-session "省心托管" (some.im managed routing) state. Non-nil only
    /// when the user selected managed routing for this session; carries the
    /// only-goes-up capability floor. Orthogonal to `modelID` / override —
    /// managed sessions never write a resolved model into `modelID`, so the
    /// managed selection can never leak downstream as a real model name.
    var managedRouting: AgentManagedRoutingState?
    let createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]
    /// Automatic host-side Worker invocations have no provider-emitted tool
    /// call to persist on. Keep their request/run accounting beside the
    /// transcript so reopening a chat and the stats dashboard see the same
    /// work the live execution card showed.
    var hostWorkerRuns: [AgentHostWorkerRunRecord]?
    /// Model-facing summary of older messages. This is intentionally
    /// separate from `messages`: context compression must shrink only the
    /// next provider request, never the user's local transcript.
    var contextSummary: String?
    /// The latest local message included in `contextSummary`. Requests send
    /// the summary plus messages after this id; the UI still renders every
    /// original message from `messages`.
    var contextSummaryThroughMessageID: AgentMessage.ID?
    /// True once the Agent has successfully applied at least one patch in
    /// this session. Drives whether the "正在编辑 / N 个文件已更改" worktree
    /// card appears — empty/new sessions never show it, even when the
    /// underlying repo has unrelated uncommitted changes.
    var didEditFiles: Bool
    /// Workspace-relative paths the Agent has actually written to in this
    /// session. The worktree-change card reads from this — anything not
    /// in here (user's own diffs, untracked `.pyc` etc.) is filtered out.
    var agentEditedPaths: [String]
    /// Workspace-relative, user-facing files created by the Agent in this
    /// conversation. Unlike `agentEditedPaths`, this is an artifact ledger:
    /// it survives Git commits and excludes transient build/cache output.
    var agentArtifactPaths: [String]
    /// Per-session interaction mode. Persisted so re-selecting a session
    /// resumes ordinary/goal context without the user having to redo setup.
    var interactionMode: AgentInteractionMode
    /// Per-session tool approval behavior. Defaults to smart approval
    /// for backwards compatibility with existing sessions.
    var approvalMode: AgentApprovalMode
    /// Which execution backend the composer should use for the next
    /// user turn. Defaults to WillDeep's native agent loop.
    var executionAgent: AgentExecutionAgent
    /// Durable contracts, evidence, retries, and acceptance verdicts for
    /// external coding-agent work. WillDeep owns this ledger; delegated CLIs
    /// can contribute evidence but cannot rewrite the contract or verdict.
    var delegatedTaskRuns: [AgentDelegatedTaskRun]
    /// Per-session opt-in specialist packs. Default empty keeps broad,
    /// domain-specific tools out of ordinary chats until the user turns
    /// an expert on.
    var activeExperts: Set<AgentExpert>
    /// Visible execution plan used by both ordinary and Goal conversations.
    /// Planning is a task phase, not a top-level interaction mode.
    var currentPlan: AgentPlan?
    /// Goal-mode definition (statement + acceptance checklist). Nil
    /// outside Goal mode, or when Goal mode is on but the user hasn't
    /// defined a goal yet.
    var currentGoal: AgentGoal?
    /// Host-owned evidence ledger for Goal Teams planning. Optional and
    /// tolerantly decoded so sessions written before this feature remain valid.
    var goalPlanningState: AgentGoalPlanningState?
    /// Coarse execution phases for a long-running Goal. Only the active phase
    /// owns `currentPlan`; future phases stay intentionally high-level so the
    /// initial proposal cannot explode into dozens of stale micro-steps.
    var goalRoadmap: AgentGoalRoadmap?
    /// Non-nil only while an approved Goal-backed Plan turn is expected to be
    /// alive. Surviving app termination makes the session eligible for one
    /// launch recovery; explicit Stop and normal turn completion clear it.
    var goalTurnRecoveryCheckpoint: AgentGoalTurnRecoveryCheckpoint?
    /// Recent automatic learning outcomes for this session. These are
    /// product-visible audit events for memory, skill, and MCP discovery
    /// actions captured at turn end.
    var learningEvents: [AgentLearningEvent]
    /// Structured record of which memories / attached skills were
    /// injected into the latest turn context.
    var latestTurnRecall: AgentTurnRecallSnapshot?
    /// Parsed local documents kept available for future turns in this
    /// conversation. The extracted sections are persisted so reopening a
    /// session does not repeatedly OCR or unzip unchanged files.
    var documentAttachments: [AgentFileAttachment]
    /// User-selected folders indexed as session-scoped local knowledge.
    var knowledgeFolders: [AgentKnowledgeFolder]
    var documentTaskMode: AgentDocumentTaskMode
    var redactSensitiveAttachmentContent: Bool
    /// Per-session right side-panel state. The visible Agent pane swaps
    /// this state when the user switches sessions, so a panel opened in
    /// one chat is restored when returning to that chat without leaking
    /// into unrelated conversations.
    var sidePanelState: AgentSidePanelState
    /// When the user pinned this session to the global pinned section.
    /// Nil = not pinned. We store the timestamp (not a bool) so pinned
    /// conversations across every workspace can be ordered
    /// "most-recently-pinned first" in the sidebar.
    var pinnedAt: Date?
    /// When the user archived this session. Nil = active. Archived
    /// sessions are hidden from the regular workspace list and
    /// surfaced under a collapsed "已归档" group at the bottom of each
    /// workspace.
    var archivedAt: Date?
    /// "This title is final — stop auto-deriving from messages."
    /// Set to true in two cases:
    ///   1. The user explicitly renamed the session via the sidebar.
    ///   2. The LLM title summarizer (see
    ///      AppStateAgentTitleSummarizer) successfully produced a
    ///      polished title from the first user→assistant exchange.
    /// In both cases we don't want `AgentRuntime.persist()`'s
    /// every-turn `deriveTitle(...)` (which falls back to the prefix
    /// of the first user message) to clobber the good title. False
    /// means "title is still the placeholder prefix; feel free to
    /// update on next persist".
    var titleIsUserSet: Bool
    /// Set when this conversation was spawned by a scheduled routine
    /// (`AppState.fireRoutine`). Nil for anything a human started. Unattended
    /// runs get a longer transient-network retry window than interactive
    /// chats, because nobody is sitting there to click 重试.
    var originRoutineID: UUID?
    /// See `AgentTurnFailure`. Non-nil only while the newest turn in this
    /// conversation ended in a failure the user has neither retried nor
    /// dismissed.
    var lastTurnFailure: AgentTurnFailure?

    init(
        id: UUID = UUID(),
        title: String = AgentSessionStore.defaultTitle,
        workspaceRootPath: String? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        sidebarWorkspaceRootPath: String? = nil,
        worktreeRecoveryInfo: AgentWorktreeRecoveryInfo? = nil,
        projectID: UUID? = nil,
        presentationScope: AgentSessionPresentationScope = .workspace,
        dispatchParentProjectID: UUID? = nil,
        dispatchTaskID: UUID? = nil,
        localWorkspaceIdentity: LocalWorkspaceIdentity? = nil,
        modelID: String? = nil,
        providerEntryID: UUID? = nil,
        providerID: String? = nil,
        providerDisplayName: String? = nil,
        openAIResponsesContinuation: AgentOpenAIResponsesContinuationSnapshot? = nil,
        managedRouting: AgentManagedRoutingState? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AgentMessage] = [],
        hostWorkerRuns: [AgentHostWorkerRunRecord]? = nil,
        contextSummary: String? = nil,
        contextSummaryThroughMessageID: AgentMessage.ID? = nil,
        didEditFiles: Bool = false,
        agentEditedPaths: [String] = [],
        agentArtifactPaths: [String] = [],
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart,
        executionAgent: AgentExecutionAgent = .willDeep,
        delegatedTaskRuns: [AgentDelegatedTaskRun] = [],
        activeExperts: Set<AgentExpert> = [],
        currentPlan: AgentPlan? = nil,
        currentGoal: AgentGoal? = nil,
        goalPlanningState: AgentGoalPlanningState? = nil,
        goalRoadmap: AgentGoalRoadmap? = nil,
        goalTurnRecoveryCheckpoint: AgentGoalTurnRecoveryCheckpoint? = nil,
        learningEvents: [AgentLearningEvent] = [],
        latestTurnRecall: AgentTurnRecallSnapshot? = nil,
        documentAttachments: [AgentFileAttachment] = [],
        knowledgeFolders: [AgentKnowledgeFolder] = [],
        documentTaskMode: AgentDocumentTaskMode = .automatic,
        redactSensitiveAttachmentContent: Bool = true,
        sidePanelState: AgentSidePanelState = .empty,
        pinnedAt: Date? = nil,
        archivedAt: Date? = nil,
        titleIsUserSet: Bool = false,
        originRoutineID: UUID? = nil,
        lastTurnFailure: AgentTurnFailure? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceRootPath = workspaceRootPath
        self.workspaceLocation = workspaceLocation ?? workspaceRootPath.map { .local(path: $0) }
        self.sidebarWorkspaceRootPath = sidebarWorkspaceRootPath
        self.worktreeRecoveryInfo = worktreeRecoveryInfo
        self.projectID = projectID
        self.presentationScope = presentationScope
        self.dispatchParentProjectID = dispatchParentProjectID
        self.dispatchTaskID = dispatchTaskID
        self.localWorkspaceIdentity = localWorkspaceIdentity
            ?? AgentWorkspaceAvailabilityResolver.captureIdentity(for: self.workspaceLocation?.localPath ?? workspaceRootPath)
        self.modelID = modelID
        self.providerEntryID = providerEntryID
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.openAIResponsesContinuation = openAIResponsesContinuation
        self.managedRouting = managedRouting
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.hostWorkerRuns = hostWorkerRuns
        self.contextSummary = contextSummary
        self.contextSummaryThroughMessageID = contextSummaryThroughMessageID
        self.didEditFiles = didEditFiles
        self.agentEditedPaths = agentEditedPaths
        self.agentArtifactPaths = agentArtifactPaths
        self.interactionMode = interactionMode
        self.approvalMode = approvalMode
        self.executionAgent = executionAgent
        self.delegatedTaskRuns = delegatedTaskRuns
        self.activeExperts = activeExperts
        self.currentPlan = currentPlan
        self.currentGoal = currentGoal
        self.goalPlanningState = goalPlanningState
        self.goalRoadmap = goalRoadmap
        self.goalTurnRecoveryCheckpoint = goalTurnRecoveryCheckpoint
        self.learningEvents = learningEvents
        self.latestTurnRecall = latestTurnRecall
        self.documentAttachments = documentAttachments
        self.knowledgeFolders = knowledgeFolders
        self.documentTaskMode = documentTaskMode
        self.redactSensitiveAttachmentContent = redactSensitiveAttachmentContent
        self.sidePanelState = sidePanelState
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.titleIsUserSet = titleIsUserSet
        self.originRoutineID = originRoutineID
        self.lastTurnFailure = lastTurnFailure
    }

    /// The session shape for one scheduled-routine run.
    ///
    /// A factory rather than an inline `AgentSession(...)` at the call site so
    /// `originRoutineID` is part of constructing a routine run instead of one
    /// more argument a later edit can quietly drop. Without the marker the run
    /// falls back to interactive retry behaviour, and a routine that fires into
    /// a dead network goes silent again — which is the whole bug this exists
    /// to prevent.
    static func forRoutineRun(
        routineID: UUID,
        workspaceRootPath: String?,
        modelID: String?,
        providerEntryID: UUID?,
        providerID: String?,
        providerDisplayName: String?
    ) -> AgentSession {
        AgentSession(
            workspaceRootPath: workspaceRootPath,
            modelID: modelID,
            providerEntryID: providerEntryID,
            providerID: providerID,
            providerDisplayName: providerDisplayName,
            originRoutineID: routineID
        )
    }

    var isPinned: Bool { pinnedAt != nil }
    var isArchived: Bool { archivedAt != nil }
    /// Composer mode and Goal-board projection are secondary views of a
    /// conversation, not ownership transfers. A workspace conversation stays
    /// in the workspace sidebar whether it is ordinary or Goal-driven.
    var belongsInWorkspaceSidebar: Bool {
        presentationScope == .workspace
    }

    /// True once this session carries a goal substantial enough to also be
    /// projected onto the Goals board.
    var hasBoardGoal: Bool {
        guard let currentGoal else { return false }
        return !currentGoal.isEmpty
    }

    /// When the AI last produced output in this session — the timestamp the
    /// sidebar shows and sorts by. Deliberately NOT `updatedAt`: that field
    /// gets refreshed whenever the session is persisted (including on switch
    /// away via `persistActiveAgentSession()`), so old chats wrongly read as
    /// "0m". We instead take the last non-empty assistant message's time,
    /// which is what the user means by "last activity". Fallbacks keep brand-
    /// new / pre-first-reply sessions sensible: last message of any role, then
    /// `updatedAt` for a truly empty session.
    var lastActivityAt: Date {
        if let aiTime = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.createdAt {
            return aiTime
        }
        if let lastMessageTime = messages.last?.createdAt {
            return lastMessageTime
        }
        return updatedAt
    }

    var workspaceName: String {
        if let sidebarWorkspaceRootPath, !sidebarWorkspaceRootPath.isEmpty {
            return URL(fileURLWithPath: sidebarWorkspaceRootPath).lastPathComponent
        }
        if let workspaceLocation {
            return workspaceLocation.displayName
        }
        guard let path = workspaceRootPath, !path.isEmpty else { return L10n.Workspace.noWorkspace }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var workspaceSidebarGroupKey: String {
        // A managed project owns the grouping outright: that is the whole
        // point of letting several folders share one group.
        if let projectID {
            return Self.projectSidebarGroupKeyPrefix + projectID.uuidString
        }
        if let sidebarWorkspaceRootPath, !sidebarWorkspaceRootPath.isEmpty {
            return sidebarWorkspaceRootPath
        }
        if let workspaceLocation {
            switch workspaceLocation {
            case .local(let path):
                return path.isEmpty ? Self.noWorkspaceSidebarGroupKey : path
            case .remote(let runtimeID, let path):
                let normalizedPath = RemotePathValidator.normalizedWorkspaceRoot(path)
                return "remote:\(runtimeID.uuidString):\(normalizedPath)"
            }
        }
        guard let path = workspaceRootPath, !path.isEmpty else {
            return Self.noWorkspaceSidebarGroupKey
        }
        return path
    }

    static let noWorkspaceSidebarGroupKey = "_no_workspace_"
    /// Distinguishes a project group key from a filesystem path, so the two
    /// can never collide in the same namespace.
    static let projectSidebarGroupKeyPrefix = "project:"

    /// The project id encoded in a sidebar group key, if it is one.
    static func projectID(fromSidebarGroupKey key: String) -> UUID? {
        guard key.hasPrefix(projectSidebarGroupKeyPrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(projectSidebarGroupKeyPrefix.count)))
    }

    // Custom decoding so older session JSON without the newer fields
    // (didEditFiles, agentEditedPaths, interactionMode, approvalMode, currentPlan,
    // currentGoal) loads cleanly — every newer field uses
    // decodeIfPresent with a default.
    enum CodingKeys: String, CodingKey {
        case id, title, workspaceRootPath, workspaceLocation, sidebarWorkspaceRootPath, worktreeRecoveryInfo, projectID, presentationScope, dispatchParentProjectID, dispatchTaskID, localWorkspaceIdentity, modelID
        case providerEntryID, providerID, providerDisplayName, openAIResponsesContinuation, managedRouting
        case createdAt, updatedAt, messages, contextSummary, contextSummaryThroughMessageID
        case didEditFiles, agentEditedPaths, agentArtifactPaths, interactionMode, approvalMode, executionAgent, delegatedTaskRuns, activeExperts, currentPlan, currentGoal, goalPlanningState, goalRoadmap, goalTurnRecoveryCheckpoint, learningEvents, latestTurnRecall, documentAttachments, knowledgeFolders, documentTaskMode, redactSensitiveAttachmentContent, sidePanelState
        case pinnedAt, archivedAt, titleIsUserSet
        case originRoutineID, lastTurnFailure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.workspaceRootPath = try c.decodeIfPresent(String.self, forKey: .workspaceRootPath)
        self.workspaceLocation = try c.decodeIfPresent(WorkspaceLocation.self, forKey: .workspaceLocation)
            ?? self.workspaceRootPath.map { .local(path: $0) }
        self.sidebarWorkspaceRootPath = try c.decodeIfPresent(String.self, forKey: .sidebarWorkspaceRootPath)
        self.worktreeRecoveryInfo = try c.decodeIfPresent(AgentWorktreeRecoveryInfo.self, forKey: .worktreeRecoveryInfo)
        self.projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        self.dispatchParentProjectID = try c.decodeIfPresent(
            UUID.self,
            forKey: .dispatchParentProjectID
        )
        self.dispatchTaskID = try c.decodeIfPresent(UUID.self, forKey: .dispatchTaskID)
        self.localWorkspaceIdentity = try c.decodeIfPresent(LocalWorkspaceIdentity.self, forKey: .localWorkspaceIdentity)
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.providerEntryID = try c.decodeIfPresent(UUID.self, forKey: .providerEntryID)
        self.providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        self.providerDisplayName = try c.decodeIfPresent(String.self, forKey: .providerDisplayName)
        self.openAIResponsesContinuation = try c.decodeIfPresent(
            AgentOpenAIResponsesContinuationSnapshot.self,
            forKey: .openAIResponsesContinuation
        )
        self.managedRouting = try c.decodeIfPresent(AgentManagedRoutingState.self, forKey: .managedRouting)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([AgentMessage].self, forKey: .messages)
        self.contextSummary = try c.decodeIfPresent(String.self, forKey: .contextSummary)
        self.contextSummaryThroughMessageID = try c.decodeIfPresent(AgentMessage.ID.self, forKey: .contextSummaryThroughMessageID)
        self.didEditFiles = try c.decodeIfPresent(Bool.self, forKey: .didEditFiles) ?? false
        self.agentEditedPaths = try c.decodeIfPresent([String].self, forKey: .agentEditedPaths) ?? []
        self.agentArtifactPaths = try c.decodeIfPresent([String].self, forKey: .agentArtifactPaths) ?? []
        self.interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode) ?? .normal
        self.approvalMode = try c.decodeIfPresent(AgentApprovalMode.self, forKey: .approvalMode) ?? .smart
        self.executionAgent = try c.decodeIfPresent(AgentExecutionAgent.self, forKey: .executionAgent) ?? .willDeep
        self.delegatedTaskRuns = try c.decodeIfPresent(
            [AgentDelegatedTaskRun].self,
            forKey: .delegatedTaskRuns
        ) ?? []
        self.activeExperts = try c.decodeIfPresent(Set<AgentExpert>.self, forKey: .activeExperts) ?? []
        self.currentPlan = try c.decodeIfPresent(AgentPlan.self, forKey: .currentPlan)
        self.currentGoal = try c.decodeIfPresent(AgentGoal.self, forKey: .currentGoal)
        if !c.contains(.goalPlanningState) {
            self.goalPlanningState = nil
        } else if let decoded = try? c.decodeIfPresent(AgentGoalPlanningState.self, forKey: .goalPlanningState) {
            self.goalPlanningState = decoded
        } else {
            // A present-but-malformed ledger is observable and conservative:
            // preserve the session, but never silently erase the evidence that
            // recovery is required.
            self.goalPlanningState = AgentGoalPlanningState(
                goalFingerprint: self.currentGoal?.statement ?? "unreadable-goal-planning-state",
                phase: .blocked,
                members: [
                    .init(roleID: "requirements", displayName: "requirements", status: .interrupted),
                    .init(roleID: "architecture", displayName: "architecture", status: .interrupted),
                    .init(roleID: "testing", displayName: "testing", status: .interrupted),
                ],
                arbitration: .init(status: .interrupted, errorMessage: "malformed persisted planning state")
            )
        }
        self.goalRoadmap = try? c.decodeIfPresent(AgentGoalRoadmap.self, forKey: .goalRoadmap)
        self.goalTurnRecoveryCheckpoint = try c.decodeIfPresent(
            AgentGoalTurnRecoveryCheckpoint.self,
            forKey: .goalTurnRecoveryCheckpoint
        )
        self.learningEvents = try c.decodeIfPresent([AgentLearningEvent].self, forKey: .learningEvents) ?? []
        self.latestTurnRecall = try c.decodeIfPresent(AgentTurnRecallSnapshot.self, forKey: .latestTurnRecall)
        self.documentAttachments = try c.decodeIfPresent([AgentFileAttachment].self, forKey: .documentAttachments) ?? []
        self.knowledgeFolders = try c.decodeIfPresent([AgentKnowledgeFolder].self, forKey: .knowledgeFolders) ?? []
        self.documentTaskMode = try c.decodeIfPresent(AgentDocumentTaskMode.self, forKey: .documentTaskMode) ?? .automatic
        self.redactSensitiveAttachmentContent = try c.decodeIfPresent(Bool.self, forKey: .redactSensitiveAttachmentContent) ?? true
        self.sidePanelState = try c.decodeIfPresent(AgentSidePanelState.self, forKey: .sidePanelState) ?? .empty
        self.pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.titleIsUserSet = try c.decodeIfPresent(Bool.self, forKey: .titleIsUserSet) ?? false
        self.originRoutineID = try c.decodeIfPresent(UUID.self, forKey: .originRoutineID)
        // A malformed failure snapshot must never cost the user the whole
        // conversation: the transcript is the valuable part, this is only the
        // banner it should re-show.
        self.lastTurnFailure = try? c.decodeIfPresent(AgentTurnFailure.self, forKey: .lastTurnFailure)
        self.presentationScope = try c.decodeIfPresent(
            AgentSessionPresentationScope.self,
            forKey: .presentationScope
        ) ?? Self.inferredPresentationScope(
            interactionMode: interactionMode,
            currentGoal: currentGoal,
            containsRoundtableReport: messages.contains {
                $0.workflowReport?.roundtable != nil
            }
        )
    }

    static func inferredPresentationScope(
        interactionMode: AgentInteractionMode,
        currentGoal: AgentGoal?,
        containsRoundtableReport: Bool
    ) -> AgentSessionPresentationScope {
        if containsRoundtableReport {
            return .roundtable
        }
        if interactionMode == .goal || currentGoal != nil {
            return .dispatchBoard
        }
        return .workspace
    }
}

nonisolated extension AgentSession {
    /// Produces the persistence snapshot used by `AgentSessionStore`.
    /// This is also a migration path for legacy sessions that still carry
    /// extracted attachment text inline.
    func externalizingAttachmentContent() -> AgentSession {
        var copy = self
        copy.documentAttachments = documentAttachments.map {
            $0.externalizingAttachmentContent()
        }
        copy.knowledgeFolders = knowledgeFolders.map {
            $0.externalizingAttachmentContent()
        }
        return copy
    }
}
