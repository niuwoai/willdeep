//
//  AgentContextRunwayHandoffDisplayTests.swift
//  WillDeepTests
//

import WillDeepCore
import AppKit
import Foundation
import Testing

@testable import WillDeep

@Suite("Context runway handoff display")
nonisolated struct AgentContextRunwayHandoffDisplayTests {
    /// A handover shaped the way `AgentContextRunwayPolicy.handoffPrompt`
    /// asks for it, in the user's language.
    private static let fullHandoff = """
        PAUSE: 上下文跑道见底了，不是任务做完了。

        DONE: 已确认下载脚本能跑通（scripts/tsing_hub_video_download.rb 手工验证过一次）。

        ANCHORS: 分支 claude/video-script，版本 1.301.0-rc5，改动集中在 scripts/tsing_hub_video_download.rb。

        REMAINING: 还差第二个 task_id 的取结果验证，以及带 --reference 的改造脚本重跑。

        NEXT PROMPT: 继续视频脚本收尾——先运行 `ruby scripts/tsing_hub_video_download.rb task_3Oh6b` 验证下载脚本与取结果流程，再按结果决定是否重跑 fl2va。
        """

    @Test("接力段从正文里摘出来，其余四段原样保留")
    func extractsRelaySectionAndKeepsTheRest() {
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: Self.fullHandoff)

        #expect(extraction.isHandoff)
        #expect(!extraction.visibleContent.contains("NEXT PROMPT"))
        #expect(extraction.visibleContent.contains("PAUSE:"))
        #expect(extraction.visibleContent.contains("DONE:"))
        #expect(extraction.visibleContent.contains("ANCHORS:"))
        #expect(extraction.visibleContent.contains("REMAINING:"))
        // 摘出来的提示词不带标签,直接可以塞进新会话的输入框。
        #expect(extraction.relayPrompt?.hasPrefix("继续视频脚本收尾") == true)
        #expect(extraction.relayPrompt?.contains("tsing_hub_video_download.rb") == true)
    }

    @Test("摘完不留尾部空行")
    func trimsTrailingBlankLines() {
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: Self.fullHandoff)
        #expect(extraction.visibleContent.hasSuffix("重跑。"))
    }

    @Test("普通回复里提到 NEXT PROMPT 不会被吞掉")
    func ordinaryProseIsNeverSwallowed() {
        let prose = """
            交接的时候模型会写一行 NEXT PROMPT: 用来续跑，这行现在折进了页脚图标。
            剩下的四段还是照常显示。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: prose)

        #expect(!extraction.isHandoff)
        #expect(extraction.visibleContent == prose)
        #expect(extraction.relayPrompt == nil)
    }

    @Test("只凑齐一段同伴还不算交接")
    func requiresEnoughCompanionSections() {
        let almost = """
            DONE: 只写了一段。

            NEXT PROMPT: 接着干。
            """
        #expect(!AgentContextRunwayHandoffDisplay.extract(from: almost).isHandoff)
    }

    @Test("凑齐两段也还不算交接")
    func twoCompanionSectionsAreStillNotEnough() {
        // 整条消息要被换成卡片,误判的代价从「藏掉一句」变成「整条回复
        // 不按正常样式显示」,门槛因此从 2 段提到 3 段。
        let almost = """
            PAUSE: 先停一下。

            DONE: 写了一半。

            NEXT PROMPT: 接着干。
            """
        #expect(!AgentContextRunwayHandoffDisplay.extract(from: almost).isHandoff)
    }

    @Test("没有 PAUSE 段就不是交接")
    func requiresPauseSection() {
        // DONE / ANCHORS / REMAINING 都是工程散文里的常见词,只有行首的
        // PAUSE: 是交接协议独有的。
        let noPause = """
            DONE: 三件事验证过了。

            ANCHORS: Xedit/AgentChatHistoryFormatter.swift

            REMAINING: 还差两处接线。

            NEXT PROMPT: 接着把剩下两处接线补完。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: noPause)

        #expect(!extraction.isHandoff)
        #expect(extraction.visibleContent == noPause)
        #expect(extraction.sections.isEmpty)
    }

    @Test("助手讨论这个功能本身时不会被误判成交接")
    func discussingTheFeatureIsNotAHandoff() {
        // 这条消息在解释卡片怎么做的,句子里带了协议里的每一个词 ——
        // 换成卡片就等于把一段正常回复整条吞掉。
        let discussion = """
            交接卡片是这么判定的:一条消息里要同时出现 PAUSE、DONE、ANCHORS、
            REMAINING 这些段标题(而且 PAUSE 必须在场),最后那段 NEXT PROMPT
            才会被当成接力指令摘出去。

            所以我打算把 minimumCompanionSections 提到 3,再要求 PAUSE 在场。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: discussion)

        #expect(!extraction.isHandoff)
        #expect(extraction.visibleContent == discussion)
        #expect(extraction.sections.isEmpty)
    }

    @Test("小节按写的顺序解析出来，标题和正文分开")
    func parsesSectionsInWrittenOrder() {
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: Self.fullHandoff)

        #expect(extraction.sections.map(\.label) == ["PAUSE", "DONE", "ANCHORS", "REMAINING"])
        #expect(extraction.sections.first?.body == "上下文跑道见底了，不是任务做完了。")
        #expect(
            extraction.sections.last?.body
                == "还差第二个 task_id 的取结果验证，以及带 --reference 的改造脚本重跑。"
        )
        // NEXT PROMPT 不在小节里 —— 它是一个动作的载荷,不是一段正文。
        #expect(!extraction.sections.contains { $0.label == "NEXT PROMPT" })
    }

    @Test("模型少写一段时不臆造那一段")
    func missingSectionIsNotInvented() {
        let withoutAnchors = """
            PAUSE: 窗口满了。

            DONE: 解析器写完了。

            REMAINING: 还差渲染器。

            NEXT PROMPT: 接着写渲染器。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: withoutAnchors)

        #expect(extraction.isHandoff)
        #expect(extraction.sections.map(\.label) == ["PAUSE", "DONE", "REMAINING"])
    }

    @Test("多行小节的正文整段留在小节里")
    func multiLineSectionKeepsItsWholeBody() {
        let multiline = """
            PAUSE: 窗口满了。

            DONE: 第一件事验证过了，
            第二件事只跑了一半。

            REMAINING: 还差回滚演练。

            NEXT PROMPT: 接着跑回滚演练。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: multiline)

        #expect(
            extraction.sections.first(where: { $0.label == "DONE" })?.body
                == "第一件事验证过了，\n第二件事只跑了一半。"
        )
    }

    @Test("非交接消息不带小节")
    func nonHandoffCarriesNoSections() {
        #expect(AgentContextRunwayHandoffDisplay.extract(from: "普通回复").sections.isEmpty)
    }

    @Test("认得 Markdown 列表与加粗写法的段标题")
    func recognizesDecoratedSectionLabels() {
        let decorated = """
            - **PAUSE:** 窗口快满了。
            - **DONE:** 迁移脚本已验证。
            - **REMAINING:** 还差回滚演练。
            - **NEXT PROMPT:** 先跑一遍 `rake db:rollback` 的演练脚本。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: decorated)

        #expect(extraction.isHandoff)
        #expect(extraction.relayPrompt == "先跑一遍 `rake db:rollback` 的演练脚本。")
        #expect(!extraction.visibleContent.contains("NEXT PROMPT"))
        #expect(extraction.visibleContent.contains("还差回滚演练"))
    }

    @Test("代码围栏里的协议样例是代码，不是协议")
    func fencedExampleIsLeftAlone() {
        let fenced = """
            PAUSE: 说明一下交接格式。

            DONE: 文档写完了。

            ANCHORS: docs/handoff.md

            ```text
            NEXT PROMPT: 这一行是文档里的例子，不能当成真的接力指令。
            ```
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: fenced)

        #expect(!extraction.isHandoff)
        #expect(extraction.visibleContent == fenced)
    }

    @Test("空的接力段不产生按钮，也不动正文")
    func emptyRelaySectionKeepsBodyIntact() {
        let empty = """
            PAUSE: 停一下。

            DONE: 什么也没验证。

            REMAINING: 全部。

            NEXT PROMPT:
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: empty)

        #expect(!extraction.isHandoff)
        #expect(extraction.visibleContent == empty)
    }

    @Test("接力段不在末尾时只吃自己那一段")
    func relaySectionStopsAtTheNextLabel() {
        let reordered = """
            PAUSE: 窗口见底。

            NEXT PROMPT: 从 AgentContextRunwayHandoffDisplay 的用例接着补。

            DONE: 解析器写完了。

            REMAINING: 还差 UI 接线。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: reordered)

        #expect(extraction.relayPrompt == "从 AgentContextRunwayHandoffDisplay 的用例接着补。")
        #expect(extraction.visibleContent.contains("DONE: 解析器写完了。"))
        #expect(extraction.visibleContent.contains("REMAINING: 还差 UI 接线。"))
        #expect(!extraction.visibleContent.contains("NEXT PROMPT"))
    }

    @Test("多行接力段整段带走")
    func multiLineRelaySectionIsTakenWhole() {
        let multiline = """
            PAUSE: 停。

            DONE: 一半。

            ANCHORS: Xedit/AgentChatChromeRenderers.swift

            NEXT PROMPT: 先跑单测，
            再把两个图标接到 AppState 上。
            """
        let extraction = AgentContextRunwayHandoffDisplay.extract(from: multiline)

        #expect(extraction.relayPrompt == "先跑单测，\n再把两个图标接到 AppState 上。")
        #expect(!extraction.visibleContent.contains("再把两个图标"))
    }

    @Test("空输入框直接发「继续」，有草稿就带着草稿一起发")
    func composedResumeInputCarriesAnyDraft() {
        #expect(
            AgentContextRunwayHandoffDisplay.composedResumeInput(
                currentInput: "",
                resumeWord: "继续"
            ) == "继续"
        )
        #expect(
            AgentContextRunwayHandoffDisplay.composedResumeInput(
                currentInput: "   \n  ",
                resumeWord: "继续"
            ) == "继续"
        )
        // 草稿不能丢:发送会清空输入框,留在那儿就是永久丢失。
        #expect(
            AgentContextRunwayHandoffDisplay.composedResumeInput(
                currentInput: "先别动 scripts/,",
                resumeWord: "继续"
            ) == "先别动 scripts/,\n\n继续"
        )
    }

    @Test("便捷入口和完整提取给出同一个提示词")
    func convenienceAccessorAgreesWithExtraction() {
        #expect(
            AgentContextRunwayHandoffDisplay.relayPrompt(in: Self.fullHandoff)
                == AgentContextRunwayHandoffDisplay.extract(from: Self.fullHandoff).relayPrompt
        )
        #expect(AgentContextRunwayHandoffDisplay.relayPrompt(in: "普通回复") == nil)
    }
}

@Suite("Context runway handoff card")
struct AgentContextRunwayHandoffCardTests {
    private static let handoff = """
        PAUSE: 上下文见底。

        DONE: 解析器写完了。

        ANCHORS: Xedit/AgentContextRunwayHandoffDisplay.swift

        REMAINING: 还差 footer 接线。

        NEXT PROMPT: 接着把两个接力图标挂到 footer 上。
        """

    private func render(
        _ messages: [AgentMessage],
        isAssistantTurnActive: Bool = false
    ) -> NSAttributedString {
        AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            isAssistantTurnActive: isAssistantTurnActive
        )
    }

    @Test("最后一条交接消息的正文不带接力段，页脚带两个接力动作")
    func latestHandoffCarriesRelayActions() {
        let rendered = render([
            AgentMessage(role: .user, content: "继续干"),
            AgentMessage(role: .assistant, content: Self.handoff),
        ])

        #expect(!rendered.string.contains("NEXT PROMPT"))
        #expect(rendered.string.contains("还差 footer 接线"))
        #expect(attributeCount(.agentChatHistoryResumeHandoff, in: rendered) == 1)
        // 「开新会话继续」带的是整份交接：新会话没有这段对话，只带
        // NEXT PROMPT 一句的话 DONE / ANCHORS / REMAINING 就丢了。
        #expect(
            firstAttributeRange(
                .agentChatHistoryHandoffRelayPrompt,
                value: Self.handoff,
                in: rendered
            ) != nil
        )
    }

    @Test("回合还在跑的时候不给接力动作")
    func activeTurnHidesRelayActions() {
        let rendered = render(
            [
                AgentMessage(role: .user, content: "继续干"),
                AgentMessage(role: .assistant, content: Self.handoff),
            ],
            isAssistantTurnActive: true
        )

        // 正文照剥 —— 这条不因回合状态而变。
        #expect(!rendered.string.contains("NEXT PROMPT"))
        #expect(attributeCount(.agentChatHistoryResumeHandoff, in: rendered) == 0)
        #expect(attributeCount(.agentChatHistoryHandoffRelayPrompt, in: rendered) == 0)
    }

    @Test("已经被后面消息接上的历史交接不再挂按钮")
    func supersededHandoffDropsRelayActions() {
        let rendered = render([
            AgentMessage(role: .user, content: "继续干"),
            AgentMessage(role: .assistant, content: Self.handoff),
            AgentMessage(role: .assistant, content: "压缩完了，我接着往下做。"),
        ])

        #expect(attributeCount(.agentChatHistoryResumeHandoff, in: rendered) == 0)
        #expect(attributeCount(.agentChatHistoryHandoffRelayPrompt, in: rendered) == 0)
    }

    @Test("普通结尾消息不长出接力动作")
    func ordinaryLastAssistantHasNoRelayActions() {
        let rendered = render([
            AgentMessage(role: .user, content: "干完了吗"),
            AgentMessage(role: .assistant, content: "干完了，测试全绿。"),
        ])

        #expect(attributeCount(.agentChatHistoryResumeHandoff, in: rendered) == 0)
        #expect(attributeCount(.agentChatHistoryHandoffRelayPrompt, in: rendered) == 0)
    }

    @Test("卡片里有标题、各小节正文和「点继续会发什么」")
    func cardShowsTitleSectionsAndRelayPrompt() {
        let rendered = render([
            AgentMessage(role: .user, content: "继续干"),
            AgentMessage(role: .assistant, content: Self.handoff),
        ]).string

        #expect(rendered.contains(L10n.ContextRunwayHandoff.cardTitle))
        // 小节标题是本地化文案,协议里的英文合同词不出现在界面上。
        #expect(rendered.contains(L10n.ContextRunwayHandoff.sectionPause))
        #expect(rendered.contains(L10n.ContextRunwayHandoff.sectionDone))
        #expect(rendered.contains(L10n.ContextRunwayHandoff.sectionAnchors))
        #expect(rendered.contains(L10n.ContextRunwayHandoff.sectionRemaining))
        #expect(rendered.contains(L10n.ContextRunwayHandoff.sectionNextPrompt))
        #expect(!rendered.contains("PAUSE:"))
        // 每一段的正文都看得见。
        #expect(rendered.contains("上下文见底"))
        #expect(rendered.contains("解析器写完了"))
        #expect(rendered.contains("Xedit/AgentContextRunwayHandoffDisplay.swift"))
        #expect(rendered.contains("还差 footer 接线"))
        // 用户按下「继续」之前就该看见将要发出去的是哪句话。
        #expect(rendered.contains("接着把两个接力图标挂到 footer 上"))
    }

    @Test("卡片动作带文字，不是两个无字图标")
    func cardActionsCarryText() {
        let rendered = render([
            AgentMessage(role: .user, content: "继续干"),
            AgentMessage(role: .assistant, content: Self.handoff),
        ])

        #expect(rendered.string.contains(L10n.ContextRunwayHandoff.resumeAction))
        #expect(rendered.string.contains(L10n.ContextRunwayHandoff.newSessionAction))
        // 动作文字就是可点区域:属性挂在「图标 + 文字」这一整段上。
        let resumeRange = firstAttributeRange(
            .agentChatHistoryResumeHandoff,
            containing: L10n.ContextRunwayHandoff.resumeAction,
            in: rendered
        )
        #expect(resumeRange != nil)
    }

    @Test("历史上的交接还是卡片，只是不给按钮")
    func supersededHandoffStillRendersAsCard() {
        let rendered = render([
            AgentMessage(role: .user, content: "继续干"),
            AgentMessage(role: .assistant, content: Self.handoff),
            AgentMessage(role: .assistant, content: "压缩完了，我接着往下做。"),
        ]).string

        #expect(rendered.contains(L10n.ContextRunwayHandoff.cardTitle))
        #expect(rendered.contains(L10n.ContextRunwayHandoff.sectionRemaining))
        #expect(!rendered.contains(L10n.ContextRunwayHandoff.resumeAction))
        #expect(!rendered.contains(L10n.ContextRunwayHandoff.newSessionAction))
    }

    @Test("回合还在跑的时候不出卡片，正文照旧剥掉接力段")
    func activeTurnKeepsPlainBody() {
        let rendered = render(
            [
                AgentMessage(role: .user, content: "继续干"),
                AgentMessage(role: .assistant, content: Self.handoff),
            ],
            isAssistantTurnActive: true
        ).string

        #expect(!rendered.contains(L10n.ContextRunwayHandoff.cardTitle))
        #expect(!rendered.contains("NEXT PROMPT"))
        // 模型自己写的段标题此刻还在正文里 —— 这就是「没换成卡片」。
        #expect(rendered.contains("PAUSE:"))
    }

    @Test("两条交接只有最后一条带按钮")
    func onlyTheLastHandoffCarriesActions() {
        let earlier = Self.handoff.replacingOccurrences(
            of: "还差 footer 接线",
            with: "还差解析器"
        )
        let rendered = render([
            AgentMessage(role: .user, content: "继续干"),
            AgentMessage(role: .assistant, content: earlier),
            AgentMessage(role: .user, content: "继续"),
            AgentMessage(role: .assistant, content: Self.handoff),
        ])

        // 两张卡片,一组按钮。
        #expect(occurrences(of: L10n.ContextRunwayHandoff.cardTitle, in: rendered.string) == 2)
        #expect(attributeCount(.agentChatHistoryResumeHandoff, in: rendered) == 1)
        #expect(attributeCount(.agentChatHistoryHandoffRelayPrompt, in: rendered) == 1)
        // 按钮挂在最后那条上:它带走的是最后那份交接。
        #expect(
            firstAttributeRange(
                .agentChatHistoryHandoffRelayPrompt,
                value: Self.handoff,
                in: rendered
            ) != nil
        )
    }

    @Test("交接消息仍然有 copy / retry 那一行页脚")
    func handoffKeepsItsFooter() {
        let rendered = render([
            AgentMessage(role: .user, content: "继续干"),
            AgentMessage(role: .assistant, content: Self.handoff),
        ])

        // body 被整条换成卡片后,footer 的 `!body.isEmpty` 判据会落空 ——
        // 这条用例守的就是那个洞。
        #expect(
            firstAttributeRange(
                .link,
                value: AgentChatHistoryFooterChrome.retryLinkValue,
                in: rendered
            ) != nil
        )
        #expect(
            firstAttributeRange(
                .link,
                value: AgentChatHistoryFooterChrome.copyLinkValue,
                in: rendered
            ) != nil
        )
    }
}
