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
    func longMessagePreviewKeepsHeadAndTail() {
        let content = String(repeating: "A", count: 120)
            + "MIDDLE_SHOULD_BE_OMITTED"
            + String(repeating: "Z", count: 120)

        let preview = AgentMessageContentPreview.make(
            content: content,
            maxCharacters: 160,
            omissionText: { "[\($0) omitted]" }
        )

        #expect(preview.content.hasPrefix(String(repeating: "A", count: 20)))
        #expect(preview.content.hasSuffix(String(repeating: "Z", count: 20)))
        #expect(preview.content.contains("omitted"))
        #expect(!preview.content.contains("MIDDLE_SHOULD_BE_OMITTED"))
        #expect(preview.omittedCharacters > 0)
        #expect(preview.content.count <= 160)
    }

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
        #expect(rendered.string.contains("swift"))
        #expect(rendered.string.contains(" Copy"))
        #expect(firstAttributeRange(.agentChatHistoryCodeCopyText, containing: "let value = 1", in: rendered) != nil)
        #expect(rendered.string.contains("let value = 1"))
        let codeBodyRange = try? #require(firstAttributeRange(
            .agentChatHistoryCodeBlockBodyID,
            containing: "let value = 1",
            in: rendered
        ))
        #expect(codeBodyRange != nil)
        if let codeBodyRange {
            let paragraphStyle = rendered.attribute(
                .paragraphStyle,
                at: codeBodyRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(paragraphStyle?.lineBreakMode == .byClipping)
        }
        #expect(!rendered.string.contains("# Title"))
        #expect(!rendered.string.contains("**bold**"))
        #expect(!rendered.string.contains("```"))
    }

    @Test
    func codeCopyRangeExpandsAcrossIconAndLabel() {
        let button = AgentChatHistoryCodeCopyChrome.button(
            copied: false,
            code: "let value = 1",
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )

        let iconOnlyRange = NSRange(location: 0, length: 1)
        let resolved = AgentChatHistoryCopyRangeResolver.contiguousRange(
            in: button,
            key: .agentChatHistoryCodeCopyText,
            matching: "let value = 1",
            seedRange: iconOnlyRange
        )

        #expect(resolved.location == 0)
        #expect(resolved.length == button.length)
        #expect((button.string as NSString).substring(with: resolved).contains(" Copy"))
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
    func preservesUserMessageLineBreaksInHistory() {
        let message = AgentMessage(
            role: .user,
            content: """
            lsof /dev/ttys* 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn

            16 zsh 3 sort 2 sleep 2 bash 1 uniq 1 lsof 1 COMMAND 1 awk
            """
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("sort -rn\n\n16 zsh"))
    }

    @Test
    func rendersPastedTextAttachmentsAsClickableLinks() throws {
        let attachment = AgentTextAttachment(
            filename: "已粘贴的文本.txt",
            content: "line one\nline two"
        )
        let message = AgentMessage(
            role: .user,
            content: "",
            textAttachments: [attachment]
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        let range = try #require(firstAttributeRange(
            .agentChatHistoryTextAttachment,
            containing: "已粘贴的文本.txt",
            in: rendered
        ))
        let payload = try #require(rendered.attribute(
            .agentChatHistoryTextAttachment,
            at: range.location,
            effectiveRange: nil
        ) as? AgentTextAttachment)

        #expect(payload.id == attachment.id)
        #expect(payload.content == "line one\nline two")
        #expect(rendered.attribute(.link, at: range.location, effectiveRange: nil) as? String == AgentChatHistoryTextAttachmentLink.value)
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

        #expect(rendered.string.contains("▸ 已运行 1 条命令"))
        #expect(!rendered.string.contains("run_command  command: git status --short"))
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
        #expect(collapsed.string.contains("▸ 已读取 1 个文件 · 已运行 1 条命令"))
        #expect(!collapsed.string.contains("tool  read_file"))

        let groupID = "\(firstID.uuidString):\(secondID.uuidString)"
        let expanded = AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            expandedToolGroupIDs: [groupID]
        )
        #expect(expanded.string.contains("▾ 已读取 1 个文件 · 已运行 1 条命令"))
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
        #expect(rendered.string.contains("  ◷ 8.4s  in 1.2k · out 2.3k  ↻"))
        #expect(firstAttributeRange(.agentChatHistoryMessageCopyText, value: "hello", in: rendered) == nil)

        let assistantCopyRange = try #require(firstAttributeRange(
            .agentChatHistoryMessageCopyText,
            value: "done",
            in: rendered
        ))
        let assistantCopyLocation = assistantCopyRange.location
        #expect(rendered.attribute(.link, at: assistantCopyLocation, effectiveRange: nil) != nil)
        let doneRange = (rendered.string as NSString).range(of: "done")
        #expect(doneRange.location != NSNotFound)
        #expect(assistantCopyLocation > doneRange.location)
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
        // The "open in standalone window" affordance is now a trailing icon
        // attachment (no text label), shown via the attachment character.
        let iconRange = (rendered.string as NSString).range(of: "\u{FFFC}")
        #expect(iconRange.location != NSNotFound)

        let tableRange = (rendered.string as NSString).range(of: "时间")
        #expect(tableRange.location != NSNotFound)
        let tableID = try #require(rendered.attribute(
            .agentChatHistoryTableBlockID,
            at: tableRange.location,
            effectiveRange: nil
        ) as? NSNumber)
        #expect(tableID.intValue == 0)

        let payload = try #require(rendered.attribute(
            .agentChatHistoryTablePayload,
            at: tableRange.location,
            effectiveRange: nil
        ) as? AgentMarkdownTablePayload)
        #expect(payload.headers == ["时间", "提交", "作者", "说明"])
        #expect(payload.rows.count == 2)
        #expect(payload.rows[0][1] == "`1633595`")
        #expect(rendered.attribute(.link, at: tableRange.location, effectiveRange: nil) as? String == AgentChatHistoryTableLink.value)

        #expect(rendered.attribute(.link, at: iconRange.location, effectiveRange: nil) as? String == AgentChatHistoryTableLink.value)
        let linkPayload = try #require(rendered.attribute(
            .agentChatHistoryTablePayload,
            at: iconRange.location,
            effectiveRange: nil
        ) as? AgentMarkdownTablePayload)
        #expect(linkPayload.headers == payload.headers)
        #expect(linkPayload.rows == payload.rows)

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
        let hiddenCopyRange = try #require(firstCopyIconRange(in: plain))
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
        let visibleCopyRange = try #require(firstAttributeRange(
            .agentChatHistoryMessageCopyText,
            value: "hello",
            in: hovered
        ))
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

    private func firstAttributeRange(
        _ key: NSAttributedString.Key,
        value expectedValue: String,
        in attributed: NSAttributedString
    ) -> NSRange? {
        var found = NSRange(location: NSNotFound, length: 0)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(key, in: fullRange) { value, range, stop in
            guard (value as? String) == expectedValue else { return }
            found = range
            stop.pointee = true
        }
        return found.location == NSNotFound ? nil : found
    }

    private func firstAttributeRange(
        _ key: NSAttributedString.Key,
        containing expectedSubstring: String,
        in attributed: NSAttributedString
    ) -> NSRange? {
        var found = NSRange(location: NSNotFound, length: 0)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(key, in: fullRange) { value, range, stop in
            guard value != nil else { return }
            let rangeText = (attributed.string as NSString).substring(with: range)
            let stringValue = value as? String
            guard stringValue?.contains(expectedSubstring) == true
                    || rangeText.contains(expectedSubstring) else { return }
            found = range
            stop.pointee = true
        }
        return found.location == NSNotFound ? nil : found
    }

    private func firstCopyIconRange(in attributed: NSAttributedString) -> NSRange? {
        let fullRange = NSRange(location: 0, length: attributed.length)
        var found = NSRange(location: NSNotFound, length: 0)
        attributed.enumerateAttribute(.attachment, in: fullRange) { value, range, stop in
            guard value != nil else { return }
            found = range
            stop.pointee = true
        }
        if found.location != NSNotFound {
            return found
        }

        for fallbackSymbol in ["⧉", "⎘"] {
            let range = (attributed.string as NSString).range(of: fallbackSymbol)
            if range.location != NSNotFound {
                return range
            }
        }
        return nil
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
        #expect(rendered.string.contains("html"))
        #expect(rendered.string.contains(" Copy"))
        #expect(firstAttributeRange(
            .agentChatHistoryCodeCopyText,
            containing: "<details><summary>",
            in: rendered
        ) != nil)
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

    /// 收集一条 assistant 消息渲染后被「成文件 chip」的所有子串(即带
    /// `.agentChatHistoryFilePath` 属性、值为 rawPath 的片段)。
    private func chippedFilePaths(in content: String) -> Set<String> {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [AgentMessage(role: .assistant, content: content)],
            isDark: false
        )
        var paths: Set<String> = []
        rendered.enumerateAttribute(
            .agentChatHistoryFilePath,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let path = value as? String { paths.insert(path) }
        }
        return paths
    }

    /// 带一个斜杠的普通词不应被染成可点文件链接(用户反馈:标准号
    /// `GB/T 45654—2025` 被误判成文件夹引用)。
    @Test
    func bareSlashWordsAreNotMistakenForFilePaths() {
        let chipped = chippedFilePaths(
            in: "标准 GB/T 45654—2025 与 TCP/IP、I/O、和/或,以及日期 01/02 都只是普通文本。"
        )
        #expect(!chipped.contains("GB/T"))
        #expect(!chipped.contains("TCP/IP"))
        #expect(!chipped.contains("I/O"))
        #expect(chipped.isEmpty)
    }

    /// 真实文件引用照常成 chip:带已知后缀的(可含目录前缀)、以及带路径
    /// 锚点(`/`、`~/`)的绝对/家目录路径。
    @Test
    func genuineFilePathsStillBecomeChips() {
        let extPaths = chippedFilePaths(
            in: "见 README.md 和 src/main.ts 还有 Xedit/AppState.swift:81 这几处。"
        )
        #expect(extPaths.contains("README.md"))
        #expect(extPaths.contains("src/main.ts"))
        #expect(extPaths.contains("Xedit/AppState.swift:81"))

        let anchored = chippedFilePaths(
            in: "可执行文件在 /usr/bin/ssh,配置在 ~/.willdeep/skills 里。"
        )
        #expect(anchored.contains("/usr/bin/ssh"))
        #expect(anchored.contains("~/.willdeep/skills"))
    }
}
