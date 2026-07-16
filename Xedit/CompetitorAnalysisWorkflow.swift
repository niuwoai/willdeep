//
//  CompetitorAnalysisWorkflow.swift
//  WillDeep
//
//  /competitor <name1, name2, …> 入口。每个产品 1 个搜索 agent 并发，
//  1 个 synthesize agent 出对比表。
//

import Foundation

struct CompetitorAnalysisWorkflow: WorkflowDefinition {
    var name: String { "competitor-analysis" }
    var displayTitle: String { "Competitor Analysis" }
    var slashCommand: String { "/competitor" }
    var shortDescription: String { "Compare named products side-by-side" }
    var argsPlaceholder: String { "product names, comma-separated" }
    var maxAgents: Int { 6 }
    var allowsEmptyArgs: Bool { false }

    private let maxCompetitors = 5

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let products = args
            .split(whereSeparator: { ",;，；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(maxCompetitors)

        guard !products.isEmpty else {
            return "No product names parsed. Use `/competitor Notion, Obsidian, Logseq`."
        }

        let scoutPrompts = products.map { product in
            """
            Research the product **\(product)** for a competitive overview.

            Use `web_search` (cap yourself at 5 searches). Pull the
            following into your brief:
            - Category / what it does (1 line)
            - Key features (3-5 bullets)
            - Pricing model + 2-3 representative price points
            - Notable strengths (what users praise)
            - Notable weaknesses (what users complain about)
            - Recent shipping cadence / how active it is
            - Founder / company / team size if findable
            - URL to its homepage

            Cite at least one URL per bullet group. Brief should be
            ≤300 words.
            """
        }

        let briefs = try await engine.parallel(maxConcurrent: products.count, scoutPrompts.enumerated().map { idx, prompt in
            { @Sendable in
                try await engine.agent(prompt, label: "scout:\(products[products.index(products.startIndex, offsetBy: idx)])")
            }
        })

        let nonNil = zip(products, briefs).compactMap { name, brief -> (String, String)? in
            guard let brief else { return nil }
            return (String(name), brief)
        }
        guard !nonNil.isEmpty else {
            return "All \(products.count) scouts failed. Check network access for the agent."
        }

        let joinedBriefs = nonNil.map { name, brief in
            "### \(name)\n\n\(brief)"
        }.joined(separator: "\n\n---\n\n")

        let synthesizePrompt = """
        Below are research briefs for \(nonNil.count) products. Produce
        a competitive comparison.

        Output structure (markdown):
        # Competitor analysis — \(nonNil.map(\.0).joined(separator: " vs "))

        ## At-a-glance comparison table
        | Product | Category | Pricing | Strength | Weakness |
        | --- | --- | --- | --- | --- |
        (one row per product, terse)

        ## Per-product depth
        (1 paragraph per product, citing URLs)

        ## Where they differ most
        (what dimensions split them — call out 3-5 axes with concrete differences)

        ## Honest take
        (2-3 sentence opinion: who should pick which, who shouldn't bother)

        Briefs:

        \(joinedBriefs)
        """

        return try await engine.agent(synthesizePrompt, label: "synthesize")
    }
}
