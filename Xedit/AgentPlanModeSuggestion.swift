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

nonisolated enum AgentPlanModeSuggestionPolicy {
    static let minimumScore = 3
    static let autoResolutionSeconds = 8

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

    static func shouldSuggest(
        userText: String,
        attachmentCount: Int = 0,
        includesWorkspaceOverview: Bool = false
    ) -> Bool {
        let normalized = userText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        guard !optOutHints.contains(where: normalized.contains) else { return false }

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

        return score >= minimumScore
    }
}
