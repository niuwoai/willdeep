//
//  AgentSpecGateSignals.swift
//  WillDeep
//
//  Deciding, before the first provider call, whether a request is the kind
//  that deserves a written design before code.
//
//  This has been tried once and removed. 1.211.0-rc6 dropped the standalone
//  Plan mode together with the "complex task" switch suggestion, its eight
//  second countdown, and the plan approval gate. The autopsy is in the
//  plan-on-demand policy: models systematically over-trigger when asked to
//  judge upfront whether work is genuinely multi-step, because planning looks
//  diligent, so every small task paid for a plan.
//
//  The correction is not a better prompt. It is a different decider. The host
//  forms the opinion from signals it can name and test; the model is only
//  ever allowed to take that opinion away (see AgentSpecGateJudge, P4). A
//  model that likes planning cannot promote a one-line fix into a design
//  document, because it is never asked to promote anything.
//
//  Phase 1 records and does not block. The threshold below is a starting
//  guess and is meant to be re-derived from spec-gate.jsonl once real
//  sessions have run through it — the false-positive rate is the gate on
//  shipping the gate. See docs/SPEC_FIRST_GATE_DESIGN.md §11.
//

import Foundation

/// One reason the host thinks a request is design-shaped. The card the user
/// eventually sees renders these directly: "this looked complex" is not an
/// explanation, "you said 先出个方案 and this touches the session archive
/// format" is.
struct AgentSpecGateSignal: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The user asked for a design, a plan, or an assessment in so many words.
        case explicitRequest
        /// A new subsystem, module, or service is being introduced.
        case newSubsystem
        /// Storage format, archive layout, migration, or cross-version compatibility.
        case persistenceChange
        /// Architecture, protocol, or cross-module wording.
        case crossModuleKeywords
        /// More than one delivery surface in the same breath.
        case multiSurface
        /// A wish or a problem statement with nothing concrete to change.
        case vagueGoal

        /// Strong signals stand alone; weak ones need a companion. Keeping
        /// this on the case itself means adding a signal forces the author to
        /// answer "is this enough on its own?" instead of silently landing in
        /// whichever bucket the call site happens to check.
        var isStrong: Bool {
            switch self {
            case .explicitRequest, .newSubsystem, .persistenceChange:
                return true
            case .crossModuleKeywords, .multiSurface, .vagueGoal:
                return false
            }
        }
    }

    let kind: Kind
    /// The matched fragment, trimmed. Evidence the user can check, not a score
    /// they have to trust.
    let evidence: String
}

