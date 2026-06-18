//
//  DeepResearchWorkflowTests.swift
//  XeditTests
//
//  1.85.0-rc20:rc20 重写 DeepResearchWorkflow 后的形态回归。
//  端到端冒烟(真跑 web_search + 模型)留给手动 /research,不进 CI;
//  这里只验:
//   1. workflow 元信息没退化(name / slashCommand / argsPlaceholder)。
//   2. 渲染函数对「空结果」「全被 refute」「正常 confirmed」三种终态
//      都能吐合理 markdown,不抛错、不留空段。
//   3. 各 Decodable 输出模型可以从 schema 真正合规的 JSON 反解出来 ——
//      防止重构时 schema 和 Swift Codable 类型对不上。
//

import Foundation
import Testing
@testable import WillDeep

extension WillDeepTests {
    @MainActor
    @Test("DeepResearchWorkflow 元信息没退化")
    func deepResearchWorkflowMetadata() {
        let wf = DeepResearchWorkflow()
        #expect(wf.name == "deep-research")
        #expect(wf.slashCommand == "/research")
        #expect(wf.argsPlaceholder.lowercased().contains("research"))
        #expect(!wf.allowsEmptyArgs)
        #expect(wf.maxAgents >= 40, "rc20 expanded pipeline; want headroom for 3-vote verify fan-out")
    }

    @MainActor
    @Test("renderEmptyReport 给空抓取仍然能出可读 markdown")
    func deepResearchRenderEmptyReport() {
        let md = DeepResearchWorkflow.renderEmptyReport(question: "What is X?", sourcesFetched: 0)
        #expect(md.hasPrefix("# What is X?"))
        #expect(md.contains("No verifiable claims"))
    }

    @MainActor
    @Test("renderAllRefutedReport 列出被 kill 的 claim 给用户审")
    func deepResearchRenderAllRefutedReport() {
        let killed: [DeepResearchWorkflow.VerifiedClaim] = [
            .init(
                base: .init(
                    claim: "X cures everything",
                    quote: "miracle",
                    importance: "central",
                    sourceURL: "https://snakeoil.example/blog",
                    sourceTitle: "Snake Oil Daily",
                    sourceQuality: "blog",
                    angle: "claims"
                ),
                verdicts: [
                    .init(refuted: true, evidence: "no clinical evidence", confidence: "high", counterSource: nil),
                    .init(refuted: true, evidence: "contradicted by NIH", confidence: "high", counterSource: nil),
                    .init(refuted: true, evidence: "marketing claim", confidence: "medium", counterSource: nil),
                ],
                refutedVotes: 3,
                survives: false
            )
        ]
        let md = DeepResearchWorkflow.renderAllRefutedReport(
            question: "Does X cure everything?",
            killed: killed,
            sourcesFetched: 1,
            claimsExtracted: 1
        )
        #expect(md.contains("Inconclusive"))
        #expect(md.contains("X cures everything"))
        #expect(md.contains("snakeoil.example"))
    }

