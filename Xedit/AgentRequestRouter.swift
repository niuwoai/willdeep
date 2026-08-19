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
//  So the runtime forms its own opinion first, from the request text alone,
//  and states it in the turn. This is deliberately the *weak* half of the
//  mechanism — it appends a `<runtime-route>` note and nothing more. The
//  model can still decide the classification is wrong, which matters,
//  because this is keyword matching and it will sometimes be wrong.
//
//  What it is NOT: a dispatcher. willdeep-rs runs the high-confidence
//  read-only cases as a worker *before* the root model sees the repository
//  and injects the report as evidence. That trade is right for a TUI, where
//  the user already expects a pause. In a GUI it doubles time-to-first-token
//  on questions as ordinary as "where is this function", and a Chinese
//  false positive is visible rather than merely wasteful. So the eligibility
//  is computed and recorded here, gated behind a setting that ships off,
//  and the decision to turn it on belongs to the Deep Share numbers rather
//  than to anyone's taste. See docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §4
//  step 4 and §5.
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
        var reason: String

        /// The paragraph appended to the user's message, or nil when there is
        /// nothing useful to say.
        var steering: String? {
            guard let profileID else { return nil }
            return """
            <runtime-route tier="\(tier.rawValue)" profile="\(profileID)" confidence="\(confidence)">
            WillDeep classified this request as bounded `\(profileID)` work before you read it. \
            Compile a task packet — keep `read_files` separate from `write_files` — and delegate \
            it rather than doing the work here. Supply a verifier whenever completion is decidable \
            by a command. If the classification is wrong, say so in one line and proceed your way.
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

    private static let locateMarkers = [
        "在哪里", "在哪个文件", "在哪儿", "定位", "找一下", "找到",
        "locate", "where is", "where are", "find where", "which file",
    ]

    private static let readMarkers = [
        "总结", "解释", "阅读", "扫一下", "扫描", "审查", "梳理", "讲讲",
        "summarize", "explain", "read the", "review the", "review docs",
        "audit", "scan the", "walk me through",
    ]

    /// Classify a request. Pure and cheap — no I/O, no model call.
    static func classify(_ request: String) -> Decision {
        let sample = String(request.prefix(classifiedPrefixLength)).lowercased()
        let mutating = contains(sample, mutatingMarkers)

        if contains(sample, testFailureMarkers) {
            return mutating
                ? worker("test_fixer", 96, autoDispatch: false,
                         reason: "a failing test has a deterministic verifier")
                : worker("log_inspector", 92, autoDispatch: true,
                         reason: "explaining a test failure is bounded and read-only")
        }
        if contains(sample, buildFailureMarkers) {
            return mutating
                ? worker("build_fixer", 96, autoDispatch: false,
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
        if !mutating, contains(sample, locateMarkers) {
            return worker("scout", 90, autoDispatch: true,
                          reason: "locating symbols and files is bounded read-only work")
        }
        if !mutating, contains(sample, readMarkers) {
            return worker("reader", 86, autoDispatch: true,
                          reason: "reading can be isolated from the parent context")
        }
        if mutating {
            return Decision(
                tier: .standard,
                profileID: "implementer",
                confidence: 78,
                autoDispatchEligible: false,
                reason: "ordinary implementation belongs on the standard tier"
            )
        }
        return Decision(
            tier: .standard,
            profileID: nil,
            confidence: 70,
            autoDispatchEligible: false,
            reason: "ambiguous work stays on the standard tier; decompose before escalating"
        )
    }

    /// The note to append to this turn's user message, or nil.
    ///
    /// `/no-subagent` suppresses it entirely: that policy means "do all of it
    /// yourself this turn", and steering the model toward a tool that has
    /// been removed from its table just wastes a round.
    static func steering(
        for request: String,
        delegationPolicy: AgentDelegationPolicy
    ) -> String? {
        guard delegationPolicy != .forbidden else { return nil }
        return classify(request).steering
    }

    private static func worker(
        _ profileID: String,
        _ confidence: Int,
        autoDispatch: Bool,
        reason: String
    ) -> Decision {
        Decision(
            tier: .worker,
            profileID: profileID,
            confidence: confidence,
            autoDispatchEligible: autoDispatch,
            reason: reason
        )
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
