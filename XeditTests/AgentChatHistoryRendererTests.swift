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
    private static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    @Test
    func userInputMinimapWaitsUntilConversationHasSeveralUserTurns() {
        #expect(AgentTranscriptUserMinimap.minimumVisibleTurnCount == 6)
    }

    @Test
    func transcriptReaderPaginationKeepsAttributedRenderBounded() {
        #expect(AgentTranscriptPagination.messagesPerPage == 60)
        #expect(AgentTranscriptPagination.pageCount(for: 0) == 1)
        #expect(AgentTranscriptPagination.pageCount(for: 60) == 1)
        #expect(AgentTranscriptPagination.pageCount(for: 61) == 2)
        #expect(AgentTranscriptPagination.messageRange(messageCount: 145, pageIndex: 0) == 0..<60)
        #expect(AgentTranscriptPagination.messageRange(messageCount: 145, pageIndex: 1) == 60..<120)
        #expect(AgentTranscriptPagination.messageRange(messageCount: 145, pageIndex: 2) == 120..<145)
        #expect(AgentTranscriptPagination.messageRange(messageCount: 145, pageIndex: 99) == 120..<145)
    }

    @Test
    func chatPaneRetainsCodexSizedRecentHistoryBeforeArchiving() {
        #expect(AgentChatTranscript.renderedMessageCap == 240)
        #expect(AgentChatTranscript.olderHistoryPreviewCharacterCap == 12_000)
    }

    @Test
    func codexTypographyUsesFifteenPointBodyAndFivePointLeading() {
        #expect(AgentSettingsStore.chatBaseFontSizeDefault == 15)
        #expect(AgentChatHistoryLayoutMetrics.bodyLineSpacing == 5)
        #expect(AgentSettingsStore.migratedChatBaseFontSize(fromLegacy: nil) == 15)
        #expect(AgentSettingsStore.migratedChatBaseFontSize(fromLegacy: 14) == 15)
        #expect(AgentSettingsStore.migratedChatBaseFontSize(fromLegacy: 13) == 13)
        #expect(AgentSettingsStore.migratedChatBaseFontSize(fromLegacy: 18) == 18)
    }

    @Test
    func startingNewTurnDoesNotReusePreviousAssistantAsStreamingMessage() {
        let previousUser = AgentMessage(
            role: .user,
            content: "上一轮问题",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let previousAssistant = AgentMessage(
            role: .assistant,
            content: "```bash\nprevious-command\n```",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        let currentUser = AgentMessage(
            role: .user,
            content: "新消息",
            createdAt: Date(timeIntervalSince1970: 102)
        )

        let selectedID = AgentStreamingMessageSelection.currentAssistantID(
            in: [previousUser, previousAssistant, currentUser],
            isResponding: true,
            turnStartedAt: Date(timeIntervalSince1970: 103)
        )

        #expect(selectedID == nil)
    }

    @Test
    func currentTurnAssistantBecomesStreamingMessageAfterItIsAppended() {
        let previousAssistant = AgentMessage(
            role: .assistant,
            content: "上一轮回答",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        let currentUser = AgentMessage(
            role: .user,
            content: "新消息",
            createdAt: Date(timeIntervalSince1970: 102)
        )
        let currentAssistant = AgentMessage(
            role: .assistant,
            content: "正在回答",
            createdAt: Date(timeIntervalSince1970: 104)
        )

        let selectedID = AgentStreamingMessageSelection.currentAssistantID(
            in: [previousAssistant, currentUser, currentAssistant],
            isResponding: true,
            turnStartedAt: Date(timeIntervalSince1970: 103)
        )

        #expect(selectedID == currentAssistant.id)
    }

    @Test
    func transcriptLayoutWidthUsesStableEightPointBuckets() {
        #expect(AgentChatHistoryLayoutMetrics.layoutWidthBucket == 8)
        #expect(AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(900) == 896)
        #expect(AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(903.9) == 896)
        #expect(AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(904) == 904)
        #expect(AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(7.9) == 7)
        #expect(AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(.infinity)
            == AgentChatHistoryLayoutMetrics.defaultTranscriptWidth)
    }

    @Test
    func modelSwitchDividerEdgesAlignWithAssistantBodyColumn() throws {
        let segments = AgentChatHistoryLayoutMetrics.transcriptEventDividerSegments(
            textMinX: 360,
            textMaxX: 640,
            usableWidth: 1_000
        )

        #expect(segments.count == 2)
        let leading = try #require(segments.first)
        let trailing = try #require(segments.last)
        #expect(leading.start == AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
        #expect(
            trailing.end
                == 1_000 - AgentChatHistoryLayoutMetrics.assistantContentTailInset
        )
        #expect(leading.end == 360 - AgentChatHistoryLayoutMetrics.transcriptEventDividerGap)
        #expect(trailing.start == 640 + AgentChatHistoryLayoutMetrics.transcriptEventDividerGap)
    }

    @Test
    func modelSwitchNoticeSharesAssistantBodyInsets() throws {
        let message = AgentMessage(
            role: .system,
            content: "模型已从 deepseek-v4-flash 更改为 gpt-5.6-sol。",
            transcriptEvent: .modelChanged
        )
        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        let noticeRange = (rendered.string as NSString).range(of: "模型已从")
        let style = try #require(rendered.attribute(
            .paragraphStyle,
            at: noticeRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)

        #expect(style.headIndent == AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
        #expect(style.firstLineHeadIndent == AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
        #expect(style.tailIndent == -AgentChatHistoryLayoutMetrics.assistantContentTailInset)
    }

    @Test
    func stoppedResponseNoticeHasNoSymbolAttachment() {
        let message = AgentMessage(
            role: .system,
            content: "用户已停止生成",
            transcriptEvent: .responseStopped
        )
        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        var attachmentCount = 0
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if value != nil {
                attachmentCount += 1
            }
        }

        #expect(rendered.string.contains("用户已停止生成"))
        #expect(attachmentCount == 0)
    }

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
    func assistantParagraphBoundariesDoNotInsertBlankRows() throws {
        let message = AgentMessage(
            role: .assistant,
            content: "第一段。\n\n第二段。\n\n第三段。"
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        #expect(rendered.string.contains("第一段。\n第二段。\n第三段。"))

        for text in ["第一段。", "第二段。", "第三段。"] {
            let range = (rendered.string as NSString).range(of: text)
            let style = try #require(rendered.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle)
            #expect(style.lineSpacing == AgentChatHistoryLayoutMetrics.bodyLineSpacing)
            #expect(style.paragraphSpacing == 0)
        }
    }

    @Test
    func providerActivityHeadlineIsLocalizedAndKeepsItsSemanticIcon() {
        let message = AgentMessage(
            role: .assistant,
            content: "Planning font size clamping implementation"
        )

        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            baseFontSize: 14
        )

        #expect(rendered.string.contains(L10n.AgentActivity.planning))
        #expect(rendered.string.contains("Planning font size clamping implementation") == false)
        var hasSemanticIcon = false
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            hasSemanticIcon = hasSemanticIcon || value != nil
        }
        #expect(hasSemanticIcon)
    }

    @Test
    func proseAfterCodeBlockKeepsBodyFontAndLineSpacing() throws {
        let message = AgentMessage(
            role: .assistant,
            content: """
            代码块前的正文。

            ```text
            web: npm start
            ```

            代码块后的正文会自然换行，但字号与行距不能缩小。
            """
        )

        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            baseFontSize: 14
        )
        let beforeRange = (rendered.string as NSString).range(of: "代码块前的正文")
        let afterRange = (rendered.string as NSString).range(of: "代码块后的正文")
        let beforeFont = try #require(rendered.attribute(
            .font,
            at: beforeRange.location,
            effectiveRange: nil
        ) as? NSFont)
        let afterFont = try #require(rendered.attribute(
            .font,
            at: afterRange.location,
            effectiveRange: nil
        ) as? NSFont)
        let beforeStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: beforeRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let afterStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: afterRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)

        #expect(beforeFont.pointSize == 14)
        #expect(afterFont.pointSize == beforeFont.pointSize)
        #expect(afterStyle.lineSpacing == beforeStyle.lineSpacing)
        #expect(afterStyle.lineSpacing == AgentChatHistoryLayoutMetrics.bodyLineSpacing)
    }

    @Test
    func tableMarginsDoNotInflateRowsOrChangeFollowingProseRhythm() throws {
        let message = AgentMessage(
            role: .assistant,
            content: """
            表格前的正文。

            | 项目 | niuwo | sslcat |
            | --- | --- | --- |
            | 服务状态 | active | active |
            | Error/Critical | 0 条 | 0 条 |

            表格后的正文会自然换行，字号与行距必须和前文一致。
            """
        )

        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            baseFontSize: 14
        )
        let string = rendered.string as NSString
        let beforeRange = string.range(of: "表格前的正文")
        let headerRange = string.range(of: "项目")
        let separatorRange = string.range(of: "─┼─")
        let lastRowRange = string.range(of: "Error/Critical")
        let afterRange = string.range(of: "表格后的正文")
        let beforeFont = try #require(rendered.attribute(
            .font,
            at: beforeRange.location,
            effectiveRange: nil
        ) as? NSFont)
        let afterFont = try #require(rendered.attribute(
            .font,
            at: afterRange.location,
            effectiveRange: nil
        ) as? NSFont)
        let beforeStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: beforeRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let headerStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: headerRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let separatorStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: separatorRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let lastRowStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: lastRowRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let afterStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: afterRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)

        #expect(headerStyle.paragraphSpacingBefore == AgentChatHistoryRenderer.MarkdownSpacing.tableParagraphBefore)
        #expect(headerStyle.paragraphSpacing == 0)
        #expect(headerStyle.lineBreakMode == .byTruncatingTail)
        #expect(separatorStyle.paragraphSpacingBefore == 0)
        #expect(separatorStyle.paragraphSpacing == 0)
        #expect(lastRowStyle.paragraphSpacingBefore == 0)
        #expect(lastRowStyle.paragraphSpacing == AgentChatHistoryRenderer.MarkdownSpacing.tableParagraph)
        #expect(afterFont.pointSize == beforeFont.pointSize)
        #expect(afterStyle.lineSpacing == beforeStyle.lineSpacing)
        #expect(afterStyle.lineSpacing == AgentChatHistoryLayoutMetrics.bodyLineSpacing)
        #expect(afterStyle.paragraphSpacingBefore == beforeStyle.paragraphSpacingBefore)
        #expect(afterStyle.paragraphSpacing == beforeStyle.paragraphSpacing)
    }

    @Test
    func richBlockBackgroundCoversTableTruncationBoundary() {
        let textTrailingInset = AgentChatHistoryLayoutMetrics.assistantContentTailInset
            + AgentChatHistoryLayoutMetrics.richBlockTextInset

        #expect(
            AgentChatHistoryLayoutMetrics.richBlockBackgroundTrailingInset
                < textTrailingInset
        )
        #expect(
            textTrailingInset
                - AgentChatHistoryLayoutMetrics.richBlockBackgroundTrailingInset
                == AgentChatHistoryLayoutMetrics.richBlockBackgroundPadding
        )
    }

    @Test
    func streamingMarkdownUsesOneNewlineBetweenPlainParagraphs() {
        let rendered = AgentAssistantMarkdownRenderer.render(
            "实时第一段。\n\n实时第二段。",
            isDark: false,
            baseFontSize: 14
        )
        let plain = String(rendered.characters)
        #expect(plain.contains("实时第一段。\n实时第二段。"))
        #expect(!plain.contains("实时第一段。\n\n实时第二段。"))
    }

    @Test
    func liveThinkingStreamingRendererParsesCommonMarkdownWhenEnabled() {
        let rendered = AgentAssistantStreamingTextRenderer.render(
            """
            # 策划案

            核心是 **天才萌宝**。

            | 项目 | 内容 |
            |---|---|
            | 集数 | 80 集 |
            """,
            rendersMarkdown: true,
            isDark: false,
            baseFontSize: 14
        )
        let plain = String(rendered.characters)

        #expect(plain.contains("策划案"))
        #expect(plain.contains("天才萌宝"))
        #expect(!plain.contains("# 策划案"))
        #expect(!plain.contains("**天才萌宝**"))
        #expect(plain.contains("项目 │ 内容"))
        #expect(!plain.contains("|---|---|"))
    }

    @Test
    func ordinaryAnswerStreamingRendererKeepsLowCostPlainTextPath() {
        let rendered = AgentAssistantStreamingTextRenderer.render(
            "# 标题与 **粗体**",
            rendersMarkdown: false,
            isDark: false,
            baseFontSize: 14
        )

        #expect(String(rendered.characters) == "# 标题与 **粗体**")
    }

    @Test
    func olderHistoryPreviewCapsPlainTextWithoutRenderingFullDetails() {
        let messages = [
            AgentMessage(role: .user, content: "short request"),
            AgentMessage(
                role: .assistant,
                content: String(repeating: "A", count: 220) + "TAIL_SHOULD_BE_OMITTED"
            ),
        ]

        let preview = AgentOlderHistoryPreview.make(
            messages: messages,
            maxCharacters: 90,
            roleLabel: { $0.rawValue },
            omissionText: { "[\($0) omitted]" }
        )

        #expect(preview.content.contains("user:\nshort request"))
        #expect(preview.content.contains("assistant:\n"))
        #expect(!preview.content.contains("TAIL_SHOULD_BE_OMITTED"))
        #expect(preview.content.count <= 90)
        #expect(preview.omittedCharacters > 0)
        #expect(preview.totalCharacters > preview.content.count)
    }

    @Test
    func olderHistoryPreviewHidesGeneratedImageDescription() {
        let content = AppState.contentByAppendingImageDescription(
            to: "现在还有图片吗？",
            description: "Image 1: internal VL-only screenshot notes.",
            imageCount: 1,
            providerID: "some-im",
            model: "qwen3-vl-plus"
        )
        let image = AgentImageAttachment(mimeType: "image/png", dataBase64: Self.tinyPNGBase64)

        let preview = AgentOlderHistoryPreview.make(
            messages: [AgentMessage(role: .user, content: content, images: [image])],
            maxCharacters: 240,
            roleLabel: { $0.rawValue },
            omissionText: { "[\($0) omitted]" }
        )

        #expect(preview.content.contains("现在还有图片吗？"))
        #expect(preview.content.contains("[Image attachment ×1]"))
        #expect(!preview.content.contains("[Image description generated"))
        #expect(!preview.content.contains("internal VL-only"))
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

        #expect(rendered.string.contains(L10n.MessageFooter.processed))
        #expect(!rendered.string.contains("Assistant"))
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
            // Long code lines char-wrap inside the card (no horizontal
            // scroll in chat) — clipping made overlong commands unreadable.
            #expect(paragraphStyle?.lineBreakMode == .byCharWrapping)
        }
        #expect(!rendered.string.contains("# Title"))
        #expect(!rendered.string.contains("**bold**"))
        #expect(!rendered.string.contains("```"))
    }

    @Test
    func rendersInlineCodeChipsAndHexColorSwatches() throws {
        let message = AgentMessage(
            role: .assistant,
            content: "Use `SleepRangeSummary` with `#8B3F52` for the low-saturation accent."
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("SleepRangeSummary"))
        #expect(rendered.string.contains("#8B3F52 ■"))
        let codeRange = try #require(firstAttributeRange(
            .agentChatHistoryInlineCodeChipColor,
            containing: "SleepRangeSummary",
            in: rendered
        ))
        #expect(rendered.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) == nil)
        let swatchLocation = (rendered.string as NSString).range(of: "■").location
        let swatchColor = try #require(rendered.attribute(
            .foregroundColor,
            at: swatchLocation,
            effectiveRange: nil
        ) as? NSColor)
        #expect(abs(swatchColor.redComponent - 0x8b / 255.0) < 0.01)
        #expect(abs(swatchColor.greenComponent - 0x3f / 255.0) < 0.01)
        #expect(abs(swatchColor.blueComponent - 0x52 / 255.0) < 0.01)
    }

    @Test
    func inlineCodeDoesNotIncreaseTextKitProseLineHeight() throws {
        let baseFontSize: CGFloat = 14
        let rendered = AgentChatHistoryRenderer.render(
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "清楚了，Ingress 用 `hub-beta.tsingfly.com` 做 `tokenhub` 的路由。"
                ),
            ],
            isDark: false,
            baseFontSize: baseFontSize,
            layoutWidth: 420
        )
        let codeRange = try #require(firstAttributeRange(
            .agentChatHistoryInlineCodeChipColor,
            containing: "hub-beta.tsingfly.com",
            in: rendered
        ))
        let codeFont = try #require(rendered.attribute(
            .font,
            at: codeRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(codeFont.pointSize == baseFontSize - 1)

        let bodyStyle = AgentChatHistoryRenderer.bodyParagraphStyle(for: .assistant, layoutWidth: 420)
        let plainLine = NSAttributedString(
            string: "清楚了，Ingress 用 hub-beta.tsingfly.com 做 tokenhub 的路由。",
            attributes: [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .paragraphStyle: bodyStyle,
            ]
        )
        let plainLineHeight = try #require(lineFragmentHeights(
            in: plainLine,
            width: 420,
            intersecting: NSRange(location: 0, length: plainLine.length)
        ).max())
        let codeLineHeight = try #require(lineFragmentHeights(
            in: rendered,
            width: 420,
            intersecting: codeRange
        ).max())

        #expect(codeLineHeight <= plainLineHeight + 0.5)
    }

    @Test
    func singleGlyphInlineCodeChipDoesNotOverlapPrecedingText() throws {
        let text = NSMutableAttributedString(
            string: "完成了。以下是 / 目录下的全部内容：",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let slashRange = (text.string as NSString).range(of: "/")
        let precedingTextRange = (text.string as NSString).range(of: "是")
        #expect(slashRange.location != NSNotFound)
        #expect(precedingTextRange.location != NSNotFound)
        text.addAttribute(
            .font,
            value: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            range: slashRange
        )

        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 600, height: 100))
        textContainer.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let slashGlyphRange = layoutManager.glyphRange(
            forCharacterRange: slashRange,
            actualCharacterRange: nil
        )
        let precedingGlyphRange = layoutManager.glyphRange(
            forCharacterRange: precedingTextRange,
            actualCharacterRange: nil
        )
        let slashRect = layoutManager.boundingRect(
            forGlyphRange: slashGlyphRange,
            in: textContainer
        )
        let precedingRect = layoutManager.boundingRect(
            forGlyphRange: precedingGlyphRange,
            in: textContainer
        )
        let chipRect = AgentChatHistoryLayoutMetrics.inlineCodeChipRect(
            for: slashRect,
            at: .zero
        )

        #expect(chipRect.minX >= precedingRect.maxX)
        #expect(chipRect.minX < slashRect.minX)
        #expect(chipRect.maxX > slashRect.maxX)
        #expect(
            slashRect.minY - chipRect.minY
                <= AgentChatHistoryLayoutMetrics.inlineCodeChipVisualTopPadding + 1
        )
        #expect(
            chipRect.maxY - slashRect.maxY
                >= AgentChatHistoryLayoutMetrics.inlineCodeChipVisualBottomPadding
        )
    }

    @Test
    func inlineCodeChipUsesCompactVisualBottomPadding() {
        #expect(AgentChatHistoryLayoutMetrics.inlineCodeChipVisualBottomPadding == 0.5)
        #expect(
            AgentChatHistoryLayoutMetrics.inlineCodeChipVisualBottomPadding
                == AgentChatHistoryLayoutMetrics.inlineCodeChipVisualTopPadding
        )
    }

    @Test
    func rendersUserImageInsteadOfGeneratedImageDescriptionInHistory() {
        let content = AppState.contentByAppendingImageDescription(
            to: "识别一下这张图",
            description: "Image 1: internal VL-only screenshot notes.",
            imageCount: 1,
            providerID: "some-im",
            model: "qwen3-vl-plus"
        )
        let image = AgentImageAttachment(mimeType: "image/png", dataBase64: Self.tinyPNGBase64)
        let message = AgentMessage(role: .user, content: content, images: [image])

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(!rendered.string.contains("You"))
        #expect(rendered.string.contains("识别一下这张图"))
        #expect(rendered.string.contains("\u{fffc}") || rendered.string.contains("Image attachment"))
        #expect(firstAttributeRange(
            .agentChatHistoryImageID,
            value: image.id.uuidString,
            in: rendered
        ) != nil)
        #expect(firstAttributeRange(
            .link,
            value: AgentChatHistoryImageLink.value,
            in: rendered
        ) != nil)
        let imageRange = try? #require(firstAttributeRange(
            .agentChatHistoryImageID,
            value: image.id.uuidString,
            in: rendered
        ))
        if let imageRange {
            #expect(rendered.attribute(.cursor, at: imageRange.location, effectiveRange: nil) as? NSCursor == NSCursor.arrow)
            let bodyRange = (rendered.string as NSString).range(of: "识别一下这张图")
            #expect(bodyRange.location != NSNotFound)
            #expect(imageRange.location < bodyRange.location)
            #expect(rendered.attribute(
                .agentChatHistoryBubbleKind,
                at: imageRange.location,
                effectiveRange: nil
            ) == nil)
            #expect(
                rendered.attribute(
                    .agentChatHistoryBubbleKind,
                    at: bodyRange.location,
                    effectiveRange: nil
                ) as? NSNumber
                    == NSNumber(value: AgentChatHistoryBubbleKind.user.rawValue)
            )
            let imageParagraphStyle = try? #require(rendered.attribute(
                .paragraphStyle,
                at: imageRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle)
            #expect(imageParagraphStyle?.alignment == .right)
            #expect(
                imageParagraphStyle?.paragraphSpacing
                    == AgentChatHistoryLayoutMetrics.userImageToBubbleSpacing
            )
        }
        #expect(!rendered.string.contains("[Image description generated"))
        #expect(!rendered.string.contains("internal VL-only"))
        #expect(!message.copyableContent.contains("internal VL-only"))
    }

    @Test
    func rendersAssistantGeneratedImageWithReferenceMarkerInHistory() {
        let image = AgentImageAttachment(
            mimeType: "image/png",
            dataBase64: Self.tinyPNGBase64,
            source: .generated,
            filePath: "/tmp/willdeep-generated-image.png",
            model: "gpt-image-2",
            prompt: "test prompt"
        )
        let message = AgentMessage(role: .assistant, content: "生成好了。", images: [image])

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        let marker = image.generatedReferenceMarker

        #expect(rendered.string.contains(L10n.MessageFooter.processed))
        #expect(!rendered.string.contains("Assistant"))
        #expect(rendered.string.contains("生成好了。"))
        #expect(rendered.string.contains("\u{fffc}") || rendered.string.contains("Image attachment"))
        #expect(marker != nil)
        #expect(firstAttributeRange(
            .agentChatHistoryImageReferenceMarker,
            value: marker ?? "",
            in: rendered
        ) != nil)
    }

    @Test
    func parsesGeneratedImageReferenceMarkerPath() throws {
        let marker = AgentGeneratedImageReference.marker(
            id: "image-1",
            path: "/tmp/generated & quoted \"image\".png",
            model: "gpt-image-2"
        )

        let path = try #require(AgentGeneratedImageReference.path(from: marker))

        #expect(path == "/tmp/generated & quoted \"image\".png")
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

        #expect(rendered.string.contains("已运行1条命令"))
        #expect(!rendered.string.contains("▸"))
        #expect(!rendered.string.contains("run_command  command: git status --short"))
        #expect(!rendered.string.contains("Tool calls"))
        #expect(!rendered.string.contains("Assistant"))
    }

    @Test
    func whitespaceOnlyAssistantMessageRendersAsToolEventWithoutEmptyTurnChrome() {
        let message = AgentMessage(
            role: .assistant,
            content: "\n\n\t\n",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "call_whitespace",
                    toolName: "run_command",
                    argumentsJSON: #"{"command":"git status --short"}"#
                )
            ],
            promptTokens: 31_050,
            completionTokens: 183,
            elapsedSeconds: 26
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(!message.hasRenderableTextContent)
        #expect(rendered.string.contains("已运行1条命令"))
        #expect(!rendered.string.contains(AgentChatMessageMetrics.assistantStatus(
            for: message,
            isStreaming: false
        )))
        #expect(!rendered.string.contains(AgentChatMessageMetrics.tokenSummary(for: message) ?? "31.1k/183"))
    }

    @Test
    func collapsedToolSummaryDescribesCreatedFilesWithoutExposingTheirPaths() {
        let message = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: (16...18).map { episode in
                AgentMessageToolCall(
                    externalID: "create_\(episode)",
                    toolName: "create_file",
                    argumentsJSON: #"{"path":"剧本/第\#(episode)集.md","title":"内部标题"}"#
                )
            }
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("生成了3个文件"))
        #expect(!rendered.string.contains("第16集.md"))
        #expect(!rendered.string.contains("create_file"))
        #expect(!rendered.string.contains("内部标题"))
    }

    @Test
    func collapsedToolSummaryRecognizesImageReads() {
        let message = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "read_image",
                    toolName: "read_file",
                    argumentsJSON: #"{"path":"artifacts/reference.png"}"#
                )
            ]
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("读取了1张图片"))
        #expect(!rendered.string.contains("reference.png"))
    }

    @Test
    func collapsedToolSummaryFallsBackToCallCountWithoutToolDetails() {
        let message = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "custom_1",
                    toolName: "private_custom_tool",
                    argumentsJSON: #"{"secret_query":"not-for-collapsed-row"}"#
                ),
                AgentMessageToolCall(
                    externalID: "custom_2",
                    toolName: "another_custom_tool",
                    argumentsJSON: #"{"private_path":"workspace/internal.txt"}"#
                )
            ]
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("执行了2次工具调用"))
        #expect(!rendered.string.contains("private_custom_tool"))
        #expect(!rendered.string.contains("not-for-collapsed-row"))
        #expect(!rendered.string.contains("workspace/internal.txt"))
    }

    @Test
    func collapsesAndExpandsConsecutiveToolCalls() throws {
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

        let baseFontSize: CGFloat = 18
        let collapsed = AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            baseFontSize: baseFontSize
        )
        #expect(collapsed.string.contains("已读取1个文件\n"))
        #expect(collapsed.string.contains("已运行1条命令"))
        #expect(!collapsed.string.contains("已读取1个文件 · 已运行1条命令"))
        #expect(!collapsed.string.contains("tool  read_file"))
        let summaryRange = (collapsed.string as NSString).range(of: "已读取1个文件")
        let summaryFont = try #require(collapsed.attribute(
            .font,
            at: summaryRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(summaryFont.pointSize == NSFont.systemFontSize)

        let groupID = "\(firstID.uuidString):\(secondID.uuidString)"
        let expanded = AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            expandedToolGroupIDs: [groupID],
            baseFontSize: baseFontSize
        )
        #expect(expanded.string.contains("已读取1个文件\n"))
        #expect(expanded.string.contains("已运行1条命令"))
        #expect(!expanded.string.contains("▾"))
        #expect(expanded.string.contains("tool  run_command  command: ls /Users/rocky/Sites/Teamify && git status --short"))
        #expect(expanded.string.contains("tool  read_file  path: /Users/rocky/Sites/Teamify/README.md"))
    }

    @Test
    func mergesInlineAndFollowingToolOnlyCallsIntoOneActivityLayer() {
        let proseID = UUID()
        let followupID = UUID()
        let messages = [
            AgentMessage(
                id: proseID,
                role: .assistant,
                content: "我先检查工程状态。",
                toolCalls: [
                    AgentMessageToolCall(
                        externalID: "call_command",
                        toolName: "run_command",
                        argumentsJSON: #"{"command":"git status --short"}"#
                    )
                ]
            ),
            AgentMessage(
                id: followupID,
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentMessageToolCall(
                        externalID: "call_read",
                        toolName: "read_file",
                        argumentsJSON: #"{"path":"README.md"}"#
                    )
                ]
            )
        ]

        let collapsed = AgentChatHistoryRenderer.render(messages: messages, isDark: false)
        #expect(collapsed.string.components(separatedBy: "已读取1个文件").count - 1 == 1)
        #expect(collapsed.string.components(separatedBy: "已运行1条命令").count - 1 == 1)
        #expect(!collapsed.string.contains("已读取1个文件 · 已运行1条命令"))

        let groupID = "inline:\(proseID.uuidString):\(followupID.uuidString)"
        let expanded = AgentChatHistoryRenderer.render(
            messages: messages,
            isDark: false,
            expandedToolGroupIDs: [groupID]
        )
        #expect(expanded.string.contains("tool  run_command  command: git status --short"))
        #expect(expanded.string.contains("tool  read_file  path: README.md"))
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
    func latestAssistantCollapsesTerminalToolSummaries() throws {
        let message = AgentMessage(
            role: .assistant,
            content: "Redis 关键调不在尾行。",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "terminal_send",
                    toolName: "terminal_send_command",
                    argumentsJSON: #"{"command":"redis-cli ping"}"#
                ),
                AgentMessageToolCall(
                    externalID: "terminal_snapshot",
                    toolName: "terminal_snapshot",
                    argumentsJSON: #"{"max_chars":2000}"#
                )
            ]
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)

        #expect(rendered.string.contains("已执行2次终端操作"))
        #expect(!rendered.string.contains("已调用 terminal send command"))
        #expect(!rendered.string.contains("已调用 terminal snapshot"))

        let bodyRange = (rendered.string as NSString).range(of: "Redis 关键调不在尾行。")
        let summaryRange = (rendered.string as NSString).range(of: "已执行2次终端操作")
        let bodyStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: bodyRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let summaryStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: summaryRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(summaryStyle.headIndent == bodyStyle.headIndent)
        #expect(summaryStyle.firstLineHeadIndent == bodyStyle.firstLineHeadIndent)
        #expect(summaryStyle.tailIndent == bodyStyle.tailIndent)
    }

    @Test
    func historicAssistantHidesTerminalToolSummariesOnly() {
        let older = AgentMessage(
            role: .assistant,
            content: "我先查一下。",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "terminal_send",
                    toolName: "terminal_send_command",
                    argumentsJSON: #"{"command":"redis-cli ping"}"#
                ),
                AgentMessageToolCall(
                    externalID: "read_file",
                    toolName: "read_file",
                    argumentsJSON: #"{"path":"README.md"}"#
                )
            ]
        )
        let latest = AgentMessage(
            role: .assistant,
            content: "查完了。"
        )

        let rendered = AgentChatHistoryRenderer.render(messages: [older, latest], isDark: false)

        #expect(rendered.string.contains("已读取1个文件"))
        #expect(!rendered.string.contains("终端操作"))
        #expect(!rendered.string.contains("terminal_send_command"))
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

        let rendered = AgentChatHistoryRenderer.render(
            messages: [user, assistant],
            isDark: false,
            baseFontSize: AgentSettingsStore.chatBaseFontSizeDefault
        )

        #expect(rendered.string.contains("hello"))
        #expect(!rendered.string.contains("You"))
        #expect(rendered.string.contains("\(L10n.MessageFooter.processedDuration("8s"))\n\ndone"))
        #expect(!rendered.string.contains("Assistant"))
        #expect(!rendered.string.contains("YOU"))
        #expect(rendered.string.contains("  1.2k/2.3k  ↻"))
        #expect(!rendered.string.contains("in 1.2k"))
        #expect(!rendered.string.contains("out 2.3k"))
        #expect(firstAttributeRange(.agentChatHistoryMessageCopyText, value: "hello", in: rendered) == nil)

        let processedRange = (rendered.string as NSString).range(
            of: L10n.MessageFooter.processedDuration("8s")
        )
        let processedFont = try #require(rendered.attribute(
            .font,
            at: processedRange.location,
            effectiveRange: nil
        ) as? NSFont)
        let processedColor = rendered.attribute(
            .foregroundColor,
            at: processedRange.location,
            effectiveRange: nil
        ) as? NSColor

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
        let bodyFont = try #require(rendered.attribute(
            .font,
            at: doneRange.location,
            effectiveRange: nil
        ) as? NSFont)
        let bodyParagraphStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: doneRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(bodyFont.pointSize == 15)
        #expect(processedFont.pointSize == NSFont.systemFontSize)
        #expect(processedFont.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(processedColor == NSColor.secondaryLabelColor)
        #expect(bodyParagraphStyle.lineSpacing == AgentChatHistoryLayoutMetrics.bodyLineSpacing)
        #expect(bodyParagraphStyle.lineSpacing == 5)
        let dividerLocation = NSMaxRange(processedRange) + 1
        let dividerColor = try #require(rendered.attribute(
            .agentChatHistoryAssistantStatusDividerColor,
            at: dividerLocation,
            effectiveRange: nil
        ) as? NSColor)
        let dividerParagraphStyle = try #require(rendered.attribute(
            .paragraphStyle,
            at: dividerLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(dividerColor.alphaComponent
            == CGFloat(AgentChatHistoryLayoutMetrics.assistantStatusDividerOpacity))
        let dividerSRGB = try #require(dividerColor.usingColorSpace(.sRGB))
        #expect(dividerSRGB.redComponent == 0)
        #expect(dividerSRGB.greenComponent == 0)
        #expect(dividerSRGB.blueComponent == 0)
        #expect(dividerParagraphStyle.minimumLineHeight
            == AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness)
        #expect(dividerParagraphStyle.maximumLineHeight
            == AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness)
        #expect(dividerParagraphStyle.paragraphSpacingBefore
            == AgentChatHistoryLayoutMetrics.assistantStatusDividerTopSpacing)
        #expect(dividerParagraphStyle.paragraphSpacing
            == AgentChatHistoryLayoutMetrics.assistantStatusDividerBottomSpacing)
        #expect(dividerParagraphStyle.headIndent == AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
        #expect(dividerParagraphStyle.tailIndent == -AgentChatHistoryLayoutMetrics.assistantContentTailInset)
        #expect(AgentChatHistoryLayoutMetrics.assistantStatusDividerTopSpacing == 9)
        #expect(AgentChatHistoryLayoutMetrics.assistantStatusDividerBottomSpacing == 18)
        #expect(AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness == 1)
        #expect(AgentChatHistoryLayoutMetrics.assistantStatusDividerOpacity == 0.075)
        let copyFont = try #require(rendered.attribute(
            .font,
            at: assistantCopyLocation,
            effectiveRange: nil
        ) as? NSFont)
        #expect(copyFont.pointSize >= 16)

        let tokenRange = (rendered.string as NSString).range(of: "1.2k/2.3k")
        let tokenFont = try #require(rendered.attribute(
            .font,
            at: tokenRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(tokenFont.pointSize == AgentDesign.chatSupportingFontSizeDefault)

        let retryRange = (rendered.string as NSString).range(of: "↻")
        let retryFont = try #require(rendered.attribute(
            .font,
            at: retryRange.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(retryFont.pointSize >= 13)
        #expect(retryFont.pointSize < copyFont.pointSize)

        let copiedButton = AgentChatHistoryFooterChrome.copyButton(
            copied: true,
            message: "done",
            paragraphStyle: rendered.attribute(
                .paragraphStyle,
                at: assistantCopyLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        #expect(copiedButton.length == assistantCopyRange.length)
        let copiedParagraphStyle = try #require(copiedButton.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(
            copiedParagraphStyle.headIndent
                == AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        )
        #expect(
            copiedParagraphStyle.tailIndent
                == -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        )
    }

    @Test
    func assistantTurnFooterAggregatesOnlyCurrentUserTurnAndShowsCacheRate() throws {
        let firstUser = AgentMessage(role: .user, content: "first")
        let firstRequest = AgentMessage(
            role: .assistant,
            content: "checking",
            usageTokens: 1_100,
            promptTokens: 1_000,
            completionTokens: 100,
            cachedPromptTokens: 400
        )
        let secondRequest = AgentMessage(
            role: .assistant,
            content: "done",
            usageTokens: 3_200,
            promptTokens: 3_000,
            completionTokens: 200,
            cachedPromptTokens: 2_000
        )
        let secondUser = AgentMessage(role: .user, content: "second")
        let nextTurnRequest = AgentMessage(
            role: .assistant,
            content: "next",
            usageTokens: 550,
            promptTokens: 500,
            completionTokens: 50,
            cachedPromptTokens: 100
        )
        let messages = [firstUser, firstRequest, secondRequest, secondUser, nextTurnRequest]
        let presentations = AgentAssistantTurnGrouping.presentations(in: messages)
        let firstSummary = try #require(presentations[secondRequest.id]?.summaryMessage)
        let nextSummary = try #require(presentations[nextTurnRequest.id]?.summaryMessage)

        #expect(firstSummary.promptTokens == 4_000)
        #expect(firstSummary.completionTokens == 300)
        #expect(firstSummary.cachedPromptTokens == 2_400)
        #expect(
            AgentChatMessageMetrics.tokenSummary(for: firstSummary)
                == "4.0k/300 · \(L10n.MessageFooter.cacheRate("60%"))"
        )
        #expect(nextSummary.promptTokens == 500)
        #expect(AgentChatMessageMetrics.cacheHitRate(for: nextSummary) == 0.2)
    }

    @Test
    func assistantTurnFooterFormatsMillionScaleTokensWithTwoDecimals() {
        let message = AgentMessage(
            role: .assistant,
            content: "done",
            usageTokens: 26_769_300,
            promptTokens: 26_725_800,
            completionTokens: 43_500
        )
        let boundaryMessage = AgentMessage(
            role: .assistant,
            content: "boundary",
            usageTokens: 1_999_500,
            promptTokens: 1_000_000,
            completionTokens: 999_500
        )

        #expect(AgentChatMessageMetrics.tokenSummary(for: message) == "26.73M/43.5k")
        #expect(AgentChatMessageMetrics.tokenSummary(for: boundaryMessage) == "1.00M/999.5k")
    }

    @Test
    func groupsRepeatedAssistantOutputsIntoOneUserTurnChrome() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let user = AgentMessage(role: .user, content: "do the work", createdAt: startedAt)
        let first = AgentMessage(
            role: .assistant,
            content: "first update",
            promptTokens: 100,
            completionTokens: 20,
            elapsedSeconds: 4,
            createdAt: startedAt.addingTimeInterval(2)
        )
        let toolLoop = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentMessageToolCall(
                externalID: "read-1",
                toolName: "read_file",
                argumentsJSON: #"{"path":"README.md"}"#
            )],
            promptTokens: 50,
            completionTokens: 10,
            elapsedSeconds: 3,
            createdAt: startedAt.addingTimeInterval(6)
        )
        let final = AgentMessage(
            role: .assistant,
            content: "final answer",
            promptTokens: 150,
            completionTokens: 30,
            elapsedSeconds: 6,
            createdAt: startedAt.addingTimeInterval(12)
        )

        let rendered = AgentChatHistoryRenderer.render(
            messages: [user, first, final],
            isDark: false,
            assistantTurnContextMessages: [user, first, toolLoop, final]
        )

        #expect(occurrences(of: L10n.MessageFooter.processedDuration("18s"), in: rendered.string) == 1)
        #expect(attributeCount(.agentChatHistoryAssistantStatusDividerColor, in: rendered) == 1)
        #expect(occurrences(of: "300/60", in: rendered.string) == 1)
        #expect(firstAttributeRange(
            .agentChatHistoryMessageCopyText,
            value: "first update\n\nfinal answer",
            in: rendered
        ) != nil)
        #expect(firstAttributeRange(
            .agentChatHistoryMessageCopyText,
            value: "first update",
            in: rendered
        ) == nil)
    }

    @Test
    func goalModeKeepsProcessMessagesArtifactsAndFinalDeliverySummary() throws {
        let startedAt = Date(timeIntervalSince1970: 1_500)
        let user = AgentMessage(role: .user, content: "完成整个目标", createdAt: startedAt)
        let phase = AgentMessage(
            role: .assistant,
            content: "Planning the implementation",
            promptTokens: 100,
            completionTokens: 10,
            elapsedSeconds: 2,
            createdAt: startedAt.addingTimeInterval(1)
        )
        let failedAttempt = AgentMessage(
            role: .assistant,
            content: "第一次尝试失败，准备换一种做法。",
            promptTokens: 200,
            completionTokens: 20,
            elapsedSeconds: 3,
            createdAt: startedAt.addingTimeInterval(4)
        )
        let artifact = AgentMessage(
            role: .assistant,
            content: "",
            images: [AgentImageAttachment(mimeType: "image/png", dataBase64: Self.tinyPNGBase64)],
            createdAt: startedAt.addingTimeInterval(7)
        )
        let final = AgentMessage(
            role: .assistant,
            content: """
            完成了，目标已经交付。

            - 修改已落盘
            - 验证已通过

            ```goal-check
            1: done
            ```
            """,
            promptTokens: 300,
            completionTokens: 30,
            elapsedSeconds: 4,
            createdAt: startedAt.addingTimeInterval(8)
        )
        let raw = [user, phase, failedAttempt, artifact, final]
        let displayed = AgentTranscriptModePresentation.modeInvariantMessages(from: raw)

        #expect(displayed.map(\.id) == raw.map(\.id))
        #expect(displayed.last?.content == final.content)

        let rendered = AgentChatHistoryRenderer.render(
            messages: displayed,
            isDark: false,
            assistantTurnContextMessages: raw
        )
        let planningTitle = try #require(
            AgentActivityHeadlinePresentation.make(
                from: "Planning the implementation"
            )?.title
        )
        #expect(rendered.string.contains("完成了，目标已经交付"))
        #expect(rendered.string.contains("第一次尝试失败"))
        #expect(rendered.string.contains(planningTitle))
        #expect(!rendered.string.contains("goal-check"))
        #expect(attributeCount(.agentChatHistoryAssistantStatusDividerColor, in: rendered) == 1)
        #expect(occurrences(of: "600/60", in: rendered.string) == 1)
    }
}
