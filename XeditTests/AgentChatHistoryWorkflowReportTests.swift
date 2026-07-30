//
//  AgentChatHistoryWorkflowReportTests.swift
//  WillDeepTests
//
//  Workflow report history baking and render-cache invalidation.
//

import Testing
@testable import WillDeep

@Suite
struct AgentChatHistoryWorkflowReportTests {
    // rc16 历史折进 NSTextView 后 workflow 卡片一度整体不可见:formatter
    // 对 .workflowReport 只画 WFL 头像行(content 恒为空),SwiftUI 卡片
    // 分支又只挂给流式 assistant。这里锁两件事:已结束卡片的状态行 +
    // 最终报告烘进历史;report mutate 后 render cache 必须失效。

    @Test
    func workflowReportBakesStatusArgsAndSummaryIntoHistory() {
        let report = WorkflowReport(
            workflowName: "deep-research",
            displayTitle: "Deep Research",
            args: "中国大模型市场深度调研",
            status: .done,
            subAgents: [
                .init(label: "scope", status: .done),
                .init(label: "search:news", status: .done),
            ],
            summary: "# 调研结论\n\n最终报告正文标记 FINAL_REPORT_BODY。"
        )
        let message = AgentMessage(role: .workflowReport, content: "", workflowReport: report)

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("Deep Research"))
        #expect(rendered.string.contains(L10n.WorkflowCard.statusDone))
        #expect(rendered.string.contains("中国大模型市场深度调研"))
        #expect(rendered.string.contains("FINAL_REPORT_BODY"))
        // copy 按钮复制的是最终报告,不是恒空的 message.content。
        #expect(message.copyableContent == report.summary)
    }

    @Test
    func workflowReportMutationInvalidatesRenderCache() {
        let report = WorkflowReport(
            workflowName: "deep-research",
            displayTitle: "Deep Research",
            args: "cache 失效验证",
            status: .running
        )
        let message = AgentMessage(role: .workflowReport, content: "", workflowReport: report)
        let first = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        // 同一条消息(id 不变)report 被 engine mutate —— render 必须
        // 重烘,不能命中旧缓存。
        var mutatedReport = report
        mutatedReport.status = .done
        mutatedReport.summary = "WORKFLOW_CACHE_BUST_MARKER"
        var mutated = message
        mutated.workflowReport = mutatedReport
        let second = AgentChatHistoryRenderer.render(messages: [mutated], isDark: false)

        #expect(!first.string.contains("WORKFLOW_CACHE_BUST_MARKER"))
        #expect(second.string.contains("WORKFLOW_CACHE_BUST_MARKER"))
    }
}
