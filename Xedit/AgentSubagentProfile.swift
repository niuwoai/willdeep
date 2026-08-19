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
//  A profile may only NARROW the global read-only whitelist. Built-in
//  writing trades are the exception: their write access is constrained by
//  the parent's workspace policy plus an exact file-set lock.
//

import Foundation

nonisolated struct AgentSubagentProfile: Codable, Equatable, Identifiable, Sendable {
    /// How a finished trade recovers when its cheap model could not do the job.
    enum EscalationPolicy: String, Codable, Equatable, Sendable {
        /// Report the failure to the parent as-is.
        case none
        /// Re-run the original prompt once on the parent session's model with
        /// the `deep` tool set. Deliberately a fresh run rather than a
        /// continuation: a small model's stuck transcript is noise to a
        /// bigger one.
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

        static let inheritsParent = ModelBinding()

        var inheritsEverything: Bool {
            preferredProviderID == nil && model == nil
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
    /// True only for built-in writing trades. Gates write tools through the
    /// workspace policy + exact file-set lock path instead of the read-only
    /// whitelist.
    var requiresWriteAccess: Bool
    /// Skills preloaded into this trade's system prompt at spawn time. Empty
    /// for every built-in trade; filled in from the profile's soul.
    var skillIdentifiers: [String]
    /// some.im virtual model that hosts this trade's job prompt server-side
    /// (`someim-32b-<skill>`). Non-nil marks a **managed trade**: while the
    /// user is signed in to some.im its model is pinned to this id and its job
    /// prompt is prepended by the relay, so the client sends neither and the
    /// settings row shows the model as locked. Signed out, the trade falls
    /// back to the user's own binding (or the session's model) and the client
    /// sends `capabilityPromptSection`, which is the offline mirror of the
    /// hosted text — see docs/SOMEIM_WORKER_VIRTUAL_MODELS.md §3.8.
    /// Nil for `deep` / `tester` / `reviewer`, which stay user-configurable.
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

    /// Whether this spawn runs against the relay-hosted job prompt right now.
    /// Resolved at spawn time, never at configuration time, so signing in or
    /// out changes behaviour without migrating anyone's saved settings.
    func usesHostedJobPrompt(someIMAuthenticated: Bool) -> Bool {
        someIMAuthenticated && hostedVirtualModel != nil
    }

    /// The tools this trade may actually call.
    ///
    /// Intersection, never union: a profile can only take tools away from
    /// the global read-only set. `writeAccessGranted` is the writing trades'
    /// narrow door, opened only once the workspace policy and file lock are
    /// satisfied.
    func effectiveToolNames(writeAccessGranted: Bool = false) -> Set<String> {
        var allowed = AgentSubagentRunner.allowedToolNames
        if requiresWriteAccess, writeAccessGranted {
            allowed.formUnion(AgentSubagentProfileCatalog.writeToolNames)
        }
        // 终端工具照 editor 写工具的先例走**按工种放行**，不进全局白名单：
        // 进了全局名单，deep/tester 会静默获得读用户终端屏幕的能力。
        // send_command 虽在此放行，执行层仍有第二道闸——只许命令文本分类
        // 为只读的（见 AgentSubagents.executeToolCall）。
        if id == AgentSubagentProfileCatalog.terminalOperatorID {
            allowed.formUnion(AgentSubagentProfileCatalog.terminalOperatorToolNames)
        }
        return toolNames.intersection(allowed)
    }

    var localizedDisplayName: String {
        switch id {
        case AgentSubagentProfileCatalog.scoutID: return L10n.AgentDelegation.profileScoutName
        case AgentSubagentProfileCatalog.readerID: return L10n.AgentDelegation.profileReaderName
        case AgentSubagentProfileCatalog.editorID: return L10n.AgentDelegation.profileEditorName
        case AgentSubagentProfileCatalog.implementerID: return L10n.AgentDelegation.profileImplementerName
        case AgentSubagentProfileCatalog.testerID: return L10n.AgentDelegation.profileTesterName
        case AgentSubagentProfileCatalog.reviewerID: return L10n.AgentDelegation.profileReviewerName
        case AgentSubagentProfileCatalog.testFixerID: return L10n.AgentDelegation.profileTestFixerName
        case AgentSubagentProfileCatalog.buildFixerID: return L10n.AgentDelegation.profileBuildFixerName
        case AgentSubagentProfileCatalog.logInspectorID: return L10n.AgentDelegation.profileLogInspectorName
        case AgentSubagentProfileCatalog.gitDetectiveID: return L10n.AgentDelegation.profileGitDetectiveName
        case AgentSubagentProfileCatalog.securityGuardID: return L10n.AgentDelegation.profileSecurityGuardName
        case AgentSubagentProfileCatalog.judgeID: return L10n.AgentDelegation.profileJudgeName
        case AgentSubagentProfileCatalog.opsRunnerID: return L10n.AgentDelegation.profileOpsRunnerName
        case AgentSubagentProfileCatalog.terminalOperatorID: return L10n.AgentDelegation.profileTerminalOperatorName
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
        case AgentSubagentProfileCatalog.implementerID: return L10n.AgentDelegation.profileImplementerPurpose
        case AgentSubagentProfileCatalog.testerID: return L10n.AgentDelegation.profileTesterPurpose
        case AgentSubagentProfileCatalog.reviewerID: return L10n.AgentDelegation.profileReviewerPurpose
        case AgentSubagentProfileCatalog.testFixerID: return L10n.AgentDelegation.profileTestFixerPurpose
        case AgentSubagentProfileCatalog.buildFixerID: return L10n.AgentDelegation.profileBuildFixerPurpose
        case AgentSubagentProfileCatalog.logInspectorID: return L10n.AgentDelegation.profileLogInspectorPurpose
        case AgentSubagentProfileCatalog.gitDetectiveID: return L10n.AgentDelegation.profileGitDetectivePurpose
        case AgentSubagentProfileCatalog.securityGuardID: return L10n.AgentDelegation.profileSecurityGuardPurpose
        case AgentSubagentProfileCatalog.judgeID: return L10n.AgentDelegation.profileJudgePurpose
        case AgentSubagentProfileCatalog.opsRunnerID: return L10n.AgentDelegation.profileOpsRunnerPurpose
        case AgentSubagentProfileCatalog.terminalOperatorID: return L10n.AgentDelegation.profileTerminalOperatorPurpose
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
    static let implementerID = "implementer"
    static let testerID = "tester"
    static let reviewerID = "reviewer"
    static let testFixerID = "test_fixer"
    static let buildFixerID = "build_fixer"
    static let logInspectorID = "log_inspector"
    static let gitDetectiveID = "git_detective"
    static let securityGuardID = "security_guard"
    static let judgeID = "judge"
    static let opsRunnerID = "ops_runner"
    static let terminalOperatorID = "terminal_operator"

    static let workerPayloadCharacterLimit = 4_000
    static let balancedPayloadCharacterLimit = 5_000
    static let widePayloadCharacterLimit = 6_000
    static let implementerPayloadCharacterLimit = 16_000

    /// Deployable model tiers. 16K is deliberately absent: the target 16GB
    /// baseline can run 35B-A3B-class models at 32K and, depending on KV cache
    /// and quantization, at 48K/64K. 256K is the ordinary multi-file coding
    /// tier; `deep` remains the exceptional parent-model fallback.
    static let workerContextWindowTokens = 32_768
    static let balancedContextWindowTokens = 49_152
    static let wideContextWindowTokens = 65_536
    static let implementerContextWindowTokens = 262_144
    /// The L tier. Deliberately spelled out rather than left implicit: a
    /// budget nobody can see is a budget nobody defends. `AgentDeepAdmission`
    /// is what decides whether a spawn may spend it.
    static let deepContextWindowTokens = 1_048_576

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

    /// Default binding for the cheap trades: some.im's GLM tier when the
    /// user is signed in, otherwise inherit the parent (resolved at spawn
    /// time, so signing in or out never requires a settings migration).
    private static let cheapBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: "glm-5",
        contextWindowTokens: workerContextWindowTokens
    )

    private static let balancedBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: "glm-5",
        contextWindowTokens: balancedContextWindowTokens
    )

    private static let wideBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: "glm-5",
        contextWindowTokens: wideContextWindowTokens
    )

    private static let implementerBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: "glm-5",
        contextWindowTokens: implementerContextWindowTokens
    )

    /// Deep used to inherit the parent session. Subagents now default to a
    /// provider of their own as requested by Settings: some.im when present,
    /// otherwise the active provider. A nil model adopts that provider's
    /// configured primary model.
    private static let automaticProviderBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: nil,
        contextWindowTokens: nil
    )

    /// `deep` is the only trade that gets the 1M window, and now it says so.
    ///
    /// It used to share `automaticProviderBinding` with tester/reviewer, which
    /// meant it silently adopted whatever the provider's primary model was.
    /// That was fine while the primary model *was* the 1M one — but then the
    /// L tier was simply the default, and "escalate to deep" bought nothing
    /// the session did not already have. Pinning it makes the escalation real
    /// and makes the tier visible in the trade settings row.
    private static let deepBinding = AgentSubagentProfile.ModelBinding(
        preferredProviderID: AgentProviderPreset.someIMID,
        model: "deepseek-v4-flash",
        contextWindowTokens: deepContextWindowTokens
    )

    static let scout = AgentSubagentProfile(
        id: scoutID,
        purpose: "Locate things: find files, symbols, call sites, or answer \"where is X / does X exist\". Fastest and cheapest; no shell.",
        modelBinding: cheapBinding,
        toolNames: ["grep_files", "search_files", "list_directory", "read_file"],
        capabilityPromptSection: AgentSubagentJobPrompts.scout,
        maxRounds: 8,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: scoutID)
    )

    static let reader = AgentSubagentProfile(
        id: readerID,
        purpose: "Read and summarize: digest long files, docs, or public web pages and answer questions about their content. No shell.",
        modelBinding: balancedBinding,
        toolNames: ["read_file", "list_directory", "web_search"],
        capabilityPromptSection: AgentSubagentJobPrompts.reader,
        maxRounds: 8,
        toolPayloadCharacterLimit: balancedPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: readerID)
    )

    /// The full read-only investigation trade. Any spawn that does not name a
    /// profile lands here, so old prompts and replayed sessions keep the same
    /// tool and round budgets while adopting the configurable provider/model
    /// routing shared by every subagent trade.
    static let deep = AgentSubagentProfile(
        id: deepID,
        purpose: "Complex investigation: reasoning across many files, read-only shell commands, and git status. Scarce 1M tier — requires an admission ticket.",
        modelBinding: deepBinding,
        toolNames: AgentSubagentRunner.allowedToolNames,
        capabilityPromptSection: """
        Your trade is INVESTIGATION. Follow the evidence across files, verify claims before \
        reporting them, and state explicitly what you could not confirm.
        """,
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
        requiresWriteAccess: true,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: editorID)
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

    /// Runs the gates and reports evidence. Deliberately has the read-only
    /// shell (tests, linters and reports are read-tier commands) but no write
    /// tool: whoever verifies may not also implement — a tester that can patch
    /// the code it just failed is not a tester
    /// (docs/GOAL_TEAMS_ROLES_DESIGN.md §2.2).
    static let tester = AgentSubagentProfile(
        id: testerID,
        purpose: "Run tests and gates, then report evidence: which commands ran, what passed or failed, with the failing output quoted. Never edits code.",
        modelBinding: automaticProviderBinding,
        toolNames: AgentSubagentRunner.allowedToolNames,
        capabilityPromptSection: """
        Your trade is VERIFICATION. Run the relevant tests or gates and report what actually \
        happened: the exact commands, their exit status, and the failing output quoted verbatim. \
        Never repair what you find — a failure you fixed yourself is a failure nobody verified. \
        If a gate cannot be run, say so and say why instead of inferring the result.
        """,
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
        modelBinding: automaticProviderBinding,
        toolNames: ["read_file", "list_directory", "grep_files", "search_files", "git_status"],
        capabilityPromptSection: """
        Your trade is REVIEW. Judge the change in front of you: does it stay inside its declared \
        scope, are version and CHANGELOG consistent with the code, is anything half-landed. State \
        an explicit verdict and the evidence for it (paths, line numbers). You did not write this \
        change and you do not fix it — report what is wrong and let its author repair it.
        """,
        maxRounds: 10,
        toolPayloadCharacterLimit: 16_000,
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
        requiresWriteAccess: true,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: testFixerID)
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
        requiresWriteAccess: true,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: buildFixerID)
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
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: logInspectorID)
    )

    static let gitDetective = AgentSubagentProfile(
        id: gitDetectiveID,
        purpose: "Answer repository-history questions: which commit introduced a regression, what a commit changed, how branches differ. Read-only git; never modifies repository state.",
        modelBinding: cheapBinding,
        toolNames: ["read_file", "grep_files", "git_status", "run_command"],
        capabilityPromptSection: AgentSubagentJobPrompts.gitDetective,
        maxRounds: 8,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: gitDetectiveID)
    )

    /// Judgement trades: no tools at all. They answer a bounded question about
    /// material handed to them, so a tool table would only give a small model
    /// room to wander — and a judge that goes looking for more evidence is a
    /// judge that stopped answering the question.
    static let securityGuard = AgentSubagentProfile(
        id: securityGuardID,
        purpose: "Decide whether one command is safe to run unattended. Answers with a verdict and one sentence of reason; has no tools and cannot run anything itself.",
        modelBinding: cheapBinding,
        toolNames: [],
        capabilityPromptSection: AgentSubagentJobPrompts.securityGuard,
        maxRounds: 1,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: securityGuardID)
    )

    static let judge = AgentSubagentProfile(
        id: judgeID,
        purpose: "Return one bounded verdict about material you supply — a routing choice, a quality check, a classification. No tools; answers only from what it is given.",
        modelBinding: cheapBinding,
        toolNames: [],
        capabilityPromptSection: AgentSubagentJobPrompts.judge,
        maxRounds: 1,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: judgeID)
    )

    static let opsRunner = AgentSubagentProfile(
        id: opsRunnerID,
        purpose: "Read-only operations queries via shell: service status, log tails, `kubectl get/describe/logs`, `gh run list`, CI results. The sandbox denies anything that mutates state, so it can inspect but never change.",
        modelBinding: cheapBinding,
        toolNames: ["run_command", "read_file", "grep_files", "list_directory"],
        capabilityPromptSection: AgentSubagentJobPrompts.opsRunner,
        maxRounds: 8,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: opsRunnerID)
    )

    static let terminalOperator = AgentSubagentProfile(
        id: terminalOperatorID,
        purpose: "Drive the visible side-panel terminal: run given read-only commands in a specified tab, read the screen, report results. Everything happens in front of the user; write commands are denied by policy.",
        modelBinding: cheapBinding,
        toolNames: [
            "terminal_list_tabs", "terminal_select_tab",
            "terminal_snapshot", "terminal_send_command", "read_file",
        ],
        capabilityPromptSection: AgentSubagentJobPrompts.terminalOperator,
        // 每条命令要「snapshot → send → snapshot」三步起，轮次给足。
        maxRounds: 12,
        toolPayloadCharacterLimit: workerPayloadCharacterLimit,
        escalation: .retryWithParentModel,
        hostedVirtualModel: AgentSubagentJobPrompts.hostedModel(for: terminalOperatorID)
    )

    static let builtIn: [AgentSubagentProfile] = [
        scout,
        reader,
        deep,
        editor,
        implementer,
        tester,
        reviewer,
        testFixer,
        buildFixer,
        logInspector,
        gitDetective,
        securityGuard,
        judge,
        opsRunner,
        terminalOperator,
    ]

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
        catalogLine(for: builtIn)
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

    /// Every trade `spawn_agent` may select: the four built-ins with the
    /// user's soul/model edits applied, plus any user-created in-process
    /// profile marked for subagent use.
    static func resolvedProfiles() -> [AgentSubagentProfile] {
        let resolved = store.profiles(usage: .subagent).compactMap { $0.asSubagentProfile() }
        // A damaged or emptied store must never leave `spawn_agent` with no
        // trades at all; fall back to code.
        return resolved.isEmpty ? AgentSubagentProfileCatalog.builtIn : resolved
    }

    /// Schema catalog including user-created trades, so the model can pick
    /// one the user configured rather than only the four built-ins.
    static var toolDescriptionCatalog: String {
        AgentSubagentProfileCatalog.catalogLine(for: resolvedProfiles())
    }

    static func resolvedProfile(id rawID: String?) -> AgentSubagentProfile {
        let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let profiles = resolvedProfiles()
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
