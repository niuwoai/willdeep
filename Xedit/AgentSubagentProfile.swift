//
//  AgentSubagentProfile.swift
//  WillDeep
//
//  Subagent "trades": a bundle of model + provider + tool whitelist +
//  capability prompt + budgets that `spawn_agent` selects by name.
//
//  Why trades instead of a free-form `model` parameter (see
//  docs/SUBAGENT_PROFILES_DESIGN.md):
//
//   - The per-round fixed cost is the tool schema, not the prompt. A child
//     loop resends its whole tool table every round, so narrowing 9 tools
//     to 4 saves more over a 12-round run than any prompt trimming could.
//   - Small models call tools more accurately when given fewer of them, so
//     narrowing buys accuracy as well as cost.
//   - Cost policy belongs to the user's configuration, not to whether the
//     model remembers to pick a cheap model this time.
//
//  Most profiles may only NARROW the global read-only whitelist. Built-in
//  writing trades and the utility generalist are explicit exceptions:
//  writes use an exact file-set lock, while terminal, Chrome and MCP actions
//  remain constrained by the parent conversation's approval policy.
//

import Foundation

nonisolated struct AgentSubagentProfile: Codable, Equatable, Identifiable, Sendable {
    /// How a finished trade recovers when its cheap model could not do the job.
    enum EscalationPolicy: String, Codable, Equatable, Sendable {
        /// Report the failure to the parent as-is.
        case none
        /// Legacy serialized name. Re-run once on the next configured tier,
        /// preserving the role's exact tools and budgets. Explicit independent
        /// model bindings do not guess a stronger model from the parent.
        case retryWithParentModel
    }

    /// Which model/provider a trade runs on. All-nil remains the explicit
    /// "inherit the parent session" representation for migrated/custom
    /// bindings, while built-in trades prefer the automatic provider route.
    struct ModelBinding: Codable, Equatable, Sendable {
        /// Exact saved provider entry. Provider preset IDs are not unique —
        /// users can keep several OpenAI-compatible endpoints — so new
        /// settings bind to the library entry UUID. Optional to keep stored
        /// v1 bindings source-compatible.
        var preferredProviderEntryID: UUID? = nil
        /// Preferred provider preset (e.g. `some-im`). Resolution picks a
        /// usable library entry for it at spawn time. This remains as a
        /// migration fallback for bindings saved before entry UUIDs existed.
        var preferredProviderID: String?
        var model: String?
        /// Context window of `model`, used for payload budgeting and for
        /// recognizing a context-overflow failure. nil → parent's window.
        var contextWindowTokens: Int?
        /// A shared model slot; nil preserves legacy explicit model bindings.
        var workerTier: AgentWorkerTier? = nil

        static let inheritsParent = ModelBinding()

        var inheritsEverything: Bool {
            preferredProviderEntryID == nil && preferredProviderID == nil && model == nil && workerTier == nil
        }
    }

    let id: String
    /// One-line trade description embedded in the `spawn_agent` schema. The
    /// model reads this to choose, so it stays English and concrete.
    var purpose: String
    var modelBinding: ModelBinding
    /// Requested tools. Always intersected with the global whitelist before
    /// use — see `effectiveToolNames(writeAccessGranted:)`.
    var toolNames: Set<String>
    /// The trade-specific half of the system prompt. The invariant half
    /// (read-only boundary, "your final message is the deliverable", "you
    /// cannot ask the user") is owned by the runner and cannot be overridden
    /// here: those lines exist because models violated them.
    var capabilityPromptSection: String
    var maxRounds: Int
    /// Per-tool-result cap fed to the child loop. Narrow-context trades keep
    /// this well under the parent's so a single large read cannot blow the
    /// window.
    var toolPayloadCharacterLimit: Int
    var escalation: EscalationPolicy
    /// True for dedicated writing trades. The built-in generalist may also
    /// accept an optional bounded write set; unlike a dedicated writer it
    /// remains usable without one for catch-all investigation work.
    var requiresWriteAccess: Bool
    /// Skills preloaded into this trade's system prompt at spawn time. Empty
    /// for every built-in trade; filled in from the profile's soul.
    var skillIdentifiers: [String]
    /// Legacy Codable metadata only. Old saved profiles may contain this key;
    /// it never selects a model or suppresses local instructions. Built-ins
    /// leave it nil. Known old model bindings are normalized at request time.
    var hostedVirtualModel: String?

    init(
        id: String,
        purpose: String,
        modelBinding: ModelBinding = .inheritsParent,
        toolNames: Set<String>,
        capabilityPromptSection: String,
        maxRounds: Int,
        toolPayloadCharacterLimit: Int,
        escalation: EscalationPolicy = .none,
        requiresWriteAccess: Bool = false,
        skillIdentifiers: [String] = [],
        hostedVirtualModel: String? = nil
    ) {
        self.id = id
        self.purpose = purpose
        self.modelBinding = modelBinding
        self.toolNames = toolNames
        self.capabilityPromptSection = capabilityPromptSection
        self.maxRounds = maxRounds
        self.toolPayloadCharacterLimit = toolPayloadCharacterLimit
        self.escalation = escalation
        self.requiresWriteAccess = requiresWriteAccess
        self.skillIdentifiers = skillIdentifiers
        self.hostedVirtualModel = hostedVirtualModel
    }

    /// The tools this trade may actually call.
    ///
    /// Narrow trades intersect the global read-only set. The built-in
    /// generalist additionally receives an audited host-capability set;
    /// `writeAccessGranted` opens file tools only after the workspace policy
    /// and exact file lock are satisfied.
    func effectiveToolNames(
        writeAccessGranted: Bool = false,
        approvedCommandGranted: Bool = false
    ) -> Set<String> {
        var allowed = AgentSubagentRunner.allowedToolNames
        var requested = toolNames
        if requested.contains("read_file") {
            requested.insert(AgentBundledRules.readerToolName)
        }
        if id == AgentSubagentProfileCatalog.generalistID {
            allowed.formUnion(AgentSubagentProfileCatalog.generalistExtraToolNames)
        }
        if supportsBoundedWrites, writeAccessGranted {
            allowed.formUnion(AgentSubagentProfileCatalog.writeToolNames)
        }
        // 终端工具照 editor 写工具的先例走**按工种放行**，不进全局白名单：
        // 进了全局名单，deep/tester 会静默获得读用户终端屏幕的能力。
        // send_command 虽在此放行，执行层仍有第二道闸：静态只读直接走；
        // Smart/Goal 只把非敏感、非确定性危险命令交父安全裁判；其余必须
        // 通过 ops_runner 的精确 target_command 人工授权。工具可见性不能
        // 绑在 target_command 上，否则 ops_runner 连批准前的只读基线都查不了。
        if AgentSubagentProfileCatalog.terminalToolTradeIDs.contains(id) {
            allowed.formUnion(AgentSubagentProfileCatalog.terminalOperatorToolNames)
        }
        return requested.intersection(allowed)
    }

    /// Dedicated writers require a declared file set. The generalist accepts
    /// one when the router cannot identify a narrower writing trade, but does
    /// not require one for ordinary catch-all work.
    var supportsBoundedWrites: Bool {
        requiresWriteAccess || id == AgentSubagentProfileCatalog.generalistID
    }

    var localizedDisplayName: String {
        if let role = AgentWorkerRole.matching(id) { return role.title }
        switch id {
        case AgentSubagentProfileCatalog.scoutID: return L10n.AgentDelegation.profileScoutName
        case AgentSubagentProfileCatalog.readerID: return L10n.AgentDelegation.profileReaderName
        case AgentSubagentProfileCatalog.editorID: return L10n.AgentDelegation.profileEditorName
        case AgentSubagentProfileCatalog.smallImplementerID: return L10n.AgentDelegation.profileSmallImplementerName
        case AgentSubagentProfileCatalog.implementerID: return L10n.AgentDelegation.profileImplementerName
        case AgentSubagentProfileCatalog.testerID: return L10n.AgentDelegation.profileTesterName
        case AgentSubagentProfileCatalog.reviewerID: return L10n.AgentDelegation.profileReviewerName
        case AgentSubagentProfileCatalog.smallReviewerID: return L10n.AgentDelegation.profileSmallReviewerName
        case AgentSubagentProfileCatalog.testFixerID: return L10n.AgentDelegation.profileTestFixerName
        case AgentSubagentProfileCatalog.buildFixerID: return L10n.AgentDelegation.profileBuildFixerName
        case AgentSubagentProfileCatalog.logInspectorID: return L10n.AgentDelegation.profileLogInspectorName
        case AgentSubagentProfileCatalog.gitDetectiveID: return L10n.AgentDelegation.profileGitDetectiveName
        case AgentSubagentProfileCatalog.securityGuardID: return L10n.AgentDelegation.profileSecurityGuardName
        case AgentSubagentProfileCatalog.judgeID: return L10n.AgentDelegation.profileJudgeName
        case AgentSubagentProfileCatalog.opsRunnerID: return L10n.AgentDelegation.profileOpsRunnerName
        case AgentSubagentProfileCatalog.terminalOperatorID: return L10n.AgentDelegation.profileTerminalOperatorName
        case AgentSubagentProfileCatalog.generalistID: return L10n.AgentDelegation.profileGeneralistName
        default: return L10n.AgentDelegation.profileDeepName
        }
    }

    /// User-facing description for the settings pane. `purpose` itself is
    /// model-facing (it ships verbatim in the `spawn_agent` tool
    /// description) and must stay English; this is its translation.
    var localizedPurpose: String {
        switch id {
        case AgentSubagentProfileCatalog.scoutID: return L10n.AgentDelegation.profileScoutPurpose
        case AgentSubagentProfileCatalog.readerID: return L10n.AgentDelegation.profileReaderPurpose
        case AgentSubagentProfileCatalog.editorID: return L10n.AgentDelegation.profileEditorPurpose
        case AgentSubagentProfileCatalog.smallImplementerID: return L10n.AgentDelegation.profileSmallImplementerPurpose
        case AgentSubagentProfileCatalog.implementerID: return L10n.AgentDelegation.profileImplementerPurpose
        case AgentSubagentProfileCatalog.testerID: return L10n.AgentDelegation.profileTesterPurpose
        case AgentSubagentProfileCatalog.reviewerID: return L10n.AgentDelegation.profileReviewerPurpose
        case AgentSubagentProfileCatalog.smallReviewerID: return L10n.AgentDelegation.profileSmallReviewerPurpose
        case AgentSubagentProfileCatalog.testFixerID: return L10n.AgentDelegation.profileTestFixerPurpose
        case AgentSubagentProfileCatalog.buildFixerID: return L10n.AgentDelegation.profileBuildFixerPurpose
        case AgentSubagentProfileCatalog.logInspectorID: return L10n.AgentDelegation.profileLogInspectorPurpose
        case AgentSubagentProfileCatalog.gitDetectiveID: return L10n.AgentDelegation.profileGitDetectivePurpose
        case AgentSubagentProfileCatalog.securityGuardID: return L10n.AgentDelegation.profileSecurityGuardPurpose
        case AgentSubagentProfileCatalog.judgeID: return L10n.AgentDelegation.profileJudgePurpose
        case AgentSubagentProfileCatalog.opsRunnerID: return L10n.AgentDelegation.profileOpsRunnerPurpose
        case AgentSubagentProfileCatalog.terminalOperatorID: return L10n.AgentDelegation.profileTerminalOperatorPurpose
        case AgentSubagentProfileCatalog.generalistID: return L10n.AgentDelegation.profileGeneralistPurpose
        default: return L10n.AgentDelegation.profileDeepPurpose
        }
    }
}

