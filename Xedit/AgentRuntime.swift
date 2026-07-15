//
//  AgentRuntime.swift
//  WillDeep
//
//  Per-session Agent runtime. Owns every piece of state that used to
//  live as a `@Published agent*` field directly on AppState. The split
//  is the prerequisite for v1.49's real concurrency: once each session
//  has its own runtime, multiple sessions can run their own turns
//  without sharing single-instance fields like `isResponding`,
//  `requestTask`, or `toolDecisionWaiter`.
//
//  v1.49 rcs:
//   - rc1: AgentRuntime scaffold (workspace + session only).
//   - rc2 (this rc): full state moves in here; UI binds to runtime;
//                    behavior still serial — only the activeRuntime
//                    actually dispatches a turn.
//   - rc3: real concurrent dispatch with per-provider limits.
//   - rc4: sidebar busy indicators, queues, settings, polish.
//

import Foundation
import Combine

@MainActor
final class AgentRuntime: ObservableObject, Identifiable {
    let id: AgentSession.ID

    /// The persisted session this runtime is driving. Mutated as the
    /// conversation progresses and written back via `persist()`.
    /// Workspace path comes from this — runtimes never look at
    /// `AppState.rootDirectory`, so changing the window's current folder
    /// doesn't cross-contaminate a session that was started against a
    /// different workspace.
    @Published var session: AgentSession

    /// Frozen at construction. Multiple runtimes will eventually run in
    /// parallel (rc3); none of them can rely on `AppState.rootDirectory`
    /// for "this session's workspace" — that's a window-level concept
    /// that drifts when the user opens a different folder.
    private(set) var workspaceRootPath: String?
    private(set) var workspaceLocation: WorkspaceLocation?
    @Published private(set) var workspaceAvailability: AgentWorkspaceAvailability = .optimistic

    // MARK: - Conversation state

    @Published var messages: [AgentMessage] = []
    @Published var contextSummary: String?
    @Published var contextSummaryThroughMessageID: AgentMessage.ID?
    @Published var patchProposals: [AgentPatchProposal] = []
    @Published var toolCalls: [AgentToolCall] = []
    @Published var latestComputerUseActivity: AgentComputerUseActivity?

    // MARK: - Composer state (per-session draft — switching tabs preserves)

    @Published var input: String = ""
    @Published var pendingImages: [AgentImageAttachment] = []
    @Published var pendingTextAttachments: [AgentTextAttachment] = []
    @Published var pendingSkills: [AgentSkillEntry] = []
    @Published var pendingFiles: [AgentFileAttachment] = []
    @Published var documentAttachments: [AgentFileAttachment] = []
    @Published var knowledgeFolders: [AgentKnowledgeFolder] = []
    @Published var documentTaskMode: AgentDocumentTaskMode = .automatic
    @Published var redactSensitiveAttachmentContent: Bool = true
    @Published var pendingIncludeWorkspaceOverview: Bool = false
    @Published var queuedMessages: [AgentQueuedMessage] = []

    // MARK: - Turn lifecycle

    @Published var isResponding: Bool = false
    /// True while a sent message is parked in `pendingDispatchQueue`
    /// waiting for a free per-provider concurrency slot. The user's
    /// message is already visible in the transcript; this drives a
    /// lightweight "queued, waiting for a free slot" indicator so the
    /// send never looks like it silently vanished. Cleared the moment
    /// the dispatch acquires a slot and the real turn begins.
    @Published var isAwaitingProviderSlot: Bool = false
    @Published var turnStartedAt: Date?
    @Published var isCompressingContext: Bool = false
    @Published var errorMessage: String?
    @Published var errorDetails: AgentErrorDetails?
    /// True when `errorMessage` is the "some.im not logged in" gate (see
    /// `AppState.someIMLoginRequiredForTurn`). Drives the error card's extra
    /// "去登录 some.im" affordance. Always reset alongside `errorMessage`.
    @Published var errorRequiresSomeIMLogin: Bool = false

