//
//  AppStateAgentRuntimeAccessors.swift
//  WillDeep
//
//  Compatibility accessors that delegate legacy AppState agent fields
//  to the active per-session AgentRuntime.
//

import Foundation

extension AppState {
    // MARK: - Per-session state (rc2: delegated to activeRuntime)
    //
    // These fields used to be `@Published` stored properties on AppState.
    // rc2 moved the data onto `AgentRuntime` (one runtime per session) and
    // kept the AppState-side names as get/set delegates so existing UI and
    // AppState companion files can continue reading `appState.agentMessages`
    // and friends without knowing where the storage lives.

    var activeRuntime: AgentRuntime? {
        guard let id = activeAgentSessionID else { return nil }
        return agentRuntimes[id]
    }

    var agentMessages: [AgentMessage] {
        get { activeRuntime?.messages ?? [] }
        set { activeRuntime?.messages = newValue }
    }

    var agentPatchProposals: [AgentPatchProposal] {
        get { activeRuntime?.patchProposals ?? [] }
        set { activeRuntime?.patchProposals = newValue }
    }

    var agentToolCalls: [AgentToolCall] {
        get { activeRuntime?.toolCalls ?? [] }
        set { activeRuntime?.toolCalls = newValue }
    }

    var agentInput: String {
        get { activeRuntime?.input ?? "" }
        set { activeRuntime?.input = newValue }
    }

    var isAgentResponding: Bool {
        get { activeRuntime?.isResponding ?? false }
        set { activeRuntime?.isResponding = newValue }
    }

    /// Wall-clock moment the current turn started; the thinking banner
    /// reads this through a `TimelineView` so elapsed seconds tick while
    /// the model is still working.
    var agentTurnStartedAt: Date? {
        get { activeRuntime?.turnStartedAt }
        set { activeRuntime?.turnStartedAt = newValue }
    }

    var agentErrorMessage: String? {
        get { activeRuntime?.errorMessage }
        set { activeRuntime?.errorMessage = newValue }
    }

    var agentErrorDetails: AgentErrorDetails? {
        get { activeRuntime?.errorDetails }
        set { activeRuntime?.errorDetails = newValue }
    }

    /// Images staged in the composer for the next user message.
    var agentPendingImages: [AgentImageAttachment] {
        get { activeRuntime?.pendingImages ?? [] }
        set { activeRuntime?.pendingImages = newValue }
    }

    /// Long pasted text staged in the composer for the next user message.
    var agentPendingTextAttachments: [AgentTextAttachment] {
        get { activeRuntime?.pendingTextAttachments ?? [] }
        set { activeRuntime?.pendingTextAttachments = newValue }
    }

    /// Skills the user attached via `@skill` for the next send.
    var agentPendingSkills: [AgentSkillEntry] {
        get { activeRuntime?.pendingSkills ?? [] }
        set { activeRuntime?.pendingSkills = newValue }
    }

    /// Files the user attached via the `@` picker for the next send.
    var agentPendingFiles: [AgentFileAttachment] {
        get { activeRuntime?.pendingFiles ?? [] }
        set { activeRuntime?.pendingFiles = newValue }
    }

    /// Whether the next send should include a workspace overview block.
    var agentPendingIncludeWorkspaceOverview: Bool {
        get { activeRuntime?.pendingIncludeWorkspaceOverview ?? false }
        set { activeRuntime?.pendingIncludeWorkspaceOverview = newValue }
    }

    /// Top-level interaction mode for the active session.
    var agentInteractionMode: AgentInteractionMode {
        get { activeRuntime?.interactionMode ?? .normal }
        set { activeRuntime?.interactionMode = newValue }
    }

    /// Per-session approval behavior shown in the composer.
    var agentApprovalMode: AgentApprovalMode {
        get { activeRuntime?.approvalMode ?? .smart }
        set { activeRuntime?.approvalMode = newValue }
    }

    /// Current proposed/approved plan for Plan mode.
    var agentCurrentPlan: AgentPlan? {
        get { activeRuntime?.currentPlan }
        set { activeRuntime?.currentPlan = newValue }
    }

    /// Currently-pinned goal for Goal mode.
    var agentCurrentGoal: AgentGoal? {
        get { activeRuntime?.currentGoal }
        set { activeRuntime?.currentGoal = newValue }
    }

    /// Recent automatic learning outcomes captured for the active session.
    var agentLearningEvents: [AgentLearningEvent] {
        get { activeRuntime?.learningEvents ?? [] }
        set { activeRuntime?.learningEvents = newValue }
    }

    /// True when Plan mode is on and no approved plan exists. While true,
    /// all write/exec tools and patch application are blocked.
    var isPlanGateActive: Bool {
        activeRuntime?.isPlanGateActive ?? false
    }

    /// Messages the user queued while the agent was busy.
    var agentQueuedMessages: [AgentQueuedMessage] {
        get { activeRuntime?.queuedMessages ?? [] }
        set { activeRuntime?.queuedMessages = newValue }
    }

    /// Per-session concrete model override.
    var agentSessionModelOverride: String? {
        get { activeRuntime?.sessionModelOverride }
        set { activeRuntime?.sessionModelOverride = newValue }
    }

    /// Live `git status` snapshot for the active session's workspace.
    var agentWorktreeChanges: AgentWorktreeChangeSummary {
        get { activeRuntime?.worktreeChanges ?? .init() }
        set { activeRuntime?.worktreeChanges = newValue }
    }

    /// Mirrors `AgentRuntime.didEditFiles` for the active session. Used to
    /// gate the worktree-change card so a fresh New Chat never shows it.
    var agentSessionDidEditFiles: Bool {
        get { activeRuntime?.didEditFiles ?? false }
        set { activeRuntime?.didEditFiles = newValue }
    }

    /// Workspace-relative paths the Agent has actually written to in the
    /// active session, used to filter out the user's own diffs.
    var agentEditedRelativePaths: Set<String> {
        get { activeRuntime?.agentEditedPaths ?? [] }
        set { activeRuntime?.agentEditedPaths = newValue }
    }

    /// Continuation resumed when the user resolves the currently-blocked
    /// tool call. Each runtime owns its own waiter so concurrent sessions
    /// do not fight over one slot.
    var agentToolDecisionWaiter: CheckedContinuation<AgentToolDecision, Never>? {
        get { activeRuntime?.toolDecisionWaiter }
        set { activeRuntime?.toolDecisionWaiter = newValue }
    }

    /// Provider request task for the active turn. Each runtime holds its
    /// own task so background sessions can continue independently.
    var agentRequestTask: Task<Void, Never>? {
        get { activeRuntime?.requestTask }
        set { activeRuntime?.requestTask = newValue }
    }
}
