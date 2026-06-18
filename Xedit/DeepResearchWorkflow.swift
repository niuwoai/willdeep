//
//  DeepResearchWorkflow.swift
//  WillDeep
//
//  /research <query> 入口。
//
//  1.85.0-rc20 重写:从原本「5 个写死 angle 并发 → 1 个 synthesize」
//  升到「scope → pipeline(search → URL-dedup → fetch+extract) → 3-vote
//  adversarial verify → synthesize」全套结构化管线,赶上 Claude Code
//  `/deep-research` 的对抗性验证能力。
//
//  关键差异(对比 rc19 之前版本):
//   1. **动态 angle 拆分**:scope agent 按问题领域吐 3-6 个 angle,不再
//      写死 news/docs/reviews/competitors/business 五件套。
//   2. **每个 source 独立 extract**:fetch+extract agent 给每个 URL 拉
//      页面、评源质量(primary/secondary/blog/forum/unreliable)、提
//      falsifiable claim + verbatim 引文 + importance。
//   3. **对抗性验证**:每条 claim 派 3 个 skeptic 默认 refute,≥2 票
//      kill。这是「报告里那条声明能不能信」的关键过滤层 —— rc19 之前
//      靠 synthesis agent 自己「合并矛盾」,没有主动反驳环节。
//   4. **跨阶段 shared state**:URL dedup map + fetch budget counter 走
//      [WorkflowState](Xedit/WorkflowState.swift),pipeline item 并发更
//      新不打架。
//   5. **schema 强约束**:每个 agent 用 [AgentStructuredSchema](Xedit/AgentStructuredSchema.swift)
//      锁住输出形态,模型出格直接被 validator 揍回去重试。
//

import Foundation

struct DeepResearchWorkflow: WorkflowDefinition {
    var name: String { "deep-research" }
    var displayTitle: String { "Deep Research" }
    var slashCommand: String { "/research" }
    var shortDescription: String { "Adversarially-verified multi-angle web research" }
    var argsPlaceholder: String { "research question…" }
    var maxAgents: Int { 80 }
    var allowsEmptyArgs: Bool { false }

    // 数值参数集中放头部,改起来方便。
    private let votesPerClaim = 3
    private let refutationsRequired = 2
    private let maxFetchBudget = 15
    private let maxVerifyClaims = 25
    private let maxSearchConcurrency = 5
    private let maxFetchConcurrency = 6
    private let maxVerifyConcurrency = 8

