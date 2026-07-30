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
    /// Dedicated workflow sessions are persisted like conversations, but are
    /// presented only by their owning surface.
    var presentationScope: AgentSessionPresentationScope
    /// Best-effort local folder identity for recovering from Finder moves
    /// or renames. Tools do not poll this on the happy path; it is consulted
    /// only after the recorded path appears to have failed.
    var localWorkspaceIdentity: LocalWorkspaceIdentity?
    /// Model id captured at the time the session was last sent (so changing
    /// the global model later doesn't silently switch what an old chat used).
    var modelID: String?
    /// Provider snapshot captured alongside `modelID` so usage analytics
    /// can group historical sessions by the actual configured provider.
    var providerID: String?
    var providerDisplayName: String?
    /// Per-session "省心托管" (some.im managed routing) state. Non-nil only
    /// when the user selected managed routing for this session; carries the
    /// only-goes-up capability floor. Orthogonal to `modelID` / override —
    /// managed sessions never write a resolved model into `modelID`, so the
    /// managed selection can never leak downstream as a real model name.
    var managedRouting: AgentManagedRoutingState?
    let createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]
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

    init(
        id: UUID = UUID(),
        title: String = AgentSessionStore.defaultTitle,
        workspaceRootPath: String? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        sidebarWorkspaceRootPath: String? = nil,
        presentationScope: AgentSessionPresentationScope = .workspace,
        localWorkspaceIdentity: LocalWorkspaceIdentity? = nil,
        modelID: String? = nil,
        providerID: String? = nil,
        providerDisplayName: String? = nil,
        managedRouting: AgentManagedRoutingState? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AgentMessage] = [],
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
        titleIsUserSet: Bool = false
    ) {
        self.id = id
        self.title = title
        self.workspaceRootPath = workspaceRootPath
        self.workspaceLocation = workspaceLocation ?? workspaceRootPath.map { .local(path: $0) }
        self.sidebarWorkspaceRootPath = sidebarWorkspaceRootPath
        self.presentationScope = presentationScope
        self.localWorkspaceIdentity = localWorkspaceIdentity
            ?? AgentWorkspaceAvailabilityResolver.captureIdentity(for: self.workspaceLocation?.localPath ?? workspaceRootPath)
        self.modelID = modelID
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.managedRouting = managedRouting
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
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
    }

    var isPinned: Bool { pinnedAt != nil }
    var isArchived: Bool { archivedAt != nil }
    var belongsInWorkspaceSidebar: Bool {
        presentationScope == .workspace
            && interactionMode != .goal
            && currentGoal == nil
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

    // Custom decoding so older session JSON without the newer fields
    // (didEditFiles, agentEditedPaths, interactionMode, approvalMode, currentPlan,
    // currentGoal) loads cleanly — every newer field uses
    // decodeIfPresent with a default.
    enum CodingKeys: String, CodingKey {
        case id, title, workspaceRootPath, workspaceLocation, sidebarWorkspaceRootPath, presentationScope, localWorkspaceIdentity, modelID
        case providerID, providerDisplayName, managedRouting
        case createdAt, updatedAt, messages, contextSummary, contextSummaryThroughMessageID
        case didEditFiles, agentEditedPaths, agentArtifactPaths, interactionMode, approvalMode, executionAgent, delegatedTaskRuns, activeExperts, currentPlan, currentGoal, goalPlanningState, goalTurnRecoveryCheckpoint, learningEvents, latestTurnRecall, documentAttachments, knowledgeFolders, documentTaskMode, redactSensitiveAttachmentContent, sidePanelState
        case pinnedAt, archivedAt, titleIsUserSet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.workspaceRootPath = try c.decodeIfPresent(String.self, forKey: .workspaceRootPath)
        self.workspaceLocation = try c.decodeIfPresent(WorkspaceLocation.self, forKey: .workspaceLocation)
            ?? self.workspaceRootPath.map { .local(path: $0) }
        self.sidebarWorkspaceRootPath = try c.decodeIfPresent(String.self, forKey: .sidebarWorkspaceRootPath)
        self.localWorkspaceIdentity = try c.decodeIfPresent(LocalWorkspaceIdentity.self, forKey: .localWorkspaceIdentity)
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        self.providerDisplayName = try c.decodeIfPresent(String.self, forKey: .providerDisplayName)
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

// MARK: - some.im managed routing ("省心托管")

/// Capability floor for a some.im managed-routing session. The floor only
/// ever rises within a session ("只升不降"): once a turn proves it needs
/// `.high` / `.premium`, later turns cannot be dropped back to a weaker tier
/// by the lightweight judge. The user can still explicitly choose Flash / Pro /
/// Premium, switch model, or start a new session. See
/// SOME_IM_MANAGED_ROUTING_DESIGN.md.
nonisolated enum AgentManagedCapabilityTier: String, Codable, Equatable, Comparable {
    case low
    case high
    case premium

    var rank: Int {
        switch self {
        case .low: return 0
        case .high: return 1
        case .premium: return 2
        }
    }

    static func < (lhs: AgentManagedCapabilityTier, rhs: AgentManagedCapabilityTier) -> Bool {
        lhs.rank < rhs.rank
    }

    var next: AgentManagedCapabilityTier? {
        switch self {
        case .low: return .high
        case .high: return .premium
        case .premium: return nil
        }
    }
}

/// Persisted per-session state for some.im managed routing. Stored on
/// `AgentSession` (additively decoded — absent on legacy sessions → nil,
/// i.e. "not a managed session").
nonisolated struct AgentManagedRoutingState: Codable, Equatable {
    /// Lowest capability tier this session may use until the user chooses a
    /// different managed tier, switches model, or starts a new session.
    var minimumTier: AgentManagedCapabilityTier
    /// Last main-call model the router resolved to. Diagnostic only.
    var lastSelectedModel: String?
    var lastEscalatedAt: Date?
    var lastEscalationReason: String?

    init(
        minimumTier: AgentManagedCapabilityTier = .low,
        lastSelectedModel: String? = nil,
        lastEscalatedAt: Date? = nil,
        lastEscalationReason: String? = nil
    ) {
        self.minimumTier = minimumTier
        self.lastSelectedModel = lastSelectedModel
        self.lastEscalatedAt = lastEscalatedAt
        self.lastEscalationReason = lastEscalationReason
    }
}

/// Task domain the routing judge classifies a turn into.
nonisolated enum SomeIMManagedDomain: String, Codable, Equatable {
    case coding
    case general
}

nonisolated enum AgentManagedRouteFamily: Equatable {
    case general
    case coding
    case unknown
}

/// Per-assistant-message record of how managed routing resolved this turn.
/// Additive observability metadata (footer chip / usage stats) — persisted
/// with the session, absent (nil) on non-managed turns. `SomeIMManagedComplexity`
/// lives in SomeIMManagedRouting.swift (same module).
nonisolated struct AgentManagedRouteDecision: Codable, Equatable {
    var selectedModel: String
    var tier: AgentManagedCapabilityTier
    var domain: SomeIMManagedDomain
    var complexity: SomeIMManagedComplexity
    /// The router fell back to the local heuristic (judge unavailable / unparsable).
    var didFallback: Bool
    /// An output-quality failure escalated this turn one tier up.
    var didEscalate: Bool
    var failureType: String?

    init(
        selectedModel: String,
        tier: AgentManagedCapabilityTier,
        domain: SomeIMManagedDomain,
        complexity: SomeIMManagedComplexity,
        didFallback: Bool,
        didEscalate: Bool = false,
        failureType: String? = nil
    ) {
        self.selectedModel = selectedModel
        self.tier = tier
        self.domain = domain
        self.complexity = complexity
        self.didFallback = didFallback
        self.didEscalate = didEscalate
        self.failureType = failureType
    }

    /// Short tier label for a footer chip (proper-noun tier names, like the pill).
    var tierLabel: String {
        switch tier {
        case .low: return "Low"
        case .high: return "High"
        case .premium: return "Premium"
        }
    }

    /// Tier plus an escalation (↑) or fallback (~) marker, e.g. "High↑".
    var tierMarkers: String {
        var text = tierLabel
        if didEscalate {
            text += "↑"
        } else if didFallback {
            text += "~"
        }
        return text
    }

    /// Footer family reflects the routing judge's task-domain verdict. Coding
    /// Plan only changes the model family for coding tasks; general tasks stay
    /// on the `someim-auto-*` family.
    var footerFamily: AgentManagedRouteFamily {
        switch domain {
        case .general:
            return .general
        case .coding:
            return .coding
        }
    }

    /// User-facing capability name derived from the actual virtual model.
    /// The coding families call the same three effective levels low/high/
    /// premium, while the footer presents them consistently as flash/pro/
    /// premium alongside the auto family.
    var footerLevelLabel: String {
        let model = selectedModel.lowercased()
        if model.hasSuffix("-premium") { return "premium" }
        if model.hasSuffix("-pro") || model.hasSuffix("-high") { return "pro" }
        if model.hasSuffix("-flash") || model.hasSuffix("-low") { return "flash" }
        switch tier {
        case .low: return "flash"
        case .high: return "pro"
        case .premium: return "premium"
        }
    }

    var footerLevelMarkers: String {
        var text = footerLevelLabel
        if didEscalate {
            text += "↑"
        } else if didFallback {
            text += "~"
        }
        return text
    }

    /// Full footer text derived from the judge domain and actual model level, e.g.
    /// `托管-通用-flash` or `托管-编程-pro↑`.
    var footerChipText: String {
        switch footerFamily {
        case .general:
            return L10n.AgentManagedRouting.generalFooter(footerLevelMarkers)
        case .coding:
            return L10n.AgentManagedRouting.codingFooter(footerLevelMarkers)
        case .unknown:
            return "\(L10n.AgentManagedRouting.footerPrefix) \(tierMarkers)"
        }
    }
}

/// some.im managed-routing model catalogue: the fixed set of main-call model
/// names a judge decision may resolve to, plus the (domain, tier) → model
/// mapping and its inverse. These are virtual model names on the some.im
/// relay, not raw upstream models. See SOME_IM_MANAGED_ROUTING_DESIGN.md
/// ("模型与命名").
nonisolated enum SomeIMManagedModel {
    static let codingPlanLow = "someim-coding-plan-low"
    static let codingPlanHigh = "someim-coding-plan-high"
    static let codingPlanPremium = "someim-coding-plan-premium"
    static let codeLow = "someim-code-low"
    static let codeHigh = "someim-code-high"
    static let codePremium = "someim-code-premium"
    static let autoFlash = "someim-auto-flash"
    static let autoPro = "someim-auto-pro"
    static let autoPremium = "someim-auto-premium"

    /// The lightweight router / output-quality judge model. Backed by a
    /// non-thinking official DeepSeek behind a clean (no-persona) virtual
    /// chain. Never selectable as a turn's main model — hence excluded from
    /// `allowlist`.
    static let judge = "someim-judge"

    /// Every main-call model a judge decision is allowed to resolve to. A
    /// `target_model` outside this set is rejected and the local
    /// (domain, tier) mapping is used instead.
    static let allowlist: Set<String> = [
        codingPlanLow, codingPlanHigh, codingPlanPremium,
        codeLow, codeHigh, codePremium,
        autoFlash, autoPro, autoPremium
    ]

    /// Resolve the actual main-call model from a task domain and the
    /// effective capability tier (already merged with the session floor).
    static func resolve(
        domain: SomeIMManagedDomain,
        tier: AgentManagedCapabilityTier,
        hasCodingPlan: Bool
    ) -> String {
        if hasCodingPlan, domain == .coding {
            switch tier {
            case .low: return codingPlanLow
            case .high: return codingPlanHigh
            case .premium: return codingPlanPremium
            }
        }
        switch (domain, tier) {
        case (.coding, .low): return codeLow
        case (.coding, .high): return codeHigh
        case (.coding, .premium): return codePremium
        case (.general, .low): return autoFlash
        case (.general, .high): return autoPro
        case (.general, .premium): return autoPremium
        }
    }

    /// Inverse of `resolve` for the only-goes-up floor bookkeeping: which
    /// tier does a resolved model correspond to. Unknown → nil.
    static func tier(of model: String) -> AgentManagedCapabilityTier? {
        switch model {
        case codingPlanLow, codeLow, autoFlash: return .low
        case codingPlanHigh, codeHigh, autoPro: return .high
        case codingPlanPremium, codePremium, autoPremium: return .premium
        default: return nil
        }
    }

    /// Next model up its own ladder for a single output-quality escalation
    /// retry. Returns nil at the top of a ladder so the retry never loops.
    /// See design doc "升档模型".
    static func escalated(from model: String) -> String? {
        switch model {
        case codingPlanLow: return codingPlanHigh
        case codingPlanHigh: return codingPlanPremium
        case codeLow: return codeHigh
        case codeHigh: return codePremium
        case autoFlash: return autoPro
        case autoPro: return autoPremium
        // premium models: top of ladder → no auto-escalation.
        default: return nil
        }
    }
}

nonisolated struct AgentSidePanelState: Codable, Equatable {
    var kind: AgentSidePanelKind?
    var selectedFilePath: String?
    var mediaTaskScope: AgentMediaTaskScope?
    var imageEditorImagePath: String?
    var imageEditorMaskPath: String?
    var imageEditorPreferredOperation: AgentImageEditorOperationPreference?
    var imageEditorContext: AgentImageEditorContext?
    var lastViewedAt: Date?

    static let empty = AgentSidePanelState()

    init(
        kind: AgentSidePanelKind? = nil,
        selectedFilePath: String? = nil,
        mediaTaskScope: AgentMediaTaskScope? = nil,
        imageEditorImagePath: String? = nil,
        imageEditorMaskPath: String? = nil,
        imageEditorPreferredOperation: AgentImageEditorOperationPreference? = nil,
        imageEditorContext: AgentImageEditorContext? = nil,
        lastViewedAt: Date? = nil
    ) {
        self.kind = kind
        self.selectedFilePath = selectedFilePath
        self.mediaTaskScope = mediaTaskScope
        self.imageEditorImagePath = imageEditorImagePath
        self.imageEditorMaskPath = imageEditorMaskPath
        self.imageEditorPreferredOperation = imageEditorPreferredOperation
        self.imageEditorContext = imageEditorContext
        self.lastViewedAt = lastViewedAt
    }
}

// MARK: - Plan & Goal modes

/// Top-level interaction mode for an Agent session. Ordinary conversations
/// may plan and execute in one flow; Goal additionally pins a long-term
/// objective and acceptance checklist to every turn.
nonisolated enum AgentInteractionMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case goal

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.normal.rawValue:
            self = .normal
        case "plan":
            // Sessions written before 1.211.0-rc6 used Plan as a top-level
            // mode. Planning now lives inside ordinary mode, so migrate them
            // without losing the visible plan or transcript.
            self = .normal
        case Self.goal.rawValue:
            self = .goal
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AgentInteractionMode: \(rawValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .normal: return L10n.InteractionMode.normal
        case .goal: return L10n.InteractionMode.goal
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "bubble.left.and.bubble.right"
        case .goal: return "target"
        }
    }
}

