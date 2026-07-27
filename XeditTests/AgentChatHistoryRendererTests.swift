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

        #expect(rendered.string.contains("已运行 1 条命令"))
        #expect(!rendered.string.contains("▸"))
        #expect(!rendered.string.contains("run_command  command: git status --short"))
        #expect(!rendered.string.contains("Tool calls"))
        #expect(!rendered.string.contains("Assistant"))
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

        #expect(rendered.string.contains("生成了 3 个文件"))
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

        #expect(rendered.string.contains("读取了 1 张图片"))
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

        #expect(rendered.string.contains("执行了 2 次工具调用"))
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
        #expect(collapsed.string.contains("已读取 1 个文件\n"))
        #expect(collapsed.string.contains("已运行 1 条命令"))
        #expect(!collapsed.string.contains("已读取 1 个文件 · 已运行 1 条命令"))
        #expect(!collapsed.string.contains("tool  read_file"))
        let summaryRange = (collapsed.string as NSString).range(of: "已读取 1 个文件")
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
        #expect(expanded.string.contains("已读取 1 个文件\n"))
        #expect(expanded.string.contains("已运行 1 条命令"))
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
        #expect(collapsed.string.components(separatedBy: "已读取 1 个文件").count - 1 == 1)
        #expect(collapsed.string.components(separatedBy: "已运行 1 条命令").count - 1 == 1)
        #expect(!collapsed.string.contains("已读取 1 个文件 · 已运行 1 条命令"))

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

        #expect(rendered.string.contains("已执行 2 次终端操作"))
        #expect(!rendered.string.contains("已调用 terminal send command"))
        #expect(!rendered.string.contains("已调用 terminal snapshot"))

        let bodyRange = (rendered.string as NSString).range(of: "Redis 关键调不在尾行。")
        let summaryRange = (rendered.string as NSString).range(of: "已执行 2 次终端操作")
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

        #expect(rendered.string.contains("已读取 1 个文件"))
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
        #expect(bodyFont.pointSize == 14)
        #expect(processedFont.pointSize == bodyFont.pointSize)
        #expect(processedColor == NSColor.tertiaryLabelColor)
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
    func settledGoalTurnKeepsOnlyArtifactsAndFinalDeliverySummary() throws {
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
        let compacted = AgentGoalTranscriptPresentation.settledMessages(from: raw)

        #expect(compacted.map(\.id) == [user.id, artifact.id, final.id])
        #expect(raw.contains(where: { $0.id == failedAttempt.id }))
        #expect(raw.last?.content.contains("goal-check") == true)
        #expect(compacted.last?.content.contains("goal-check") == false)

        let rendered = AgentChatHistoryRenderer.render(
            messages: compacted,
            isDark: false,
            assistantTurnContextMessages: raw
        )
        #expect(rendered.string.contains("完成了，目标已经交付"))
        #expect(!rendered.string.contains("第一次尝试失败"))
        #expect(!rendered.string.contains("Planning the implementation"))
        #expect(!rendered.string.contains("goal-check"))
        #expect(attributeCount(.agentChatHistoryAssistantStatusDividerColor, in: rendered) == 1)
        #expect(occurrences(of: "600/60", in: rendered.string) == 1)
        #expect(firstAttributeRange(
            .agentChatHistoryMessageCopyText,
            value: """
            完成了，目标已经交付。

            - 修改已落盘
            - 验证已通过
            """,
            in: rendered
        ) != nil)
    }

    @Test
    func settledGoalTurnFallsBackToLatestActivityWhenNoSummaryExists() {
        let user = AgentMessage(role: .user, content: "继续")
        let planning = AgentMessage(role: .assistant, content: "Planning next pass")
        let verifying = AgentMessage(role: .assistant, content: "Verifying current files")

        let compacted = AgentGoalTranscriptPresentation.settledMessages(
            from: [user, planning, verifying]
        )

        #expect(compacted.map(\.id) == [user.id, verifying.id])
    }

    @Test
    func settledGoalTurnSanitizesProtocolWhenThereIsOnlyOneAssistantMessage() {
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

        let compacted = AgentGoalTranscriptPresentation.settledMessages(from: [user, final])

        #expect(compacted.map(\.id) == [user.id, final.id])
        #expect(compacted.last?.content == "已完成。")
        #expect(compacted.last?.toolCalls.isEmpty == true)
        #expect(final.content.contains("```progress"))
        #expect(final.toolCalls.count == 1)
    }

    @Test
    @MainActor
    func rendersSettledGoalRoundSummaryForDesignQA() throws {
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
        let compacted = AgentGoalTranscriptPresentation.settledMessages(from: raw)
            .filter { $0.role == .assistant }
        let view = AgentChatHistoryNSTextView()
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = NSSize(width: 32, height: 24)
        view.frame = NSRect(x: 0, y: 0, width: 773, height: 578)
        view.textContainer?.size = NSSize(width: 709, height: CGFloat.greatestFiniteMagnitude)
        view.applyMessages(
            compacted,
            isDark: false,
            assistantTurnContextMessages: raw,
            baseFontSize: 14
        )

        #expect(view.string.contains("完成了，Goal 回合现在会在结束后收束为交付小结"))
        #expect(!view.string.contains("第一次渲染没有收口"))
        #expect(!view.string.contains("swift test"))
        #expect(!view.string.contains("1: done"))
        #expect(!view.string.contains(L10n.AgentTurnProgress.title))

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

        #expect(occurrences(of: "已运行 26 条命令", in: view.string) == 1)
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
            of: "\u{FFFC}  已执行 4 次终端操作"
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
            "已读取 5 个文件",
            "已浏览 4 个目录",
            "已搜索代码 4 次",
            "已查看 Git 状态",
            "已运行 3 条命令",
        ]
        for row in expectedRows {
            #expect(view.string.contains(row))
        }
        #expect(!view.string.contains("已读取 5 个文件 · 已浏览 4 个目录"))

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

    private func attributeCount(
        _ key: NSAttributedString.Key,
        in attributed: NSAttributedString
    ) -> Int {
        var count = 0
        attributed.enumerateAttribute(
            key,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private func lineFragmentHeights(
        in attributed: NSAttributedString,
        width: CGFloat,
        intersecting characterRange: NSRange
    ) -> [CGFloat] {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: width, height: 1000))
        textContainer.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var heights: [CGFloat] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        ) { rect, _, _, lineGlyphRange, _ in
            guard NSIntersectionRange(lineGlyphRange, glyphRange).length > 0 else { return }
            heights.append(rect.height)
        }
        return heights
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

    // MARK: - Workflow report history baking (1.155.0-rc9)
    //
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
