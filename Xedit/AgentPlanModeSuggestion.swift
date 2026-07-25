//
//  AgentPlanModeSuggestion.swift
//  WillDeep
//
//  Local, deterministic preflight for suggesting Plan mode before a complex
//  task is dispatched. The classifier intentionally favors precision: a
//  single "fix" or "refactor" word is not enough to interrupt the user.
//

import Foundation

nonisolated struct AgentPlanModeSuggestion: Equatable, Identifiable {
    let id = UUID()
}

/// Which action the pre-dispatch preflight recommends for a given input.
///
/// - `skip`: not complex enough (or the user opted out) — send normally.
/// - `askFlash`: locally ambiguous (`flashScoreRange`) — ask a lightweight
///   flash model whether Plan mode is worth suggesting.
/// - `suggest`: locally confident (>= `minimumScore`) — surface the banner
///   directly without spending a round-trip on the flash judge.
nonisolated enum AgentPlanModeSuggestionBand: Equatable {
    case skip
    case askFlash
    case suggest
}

nonisolated enum AgentPlanModeSuggestionPolicy {
    /// 1.202.0: raised the entry bar. A direct suggestion now needs 4 points
    /// (was 3) — a single strong-complexity hint (2) plus one weak signal no
    /// longer interrupts on its own; it takes a genuine multi-signal task.
    static let minimumScore = 4
    /// Locally ambiguous window forwarded to the flash judge. Raised the low
    /// end from 1 → 2 alongside `minimumScore`: a lone weak hint (score 1) now
    /// skips outright instead of spending a judge round-trip.
    static let flashScoreRange = 2...3
    static let autoResolutionSeconds = 15

    private static let optOutHints = [
        "不要 plan", "不用 plan", "别进 plan", "直接执行", "直接做",
        "don't use plan", "do not use plan", "skip plan", "just do it"
    ]

    private static let strongComplexityHints = [
        "架构", "重构", "迁移", "安全审计", "性能优化", "疑难调试",
        "跨文件", "多文件", "跨模块", "多模块", "前后端", "数据库迁移",
        "architecture", "refactor", "migration", "security audit",
        "performance optimization", "cross-file", "multi-file", "end-to-end"
    ]

    private static let planningHints = [
        "分步骤", "完整实现", "整体实现", "端到端", "从头实现", "先分析",
        "先检查", "然后", "最后", "step by step", "full implementation",
        "first inspect", "first analyze", "then", "finally"
    ]

    private static let verificationHints = [
        "单元测试", "自动化测试", "回归测试", "集成测试", "端到端测试",
        "验证构建", "运行测试", "unit test", "integration test", "regression test",
        "e2e test", "run the tests", "verify the build"
    ]

    private static let multiScopeHints = [
        "并更新", "并补充", "并修复", "并实现", "同时", "以及",
        "and update", "and add", "and fix", "and implement", "as well as"
    ]

    /// Local, deterministic complexity score. Returns `nil` when the user
    /// explicitly opted out of Plan mode (an unconditional "send normally"),
    /// which is distinct from a plain score of 0.
    static func score(
        userText: String,
        attachmentCount: Int = 0,
        includesWorkspaceOverview: Bool = false
    ) -> Int? {
        let normalized = userText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return 0 }
        guard !optOutHints.contains(where: normalized.contains) else { return nil }

        var score = 0

        if strongComplexityHints.contains(where: normalized.contains) {
            score += 2
        }
        if planningHints.contains(where: normalized.contains) {
            score += 2
        }
        if verificationHints.contains(where: normalized.contains) {
            score += 1
        }
        if multiScopeHints.contains(where: normalized.contains) {
            score += 1
        }

        let enumeratedLineCount = normalized
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.first else { return false }
                return first.isNumber || trimmed.hasPrefix("-") || trimmed.hasPrefix("•")
            }
            .count
        if enumeratedLineCount >= 2 {
            score += 2
        }

        if normalized.count >= 700 {
            score += 2
        } else if normalized.count >= 240 {
            score += 1
        }

        if attachmentCount >= 2 || (attachmentCount > 0 && includesWorkspaceOverview) {
            score += 1
        }

        return score
    }

    /// Maps the local score into the three-way preflight decision.
    ///
    /// - `>= minimumScore` (4): locally confident → `.suggest` (no flash call).
    /// - `flashScoreRange` (2...3): locally ambiguous → `.askFlash`.
    /// - below the flash window, or opt-out (`score == nil`): `.skip`.
    static func band(
        userText: String,
        attachmentCount: Int = 0,
        includesWorkspaceOverview: Bool = false
    ) -> AgentPlanModeSuggestionBand {
        guard let score = score(
            userText: userText,
            attachmentCount: attachmentCount,
            includesWorkspaceOverview: includesWorkspaceOverview
        ) else {
            return .skip
        }
        if score >= minimumScore { return .suggest }
        if flashScoreRange.contains(score) { return .askFlash }
        return .skip
    }

    /// Back-compatible boolean preflight: true only when the local score is
    /// confident enough to suggest Plan mode outright (the `.suggest` band).
    static func shouldSuggest(
        userText: String,
        attachmentCount: Int = 0,
        includesWorkspaceOverview: Bool = false
    ) -> Bool {
        band(
            userText: userText,
            attachmentCount: attachmentCount,
            includesWorkspaceOverview: includesWorkspaceOverview
        ) == .suggest
    }
}
