//
//  AgentChatHistoryTurnTimestampTests.swift
//  WillDeepTests
//
//  一轮 Agent 输出结束后，footer 末尾挂完成时间：平时透明占位，悬停到这一轮
//  时才由文本视图显色。
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite("Assistant turn timestamp")
struct AgentChatHistoryTurnTimestampTests {
    @Test("完成时间取各条回复 createdAt + 耗时的最大值")
    func completedAtUsesLatestFinish() {
        var first = AgentMessage(role: .assistant, content: "a", createdAt: Date(timeIntervalSince1970: 1_000))
        first.elapsedSeconds = 30
        var second = AgentMessage(role: .assistant, content: "b", createdAt: Date(timeIntervalSince1970: 1_010))
        second.elapsedSeconds = 5
        #expect(AgentAssistantTurnGrouping.completedAt(of: [first, second]) == Date(timeIntervalSince1970: 1_030))
    }

    @Test("footer 带透明的完成时间，整轮消息共用同一个 key")
    func footerReservesHiddenTimestamp() throws {
        let user = AgentMessage(role: .user, content: "升级 tokenhub", createdAt: Date(timeIntervalSince1970: 800_000_000))
        let progress = AgentMessage(role: .assistant, content: "我先看看集群。", createdAt: Date(timeIntervalSince1970: 800_000_010))
        var answer = AgentMessage(role: .assistant, content: "升级完成。", createdAt: Date(timeIntervalSince1970: 800_000_060))
        answer.elapsedSeconds = 12

        let rendered = AgentChatHistoryRenderer.render(messages: [user, progress, answer], isDark: false)

        var stamps: [(NSRange, String)] = []
        rendered.enumerateAttribute(
            .agentChatHistoryTurnTimestamp,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            if let key = value as? String { stamps.append((range, key)) }
        }
        let stamp = try #require(stamps.first)
        #expect(stamps.count == 1)

        let expected = AgentChatHistoryRenderer.formatFullTimestamp(Date(timeIntervalSince1970: 800_000_072))
        #expect((rendered.string as NSString).substring(with: stamp.0).contains(expected))
        #expect(rendered.attribute(.foregroundColor, at: NSMaxRange(stamp.0) - 1, effectiveRange: nil) as? NSColor == .clear)

        // 进度消息和最终回答都挂同一个 key，悬停到这一轮任意位置都能点亮时间。
        let body = (rendered.string as NSString)
        let progressIndex = body.range(of: "我先看看集群").location
        let answerIndex = body.range(of: "升级完成").location
        #expect(rendered.attribute(.agentChatHistoryAssistantTurnKey, at: progressIndex, effectiveRange: nil) as? String == stamp.1)
        #expect(rendered.attribute(.agentChatHistoryAssistantTurnKey, at: answerIndex, effectiveRange: nil) as? String == stamp.1)
        #expect(stamp.1 == answer.id.uuidString)
    }
}
