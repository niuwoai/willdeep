//
//  AgentToolReceiptRenderingTests.swift
//  WillDeepTests
//
//  Covers exceptional outcome receipts. Successful work keeps its concrete
//  action summary (for example “已运行1条命令”) without an inconsistent
//  “完成” suffix; failures and denials remain explicit.
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentToolReceiptRenderingTests {

    // MARK: - outcomeBadge verdict logic

    private func inlineGroup(
        _ receipts: [String: AgentToolCallStatus]
    ) -> AgentChatHistoryRenderer.ToolCallHistoryGroup {
        AgentChatHistoryRenderer.ToolCallHistoryGroup(
            inlineMessageIDs: [UUID()],
            calls: receipts.keys.map {
                AgentMessageToolCall(externalID: $0, toolName: "run_command", argumentsJSON: "{}")
            },
            receipts: receipts
        )
    }

    @Test
    func allSucceededNeedsNoExtraBadge() {
        let group = inlineGroup(["a": .succeeded, "b": .succeeded])
        #expect(group.outcomeBadge == nil)
    }

    @Test
    func anyFailureWinsOverSuccess() {
        // A failure is the thing the user most needs to see, so it beats
        // co-occurring successes in the single-line verdict.
        let group = inlineGroup(["a": .succeeded, "b": .failed])
        #expect(group.outcomeBadge == "(1条失败)")
    }

    @Test
    func failureCountIsReported() {
        let group = inlineGroup(["a": .failed, "b": .failed, "c": .succeeded])
        #expect(group.outcomeBadge == "(2条失败)")
    }

    @Test
    func denialShownWhenNoFailures() {
        let group = inlineGroup(["a": .denied, "b": .succeeded])
        #expect(group.outcomeBadge == "(1条已拒绝)")
    }

    @Test
    func failureTakesPriorityOverDenial() {
        let group = inlineGroup(["a": .failed, "b": .denied])
        #expect(group.outcomeBadge == "(1条失败)")
    }

    @Test
    func emptyReceiptsYieldNoBadge() {
        // Legacy sessions (or in-flight groups) resolve nothing → no badge,
        // falling back to the old badge-less rendering rather than lying.
        let group = inlineGroup([:])
        #expect(group.outcomeBadge == nil)
    }

    // MARK: - end-to-end render bakes the receipt into history

    @Test
    func settledIntentLineKeepsActionSummaryWithoutCompletionSuffix() {
        let call = AgentMessageToolCall(
            externalID: "call_1",
            toolName: "run_command",
            argumentsJSON: "{\"command\":\"make gen\"}"
        )
        var intent = AgentMessage(
            role: .assistant,
            content: "让我运行下一个生成器",
            toolCalls: [call],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        intent.settledToolReceipts = ["call_1": .succeeded]

        let rendered = AgentChatHistoryRenderer.render(messages: [intent], isDark: false)
        #expect(rendered.string.contains("让我运行下一个生成器"))
        #expect(rendered.string.contains("已运行1条命令"))
        #expect(!rendered.string.contains("✓ 完成"))
    }

    @Test
    func settledIntentLineRendersFailureReceipt() throws {
        let call = AgentMessageToolCall(
            externalID: "call_9",
            toolName: "run_command",
            argumentsJSON: "{\"command\":\"swift test\"}"
        )
        var intent = AgentMessage(
            role: .assistant,
            content: "让我进行最后一次全面验证",
            toolCalls: [call],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        intent.settledToolReceipts = ["call_9": .failed]

        let rendered = AgentChatHistoryRenderer.render(messages: [intent], isDark: false)
        #expect(rendered.string.contains("让我进行最后一次全面验证"))
        #expect(rendered.string.contains("已运行1条命令(1条失败)"))
        #expect(!rendered.string.contains("✗"))

        // Routine command failures (Agent will retry) must not paint the
        // receipt badge in alarm red — keep the same secondary tone as the
        // rest of the activity line.
        let badgeLocation = (rendered.string as NSString).range(of: "(1条失败)").location
        #expect(badgeLocation != NSNotFound)
        let badgeColor = try #require(rendered.attribute(
            .foregroundColor,
            at: badgeLocation,
            effectiveRange: nil
        ) as? NSColor)
        #expect(badgeColor.isEqual(NSColor.secondaryLabelColor))
        #expect(!badgeColor.isEqual(NSColor.systemRed))
    }

    @Test
    func receiptChangeBustsRenderCache() {
        // A call resolving running → failed must invalidate the render
        // cache, otherwise the exceptional receipt is skipped.
        let call = AgentMessageToolCall(
            externalID: "call_c",
            toolName: "run_command",
            argumentsJSON: "{\"command\":\"x\"}"
        )
        let base = AgentMessage(
            role: .assistant,
            content: "让我核实一下",
            toolCalls: [call],
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let first = AgentChatHistoryRenderer.render(messages: [base], isDark: false)

        var resolved = base
        resolved.settledToolReceipts = ["call_c": .failed]
        let second = AgentChatHistoryRenderer.render(messages: [resolved], isDark: false)

        #expect(!first.string.contains("(1条失败)"))
        #expect(second.string.contains("已运行1条命令(1条失败)"))
    }
}