    // MARK: - Run

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let question = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw WorkflowError.missingArgs(workflow: name)
        }

        // Phase 0 — Scope: 把问题拆成 3-6 个互补 angle。
        let scope = try await engine.agent(
            scopePrompt(question: question),
            label: "scope",
            schema: scopeSchema,
            decode: ScopeOutput.self
        )

        // Shared state:URL dedup + fetch budget。pipeline item 并发更新。
        let dedup = WorkflowState(DedupState(seen: [], remainingFetchSlots: maxFetchBudget))

        // Phase 1 — Pipeline: per-angle search → URL-dedup → fetch+extract。
        // item-level 不 barrier,某个 angle search 慢 不挡其他 angle 进 fetch。
        let perAngle = await engine.pipeline(
            scope.angles,
            maxConcurrent: maxSearchConcurrency
        ) { angle, _ in
            // Stage 1: search this angle。
            let search = try await engine.agent(
                self.searchPrompt(question: question, angle: angle),
                label: "search:\(angle.label)",
                schema: self.searchSchema,
                decode: SearchOutput.self
            )

            // Stage 2: dedup + budget check。
            let novel: [SearchResult] = await dedup.update { state -> [SearchResult] in
                var picks: [SearchResult] = []
                // 按 relevance 排:high → medium → low,预算不够先掉低相关。
                let sorted = search.results.sorted { Self.relevanceRank($0.relevance) < Self.relevanceRank($1.relevance) }
                for result in sorted {
                    let key = Self.normalizedURL(result.url)
                    if state.seen.contains(key) { continue }
                    if state.remainingFetchSlots <= 0,
                       Self.relevanceRank(result.relevance) >= 1 {
                        // 预算用完了只放 high relevance 的进。
                        continue
                    }
                    state.seen.insert(key)
                    state.remainingFetchSlots -= 1
                    picks.append(result)
                }
                return picks
            }

            // Stage 3: fetch+extract 每个 novel source(item 内部 parallel)。
            let extracted = await engine.parallel(
                maxConcurrent: self.maxFetchConcurrency,
                novel.map { source in
                    { @Sendable in
                        try await engine.agent(
                            self.fetchPrompt(question: question, source: source, angle: angle.label),
                            label: "fetch:\(Self.host(of: source.url))",
                            schema: self.extractSchema,
                            decode: ExtractOutput.self
                        )
                        .toFetched(source: source, angle: angle.label)
                    }
                }
            )

            return extracted.compactMap { $0 }
        }

        // Flatten 所有 angle 的 fetched sources。
        let allSources: [FetchedSource] = perAngle.compactMap { $0 }.flatMap { $0 }
        let allClaims: [PendingClaim] = allSources.flatMap { source in
            source.claims.map { claim in
                PendingClaim(
                    claim: claim.claim,
                    quote: claim.quote,
                    importance: claim.importance,
                    sourceURL: source.url,
                    sourceTitle: source.title,
                    sourceQuality: source.sourceQuality,
                    angle: source.angle
                )
            }
        }

        if allClaims.isEmpty {
            return Self.renderEmptyReport(
                question: question,
                sourcesFetched: allSources.count
            )
        }

        // Phase 2 — Verify: 排序取 top N,每条 claim 3 票 adversarial。
        let ranked = allClaims
            .sorted { Self.importanceRank($0.importance) < Self.importanceRank($1.importance) }
            .prefix(maxVerifyClaims)

        let verified = await engine.parallel(
            maxConcurrent: maxVerifyConcurrency,
            ranked.map { claim in
                { @Sendable in
                    let verdicts = await engine.parallel(
                        maxConcurrent: self.votesPerClaim,
                        (0..<self.votesPerClaim).map { voteIndex in
                            { @Sendable in
                                try await engine.agent(
                                    self.verifyPrompt(question: question, claim: claim, voteIndex: voteIndex),
                                    label: "verify:\(claim.claim.prefix(36))…(\(voteIndex + 1)/\(self.votesPerClaim))",
                                    schema: self.verdictSchema,
                                    decode: VerdictOutput.self
                                )
                            }
                        }
                    )
                    let valid = verdicts.compactMap { $0 }
                    let refutedCount = valid.filter { $0.refuted }.count
                    // 抽弃票数(被 user skip / agent 报错的) 算 abstain。
                    // valid 不够 quorum 或 refute 数过线 → 本条 claim 不能进报告。
                    let survives = valid.count >= self.refutationsRequired && refutedCount < self.refutationsRequired
                    return VerifiedClaim(
                        base: claim,
                        verdicts: valid,
                        refutedVotes: refutedCount,
                        survives: survives
                    )
                }
            }
        ).compactMap { $0 }

        let confirmed = verified.filter { $0.survives }
        let killed = verified.filter { !$0.survives }

        if confirmed.isEmpty {
            return Self.renderAllRefutedReport(
                question: question,
                killed: killed,
                sourcesFetched: allSources.count,
                claimsExtracted: allClaims.count
            )
        }

        // Phase 3 — Synthesize: 合并语义重复、按 confidence 排、cite。
        let report = try await engine.agent(
            synthesisPrompt(question: question, confirmed: confirmed, killed: killed),
            label: "synthesize",
            schema: reportSchema,
            decode: SynthesisOutput.self
        )

        return Self.renderFinalReport(
            question: question,
            report: report,
            confirmed: confirmed,
            killed: killed,
            allSources: allSources
        )
    }

    // MARK: - Output models (Decodable)

    struct ScopeOutput: Decodable {
        struct Angle: Decodable, Sendable {
            let label: String
            let query: String
            let rationale: String?
        }
        let question: String
        let summary: String
        let angles: [Angle]
    }

    struct SearchOutput: Decodable {
        let results: [SearchResult]
    }

    struct SearchResult: Decodable, Sendable {
        let url: String
        let title: String
        let snippet: String?
        /// "high" / "medium" / "low" —— schema enum 已经锁死。
        let relevance: String
    }

    struct ExtractOutput: Decodable, Sendable {
        struct ExtractedClaim: Decodable, Sendable {
            let claim: String
            let quote: String
            /// "central" / "supporting" / "tangential"
            let importance: String
        }
        let sourceQuality: String   // primary / secondary / blog / forum / unreliable
        let publishDate: String?
        let claims: [ExtractedClaim]

        enum CodingKeys: String, CodingKey {
            case sourceQuality, publishDate, claims
        }

        func toFetched(source: SearchResult, angle: String) -> FetchedSource {
            FetchedSource(
                url: source.url,
                title: source.title,
                angle: angle,
                sourceQuality: sourceQuality,
                publishDate: publishDate,
                claims: claims
            )
        }
    }

    struct FetchedSource: Sendable {
        let url: String
        let title: String
        let angle: String
        let sourceQuality: String
        let publishDate: String?
        let claims: [ExtractOutput.ExtractedClaim]
    }

    struct PendingClaim: Sendable {
        let claim: String
        let quote: String
        let importance: String
        let sourceURL: String
        let sourceTitle: String
        let sourceQuality: String
        let angle: String
    }

    struct VerdictOutput: Decodable, Sendable {
        let refuted: Bool
        let evidence: String
        /// "high" / "medium" / "low"
        let confidence: String
        let counterSource: String?
    }

    struct VerifiedClaim {
        let base: PendingClaim
        let verdicts: [VerdictOutput]
        let refutedVotes: Int
        let survives: Bool
    }

    struct SynthesisOutput: Decodable {
        struct Finding: Decodable {
            let claim: String
            /// "high" / "medium" / "low"
            let confidence: String
            let sources: [String]
            let evidence: String
        }
        let summary: String
        let findings: [Finding]
        let caveats: String
        let openQuestions: [String]?
    }

    // MARK: - Schemas

    private var scopeSchema: AgentStructuredSchema {
        AgentStructuredSchema(
            type: .object,
            properties: [
                "question": AgentStructuredSchema(type: .string),
                "summary": AgentStructuredSchema(type: .string),
                "angles": AgentStructuredSchema(
                    type: .array,
                    items: AgentStructuredSchema(
                        type: .object,
                        properties: [
                            "label": AgentStructuredSchema(type: .string),
                            "query": AgentStructuredSchema(type: .string),
                            "rationale": AgentStructuredSchema(type: .string),
                        ],
                        required: ["label", "query"]
                    ),
                    minItems: 3,
                    maxItems: 6
                ),
            ],
            required: ["question", "summary", "angles"]
        )
    }

    private var searchSchema: AgentStructuredSchema {
        AgentStructuredSchema(
            type: .object,
            properties: [
                "results": AgentStructuredSchema(
                    type: .array,
                    items: AgentStructuredSchema(
                        type: .object,
                        properties: [
                            "url": AgentStructuredSchema(type: .string),
                            "title": AgentStructuredSchema(type: .string),
                            "snippet": AgentStructuredSchema(type: .string),
                            "relevance": AgentStructuredSchema(
                                type: .string,
                                enumValues: [.string("high"), .string("medium"), .string("low")]
                            ),
                        ],
                        required: ["url", "title", "relevance"]
                    ),
                    maxItems: 6
                ),
            ],
            required: ["results"]
        )
    }

    private var extractSchema: AgentStructuredSchema {
        AgentStructuredSchema(
            type: .object,
            properties: [
                "sourceQuality": AgentStructuredSchema(
                    type: .string,
                    enumValues: [
                        .string("primary"), .string("secondary"), .string("blog"),
                        .string("forum"), .string("unreliable"),
                    ]
                ),
                "publishDate": AgentStructuredSchema(type: .string),
                "claims": AgentStructuredSchema(
                    type: .array,
                    items: AgentStructuredSchema(
                        type: .object,
                        properties: [
                            "claim": AgentStructuredSchema(type: .string),
                            "quote": AgentStructuredSchema(type: .string),
                            "importance": AgentStructuredSchema(
                                type: .string,
                                enumValues: [.string("central"), .string("supporting"), .string("tangential")]
                            ),
                        ],
                        required: ["claim", "quote", "importance"]
                    ),
                    maxItems: 5
                ),
            ],
            required: ["sourceQuality", "claims"]
        )
    }

    private var verdictSchema: AgentStructuredSchema {
        AgentStructuredSchema(
            type: .object,
            properties: [
                "refuted": AgentStructuredSchema(type: .boolean),
                "evidence": AgentStructuredSchema(type: .string),
                "confidence": AgentStructuredSchema(
                    type: .string,
                    enumValues: [.string("high"), .string("medium"), .string("low")]
                ),
                "counterSource": AgentStructuredSchema(type: .string),
            ],
            required: ["refuted", "evidence", "confidence"]
        )
    }

    private var reportSchema: AgentStructuredSchema {
        AgentStructuredSchema(
            type: .object,
            properties: [
                "summary": AgentStructuredSchema(type: .string),
                "findings": AgentStructuredSchema(
                    type: .array,
                    items: AgentStructuredSchema(
                        type: .object,
                        properties: [
                            "claim": AgentStructuredSchema(type: .string),
                            "confidence": AgentStructuredSchema(
                                type: .string,
                                enumValues: [.string("high"), .string("medium"), .string("low")]
                            ),
                            "sources": AgentStructuredSchema(
                                type: .array,
                                items: AgentStructuredSchema(type: .string)
                            ),
                            "evidence": AgentStructuredSchema(type: .string),
                        ],
                        required: ["claim", "confidence", "sources", "evidence"]
                    )
                ),
                "caveats": AgentStructuredSchema(type: .string),
                "openQuestions": AgentStructuredSchema(
                    type: .array,
                    items: AgentStructuredSchema(type: .string)
                ),
            ],
            required: ["summary", "findings", "caveats"]
        )
    }

    // MARK: - Prompts

    private func scopePrompt(question: String) -> String {
        """
        ## Research scope agent

        ## Question
        \(question)

        ## Task
        Decompose this research question into 3-6 complementary web search angles. Pick angles that suit the question's domain. Examples:
        - broad/primary  ·  academic/technical  ·  recent news  ·  contrarian/skeptical  ·  practitioner/implementation
        - For medical: anatomy / common causes / serious differentials / authoritative refs / red flags
        - For tech: state-of-art / benchmarks / limitations / industry adoption / cost+tradeoffs

        Make queries specific enough to surface high-signal results. Avoid redundancy.
        Return: the question (verbatim or lightly normalized), a 1-2 sentence decomposition strategy, and the angles.
        """
    }

    private func searchPrompt(question: String, angle: ScopeOutput.Angle) -> String {
        """
        ## Web Searcher: \(angle.label)

        Research question: "\(question)"
        Your angle: **\(angle.label)** — \(angle.rationale ?? "")
        Search query: `\(angle.query)`

        ## Task
        Use `web_search` with the query above (or a refined version). Return the top 4-6 most relevant results.
        Rank by relevance to the ORIGINAL question, not just the search query. Skip obvious SEO spam / content farms.
        Each result needs: url, title, snippet (1-line gist), relevance (high/medium/low).
        """
    }

    private func fetchPrompt(question: String, source: SearchResult, angle: String) -> String {
        """
        ## Source Extractor

        Research question: "\(question)"

        Fetch and extract key claims from this source:
        **URL:** \(source.url)
        **Title:** \(source.title)
        **Found via:** \(angle) search

        ## Task
        1. Use `web_search` (NOT web_fetch — not available) to look up the URL's content if needed; or work from the snippet if the page can't be fetched directly.
        2. Assess source quality: primary (research/institution), secondary (mainstream reporting), blog (opinion piece), forum (discussion), unreliable (SEO spam / paywalled / unclear).
        3. Extract 2-5 FALSIFIABLE claims that bear on the research question. Each claim MUST:
           - be a concrete, checkable statement (not vague generalities)
           - include a direct verbatim quote from the source as supporting evidence
           - be rated central / supporting / tangential to the research question
        4. Note publish date if available.

        If the source is irrelevant / paywalled / SEO spam → return claims: [] and sourceQuality: "unreliable".
        """
    }

    private func verifyPrompt(question: String, claim: PendingClaim, voteIndex: Int) -> String {
        """
        ## Adversarial Claim Verifier (voter \(voteIndex + 1)/\(votesPerClaim))

        Be SKEPTICAL. Try to REFUTE this claim. ≥\(refutationsRequired)/\(votesPerClaim) refutations kill it.

        ## Research question
        \(question)

        ## Claim under review
        "\(claim.claim)"

        **Source:** \(claim.sourceURL) (\(claim.sourceQuality))
        **Supporting quote:** "\(claim.quote)"

        ## Checklist
        1. Is the claim actually supported by the quote, or is it an overreach / misread?
        2. `web_search` for contradicting evidence — does any credible source dispute or heavily qualify this?
        3. Is the source quality sufficient for the claim's strength? (extraordinary claims need primary sources)
        4. Is the claim outdated? (check dates — old claims about fast-moving fields are suspect)
        5. Is this a marketing claim / press release / cherry-picked benchmark / forum speculation?

        **refuted = true** if: unsupported by quote / contradicted / low-quality source for strong claim / outdated / marketing fluff.
        **refuted = false** ONLY if: claim is well-supported, current, and source quality matches claim strength.
        Default to refuted = true if uncertain.

        Evidence MUST be specific (cite what changed your mind, e.g. a counter URL).
        """
    }

    private func synthesisPrompt(question: String, confirmed: [VerifiedClaim], killed: [VerifiedClaim]) -> String {
        let confirmedBlock = confirmed.enumerated().map { idx, c in
            let bestVerdict = c.verdicts.filter { !$0.refuted }
                .sorted { Self.confidenceRank($0.confidence) < Self.confidenceRank($1.confidence) }
                .first
            return """
            ### [\(idx)] \(c.base.claim)
            Vote: \(c.verdicts.count - c.refutedVotes)-\(c.refutedVotes) · Source: \(c.base.sourceURL) (\(c.base.sourceQuality))
            Quote: "\(c.base.quote)"
            Verifier evidence (\(bestVerdict?.confidence ?? "n/a")): \(bestVerdict?.evidence ?? "(no surviving verdict)")
            """
        }.joined(separator: "\n\n")

        let killedBlock = killed.isEmpty ? "" : """

        ## Refuted claims (for transparency, not for the report)
        \(killed.map { "- \"\($0.base.claim)\" (\($0.base.sourceURL), vote \($0.verdicts.count - $0.refutedVotes)-\($0.refutedVotes))" }.joined(separator: "\n"))
        """

        return """
        ## Synthesis: research report

        **Question:** \(question)

        \(confirmed.count) claims survived \(votesPerClaim)-vote adversarial verification. Merge semantic duplicates and synthesize.

        ## Confirmed claims
        \(confirmedBlock)
        \(killedBlock)

        ## Instructions
        1. Identify claims that say the same thing — merge them, combine their sources.
        2. Group related claims into coherent findings. Each finding should directly address the research question.
        3. Assign confidence per finding: high (multiple primary sources, unanimous votes), medium (secondary sources or split votes), low (single source or blog-quality).
        4. Write a 3-5 sentence executive summary answering the research question.
        5. Note caveats: what's uncertain, what sources were weak, what time-sensitivity applies.
        6. List 2-4 open questions that emerged but weren't answered.
        """
    }

    // MARK: - Renderers

    static func renderEmptyReport(question: String, sourcesFetched: Int) -> String {
        """
        # \(question) — research summary

        No verifiable claims extracted. \(sourcesFetched) sources fetched, all empty or unreliable.

        Try: a more specific question, a different time window, or check the configured search provider's quota.
        """
    }

    static func renderAllRefutedReport(question: String, killed: [VerifiedClaim], sourcesFetched: Int, claimsExtracted: Int) -> String {
        """
        # \(question) — research summary

        ## Inconclusive

        \(killed.count) claims were extracted and all \(killed.count) were refuted by adversarial verification — the available sources may be low-quality or the claims may be overstated.

        ## Stats
        - Sources fetched: \(sourcesFetched)
        - Claims extracted: \(claimsExtracted)
        - Claims verified (all refuted): \(killed.count)

        ## Refuted (for transparency)
        \(killed.prefix(10).map { "- \"\($0.base.claim)\" (\($0.base.sourceURL), vote \($0.verdicts.count - $0.refutedVotes)-\($0.refutedVotes))" }.joined(separator: "\n"))
        """
    }

    static func renderFinalReport(
        question: String,
        report: SynthesisOutput,
        confirmed: [VerifiedClaim],
        killed: [VerifiedClaim],
        allSources: [FetchedSource]
    ) -> String {
        var sections: [String] = []
        sections.append("# \(question) — research summary")
        sections.append("## TL;DR\n\n\(report.summary)")

        if !report.findings.isEmpty {
            var findingsBlock = "## Findings\n"
            for finding in report.findings {
                let cites = finding.sources.map { "[\($0)](\($0))" }.joined(separator: ", ")
                findingsBlock += "\n- **[\(finding.confidence)]** \(finding.claim)  \n  _Evidence:_ \(finding.evidence)  \n  _Sources:_ \(cites)\n"
            }
            sections.append(findingsBlock)
        }

        if !report.caveats.isEmpty {
            sections.append("## Caveats\n\n\(report.caveats)")
        }

        if let openQ = report.openQuestions, !openQ.isEmpty {
            sections.append("## Open questions\n\n" + openQ.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !killed.isEmpty {
            sections.append("## Refuted claims (for transparency)\n\n" + killed.prefix(10).map {
                "- \"\($0.base.claim)\" — vote \($0.verdicts.count - $0.refutedVotes)-\($0.refutedVotes), source: \($0.base.sourceURL)"
            }.joined(separator: "\n"))
        }

        sections.append("""
        ## Stats
        - Sources fetched: \(allSources.count)
        - Claims verified: \(confirmed.count) confirmed · \(killed.count) refuted
        """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private struct DedupState: Sendable {
        var seen: Set<String>
        var remainingFetchSlots: Int
    }

    private static func normalizedURL(_ url: String) -> String {
        if let parsed = URL(string: url),
           let host = parsed.host?.replacingOccurrences(of: "www.", with: "") {
            let path = parsed.path.hasSuffix("/") ? String(parsed.path.dropLast()) : parsed.path
            return "\(host)\(path)".lowercased()
        }
        return url.lowercased()
    }

    private static func host(of url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "unknown"
    }

    private static func relevanceRank(_ relevance: String) -> Int {
        switch relevance.lowercased() {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 3
        }
    }

    private static func importanceRank(_ importance: String) -> Int {
        switch importance.lowercased() {
        case "central": return 0
        case "supporting": return 1
        case "tangential": return 2
        default: return 3
        }
    }

    private static func confidenceRank(_ confidence: String) -> Int {
        switch confidence.lowercased() {
        case "high": return 0
        case "medium": return 1
        case "low": return 2
        default: return 3
        }
    }
}