    // MARK: - Per-session mode & overrides

    @Published var interactionMode: AgentInteractionMode = .normal
    @Published var approvalMode: AgentApprovalMode = .smart
    @Published var executionAgent: AgentExecutionAgent = .willDeep
    @Published var activeExperts: Set<AgentExpert> = []
    @Published var currentPlan: AgentPlan?
    /// Runtime-only pre-dispatch prompt for complex Normal-mode tasks.
    /// Keeping it per session prevents one chat's countdown from appearing
    /// after the user switches to another conversation.
    @Published var pendingPlanModeSuggestion: AgentPlanModeSuggestion?
    @Published var currentGoal: AgentGoal?
    /// Runtime-only guard for mid-turn manual goal edits. If the user edits
    /// the goal while an old request is already in flight, that older reply's
    /// trailing `goal-check` block must not be applied to the new checklist.
    @Published var currentGoalEditedAt: Date?
    @Published var learningEvents: [AgentLearningEvent] = []
    @Published var latestTurnRecall: AgentTurnRecallSnapshot?
    @Published var sidePanelState: AgentSidePanelState = .empty
    /// Last image candidate selected from a widget in this runtime. This is
    /// runtime-only context: the clicked widget still sends a normal user
    /// message, while the next turn also receives a compact structured block
    /// so follow-up tools can use the chosen image without transcript mining.
    @Published var latestImageChoice: AgentImageChoiceSelection?
    /// Last Replicate/some.im mask-edit submission for this runtime. Kept
    /// separate from the registry so the model receives the most recent
    /// source/mask/task anchors as turn context even before the task finishes.
    @Published var latestImageEditSubmission: AgentImageEditSubmission?
    /// Most recent media task completion surfaced to this runtime. This keeps
    /// async image/video outputs actionable in the same turn that drains the
    /// completion queue.
    @Published var latestMediaTaskCompletion: AgentMediaTaskCompletionContext?
    /// Most recent manual media-task refresh batch from the side panel. The
    /// next model turn can use this to decide whether to wait, poll again,
    /// continue from completed artifacts, or recover failed tasks.
    @Published var latestMediaTaskRefresh: AgentMediaTaskRefreshContext?
    /// Most recent manifest/package import from Ruby, Skill, or third-party
    /// API scripts. Keeps pending/completed/failed imported tasks available to
    /// the next model turn even after the tool output scrolls away.
    @Published var latestMediaImport: AgentMediaImportContext?
    /// Last structured tool action emitted by a sandboxed widget. Widgets can
    /// ask the chat loop to run tools, but never execute them directly.
    @Published var latestWidgetToolAction: AgentWidgetToolAction?
    @Published var sessionModelOverride: String?
    /// Per-session some.im managed-routing state ("省心托管"). Mirrors
    /// `AgentSession.managedRouting`; non-nil only for managed sessions and
    /// carries the only-goes-up capability floor.
    @Published var managedRouting: AgentManagedRoutingState?
    /// True after the runtime successfully applied at least one patch.
    /// Drives the "正在编辑 / N 个文件已更改" worktree card so empty
    /// sessions never light it up.
    @Published var didEditFiles: Bool = false
    /// Workspace-relative paths the Agent has actually written to in
    /// this session (via apply_patch). Used to filter the worktree-change
    /// card so it shows only files Agent touched — never the user's own
    /// uncommitted edits or untracked junk like `__pycache__/*.pyc`.
    @Published var agentEditedPaths: Set<String> = []
    /// User-facing files created during this conversation. Kept separately
    /// from Git state so committing an output does not make it disappear from
    /// the right-rail artifact list.
    @Published var agentArtifactPaths: Set<String> = []
    /// Live `git status` snapshot for this session's workspace. Each
    /// runtime owns its own — switching from a session in workspace A
    /// to one in workspace B shouldn't briefly show A's changes. The
    /// refresh task is driven by the same code that drives the global
    /// gitStatus, but writes into this per-runtime field.
    @Published var worktreeChanges: AgentWorktreeChangeSummary = .init()
    /// Whether the inline changed-file list above the composer is expanded.
    /// Default collapsed so only the sticky composer summary bar is visible.
    @Published var isWorktreeChangeCardExpanded: Bool = false