    @MainActor
    @Test("renderFinalReport 包含 TL;DR + findings + sources + stats 各段")
    func deepResearchRenderFinalReport() {
        let confirmed: [DeepResearchWorkflow.VerifiedClaim] = [
            .init(
                base: .init(
                    claim: "Swift 6 ships strict concurrency by default",
                    quote: "Swift 6 enables strict concurrency",
                    importance: "central",
                    sourceURL: "https://swift.org/blog/swift-6",
                    sourceTitle: "Swift 6 release",
                    sourceQuality: "primary",
                    angle: "docs"
                ),
                verdicts: [
                    .init(refuted: false, evidence: "swift.org release post confirms", confidence: "high", counterSource: nil),
                    .init(refuted: false, evidence: "Apple WWDC slide", confidence: "high", counterSource: nil),
                    .init(refuted: false, evidence: "Xcode 16 release notes", confidence: "high", counterSource: nil),
                ],
                refutedVotes: 0,
                survives: true
            )
        ]
        let report = DeepResearchWorkflow.SynthesisOutput(
            summary: "Swift 6 introduces strict concurrency.",
            findings: [
                .init(
                    claim: "Strict concurrency is the default in Swift 6.",
                    confidence: "high",
                    sources: ["https://swift.org/blog/swift-6"],
                    evidence: "Multiple official sources."
                )
            ],
            caveats: "Some migration friction; opt-out available for legacy projects.",
            openQuestions: ["How will downstream libraries adopt the model?"]
        )
        let allSources: [DeepResearchWorkflow.FetchedSource] = [
            .init(
                url: "https://swift.org/blog/swift-6",
                title: "Swift 6 release",
                angle: "docs",
                sourceQuality: "primary",
                publishDate: nil,
                claims: []
            )
        ]
        let md = DeepResearchWorkflow.renderFinalReport(
            question: "What's new in Swift 6?",
            report: report,
            confirmed: confirmed,
            killed: [],
            allSources: allSources
        )
        #expect(md.contains("# What's new in Swift 6?"))
        #expect(md.contains("## TL;DR"))
        #expect(md.contains("strict concurrency"))
        #expect(md.contains("## Findings"))
        #expect(md.contains("**[high]**"))
        #expect(md.contains("## Caveats"))
        #expect(md.contains("## Open questions"))
        #expect(md.contains("## Stats"))
        #expect(md.contains("Sources fetched: 1"))
    }

    @MainActor
    @Test("SynthesisOutput Codable round-trips schema-shaped JSON")
    func deepResearchSynthesisOutputDecodesFromCanonicalJSON() throws {
        let json = """
        {
          "summary": "exec summary",
          "findings": [
            {
              "claim": "claim A",
              "confidence": "high",
              "sources": ["https://a.com"],
              "evidence": "ev A"
            }
          ],
          "caveats": "cave",
          "openQuestions": ["q1", "q2"]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let out = try JSONDecoder().decode(DeepResearchWorkflow.SynthesisOutput.self, from: data)
        #expect(out.summary == "exec summary")
        #expect(out.findings.count == 1)
        #expect(out.findings[0].confidence == "high")
        #expect(out.openQuestions == ["q1", "q2"])
    }

    @MainActor
    @Test("ScopeOutput Codable round-trips schema-shaped JSON")
    func deepResearchScopeOutputDecodesFromCanonicalJSON() throws {
        let json = """
        {
          "question": "Q",
          "summary": "S",
          "angles": [
            {"label": "L1", "query": "Q1", "rationale": "R1"},
            {"label": "L2", "query": "Q2"},
            {"label": "L3", "query": "Q3"}
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let out = try JSONDecoder().decode(DeepResearchWorkflow.ScopeOutput.self, from: data)
        #expect(out.angles.count == 3)
        #expect(out.angles[1].rationale == nil)  // 可选字段
        #expect(out.angles[2].label == "L3")
    }

    @MainActor
    @Test("ExtractOutput.toFetched 把 quality / publishDate / claims 透出来")
    func deepResearchExtractOutputToFetched() {
        let extract = DeepResearchWorkflow.ExtractOutput(
            sourceQuality: "primary",
            publishDate: "2026-01-15",
            claims: [
                .init(claim: "C1", quote: "Q1", importance: "central"),
                .init(claim: "C2", quote: "Q2", importance: "supporting"),
            ]
        )
        let source = DeepResearchWorkflow.SearchResult(
            url: "https://example.com/p1",
            title: "Example",
            snippet: "snippet",
            relevance: "high"
        )
        let fetched = extract.toFetched(source: source, angle: "docs")
        #expect(fetched.url == "https://example.com/p1")
        #expect(fetched.sourceQuality == "primary")
        #expect(fetched.publishDate == "2026-01-15")
        #expect(fetched.angle == "docs")
        #expect(fetched.claims.count == 2)
        #expect(fetched.claims[0].importance == "central")
    }
}
