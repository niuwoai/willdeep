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
import AppKit
import SwiftUI
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

    @Test("quoted expert selection survives persistence and enters transcript")
    func testQuotePersistenceAndTranscript() throws {
        let sourceID = UUID()
        let quote = RoundtableQuoteReference(
            messageID: sourceID,
            speakerName: "林越",
            excerpt: "先验证最痛的那个场景",
            isSelection: true
        )
        let message = RoundtableMessage(
            speaker: .user,
            round: 1,
            content: "我同意，先做小范围验证。",
            quote: quote
        )

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(RoundtableMessage.self, from: encoded)
        #expect(decoded.quote == quote)

        let transcript = AgentRoundtablePromptBuilder.transcript([decoded])
        #expect(transcript.contains("引用 林越的选段"))
        #expect(transcript.contains("先验证最痛的那个场景"))
        #expect(transcript.contains("我同意，先做小范围验证。"))
    }

    @Test("old messages and reports decode without quote or active expert")
    func testBackwardCompatibleOptionalFields() throws {
        let messageJSON = """
        {
          "id": "\(UUID().uuidString)",
          "speaker": "expert",
          "role": "product",
          "round": 1,
          "content": "旧会话发言",
          "createdAt": 0,
          "isError": false
        }
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(RoundtableMessage.self, from: messageJSON)
        #expect(message.quote == nil)

        let reportJSON = """
        {
          "id": "\(UUID().uuidString)",
          "topic": "旧议题",
          "title": "旧讨论",
          "phase": "discussing",
          "experts": ["product", "risk"],
          "messages": [],
          "currentRound": 1,
          "converged": false,
          "createdAt": 0,
          "updatedAt": 0
        }
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(AgentRoundtableReport.self, from: reportJSON)
        #expect(report.activeExpert == nil)
        #expect(report.activeExpertDraft == nil)
        #expect(report.activeExpertDraftIsComplete == nil)
        #expect(report.preparation == nil)
        #expect(report.finalDocumentFilePath == nil)
        #expect(report.finalDocumentWriteError == nil)
    }

    // MARK: - 专家池不变量

    @Test("expert roster contains every supported role with distinct personas")
    func testExpertRoster() {
        let all = AgentRoundtableExpertRole.allCases
        let expectedRoles: Set<AgentRoundtableExpertRole> = [
            .product, .architecture, .finance, .risk, .strategy, .psychology,
            .legal, .research, .growth, .operations,
        ]
        #expect(Set(all) == expectedRoles)
        // 每个角色都有非空人设、显示名、专长。
        for role in all {
            #expect(!role.systemPersona.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!role.displayName.isEmpty)
            #expect(!role.shortExpertise.isEmpty)
        }
        // 人设互不相同(防复制粘贴趋同)。
        let personas = Set(all.map(\.systemPersona))
        #expect(personas.count == all.count)

        let names = Set(all.map(\.personalName))
        let titles = Set(all.map(\.roleTitle))
        let avatarAssets = Set(all.map(\.avatarAssetName))
        #expect(names.count == all.count)
        #expect(titles.count == all.count)
        #expect(avatarAssets.count == all.count)
    }

    @Test("expert markdown is rendered without exposing source markers")
    func testExpertMarkdownRenderer() {
        let rendered = RoundtableMarkdownTextRenderer.attributedString(
            from: "先看 **核心风险**，再执行 `灰度发布`。\n\n**下一轮建议：** 分层抽样。"
        )
        #expect(rendered.string == "先看 核心风险，再执行 灰度发布。\n\n下一轮建议： 分层抽样。")
        #expect(!rendered.string.contains("**"))

        let boldRange = (rendered.string as NSString).range(of: "核心风险")
        let boldFont = rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let codeRange = (rendered.string as NSString).range(of: "灰度发布")
        let codeFont = rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @MainActor
    @Test("selectable message text sizing is deterministic and width-aware")
    func testSelectableMessageTextSizing() {
        let coordinator = RoundtableSelectableMessageText.Coordinator(
            onSelectionChange: { _ in }
        )
        let textView = NSTextView(frame: .zero)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textStorage?.setAttributedString(
            RoundtableMarkdownTextRenderer.attributedString(
                from: String(repeating: "这是一段用于验证窗口缩放时稳定换行的专家发言。", count: 8)
            )
        )

        let wide = coordinator.sizeThatFits(textView, width: 420)
        let repeated = coordinator.sizeThatFits(textView, width: 420)
        coordinator.invalidateMeasurement()
        let narrow = coordinator.sizeThatFits(textView, width: 210)

        #expect(wide == repeated)
        #expect(narrow.height > wide.height)
        #expect(wide.height >= 22)
    }

    @Test("final document unwraps markdown fence and removes read-only handoff")
    func testFinalDocumentNormalization() {
        let raw = """
        由于我是只读子代理，无法直接写文件。以下是完整的决策文档，请父 agent 写入结论文件：

        ```markdown
        # 35 岁转行 AI 工程师 —— 专家圆桌决策文档

        ## 核心结论

        建议先完成 **12 周验证**，再决定是否全职转行。

        ## 建议的下一步

        - 完成一个可公开演示的项目
        - 访谈三位从业者
        ```
        说明：正文已经完成，请将上述内容写入结论文件。
        """

        let normalized = AgentRoundtableDocumentNormalizer.normalize(raw)
        #expect(normalized.hasPrefix("## 核心结论"))
        #expect(normalized.contains("**12 周验证**"))
        #expect(normalized.contains("- 完成一个可公开演示的项目"))
        #expect(!normalized.contains("只读子代理"))
        #expect(!normalized.contains("父 agent"))
        #expect(!normalized.contains("请将上述内容写入"))
        #expect(!normalized.contains("```"))
        #expect(!normalized.contains("# 35 岁转行"))
    }

    @Test("partially normalized document removes orphan fence and handoff suffix")
    func testPartiallyNormalizedFinalDocumentNormalization() {
        let raw = """
        ## 核心结论

        建议先小步验证。
        ```

        ---

        **说明：** 请将上述内容写入结论文件。
        """

        let normalized = AgentRoundtableDocumentNormalizer.normalize(raw)
        #expect(normalized == "## 核心结论\n\n建议先小步验证。")
    }

    @Test("normal final document keeps native markdown structure")
    func testNormalFinalDocumentPreserved() {
        let markdown = """
        ## 核心结论

        保持 **小步验证**。

        ```
        示例代码块不能吃掉整份文档
        ```

        ## 待你决策

        1. 时间投入
        2. 风险上限
        """
        #expect(AgentRoundtableDocumentNormalizer.normalize(markdown) == markdown)
    }

    @MainActor
    @Test("final document persists as a real markdown file")
    func testFinalDocumentPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtable-document-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try RoundtableDocumentExporter.persist(
            reportID: UUID(),
            title: "转行决策",
            markdown: """
            ```markdown
            # 重复标题

            ## 核心结论

            建议先验证。
            ```
            """,
            rootDirectory: root
        )
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "md")
        #expect(saved.hasPrefix("# 转行决策\n\n## 核心结论"))
        #expect(!saved.contains("```"))
        #expect(!saved.contains("# 重复标题"))
    }

    @MainActor
    @Test("discussion visual fixture renders at product viewport")
    func testDiscussionVisualFixtureRenders() throws {
        let productMessageID = UUID()
        let report = AgentRoundtableReport(
            topic: "我们的新产品应该先快速发布，还是继续打磨两个月？",
            title: "发布时机与产品质量",
            phase: .discussing,
            experts: [.product, .risk, .finance, .architecture],
            messages: [
                .init(
                    speaker: .chair,
                    round: 0,
                    content: "今天我们不争论“快还是慢”本身，而是判断现在的风险是否可控、验证目标是否清楚。请各位把取舍摆到桌面上。"
                ),
                .init(
                    id: productMessageID,
                    speaker: .expert,
                    role: .product,
                    round: 1,
                    content: "我支持先发布一个边界清晰的版本。@何谨，风险不是继续等待就会自动消失；如果连最痛的场景都没让真实用户碰过，再打磨两个月很可能只是团队自我感动。",
                    osr: .init(
                        topic: "是否先验证真实需求",
                        stance: .support,
                        arguments: ["真实使用比内部判断更可靠"],
                        suggestion: "限定一类用户和一个核心场景，两周内小范围上线。"
                    )
                ),
                .init(
                    speaker: .expert,
                    role: .risk,
                    round: 1,
                    content: "我反对直接面向全部用户发布。@林越，我同意要验证，但当前数据回滚和权限隔离还没有演练，出一次事故会把早期口碑烧掉。",
                    osr: .init(
                        topic: "发布风险是否可逆",
                        stance: .oppose,
                        arguments: ["回滚链路未经演练", "权限边界仍不清楚"],
                        suggestion: "先做邀请制灰度，并把一键回滚作为上线门槛。"
                    )
                ),
                .init(
                    speaker: .expert,
                    role: .finance,
                    round: 1,
                    content: "我保持中立。多打磨两个月的机会成本不低，但如果灰度范围可控，试错成本也能封顶。关键是先给这轮实验设预算和停止条件。",
                    osr: .init(
                        topic: "试错成本与机会成本",
                        stance: .neutral,
                        arguments: ["两个月人力成本明确", "灰度损失可封顶"],
                        suggestion: "设定四周预算上限和三个停止指标。"
                    )
                ),
                .init(
                    speaker: .user,
                    round: 1,
                    content: "我接受邀请制灰度，请继续讨论首批用户和回滚门槛。",
                    quote: .init(
                        messageID: productMessageID,
                        speakerName: "产品经理 · 林越",
                        excerpt: "限定一类用户和一个核心场景，两周内小范围上线。",
                        isSelection: true
                    )
                ),
            ],
            currentRound: 2,
            activeExpert: .architecture
        )
        let appState = AppState()
        let view = RoundtableDiscussionView(
            route: .constant(.discussion(runtimeID: UUID(), reportID: report.id)),
            runtimeID: UUID(),
            reportID: report.id,
            previewReport: report
        )
        .environmentObject(appState)
        .frame(width: 980, height: 720)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Could not allocate bitmap for Expert Roundtable visual fixture")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Could not encode Expert Roundtable visual fixture")
            return
        }
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-roundtable-design-preview.png")
        try png.write(to: output, options: .atomic)
        #expect(png.count > 20_000)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}