    // MARK: - Non-published runtime plumbing

    /// The in-flight provider request for the current turn, or nil
    /// when idle. Cancelled when the session is closed or the user
    /// stops the response.
    var requestTask: Task<Void, Never>?
    /// Runtime-side fallback for the Plan suggestion countdown. The banner
    /// also renders its own per-second progress, but auto-resolution must not
    /// depend on the composer currently being mounted on screen.
    var planModeSuggestionAutoResolveTask: Task<Void, Never>?
    /// Skills that were explicitly attached to the in-flight user turn.
    /// They are cleared/overwritten on the next dispatch and used only
    /// to explain turn recall in reports.
    var currentTurnAttachedSkills: [AgentSkillEntry] = []

    /// Set when the user presses Stop while queued messages exist. The
    /// cancelled turn skips post-turn compression so the queue head can
    /// dispatch as soon as the provider/tool loop unwinds.
    var shouldConsumeQueueAfterStop: Bool = false

    /// Continuation resumed when the user resolves a blocking tool
    /// call (Allow / Deny / Confirm / answer ask_user). Per-runtime
    /// so concurrent sessions don't race over a single waiter slot.
    var toolDecisionWaiter: CheckedContinuation<AgentToolDecision, Never>?
    /// The specific tool call currently backed by `toolDecisionWaiter`.
    /// Without this guard, clicking a different pending card could resume
    /// the wrong continuation when multiple approval cards are visible.
    var toolDecisionWaiterCallID: AgentToolCall.ID?
    /// Decisions clicked before the tool loop has registered its waiter.
    /// This closes the race where the UI card accepts a click but the
    /// continuation slot is not ready yet, leaving an apparently dead card.
    var pendingToolDecisions: [AgentToolCall.ID: AgentToolDecision] = [:]

    // MARK: - Plan gate

    /// True when Plan mode is on AND no active approved/executing plan exists.
    /// Completed plans require a fresh approval before later write-tier work.
    var isPlanGateActive: Bool {
        guard interactionMode == .plan else { return false }
        guard let plan = currentPlan else { return true }
        return plan.status != .approved && plan.status != .executing
    }

    // MARK: - Init

    init(session: AgentSession) {
        self.id = session.id
        self.session = session
        self.workspaceRootPath = session.workspaceRootPath
        self.workspaceLocation = session.workspaceLocation

        // Seed live state from persisted session.
        self.messages = session.messages.map(Self.normalizingInterruptedConsultation)
        self.latestComputerUseActivity = AgentComputerUseActivity.latest(in: self.messages)
        self.contextSummary = session.contextSummary
        self.contextSummaryThroughMessageID = session.contextSummaryThroughMessageID
        self.didEditFiles = session.didEditFiles
        self.agentEditedPaths = Set(session.agentEditedPaths)
        self.agentArtifactPaths = Set(session.agentArtifactPaths)
        self.interactionMode = session.interactionMode
        self.approvalMode = session.approvalMode
        self.executionAgent = session.executionAgent
        self.activeExperts = session.activeExperts
        self.currentPlan = session.currentPlan
        self.currentGoal = session.currentGoal
        self.learningEvents = session.learningEvents
        self.latestTurnRecall = session.latestTurnRecall
        self.documentAttachments = session.documentAttachments
        self.knowledgeFolders = session.knowledgeFolders
        self.documentTaskMode = session.documentTaskMode
        self.redactSensitiveAttachmentContent = session.redactSensitiveAttachmentContent
        self.sidePanelState = session.sidePanelState
        self.managedRouting = session.managedRouting
    }

