//
//  AgentTurnProgressPresentationTests.swift
//  WillDeepTests
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite("Agent 本轮进度界面")
@MainActor
struct AgentTurnProgressPresentationTests {
    @Test("正文与本轮进度卡保留清晰间距")
    func progressCardKeepsDistanceFromBody() {
        #expect(AgentTurnProgressLayoutMetrics.contentSpacing == 14)
    }

    /// 每一轮都留着自己的进度卡时，长会话会摞出一列内容雷同、计数早已过期
    /// 的小卡片。只有最新一条 assistant 消息保留卡片；更早的照旧剥掉
    /// progress 协议块，但不再渲染卡片。
    @Test("历史轮次不再各留一张本轮进度卡")
    func onlyTheNewestTurnKeepsItsProgressCard() {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "读取工程"),
                AgentPlan.Step(text: "实现播放器"),
            ],
            summary: ""
        )
        func turn(_ body: String) -> String {
            """
            \(body)

            ```progress
            1: done
            2: in_progress
            ```
            """
        }
        let messages = [
            AgentMessage(role: .user, content: "开始"),
            AgentMessage(role: .assistant, content: turn("第一轮")),
            AgentMessage(role: .user, content: "继续"),
            AgentMessage(role: .assistant, content: turn("第二轮")),
        ]

        let rendered = AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            progressPlan: plan
        ).string

        let title = L10n.AgentTurnProgress.title
        let cardCount = rendered.components(separatedBy: title).count - 1
        #expect(cardCount == 1, "期望只有最新一轮保留进度卡，实际出现 \(cardCount) 张")

        // 两轮正文都还在，且都不该漏出原始 progress 协议块。
        #expect(rendered.contains("第一轮"))
        #expect(rendered.contains("第二轮"))
        #expect(!rendered.contains("```progress"))
        #expect(!rendered.contains("1: done"))
    }

    @Test("隐藏 progress 协议并合并本轮最后状态")
    func extractsAndMergesProgressBlocks() throws {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "读取工程"),
                AgentPlan.Step(text: "实现播放器"),
                AgentPlan.Step(text: "运行验证"),
            ],
            summary: ""
        )
        let content = """
        已完成工程检查。

        ```progress
        1: done
        2: in_progress
        ```

        正在补齐界面。

        ```progress
        2: done
        3: failed
        ```
        """

        let extraction = AgentTurnProgressPresentation.extract(from: content, plan: plan)
        let presentation = try #require(extraction.presentation)

        #expect(extraction.visibleContent == "已完成工程检查。\n\n正在补齐界面。")
        #expect(!extraction.visibleContent.contains("```progress"))
        #expect(presentation.items.map(\.index) == [1, 2, 3])
        #expect(presentation.items.map(\.status) == [.done, .done, .failed])
        #expect(presentation.items.map(\.title) == ["读取工程", "实现播放器", "运行验证"])
        #expect(presentation.completedCount == 2)
        #expect(presentation.inProgressCount == 0)
        #expect(presentation.failedCount == 1)
        #expect(presentation.detailItems.map(\.index) == [3])
    }

    @Test("普通代码块不会被当作进度协议")
    func preservesOrdinaryCodeBlocks() {
        let content = """
        ```swift
        let progress = true
        ```
        """

        let extraction = AgentTurnProgressPresentation.extract(from: content, plan: nil)

        #expect(extraction.visibleContent == content)
        #expect(extraction.presentation == nil)
    }

    @Test("Goal 自检协议不会作为聊天正文显示")
    func hidesGoalCheckProtocolWithOrWithoutProgress() {
        let goalOnly = AgentTurnProgressPresentation.extract(
            from: """
            本轮验证已通过。

            ```goal-check
            1: done
            ```
            """,
            plan: nil
        )
        #expect(goalOnly.visibleContent == "本轮验证已通过。")
        #expect(goalOnly.presentation == nil)

        let withProgress = AgentTurnProgressPresentation.extract(
            from: """
            已完成交付。

            ```progress
            1: done
            ```

            ```goal-check
            1: done
            ```
            """,
            plan: nil
        )
        #expect(withProgress.visibleContent == "已完成交付。")
        #expect(withProgress.presentation?.items.map(\.status) == [.done])
    }

    @Test("TextKit 历史渲染为可展开摘要而不是代码块")
    func historyRendererUsesProgressSurface() throws {
        let message = AgentMessage(
            role: .assistant,
            content: """
            已完成实现。

            ```progress
            1: done
            2: in_progress
            3: failed
            ```
            """
        )
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "读取工程"),
                AgentPlan.Step(text: "补齐播放器界面"),
                AgentPlan.Step(text: "运行前端验证"),
            ],
            summary: ""
        )
        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: true,
            expandedProgressBlockIDs: [message.id.uuidString],
            progressPlan: plan
        )

        #expect(!rendered.string.contains("in_progress"))
        #expect(!rendered.string.contains("```progress"))
        #expect(rendered.string.contains("补齐播放器界面"))
        #expect(rendered.string.contains("运行前端验证"))

        let fullRange = NSRange(location: 0, length: rendered.length)
        var foundBlock = false
        var foundToggle = false
        rendered.enumerateAttribute(.agentChatHistoryProgressBlockID, in: fullRange) { value, _, _ in
            foundBlock = foundBlock || value as? String == message.id.uuidString
        }
        rendered.enumerateAttribute(.agentChatHistoryProgressToggleID, in: fullRange) { value, _, _ in
            foundToggle = foundToggle || value as? String == message.id.uuidString
        }
        #expect(foundBlock)
        #expect(foundToggle)
    }

    @Test("渲染第 3 案的收起与展开状态供视觉验收")
    func rendersSelectedDesignForVisualQA() throws {
        let outputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/visual-qa/turn-progress/implementation-option-3.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let collapsed = AgentTurnProgressPresentation(items: [
            .init(index: 2, status: .done, title: "补齐数据模型"),
            .init(index: 3, status: .done, title: "完善播放策略"),
            .init(index: 5, status: .done, title: "接入本地曲源"),
            .init(index: 6, status: .inProgress, title: "补齐播放器与曲库界面"),
            .init(index: 7, status: .inProgress, title: "处理播放器状态"),
            .init(index: 8, status: .failed, title: "前端验证"),
        ])
        let expanded = AgentTurnProgressPresentation(items: [
            .init(index: 2, status: .done, title: "补齐数据模型"),
            .init(index: 3, status: .done, title: "完善播放策略"),
            .init(index: 4, status: .done, title: "实现故障回退"),
            .init(index: 5, status: .done, title: "接入本地曲源"),
            .init(index: 6, status: .inProgress, title: "补齐播放器与曲库界面"),
            .init(index: 7, status: .inProgress, title: "处理播放器状态"),
            .init(index: 8, status: .failed, title: "前端验证"),
        ])
        let fixture = VStack(alignment: .leading, spacing: 28) {
            Text("已将你的补充落实到模型：曲源按格式偏好、优先级和可用状态排序。")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            AgentTurnProgressView(presentation: collapsed)
            Text("已完成语法检验，播放策略已纳入优先级与故障回退。")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            AgentTurnProgressView(
                presentation: expanded,
                showsPlanAction: true,
                initiallyExpanded: true
            )
        }
        .padding(18)
        .frame(width: 714)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.075, alpha: 1)))
        .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: fixture)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 714, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = max(1, hostingView.fittingSize.height)
        hostingView.frame = NSRect(x: 0, y: 0, width: 714, height: fittingHeight)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)

        #expect(hostingView.frame.width == 714)
        #expect(hostingView.frame.height > 220)
    }
}
