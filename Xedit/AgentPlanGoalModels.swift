//
//  AgentPlanGoalModels.swift
//  WillDeep
//
//  Plan / Goal interaction-mode models split out of AgentModels.swift.
//

import Foundation

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
    /// 完全访问：允许访问互联网、任意本机文件与凭据，不再经过 AI 审核。
    /// 仅保留确定性恶意命令黑名单，以及必须由用户本人回答的交互边界。
    /// 顺序上紧挨 smart 而不是排在最前——最放得开的档位摆在菜单第一行，
    /// 等于请人误点；但它也不该沉到底部让人找不到。严格模式仍然压轴。
    case fullAccess = "silent"
    case workspaceAccess
    case requestEveryTime

    var id: String { rawValue }

    /// 未知取值一律退回 `.smart`，而不是让整条会话解码失败。
    /// 加档位是会发生的事，而旧版本读到新档位时，合成的 Codable 会 throw，
    /// 那个 throw 会顺着 `AgentSession` 的 decode 冒上去——用户看到的是
    /// **整个会话从列表里消失**，不是一个降级的审批档位。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentApprovalMode(rawValue: raw) ?? .smart
    }

    var displayName: String {
        switch self {
        case .requestEveryTime: return L10n.ApprovalMode.requestEveryTime
        case .fullAccess: return L10n.ApprovalMode.fullAccess
        case .smart: return L10n.ApprovalMode.smart
        case .workspaceAccess: return L10n.ApprovalMode.workspaceAccess
        }
    }

    var summary: String {
        switch self {
        case .requestEveryTime: return L10n.ApprovalMode.requestEveryTimeSummary
        case .fullAccess: return L10n.ApprovalMode.fullAccessSummary
        case .smart: return L10n.ApprovalMode.smartSummary
        case .workspaceAccess: return L10n.ApprovalMode.workspaceAccessSummary
        }
    }

    var systemPromptDescription: String {
        switch self {
        case .requestEveryTime:
            return "Strict mode: ask before security-relevant writes or external actions. Read-only tools and bounded harmless metadata changes such as the current session title may run automatically. Danger-tier tools still require typed confirmation."
        case .fullAccess:
            return "Full Access: the user explicitly allows internet access and access to any file or credential on this Mac without approval prompts. Run tool calls automatically unless they hit WillDeep's deterministic malicious-command denylist or require the user's own answer. This is broad authority, not a licence to be reckless: prefer reversible steps, keep backups before destructive operations, and say what you are about to do."
        case .smart:
            return "Use WillDeep's smart review policy: read-only tools and workspace-scoped writes run automatically; safe external actions may be AI-approved; uncertain or risky external actions ask the user."
        case .workspaceAccess:
            return "Allow write-tier actions and delegated agent work inside the current workspace to auto-run. External/network actions, danger-tier tools, the Plan gate, and untrusted MCP calls still require user approval."
        }
    }

    var conciseSystemPromptDescription: String {
        switch self {
        case .requestEveryTime:
            return "Strict: reads and bounded harmless title metadata auto-run; security-relevant writes or external actions ask; danger-tier commands require typed confirmation."
        case .fullAccess:
            return "Full Access: internet, any local file, and credentials auto-run without approval prompts; only deterministic malicious-command rules and user-answer boundaries stop execution."
        case .smart:
            return "Reads and workspace-scoped writes auto-run; safe external actions may pass intelligent review; uncertain external actions ask; danger-tier commands require typed confirmation."
        case .workspaceAccess:
            return "Reads and workspace-scoped writes auto-run; untrusted external actions ask; danger-tier commands require typed confirmation."
        }
    }

    var symbol: String {
        switch self {
        case .requestEveryTime: return "hand.raised"
        case .fullAccess: return "exclamationmark.shield"
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
    case hermesCLI
    case cursorAgent
    case clineCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .willDeep: return L10n.ExecutionAgent.willDeepName
        case .claudeCode: return L10n.ExecutionAgent.claudeCodeName
        case .codexCLI: return L10n.ExecutionAgent.codexName
        case .hermesCLI: return L10n.ExecutionAgent.hermesName
        case .cursorAgent: return L10n.ExecutionAgent.cursorName
        case .clineCLI: return L10n.ExecutionAgent.clineName
        }
    }

    var summary: String {
        switch self {
        case .willDeep: return L10n.ExecutionAgent.willDeepSummary
        case .claudeCode: return L10n.ExecutionAgent.claudeCodeSummary
        case .codexCLI: return L10n.ExecutionAgent.codexSummary
        case .hermesCLI: return L10n.ExecutionAgent.hermesSummary
        case .cursorAgent: return L10n.ExecutionAgent.cursorSummary
        case .clineCLI: return L10n.ExecutionAgent.clineSummary
        }
    }

    var symbol: String {
        switch self {
        case .willDeep: return "hammer.fill"
        case .claudeCode: return "sparkles.rectangle.stack"
        case .codexCLI: return "terminal"
        case .hermesCLI: return "h.circle"
        case .cursorAgent: return "cursorarrow.click"
        case .clineCLI: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var toolName: String? {
        switch self {
        case .willDeep: return nil
        case .claudeCode: return "claude_code"
        case .codexCLI: return "codex_cli"
        case .hermesCLI: return "hermes_cli"
        case .cursorAgent: return "cursor_agent"
        case .clineCLI: return "cline_cli"
        }
    }

    var defaultPermissionMode: String? {
        switch self {
        case .willDeep: return nil
        case .claudeCode: return "acceptEdits"
        case .codexCLI: return "workspaceWrite"
        case .hermesCLI: return "workspaceWrite"
        case .cursorAgent: return "default"
        case .clineCLI: return "act"
        }
    }

    var supportsStructuredExecution: Bool {
        switch self {
        case .claudeCode, .codexCLI:
            return true
        case .willDeep, .hermesCLI, .cursorAgent, .clineCLI:
            return false
        }
    }

    init?(delegatedToolName: String) {
        switch delegatedToolName {
        case "claude_code":
            self = .claudeCode
        case "codex_cli":
            self = .codexCLI
        case "hermes_cli":
            self = .hermesCLI
        case "cursor_agent":
            self = .cursorAgent
        case "cline_cli":
            self = .clineCLI
        default:
            return nil
        }
    }
}

/// Coarse roadmap for a long-running Goal. The roadmap is deliberately much
/// smaller than the work itself: each phase receives a fresh bounded Plan when
/// it becomes active, allowing one Goal to advance across multiple turns
/// without presenting a 19-step wall on day one.
nonisolated struct AgentGoalRoadmap: Codable, Equatable {
    static let maximumPhaseCount = 6
    static let maximumStepsPerPhase = 6
    static let maximumAcceptanceCriteriaPerPhase = 6
    static let maximumPhaseTitleCharacters = 160
    static let maximumAcceptanceCriterionCharacters = 300

    enum PhaseStatus: String, Codable, Equatable {
        case pending
        case planning
        case executing
        case completed
        case blocked

        init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = PhaseStatus(rawValue: raw) ?? .blocked
        }
    }

    struct Phase: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var acceptanceCriteria: [String]
        var status: PhaseStatus
        var completedAt: Date?

        init(
            id: String,
            title: String,
            acceptanceCriteria: [String],
            status: PhaseStatus = .pending,
            completedAt: Date? = nil
        ) {
            self.id = id
            self.title = title
            self.acceptanceCriteria = acceptanceCriteria
            self.status = status
            self.completedAt = completedAt
        }
    }

    var phases: [Phase]
    var activePhaseIndex: Int

    init(phases: [Phase], activePhaseIndex: Int = 0) {
        self.phases = phases
        self.activePhaseIndex = activePhaseIndex
    }

    var activePhase: Phase? {
        guard phases.indices.contains(activePhaseIndex) else { return nil }
        return phases[activePhaseIndex]
    }

    var isComplete: Bool {
        !phases.isEmpty && phases.allSatisfy { $0.status == .completed }
    }

    var phasePositionText: String {
        guard !phases.isEmpty else { return "0/0" }
        return "\(min(activePhaseIndex + 1, phases.count))/\(phases.count)"
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
        currentGoal: AgentGoal? = nil,
        goalRoadmap: AgentGoalRoadmap? = nil
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
            let canResumePhasePlanning = currentPlan == nil
                && goalRoadmap?.activePhase?.status == .planning
            if currentPlan?.status != .approved
                && currentPlan?.status != .executing
                && !canResumeInterruptedFinalization
                && !canResumePhasePlanning {
                copy.phase = .blocked
            }
        case .completed:
            if currentPlan?.status != .done && goalRoadmap?.isComplete != true {
                copy.phase = .blocked
            }
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
    /// Set when the user pressed Stop while this plan was the active
    /// execution contract. An interrupted plan stays visible with its step
    /// statuses, but it stops being the contract: follow-up messages may
    /// start a different task (and capture a replacement plan), and the
    /// automatic continuation loop leaves it alone. Cleared when the model
    /// resumes it by reporting progress, or when a restart is requested
    /// from the plan card. Older persisted plans decode as nil (= active).
    var interruptedAt: Date? = nil

    var isInterrupted: Bool { interruptedAt != nil }

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
    /// AI-authored execution graph. Acceptance criteria remain in
    /// `checklist`; they are not execution steps and must never be projected
    /// into an artificial linear chain.
    var dispatchPlan: AgentGoalDispatchPlan? = nil
    /// Stable profile IDs selected before planning starts. The primary
    /// planner can be a WillDeep model or an external coding-agent CLI.
    var planningProfileID: String? = nil
    var planningFallbackProfileIDs: [String]? = nil
    var planningAttemptedProfileIDs: [String]? = nil
    /// Project Worker pool selected before dispatch planning begins.
    var selectedWorkerProfileIDs: [String]? = nil
    /// Budget and spend for the current execution segment. Persisted so a
    /// relaunch cannot hand a long-running Goal a fresh full budget.
    var continuationBudget: AgentGoalContinuationBudget? = nil

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

    init(
        statement: String = "",
        checklist: [Item] = [],
        dispatchPlan: AgentGoalDispatchPlan? = nil,
        planningProfileID: String? = nil,
        planningFallbackProfileIDs: [String]? = nil,
        planningAttemptedProfileIDs: [String]? = nil,
        selectedWorkerProfileIDs: [String]? = nil,
        continuationBudget: AgentGoalContinuationBudget? = nil
    ) {
        self.statement = statement
        self.checklist = checklist
        self.dispatchPlan = dispatchPlan
        self.planningProfileID = planningProfileID
        self.planningFallbackProfileIDs = planningFallbackProfileIDs
        self.planningAttemptedProfileIDs = planningAttemptedProfileIDs
        self.selectedWorkerProfileIDs = selectedWorkerProfileIDs
        self.continuationBudget = continuationBudget
    }

    var isEmpty: Bool { statement.isEmpty && checklist.isEmpty }
}
