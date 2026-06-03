//
//  AgentRuntime.swift
//  VeilWriter
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
    let workspaceRootPath: String?

    // MARK: - Conversation state

    @Published var messages: [AgentMessage] = []
    @Published var patchProposals: [AgentPatchProposal] = []
    @Published var toolCalls: [AgentToolCall] = []

    // MARK: - Composer state (per-session draft — switching tabs preserves)

    @Published var input: String = ""
    @Published var pendingImages: [AgentImageAttachment] = []
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
    @Published var currentPlan: AgentPlan?
    @Published var currentGoal: AgentGoal?
    @Published var sessionModelOverride: String?
    /// True after the runtime successfully applied at least one patch.
    /// Drives the "正在编辑 / N 个文件已更改" worktree card so empty
    /// sessions never light it up.
    @Published var didEditFiles: Bool = false
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

        // Seed live state from persisted session.
        self.messages = session.messages
        self.didEditFiles = session.didEditFiles
        self.interactionMode = session.interactionMode
        self.currentPlan = session.currentPlan
        self.currentGoal = session.currentGoal
    }

    // MARK: - Persistence

    /// Push the runtime's persisted-shape state back onto `session`
    /// and write to disk. Call after any mutation that touches the
    /// fields `AgentSession` cares about.
    func persist() {
        session.messages = messages
        session.didEditFiles = didEditFiles
        session.interactionMode = interactionMode
        session.currentPlan = currentPlan
        session.currentGoal = currentGoal
        session.updatedAt = Date()
        let derived = AgentSessionStore.deriveTitle(from: messages)
        if !derived.isEmpty {
            session.title = derived
        }
        AgentSessionStore.save(session)
    }

    /// True if this session has no real user messages yet.
    var isEmpty: Bool {
        !messages.contains(where: { $0.role == .user })
    }
}
