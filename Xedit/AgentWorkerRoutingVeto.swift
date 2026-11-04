//
//  AgentWorkerRoutingVeto.swift
//  WillDeep
//
//  The local model's veto over privileged keyword routes.
//
//  `AgentWorkerRoutingModel` lets the model pick a trade where keywords had
//  no answer. This file is its mirror image: keywords *did* have an answer,
//  a high-confidence one, and it lands on a privileged destination whose
//  `enforcesDelegatedExecution` is true regardless of policy. A wrong hit
//  there does not merely mislabel the worker — `AgentWorkerRouteGuard`
//  blocks the edit at the tool boundary.
//
//  The asymmetry is the whole design. The model may only answer "no, this
//  is not operations work", which removes privilege; it can never move a
//  request *into* a privileged destination. So the contract's rule —
//  privileged destinations are reachable only by explicit keyword evidence —
//  survives intact: a veto subtracts evidence, it never manufactures any.
//
//  Every unusable answer upholds the keyword decision. A missing Ollama, a
//  timeout, a truncated reply, a model that ignores `think: false` and
//  returns empty content: all of them leave the turn exactly as it is today.
//
//  See docs/WORKER_ROUTING_VETO_DESIGN.md.
//

import Foundation

nonisolated enum AgentWorkerRoutingVeto {
    /// The two destinations whose misroute actually costs the user something.
    /// `test_fixer` / `build_fixer` sit at 96 but do not enforce delegation,
    /// so a wrong guess there is a suboptimal trade, not a blocked edit —
    /// not worth a model round trip.
    static let vetoableProfileIDs: Set<String> = [
        AgentSubagentProfileCatalog.opsRunnerID,
        AgentSubagentProfileCatalog.terminalOperatorID,
    ]

    /// Whether this keyword decision is worth confirming with the model.
    ///
    /// Operator pins are exempt on purpose: the user named the worker, and a
    /// 2B model does not get to overrule an explicit instruction.
    static func shouldRequestVeto(for decision: AgentRequestRouter.Decision) -> Bool {
        guard !decision.isOperatorPinned else { return false }
        guard let profileID = decision.profileID else { return false }
        return vetoableProfileIDs.contains(profileID)
    }

    struct Verdict: Equatable, Sendable {
        /// true keeps the keyword decision; false downgrades it.
        let upheld: Bool
        /// Audit only — never gates the outcome. A model that is unsure is
        /// still answering, and the safe direction is already `upheld`.
        let confidence: Int
    }

    /// Naming the key matters. Local gemma4 answers `{"category":...}` or
    /// `{"task":...}` when the wording does not say which key to use, and a
    /// reply the parser cannot read silently upholds — the feature would
    /// look installed and do nothing. Same lesson as the routing model's
    /// `verdict_format_line`.
    static func systemPrompt() -> String {
        """
        用户向一个编程助手发出了下面的请求。关键词规则判断它属于"生产运维"类工作，
        也就是要在生产环境或用户可见的终端里执行部署、发布、重启服务这类命令。

        请判断这个判断是否正确。判断依据是请求要做的事，不是它提到的词——
        提到 deployment、部署脚本、发布流程的文件名或代码，并不等于要执行部署。
        修改文件、阅读代码、解释配置、查看状态，都不是生产运维。

        只输出 JSON，不要解释。格式：{"upheld":true或false,"confidence":0到100的整数}
        """
    }

    static func userPrompt(for request: String) -> String {
        "请求：\(String(request.prefix(AgentWorkerRoutingModel.classifiedPrefixLength)))"
    }

    /// Why an answer could not be used. Carried into the audit log so a
    /// silently-failing model is visible as a pattern rather than as an
    /// absence of records — the failure mode this design is most exposed to
    /// is a model that ignores `think: false`, returns empty content, and
    /// upholds every single time.
    enum Unusable: String, Sendable, Error {
        case emptyContent = "empty_content"
        case malformedJSON = "malformed_json"
        case missingField = "missing_upheld_field"
    }

    /// Parse a raw reply. Returns the verdict, or the reason it is unusable.
    /// Never throws and never returns "downgrade" for an answer it could not
    /// read: every failure path upholds.
    static func parseVerdict(_ raw: String) -> Result<Verdict, Unusable> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyContent) }
        guard let data = jsonBody(from: trimmed).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(.malformedJSON) }

        // 只认真正的布尔和这两个字符串。把任何拿不准的东西解释成 false，
        // 就等于让一次含糊回答撤掉特权保护。
        //
        // 必须走 CFBooleanGetTypeID 而不是 `as? Bool`：JSONSerialization 把
        // JSON 数字桥接成 NSNumber，而 `NSNumber as? Bool` 对 `1` 会成功并
        // 返回 true。写成 `case let value as Bool` 时，`{"upheld":1}` 会被
        // 当成一次合法的「维持」——方向恰好相反的那次更危险：`0` 会变成
        // 一次凭空的否决。
        let upheld: Bool
        switch object["upheld"] {
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            upheld = value.boolValue
        case let value as String where value.lowercased() == "true":
            upheld = true
        case let value as String where value.lowercased() == "false":
            upheld = false
        default:
            return .failure(.missingField)
        }

        let rawConfidence = (object["confidence"] as? Int)
            ?? (object["confidence"] as? Double).map(Int.init)
            ?? 0
        return .success(Verdict(upheld: upheld, confidence: min(max(rawConfidence, 0), 100)))
    }

    private static func jsonBody(from text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// An in-flight veto confirmation, owned by the turn that started it.
    ///
    /// Turn-owned on purpose, like the speculative scout: this must never
    /// enter the registry's background wake-up channels, or a late answer
    /// would start another model turn after the current one ended.
    /// Expired means discarded, never resumed.
    struct Ticket {
        let requestText: String
        let keywordDecision: AgentRequestRouter.Decision
        let startedAt: Date
        let model: String
        let task: Task<Result<Verdict, Unusable>, Never>

        /// Remaining budget before the turn stops waiting. The deadline is
        /// measured from when the veto started, not from when someone asks:
        /// a veto that began with the first provider request has usually
        /// already landed by the first tool boundary, and whatever is left
        /// is all the turn should still spend.
        var remainingBudget: TimeInterval {
            max(0, AgentWorkerRoutingModel.timeout - Date().timeIntervalSince(startedAt))
        }
    }

    /// The downgraded decision for a vetoed request.
    ///
    /// Deliberately a second pass over the same keyword table rather than
    /// anything the model said: the result is deterministic, reproducible
    /// from the request text alone, and cannot name a privileged profile.
    static func downgradedDecision(
        for requestText: String,
        delegationPolicy: AgentDelegationPolicy,
        sharedConfig: AgentSharedRuntimeConfig = .load()
    ) -> AgentRequestRouter.Decision? {
        AgentRequestRouter.routedDecision(
            for: requestText,
            delegationPolicy: delegationPolicy,
            sharedConfig: sharedConfig,
            skippingPrivilegedBranches: true
        )
    }
}