/// Per-session approval posture exposed from the Agent composer. It
/// influences only write-tier auto-approval; read tools still run
/// automatically, and danger-tier tools still require typed confirmation.
/// Goal's host-owned evidence phase remains read-only until validation.
nonisolated enum AgentApprovalMode: String, Codable, CaseIterable, Identifiable {
    case smart
    case workspaceAccess
    case requestEveryTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .requestEveryTime: return L10n.ApprovalMode.requestEveryTime
        case .smart: return L10n.ApprovalMode.smart
        case .workspaceAccess: return L10n.ApprovalMode.workspaceAccess
        }
    }

    var summary: String {
        switch self {
        case .requestEveryTime: return L10n.ApprovalMode.requestEveryTimeSummary
        case .smart: return L10n.ApprovalMode.smartSummary
        case .workspaceAccess: return L10n.ApprovalMode.workspaceAccessSummary
        }
    }

    var systemPromptDescription: String {
        switch self {
        case .requestEveryTime:
            return "Strict mode: ask before every write or external action. Read-only tools may run automatically. Danger-tier tools still require typed confirmation."
        case .smart:
            return "Use WillDeep's smart review policy: read-only tools and workspace-scoped writes run automatically; safe external actions may be AI-approved; uncertain or risky external actions ask the user."
        case .workspaceAccess:
            return "Allow write-tier actions and delegated agent work inside the current workspace to auto-run. External/network actions, danger-tier tools, the Plan gate, and untrusted MCP calls still require user approval."
        }
    }

    var conciseSystemPromptDescription: String {
        switch self {
        case .requestEveryTime:
            return "Strict: reads auto-run; every write or external action asks; danger-tier commands require typed confirmation."
        case .smart:
            return "Reads and workspace-scoped writes auto-run; safe external actions may pass intelligent review; uncertain external actions ask; danger-tier commands require typed confirmation."
        case .workspaceAccess:
            return "Reads and workspace-scoped writes auto-run; untrusted external actions ask; danger-tier commands require typed confirmation."
        }
    }

    var symbol: String {
        switch self {
        case .requestEveryTime: return "hand.raised"
        case .smart: return "checkmark.shield"
        case .workspaceAccess: return "shield.lefthalf.filled"
        }
    }
}