    private static func normalizingInterruptedConsultation(_ message: AgentMessage) -> AgentMessage {
        guard message.role == .workflowReport,
              var report = message.workflowReport,
              report.consultation != nil,
              report.status == .planning || report.status == .running else {
            return message
        }
        var normalized = message
        report.status = .cancelled
        report.finishedAt = report.finishedAt ?? Date()
        report.summary = report.summary.isEmpty ? L10n.Consultation.interrupted : report.summary
        if var consultation = report.consultation {
            consultation.phase = .cancelled
            report.consultation = consultation
        }
        normalized.workflowReport = report
        return normalized
    }

    /// Move an idle/new session to another workspace. Used by the
    /// composer workspace picker before the first user turn, so the
    /// sidebar immediately reflects the selected folder.
    func rebindWorkspace(to path: String?) {
        let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceRootPath = normalized?.isEmpty == true ? nil : normalized
        workspaceLocation = workspaceRootPath.map { .local(path: $0) }
        workspaceAvailability = .optimistic
        session.workspaceRootPath = workspaceRootPath
        session.workspaceLocation = workspaceLocation
        session.localWorkspaceIdentity = AgentWorkspaceAvailabilityResolver.captureIdentity(for: workspaceRootPath)
    }

    func rebindRemoteWorkspace(runtimeID: UUID, path: String) {
        let normalized = RemotePathValidator.normalizedWorkspaceRoot(path)
        workspaceRootPath = nil
        workspaceLocation = .remote(runtimeID: runtimeID, path: normalized)
        workspaceAvailability = .optimistic
        session.workspaceRootPath = nil
        session.workspaceLocation = workspaceLocation
        session.localWorkspaceIdentity = nil
    }

