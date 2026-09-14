//
//  AgentRequestRouter.swift
//  WillDeep
//
//  Classifying a request before the model reads it.
//
//  The delegation contract in the system prompt tells the model to prefer
//  bounded trades. It is read every turn and followed selectively: by the
//  time the model is deciding, it has already started thinking about the
//  problem, and compiling a task packet reads as a detour. Advice loses to
//  momentum.
//
//  So the runtime forms its own opinion first, from the request text alone.
//  Read/preparation work can run as an explicitly enabled bounded preflight.
//  Automatic routes are advisory so a small, single-owner request does not
//  pay for a second model before useful work starts. Explicitly named workers,
//  `/subagent`, and privileged ops routes remain delegate-first policy.
//
//  What it is NOT: a dispatcher. willdeep-rs runs the high-confidence
//  read-only cases as a worker *before* the root model sees the repository
//  and injects the report as evidence. That trade is right for a TUI, where
//  the user already expects a pause. In a GUI it doubles time-to-first-token
//  on questions as ordinary as "where is this function", and a Chinese
//  false positive is visible rather than merely wasteful. So the eligibility
//  is computed and recorded here, behind a setting that the Deep Share
//  numbers were meant to decide. It remains opt-in because serial preflight
//  increases time-to-first-token even when the root could answer directly.
//  See docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §4 step 4 and §5.
//

import Foundation