/// Optional specialist packs that expand the model-facing tool surface and
/// domain prompt only when the user explicitly enables them for a session.
nonisolated enum AgentExpert: String, Codable, CaseIterable, Identifiable, Hashable {
    case shortDrama
    case browserOps
    case webCoding

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shortDrama: return L10n.Expert.shortDrama
        case .browserOps: return L10n.Expert.browserOps
        case .webCoding: return L10n.Expert.webCoding
        }
    }

    var summary: String {
        switch self {
        case .shortDrama: return L10n.Expert.shortDramaSummary
        case .browserOps: return L10n.Expert.browserOpsSummary
        case .webCoding: return L10n.Expert.webCodingSummary
        }
    }

    var symbol: String {
        switch self {
        case .shortDrama: return "film.stack"
        case .browserOps: return "globe.badge.chevron.backward"
        case .webCoding: return "curlybraces.square"
        }
    }

    var systemPromptBlock: String {
        switch self {
        case .shortDrama:
            return """
            === SHORT DRAMA EXPERT — ACTIVE ===
            The user enabled the short-drama production expert for this session. You may use the `short_drama_*` tools to plan projects, maintain episode/shot/asset structure, generate or refresh media tasks, review storyboards, and export production packages.
            Keep short-drama actions anchored by project/episode/shot/asset IDs. Prefer dry-run options for broad structure changes or batch generation before spending provider calls or mutating many records.
            """
        case .browserOps:
            return """
            === BROWSER OPERATIONS EXPERT — ACTIVE ===
            The user enabled the browser operations expert for this session. You may use `embedded_browser_*` tools for the visible in-app side-panel browser, including navigation, page reading, DOM snapshots, wait conditions, console logs, AJAX/API request inspection, redacted request/response headers, HAR export, storage/cookie inspection, page performance diagnostics, failed-resource aggregation, network resource timing, screenshot capture, CSS-selector clicks, JavaScript evaluation, and form filling.
            Use `chrome_*` tools only when the user needs their existing Chrome tabs, cookies, or login session. Start with chrome_list_tabs/chrome_activate_tab when the target tab is ambiguous, then take a fresh chrome_snapshot and prefer its ref over a hand-written selector. After navigation or mutation, use chrome_wait_for and take another snapshot before the next action. Screenshots and page mutations may expose or change private web apps, so keep actions scoped and prefer read/status calls before clicking or typing.
            """
        case .webCoding:
            return """
            === WEB PROGRAMMING EXPERT — ACTIVE ===
            The user enabled the web programming expert for this session. Treat UI generation, HTML/CSS/JS, React/Vue/Next/Vite, frontend screenshots, local assets, preview, screenshot QA, and dev-server orchestration as first-class work.
            When the user provides screenshots or local image assets, use them as visual requirements. Build a faithful, responsive UI from the supplied pixels, then preview and visually verify when practical.
            For React work, keep all user-visible JSX/TSX text in i18n resources. Prefer yarn for install/build/dev commands unless the project proves another package manager is required.
            For static HTML artifacts, prefer local files plus show_widget/html preview. When using `show_widget` with `html_path`, local relative CSS, JS, and image references may be loaded from the HTML file's directory; keep those references workspace-local or explicitly user-provided.
            For Vite/Next/React/Vue apps, start dev servers with `run_command` and `run_in_background: true`, inspect output with `get_job_output`, stop with `kill_job`, and use the Dev Server side panel to track running frontend/backend jobs and tail logs. If the project has both frontend and backend, manage them as separate background jobs and label which command belongs to which server.
            For live preview/screenshot QA, use the Preview/Widget side panel for static artifacts and `embedded_browser_*` or `chrome_*` screenshot/read tools for running web apps when available.
            """
        }
    }
}

