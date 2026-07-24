//
//  AgentRoundtableTests.swift
//  WillDeepTests
//
//  专家圆桌核心纯函数测试:结构化输出解析的分层兜底、payload 校验、
//  角色/立场解析、transcript 渲染。锁定「主模型偶发夹带 markdown 围栏 /
//  前后噪声时仍能抠出 JSON」这一不变量(吸取 think 标签泄漏教训)。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentRoundtableTests {

    // MARK: - 分层 JSON 解码兜底

    @Test("clean JSON decodes directly")
    func testCleanJSONDecodes() {
        let raw = #"{"topic":"是否重写","stance":"oppose","arguments":["成本高"],"suggestion":"先试点","speaking":"我反对全面重写。@架构师 你说的对。"}"#
        let payload = AgentRoundtableEngine.decodeExpert(raw)
        #expect(payload != nil)
        #expect(payload?.topic == "是否重写")
        #expect(payload?.resolvedStance == .oppose)
        #expect(payload?.isValid == true)
    }

    @Test("JSON wrapped in markdown fence is extracted")
    func testFencedJSONExtracted() {
        let raw = """
        好的，这是我的发言：
        ```json
        {"topic":"预算","stance":"support","speaking":"我支持这个预算。@财务 有道理。"}
        ```
        """
        let payload = AgentRoundtableEngine.decodeExpert(raw)
        #expect(payload != nil)
        #expect(payload?.resolvedStance == .support)
        #expect(payload?.speaking.contains("我支持") == true)
    }

    @Test("JSON with leading/trailing noise is extracted")
    func testNoisyJSONExtracted() {
        let raw = #"<thinking>先想想</thinking> {"topic":"方向","stance":"neutral","speaking":"我保持中立。"} 就这样"#
        let payload = AgentRoundtableEngine.decodeExpert(raw)
        #expect(payload != nil)
        #expect(payload?.resolvedStance == .neutral)
    }

    @Test("nested braces do not break extraction")
    func testNestedBracesExtracted() {
        let raw = #"{"topic":"配置","stance":"support","suggestion":"用 {\"key\":\"val\"} 这种结构","speaking":"这里嵌套了 {大括号}。"}"#
        let payload = AgentRoundtableEngine.decodeExpert(raw)
        #expect(payload != nil)
        #expect(payload?.suggestion?.contains("key") == true)
    }

    @Test("malformed JSON returns nil")
    func testMalformedReturnsNil() {
        #expect(AgentRoundtableEngine.decodeExpert("完全不是 JSON 的一段话") == nil)
        #expect(AgentRoundtableEngine.decodeExpert("{ 残缺的 json") == nil)
        #expect(AgentRoundtableEngine.decodeExpert("") == nil)
    }

    @Test("extractJSONObject returns first balanced object")
    func testExtractBalancedObject() {
        #expect(AgentRoundtableEngine.extractJSONObject("前缀 {\"a\":1} 后缀") == "{\"a\":1}")
        #expect(AgentRoundtableEngine.extractJSONObject("没有大括号") == nil)
    }

    // MARK: - 专家 payload 校验与立场解析

    @Test("expert payload validity requires speaking and topic")
    func testExpertValidity() {
        let empty = RoundtableExpertPayload(topic: "", stance: "support", arguments: nil, suggestion: nil, speaking: "")
        #expect(empty.isValid == false)
        let noSpeaking = RoundtableExpertPayload(topic: "议题", stance: "support", arguments: nil, suggestion: nil, speaking: "   ")
        #expect(noSpeaking.isValid == false)
        let ok = RoundtableExpertPayload(topic: "议题", stance: "support", arguments: nil, suggestion: nil, speaking: "有内容")
        #expect(ok.isValid == true)
    }

    @Test("stance parsing handles english and chinese and unknown")
    func testStanceParsing() {
        func stance(_ s: String) -> RoundtableOSR.Stance {
            RoundtableExpertPayload(topic: "t", stance: s, arguments: nil, suggestion: nil, speaking: "x").resolvedStance
        }
        #expect(stance("support") == .support)
        #expect(stance("OPPOSE") == .oppose)
        #expect(stance("中立") == .neutral)
        #expect(stance("反对") == .oppose)
        #expect(stance("胡说八道") == .undecided)
    }

    @Test("expert payload converts to OSR filtering empty arguments")
    func testToOSR() {
        let payload = RoundtableExpertPayload(
            topic: "议题", stance: "oppose",
            arguments: ["有效论据", "  ", ""], suggestion: "建议", speaking: "发言"
        )
        let osr = payload.toOSR()
        #expect(osr.stance == .oppose)
        #expect(osr.arguments == ["有效论据"])
        #expect(osr.suggestion == "建议")
    }

    // MARK: - 专家反问(交互追问闭环)

    @Test("expert payload without needsUserInput does not ask user")
    func testDefaultDoesNotAskUser() {
        let payload = RoundtableExpertPayload(topic: "议题", stance: "support", arguments: nil, suggestion: nil, speaking: "常规发言")
        #expect(payload.asksUser == false)
        #expect(payload.resolvedUserOptions.isEmpty)
    }

    @Test("expert payload with needsUserInput asks user and parses options")
    func testAsksUserWithOptions() {
        let raw = #"{"topic":"预算","stance":"undecided","speaking":"你打算投入多少?","needsUserInput":true,"userOptions":["10万以内","10-50万","","  "]}"#
        let payload = AgentRoundtableEngine.decodeExpert(raw)
        #expect(payload != nil)
        #expect(payload?.asksUser == true)
        // 空白选项被过滤。
        #expect(payload?.resolvedUserOptions == ["10万以内", "10-50万"])
    }

    @Test("needsUserInput true with no options still asks user (free-form answer)")
    func testAsksUserWithoutOptions() {
        let raw = #"{"topic":"方向","stance":"neutral","speaking":"能说说你的真实目标吗?","needsUserInput":true}"#
        let payload = AgentRoundtableEngine.decodeExpert(raw)
        #expect(payload?.asksUser == true)
        #expect(payload?.resolvedUserOptions.isEmpty == true)
    }

    // MARK: - 推荐 payload

    @Test("recommendation resolves valid roles and dedupes")
    func testRecommendationResolve() {
        let payload = RoundtableRecommendationPayload(
            experts: ["product", "risk", "product", "不存在的角色"],
            title: "标题", reason: nil
        )
        let roles = payload.resolvedExperts
        #expect(roles == [.product, .risk])
        #expect(payload.isValid == true)
    }

    @Test("recommendation with fewer than 2 valid roles is invalid")
    func testRecommendationTooFew() {
        let payload = RoundtableRecommendationPayload(experts: ["product", "垃圾"], title: "t", reason: nil)
        #expect(payload.isValid == false)
    }

    // MARK: - 导播小结 payload

    @Test("moderation validity requires non-empty summary")
    func testModerationValidity() {
        #expect(RoundtableModerationPayload(summary: "", converged: true).isValid == false)
        #expect(RoundtableModerationPayload(summary: "有小结", converged: false).isValid == true)
    }

    // MARK: - transcript 渲染

    @Test("transcript renders speakers and optionally excludes errors")
    func testTranscriptRendering() {
        let messages: [RoundtableMessage] = [
            .init(speaker: .chair, round: 0, content: "开场"),
            .init(speaker: .expert, role: .product, round: 1, content: "产品观点"),
            .init(speaker: .expert, role: .risk, round: 1, content: "失败了", isError: true),
        ]
        let full = AgentRoundtablePromptBuilder.transcript(messages)
        #expect(full.contains("开场"))
        #expect(full.contains("产品观点"))
        #expect(full.contains("失败了"))

        let clean = AgentRoundtablePromptBuilder.transcript(messages, excludeErrors: true)
        #expect(clean.contains("产品观点"))
        #expect(!clean.contains("失败了"))
    }

    // MARK: - 专家池不变量

    @Test("expert roster has six roles with distinct personas")
    func testExpertRoster() {
        let all = AgentRoundtableExpertRole.allCases
        #expect(all.count == 6)
        // 每个角色都有非空人设、显示名、专长。
        for role in all {
            #expect(!role.systemPersona.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!role.displayName.isEmpty)
            #expect(!role.shortExpertise.isEmpty)
        }
        // 人设互不相同(防复制粘贴趋同)。
        let personas = Set(all.map(\.systemPersona))
        #expect(personas.count == 6)
    }
}