    func localWorkspaceURLForOptimisticUse() throws -> URL? {
        if workspaceAvailability.blocksLocalWorkspaceUse,
           let message = workspaceAvailability.message {
            throw AgentWorkspaceAvailabilityError.unavailable(message)
        }
        guard let path = workspaceLocation?.localPath ?? workspaceRootPath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    @discardableResult
    func diagnoseLocalWorkspaceAfterFailure() -> AgentWorkspaceAvailability? {
        guard let path = workspaceLocation?.localPath ?? workspaceRootPath, !path.isEmpty else {
            return nil
        }
        let identity = session.localWorkspaceIdentity
            ?? AgentWorkspaceAvailabilityResolver.captureIdentity(for: path)
        if session.localWorkspaceIdentity == nil, identity?.hasIdentity == true {
            session.localWorkspaceIdentity = identity
        }
        let availability = AgentWorkspaceAvailabilityResolver.diagnose(path: path, identity: identity)
        workspaceAvailability = availability
        return availability
    }

    /// The runtime's current local checkout path, if it's bound to one.
    /// Mirrors the resolution order of the workspace-availability helpers
    /// but never throws or diagnoses — purely a read for lightweight UI
    /// signals like the same-directory collision hint. `nil` for remote
    /// runtimes or an unbound session.
    var localWorkspacePath: String? {
        guard let path = workspaceLocation?.localPath ?? workspaceRootPath, !path.isEmpty else {
            return nil
        }
        return path
    }

    // MARK: - Persistence

    /// Push the runtime's persisted-shape state back onto `session`
    /// and enqueue an ordered background write. The disk I/O rides
    /// `AgentSessionStore`'s serial write queue instead of blocking the
    /// main actor; write failures are broadcast via
    /// `AgentSessionStore.saveDidFailNotification` (each AppState
    /// instance claims failures for the runtimes it owns).
    func persist(touchUpdatedAt: Bool = true) {
        session.messages = messages
        session.contextSummary = contextSummary
        session.contextSummaryThroughMessageID = contextSummaryThroughMessageID
        session.workspaceRootPath = workspaceRootPath
        session.workspaceLocation = workspaceLocation
        if workspaceLocation?.localPath == nil {
            session.localWorkspaceIdentity = nil
        } else if session.localWorkspaceIdentity == nil {
            session.localWorkspaceIdentity = AgentWorkspaceAvailabilityResolver.captureIdentity(for: workspaceLocation?.localPath ?? workspaceRootPath)
        }
        session.didEditFiles = didEditFiles
        session.agentEditedPaths = agentEditedPaths.sorted()
        session.agentArtifactPaths = agentArtifactPaths.sorted()
        session.interactionMode = interactionMode
        session.approvalMode = approvalMode
        session.executionAgent = executionAgent
        session.activeExperts = activeExperts
        session.currentPlan = currentPlan
        session.currentGoal = currentGoal
        session.learningEvents = learningEvents
        session.latestTurnRecall = latestTurnRecall
        session.documentAttachments = documentAttachments
        session.knowledgeFolders = knowledgeFolders
        session.documentTaskMode = documentTaskMode
        session.redactSensitiveAttachmentContent = redactSensitiveAttachmentContent
        session.sidePanelState = sidePanelState
        session.managedRouting = managedRouting
        if touchUpdatedAt {
            session.updatedAt = Date()
        }
        // Two title sources fight for this slot:
        //   1. User-set (sidebar rename) — `titleIsUserSet == true`,
        //      we leave it alone forever.
        //   2. Auto-derived prefix of first user message — runs on
        //      every persist as a "first impression" placeholder until
        //      the LLM summarizer (see AppStateAgentTitleSummarizer)
        //      replaces it with something nicer. The summarizer also
        //      clears titleIsUserSet — it stays false because it's
        //      still an automatic origin, which means a future
        //      first-user-message change could legitimately re-derive
        //      (rare, but cheap to allow).
        if !session.titleIsUserSet {
            let derived = AgentSessionStore.deriveTitle(from: messages)
            if !derived.isEmpty {
                session.title = derived
            }
        }
        AgentSessionStore.saveAsync(session)
    }

    // MARK: - Managed routing ("省心托管") floor

    /// Raise the managed-routing capability floor. Router-driven changes are
    /// only-goes-up: a tier at or below the current floor is ignored. Returns
    /// true if the floor rose. Callers persist afterwards.
    @discardableResult
    func raiseManagedFloor(to tier: AgentManagedCapabilityTier, reason: String?) -> Bool {
        guard var state = managedRouting else { return false }
        guard tier > state.minimumTier else { return false }
        state.minimumTier = tier
        state.lastEscalatedAt = Date()
        state.lastEscalationReason = reason
        managedRouting = state
        return true
    }

    /// Record the main-call model the router resolved to this turn
    /// (diagnostic only; does not affect the floor).
    func noteManagedSelectedModel(_ model: String) {
        guard var state = managedRouting else { return }
        guard state.lastSelectedModel != model else { return }
        state.lastSelectedModel = model
        managedRouting = state
    }

    /// User-selected managed-routing floor. Unlike router escalation, this can
    /// move both up and down. No-op when the session is not managed.
    func setManagedFloor(to tier: AgentManagedCapabilityTier) {
        guard var state = managedRouting else { return }
        guard state.minimumTier != tier else { return }
        state.minimumTier = tier
        if tier == .low {
            state.lastEscalatedAt = nil
            state.lastEscalationReason = nil
        } else {
            state.lastEscalatedAt = Date()
            state.lastEscalationReason = "user_selected_\(tier.rawValue)"
        }
        managedRouting = state
    }

    /// Reset the managed floor to `.low`. No-op when the session is not
    /// managed.
    func resetManagedFloor() {
        setManagedFloor(to: .low)
    }

    /// True if this session has no real user messages yet.
    var isEmpty: Bool {
        !messages.contains(where: { $0.role == .user })
    }
}
