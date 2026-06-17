//
//  DeepResearchWorkflow.swift
//  WillDeep
//
//  /research <query> 入口。5 个搜索 angle 并发 → 1 个 synthesize。
//

import Foundation

struct DeepResearchWorkflow: WorkflowDefinition {
    var name: String { "deep-research" }
    var displayTitle: String { "Deep Research" }
    var slashCommand: String { "/research" }
    var shortDescription: String { "Fan-out web search + synthesize a cited report" }
    var argsPlaceholder: String { "research question…" }
    var maxAgents: Int { 10 }
    var allowsEmptyArgs: Bool { false }

    /// 5 个固定 angle 拆分。比让 LLM 先做一次"拆问题"那一步轻 —— 节省
    /// 一个 round-trip，对绝大多数研究 query 也够覆盖。每个 angle 的
    /// prompt 显式说"web_search 不超过 6 次"，避免子 agent 在网上死循环
    /// 烧 token。
    private let angles: [(label: String, focus: String)] = [
        ("news", "Recent news, announcements, and changelog about"),
        ("docs", "Official docs, technical deep-dives, and design rationale of"),
        ("reviews", "User reviews, forum discussions, and community sentiment about"),
        ("competitors", "Competitors, alternatives, and comparison articles about"),
        ("business", "Pricing, business model, and market position of"),
    ]

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let topic = args.trimmingCharacters(in: .whitespacesAndNewlines)

        // 5 个搜索 agent 并发。
        let searchPrompts = angles.map { angle in
            """
            Research task: \(angle.focus): \(topic).

            Use `web_search` (cap yourself at 6 searches) plus `read_file`
            only if you find references to local files. Pull out concrete
            facts, dates, names, numbers, quotes. Cite every claim with a
            URL.

            Return a tight markdown brief with sections:
            ## Key findings
            (bulleted, each bullet ends with citation URL)
            ## Open questions
            (what you couldn't pin down)
            """
        }

        let searchResults = await engine.parallel(maxConcurrent: 5, searchPrompts.enumerated().map { idx, prompt in
            { @Sendable in
                try await engine.agent(prompt, label: "search:\(self.angles[idx].label)")
            }
        })

        let nonNilResults = searchResults.compactMap { $0 }
        guard !nonNilResults.isEmpty else {
            return "All 5 research angles failed. Try a more specific query."
        }

        // Synthesize.
        let joinedBriefs = nonNilResults.enumerated().map { idx, brief in
            "### Angle \(idx + 1) — \(angles[idx].label)\n\n\(brief)"
        }.joined(separator: "\n\n---\n\n")

        let synthesisPrompt = """
        You are synthesizing 5 parallel research briefs about: \(topic).

        Below are the briefs. Merge them into one report. Deduplicate
        overlapping facts, keep every URL citation, and call out
        contradictions between sources explicitly.

        Output structure (markdown):
        # \(topic) — research summary
        ## TL;DR
        (3-5 sentence executive summary)
        ## What we know
        (grouped by theme, every claim cites a URL)
        ## What's contested
        (sources disagree on …)
        ## Open questions
        (still unanswered)

        Briefs:

        \(joinedBriefs)
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }
}
