//
//  AgentPlanContinuation.swift
//  WillDeep
//
//  Deterministic handling for short operator replies that approve an already
//  proposed Plan. This lives in the host instead of relying on the model to
//  infer whether "继续" means "execute" or "draft another plan".
//

import Foundation

nonisolated enum AgentPlanContinuationPolicy {
    private static let compactApprovalPhrases: Set<String> = [
        "继续",
        "继续执行",
        "执行",
        "执行吧",
        "开始",
        "开始吧",
        "开始执行",
        "按计划执行",
        "按这个计划执行",
        "按照计划执行",
        "按照这个计划执行",
        "照计划执行",
        "就按计划执行",
        "就按这个计划执行",
        "可以继续",
        "可以执行",
        "可以开始",
        "好的继续",
        "好的执行",
        "好的开始",
        "好的开始吧",
        "没问题继续",
        "没问题执行",
        "没问题开始",
        "确认执行",
        "批准执行",
        "同意执行",
    ]

    private static let wordApprovalPhrases: Set<String> = [
        "continue",
        "proceed",
        "execute",
        "execute it",
        "start",
        "start execution",
        "go ahead",
        "go ahead and execute",
        "proceed with the plan",
        "execute the plan",
        "follow the plan",
        "implement the plan",
        "approve",
        "approved",
        "yes proceed",
        "yes execute",
        "ok proceed",
        "okay proceed",
        "looks good proceed",
        "looks good go ahead",
    ]

    static func isExplicitApproval(_ text: String) -> Bool {
        let words = normalizedWords(text)
        guard !words.isEmpty else { return false }
        if wordApprovalPhrases.contains(words) {
            return true
        }
        return compactApprovalPhrases.contains(words.replacingOccurrences(of: " ", with: ""))
    }

    /// An approved Plan remains the execution contract until progress marks
    /// it done or the operator rejects it. A complex follow-up must not
    /// trigger the automatic Plan-mode preflight and silently replace it.
    static func hasActiveExecutionContract(_ plan: AgentPlan?) -> Bool {
        guard let plan else { return false }
        return plan.status == .approved || plan.status == .executing
    }

    /// Delegated CLI executors cannot rely on the native system prompt, so
    /// carry the approved Plan in the task text that is handed to them.
    static func delegatedExecutionTask(
        userText: String,
        currentPlan: AgentPlan?
    ) -> String {
        guard let currentPlan,
              currentPlan.status == .approved || currentPlan.status == .executing else {
            return userText
        }

        let steps = currentPlan.steps.enumerated()
            .map { "\($0.offset + 1). [\($0.element.status.rawValue)] \($0.element.text)" }
            .joined(separator: "\n")
        let summary = currentPlan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryBlock = summary.isEmpty ? "" : "\nPlan summary: \(summary)"
        return """
        \(userText)

        === APPROVED WILLDEEP PLAN — EXECUTE, DO NOT RE-PLAN ===\(summaryBlock)
        \(steps)

        The operator has approved this Plan. Execute these steps end-to-end and report verified progress; do not replace it with another plan.
        """
    }

    private static func normalizedWords(_ text: String) -> String {
        let lowered = text.lowercased()
        let punctuationAsSpaces = lowered.unicodeScalars.map { scalar -> String in
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        return punctuationAsSpaces
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

extension AppState {
    /// Promote a proposed Plan to the executable Normal-mode contract when
    /// the operator sends an unambiguous short approval. Re-evaluated at the
    /// real dispatch boundary so a message queued before Plan synthesis
    /// finished still observes the newly proposed Plan.
    @discardableResult
    func applyExplicitPlanContinuationIfNeeded(
        for runtime: AgentRuntime,
        text: String,
        hasAttachments: Bool,
        source: AgentMessageSource
    ) -> Bool {
        guard source == .operatorInput,
              !hasAttachments,
              runtime.interactionMode == .plan,
              var plan = runtime.currentPlan,
              plan.status == .proposed,
              AgentPlanContinuationPolicy.isExplicitApproval(text) else {
            return false
        }

        plan.status = .approved
        runtime.currentPlan = plan
        runtime.interactionMode = .normal
        runtime.goalTurnRecoveryCheckpoint = nil
        return true
    }
}