/// Composer-level execution backend for a user turn.
///
/// This is deliberately separate from the model/provider picker: providers
/// choose the LLM API used by WillDeep itself, while this chooses whether
/// the submitted task is handled by WillDeep or delegated to an external
/// coding agent CLI through the existing tool/approval boundary.
nonisolated enum AgentExecutionAgent: String, Codable, CaseIterable, Identifiable, Hashable {
    case willDeep
    case claudeCode
    case codexCLI
    case cursorAgent
    case clineCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .willDeep: return L10n.ExecutionAgent.willDeepName
        case .claudeCode: return L10n.ExecutionAgent.claudeCodeName
        case .codexCLI: return L10n.ExecutionAgent.codexName
        case .cursorAgent: return L10n.ExecutionAgent.cursorName
        case .clineCLI: return L10n.ExecutionAgent.clineName
        }
    }

    var summary: String {
        switch self {
        case .willDeep: return L10n.ExecutionAgent.willDeepSummary
        case .claudeCode: return L10n.ExecutionAgent.claudeCodeSummary
        case .codexCLI: return L10n.ExecutionAgent.codexSummary
        case .cursorAgent: return L10n.ExecutionAgent.cursorSummary
        case .clineCLI: return L10n.ExecutionAgent.clineSummary
        }
    }

    var symbol: String {
        switch self {
        case .willDeep: return "hammer.fill"
        case .claudeCode: return "sparkles.rectangle.stack"
        case .codexCLI: return "terminal"
        case .cursorAgent: return "cursorarrow.click"
        case .clineCLI: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var toolName: String? {
        switch self {
        case .willDeep: return nil
        case .claudeCode: return "claude_code"
        case .codexCLI: return "codex_cli"
        case .cursorAgent: return "cursor_agent"
        case .clineCLI: return "cline_cli"
        }
    }

    var defaultPermissionMode: String? {
        switch self {
        case .willDeep: return nil
        case .claudeCode: return "acceptEdits"
        case .codexCLI: return "workspaceWrite"
        case .cursorAgent: return "default"
        case .clineCLI: return "act"
        }
    }

    init?(delegatedToolName: String) {
        switch delegatedToolName {
        case "claude_code":
            self = .claudeCode
        case "codex_cli":
            self = .codexCLI
        case "cursor_agent":
            self = .cursorAgent
        case "cline_cli":
            self = .clineCLI
        default:
            return nil
        }
    }
}

/// Persisted, host-owned ledger for Goal Teams planning. The raw-value enums
/// intentionally use tolerant decoding: future/unknown values narrow the
/// session to a blocked/interrupted state instead of failing the whole chat.
nonisolated struct AgentGoalPlanningState: Codable, Equatable {
    static let currentSchemaVersion = 1

    enum Phase: String, Codable, Equatable {
        case collecting
        case arbitrating
        case readyForProposal = "ready_for_proposal"
        case awaitingApproval = "awaiting_approval"
        case executing
        case blocked
        case completed

        init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Phase(rawValue: raw) ?? .blocked
        }
    }

    struct Member: Codable, Equatable, Identifiable {
        enum Status: String, Codable, Equatable {
            case pending
            case running
            case completed
            case failed
            case interrupted

            init(from decoder: Decoder) throws {
                let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
                self = Status(rawValue: raw) ?? .interrupted
            }
        }

        var id: String { roleID }
        var roleID: String
        var displayName: String
        var runID: UUID?
        var status: Status
        var report: String?
        var errorMessage: String?

        init(
            roleID: String,
            displayName: String,
            runID: UUID? = nil,
            status: Status = .pending,
            report: String? = nil,
            errorMessage: String? = nil
        ) {
            self.roleID = roleID
            self.displayName = displayName
            self.runID = runID
            self.status = status
            self.report = report
            self.errorMessage = errorMessage
        }
    }

    struct Arbitration: Codable, Equatable {
        enum Status: String, Codable, Equatable {
            case pending
            case running
            case completed
            case failed
            case interrupted

            init(from decoder: Decoder) throws {
                let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
                self = Status(rawValue: raw) ?? .interrupted
            }
        }

        var status: Status
        var report: String?
        var errorMessage: String?

        init(status: Status = .pending, report: String? = nil, errorMessage: String? = nil) {
            self.status = status
            self.report = report
            self.errorMessage = errorMessage
        }
    }

    var schemaVersion: Int
    var generationID: UUID
    var goalFingerprint: String
    var revisionNote: String?
    var phase: Phase
    var members: [Member]
    var arbitration: Arbitration

    init(
        schemaVersion: Int = currentSchemaVersion,
        generationID: UUID = UUID(),
        goalFingerprint: String,
        revisionNote: String? = nil,
        phase: Phase = .collecting,
        members: [Member],
        arbitration: Arbitration = Arbitration()
    ) {
        self.schemaVersion = schemaVersion
        self.generationID = generationID
        self.goalFingerprint = goalFingerprint
        self.revisionNote = revisionNote
        self.phase = phase
        self.members = members
        self.arbitration = arbitration
    }

    static func fingerprint(for goal: AgentGoal) -> String {
        ([goal.statement] + goal.checklist.map(\.text)).joined(separator: "\u{1F}")
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generationID, goalFingerprint, revisionNote, phase, members, arbitration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        generationID = (try? container.decodeIfPresent(UUID.self, forKey: .generationID)) ?? UUID()
        goalFingerprint = (try? container.decodeIfPresent(String.self, forKey: .goalFingerprint)) ?? ""
        revisionNote = (try? container.decodeIfPresent(String.self, forKey: .revisionNote)) ?? nil
        phase = (try? container.decodeIfPresent(Phase.self, forKey: .phase)) ?? .blocked
        members = (try? container.decodeIfPresent([Member].self, forKey: .members)) ?? []
        arbitration = (try? container.decodeIfPresent(Arbitration.self, forKey: .arbitration)) ?? Arbitration(status: .interrupted)

        if schemaVersion > Self.currentSchemaVersion || goalFingerprint.isEmpty || members.count != 3 {
            phase = .blocked
        }
    }

    /// Runtime restoration never resumes an in-flight network operation.
    /// Completed evidence is retained, while ambiguous work is interrupted.
    var normalizedForRestore: AgentGoalPlanningState {
        normalizedForRestore(currentPlan: nil)
    }

    func normalizedForRestore(
        currentPlan: AgentPlan?,
        currentGoal: AgentGoal? = nil
    ) -> AgentGoalPlanningState {
        var copy = self
        var interrupted = false
        for index in copy.members.indices
        where copy.members[index].status == .running || copy.members[index].status == .pending {
            copy.members[index].status = .interrupted
            interrupted = true
        }
        if copy.arbitration.status == .running {
            copy.arbitration.status = .interrupted
            interrupted = true
        }
        if interrupted || copy.phase == .collecting || copy.phase == .arbitrating
            || copy.schemaVersion > Self.currentSchemaVersion {
            copy.phase = .blocked
        }
        if let currentGoal, copy.goalFingerprint != Self.fingerprint(for: currentGoal) {
            copy.phase = .blocked
        }
        let hasIncompleteGoalChecklist = currentGoal.map {
            !$0.checklist.isEmpty && $0.checklist.contains(where: { !$0.done })
        } ?? false
        let hasCompletedGoalChecklist = currentGoal.map {
            !$0.checklist.isEmpty && $0.checklist.allSatisfy(\.done)
        } ?? false
        if copy.phase == .executing,
           currentPlan?.status == .done,
           hasCompletedGoalChecklist {
            copy.phase = .completed
        }
        switch copy.phase {
        case .readyForProposal:
            // The synthesis wake is runtime-only and cannot be reconstructed
            // safely after launch. Require an explicit retry instead of
            // leaving a permanently ready-but-silent session.
            copy.phase = .blocked
        case .awaitingApproval:
            // Legacy sessions may still carry the removed approval phase.
            // A valid plan now proceeds automatically.
            if currentPlan?.status == .proposed
                || currentPlan?.status == .approved
                || currentPlan?.status == .executing {
                copy.phase = .executing
            } else {
                copy.phase = .blocked
            }
        case .executing:
            // `.done + .executing` is a valid narrow recovery state: every
            // Plan step reached a terminal status, but the provider stopped
            // before the same Goal round completed its checklist. Keep the
            // ledger only while a real acceptance item remains unfinished,
            // so a completed or empty Goal cannot retain write permission.
            let canResumeInterruptedFinalization = currentPlan?.status == .done
                && hasIncompleteGoalChecklist
            if currentPlan?.status != .approved
                && currentPlan?.status != .executing
                && !canResumeInterruptedFinalization {
                copy.phase = .blocked
            }
        case .completed:
            if currentPlan?.status != .done { copy.phase = .blocked }
        case .collecting, .arbitrating, .blocked:
            break
        }
        return copy
    }
}

/// A visible execution plan parsed from the agent's reply.
/// Lifecycle:
///   proposed/rejected are retained for persisted-session compatibility.
///   New plans become approved (ready) immediately, then executing/done as
///   progress arrives. Tool safety is governed by AgentApprovalMode.
nonisolated struct AgentPlan: Codable, Equatable {
    enum Status: String, Codable { case proposed, approved, rejected, executing, done }

    /// Per-step lifecycle. Agent self-reports via a ```progress fenced
    /// block; the user can also click checkboxes to override.
    enum StepStatus: String, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done
        case skipped
        case failed
    }

    struct Step: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var status: StepStatus

        init(id: UUID = UUID(), text: String, status: StepStatus = .pending) {
            self.id = id
            self.text = text
            self.status = status
        }
    }

    var status: Status
    var steps: [Step]
    /// Free-form preamble the agent put before the numbered list. Shown
    /// muted at the top of the plan card.
    var summary: String

    init(status: Status = .proposed, steps: [Step] = [], summary: String = "") {
        self.status = status
        self.steps = steps
        self.summary = summary
    }

    /// Convenience for older call sites that built plans from raw strings.
    init(status: Status, summary: String, stepTexts: [String]) {
        self.status = status
        self.steps = stepTexts.map { Step(text: $0) }
        self.summary = summary
    }
}

/// A long-term goal pinned to a session. Sticks to every system prompt so
/// the agent stays aligned, and renders as a banner at the top of the
/// transcript. `checklist` entries can be ticked off independently.
nonisolated struct AgentGoal: Codable, Equatable {
    var statement: String
    var checklist: [Item]

    struct Item: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var done: Bool

        init(id: UUID = UUID(), text: String, done: Bool = false) {
            self.id = id
            self.text = text
            self.done = done
        }
    }

    init(statement: String = "", checklist: [Item] = []) {
        self.statement = statement
        self.checklist = checklist
    }

    var isEmpty: Bool { statement.isEmpty && checklist.isEmpty }
}

enum AgentModelRoutingMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case flash
    case pro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .flash: return "Flash"
        case .pro: return "Pro"
        }
    }

    var description: String {
        switch self {
        case .auto:
            return "Cost-first routing. Agent turns and compression use Flash unless a session override is selected."
        case .flash:
            return "Always use the lower-cost model slot."
        case .pro:
            return "Always use the stronger model slot."
        }
    }
}

enum AgentModelPurpose {
    case interactive
    case compression
}

struct AgentImageDescriptionConfiguration: Codable, Equatable {
    var providerID: String
    var baseURL: String
    var model: String
    var apiKey: String

    static let `default` = AgentImageDescriptionConfiguration(
        providerID: "dashscope",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        model: "qwen3-vl-plus",
        apiKey: ""
    )

