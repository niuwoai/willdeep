//
//  AgentModels.swift
//  WillDeep
//
//  Lightweight models for the built-in project agent.
//

import Foundation

/// A persisted Agent conversation. Lives as one JSON file under the app's
/// Application Support directory. `workspaceLocation` is the canonical
/// workspace binding; `workspaceRootPath` remains for local legacy sessions.
struct AgentSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// Optional — sessions started before a folder was picked have no root.
    var workspaceRootPath: String?
    /// Canonical workspace binding. Remote sessions persist here while
    /// `workspaceRootPath` remains as the local-only compatibility slot.
    var workspaceLocation: WorkspaceLocation?
    /// Model id captured at the time the session was last sent (so changing
    /// the global model later doesn't silently switch what an old chat used).
    var modelID: String?
    /// Provider snapshot captured alongside `modelID` so usage analytics
    /// can group historical sessions by the actual configured provider.
    var providerID: String?
    var providerDisplayName: String?
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
    /// Per-session interaction mode. Persisted so re-selecting a session
    /// resumes plan/goal context without the user having to redo setup.
    var interactionMode: AgentInteractionMode
    /// Per-session tool approval behavior. Defaults to smart approval
    /// for backwards compatibility with existing sessions.
    var approvalMode: AgentApprovalMode
    /// Which execution backend the composer should use for the next
    /// user turn. Defaults to WillDeep's native agent loop.
    var executionAgent: AgentExecutionAgent
    /// Per-session opt-in specialist packs. Default empty keeps broad,
    /// domain-specific tools out of ordinary chats until the user turns
    /// an expert on.
    var activeExperts: Set<AgentExpert>
    /// Plan-mode state (proposed → approved → done). Nil outside Plan
    /// mode, or when Plan mode is on but no plan has been drafted yet.
    var currentPlan: AgentPlan?
    /// Goal-mode definition (statement + acceptance checklist). Nil
    /// outside Goal mode, or when Goal mode is on but the user hasn't
    /// defined a goal yet.
    var currentGoal: AgentGoal?
    /// Recent automatic learning outcomes for this session. These are
    /// product-visible audit events for memory, skill, and MCP discovery
    /// actions captured at turn end.
    var learningEvents: [AgentLearningEvent]
    /// Structured record of which memories / attached skills were
    /// injected into the latest turn context.
    var latestTurnRecall: AgentTurnRecallSnapshot?
    /// When the user pinned this session to the top of its workspace
    /// group. Nil = not pinned. We store the timestamp (not a bool) so
    /// that multiple pinned items inside one workspace can be ordered
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
        modelID: String? = nil,
        providerID: String? = nil,
        providerDisplayName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AgentMessage] = [],
        contextSummary: String? = nil,
        contextSummaryThroughMessageID: AgentMessage.ID? = nil,
        didEditFiles: Bool = false,
        agentEditedPaths: [String] = [],
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart,
        executionAgent: AgentExecutionAgent = .willDeep,
        activeExperts: Set<AgentExpert> = [],
        currentPlan: AgentPlan? = nil,
        currentGoal: AgentGoal? = nil,
        learningEvents: [AgentLearningEvent] = [],
        latestTurnRecall: AgentTurnRecallSnapshot? = nil,
        pinnedAt: Date? = nil,
        archivedAt: Date? = nil,
        titleIsUserSet: Bool = false
    ) {
        self.id = id
        self.title = title
        self.workspaceRootPath = workspaceRootPath
        self.workspaceLocation = workspaceLocation ?? workspaceRootPath.map { .local(path: $0) }
        self.modelID = modelID
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.contextSummary = contextSummary
        self.contextSummaryThroughMessageID = contextSummaryThroughMessageID
        self.didEditFiles = didEditFiles
        self.agentEditedPaths = agentEditedPaths
        self.interactionMode = interactionMode
        self.approvalMode = approvalMode
        self.executionAgent = executionAgent
        self.activeExperts = activeExperts
        self.currentPlan = currentPlan
        self.currentGoal = currentGoal
        self.learningEvents = learningEvents
        self.latestTurnRecall = latestTurnRecall
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.titleIsUserSet = titleIsUserSet
    }

    var isPinned: Bool { pinnedAt != nil }
    var isArchived: Bool { archivedAt != nil }

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
        if let workspaceLocation {
            return workspaceLocation.displayName
        }
        guard let path = workspaceRootPath, !path.isEmpty else { return L10n.Workspace.noWorkspace }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var workspaceSidebarGroupKey: String {
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
        case id, title, workspaceRootPath, workspaceLocation, modelID
        case providerID, providerDisplayName
        case createdAt, updatedAt, messages, contextSummary, contextSummaryThroughMessageID
        case didEditFiles, agentEditedPaths, interactionMode, approvalMode, executionAgent, activeExperts, currentPlan, currentGoal, learningEvents, latestTurnRecall
        case pinnedAt, archivedAt, titleIsUserSet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.workspaceRootPath = try c.decodeIfPresent(String.self, forKey: .workspaceRootPath)
        self.workspaceLocation = try c.decodeIfPresent(WorkspaceLocation.self, forKey: .workspaceLocation)
            ?? self.workspaceRootPath.map { .local(path: $0) }
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        self.providerDisplayName = try c.decodeIfPresent(String.self, forKey: .providerDisplayName)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([AgentMessage].self, forKey: .messages)
        self.contextSummary = try c.decodeIfPresent(String.self, forKey: .contextSummary)
        self.contextSummaryThroughMessageID = try c.decodeIfPresent(AgentMessage.ID.self, forKey: .contextSummaryThroughMessageID)
        self.didEditFiles = try c.decodeIfPresent(Bool.self, forKey: .didEditFiles) ?? false
        self.agentEditedPaths = try c.decodeIfPresent([String].self, forKey: .agentEditedPaths) ?? []
        self.interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode) ?? .normal
        self.approvalMode = try c.decodeIfPresent(AgentApprovalMode.self, forKey: .approvalMode) ?? .smart
        self.executionAgent = try c.decodeIfPresent(AgentExecutionAgent.self, forKey: .executionAgent) ?? .willDeep
        self.activeExperts = try c.decodeIfPresent(Set<AgentExpert>.self, forKey: .activeExperts) ?? []
        self.currentPlan = try c.decodeIfPresent(AgentPlan.self, forKey: .currentPlan)
        self.currentGoal = try c.decodeIfPresent(AgentGoal.self, forKey: .currentGoal)
        self.learningEvents = try c.decodeIfPresent([AgentLearningEvent].self, forKey: .learningEvents) ?? []
        self.latestTurnRecall = try c.decodeIfPresent(AgentTurnRecallSnapshot.self, forKey: .latestTurnRecall)
        self.pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.titleIsUserSet = try c.decodeIfPresent(Bool.self, forKey: .titleIsUserSet) ?? false
    }
}

