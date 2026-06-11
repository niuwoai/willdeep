//
//  AgentChatHistoryRendererTests.swift
//  WillDeepTests
//
//  Covers the TextKit Markdown renderer used by Agent chat history and
//  transcript reader windows.
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentChatHistoryRendererTests {
    @Test
    func rendersNonToolMarkdownWithoutRawMarkers() {
        let message = AgentMessage(
            role: .assistant,
            content: """
            # Title

            A **bold** word and `code`.

            - item

            ```swift
            let value = 1
            ```
            """
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("Assistant"))
        #expect(rendered.string.contains("Title"))
        #expect(rendered.string.contains("bold"))
        #expect(rendered.string.contains("code"))
        #expect(rendered.string.contains("swift  ⎘ Copy"))
        #expect(rendered.string.contains("let value = 1"))
        #expect(!rendered.string.contains("# Title"))
        #expect(!rendered.string.contains("**bold**"))
        #expect(!rendered.string.contains("```"))
    }

    @Test
    func keepsToolOutputPlainAndMonospaced() throws {
        let message = AgentMessage(
            role: .tool,
            content: "## not markdown\n`raw`",
            toolCallID: "call_1"
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("Tool output"))
        #expect(rendered.string.contains("## not markdown"))
        #expect(rendered.string.contains("`raw`"))

        let range = (rendered.string as NSString).range(of: "## not markdown")
        let font = try #require(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test
    func rendersToolCallOnlyAssistantMessageAsToolEvent() {
        let id = UUID()
        let message = AgentMessage(
            id: id,
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "call_1",
                    toolName: "run_command",
                    argumentsJSON: #"{"command":"git status --short"}"#
                )
            ]
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("▸ 执行了 1 条工具调用"))
        #expect(rendered.string.contains("run_command  command: git status --short"))
        #expect(!rendered.string.contains("Tool calls"))
        #expect(!rendered.string.contains("Assistant"))
    }

    @Test
    func collapsesAndExpandsConsecutiveToolCalls() {
        let firstID = UUID()
        let secondID = UUID()
        let messages = [
            AgentMessage(
                id: firstID,
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentMessageToolCall(
                        externalID: "call_1",
                        toolName: "run_command",
                        argumentsJSON: #"{"command":"ls /Users/rocky/Sites/Teamify && git status --short"}"#
                    )
                ]
            ),
            AgentMessage(
                id: secondID,
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentMessageToolCall(
                        externalID: "call_2",
                        toolName: "read_file",
                        argumentsJSON: #"{"path":"/Users/rocky/Sites/Teamify/README.md","limit":120}"#
                    )
                ]
            )
        ]

        let collapsed = AgentChatHistoryRenderer.render(messages: messages, isDark: false)
        #expect(collapsed.string.contains("▸ 执行了 2 条工具调用"))
        #expect(!collapsed.string.contains("tool  read_file"))

        let groupID = "\(firstID.uuidString):\(secondID.uuidString)"
        let expanded = AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            expandedToolGroupIDs: [groupID]
        )
        #expect(expanded.string.contains("▾ 执行了 2 条工具调用"))
        #expect(expanded.string.contains("tool  run_command  command: ls /Users/rocky/Sites/Teamify && git status --short"))
        #expect(expanded.string.contains("tool  read_file  path: /Users/rocky/Sites/Teamify/README.md"))
    }

    /// Short args fit fully in the inline preview → no "完整参数 X B"
    /// tail. The old behavior unconditionally appended a byte size
    /// even when the args were already 100% visible above, producing
    /// the cryptic "25 B args" the user complained about.
    @Test
    func shortToolArgsHaveNoTruncationTail() {
        let id = UUID()
        let message = AgentMessage(
            id: id,
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "call_short",
                    toolName: "read_file",
                    argumentsJSON: #"{"path":"deployment.md"}"#
                )
            ]
        )

        let groupID = "\(id.uuidString)"
        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            expandedToolGroupIDs: [groupID]
        )
        #expect(rendered.string.contains("tool  read_file  path: deployment.md"))
        #expect(!rendered.string.contains("B args"))
        #expect(!rendered.string.contains("完整参数"))
    }

    /// A long single-arg value that has to be sliced with `...` MUST
    /// surface "完整参数 X.X KB" so the user knows there's hidden
    /// content. This is the only case where the byte size adds info.
    @Test
    func truncatedLongToolArgsShowFullSizeTail() {
        let id = UUID()
        let longCommand = String(repeating: "a", count: 800)
        let message = AgentMessage(
            id: id,
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "call_long",
                    toolName: "run_command",
                    argumentsJSON: #"{"command":"\#(longCommand)"}"#
                )
            ]
        )

        let groupID = "\(id.uuidString)"
        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            expandedToolGroupIDs: [groupID]
        )
        #expect(rendered.string.contains("..."))
        #expect(rendered.string.contains("完整参数"))
    }

    /// When a dict has > 2 keys we only render the first 2 (preferred
    /// or alphabetical) — the rest are hidden. Surface the full byte
    /// size so the user knows there are dropped keys, not just a
    /// trimmed value.
    @Test
    func dictWithMoreThanTwoKeysShowsFullSizeTail() {
        let id = UUID()
        let message = AgentMessage(
            id: id,
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "call_dict",
                    toolName: "read_file",
                    argumentsJSON: #"{"path":"a.md","limit":10,"offset":0,"encoding":"utf-8"}"#
                )
            ]
        )

        let groupID = "\(id.uuidString)"
        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            expandedToolGroupIDs: [groupID]
        )
        #expect(rendered.string.contains("完整参数"))
    }

    /// `argumentsJSON == "{}"` means the model called a no-arg tool.
    /// The old code rendered "tool  toolname  · 2 B args" — pure
    /// noise. New code drops the tail entirely.
    @Test
    func emptyArgsRenderJustToolNameWithoutTail() {
        let id = UUID()
        let message = AgentMessage(
            id: id,
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "call_empty",
                    toolName: "list_skills",
                    argumentsJSON: "{}"
                )
            ]
        )

        let groupID = "\(id.uuidString)"
        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            expandedToolGroupIDs: [groupID]
        )
        #expect(rendered.string.contains("tool  list_skills"))
        #expect(!rendered.string.contains("B args"))
        #expect(!rendered.string.contains("完整参数"))
    }

    @Test
    func rendersMessageFooterCopyStatsAndRetry() throws {
        let user = AgentMessage(
            role: .user,
            content: "hello"
        )
        let assistant = AgentMessage(
            role: .assistant,
            content: "done",
            usageTokens: 3_500,
            promptTokens: 1_240,
            completionTokens: 2_260,
            elapsedSeconds: 8.4
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [user, assistant], isDark: false)

        #expect(rendered.string.contains("You\nhello"))
        #expect(rendered.string.contains("✦ Assistant\ndone"))
        #expect(!rendered.string.contains("YOU"))
        #expect(!rendered.string.contains("hello\n⎘"))
        #expect(rendered.string.contains("done\n⎘  ◷ 8.4s  in 1.2k · out 2.3k  ↻"))

        let assistantCopyRange = (rendered.string as NSString).range(of: "done\n⎘")
        let assistantCopyLocation = assistantCopyRange.location + "done\n".count
        let copyFont = try #require(rendered.attribute(
            .font,
            at: assistantCopyLocation,
            effectiveRange: nil
        ) as? NSFont)
        #expect(copyFont.pointSize >= 16)

        let elapsedIconRange = (rendered.string as NSString).range(of: "◷")
        let elapsedIconFont = try #require(rendered.attribute(
            .font,
            at: elapsedIconRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(elapsedIconFont.pointSize >= 16)

        let tokenRange = (rendered.string as NSString).range(of: "in 1.2k")
        let tokenFont = try #require(rendered.attribute(
            .font,
            at: tokenRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(tokenFont.pointSize >= 11)

        let retryRange = (rendered.string as NSString).range(of: "↻")
        let retryFont = try #require(rendered.attribute(
            .font,
            at: retryRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(retryFont.pointSize >= 13)
        #expect(retryFont.pointSize < copyFont.pointSize)
    }

    @Test
    func marksMarkdownTablesForTextKitTableChrome() throws {
        let message = AgentMessage(
            role: .assistant,
            content: """
            最近提交总结（近 15 条）

            | 时间 | 提交 | 作者 | 说明 |
            | --- | --- | --- | --- |
            | 06-04 13:47 | `1633595` | insight68 | 合并 main 分支 |
            | 06-04 13:33 | `561a2e9` | insight68 | **hermes** 相关 |
            """
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("时间"))
        #expect(rendered.string.contains("作者"))
        #expect(rendered.string.contains("─┼─"))

        let tableRange = (rendered.string as NSString).range(of: "时间")
        #expect(tableRange.location != NSNotFound)
        let tableID = try #require(rendered.attribute(
            .agentChatHistoryTableBlockID,
            at: tableRange.location,
            effectiveRange: nil
        ) as? NSNumber)
        #expect(tableID.intValue == 0)

        let paragraphStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: tableRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(paragraphStyle.lineSpacing >= 2)
        // 用户反馈：表格紧贴前后正文一团糟。`tableBlockParagraphStyle`
        // 必须在该段范围内同时设置 paragraphSpacingBefore（上 margin）
        // 和 paragraphSpacing（下 margin）。两个 > 0 才算正常生效；
        // 别的回归会把其中一个意外清零。
        #expect(paragraphStyle.paragraphSpacingBefore > 0)
        #expect(paragraphStyle.paragraphSpacing > 0)
    }

    @Test
    func headingBlocksGetVerticalAirAboveAndBelow() throws {
        // 同样的体验问题：`## 段标题` 黏在前一段尾巴上、和正文也没拉开。
        // 渲染时 heading 范围应当被标 `agentChatHistoryHeadingLevel`，
        // 且其 paragraphStyle 上下间距都 > 0。
        let message = AgentMessage(
            role: .assistant,
            content: """
            前置正文一行。

            ## 组织架构与权限

            紧接着的正文，不应该黏在标题屁股上。
            """
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        let headingRange = (rendered.string as NSString).range(of: "组织架构与权限")
        #expect(headingRange.location != NSNotFound)

        let level = try #require(rendered.attribute(
            .agentChatHistoryHeadingLevel,
            at: headingRange.location,
            effectiveRange: nil
        ) as? NSNumber)
        #expect(level.intValue == 2)

        let style = try #require(rendered.attribute(
            .paragraphStyle,
            at: headingRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(style.paragraphSpacingBefore > 0)
        #expect(style.paragraphSpacing > 0)
    }

    @Test
    func reservesUserFooterSpaceAndRevealsItOnlyOnHover() throws {
        let id = UUID()
        let user = AgentMessage(
            id: id,
            role: .user,
            content: "hello",
            createdAt: Date(timeIntervalSince1970: 750_000_000)
        )

        let plain = AgentChatHistoryRenderer.render(messages: [user], isDark: false)
        #expect(plain.string.contains("You\nhello"))
        #expect(plain.string.contains("⎘"))
        let hiddenCopyRange = (plain.string as NSString).range(of: "⎘")
        #expect(hiddenCopyRange.location != NSNotFound)
        #expect(plain.attribute(.link, at: hiddenCopyRange.location, effectiveRange: nil) == nil)
        #expect(plain.attribute(
            NSAttributedString.Key("AgentChatHistoryMessageCopyText"),
            at: hiddenCopyRange.location,
            effectiveRange: nil
        ) == nil)
        let hiddenColor = try #require(plain.attribute(
            .foregroundColor,
            at: hiddenCopyRange.location,
            effectiveRange: nil
        ) as? NSColor)
        #expect(hiddenColor.alphaComponent == 0)

        let hovered = AgentChatHistoryRenderer.render(
            messages: [user],
            isDark: false,
            hoveredUserMessageID: id
        )
        #expect(hovered.string.contains("You\nhello"))
        #expect(hovered.string.contains("⎘"))
        let visibleCopyRange = (hovered.string as NSString).range(of: "⎘")
        #expect(visibleCopyRange.location != NSNotFound)
        #expect(hovered.attribute(.link, at: visibleCopyRange.location, effectiveRange: nil) != nil)
        #expect(hovered.attribute(
            NSAttributedString.Key("AgentChatHistoryMessageCopyText"),
            at: visibleCopyRange.location,
            effectiveRange: nil
        ) as? String == "hello")
        let visibleColor = try #require(hovered.attribute(
            .foregroundColor,
            at: visibleCopyRange.location,
            effectiveRange: nil
        ) as? NSColor)
        #expect(visibleColor.alphaComponent > 0)
    }

    @Test
    func keepsUserMessageBodyLeftAlignedInsideItsColumn() throws {
        let user = AgentMessage(
            role: .user,
            content: """
            第一行内容
            第二行内容也应该从左侧开始
            """
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [user], isDark: false)
        let bodyRange = (rendered.string as NSString).range(of: "第一行内容")
        let paragraphStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: bodyRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)

        #expect(paragraphStyle.alignment == .left)
        #expect(paragraphStyle.headIndent > 0)
        #expect(paragraphStyle.tailIndent < 0)
    }

    @Test
    func normalizesHtmlDetailsAndLongRulesForChatMarkdown() {
        let message = AgentMessage(
            role: .assistant,
            content: """
            修复方法：
            ----

            <details><summary>该文件是此次合并新引入的：</summary>

            提交 3e05c43 新增。</details>
            """
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("────────────────────────"))
        #expect(rendered.string.contains("html  ⎘ Copy"))
        #expect(rendered.string.contains("<details><summary>该文件是此次合并新引入的：</summary>"))
        #expect(rendered.string.contains("提交 3e05c43 新增。</details>"))
        #expect(!rendered.string.contains("----"))
    }

    @Test
    func cacheKeyTracksEditedEarlierContentWithSameLength() {
        let id = UUID()
        let first = [
            AgentMessage(id: id, role: .assistant, content: "# One")
        ]
        let second = [
            AgentMessage(id: id, role: .assistant, content: "# Two")
        ]

        _ = AgentChatHistoryRenderer.render(messages: first, isDark: false)
        let rendered = AgentChatHistoryRenderer.render(messages: second, isDark: false)

        #expect(rendered.string.contains("Two"))
        #expect(!rendered.string.contains("One"))
    }
}