    init(providerID: String, baseURL: String, model: String, apiKey: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? Self.default.providerID
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.default.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    var normalized: AgentImageDescriptionConfiguration {
        var result = self
        result.providerID = result.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = result.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let preset = AgentProviderPreset.preset(id: result.providerID)
        if preset == nil {
            result.providerID = AgentProviderPreset.customID
        }
        if result.baseURL.isEmpty {
            result.baseURL = Self.default.baseURL
        }
        if result.model.isEmpty {
            result.model = Self.default.model
        }
        return result
    }

    var agentConfiguration: AgentConfiguration {
        AgentConfiguration(
            providerID: providerID,
            baseURL: baseURL,
            model: model,
            flashModel: model,
            proModel: model,
            routingMode: .flash,
            imageDescription: self,
            apiKey: apiKey
        ).normalized
    }
}

struct AgentConfiguration: Codable, Equatable {
    var providerID: String
    var baseURL: String
    /// Legacy/current resolved model field. Older settings only stored this.
    var model: String
    var flashModel: String
    var proModel: String
    var routingMode: AgentModelRoutingMode
    var imageDescription: AgentImageDescriptionConfiguration
    var apiKey: String
    /// Optional dedicated model for one-shot conversation-title
    /// summarization. Empty → fall back to `flashModel`. We keep this
    /// separate so users can wire a cheap/fast model (haiku, 4o-mini,
    /// deepseek-chat, qwen-turbo …) for the "give this chat a 12-char
    /// title" task without dragging that model into the main loop.
    var titleModel: String
    /// When `providerID == custom`, this lets the user pin which
    /// transport-protocol family the adapter facade dispatches into.
    /// `nil` (every other preset / older config) falls back to the
    /// preset's `kind` via `providerKind` below. See
    /// `AgentProviderEntry.customKindOverride` for the persisted-side
    /// source of truth.
    var customKindOverride: AgentProviderKind?

    static let `default` = AgentConfiguration(
        providerID: AgentProviderPreset.deepSeekID,
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-flash",
        flashModel: "deepseek-v4-flash",
        proModel: "deepseek-v4-pro",
        routingMode: .auto,
        imageDescription: .default,
        apiKey: "",
        titleModel: ""
    )

    init(
        providerID: String,
        baseURL: String,
        model: String,
        flashModel: String? = nil,
        proModel: String? = nil,
        routingMode: AgentModelRoutingMode = .auto,
        imageDescription: AgentImageDescriptionConfiguration = .default,
        apiKey: String,
        titleModel: String = "",
        customKindOverride: AgentProviderKind? = nil
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.flashModel = flashModel ?? model
        self.proModel = proModel ?? model
        self.routingMode = routingMode
        self.imageDescription = imageDescription
        self.apiKey = apiKey
        self.titleModel = titleModel
        // Override only applies to Custom — guard here too so callers
        // that forget to filter don't accidentally override a named
        // preset's kind. Matches the same defensive check in
        // `AgentProviderEntry.init`.
        self.customKindOverride = (providerID == AgentProviderPreset.customID) ? customKindOverride : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? AgentConfiguration.default.providerID
        baseURL = try container.decode(String.self, forKey: .baseURL)
        let legacyModel = try container.decodeIfPresent(String.self, forKey: .model) ?? AgentConfiguration.default.model
        model = legacyModel
        flashModel = try container.decodeIfPresent(String.self, forKey: .flashModel) ?? legacyModel
        proModel = try container.decodeIfPresent(String.self, forKey: .proModel) ?? legacyModel
        routingMode = try container.decodeIfPresent(AgentModelRoutingMode.self, forKey: .routingMode) ?? .auto
        imageDescription = try container.decodeIfPresent(AgentImageDescriptionConfiguration.self, forKey: .imageDescription) ?? .default
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        titleModel = try container.decodeIfPresent(String.self, forKey: .titleModel) ?? ""
        // New field — 1.56.1. Older configs have no key → nil → uses preset kind.
        let override = try container.decodeIfPresent(AgentProviderKind.self, forKey: .customKindOverride)
        customKindOverride = (providerID == AgentProviderPreset.customID) ? override : nil
    }

    var normalized: AgentConfiguration {
        var result = self
        result.providerID = result.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.flashModel = result.flashModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.proModel = result.proModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.imageDescription = result.imageDescription.normalized
        result.apiKey = result.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result.titleModel = result.titleModel.trimmingCharacters(in: .whitespacesAndNewlines)

        let preset = AgentProviderPreset.preset(id: result.providerID)
        if preset == nil {
            result.providerID = AgentProviderPreset.customID
        }
        if result.baseURL.isEmpty {
            result.baseURL = AgentConfiguration.default.baseURL
        }
        if result.flashModel.isEmpty {
            result.flashModel = preset?.defaultFlashModel ?? result.model
        }
        if result.proModel.isEmpty {
            result.proModel = preset?.defaultProModel ?? result.model
        }
        // Detect a stale model carried over from a previous provider —
        // e.g. user had OpenAI's `gpt-3.5-16k` as flashModel, then
        // switched provider to DeepSeek in Settings. Without this check
        // the chat-mode model picker keeps offering `gpt-3.5-16k` as
        // the "route default", which is just confusing. If the model
        // string contains no hint that matches the current preset,
        // reset to that preset's documented default.
        if let preset, preset.id != AgentProviderPreset.customID {
            if !preset.recognizesModelID(result.flashModel) {
                result.flashModel = preset.defaultFlashModel
            }
            if !preset.recognizesModelID(result.proModel) {
                result.proModel = preset.defaultProModel
            }
            if !preset.recognizesModelID(result.model) {
                result.model = preset.defaultModel
            }
        }
        if result.flashModel.isEmpty {
            result.flashModel = AgentConfiguration.default.flashModel
        }
        if result.proModel.isEmpty {
            result.proModel = AgentConfiguration.default.proModel
        }
        if result.model.isEmpty {
            result.model = result.model(for: .interactive)
        }
        return result
    }

    func model(for purpose: AgentModelPurpose) -> String {
        switch purpose {
        case .compression:
            return flashModel
        case .interactive:
            switch routingMode {
            case .auto, .flash:
                return flashModel
            case .pro:
                return proModel
            }
        }
    }

    /// Model to use for the one-shot "summarize this chat into a 12-char
    /// title" call. Returns `titleModel` if explicitly set, otherwise
    /// falls back to `flashModel` (we never run titling on `proModel` —
    /// the task is trivial and the price gap is real).
    func titleSummaryModel() -> String {
        let trimmed = titleModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? flashModel : trimmed
    }

    func resolved(for purpose: AgentModelPurpose) -> AgentConfiguration {
        var result = normalized
        result.model = result.model(for: purpose)
        return result
    }

    var routingLabel: String {
        "\(routingMode.displayName) · \(model(for: .interactive))"
    }

    var supportsImageInput: Bool {
        guard AgentProviderPreset.preset(id: providerID)?.supportsImageInput ?? true else {
            return false
        }
        return Self.modelAcceptsImageInput(model)
    }

    var requiresAPIKey: Bool {
        AgentProviderPreset.preset(id: providerID)?.requiresAPIKey ?? true
    }

    /// Model-level vision gate, layered on top of the provider preset flag.
    ///
    /// A relay provider (e.g. some.im) can host both vision and text-only
    /// models, so the provider-level `supportsImageInput` alone is not
    /// enough: sending an OpenAI `image_url` content part to a text-only
    /// model like `deepseek-v4-flash` fails the whole request with
    /// HTTP 400 "unknown variant `image_url`, expected `text`" — even when
    /// the image sits hundreds of messages back in the history.
    ///
    /// Conservative denylist: only families known to reject image parts
    /// return false; unknown models keep image support so genuinely
    /// multimodal custom models aren't degraded.
    nonisolated static func modelAcceptsImageInput(_ model: String) -> Bool {
        let lower = model.lowercased()
        // DeepSeek chat/coder models are text-only (deepseek-vl is the
        // vision family and keeps image support).
        if lower.contains("deepseek"), !lower.contains("vl") { return false }
        // some.im auto-routing text tier maps to text-only backends.
        if lower.hasPrefix("someim-auto") { return false }
        // some.im coding-plan tiers currently map to text-only backends
        // (deepseek / glm chat models). Managed routing never targets a
        // vision model, so keep the whole family text-only.
        if lower.hasPrefix("someim-coding") { return false }
        return true
    }

