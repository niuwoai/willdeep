//
//  RoundtableSetupAndAnalysisTests.swift
//  WillDeepTests
//
//  专家圆桌会前准备、阵容边界与两阶段发言分析的独立验收测试。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct RoundtableSetupAndAnalysisTests {
    @Test("preparation selection keeps order, removes duplicates, and caps at six")
    func preparationSelectionNormalization() {
        let normalized = RoundtablePreparation.normalizedExperts([
            .legal,
            .psychology,
            .legal,
            .research,
            .growth,
            .operations,
            .risk,
            .finance,
        ])

        #expect(normalized == [
            .legal,
            .psychology,
            .research,
            .growth,
            .operations,
            .risk,
        ])
        #expect(normalized.count == RoundtablePreparation.maximumExpertCount)
    }

    @Test("preparation selection is valid only from two through six experts")
    func preparationSelectionBounds() {
        let tooFew = RoundtablePreparation(
            originalTopic: "议题",
            selectedExperts: [.legal]
        )
        let minimum = RoundtablePreparation(
            originalTopic: "议题",
            selectedExperts: [.legal, .psychology]
        )
        let maximum = RoundtablePreparation(
            originalTopic: "议题",
            selectedExperts: [
                .product,
                .architecture,
                .finance,
                .risk,
                .strategy,
                .psychology,
            ]
        )

        #expect(!tooFew.hasValidExpertSelection)
        #expect(minimum.hasValidExpertSelection)
        #expect(maximum.hasValidExpertSelection)
    }

    @Test("preparation payload rejects duplicate or incomplete recommendations")
    func preparationPayloadValidation() {
        let duplicateOnly = RoundtablePreparationPayload(
            title: "去留决策",
            refinedTopic: "是否应该转行？",
            framework: ["现金流", "能力差距", "机会成本"],
            clarificationQuestions: [],
            recommendations: [
                .init(expert: "legal", reason: "劳动合同风险"),
                .init(expert: "legal", reason: "竞业限制风险"),
            ]
        )
        let complete = RoundtablePreparationPayload(
            title: "去留决策",
            refinedTopic: "未来半年是否应该转行？",
            framework: ["现金流", "能力差距", "机会成本"],
            clarificationQuestions: ["可承受多久没有收入？"],
            recommendations: [
                .init(expert: "finance", reason: "评估现金流"),
                .init(expert: "psychology", reason: "识别冲动与压力"),
                .init(expert: "legal", reason: "检查合同约束"),
            ]
        )

        #expect(!duplicateOnly.isValid)
        #expect(complete.isValid)

        let preparation = complete.makePreparation(originalTopic: "我想转行")
        #expect(preparation.resolvedTopic == "未来半年是否应该转行？")
        #expect(preparation.framework == ["现金流", "能力差距", "机会成本"])
        #expect(preparation.clarificationQuestions == ["可承受多久没有收入？"])
        #expect(preparation.recommendedExperts == [.finance, .psychology, .legal])
        #expect(preparation.selectedExperts == [.finance, .psychology, .legal])
    }

    @Test("expert analysis attaches the exact visible speech without rewriting it")
    func expertAnalysisPreservesVisibleSpeech() {
        let visibleSpeech = "我反对立刻裸辞。建议先留出六个月现金储备。"
        let analysis = RoundtableExpertAnalysisPayload(
            topic: "现金流安全边界",
            stance: "oppose",
            arguments: ["收入中断风险"],
            suggestion: "准备六个月现金储备",
            needsUserInput: false,
            userOptions: []
        )

        let payload = analysis.attachingSpeech(visibleSpeech)

        #expect(payload.speaking == visibleSpeech)
        #expect(payload.resolvedStance == .oppose)
        #expect(payload.toOSR().arguments == ["收入中断风险"])
        #expect(!payload.asksUser)
    }

    @Test("expert analysis decoder tolerates fenced JSON and excludes speech field")
    func expertAnalysisDecoding() {
        let raw = """
        ```json
        {
          "topic": "合同风险",
          "stance": "neutral",
          "arguments": ["竞业限制需要核验"],
          "suggestion": "先审查劳动合同",
          "needsUserInput": true,
          "userOptions": ["有竞业条款", "没有竞业条款"]
        }
        ```
        """

        let analysis = AgentRoundtableEngine.decodeExpertAnalysis(raw)

        #expect(analysis?.isValid == true)
        #expect(analysis?.stance == "neutral")
        #expect(analysis?.needsUserInput == true)
        #expect(analysis?.userOptions == ["有竞业条款", "没有竞业条款"])
    }

    @Test("preparation transcript keeps speaker boundaries and recent context")
    func preparationTranscriptRendering() {
        let transcript = AgentRoundtableEngine.preparationTranscript([
            .init(speaker: .user, content: "我最多能承受三个月没有收入。"),
            .init(speaker: .assistant, content: "那就把现金流安全边界纳入框架。"),
        ])

        #expect(transcript.contains("USER: 我最多能承受三个月没有收入。"))
        #expect(transcript.contains("ASSISTANT: 那就把现金流安全边界纳入框架。"))
    }

    @Test("stream completion state survives persistence without changing speech")
    func streamingCompletionPersistence() throws {
        let report = AgentRoundtableReport(
            topic: "议题",
            phase: .discussing,
            experts: [.legal, .psychology],
            activeExpert: .legal,
            activeExpertDraft: "可见正文已经流完。",
            activeExpertDraftIsComplete: true
        )

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AgentRoundtableReport.self, from: encoded)

        #expect(decoded.activeExpert == .legal)
        #expect(decoded.activeExpertDraft == "可见正文已经流完。")
        #expect(decoded.activeExpertDraftIsComplete == true)
    }
}
