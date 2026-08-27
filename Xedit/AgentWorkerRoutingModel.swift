//
//  AgentWorkerRoutingModel.swift
//  WillDeep
//
//  Model-backed worker routing, layered on top of the keyword router.
//
//  `AgentRequestRouter.classify` is a pure keyword matcher — cheap, sync,
//  and deliberately narrow. Measured against 654 real requests it put 85.6%
//  into the two fallback branches (`implementer` at 78 and "nothing fits"
//  at 70) and agreed with the silver labels only 23.1% of the time. Keyword
//  markers cannot read intent; they can only spot vocabulary.
//
//  So the keyword decision keeps the fast path it is good at — every branch
//  that actually matched a marker scores 86 or above and is taken verbatim,
//  costing nothing — and only the fallback branches are escalated to a
//  model. That split matters: consulting a model on every turn would add
//  1.3–2.0s to the 14.4% of requests the keywords already get right.
//
//  The shared client streams chat and takes no response-format argument,
//  and threading a JSON schema through every provider adapter to constrain
//  one auxiliary call is not worth the blast radius. So the reply is
//  constrained by prompt and validated defensively instead: anything that
//  is not a known profile ID is discarded. Every failure — timeout,
//  malformed JSON, unknown ID, and the empty-content reply that local
//  Gemma 4 returns when it gives up — falls back to the keyword decision
//  rather than blocking the turn.
//
//  Local calls already get `reasoning_effort: "none"` from the OpenAI-Chat
//  adapter (see AgentClientOpenAIChat), so a thinking-capable local model
//  answers in one short line instead of spending 1300 characters of
//  reasoning on a classification.
//

import Foundation

nonisolated enum AgentWorkerRoutingModel {
    /// Keyword decisions at or above this confidence matched an actual
    /// marker list and are taken as-is. Below it live exactly the two
    /// fallback branches of `AgentRequestRouter.classify` — `implementer`
    /// (78) and the ambiguous standard-tier decision (70) — which is what
    /// the model is here to improve on.
    static let keywordTrustThreshold = 86

    /// Local small models answer a classification in 1–2s warm. Past this
    /// the turn has waited long enough and the keyword decision wins.
    static let timeout: TimeInterval = 8

    /// Only the request head is classified — the same window the keyword
    /// router reads, so both tiers see the same evidence.
    static let classifiedPrefixLength = 600

    struct Candidate: Equatable, Sendable {
        let id: String
        let purpose: String
    }

    /// Routable trades, each with the one-line purpose the model sees.
    /// `judge`, `security_guard` and the `small_*` variants are deliberately
    /// absent: they are escalation targets chosen by other machinery, not
    /// destinations for a fresh user request.
    static let candidates: [Candidate] = [
        Candidate(id: AgentSubagentProfileCatalog.scoutID,
                  purpose: "定位符号、文件、调用点；只读的代码检索"),
        Candidate(id: AgentSubagentProfileCatalog.readerID,
                  purpose: "阅读并转述已知文件或文档的内容；只读"),
        Candidate(id: AgentSubagentProfileCatalog.logInspectorID,
                  purpose: "解释报错、堆栈、构建或测试的失败输出；只读，不改代码"),
        Candidate(id: AgentSubagentProfileCatalog.gitDetectiveID,
                  purpose: "追溯改动历史、定位引入问题的提交；只读"),
        Candidate(id: AgentSubagentProfileCatalog.testerID,
                  purpose: "运行测试或检查门禁并汇报结果；不修改源码"),
        Candidate(id: AgentSubagentProfileCatalog.reviewerID,
                  purpose: "审查一段改动或代码质量；只读"),
        Candidate(id: AgentSubagentProfileCatalog.terminalOperatorID,
                  purpose: "查看或操作用户可见的终端会话"),
        Candidate(id: AgentSubagentProfileCatalog.opsRunnerID,
                  purpose: "部署、发布、重启线上服务等生产运维动作"),
        Candidate(id: AgentSubagentProfileCatalog.editorID,
                  purpose: "改动明确点名的单个文件"),
        Candidate(id: AgentSubagentProfileCatalog.testFixerID,
                  purpose: "修复失败的测试"),
        Candidate(id: AgentSubagentProfileCatalog.buildFixerID,
                  purpose: "修复编译、链接、依赖导致的构建失败"),
        Candidate(id: AgentSubagentProfileCatalog.implementerID,
                  purpose: "跨多个文件的常规实现与修改")
    ]

    /// The model may also decline: "none" means nothing fits and the
    /// standard tier should proceed without a trade.
    static let noneChoice = "none"

    static var choiceIDs: [String] { candidates.map(\.id) + [noneChoice] }

    static func systemPrompt() -> String {
        let menu = candidates
            .map { "- \($0.id): \($0.purpose)" }
            .joined(separator: "\n")
        return """
        你是任务派发分类器。根据用户请求，从候选 worker 中选出最合适的一个。
        候选：
        \(menu)
        - \(noneChoice): 以上都不合适，或请求过于宽泛无法归类

        判断依据是请求要做的事，不是它提到的词。只输出 JSON，不要解释。
        """
    }

    static func userPrompt(for request: String) -> String {
        "请求：\(String(request.prefix(classifiedPrefixLength)))"
    }

    struct Verdict: Equatable, Sendable {
        /// nil means the model chose `none`.
        let profileID: String?
        let confidence: Int
    }

    /// Parse a raw model reply. Returns nil for every unusable answer —
    /// empty content (what local Gemma 4 returns when it gives up), a
    /// fenced or truncated body, or an ID outside the candidate list.
    static func parseVerdict(_ raw: String) -> Verdict? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = jsonBody(from: trimmed).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let worker = object["worker"] as? String
        else { return nil }

        let confidence = (object["confidence"] as? Int)
            ?? (object["confidence"] as? Double).map(Int.init)
            ?? 0
        if worker == noneChoice { return Verdict(profileID: nil, confidence: confidence) }
        guard candidates.contains(where: { $0.id == worker }) else { return nil }
        return Verdict(profileID: worker, confidence: confidence)
    }

    /// Local models wrap JSON in a ```json fence often enough to be worth
    /// stripping, even with a schema in play.
    private static func jsonBody(from text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Whether this keyword decision should be escalated to the model.
    static func shouldConsultModel(for decision: AgentRequestRouter.Decision) -> Bool {
        decision.confidence < keywordTrustThreshold
    }

    /// Fold a model verdict into the keyword decision. The model only ever
    /// replaces the routed trade; the safety-relevant flags stay under the
    /// keyword router's control, because a mutating request must not become
    /// auto-dispatchable just because a small model felt confident.
    static func merged(
        keyword: AgentRequestRouter.Decision,
        verdict: Verdict
    ) -> AgentRequestRouter.Decision {
        guard let profileID = verdict.profileID else { return keyword }
        var merged = keyword
        merged.profileID = profileID
        merged.reason = "local routing model selected \(profileID)"
        return merged
    }
}