    /// Transport-protocol family this configuration speaks. Resolution
    /// order:
    ///   1. For the Custom preset, honour `customKindOverride` if set
    ///      (so a self-hosted Anthropic / Gemini / Responses proxy can
    ///      pick its dialect from the Settings dropdown).
    ///   2. Otherwise look up the preset's intrinsic `kind`.
    ///   3. Unrecognised providerID falls back to `.openAIChat`, which
    ///      matches the historical "everything was OpenAI-compatible"
    ///      behaviour and is safe for pre-existing user libraries.
    var providerKind: AgentProviderKind {
        if providerID == AgentProviderPreset.customID,
           let override = customKindOverride {
            return override
        }
        return AgentProviderPreset.preset(id: providerID)?.kind ?? .openAIChat
    }
}

/// Transport-protocol family a preset speaks. `providerID` identifies
/// the vendor / relay station (OpenRouter, SiliconFlow, …); `kind`
/// identifies *how* we talk to it. Multiple providerIDs share the same
/// kind (every OpenAI-compatible relay → `.openAIChat`), and the same
/// vendor can expose more than one kind (OpenAI exposes both Chat
/// Completions and the newer Responses API).
enum AgentProviderKind: String, Codable, Equatable {
    /// Classic `/v1/chat/completions` SSE — OpenAI, DashScope, DeepSeek,
    /// Kimi, Moonshot, OpenRouter, SiliconFlow, AnyRouter, some.im, and
    /// the catch-all Custom preset all speak this dialect.
    case openAIChat
    /// New `/v1/responses` API — used by o-series reasoning models.
    case openAIResponses
    /// Anthropic native `/v1/messages` — `x-api-key` + `anthropic-version`
    /// headers, a wholly different request/event shape from OpenAI.
    case anthropicMessages
    /// Google AI Studio / Vertex `streamGenerateContent` — `?key=...`
    /// query param auth, function_declarations schema.
    case geminiGenerateContent
}

struct AgentProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Transport-protocol family. See `AgentProviderKind` doc-comment.
    let kind: AgentProviderKind
    let baseURL: String
    let defaultFlashModel: String
    let defaultProModel: String
    let supportsModelFetch: Bool
    let supportsImageInput: Bool
    let requiresAPIKey: Bool
    /// Short list of substrings that identify a model as belonging to
    /// this provider — used by `normalized()` to detect when a stale
    /// flash/pro model name from a previous provider got carried over
    /// after the user switched providers in Settings. Best-effort: an
    /// unrecognised name doesn't crash, it just sticks until the user
    /// picks one from the live model list.
    let modelHints: [String]

    static let openAIID = "openai"
    static let deepSeekID = "deepseek"
    static let ollamaID = "ollama"
    static let customID = "custom"
    static let someIMID = "some-im"

    var defaultModel: String { defaultFlashModel }
    var defaultVisionModel: String {
        if id == "dashscope" {
            return "qwen3-vl-plus"
        }
        if id == Self.customID {
            return ""
        }
        return defaultFlashModel
    }

    init(
        id: String,
        displayName: String,
        kind: AgentProviderKind = .openAIChat,
        baseURL: String,
        defaultModel: String,
        defaultFlashModel: String? = nil,
        defaultProModel: String? = nil,
        supportsModelFetch: Bool,
        supportsImageInput: Bool = true,
        requiresAPIKey: Bool = true,
        modelHints: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.defaultFlashModel = defaultFlashModel ?? defaultModel
        self.defaultProModel = defaultProModel ?? defaultModel
        self.supportsModelFetch = supportsModelFetch
        self.supportsImageInput = supportsImageInput
        self.requiresAPIKey = requiresAPIKey
        self.modelHints = modelHints
    }

    /// Quick "does this model name look like it could be one of mine"
    /// check. Custom provider says yes to everything (no opinion); a
    /// preset without hints also says yes (back-compat). Lowercase
    /// substring match against `modelHints`.
    func recognizesModelID(_ rawID: String) -> Bool {
        let id = rawID.lowercased()
        guard !id.isEmpty else { return true }
        guard self.id != Self.customID else { return true }
        guard !modelHints.isEmpty else { return true }
        return modelHints.contains { id.contains($0.lowercased()) }
    }

    static let all: [AgentProviderPreset] = [
        AgentProviderPreset(
            id: openAIID,
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4.1-mini",
            defaultProModel: "gpt-4.1",
            supportsModelFetch: true,
            modelHints: ["gpt-", "o1", "o3", "text-embedding", "davinci"]
        ),
        AgentProviderPreset(
            id: "openai-responses",
            displayName: "OpenAI Responses",
            kind: .openAIResponses,
            // Same origin as classic OpenAI; the adapter just hits
            // `/responses` instead of `/chat/completions`. Keep the
            // `/v1` suffix here — `AgentNetworkSupport.endpoint` will
            // collapse a duplicate when joining `responses`.
            baseURL: "https://api.openai.com/v1",
            // o-series reasoning models are the headline use case
            // for Responses; the cheaper / smaller `o4-mini` is the
            // sensible flash default, with `o3` as the pro tier.
            defaultModel: "o4-mini",
            defaultProModel: "o3",
            supportsModelFetch: true,
            modelHints: ["gpt-", "o1", "o3", "o4"]
        ),
        AgentProviderPreset(
            id: "dashscope",
            displayName: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            defaultProModel: "qwen-max",
            supportsModelFetch: true,
            modelHints: ["qwen", "qwq"]
        ),
        AgentProviderPreset(
            id: deepSeekID,
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-v4-flash",
            defaultProModel: "deepseek-v4-pro",
            supportsModelFetch: true,
            supportsImageInput: false,
            modelHints: ["deepseek"]
        ),
        AgentProviderPreset(
            id: "kimi",
            displayName: "Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2.5",
            supportsModelFetch: true,
            modelHints: ["kimi"]
        ),
        AgentProviderPreset(
            id: "moonshot",
            displayName: "Moonshot",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "moonshot-v1-8k",
            supportsModelFetch: true,
            modelHints: ["moonshot"]
        ),
        AgentProviderPreset(
            id: "claude",
            displayName: "Claude",
            kind: .anthropicMessages,
            // Adapter appends `v1/messages` / `v1/models` itself; the
            // base URL stays at the bare origin so the same field can
            // host enterprise / proxy deployments that mount Anthropic
            // under a different prefix.
            baseURL: "https://api.anthropic.com",
            defaultModel: "claude-sonnet-4-5",
            supportsModelFetch: true,
            modelHints: ["claude", "anthropic"]
        ),
        AgentProviderPreset(
            id: "gemini",
            displayName: "Google Gemini",
            kind: .geminiGenerateContent,
            // Adapter appends `v1beta/models/{model}:streamGenerateContent`
            // (or `:generateContent` for the non-streaming classifier).
            // Base URL stays at the bare origin so enterprise / Vertex
            // proxies that mount Gemini under a custom prefix can reuse
            // the same field without us hardcoding `v1beta`.
            baseURL: "https://generativelanguage.googleapis.com",
            defaultModel: "gemini-2.5-flash",
            defaultProModel: "gemini-2.5-pro",
            supportsModelFetch: true,
            modelHints: ["gemini"]
        ),
        // ---- Relay stations (all OpenAI Chat-compatible) ----
        // OpenRouter aggregates 100+ models behind one API. We default
        // to a free-tier text model so the user can verify the
        // connection without spending budget; chat picker shows
        // alternates from the live /models fetch.
        AgentProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-4o-mini",
            defaultProModel: "anthropic/claude-sonnet-4.5",
            supportsModelFetch: true,
            // Model IDs on OpenRouter are namespaced (`vendor/model`)
            // and span every major lab — a hint list would either be
            // misleadingly narrow or pointlessly broad. Empty list →
            // `recognizesModelID` defaults to true, which is the
            // right call for an aggregator.
            modelHints: []
        ),
        // SiliconFlow (硅基流动) — a popular Chinese relay with cheap
        // access to Qwen / DeepSeek / GLM / Yi / etc.
        AgentProviderPreset(
            id: "siliconflow",
            displayName: "SiliconFlow (硅基流动)",
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModel: "Qwen/Qwen2.5-7B-Instruct",
            defaultProModel: "deepseek-ai/DeepSeek-V3",
            supportsModelFetch: true,
            modelHints: []
        ),
        // AnyRouter — same shape as OpenRouter, different vendor.
        // Base URL placeholder; user should override if their account
        // is on a different shard.
        AgentProviderPreset(
            id: "anyrouter",
            displayName: "AnyRouter",
            baseURL: "https://anyrouter.top/v1",
            defaultModel: "gpt-4o-mini",
            defaultProModel: "claude-sonnet-4-5",
            supportsModelFetch: true,
            modelHints: []
        ),
        // some.im managed relay. Every account can have its own routing
        // config, but the product-facing provider name stays canonical.
        AgentProviderPreset(
            id: "some-im",
            displayName: "some.im",
            baseURL: "https://some.im/v1",
            defaultModel: "deepseek-v4-flash",
            defaultProModel: "deepseek-v4-pro",
            supportsModelFetch: true,
            modelHints: []
        ),
        AgentProviderPreset(
            id: ollamaID,
            displayName: "Ollama / Local OpenAI",
            baseURL: "http://127.0.0.1:11434/v1",
            defaultModel: "qwen3.5-4b-vl-q4_k_m",
            defaultProModel: "qwen3.5-4b-vl-q4_k_m",
            supportsModelFetch: true,
            requiresAPIKey: false,
            modelHints: []
        ),
        AgentProviderPreset(
            id: customID,
            displayName: "Custom",
            baseURL: "",
            defaultModel: "",
            supportsModelFetch: true
        )
    ]

    static func preset(id: String) -> AgentProviderPreset? {
        all.first { $0.id == id }
    }

    static func normalizedDisplayName(providerID: String?, storedDisplayName: String?) -> String? {
        let normalizedID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = storedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedID == someIMID || display == "some.im (Rocky's relay)" {
            return preset(id: someIMID)?.displayName ?? "some.im"
        }
        if !display.isEmpty {
            return display
        }
        if !normalizedID.isEmpty {
            return preset(id: normalizedID)?.displayName ?? normalizedID
        }
        return nil
    }

    static func matchingBaseURL(_ baseURL: String) -> AgentProviderPreset? {
        let normalized = normalizeBaseURL(baseURL)
        return all.first { preset in
            !preset.baseURL.isEmpty && normalizeBaseURL(preset.baseURL) == normalized
        }
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t")).lowercased()
    }
}