nonisolated enum AgentSpecGateSignals {
    /// Everything the admission screen reads. Assembled from state the turn
    /// already has, so running it costs nothing beyond the string scan below.
    struct Input: Sendable {
        var requestText: String
        var routeDecision: AgentRequestRouter.Decision?
        var hasWorkspace: Bool
        var isGoalMode: Bool
        var isUnattendedDispatch: Bool

        init(
            requestText: String,
            routeDecision: AgentRequestRouter.Decision? = nil,
            hasWorkspace: Bool = true,
            isGoalMode: Bool = false,
            isUnattendedDispatch: Bool = false
        ) {
            self.requestText = requestText
            self.routeDecision = routeDecision
            self.hasWorkspace = hasWorkspace
            self.isGoalMode = isGoalMode
            self.isUnattendedDispatch = isUnattendedDispatch
        }
    }

    /// Shortest request worth scanning. Below this a message is an aside, a
    /// correction, or "继续" — none of which start design work, and all of
    /// which would otherwise trip `vagueGoal` on a stray 希望.
    static let minimumRequestLength = 12

    /// Longest fragment kept as evidence. Long enough to recognise the
    /// sentence, short enough that the audit log stays readable.
    static let evidenceLimit = 120

    // MARK: - Vocabulary

    private static let explicitRequestTerms = [
        "先出个设计", "先出设计", "先写需求", "先写设计", "出个方案", "做个方案",
        "技术方案", "设计一下", "先别写代码", "先别动代码", "先讨论", "讨论清楚",
        "评估一下怎么做", "先出文档", "写个设计", "设计文档", "需求文档",
        "design doc", "design first", "write a spec", "before you code",
        "don't write code yet", "let's discuss first",
    ]

    private static let newSubsystemTerms = [
        "新增一个子系统", "新的子系统", "新子系统", "新模块", "新增模块", "新服务",
        "新增服务", "从零搭", "从头搭", "搭一套", "做一套", "整套", "一整套",
        "new subsystem", "new module", "new service", "from scratch",
    ]

    private static let persistenceTerms = [
        "存档格式", "落盘格式", "持久化格式", "数据格式", "迁移", "数据迁移",
        "向后兼容", "向前兼容", "跨版本兼容", "schema", "表结构", "改字段",
        "persistence format", "storage format", "migration", "backward compat",
    ]

    private static let crossModuleTerms = [
        "架构", "重构整个", "跨模块", "跨文件", "对外协议", "通信协议", "接口协议",
        "解耦", "分层", "边界", "改造", "整体设计",
        "architecture", "cross-module", "protocol", "refactor the whole",
    ]

    /// Surfaces this product actually ships to. Two or more named together is
    /// the cheapest reliable tell that a change is not local.
    private static let surfaceTerms = [
        "macos", "android", "ios", "网关", "gateway", "插件页", "plugin page",
        "手机端", "移动端", "命令行", "cli", "web", "服务端", "server",
    ]

    private static let wishTerms = [
        "我希望", "我想要", "希望能", "能不能做", "能不能加", "有没有办法",
        "我要的是", "最好能", "想让它", "i want", "i'd like", "it would be nice",
        "can we make", "wish",
    ]

    /// A concrete anchor — a path, an extension, a Type name, a symbol. Its
    /// presence is what separates "会话归档太慢了" (a wish) from
    /// "AgentSessionStore.loadAll 每次全量解码" (a target).
    private static let anchorPattern = try? NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_]*\.(swift|rs|go|ts|tsx|js|json|md|toml|yaml|yml))|(\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\b)|(/[A-Za-z0-9_./-]{4,})|(\w+\(\))"#
    )

    // MARK: - Entry point

    /// Signals present in this request. Empty means "nothing to see", which is
    /// the overwhelmingly common answer and costs one lowercased copy plus a
    /// handful of substring scans.
    static func signals(for input: Input) -> [AgentSpecGateSignal] {
        // Exclusions first: these turns must never gate, so they must never
        // even be measured. Goal mode already runs its own evidence planning
        // gate and two gates would wait on each other; an unattended dispatch
        // child has nobody to review a document; without a workspace there is
        // no docs/ to write into.
        guard !input.isGoalMode,
              !input.isUnattendedDispatch,
              input.hasWorkspace else { return [] }

        let text = input.requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumRequestLength else { return [] }
        let haystack = text.lowercased()

        var found: [AgentSpecGateSignal] = []

        if let hit = firstMatch(in: haystack, original: text, terms: explicitRequestTerms) {
            found.append(AgentSpecGateSignal(kind: .explicitRequest, evidence: hit))
        }
        if let hit = firstMatch(in: haystack, original: text, terms: newSubsystemTerms) {
            found.append(AgentSpecGateSignal(kind: .newSubsystem, evidence: hit))
        }
        if let hit = firstMatch(in: haystack, original: text, terms: persistenceTerms) {
            found.append(AgentSpecGateSignal(kind: .persistenceChange, evidence: hit))
        }
        if let hit = firstMatch(in: haystack, original: text, terms: crossModuleTerms) {
            found.append(AgentSpecGateSignal(kind: .crossModuleKeywords, evidence: hit))
        }
        if let hit = multiSurfaceMatch(in: haystack, original: text) {
            found.append(AgentSpecGateSignal(kind: .multiSurface, evidence: hit))
        }
        if let hit = vagueGoalMatch(in: haystack, original: text) {
            found.append(AgentSpecGateSignal(kind: .vagueGoal, evidence: hit))
        }

        return found
    }

    /// Whether the signals clear the bar: any strong one, or two weak ones.
    /// Deliberately not a score. A number invites tuning by feel; a rule can
    /// be argued with, and every failure lands on a named case.
    static func clearsThreshold(_ signals: [AgentSpecGateSignal]) -> Bool {
        if signals.contains(where: { $0.kind.isStrong }) { return true }
        return signals.count >= 2
    }

    // MARK: - Matching

    private static func firstMatch(
        in haystack: String,
        original: String,
        terms: [String]
    ) -> String? {
        for term in terms where haystack.contains(term) {
            return excerpt(around: term, in: haystack, original: original)
        }
        return nil
    }

    /// Two distinct surfaces named in one request. One surface is just where
    /// the work happens; two is a coordination problem.
    private static func multiSurfaceMatch(in haystack: String, original: String) -> String? {
        var seen: [String] = []
        for term in surfaceTerms where haystack.contains(term) {
            seen.append(term)
            if seen.count >= 2 { break }
        }
        guard seen.count >= 2 else { return nil }
        return excerpt(around: seen[0], in: haystack, original: original)
    }

    /// A wish with no anchor in it. Both halves matter: "我希望 AgentSpecGate
    /// 支持 X" names its target and is ordinary work, while "我希望它别这么卡"
    /// is a problem statement that has to become a requirement before anyone
    /// can implement it.
    private static func vagueGoalMatch(in haystack: String, original: String) -> String? {
        guard let wish = wishTerms.first(where: { haystack.contains($0) }) else { return nil }
        guard !containsAnchor(original) else { return nil }
        return excerpt(around: wish, in: haystack, original: original)
    }

    private static func containsAnchor(_ text: String) -> Bool {
        guard let anchorPattern else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return anchorPattern.firstMatch(in: text, options: [], range: range) != nil
    }

    /// The sentence the term sits in, capped. Offsets come from the lowercased
    /// copy but both strings are the same length only for ASCII, so the slice
    /// is taken from `haystack` and used purely as a human-readable excerpt —
    /// never fed back into matching.
    private static func excerpt(around term: String, in haystack: String, original: String) -> String {
        guard let range = haystack.range(of: term) else {
            return String(original.prefix(evidenceLimit))
        }
        let sentenceBreaks = CharacterSet(charactersIn: "。！？\n.!?;；")
        var start = range.lowerBound
        while start > haystack.startIndex {
            let previous = haystack.index(before: start)
            if let scalar = haystack[previous].unicodeScalars.first,
               sentenceBreaks.contains(scalar) { break }
            start = previous
        }
        var end = range.upperBound
        while end < haystack.endIndex {
            if let scalar = haystack[end].unicodeScalars.first,
               sentenceBreaks.contains(scalar) { break }
            end = haystack.index(after: end)
        }
        let slice = haystack[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return String(slice.prefix(evidenceLimit))
    }
}
