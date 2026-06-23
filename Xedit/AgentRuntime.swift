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

    // MARK: - Conversation state

    @Published var messages: [AgentMessage] = []
    @Published var contextSummary: String?
    @Published var contextSummaryThroughMessageID: AgentMessage.ID?
    @Published var patchProposals: [AgentPatchProposal] = []
    @Published var toolCalls: [AgentToolCall] = []

    // MARK: - Composer state (per-session draft — switching tabs preserves)

    @Published var input: String = ""
    @Published var pendingImages: [AgentImageAttachment] = []
    @Published var pendingTextAttachments: [AgentTextAttachment] = []
    @Published var pendingSkills: [AgentSkillEntry] = []
    @Published var pendingFiles: [AgentFileAttachment] = []
    @Published var pendingIncludeWorkspaceOverview: Bool = false
    @Published var queuedMessages: [AgentQueuedMessage] = []

    // MARK: - Turn lifecycle

    @Published var isResponding: Bool = false
    @Published var turnStartedAt: Date?
    @Published var isCompressingContext: Bool = false
    @Published var errorMessage: String?
    @Published var errorDetails: AgentErrorDetails?

    // MARK: - Per-session mode & overrides

    @Published var interactionMode: AgentInteractionMode = .normal
    @Published var approvalMode: AgentApprovalMode = .smart
    @Published var executionAgent: AgentExecutionAgent = .willDeep
    @Published var currentPlan: AgentPlan?
    @Published var currentGoal: AgentGoal?
    @Published var learningEvents: [AgentLearningEvent] = []
    @Published var latestTurnRecall: AgentTurnRecallSnapshot?
    @Published var sessionModelOverride: String?
    /// True after the runtime successfully applied at least one patch.
    /// Drives the "正在编辑 / N 个文件已更改" worktree card so empty
    /// sessions never light it up.
    @Published var didEditFiles: Bool = false
    /// Workspace-relative paths the Agent has actually written to in
    /// this session (via apply_patch). Used to filter the worktree-change
    /// card so it shows only files Agent touched — never the user's own
    /// uncommitted edits or untracked junk like `__pycache__/*.pyc`.
    @Published var agentEditedPaths: Set<String> = []
    /// Live `git status` snapshot for this session's workspace. Each
    /// runtime owns its own — switching from a session in workspace A
    /// to one in workspace B shouldn't briefly show A's changes. The
    /// refresh task is driven by the same code that drives the global
    /// gitStatus, but writes into this per-runtime field.
    @Published var worktreeChanges: AgentWorktreeChangeSummary = .init()

    // MARK: - Non-published runtime plumbing

    /// The in-flight provider request for the current turn, or nil
    /// when idle. Cancelled when the session is closed or the user
    /// stops the response.
    var requestTask: Task<Void, Never>?
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

    // MARK: - Plan gate

    /// True when Plan mode is on AND no plan exists yet OR the existing
    /// plan hasn't been approved. While true, all write/exec tools and
    /// patch application are blocked.
    var isPlanGateActive: Bool {
        guard interactionMode == .plan else { return false }
        guard let plan = currentPlan else { return true }
        return plan.status != .approved && plan.status != .executing && plan.status != .done
    }

    // MARK: - Init

    init(session: AgentSession) {
        self.id = session.id
        self.session = session
        self.workspaceRootPath = session.workspaceRootPath
        self.workspaceLocation = session.workspaceLocation

        // Seed live state from persisted session.
        self.messages = session.messages
        self.contextSummary = session.contextSummary
        self.contextSummaryThroughMessageID = session.contextSummaryThroughMessageID
        self.didEditFiles = session.didEditFiles
        self.agentEditedPaths = Set(session.agentEditedPaths)
        self.interactionMode = session.interactionMode
        self.approvalMode = session.approvalMode
        self.executionAgent = session.executionAgent
        self.currentPlan = session.currentPlan
        self.currentGoal = session.currentGoal
        self.learningEvents = session.learningEvents
        self.latestTurnRecall = session.latestTurnRecall
    }

    /// Move an idle/new session to another workspace. Used by the
    /// composer workspace picker before the first user turn, so the
    /// sidebar immediately reflects the selected folder.
    func rebindWorkspace(to path: String?) {
        let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceRootPath = normalized?.isEmpty == true ? nil : normalized
        workspaceLocation = workspaceRootPath.map { .local(path: $0) }
        session.workspaceRootPath = workspaceRootPath
        session.workspaceLocation = workspaceLocation
    }

    func rebindRemoteWorkspace(runtimeID: UUID, path: String) {
        let normalized = RemotePathValidator.normalizedWorkspaceRoot(path)
        workspaceRootPath = nil
        workspaceLocation = .remote(runtimeID: runtimeID, path: normalized)
        session.workspaceRootPath = nil
        session.workspaceLocation = workspaceLocation
    }

    // MARK: - Persistence

    /// Push the runtime's persisted-shape state back onto `session`
    /// and write to disk. Call after any mutation that touches the
    /// fields `AgentSession` cares about.
    func persist() {
        session.messages = messages
        session.contextSummary = contextSummary
        session.contextSummaryThroughMessageID = contextSummaryThroughMessageID
        session.workspaceRootPath = workspaceRootPath
        session.workspaceLocation = workspaceLocation
        session.didEditFiles = didEditFiles
        session.agentEditedPaths = agentEditedPaths.sorted()
        session.interactionMode = interactionMode
        session.approvalMode = approvalMode
        session.executionAgent = executionAgent
        session.currentPlan = currentPlan
        session.currentGoal = currentGoal
        session.learningEvents = learningEvents
        session.latestTurnRecall = latestTurnRecall
        session.updatedAt = Date()
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
        AgentSessionStore.save(session)
    }

    /// True if this session has no real user messages yet.
    var isEmpty: Bool {
        !messages.contains(where: { $0.role == .user })
    }
}