enum AgentPatchStatus: String, Codable {
    case pending
    case applied
    case rejected
    case failed
}

struct AgentPatchProposal: Identifiable, Codable, Equatable {
    let id: UUID
    let messageID: UUID
    let title: String
    let diff: String
    var status: AgentPatchStatus
    var statusMessage: String?

    init(
        id: UUID = UUID(),
        messageID: UUID,
        title: String,
        diff: String,
        status: AgentPatchStatus = .pending,
        statusMessage: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.title = title
        self.diff = diff
        self.status = status
        self.statusMessage = statusMessage
    }
}

struct AgentLineChangeStats: Equatable {
    var added: Int?
    var deleted: Int?

    nonisolated init(added: Int?, deleted: Int?) {
        self.added = added
        self.deleted = deleted
    }
}

struct AgentFileChangeSummary: Identifiable, Equatable {
    var path: String
    var kind: GitFileStatusKind
    var lineStats: AgentLineChangeStats

    nonisolated var id: String { path }

    nonisolated var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    nonisolated var addedLines: Int {
        lineStats.added ?? 0
    }

    nonisolated var deletedLines: Int {
        lineStats.deleted ?? 0
    }

    nonisolated var hasKnownLineStats: Bool {
        lineStats.added != nil || lineStats.deleted != nil
    }
}

struct AgentWorktreeChangeSummary: Equatable {
    var repositoryRoot: URL?
    var files: [AgentFileChangeSummary]

    nonisolated init(repositoryRoot: URL? = nil, files: [AgentFileChangeSummary] = []) {
        self.repositoryRoot = repositoryRoot
        self.files = files.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    nonisolated var isEmpty: Bool {
        files.isEmpty
    }

    nonisolated var fileCount: Int {
        files.count
    }

    nonisolated var totalAddedLines: Int {
        files.reduce(0) { $0 + $1.addedLines }
    }

    nonisolated var totalDeletedLines: Int {
        files.reduce(0) { $0 + $1.deletedLines }
    }

    nonisolated func change(for relativePath: String) -> AgentFileChangeSummary? {
        files.first { $0.path == relativePath }
    }

    nonisolated func filtering(paths: Set<String>) -> AgentWorktreeChangeSummary {
        guard !paths.isEmpty else {
            return AgentWorktreeChangeSummary(repositoryRoot: repositoryRoot)
        }
        return AgentWorktreeChangeSummary(
            repositoryRoot: repositoryRoot,
            files: files.filter { paths.contains($0.path) }
        )
    }
}

struct AgentWorktreeDiffPreview: Identifiable, Equatable {
    let id: UUID
    var title: String
    var diff: String

    nonisolated init(id: UUID = UUID(), title: String, diff: String) {
        self.id = id
        self.title = title
        self.diff = diff
    }
}

enum AgentPatchError: LocalizedError {
    case emptyDiff
    case unsupportedDiff
    case noWorkspace
    case pathOutsideWorkspace(String)
    case missingFile(String)
    case hunkDidNotMatch(String)
    case targetAlreadyExists(String)
    case duplicateTarget(String)
    case writeVerificationFailed(String)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyDiff:
            return L10n.AgentPatchError.emptyDiff
        case .unsupportedDiff:
            return L10n.AgentPatchError.unsupportedDiff
        case .noWorkspace:
            return L10n.AgentPatchError.noWorkspace
        case .pathOutsideWorkspace(let path):
            return L10n.AgentPatchError.pathOutsideWorkspace(path)
        case .missingFile(let path):
            return L10n.AgentPatchError.missingFile(path)
        case .hunkDidNotMatch(let path):
            return L10n.AgentPatchError.hunkDidNotMatch(path)
        case .targetAlreadyExists(let path):
            return L10n.AgentPatchError.targetAlreadyExists(path)
        case .duplicateTarget(let path):
            return L10n.AgentPatchError.duplicateTarget(path)
        case .writeVerificationFailed(let path):
            return L10n.AgentPatchError.writeVerificationFailed(path)
        case .rollbackFailed(let path):
            return L10n.AgentPatchError.rollbackFailed(path)
        }
    }
}

enum AgentClientError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case serverStatus(AgentProviderHTTPError)
    /// The provider accepted the request (HTTP 2xx) but the SSE stream
    /// closed without emitting a single meaningful event — no text, no
    /// reasoning, no tool call, not even a finish_reason. A relay whose
    /// token has expired (or an upstream hiccup / rate-limit expressed as
    /// an empty body) shows up exactly like this. Without this case the
    /// turn would be treated as a silent success: placeholder dropped, no
    /// card, no reply — the user sees nothing happen.
    case emptyStream(providerID: String, model: String)
    /// Thrown when `AgentClient` is asked to talk to a provider whose
    /// transport-protocol family has no adapter wired up yet. Only
    /// expected during the multi-provider rollout — once Anthropic /
    /// Gemini / Responses adapters land this should become unreachable.
    case unsupportedProviderKind(AgentProviderKind)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key in Settings before sending an agent request."
        case .invalidBaseURL:
            return "The agent base URL is invalid."
        case .invalidResponse:
            return "The model provider returned an invalid response."
        case .serverStatus(let error):
            return "The model provider returned HTTP \(error.statusCode)."
        case .emptyStream(let providerID, let model):
            return "The provider \(providerID) (\(model)) returned an empty stream."
        case .unsupportedProviderKind(let kind):
            return "Support for the \(kind.rawValue) protocol is not enabled in this build yet."
        }
    }
}

struct AgentProviderHTTPError: Equatable {
    let statusCode: Int
    let method: String
    let url: String
    let providerID: String
    let model: String
    let requestSummary: String
    let requestBody: String
    let responseBody: String
}

struct AgentErrorDetails: Equatable, Identifiable {
    let id = UUID()
    let sections: [Section]

    struct Section: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
}

nonisolated enum AgentAttachmentParseStatus: String, Codable, Equatable, Sendable {
    case parsing
    case ready
    case failed
}

nonisolated enum AgentAttachmentDocumentKind: String, Codable, Equatable, Sendable {
    case text
    case pdf
    case word
    case spreadsheet
}

