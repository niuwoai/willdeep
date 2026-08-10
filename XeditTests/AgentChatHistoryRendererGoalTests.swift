//
//  AgentChatHistoryRendererGoalTests.swift
//  WillDeepTests
//
//  Split out of AgentChatHistoryRendererTests.swift to keep files under the
//  repository size limit. Same renderer, second half of the coverage: Goal
//  transcript stability, workflow and tool receipt cards, and citations.
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentChatHistoryRendererGoalTests {
    @Test
    func goalModeKeepsEveryVisibleMessageWhenNoSummaryExists() {
        let user = AgentMessage(role: .user, content: "继续")
        let planning = AgentMessage(role: .assistant, content: "Planning next pass")
        let verifying = AgentMessage(role: .assistant, content: "Verifying current files")

        let displayed = AgentTranscriptModePresentation.modeInvariantMessages(
            from: [user, planning, verifying]
        )

        #expect(displayed.map(\.id) == [user.id, planning.id, verifying.id])
    }

    @Test
    func goalModeDoesNotRewritePersistedAssistantMessages() {
        let user = AgentMessage(role: .user, content: "交付")
        let final = AgentMessage(
            role: .assistant,
            content: """
            已完成。

            ```progress
            1: done
            ```
            """,
            toolCalls: [AgentMessageToolCall(
                externalID: "goal-settled-command",
                toolName: "terminal_send_command",
                argumentsJSON: #"{"command":"swift test"}"#
            )]
        )

        let displayed = AgentTranscriptModePresentation.modeInvariantMessages(from: [user, final])

        #expect(displayed.map(\.id) == [user.id, final.id])
        #expect(displayed.last?.content == final.content)
        #expect(displayed.last?.toolCalls == final.toolCalls)
    }

    @Test
    @MainActor
    func rendersGoalRoundWithoutModeDrivenCompactionForDesignQA() throws {
        let startedAt = Date(timeIntervalSince1970: 4_000)
        let user = AgentMessage(role: .user, content: "完成 Goal 回合", createdAt: startedAt)
        let raw = [
            user,
            AgentMessage(
                role: .assistant,
                content: "Planning Goal transcript presentation",
                promptTokens: 12_000,
                completionTokens: 40,
                elapsedSeconds: 120,
                createdAt: startedAt.addingTimeInterval(1)
            ),
            AgentMessage(
                role: .assistant,
                content: "第一次渲染没有收口，正在调整历史分组。",
                toolCalls: [AgentMessageToolCall(
                    externalID: "goal-design-qa-command",
                    toolName: "terminal_send_command",
                    argumentsJSON: #"{"command":"swift test"}"#
                )],
                promptTokens: 14_000,
                completionTokens: 80,
                elapsedSeconds: 180,
                createdAt: startedAt.addingTimeInterval(121)
            ),
            AgentMessage(
                role: .assistant,
                content: """
                完成了，Goal 回合现在会在结束后收束为交付小结。

                结果：

                - 执行中的读取、搜索、编辑和命令仍会实时展示。
                - 回合结束后只保留最终结果与生成的图片、文档等真实产物。
                - 中间尝试、命令正文和内部 `goal-check` 协议不再堆在聊天区。

                本次推进：

                - 处理时长、Token 与模型信息继续按完整回合聚合。
                - 原始消息和工具记录没有删除，审计、重试和任务面板仍可使用。

                验证通过：

                - Goal 历史收口、产物保留、失败兜底与协议隐藏回归测试通过。

                ```progress
                1: done
                ```

                ```goal-check
                1: done
                ```
                """,
                promptTokens: 18_000,
                completionTokens: 620,
                elapsedSeconds: 468,
                createdAt: startedAt.addingTimeInterval(302)
            ),
        ]
        let displayed = AgentTranscriptModePresentation.modeInvariantMessages(from: raw)
            .filter { $0.role == .assistant }
        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = NSSize(width: 32, height: 24)
        view.frame = NSRect(x: 0, y: 0, width: 773, height: 578)
        view.textContainer?.size = NSSize(width: 709, height: CGFloat.greatestFiniteMagnitude)
        view.applyMessages(
            displayed,
            isDark: false,
            assistantTurnContextMessages: raw,
            baseFontSize: 14
        )
        let planningTitle = try #require(
            AgentActivityHeadlinePresentation.make(
                from: "Planning Goal transcript presentation"
            )?.title
        )

        #expect(view.string.contains("完成了，Goal 回合现在会在结束后收束为交付小结"))
        #expect(view.string.contains(planningTitle))
        #expect(view.string.contains("第一次渲染没有收口"))
        #expect(!view.string.contains("swift test"))
        #expect(!view.string.contains("1: done"))
        #expect(view.string.contains(L10n.AgentTurnProgress.title))

        let outputPath = ProcessInfo.processInfo.environment[
            "WILLDEEP_GOAL_SUMMARY_DESIGN_QA_OUTPUT"
        ] ?? "/private/tmp/Xedit-goal-round-summary-design-qa.png"
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @Test
    func activeAssistantTurnKeepsOneProcessingHeaderAndNoPrematureFooter() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let user = AgentMessage(role: .user, content: "continue", createdAt: startedAt)
        let first = AgentMessage(
            role: .assistant,
            content: "working update",
            promptTokens: 100,
            completionTokens: 20,
            elapsedSeconds: 4,
            createdAt: startedAt.addingTimeInterval(1)
        )
        let toolLoop = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentMessageToolCall(
                externalID: "terminal-1",
                toolName: "terminal_send_command",
                argumentsJSON: #"{"command":"true"}"#
            )],
            promptTokens: 50,
            completionTokens: 10,
            elapsedSeconds: 2,
            createdAt: startedAt.addingTimeInterval(6)
        )

        let rendered = AgentChatHistoryRenderer.render(
            messages: [user, first],
            isDark: false,
            assistantTurnContextMessages: [user, first, toolLoop],
            isAssistantTurnActive: true
        )

        #expect(occurrences(of: L10n.MessageFooter.processing, in: rendered.string) == 1)
        #expect(attributeCount(.agentChatHistoryAssistantStatusDividerColor, in: rendered) == 1)
        #expect(!rendered.string.contains("150/30"))
        #expect(firstAttributeRange(
            .agentChatHistoryMessageCopyText,
            value: "working update",
            in: rendered
        ) == nil)
    }

    @Test
    func nextUserInputStartsANewAssistantTurnChrome() {
        let startedAt = Date(timeIntervalSince1970: 2_500)
        let firstUser = AgentMessage(role: .user, content: "first", createdAt: startedAt)
        let firstUpdate = AgentMessage(
            role: .assistant,
            content: "first update",
            promptTokens: 100,
            completionTokens: 20,
            elapsedSeconds: 2,
            createdAt: startedAt.addingTimeInterval(1)
        )
        let firstFinal = AgentMessage(
            role: .assistant,
            content: "first final",
            promptTokens: 200,
            completionTokens: 40,
            elapsedSeconds: 3,
            createdAt: startedAt.addingTimeInterval(5)
        )
        let secondUser = AgentMessage(
            role: .user,
            content: "second",
            createdAt: startedAt.addingTimeInterval(10)
        )
        let secondFinal = AgentMessage(
            role: .assistant,
            content: "second final",
            promptTokens: 400,
            completionTokens: 80,
            elapsedSeconds: 4,
            createdAt: startedAt.addingTimeInterval(11)
        )
        let messages = [firstUser, firstUpdate, firstFinal, secondUser, secondFinal]

        let rendered = AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            assistantTurnContextMessages: messages
        )

        #expect(attributeCount(.agentChatHistoryAssistantStatusDividerColor, in: rendered) == 2)
        #expect(occurrences(of: "300/60", in: rendered.string) == 1)
        #expect(occurrences(of: "400/80", in: rendered.string) == 1)
    }

    @Test
    @MainActor
    func rendersGroupedAssistantTurnForDesignQA() throws {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let user = AgentMessage(role: .user, content: "继续啊", createdAt: startedAt)
        let first = AgentMessage(
            role: .assistant,
            content: "正在检查消息分组逻辑。",
            promptTokens: 18_400,
            completionTokens: 72,
            elapsedSeconds: 4,
            createdAt: startedAt.addingTimeInterval(1)
        )
        let toolLoop = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentMessageToolCall(
                externalID: "edit-1",
                toolName: "apply_patch",
                argumentsJSON: #"{"path":"AgentChatHistoryFormatter.swift"}"#
            )],
            promptTokens: 15_600,
            completionTokens: 84,
            elapsedSeconds: 3,
            createdAt: startedAt.addingTimeInterval(6)
        )
        let final = AgentMessage(
            role: .assistant,
            content: "已完成：同一轮只保留一组处理状态和统计。",
            promptTokens: 15_600,
            completionTokens: 210,
            elapsedSeconds: 6,
            createdAt: startedAt.addingTimeInterval(12)
        )
        let visibleMessages = [user, first, final]
        let contextMessages = [user, first, toolLoop, final]
        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.frame = NSRect(x: 0, y: 0, width: 636, height: 499)
        view.textContainer?.size = NSSize(width: 604, height: CGFloat.greatestFiniteMagnitude)
        view.applyMessages(
            visibleMessages,
            isDark: false,
            assistantTurnContextMessages: contextMessages,
            baseFontSize: 14
        )

        #expect(occurrences(of: L10n.MessageFooter.processedDuration("18s"), in: view.string) == 1)
        #expect(occurrences(of: "49.6k/366", in: view.string) == 1)

        let defaultOutputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/visual-qa/assistant-turn-grouping/implementation-rc10.png")
        let outputPath = ProcessInfo.processInfo.environment[
            "WILLDEEP_TURN_GROUP_DESIGN_QA_OUTPUT"
        ] ?? defaultOutputURL.path
        guard FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
        ) else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @Test
    @MainActor
    func rendersShortModelSwitchDividerAndMergedCommandsForDesignQA() throws {
        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment[
                "WILLDEEP_COMMAND_GROUP_QA_OUTPUT"
            ] ?? "/tmp/Xedit-command-group-design-qa",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let commandCalls = (1...26).map { index in
            AgentMessageToolCall(
                externalID: "command-\(index)",
                toolName: "run_command",
                argumentsJSON: #"{"command":"check-step-\#(index)"}"#
            )
        }
        let messages = [
            AgentMessage(role: .assistant, content: "", toolCalls: commandCalls),
            AgentMessage(
                role: .system,
                content: L10n.AgentModelPicker.modelChanged(
                    from: "deepseek-v4-flash",
                    to: "deepseek-v4-pro"
                ),
                transcriptEvent: .modelChanged
            ),
            AgentMessage(role: .assistant, content: "继续分析运行结果。")
        ]
        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = NSSize(width: 40, height: 24)
        view.frame = NSRect(x: 0, y: 0, width: 1_126, height: 220)
        view.textContainer?.size = NSSize(width: 1_046, height: CGFloat.greatestFiniteMagnitude)
        view.applyMessages(
            messages,
            isDark: false,
            assistantTurnContextMessages: messages,
            baseFontSize: 14
        )
        view.layoutSubtreeIfNeeded()

        #expect(occurrences(of: "已运行26条命令", in: view.string) == 1)
        #expect(occurrences(of: "模型已从", in: view.string) == 1)

        let implementationURL = outputDirectory.appendingPathComponent(
            "model-switch-command-group-implementation.png"
        )
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: implementationURL, options: .atomic)

        guard let referencePath = ProcessInfo.processInfo.environment[
            "WILLDEEP_COMMAND_GROUP_QA_REFERENCE"
        ],
        let reference = NSImage(contentsOfFile: referencePath),
        let implementation = NSImage(contentsOf: implementationURL) else {
            return
        }

        let panelSize = NSSize(width: 1_126, height: 220)
        let comparison = NSImage(size: NSSize(width: panelSize.width, height: panelSize.height * 2))
        comparison.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: comparison.size).fill()
        let referenceCrop = NSRect(
            x: 0,
            y: max(0, reference.size.height - panelSize.height),
            width: reference.size.width,
            height: min(panelSize.height, reference.size.height)
        )
        reference.draw(
            in: NSRect(x: 0, y: panelSize.height, width: panelSize.width, height: panelSize.height),
            from: referenceCrop,
            operation: .copy,
            fraction: 1
        )
        implementation.draw(
            in: NSRect(origin: .zero, size: panelSize),
            from: NSRect(origin: .zero, size: implementation.size),
            operation: .copy,
            fraction: 1
        )
        comparison.unlockFocus()
        let comparisonTIFF = try #require(comparison.tiffRepresentation)
        let comparisonBitmap = try #require(NSBitmapImageRep(data: comparisonTIFF))
        let comparisonPNG = try #require(comparisonBitmap.representation(using: .png, properties: [:]))
        try comparisonPNG.write(
            to: outputDirectory.appendingPathComponent(
                "model-switch-command-group-comparison.png"
            ),
            options: .atomic
        )
    }

    @Test
    @MainActor
    func rendersTerminalSummaryAlignedWithAssistantBodyForDesignQA() throws {
        let outputDirectory = URL(
            fileURLWithPath: "/tmp/Xedit-terminal-summary-alignment-design-qa",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let terminalCalls = (1...4).map { index in
            AgentMessageToolCall(
                externalID: "terminal-operation-\(index)",
                toolName: "terminal_snapshot",
                argumentsJSON: #"{"max_chars":2000}"#
            )
        }
        let message = AgentMessage(
            role: .assistant,
            content: """
            明白，让我先看下侧边栏终端当前状态。

            终端的 K8s master 节点上，直接更新 Deployment 镜像。
            """,
            toolCalls: terminalCalls
        )
        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = NSSize(width: 18, height: 16)
        view.textContainer?.lineFragmentPadding = 0
        view.linkTextAttributes = [
            .underlineStyle: 0,
            .cursor: NSCursor.arrow,
        ]
        view.frame = NSRect(x: 0, y: 0, width: 587, height: 142)
        view.textContainer?.size = NSSize(width: 551, height: CGFloat.greatestFiniteMagnitude)
        view.applyMessages([message], isDark: false, baseFontSize: 14)
        view.layoutSubtreeIfNeeded()

        let bodyRange = (view.string as NSString).range(of: "明白，让我先看下侧边栏终端当前状态。")
        let summaryRange = (view.string as NSString).range(
            of: "\u{FFFC} 已执行4次终端操作"
        )
        let bodyGlyphRange = try #require(view.layoutManager?.glyphRange(
            forCharacterRange: bodyRange,
            actualCharacterRange: nil
        ))
        let summaryGlyphRange = try #require(view.layoutManager?.glyphRange(
            forCharacterRange: summaryRange,
            actualCharacterRange: nil
        ))
        let bodyRect = try #require(view.layoutManager?.boundingRect(
            forGlyphRange: bodyGlyphRange,
            in: view.textContainer!
        ))
        let summaryRect = try #require(view.layoutManager?.boundingRect(
            forGlyphRange: summaryGlyphRange,
            in: view.textContainer!
        ))
        #expect(abs(bodyRect.minX - summaryRect.minX) < 0.5)

        let outputURL = outputDirectory.appendingPathComponent("implementation.png")
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)
    }

    @Test
    @MainActor
    func rendersIconLedToolActivityTimelineForDesignQA() throws {
        let outputURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment[
                "WILLDEEP_TOOL_ACTIVITY_QA_OUTPUT"
            ] ?? "/tmp/Xedit-tool-activity-timeline-design-qa/implementation.png"
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var calls: [AgentMessageToolCall] = []
        calls += (1...5).map { index in
            AgentMessageToolCall(
                externalID: "read-\(index)",
                toolName: "read_file",
                argumentsJSON: #"{"path":"Xedit/File-\#(index).swift"}"#
            )
        }
        calls += (1...4).map { index in
            AgentMessageToolCall(
                externalID: "directory-\(index)",
                toolName: "list_directory",
                argumentsJSON: #"{"path":"Xedit/Section-\#(index)"}"#
            )
        }
        calls += (1...4).map { index in
            AgentMessageToolCall(
                externalID: "search-\(index)",
                toolName: "grep_files",
                argumentsJSON: #"{"pattern":"activity-\#(index)"}"#
            )
        }
        calls.append(AgentMessageToolCall(
            externalID: "git-status",
            toolName: "git_status",
            argumentsJSON: "{}"
        ))
        calls += (1...3).map { index in
            AgentMessageToolCall(
                externalID: "command-\(index)",
                toolName: "run_command",
                argumentsJSON: #"{"command":"verify-step-\#(index)"}"#
            )
        }

        let message = AgentMessage(
            role: .assistant,
            content: "我已经核对了工具活动摘要。下面按操作类型分行展示，便于快速扫读当前回合做过什么。",
            toolCalls: calls
        )
        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = NSSize(width: 18, height: 16)
        view.textContainer?.lineFragmentPadding = 0
        view.linkTextAttributes = [
            .underlineStyle: 0,
            .cursor: NSCursor.arrow,
        ]
        view.frame = NSRect(x: 0, y: 0, width: 684, height: 319)
        view.textContainer?.size = NSSize(
            width: 648,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.applyMessages([message], isDark: false, baseFontSize: 14)
        view.layoutSubtreeIfNeeded()

        let expectedRows = [
            "已读取5个文件",
            "已浏览4个目录",
            "已搜索代码4次",
            "已查看 Git 状态",
            "已运行3条命令",
        ]
        for row in expectedRows {
            #expect(view.string.contains(row))
        }
        #expect(!view.string.contains("已读取5个文件 · 已浏览4个目录"))

        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)
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

        let firstRowStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: tableRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let lastRowRange = (rendered.string as NSString).range(of: "06-04 13:33")
        let lastRowStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: lastRowRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(firstRowStyle.lineSpacing >= 2)
        // 上下 margin 只落在整个表格的首行和末行，避免每一行都被
        // paragraph spacing 撑开；表格块仍必须与前后正文明确分隔。
        #expect(firstRowStyle.paragraphSpacingBefore > 0)
        #expect(firstRowStyle.paragraphSpacing == 0)
        #expect(lastRowStyle.paragraphSpacingBefore == 0)
        #expect(lastRowStyle.paragraphSpacing > 0)
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
        #expect(plain.string.contains("hello"))
        #expect(!plain.string.contains("You"))
        let hiddenCopyRange = try #require(firstCopyIconRange(in: plain))
        #expect(plain.attribute(.agentChatHistoryUserMessageID, at: hiddenCopyRange.location, effectiveRange: nil) as? String == id.uuidString)
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
        let plainBodyRange = (plain.string as NSString).range(of: "hello")
        let hiddenFooterStart = NSMaxRange(plainBodyRange) + 1
        let hiddenTimestampColor = try #require(plain.attribute(
            .foregroundColor,
            at: hiddenFooterStart,
            effectiveRange: nil
        ) as? NSColor)
        #expect(hiddenTimestampColor.alphaComponent == 0)

        let hovered = AgentChatHistoryRenderer.render(
            messages: [user],
            isDark: false,
            hoveredUserMessageID: id
        )
        #expect(hovered.string.contains("hello"))
        #expect(!hovered.string.contains("You"))
        let visibleCopyRange = try #require(firstAttributeRange(
            .agentChatHistoryMessageCopyText,
            value: "hello",
            in: hovered
        ))
        #expect(hovered.attribute(.agentChatHistoryUserMessageID, at: visibleCopyRange.location, effectiveRange: nil) as? String == id.uuidString)
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
        let visibleTimestampColor = try #require(hovered.attribute(
            .foregroundColor,
            at: hiddenFooterStart,
            effectiveRange: nil
        ) as? NSColor)
        #expect(visibleTimestampColor.alphaComponent > 0)
        let visibleFooterStyle = try #require(hovered.attribute(
            .paragraphStyle,
            at: visibleCopyRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(visibleFooterStyle.paragraphSpacingBefore == AgentChatHistoryLayoutMetrics.userFooterTopSpacing)
        #expect(visibleFooterStyle.paragraphSpacing == AgentChatHistoryLayoutMetrics.userFooterBottomSpacing)
        #expect(visibleFooterStyle.tailIndent == AgentChatHistoryLayoutMetrics.userBodyTailIndent
            - AgentChatHistoryLayoutMetrics.userFooterTrailingInset)

        #expect(!AgentChatHistoryBubbleKind.assistant.drawsRoundedBackground)
        #expect(AgentChatHistoryBubbleKind.user.drawsRoundedBackground)
    }

    @Test
    func userBubbleInsetsAndTurnSpacingTrackNarrowLayoutWidth() throws {
        let layoutWidth: CGFloat = 640
        let assistant = AgentMessage(role: .assistant, content: "before")
        let user = AgentMessage(role: .user, content: "after")
        let rendered = AgentChatHistoryRenderer.render(
            messages: [assistant, user],
            isDark: false,
            layoutWidth: layoutWidth
        )

        let userRange = (rendered.string as NSString).range(of: "after")
        #expect(userRange.location != NSNotFound)
        let bodyStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: userRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let bubbleLeadingEdge = AgentChatHistoryLayoutMetrics.userBubbleLeadingEdge(for: layoutWidth)
        #expect(bodyStyle.headIndent == AgentChatHistoryLayoutMetrics.userBodyHeadIndent(for: layoutWidth))
        #expect(bodyStyle.headIndent - bubbleLeadingEdge == AgentChatHistoryLayoutMetrics.userBubbleHorizontalPadding)
        #expect(-bodyStyle.tailIndent - AgentChatHistoryLayoutMetrics.userBubbleTrailingMargin
            == AgentChatHistoryLayoutMetrics.userBubbleHorizontalPadding)
        #expect(AgentChatHistoryLayoutMetrics.userBubbleCornerRadius == 14)
        #expect(AgentChatHistoryLayoutMetrics.userBubbleFillOpacity == 0.026)

        let separatorStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: userRange.location - 1,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(separatorStyle.paragraphSpacing == AgentChatHistoryLayoutMetrics.userTurnTopSpacing)
    }

    @Test
    @MainActor
    func textViewReflowsUserBodyIndentWhenItsWidthChanges() throws {
        let user = AgentMessage(role: .user, content: "responsive inset")
        let view = AgentChatHistoryNSTextView()
        view.setFrameSize(NSSize(width: 640, height: 1))
        view.applyMessages([user], isDark: false)

        let narrowRange = (view.string as NSString).range(of: "responsive inset")
        let narrowStyle = try #require(view.textStorage?.attribute(
            .paragraphStyle,
            at: narrowRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(narrowStyle.headIndent == AgentChatHistoryLayoutMetrics.userBodyHeadIndent(for: 640))

        view.setFrameSize(NSSize(width: 900, height: 1))
        let wideRange = (view.string as NSString).range(of: "responsive inset")
        let wideStyle = try #require(view.textStorage?.attribute(
            .paragraphStyle,
            at: wideRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(wideStyle.headIndent == AgentChatHistoryLayoutMetrics.userBodyHeadIndent(for: 900))
        #expect(wideStyle.headIndent > narrowStyle.headIndent)

        view.setFrameSize(NSSize(width: 903, height: 1))
        let sameBucketStyle = try #require(view.textStorage?.attribute(
            .paragraphStyle,
            at: wideRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(sameBucketStyle.headIndent == wideStyle.headIndent)

        view.setFrameSize(NSSize(width: 904, height: 1))
        let nextBucketStyle = try #require(view.textStorage?.attribute(
            .paragraphStyle,
            at: wideRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(nextBucketStyle.headIndent > sameBucketStyle.headIndent)
    }

    @Test
    @MainActor
    func textViewIntrinsicHeightKeepsRoomForFinalBubbleCorners() throws {
        let user = AgentMessage(
            role: .user,
            content: "last user message"
        )
        let view = AgentChatHistoryNSTextView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 1)
        view.textContainer?.size = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        view.applyMessages([user], isDark: false)

        let layoutManager = try #require(view.layoutManager)
        let textContainer = try #require(view.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height

        #expect(view.intrinsicContentSize.height >= ceil(usedHeight + AgentChatHistoryLayoutMetrics.bubbleDrawingVerticalOverscan))
    }

    @Test
    @MainActor
    func assistantStatusDividerRenderingMatchesReferenceMetrics() throws {
        let assistant = AgentMessage(
            role: .assistant,
            content: "正文排版校验",
            elapsedSeconds: 67
        )
        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.frame = NSRect(x: 0, y: 0, width: 797, height: 1)
        view.textContainer?.size = NSSize(width: 797, height: CGFloat.greatestFiniteMagnitude)
        view.applyMessages([assistant], isDark: false, baseFontSize: 14)

        let layoutManager = try #require(view.layoutManager)
        let textContainer = try #require(view.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let processedRange = (view.string as NSString).range(
            of: L10n.MessageFooter.processedDuration("1m 7s")
        )
        let bodyRange = (view.string as NSString).range(of: "正文排版校验")
        #expect(processedRange.location != NSNotFound)
        #expect(bodyRange.location != NSNotFound)
        let processedFont = try #require(view.attributedString().attribute(
            .font,
            at: processedRange.location,
            effectiveRange: nil
        ) as? NSFont)
        let bodyFont = try #require(view.attributedString().attribute(
            .font,
            at: bodyRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(processedFont.pointSize == bodyFont.pointSize)
        #expect(processedFont.fontDescriptor == bodyFont.fontDescriptor)
        let dividerRange = NSRange(location: NSMaxRange(processedRange) + 1, length: 1)

        let processedGlyphRange = layoutManager.glyphRange(
            forCharacterRange: processedRange,
            actualCharacterRange: nil
        )
        let dividerGlyphRange = layoutManager.glyphRange(
            forCharacterRange: dividerRange,
            actualCharacterRange: nil
        )
        let bodyGlyphRange = layoutManager.glyphRange(
            forCharacterRange: bodyRange,
            actualCharacterRange: nil
        )
        let processedLineRect = layoutManager.lineFragmentRect(
            forGlyphAt: processedGlyphRange.location,
            effectiveRange: nil
        )
        let dividerLineRect = layoutManager.lineFragmentRect(
            forGlyphAt: dividerGlyphRange.location,
            effectiveRange: nil
        )
        let bodyLineRect = layoutManager.lineFragmentRect(
            forGlyphAt: bodyGlyphRange.location,
            effectiveRange: nil
        )
        let dividerY = dividerLineRect.minY
            + AgentChatHistoryLayoutMetrics.assistantStatusDividerTopSpacing
        let dividerBottomY = dividerY
            + AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness
        #expect(dividerY - processedLineRect.maxY
            == AgentChatHistoryLayoutMetrics.assistantStatusDividerTopSpacing)
        #expect(bodyLineRect.minY - dividerBottomY
            == AgentChatHistoryLayoutMetrics.assistantStatusDividerBottomSpacing)

        if let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_DESIGN_QA_OUTPUT"] {
            let renderedHeight = ceil(view.intrinsicContentSize.height)
            view.frame = NSRect(x: 0, y: 0, width: 797, height: renderedHeight)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    @Test
    @MainActor
    func selectedHistoryTextCanBeAddedToCurrentTask() {
        let view = AgentChatHistoryNSTextView()
        view.string = "alpha selected excerpt omega"
        view.setSelectedRange(NSRange(location: 6, length: 16))
        var receivedText: String?
        view.onAddSelectionToTask = { receivedText = $0 }

        let didAdd = view.addCurrentSelectionToTask()

        #expect(didAdd)
        #expect(receivedText == "selected excerpt")
    }

    @Test
    @MainActor
    func emptyHistorySelectionIsNotAddedToCurrentTask() {
        let view = AgentChatHistoryNSTextView()
        view.string = "message"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        var callbackCount = 0
        view.onAddSelectionToTask = { _ in callbackCount += 1 }

        let didAdd = view.addCurrentSelectionToTask()

        #expect(!didAdd)
        #expect(callbackCount == 0)
    }

    @Test
    @MainActor
    func transcriptStyleRefreshPreservesSelectedText() {
        let message = AgentMessage(role: .assistant, content: "alpha selected excerpt omega")
        let view = AgentChatHistoryNSTextView()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        view.applyMessages(
            [message],
            isDark: false,
            baseFontSize: 14
        )
        let range = (view.string as NSString).range(of: "selected excerpt")
        view.setSelectedRange(range)

        view.applySearch(query: "alpha", activeMatchIndex: 0, isDark: false)
        view.applySearch(query: "", activeMatchIndex: nil, isDark: false)

        #expect(view.selectedRange() == range)
        var receivedText: String?
        view.onAddSelectionToTask = { receivedText = $0 }
        #expect(view.addCurrentSelectionToTask())
        #expect(receivedText == "selected excerpt")
    }

    @Test
    func selectionActionUsesCodexStyleSurfaceMetrics() {
        #expect(AgentChatSelectionActionMetrics.cornerRadius == 8)
        #expect(AgentChatSelectionActionMetrics.height == 28)
        #expect(AgentChatSelectionActionMetrics.borderWidth == 0.5)
        #expect(AgentChatSelectionActionMetrics.shadowRadius == 7)
        #expect(AgentChatSelectionActionMetrics.lightShadowOpacity == 0.16)
        #expect(AgentChatSelectionActionMetrics.darkShadowOpacity == 0.36)
        #expect(
            AgentChatSelectionActionMetrics.backgroundColor(
                isDark: false,
                isHovered: false
            ).whiteComponent
                > AgentChatSelectionActionMetrics.backgroundColor(
                    isDark: false,
                    isHovered: true
                ).whiteComponent
        )
    }

    @Test("render Codex-style chat selection action for design QA")
    @MainActor
    func renderSelectionActionForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment[
            "WILLDEEP_SELECTION_ACTION_DESIGN_QA_OUTPUT"
        ] ?? "/private/tmp/willdeep-selection-action-design-qa.png"

        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.font = NSFont.systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.frame = NSRect(x: 0, y: 0, width: 335, height: 113)
        view.string = "已处理 7m 8s\n\n部署确认完成。基于终端记录的 deployment success。\n同步更新本地版本。"
        view.setSelectedRange((view.string as NSString).range(of: "基于终端记录的 deployment"))
        view.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: view)
        )
        view.layoutSubtreeIfNeeded()

        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @Test
    func transcriptSearchFindsCaseInsensitiveMatches() {
        let ranges = AgentTranscriptSearch.matchRanges(
            in: "Needle, haystack, needle, NEEDLE.",
            query: "needle"
        )

        #expect(ranges.count == 3)
    }

    @Test
    func transcriptSearchHighlightsActiveMatchDifferently() throws {
        let base = NSAttributedString(
            string: "alpha beta Alpha",
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        let result = AgentTranscriptSearch.highlightedString(
            from: base,
            query: "alpha",
            activeMatchIndex: 1,
            isDark: false
        )

        #expect(result.matchCount == 2)
        let firstBackground = try #require(result.attributedString.attribute(
            .backgroundColor,
            at: result.matchRanges[0].location,
            effectiveRange: nil
        ) as? NSColor)
        let activeBackground = try #require(result.attributedString.attribute(
            .backgroundColor,
            at: result.matchRanges[1].location,
            effectiveRange: nil
        ) as? NSColor)
        let activeUnderline = try #require(result.attributedString.attribute(
            .underlineStyle,
            at: result.matchRanges[1].location,
            effectiveRange: nil
        ) as? Int)

        #expect(firstBackground != activeBackground)
        #expect(activeUnderline == NSUnderlineStyle.single.rawValue)
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

    @Test
    func unicodeBasenameIsPreservedAsOneFilePath() throws {
        let rawPath = "docs/沙箱环境编译轻邮的坑与解决.md"
        let rendered = AgentChatHistoryRenderer.render(
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "文件已创建，完整路径是 `\(rawPath)`。请确认文件名。"
                )
            ],
            isDark: false
        )
        let pathRange = try #require(firstAttributeRange(
            .agentChatHistoryFilePath,
            containing: rawPath,
            in: rendered
        ))

        #expect((rendered.string as NSString).substring(with: pathRange) == rawPath)
        #expect(
            rendered.attribute(.agentChatHistoryFilePath, at: pathRange.location, effectiveRange: nil) as? String
                == rawPath
        )
        #expect(rendered.attribute(.backgroundColor, at: pathRange.location, effectiveRange: nil) == nil)
        #expect(rendered.attribute(
            .agentChatHistoryInlineCodeChipColor,
            at: pathRange.location,
            effectiveRange: nil
        ) == nil)

        let basenameRange = (rendered.string as NSString).range(of: "沙箱环境编译轻邮的坑与解决")
        let basenameFont = try #require(rendered.attribute(
            .font,
            at: basenameRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(!basenameFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test
    func localPathLinksUseQuietTextStylingWithoutChipBackgrounds() throws {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "项目目录例如 `~/Sites`、`~/a3-ui`、`~/WorkBuddy`。"
                )
            ],
            isDark: false
        )
        let pathRange = try #require(firstAttributeRange(
            .agentChatHistoryFilePath,
            containing: "~/Sites",
            in: rendered
        ))

        #expect(rendered.attribute(.backgroundColor, at: pathRange.location, effectiveRange: nil) == nil)
        #expect(rendered.attribute(
            .agentChatHistoryInlineCodeChipColor,
            at: pathRange.location,
            effectiveRange: nil
        ) == nil)
        #expect(
            rendered.attribute(.underlineStyle, at: pathRange.location, effectiveRange: nil) as? Int
                == NSUnderlineStyle.single.rawValue
        )
        #expect(
            rendered.attribute(
                .foregroundColor,
                at: pathRange.location,
                effectiveRange: nil
            ) as? NSColor == NSColor.labelColor
        )
        let trailingKern = try #require(rendered.attribute(
            .kern,
            at: NSMaxRange(pathRange) - 1,
            effectiveRange: nil
        ) as? NSNumber)
        #expect(trailingKern.doubleValue > 1)
    }

    @Test
    func longInlineCodeFileNamesKeepUnderscoresAboveTheClipEdge() throws {
        let fileName = "customer_usage_diagnostic.go"
        let rendered = AgentChatHistoryRenderer.render(
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "`\(fileName)`"
                )
            ],
            isDark: false
        )
        var fileSegments: [(text: String, baselineOffset: Double?)] = []
        rendered.enumerateAttribute(
            .agentChatHistoryFilePath,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            guard (value as? String) == fileName else { return }
            fileSegments.append((
                text: (rendered.string as NSString).substring(with: range),
                baselineOffset: (rendered.attribute(
                    .baselineOffset,
                    at: range.location,
                    effectiveRange: nil
                ) as? NSNumber)?.doubleValue
            ))
        }

        #expect(fileSegments.map(\.text).joined() == fileName)
        #expect(fileSegments.allSatisfy {
            $0.baselineOffset == Double(MarkdownInline.inlineCodeBaselineOffset)
        })
    }

    @Test
    func attachmentSourceMarkersBecomePreciseCitationLinks() throws {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "结论来自本地资料。[Source: reports/brief.pdf; page=7]"
                )
            ],
            isDark: false
        )
        let citationRange = (rendered.string as NSString).range(of: "[Source: reports/brief.pdf; page=7]")
        #expect(citationRange.location != NSNotFound)
        let payload = try #require(
            rendered.attribute(
                .agentChatHistoryAttachmentCitation,
                at: citationRange.location,
                effectiveRange: nil
            ) as? AgentAttachmentCitationPayload
        )
        #expect(payload.relativePath == "reports/brief.pdf")
        #expect(payload.sourceReference == "page=7")
        #expect(
            rendered.attribute(.link, at: citationRange.location, effectiveRange: nil) as? String
                == AgentChatHistoryAttachmentCitationLink.value
        )
        #expect(rendered.attribute(.agentChatHistoryFilePath, at: citationRange.location, effectiveRange: nil) == nil)
    }
}