nonisolated enum AgentRequestRouter {
    enum Tier: String, Equatable, Sendable {
        case worker
        case standard
    }

    struct Decision: Equatable, Sendable {
        var tier: Tier
        /// The trade this request looks like, or nil when nothing fits and
        /// the standard tier should simply proceed.
        var profileID: String?
        /// 0–100. Only used to decide auto-dispatch eligibility and to make
        /// the note honest about how sure the runtime is.
        var confidence: Int
        /// Whether this would be safe to run as a worker *before* the model
        /// answers. True only for read-only work — a request that changes
        /// files is never pre-run, because a preflight that edits is not a
        /// preflight.
        var autoDispatchEligible: Bool
        /// Bounded worker the host should run before the root model starts.
        /// For read-only requests this is normally the routed profile itself;
        /// for mutations it is a read-only scout that prepares the write task.
        var preflightProfileID: String? = nil
        /// This route is eligible for delegate-first enforcement. The actual
        /// enforcement also considers the per-turn policy: automatic coding
        /// routes are advisory, while explicit and privileged routes are hard.
        var requiresDelegatedExecution: Bool = false
        var reason: String

        var isPreflightCandidate: Bool { preflightProfileID != nil }

        /// 操作员点名的判决：满分 + 强制委派，且不是预跑候选。
        var isOperatorPinned: Bool {
            confidence == 100 && requiresDelegatedExecution && !autoDispatchEligible
                && reason == "operator named this worker in the composer"
        }

        /// Whether the host must observe a matching worker attempt before a
        /// direct write/ops tool may run.
        func enforcesDelegatedExecution(for delegationPolicy: AgentDelegationPolicy) -> Bool {
            guard requiresDelegatedExecution else { return false }
            return isOperatorPinned
                || delegationPolicy == .required
                || profileID == AgentSubagentProfileCatalog.opsRunnerID
        }

        /// Compatibility view for call sites that do not carry a turn policy.
        var steering: String? { steering(for: .automatic) }

        /// The paragraph appended to the user's message, or nil when there is
        /// nothing useful to say.
        func steering(for delegationPolicy: AgentDelegationPolicy) -> String? {
            guard let profileID else { return nil }
            let enforced = enforcesDelegatedExecution(for: delegationPolicy)
            let instruction: String
            if enforced {
                instruction = """
                Compile a task packet — keep `read_files` separate from `write_files` — and delegate \
                it before direct execution. Supply a verifier whenever completion is decidable by a \
                command. The host may refuse direct execution until the routed worker has been attempted.
                """
            } else {
                instruction = """
                Treat this as a routing hint, not a mandatory extra stage. Delegate only when the work is \
                independently bounded and doing so avoids duplicate context or can run in parallel. For a \
                small single-owner task, proceed directly. If you delegate, keep `read_files` separate from \
                `write_files` and supply a verifier when a command can decide completion.
                """
            }
            return """
            <runtime-route tier="\(tier.rawValue)" profile="\(profileID)" confidence="\(confidence)">
            \(isOperatorPinned
                ? "The operator named `\(profileID)` for this request in the composer. This is an instruction, not a classification — do not re-route it."
                : "WillDeep classified this request as bounded `\(profileID)` work before you read it.") \
            \(instruction)
            </runtime-route>
            """
        }
    }

    /// Only the first slice of a request is classified. A long paste is
    /// usually material rather than instruction, and letting it vote turns
    /// every pasted stack trace into a `log_inspector` verdict.
    static let classifiedPrefixLength = 4_000

    /// Words that mean the request changes something. Checked first because
    /// it flips several categories: "explain this test failure" is reading,
    /// "fix this test failure" is repair, and they route to different trades.
    private static let mutatingMarkers = [
        "修复", "修改", "实现", "新增", "删除", "重构", "改成", "改为", "补上", "加上",
        "开发", "编码", "写代码", "修一下", "改一下", "优化", "适配", "接入", "添加",
        "补测试", "写测试",
        "fix", "implement", "add ", "change", "edit", "refactor", "rewrite", "create",
    ]

    private static let testFailureMarkers = [
        "测试失败", "测试不通过", "断言失败", "跑不过",
        "test fail", "failing test", "tests fail", "assertion fail",
    ]

    private static let buildFailureMarkers = [
        "编译失败", "构建失败", "类型错误", "编译错误",
        "compile error", "build fail", "lint error", "type error", "does not compile",
    ]

    private static let regressionMarkers = [
        "哪个提交", "哪次提交", "引入这个问题", "什么时候坏的", "回归",
        "git history", "regression", "which commit", "when did this break",
    ]

    private static let logMarkers = [
        "错误日志", "分析日志", "报错输出", "崩溃日志", "堆栈",
        "traceback", "stack trace", "panic", "crash log", "error log",
    ]

    /// Running the gates, as opposed to explaining or repairing a failure.
    /// Kept separate from `testFailureMarkers`, which is about a failure that
    /// already happened.
    private static let testRunMarkers = [
        "跑测试", "跑一下测试", "跑单测", "运行测试", "跑一遍测试", "验证一下",
        "run the test", "run tests", "run the suite", "verify this", "check it passes",
    ]

    /// Reviewing a *change* — which is `reviewer`'s trade — rather than
    /// reading code in general, which is `reader`'s. Checked before the read
    /// markers because "审查" matches both and the narrower one should win.
    private static let reviewMarkers = [
        "审查这个改动", "审查改动", "审查这次", "代码审查", "评审这个改动", "看下这个改动",
        "检查这次提交", "检查这个改动", "review the change", "review this change",
        "review the diff", "review this diff", "code review", "review my changes",
    ]

    private static let locateMarkers = [
        "在哪里", "在哪个文件", "在哪儿", "定位", "找一下", "找到",
        "locate", "where is", "where are", "find where", "which file",
    ]

    private static let readMarkers = [
        "总结", "解释", "阅读", "扫一下", "扫描", "审查", "梳理", "讲讲",
        "summarize", "explain", "read the", "review the", "review docs",
        "audit", "scan the", "walk me through",
    ]

    private static let terminalMarkers = [
        "看看终端", "检查终端", "终端环境检查", "终端里", "终端窗口", "侧栏终端",
        "inspect terminal", "check terminal", "terminal environment", "terminal pane", "terminal window",
    ]

    private static let operationsMarkers = [
        "部署", "发布到", "生产环境", "线上环境", "重启服务", "服务状态", "回滚发布",
        "deploy", "release to", "production cluster", "restart service", "service status",
        "systemctl", "kubectl rollout", "helm upgrade",
    ]

    /// Classify a request. Pure and cheap — no I/O, no model call.
    ///
    /// `skippingPrivilegedBranches` re-runs the same table with the two
    /// privileged destinations removed. It exists for one caller: the routing
    /// veto, which downgrades a privileged decision the local model rejected.
    /// The downgrade target stays a keyword verdict — the model only decides
    /// *whether* to skip those branches, never *what* to pick instead, so a
    /// veto can shrink what the turn may do but can never redirect it.
    static func classify(
        _ request: String,
        skippingPrivilegedBranches: Bool = false
    ) -> Decision {
        // Composer context is model input, not operator intent. Skill/file
        // metadata can contain words such as "部署" or "生产环境" and used to
        // steal the route before the user's actual sentence was considered.
        // The attached-prompt protocol already has an unambiguous boundary;
        // reuse its parser so only text authored by the operator gets a vote.
        let operatorText = AgentAttachedPromptDisplay.transform(request).userAuthoredText
        let sample = String(operatorText.prefix(classifiedPrefixLength)).lowercased()
        let mutating = contains(sample, mutatingMarkers)

        if !skippingPrivilegedBranches, contains(sample, terminalMarkers) {
            return worker(
                "terminal_operator",
                94,
                autoDispatch: true,
                reason: "visible terminal inspection belongs to the terminal operator"
            )
        }
        // Word-boundary matching, unlike every other marker table: this branch
        // enforces delegated execution regardless of policy, so a false hit
        // does not merely mislabel the Worker — it blocks the edit. "deploy"
        // as a bare substring fires on "deployment", turning "把 deployment
        // 里的注解改一下" (editing a manifest) into a production rollout.
        if !skippingPrivilegedBranches, containsWord(sample, operationsMarkers) {
            return worker(
                "ops_runner",
                94,
                autoDispatch: true,
                requiresDelegatedExecution: true,
                reason: "production operations need a read-only preflight and exact-command execution"
            )
        }

        if contains(sample, testFailureMarkers) {
            return mutating
                ? worker("test_fixer", 96, autoDispatch: false, preflightProfileID: "log_inspector",
                         requiresDelegatedExecution: true,
                         reason: "a failing test has a deterministic verifier")
                : worker("log_inspector", 92, autoDispatch: true,
                         reason: "explaining a test failure is bounded and read-only")
        }
        if contains(sample, buildFailureMarkers) {
            return mutating
                ? worker("build_fixer", 96, autoDispatch: false, preflightProfileID: "log_inspector",
                         requiresDelegatedExecution: true,
                         reason: "build diagnostics have a deterministic verifier")
                : worker("log_inspector", 92, autoDispatch: true,
                         reason: "explaining a build failure is bounded and read-only")
        }
        if !mutating, contains(sample, regressionMarkers) {
            return worker("git_detective", 94, autoDispatch: true,
                          reason: "repository archaeology is bounded and read-only")
        }
        if !mutating, contains(sample, logMarkers) {
            return worker("log_inspector", 92, autoDispatch: true,
                          reason: "failure output can be inspected in a small window")
        }
        if !mutating, contains(sample, testRunMarkers) {
            return worker("tester", 90, autoDispatch: true,
                          reason: "running gates and reporting evidence is the tester trade")
        }
        if !mutating, contains(sample, reviewMarkers) {
            return worker("reviewer", 90, autoDispatch: true,
                          reason: "reviewing a change is bounded and read-only")
        }
        if !mutating, contains(sample, locateMarkers) {
            return worker("scout", 90, autoDispatch: true,
                          reason: "locating symbols and files is bounded read-only work")
        }
        if !mutating, contains(sample, readMarkers) {
            return worker("reader", 86, autoDispatch: true,
                          reason: "reading can be isolated from the parent context")
        }
        if mutating {
            // A change that names exactly one source file is what `editor`
            // exists for — one declared path, nothing else touchable. Without
            // this branch every mutating request became `implementer`, and
            // `editor` was never so much as suggested.
            if namedSourceFiles(sample).count == 1 {
                return worker("editor", 88, autoDispatch: false,
                              preflightProfileID: "scout",
                              requiresDelegatedExecution: true,
                              reason: "the request names a single file to change")
            }
            return Decision(
                tier: .standard,
                profileID: "implementer",
                confidence: 78,
                autoDispatchEligible: false,
                preflightProfileID: "scout",
                requiresDelegatedExecution: true,
                reason: "ordinary implementation belongs on the standard tier"
            )
        }
        return Decision(
            tier: .worker,
            profileID: AgentSubagentProfileCatalog.generalistID,
            confidence: 70,
            autoDispatchEligible: false,
            requiresDelegatedExecution: true,
            reason: "no narrower trade fits, so the general-purpose utility worker owns the task"
        )
    }

    /// The note to append to this turn's user message, or nil.
    ///
    /// `/no-subagent` suppresses it entirely: that policy means "do all of it
    /// yourself this turn", and steering the model toward a tool that has
    /// been removed from its table just wastes a round.
    static func steering(
        for request: String,
        delegationPolicy: AgentDelegationPolicy,
        sharedConfig: AgentSharedRuntimeConfig = .load()
    ) -> String? {
        // `agent.small_model_routing = false` in the shared config.toml turns
        // this off for both clients at once. Absent means on, matching the
        // willdeep-rs default.
        routedDecision(
            for: request,
            delegationPolicy: delegationPolicy,
            sharedConfig: sharedConfig
        )?.steering(for: delegationPolicy)
    }

    static func routedDecision(
        for request: String,
        delegationPolicy: AgentDelegationPolicy,
        sharedConfig: AgentSharedRuntimeConfig = .load(),
        skippingPrivilegedBranches: Bool = false
    ) -> Decision? {
        guard sharedConfig.smallModelRouting != false else { return nil }
        guard delegationPolicy != .forbidden else { return nil }
        guard delegationPolicy != .agentPreferred else { return nil }
        return classify(request, skippingPrivilegedBranches: skippingPrivilegedBranches)
    }

    /// 操作员在 composer 里 `@` 点名了某个 worker。
    ///
    /// 这跟关键词打分、模型判断都不是一回事：那两条是「猜」，这条是明确指令。
    /// 所以 confidence 直接给满分，并把 `requiresDelegatedExecution` 置真——
    /// 点了名还让根模型自己上手，等于没点。刻意**不**开 autoDispatchEligible：
    /// 预跑是宿主替用户抢跑，用户点名的是「派给他」，不是「现在就跑」。
    static func pinnedDecision(profileID: String) -> Decision {
        Decision(
            tier: .worker,
            profileID: profileID,
            confidence: 100,
            autoDispatchEligible: false,
            preflightProfileID: nil,
            requiresDelegatedExecution: true,
            reason: "operator named this worker in the composer"
        )
    }

    private static func worker(
        _ profileID: String,
        _ confidence: Int,
        autoDispatch: Bool,
        preflightProfileID: String? = nil,
        requiresDelegatedExecution: Bool = false,
        reason: String
    ) -> Decision {
        Decision(
            tier: .worker,
            profileID: profileID,
            confidence: confidence,
            autoDispatchEligible: autoDispatch,
            preflightProfileID: preflightProfileID ?? (autoDispatch ? profileID : nil),
            requiresDelegatedExecution: requiresDelegatedExecution,
            reason: reason
        )
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// Which privileged marker this request tripped, if any.
    ///
    /// Attribution for `route-veto.jsonl`: the resulting profile alone cannot
    /// tell you *which word* caused a false positive, and that is the only
    /// question worth asking of this table. Uses the same matching the branch
    /// itself uses, so the answer is the real cause rather than a re-guess.
    static func matchedPrivilegedMarker(in request: String) -> String? {
        let operatorText = AgentAttachedPromptDisplay.transform(request).userAuthoredText
        let sample = String(operatorText.prefix(classifiedPrefixLength)).lowercased()
        if let hit = terminalMarkers.first(where: { sample.contains($0) }) { return hit }
        return operationsMarkers.first { containsWord(sample, $0) }
    }

    /// Like `contains`, but an ASCII needle must not sit inside a longer ASCII
    /// word: "deploy" matches "deploy to prod" and "deploy一下", never
    /// "deployment". CJK needles have no boundary to test — every neighbouring
    /// character is a letter — so they keep plain substring semantics.
    ///
    /// Only the boundary of ASCII letters and digits counts. Checking
    /// `Character.isLetter` alone would reject "deploy一下", since CJK
    /// characters are letters too.
    private static func containsWord(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { needle in
            guard !needle.isEmpty else { return false }
            guard needle.allSatisfy({ $0.isASCII }) else { return haystack.contains(needle) }
            return containsWord(haystack, needle)
        }
    }

    private static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        func isWordCharacter(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }

        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let openingIsClean = found.lowerBound == haystack.startIndex
                || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
            let closingIsClean = found.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[found.upperBound])
            if openingIsClean, closingIsClean { return true }
            guard found.lowerBound < haystack.endIndex else { break }
            searchStart = haystack.index(after: found.lowerBound)
        }
        return false
    }

    /// Distinct source files the request names. Deliberately literal: a path
    /// the user typed is evidence about scope, while a guess at which files a
    /// vague request implies is exactly the kind of thing this classifier
    /// must not do. Extensions come from the repair set so "a source file"
    /// means one thing across the runtime — `.o` / `.json` / `.lock` paths in
    /// a pasted log never count as an edit target.
    static func namedSourceFiles(_ sample: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: " \t\n\r,;:()[]{}<>\"'`，。、；：（）【】「」")
        var files: Set<String> = []
        for token in sample.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex else { continue }
            let ext = String(trimmed[trimmed.index(after: dot)...])
            guard AgentWorkerAutoDispatch.repairableExtensions.contains(ext) else { continue }
            files.insert(trimmed)
        }
        return files
    }
}