// MARK: - Catalog

nonisolated enum AgentSubagentProfileCatalog {
    static let scoutID = "scout"
    static let readerID = "reader"
    static let deepID = "deep"
    static let editorID = "editor"
    static let smallImplementerID = "small_implementer"
    static let implementerID = "implementer"
    static let testerID = "tester"
    static let reviewerID = "reviewer"
    static let smallReviewerID = "small_reviewer"
    static let testFixerID = "test_fixer"
    static let buildFixerID = "build_fixer"
    static let logInspectorID = "log_inspector"
    static let gitDetectiveID = "git_detective"
    static let securityGuardID = "security_guard"
    static let judgeID = "judge"
    static let opsRunnerID = "ops_runner"
    static let terminalOperatorID = "terminal_operator"
    static let generalistID = "generalist"

    static let workerPayloadCharacterLimit = 4_000
    static let balancedPayloadCharacterLimit = 5_000
    static let widePayloadCharacterLimit = 6_000
    static let implementerPayloadCharacterLimit = 16_000
    /// The generalist reads whole files the way `deep` does, but on a 64K
    /// window rather than 1M — so its per-result cap sits between the narrow
    /// trades and `tester`, not at `deep`'s 24K.
    static let generalistPayloadCharacterLimit = 8_000

    /// Compatibility constants. Active requests use the shared tier's
    /// configured budget, capped by the model's supported context window.
    static let workerContextWindowTokens = AgentWorkerTierModels.standardWindow
    static let balancedContextWindowTokens = AgentWorkerTierModels.standardWindow
    static let wideContextWindowTokens = AgentWorkerTierModels.standardWindow
    static let implementerContextWindowTokens = 262_144
    /// The L tier. Deliberately spelled out rather than left implicit: a
    /// budget nobody can see is a budget nobody defends. `AgentDeepAdmission`
    /// is what decides whether a spawn may spend it.
    static let deepContextWindowTokens = AgentWorkerTierModels.extendedWindow

    /// Tools a built-in writing trade adds on top of the read-only set, and
    /// only while its exact file-set workspace grant is held.
    static let writeToolNames: Set<String> = ["apply_patch", "create_file"]

    /// Tools the terminal-operator trade adds on top of the read-only set.
    /// snapshot / list_tabs / select_tab 本来就是 .read 档；send_command
    /// 是 .write，但执行层限定其命令文本必须分类为只读才放行。刻意不含
    /// send_control——打断用户前台任务的爆炸半径不给子代理。
    static let terminalOperatorToolNames: Set<String> = [
        "terminal_list_tabs", "terminal_select_tab",
        "terminal_snapshot", "terminal_send_command",
    ]

    /// Broad host capabilities carried only by the catch-all generalist.
    /// `call_mcp_tool` is the gateway to every tool exposed by every
    /// configured MCP server; individual calls still use the parent's trust
    /// and approval policy. Chrome tools operate the user's existing profile,
    /// preserving its logged-in session without exposing cookies directly.
    static let generalistExtraToolNames: Set<String> = [
        "chrome_status", "chrome_read_page", "chrome_read_selection",
        "chrome_snapshot", "chrome_list_tabs", "chrome_activate_tab",
        "chrome_navigate", "chrome_history", "chrome_click", "chrome_type",
        "chrome_hover", "chrome_select_option", "chrome_press_key",
        "chrome_scroll", "chrome_wait_for", "chrome_capture_tab",
        "chrome_debugger_command",
        "list_mcp_servers", "list_mcp_tools", "call_mcp_tool",
    ]

    /// Only these trades may see or drive the user's visible terminal.
    /// Exact-command approval narrows what `ops_runner` may send; it must not
    /// decide whether the terminal exists in that Worker's tool table.
    static let terminalToolTradeIDs: Set<String> = [
        opsRunnerID, terminalOperatorID, generalistID,
    ]

    /// Trades whose shell is read-only and stays read-only: their
    /// `run_command` passes the static read classifier or it is denied, full
    /// stop. No intelligent-review escalation, no approved-command channel.
    ///
    /// The distinction matters because the runner's command gate is otherwise
    /// profile-agnostic: any trade holding `run_command` can have a *modifying*
    /// command waved through by the parent's safety judge. That is a reasonable
    /// bargain for `deep` and `ops_runner`, which exist to act. It is not one
    /// for the reading trades, which were handed a shell so they could stop
    /// laundering `ls` and `head` through `ops_runner` — widening them into
    /// quiet writers would trade one mis-routing problem for a worse one.
    static let strictReadOnlyShellTradeIDs: Set<String> = [
        scoutID, readerID,
    ]

    // The model tier is independent of the role and its tool authority.
    private static let cheapBinding = AgentSubagentProfile.ModelBinding(workerTier: .standard)
    private static let balancedBinding = cheapBinding
    private static let wideBinding = cheapBinding
    private static let smallCodingBinding = cheapBinding
    private static let generalistBinding = cheapBinding
    private static let implementerBinding = AgentSubagentProfile.ModelBinding(workerTier: .advanced)
    private static let automaticProviderBinding = AgentSubagentProfile.ModelBinding(workerTier: .advanced)
    private static let deepBinding = AgentSubagentProfile.ModelBinding(workerTier: .expert)

    static let scout = AgentSubagentProfile(
        id: scoutID,
        purpose: "Locate things: find files, symbols, call sites, or answer \"where is X / does X exist\". Fastest and cheapest; read-only shell for listing and inspection only.",
        modelBinding: cheapBinding,
        toolNames: ["grep_files", "search_files", "list_directory", "read_file", "run_command"],
        capabilityPromptSection: AgentSubagentJobPrompts.scout,
        maxRounds: 8,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    static let reader = AgentSubagentProfile(
        id: readerID,
        purpose: "Read and summarize: digest long files, docs, or public web pages and answer questions about their content. Read-only shell for locating and listing the material.",
        modelBinding: balancedBinding,
        toolNames: ["read_file", "list_directory", "web_search", "web_fetch", "run_command"],
        capabilityPromptSection: AgentSubagentJobPrompts.reader,
        maxRounds: 8,
        toolPayloadCharacterLimit: balancedPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    /// The full read-only investigation trade. Any spawn that does not name a
    /// profile lands here, so old prompts and replayed sessions keep the same
    /// tool and round budgets while adopting the configurable provider/model
    /// routing shared by every subagent trade.
    static let deep = AgentSubagentProfile(
        id: deepID,
        purpose: "Legacy complex investigation: reasoning across files and git state. Uses the configured expert tier and retains its legacy admission requirement.",
        modelBinding: deepBinding,
        toolNames: AgentSubagentRunner.allowedToolNames,
        capabilityPromptSection: AgentSubagentJobPrompts.deep,
        maxRounds: AgentSubagentRunner.maxRounds,
        toolPayloadCharacterLimit: 24_000,
        escalation: .none
    )

    static let editor = AgentSubagentProfile(
        id: editorID,
        purpose: "Edit ONE declared file inside the parent workspace policy; cannot touch any other path.",
        modelBinding: balancedBinding,
        toolNames: ["read_file", "apply_patch"],
        capabilityPromptSection: AgentSubagentJobPrompts.editor,
        maxRounds: 6,
        toolPayloadCharacterLimit: balancedPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        requiresWriteAccess: true
    )

    static let implementer = AgentSubagentProfile(
        id: implementerID,
        purpose: "Implement a bounded multi-file feature or refactor across at most 16 declared existing or new paths on a deployable 256K model.",
        modelBinding: implementerBinding,
        toolNames: [
            "search_files", "grep_files", "list_directory", "read_file",
            "create_file", "apply_patch", "run_command",
        ],
        capabilityPromptSection: AgentSubagentJobPrompts.implementer,
        maxRounds: 18,
        toolPayloadCharacterLimit: implementerPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        requiresWriteAccess: true
    )

    static let smallImplementer = AgentSubagentProfile(
        id: smallImplementerID,
        purpose: "Implement a low-risk task across at most three declared paths on the configured standard tier; a verifier and independent reviewer gate delivery.",
        modelBinding: smallCodingBinding,
        toolNames: [
            "search_files", "grep_files", "list_directory", "read_file",
            "create_file", "apply_patch", "run_command",
        ],
        capabilityPromptSection: AgentSubagentJobPrompts.smallImplementer,
        maxRounds: 10,
        toolPayloadCharacterLimit: widePayloadCharacterLimit,
        escalation: .none,
        requiresWriteAccess: true
    )

    /// Runs the gates and reports evidence. Deliberately has the read-only
    /// shell (tests, linters and reports are read-tier commands) but no write
    /// tool: whoever verifies may not also implement — a tester that can patch
    /// the code it just failed is not a tester
    /// (docs/GOAL_TEAMS_ROLES_DESIGN.md §2.2).
    static let tester = AgentSubagentProfile(
        id: testerID,
        purpose: "Run tests and gates, then report evidence: which commands ran, what passed or failed, with the failing output quoted. Never edits code.",
        modelBinding: cheapBinding,
        toolNames: AgentSubagentRunner.allowedToolNames,
        capabilityPromptSection: AgentSubagentJobPrompts.tester,
        maxRounds: AgentSubagentRunner.maxRounds,
        toolPayloadCharacterLimit: 16_000,
        escalation: .none
    )

    /// Independent review of a change's boundary. No shell at all: a reviewer
    /// exists to read what is there, and giving it commands invites it to
    /// "just check" by re-running what the developer already ran.
    static let reviewer = AgentSubagentProfile(
        id: reviewerID,
        purpose: "Independent read-only review of a change: scope creep, version/CHANGELOG consistency, git hygiene. No shell, no edits.",
        modelBinding: deepBinding,
        toolNames: ["read_file", "list_directory", "grep_files", "search_files", "git_status"],
        capabilityPromptSection: AgentSubagentJobPrompts.reviewer,
        maxRounds: 10,
        toolPayloadCharacterLimit: 16_000,
        escalation: .none
    )

    static let smallReviewer = AgentSubagentProfile(
        id: smallReviewerID,
        purpose: "Independently accept, reject, or escalate one verified low-risk change from supplied before/after evidence. No tools and no edits.",
        modelBinding: smallCodingBinding,
        toolNames: [],
        capabilityPromptSection: AgentSubagentJobPrompts.smallReviewer,
        maxRounds: 3,
        toolPayloadCharacterLimit: widePayloadCharacterLimit,
        escalation: .none
    )

    /// Fixes a failing test to green. Unlike `editor` it needs more than one
    /// file — the implementation and its test usually move together — so it
    /// runs on the file-set write channel, and unlike `tester` it is allowed
    /// to change code. The separation stays honest because the verdict is not
    /// its own: the verifier command decides, not the model.
    static let testFixer = AgentSubagentProfile(
        id: testFixerID,
        purpose: "Fix a failing test to green within the files listed in the task. Requires a `task` with `write_files` and a `verifier` command; the verifier's exit code decides success, not the model.",
        modelBinding: wideBinding,
        toolNames: ["read_file", "grep_files", "apply_patch", "run_command"],
        capabilityPromptSection: AgentSubagentJobPrompts.testFixer,
        maxRounds: 6,
        toolPayloadCharacterLimit: widePayloadCharacterLimit,
        escalation: .retryWithParentModel,
        requiresWriteAccess: true
    )

    static let buildFixer = AgentSubagentProfile(
        id: buildFixerID,
        purpose: "Fix compiler, type-check, or lint failures within the files listed in the task. Requires a `task` with `write_files` and a build/lint `verifier` command.",
        modelBinding: balancedBinding,
        toolNames: ["read_file", "grep_files", "apply_patch", "run_command"],
        capabilityPromptSection: AgentSubagentJobPrompts.buildFixer,
        maxRounds: 6,
        toolPayloadCharacterLimit: balancedPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        requiresWriteAccess: true
    )

    /// Reads pre-processed log excerpts. No shell: whoever hands this trade
    /// its input is responsible for slicing the log deterministically, which
    /// is the whole reason a small model can do this job at all.
    static let logInspector = AgentSubagentProfile(
        id: logInspectorID,
        purpose: "Explain errors, stack traces, or pre-processed log excerpts: cluster them, rank by severity, quote the decisive lines. Read-only, no shell.",
        modelBinding: cheapBinding,
        toolNames: ["read_file", "grep_files", "list_directory"],
        capabilityPromptSection: AgentSubagentJobPrompts.logInspector,
        maxRounds: 6,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    static let gitDetective = AgentSubagentProfile(
        id: gitDetectiveID,
        purpose: "Answer repository-history questions: which commit introduced a regression, what a commit changed, how branches differ. Read-only git; never modifies repository state.",
        modelBinding: cheapBinding,
        toolNames: ["read_file", "grep_files", "git_status", "run_command"],
        capabilityPromptSection: AgentSubagentJobPrompts.gitDetective,
        maxRounds: 8,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    /// Judgement trades: no tools at all. They answer a bounded question about
    /// material handed to them, so a tool table would only give a small model
    /// room to wander — and a judge that goes looking for more evidence is a
    /// judge that stopped answering the question.
    static let securityGuard = AgentSubagentProfile(
        id: securityGuardID,
        purpose: "Decide whether one command is safe to run unattended. Answers with a verdict and one sentence of reason; has no tools and cannot run anything itself.",
        modelBinding: .init(preferredProviderID: AgentProviderPreset.someIMID),
        toolNames: [],
        capabilityPromptSection: AgentSubagentJobPrompts.securityGuard,
        maxRounds: 1,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    static let judge = AgentSubagentProfile(
        id: judgeID,
        purpose: "Return one bounded verdict about material you supply — a routing choice, a quality check, a classification. No tools; answers only from what it is given.",
        modelBinding: .init(preferredProviderID: AgentProviderPreset.someIMID),
        toolNames: [],
        capabilityPromptSection: AgentSubagentJobPrompts.judge,
        maxRounds: 1,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    static let opsRunner = AgentSubagentProfile(
        id: opsRunnerID,
        purpose: "Run operations queries directly; submit bounded modifying commands for smart review or exact human approval. Dangerous, credential-sensitive, rollback, and cleanup commands stay with the parent.",
        modelBinding: implementerBinding,
        toolNames: [
            "run_command", "read_file", "grep_files", "list_directory",
            "terminal_list_tabs", "terminal_select_tab",
            "terminal_snapshot", "terminal_send_command",
        ],
        capabilityPromptSection: AgentSubagentJobPrompts.opsRunner,
        // Read-only production investigations often need several independent
        // probes plus one final synthesis turn. Eight rounds could expire
        // immediately after the decisive command returned.
        maxRounds: 32,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    static let terminalOperator = AgentSubagentProfile(
        id: terminalOperatorID,
        purpose: "Drive the visible side-panel terminal: run read-only commands directly; submit bounded modifying commands for smart review or exact human approval; read the screen and report results.",
        modelBinding: cheapBinding,
        toolNames: [
            "terminal_list_tabs", "terminal_select_tab",
            "terminal_snapshot", "terminal_send_command", "read_file",
        ],
        capabilityPromptSection: AgentSubagentJobPrompts.terminalOperator,
        // 每条命令要「snapshot → send → snapshot」三步起，轮次给足。
        maxRounds: 32,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    /// The catch-all trade: everything `deep` can read, on a model a size down
    /// from the session's and with no admission ticket to spend.
    ///
    /// It exists because the catalog had a hole in the middle. The narrow read
    /// trades carry four tools apiece and no shell; `deep` carries everything
    /// but is the scarce 1M tier behind `AgentDeepAdmission`. Any ordinary
    /// question that needed to both read files and run `git log` therefore had
    /// two exits, and both were wrong: burn the 1M ticket, or file it as
    /// operations work and send it to `ops_runner`. The usage data says which
    /// one people took — `ops_runner` ran 60% of all spawns, a third of them on
    /// jobs with nothing operational about them.
    ///
    /// This is the deliberate catch-all. It has the user's visible terminal,
    /// logged-in Chrome bridge and configured MCP gateway, and can accept the
    /// same exact-file write lock as a dedicated writer when the task packet
    /// declares paths. Execution still flows through the parent's approval
    /// policy; broad tool visibility is not broad silent authority.
    static let generalist = AgentSubagentProfile(
        id: generalistID,
        purpose: "General-purpose fallback for work that does not clearly belong to another trade. Can inspect and patch declared files, use the visible terminal, operate the user's logged-in Chrome profile, and discover or call configured MCP tools; parent approval and exact file scopes still apply.",
        modelBinding: generalistBinding,
        toolNames: AgentSubagentRunner.allowedToolNames
            .union(writeToolNames)
            .union(terminalOperatorToolNames)
            .union(generalistExtraToolNames),
        capabilityPromptSection: AgentSubagentJobPrompts.generalist,
        maxRounds: 14,
        toolPayloadCharacterLimit: generalistPayloadCharacterLimit,
        escalation: .retryWithParentModel
    )

    static let builtIn: [AgentSubagentProfile] = [
        scout,
        generalist,
        reader,
        deep,
        editor,
        smallImplementer,
        implementer,
        tester,
        reviewer,
        smallReviewer,
        testFixer,
        buildFixer,
        logInspector,
        gitDetective,
        securityGuard,
        judge,
        opsRunner,
        terminalOperator,
    ]

    /// The capability-oriented trades exposed to people and to the parent
    /// model. The remaining built-ins are implementation details retained for
    /// automatic routing, hosted relay chains, saved workflows, and history.
    /// Model size is configured by the binding, not encoded as another trade.
    static let publicBuiltIn: [AgentSubagentProfile] = [
        generalist,
        implementer,
        tester,
        reviewer,
        opsRunner,
    ]

    static let publicIDs = Set(publicBuiltIn.map(\.id))

    static func isPublic(id rawID: String) -> Bool {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return publicIDs.contains(trimmed)
    }

    /// Presentation-only grouping for legacy specialist trades. Runtime
    /// resolution deliberately keeps the original ID and its narrower tools.
    static func publicID(for rawID: String) -> String {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch id {
        case scoutID, readerID, logInspectorID, gitDetectiveID, deepID, generalistID:
            return generalistID
        case editorID, smallImplementerID, implementerID, testFixerID, buildFixerID:
            return implementerID
        case testerID:
            return testerID
        case reviewerID, smallReviewerID, securityGuardID, judgeID:
            return reviewerID
        case opsRunnerID, terminalOperatorID:
            return opsRunnerID
        default:
            return id
        }
    }

    /// Resolve a spawn's `profile` argument. Unknown or missing → `deep`,
    /// which is the behaviour every pre-profile caller already expects.
    static func profile(id rawID: String?) -> AgentSubagentProfile {
        let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let trimmed, !trimmed.isEmpty else { return deep }
        return builtIn.first { $0.id == trimmed } ?? deep
    }

    static func isKnown(id rawID: String) -> Bool {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return builtIn.contains { $0.id == trimmed }
    }

    /// Default provider for all subagent trades: some.im wins whenever a
    /// corresponding library entry exists; otherwise use the provider marked
    /// active in Settings (and finally the first entry for damaged legacy
    /// libraries with no active id).
    static func defaultProviderEntry(in library: AgentProviderLibrary) -> AgentProviderEntry? {
        library.entries.first { $0.providerID == AgentProviderPreset.someIMID }
            ?? library.active
            ?? library.entries.first
    }

    /// Resolve a persisted binding to one concrete provider library entry.
    /// UUID is authoritative. Provider ID keeps v1 settings working. The
    /// built-in some.im preference is an automatic default, so when some.im
    /// is absent it intentionally falls through to the active provider.
    static func providerEntry(
        for binding: AgentSubagentProfile.ModelBinding,
        in library: AgentProviderLibrary
    ) -> AgentProviderEntry? {
        if let entryID = binding.preferredProviderEntryID,
           let exact = library.entries.first(where: { $0.id == entryID }) {
            return exact
        }
        if let providerID = binding.preferredProviderID,
           let matching = library.entries.first(where: { $0.providerID == providerID }) {
            return matching
        }
        if binding.preferredProviderID == AgentProviderPreset.someIMID {
            return defaultProviderEntry(in: library)
        }
        return nil
    }

    /// The built-in `glm-5` choice is specific to some.im. If automatic
    /// routing had to fall back to another provider, use that entry's primary
    /// model instead of sending an invalid cross-provider model id.
    static func bindingModelApplies(
        _ binding: AgentSubagentProfile.ModelBinding,
        to entry: AgentProviderEntry
    ) -> Bool {
        if let entryID = binding.preferredProviderEntryID {
            return entryID == entry.id
        }
        guard let providerID = binding.preferredProviderID else { return true }
        return providerID == entry.providerID
    }

    /// Schema-facing catalog line for the `spawn_agent` tool description.
    /// Built-ins only; `AgentSubagentProfileStore.toolDescriptionCatalog`
    /// is the one the live schema uses, since it also lists user-created
    /// trades.
    static var toolDescriptionCatalog: String {
        catalogLine(for: publicBuiltIn)
    }

    static func catalogLine(for profiles: [AgentSubagentProfile]) -> String {
        profiles
            .map { "`\($0.id)` — \($0.purpose)" }
            .joined(separator: " ")
    }

    /// Apply the user's per-trade model overrides from settings. Tool sets,
    /// prompts and budgets are never user-editable — narrowing rules and
    /// safety lines are not configuration.
    static func applyingOverrides(
        _ overrides: [String: AgentSubagentProfile.ModelBinding]
    ) -> [AgentSubagentProfile] {
        builtIn.map { profile in
            guard let override = overrides[profile.id] else { return profile }
            var copy = profile
            copy.modelBinding = override
            return copy
        }
    }
}

// MARK: - Settings persistence

/// Trade → runtime resolution. Storage now lives in `AgentProfileStore`
/// (agent-profile.v2), which also owns dispatch profiles; this enum stays as
/// the trade-facing façade so the runner and the `spawn_agent` schema keep
/// one call site.
nonisolated enum AgentSubagentProfileStore {
    private static var store: AgentProfileStore { AgentProfileStore() }

    /// Model bindings only, kept for callers that still think in v1 terms
    /// (the settings section binds directly to these).
    static func loadOverrides() -> [String: AgentSubagentProfile.ModelBinding] {
        var bindings: [String: AgentSubagentProfile.ModelBinding] = [:]
        for profile in store.profiles(usage: .subagent) where profile.origin == .builtIn {
            bindings[profile.id] = profile.runtime.modelBinding
        }
        return bindings.filter { AgentSubagentProfileCatalog.isKnown(id: $0.key) }
    }

    static func saveOverrides(_ overrides: [String: AgentSubagentProfile.ModelBinding]) {
        let store = store
        var profiles = store.profiles()
        for index in profiles.indices {
            guard let binding = overrides[profiles[index].id] else { continue }
            profiles[index].runtime.modelBinding = binding
        }
        store.save(profiles: profiles)
    }

    /// Public capability trades `spawn_agent` advertises, with user edits
    /// applied, plus user-created in-process profiles.
    static func resolvedProfiles() -> [AgentSubagentProfile] {
        let all = allResolvedProfiles()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let publicProfiles = AgentSubagentProfileCatalog.publicBuiltIn.compactMap { byID[$0.id] }
        let managedProfiles = all.filter { !AgentSubagentProfileCatalog.isKnown(id: $0.id) }
        return publicProfiles + managedProfiles
    }

    /// Includes hidden legacy built-ins so saved workflows and automatic
    /// specialist routing continue to resolve their exact tool contracts.
    static func allResolvedProfiles() -> [AgentSubagentProfile] {
        let resolved = store.profiles(usage: .subagent).compactMap { $0.asSubagentProfile() }
        // A damaged or emptied store must never leave `spawn_agent` with no
        // trades at all; fall back to code.
        return resolved.isEmpty ? AgentSubagentProfileCatalog.builtIn : resolved
    }

    /// Schema catalog including user-created trades, so the model can pick
    /// one the user configured rather than only the six public built-ins.
    static var toolDescriptionCatalog: String {
        AgentSubagentProfileCatalog.catalogLine(for: resolvedProfiles())
    }

    static func resolvedProfile(id rawID: String?) -> AgentSubagentProfile {
        let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let profiles = allResolvedProfiles()
        if let trimmed, !trimmed.isEmpty,
           let match = profiles.first(where: { $0.id.lowercased() == trimmed }) {
            return match
        }
        // Unknown or missing → deep, which is what every pre-profile caller
        // already expects.
        return profiles.first { $0.id == AgentSubagentProfileCatalog.deepID }
            ?? AgentSubagentProfileCatalog.deep
    }
}
