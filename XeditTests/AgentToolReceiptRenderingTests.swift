//
//  AgentToolReceiptRenderingTests.swift
//  WillDeepTests
//
//  Covers the "intent line → ✓/✗ outcome receipt" rendering added so a
//  settled assistant intent ("让我运行下一个生成器") shows whether the
//  tool it triggered actually succeeded, instead of dangling with no
//  result. Two layers: the group-level `outcomeBadge` verdict logic, and
//  the end-to-end formatter render that bakes it into the TextKit history.
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
    func allSucceededYieldsCheckmark() {
        let group = inlineGroup(["a": .succeeded, "b": .succeeded])
        #expect(group.outcomeBadge == "✓ 完成")
    }

    @Test
    func anyFailureWinsOverSuccess() {
        // A failure is the thing the user most needs to see, so it beats
        // co-occurring successes in the single-line verdict.
        let group = inlineGroup(["a": .succeeded, "b": .failed])
        #expect(group.outcomeBadge == "✗ 1 失败")
    }

    @Test
    func failureCountIsReported() {
        let group = inlineGroup(["a": .failed, "b": .failed, "c": .succeeded])
        #expect(group.outcomeBadge == "✗ 2 失败")
    }

    @Test
    func denialShownWhenNoFailures() {
        let group = inlineGroup(["a": .denied, "b": .succeeded])
        #expect(group.outcomeBadge == "✗ 1 已拒绝")
    }

    @Test
    func failureTakesPriorityOverDenial() {
        let group = inlineGroup(["a": .failed, "b": .denied])
        #expect(group.outcomeBadge == "✗ 1 失败")
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
    func settledIntentLineRendersSuccessReceipt() {
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
        #expect(rendered.string.contains("✓ 完成"))
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
        #expect(rendered.string.contains("✗ 1 失败"))

        // Routine command failures (Agent will retry) must not paint the
        // receipt badge in alarm red — keep the same secondary tone as the
        // rest of the activity line.
        let badgeLocation = (rendered.string as NSString).range(of: "✗ 1 失败").location
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
        // A call resolving running → succeeded must invalidate the render
        // cache, otherwise the ✓ badge is skipped on the second render.
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
        resolved.settledToolReceipts = ["call_c": .succeeded]
        let second = AgentChatHistoryRenderer.render(messages: [resolved], isDark: false)

        #expect(!first.string.contains("✓ 完成"))
        #expect(second.string.contains("✓ 完成"))
    }
}