// MARK: - Plan & Goal modes

/// Top-level interaction mode for an Agent session. Plan locks all write
/// tools until the user approves a plan; Goal pins a long-term objective
/// + checklist to every system prompt. Normal is the default.
enum AgentInteractionMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case plan
    case goal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return L10n.InteractionMode.normal
        case .plan: return L10n.InteractionMode.plan
        case .goal: return L10n.InteractionMode.goal
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "bubble.left.and.bubble.right"
        case .plan: return "list.number"
        case .goal: return "target"
        }
    }
}

/// Per-session approval posture exposed from the Agent composer. It
/// influences only write-tier auto-approval; read tools still run
/// automatically, danger-tier tools still require typed confirmation,
/// and Plan mode keeps its own plan-approval gate.
enum AgentApprovalMode: String, Codable, CaseIterable, Identifiable {
    case requestEveryTime
    case smart
    case workspaceAccess

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
            return "Ask before every write-tier tool call. Read-only tools may run automatically. Danger-tier tools still require typed confirmation."
        case .smart:
            return "Use WillDeep's smart approval policy: read-only tools run automatically; pinned, trusted, built-in allowlisted, or AI-classified normal non-malicious calls may auto-run; uncertain writes ask the user."
        case .workspaceAccess:
            return "Allow write-tier workspace actions and shell/delegated agent work inside the current workspace to auto-run. Danger-tier tools, Plan gate, and untrusted MCP calls still require user approval."
        }
    }

    var conciseSystemPromptDescription: String {
        switch self {
        case .requestEveryTime:
            return "Reads auto-run; every write asks; danger-tier commands require typed confirmation."
        case .smart:
            return "Reads auto-run; normal non-malicious work may be AI-approved; uncertain writes ask; danger-tier commands require typed confirmation."
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
enum AgentExpert: String, Codable, CaseIterable, Identifiable, Hashable {
    case shortDrama
    case browserOps

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shortDrama: return L10n.Expert.shortDrama
        case .browserOps: return L10n.Expert.browserOps
        }
    }

    var summary: String {
        switch self {
        case .shortDrama: return L10n.Expert.shortDramaSummary
        case .browserOps: return L10n.Expert.browserOpsSummary
        }
    }

    var symbol: String {
        switch self {
        case .shortDrama: return "film.stack"
        case .browserOps: return "globe.badge.chevron.backward"
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
            Use `chrome_*` tools only when the user needs their existing Chrome tabs, cookies, or login session. Screenshots and page mutations may expose or change private web apps, so keep actions scoped, explain selectors when useful, and prefer read/status calls before clicking or typing.
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
enum AgentExecutionAgent: String, Codable, CaseIterable, Identifiable {
    case willDeep
    case claudeCode
    case codexCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .willDeep: return "WillDeep"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex"
        }
    }

    var summary: String {
        switch self {
        case .willDeep:
            return "使用当前会话自己的模型和工具循环。"
        case .claudeCode:
            return "通过本机 Claude Code CLI 执行这轮任务。"
        case .codexCLI:
            return "通过本机 Codex CLI 执行这轮任务。"
        }
    }

    var symbol: String {
        switch self {
        case .willDeep: return "sparkles"
        case .claudeCode: return "sparkles.rectangle.stack"
        case .codexCLI: return "terminal"
        }
    }

    var toolName: String? {
        switch self {
        case .willDeep: return nil
        case .claudeCode: return "claude_code"
        case .codexCLI: return "codex_cli"
        }
    }

    var defaultPermissionMode: String? {
        switch self {
        case .willDeep: return nil
        case .claudeCode: return "acceptEdits"
        case .codexCLI: return "workspaceWrite"
        }
    }
}

/// A user-approvable execution plan parsed from the agent's reply.
/// Lifecycle:
///   proposed → awaiting user click
///   approved → write tools unlocked, agent continues
///   rejected → user dismissed; agent should re-plan on next turn
///   executing/done used purely for display once approved.
struct AgentPlan: Codable, Equatable {
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
struct AgentGoal: Codable, Equatable {
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
        AgentProviderPreset.preset(id: providerID)?.supportsImageInput ?? true
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
    /// Short list of substrings that identify a model as belonging to
    /// this provider — used by `normalized()` to detect when a stale
    /// flash/pro model name from a previous provider got carried over
    /// after the user switched providers in Settings. Best-effort: an
    /// unrecognised name doesn't crash, it just sticks until the user
    /// picks one from the live model list.
    let modelHints: [String]

    static let openAIID = "openai"
    static let deepSeekID = "deepseek"
    static let customID = "custom"

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
        // Rocky's personal relay. No public default model — every
        // account has its own routing config.
        AgentProviderPreset(
            id: "some-im",
            displayName: "some.im (Rocky's relay)",
            baseURL: "https://some.im/v1",
            defaultModel: "deepseek-v4-flash",
            defaultProModel: "deepseek-v4-pro",
            supportsModelFetch: true,
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
        }
    }
}

enum AgentClientError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case serverStatus(AgentProviderHTTPError)
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

/// A file the user attached via the composer's `@` picker. We carry the
/// URL (for display + dedup) and a workspace-relative display path; the
/// actual contents get re-read at send time so the model always sees
/// the latest on-disk state, not a stale snapshot.
struct AgentFileAttachment: Identifiable, Equatable {
    let url: URL
    let relativePath: String

    var id: String { url.standardizedFileURL.path }
}