nonisolated enum AgentAttachmentSectionKind: String, Codable, Equatable, Sendable {
    case page
    case sheet
    case heading
    case chunk
}

nonisolated struct AgentAttachmentSection: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: AgentAttachmentSectionKind
    let ordinal: Int
    let title: String
    let sourceReference: String
    let text: String
    let wasRecognizedByOCR: Bool
}

/// Lightweight per-section metadata kept in session JSON after the full
/// extracted text moved into an `AgentAttachmentContentStore` sidecar file.
nonisolated struct AgentAttachmentSectionSummary: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: AgentAttachmentSectionKind
    let ordinal: Int
    let title: String
    let sourceReference: String
    let characterCount: Int
    let preview: String
    let wasRecognizedByOCR: Bool

    init(section: AgentAttachmentSection) {
        id = section.id
        kind = section.kind
        ordinal = section.ordinal
        title = section.title
        sourceReference = section.sourceReference
        characterCount = section.text.count
        preview = Self.preview(of: section.text)
        wasRecognizedByOCR = section.wasRecognizedByOCR
    }

    private static let maxPreviewCharacters = 160

    private static func preview(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxPreviewCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxPreviewCharacters)
        return String(trimmed[..<end]) + "…"
    }
}

nonisolated struct AgentAttachmentAnalysis: Codable, Equatable, Sendable {
    let documentKind: AgentAttachmentDocumentKind
    /// Per-section metadata (titles, locators, sizes) that stays in session
    /// JSON so lists and toggles render without touching the sidecar file.
    private(set) var sectionSummaries: [AgentAttachmentSectionSummary]
    /// Content-addressed sidecar file holding the full section texts.
    private(set) var contentFilePath: String?
    private(set) var contentSHA256: String?
    /// Full sections still held inline: a fresh parse before `externalized()`
    /// ran, or a legacy session whose JSON inlines the text. Encoded back
    /// under the legacy `sections` key so nothing is lost if externalization
    /// fails or never runs.
    private(set) var inlineSections: [AgentAttachmentSection]?
    let totalUnitCount: Int
    let didUseOCR: Bool
    let warnings: [String]
    let containsPotentialPromptInjection: Bool

    init(
        documentKind: AgentAttachmentDocumentKind,
        sections: [AgentAttachmentSection],
        totalUnitCount: Int,
        didUseOCR: Bool,
        warnings: [String],
        containsPotentialPromptInjection: Bool
    ) {
        self.documentKind = documentKind
        self.sectionSummaries = sections.map(AgentAttachmentSectionSummary.init)
        self.inlineSections = sections
        self.totalUnitCount = totalUnitCount
        self.didUseOCR = didUseOCR
        self.warnings = warnings
        self.containsPotentialPromptInjection = containsPotentialPromptInjection
    }

    var extractedCharacterCount: Int {
        sectionSummaries.reduce(0) { $0 + $1.characterCount }
    }

    /// Compatibility accessor for code paths that need the full extracted
    /// text. New list and toggle UI should prefer `sectionSummaries` so it
    /// does not read a sidecar file while rendering.
    var sections: [AgentAttachmentSection] { loadedSections() }

    var needsContentExternalization: Bool { inlineSections != nil }

    /// Full section texts. Reads the sidecar file when the content was
    /// externalized, so call at send/render/export time — not per frame.
    func loadedSections() -> [AgentAttachmentSection] {
        if let inlineSections { return inlineSections }
        guard let contentFilePath, let contentSHA256 else { return [] }
        return AgentAttachmentContentStore.loadSections(
            atPath: contentFilePath,
            expectedSHA256: contentSHA256
        ) ?? []
    }

    /// Moves the inline section texts into the content store, leaving only
    /// summaries plus a path/hash reference behind.
    func externalized() throws -> AgentAttachmentAnalysis {
        guard let inlineSections else { return self }
        let stored = try AgentAttachmentContentStore.store(sections: inlineSections)
        var copy = self
        copy.contentFilePath = stored.filePath
        copy.contentSHA256 = stored.sha256
        copy.inlineSections = nil
        return copy
    }

    /// Externalizes, keeping the inline copy on failure so the attachment
    /// stays usable (just heavier) when the disk write fails.
    func externalizedOrInline() -> AgentAttachmentAnalysis {
        do {
            return try externalized()
        } catch {
            print("AgentAttachmentContentStore: failed to externalize attachment content")
            return self
        }
    }

    enum CodingKeys: String, CodingKey {
        case documentKind
        // Legacy key: full sections inlined in session JSON.
        case sections
        case sectionSummaries, contentFilePath, contentSHA256
        case totalUnitCount, didUseOCR, warnings, containsPotentialPromptInjection
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentKind = try c.decode(AgentAttachmentDocumentKind.self, forKey: .documentKind)
        let inline = try c.decodeIfPresent([AgentAttachmentSection].self, forKey: .sections)
        inlineSections = inline
        sectionSummaries = try c.decodeIfPresent([AgentAttachmentSectionSummary].self, forKey: .sectionSummaries)
            ?? inline?.map(AgentAttachmentSectionSummary.init)
            ?? []
        contentFilePath = try c.decodeIfPresent(String.self, forKey: .contentFilePath)
        contentSHA256 = try c.decodeIfPresent(String.self, forKey: .contentSHA256)
        totalUnitCount = try c.decode(Int.self, forKey: .totalUnitCount)
        didUseOCR = try c.decode(Bool.self, forKey: .didUseOCR)
        warnings = try c.decode([String].self, forKey: .warnings)
        containsPotentialPromptInjection = try c.decode(Bool.self, forKey: .containsPotentialPromptInjection)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(documentKind, forKey: .documentKind)
        try c.encodeIfPresent(inlineSections, forKey: .sections)
        try c.encode(sectionSummaries, forKey: .sectionSummaries)
        try c.encodeIfPresent(contentFilePath, forKey: .contentFilePath)
        try c.encodeIfPresent(contentSHA256, forKey: .contentSHA256)
        try c.encode(totalUnitCount, forKey: .totalUnitCount)
        try c.encode(didUseOCR, forKey: .didUseOCR)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(containsPotentialPromptInjection, forKey: .containsPotentialPromptInjection)
    }
}

/// A local file staged in the composer. Parsing starts immediately so the UI
/// can preview exactly what will be sent; the original URL remains the source
/// of truth and can be re-attached when the user wants a fresh parse.
nonisolated struct AgentFileAttachment: Identifiable, Codable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    var parseStatus: AgentAttachmentParseStatus = .parsing
    var analysis: AgentAttachmentAnalysis?
    var parseError: String?
    var excludedSectionIDs: Set<String> = []
    var isEnabled: Bool = true
    var sourceFileSize: Int64?
    var sourceModifiedAt: Date?
    /// Set only after the user explicitly confirms that an otherwise unknown
    /// file of at most 8 KB should be decoded and sent as plain text.
    var treatsUnknownTypeAsText: Bool?

    var id: String { url.standardizedFileURL.path }

    var includedSections: [AgentAttachmentSection] {
        guard let analysis else { return [] }
        return analysis.loadedSections().filter { !excludedSectionIDs.contains($0.id) }
    }

    func externalizingAttachmentContent() -> AgentFileAttachment {
        guard let analysis else { return self }
        var copy = self
        copy.analysis = analysis.externalizedOrInline()
        return copy
    }
}

nonisolated enum AgentKnowledgeFolderIndexStatus: String, Codable, Equatable, Sendable {
    case pending
    case indexing
    case ready
    case failed
}

nonisolated enum AgentDocumentTaskMode: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case summarize
    case compare
    case spreadsheetAnalysis
    case codeReview
    case evidenceExtraction
}

nonisolated struct AgentKnowledgeFolder: Identifiable, Codable, Equatable, Sendable {
    let url: URL
    var isEnabled: Bool = true
    var status: AgentKnowledgeFolderIndexStatus = .pending
    var documents: [AgentFileAttachment] = []
    var excludedPatterns: [String] = []
    var skippedFileCount: Int = 0
    var lastIndexedAt: Date?
    var errorMessage: String?

    var id: String { url.standardizedFileURL.path }

    func externalizingAttachmentContent() -> AgentKnowledgeFolder {
        var copy = self
        copy.documents = documents.map { $0.externalizingAttachmentContent() }
        return copy
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
