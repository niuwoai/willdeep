//
//  AgentChatHistoryChromeRenderer.swift
//  WillDeep
//
//  Header, bubble, footer, and tool-group chrome for the TextKit chat renderer.
//

import AppKit
import ImageIO

extension AgentChatHistoryRenderer {
    static func appendTranscriptEventNotice(
        _ event: AgentTranscriptEvent,
        content: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor
    ) {
        let start = result.length
        switch event {
        case .modelChanged:
            result.append(transcriptEventIconToken(systemName: "cube"))
            result.append(NSAttributedString(string: "  "))
        case .responseStopped:
            break
        case .autoPlanModeEntered:
            result.append(transcriptEventIconToken(systemName: "list.number"))
            result.append(NSAttributedString(string: "  "))
        }
        result.append(NSAttributedString(
            string: content,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        ))
        let range = NSRange(location: start, length: result.length - start)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 1
        style.paragraphSpacing = 2
        style.headIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        style.tailIndent = -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        result.addAttributes(
            [
                .paragraphStyle: style,
                .agentChatHistoryTranscriptEventNotice: AgentChatHistoryTranscriptEventNotice.value,
            ],
            range: range
        )
    }

    static func appendActivityHeadline(
        _ presentation: AgentActivityHeadlinePresentation,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor
    ) {
        result.append(transcriptEventIconToken(systemName: presentation.systemImage))
        result.append(NSAttributedString(
            string: "  " + presentation.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium),
                .foregroundColor: color,
            ]
        ))
    }

    static func appendHeader(
        for message: AgentMessage,
        isToolCallOnly: Bool,
        isStreamingAssistantTurn: Bool,
        to result: NSMutableAttributedString,
        headerFont: NSFont,
        assistantStatusFont: NSFont,
        assistantStatusColor: NSColor,
        assistantStatusDividerColor: NSColor,
        secondaryColor: NSColor
    ) {
        if message.role == .assistant, !isToolCallOnly {
            let headerStart = result.length
            result.append(NSAttributedString(
                string: AgentChatMessageMetrics.assistantStatus(
                    for: message,
                    isStreaming: isStreamingAssistantTurn
                ) + "\n",
                attributes: [
                    .font: assistantStatusFont,
                    .foregroundColor: assistantStatusColor,
                ]
            ))
            result.addAttribute(
                .paragraphStyle,
                value: headerParagraphStyle(for: message.role),
                range: NSRange(location: headerStart, length: result.length - headerStart)
            )
            let dividerStart = result.length
            result.append(NSAttributedString(
                string: "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness),
                    .foregroundColor: NSColor.clear,
                    .agentChatHistoryAssistantStatusDividerColor: assistantStatusDividerColor,
                ]
            ))
            result.addAttribute(
                .paragraphStyle,
                value: assistantStatusDividerParagraphStyle(),
                range: NSRange(location: dividerStart, length: result.length - dividerStart)
            )
            return
        }

        let label: String
        let avatar: String
        let color: NSColor
        switch message.role {
        case .system:
            label = "System"
            avatar = "SYS"
            color = NSColor.systemPurple
        case .user:
            // User messages are identified by their right-aligned, faint
            // surface; a repeated "You" label only adds visual noise.
            return
        case .assistant:
            label = "Tool calls"
            avatar = "TL"
            color = NSColor.secondaryLabelColor
        case .tool:
            label = message.toolCallID.map { "Tool output · \($0)" } ?? "Tool output"
            avatar = "OUT"
            color = NSColor.systemGreen
        case .workflowReport:
            // 运行中的 workflow 卡片由 SwiftUI 工作态表面渲染（见
            // AgentChatTranscript 的 activeWorkflowMessages 挂载点）；进
            // 历史的已结束卡片在这个头像行下面由 formatter 烘焙
            // 状态行 + 最终报告（AgentChatHistoryRenderer.workflowHistoryBody）。
            label = "Workflow"
            avatar = "WFL"
            color = NSColor.systemBlue
        case .widget:
            label = "Widget"
            avatar = "WGT"
            color = NSColor.systemTeal
        case .scheduledTask:
            label = "Scheduled task"
            avatar = "TSK"
            color = NSColor.systemIndigo
        }

        let headerStart = result.length
        switch message.role {
        case .user:
            result.append(NSAttributedString(
                string: label + "\n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: secondaryColor,
                ]
            ))
        case .system, .assistant, .tool, .workflowReport, .widget, .scheduledTask:
            result.append(avatarToken(label: avatar, fill: color))
            result.append(NSAttributedString(
                string: " " + label + "\n",
                attributes: [
                    .font: headerFont,
                    .foregroundColor: isToolCallOnly ? color : secondaryColor,
                ]
            ))
        }
        result.addAttribute(
            .paragraphStyle,
            value: headerParagraphStyle(for: message.role),
            range: NSRange(location: headerStart, length: result.length - headerStart)
        )
        if message.role == .user {
            result.addAttribute(
                .agentChatHistoryUserMessageID,
                value: message.id.uuidString,
                range: NSRange(location: headerStart, length: result.length - headerStart)
            )
        }
    }

    static func bubbleKind(for role: AgentRole) -> AgentChatHistoryBubbleKind {
        switch role {
        case .system:
            return .system
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .tool, .workflowReport, .widget, .scheduledTask:
            return .tool
        }
    }

    static func bodyParagraphStyle(
        for role: AgentRole,
        layoutWidth: CGFloat = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth,
        lineSpacing: CGFloat = MarkdownSpacing.bodyLine
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = role == .user ? MarkdownSpacing.userParagraph : MarkdownSpacing.assistantParagraph
        switch role {
        case .user:
            let headIndent = AgentChatHistoryLayoutMetrics.userBodyHeadIndent(for: layoutWidth)
            style.headIndent = headIndent
            style.firstLineHeadIndent = headIndent
            style.tailIndent = AgentChatHistoryLayoutMetrics.userBodyTailIndent
        case .assistant, .system, .tool, .workflowReport, .widget, .scheduledTask:
            style.headIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
            style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
            style.tailIndent = -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        }
        return style
    }

    static func footerParagraphStyle(
        for role: AgentRole,
        layoutWidth: CGFloat = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth,
        lineSpacing: CGFloat = MarkdownSpacing.bodyLine
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = role == .user ? .right : .left
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = role == .user
            ? AgentChatHistoryLayoutMetrics.userFooterBottomSpacing
            : 0
        switch role {
        case .user:
            let headIndent = AgentChatHistoryLayoutMetrics.userBodyHeadIndent(for: layoutWidth)
            style.headIndent = headIndent
            style.firstLineHeadIndent = headIndent
            style.tailIndent = AgentChatHistoryLayoutMetrics.userBodyTailIndent
                - AgentChatHistoryLayoutMetrics.userFooterTrailingInset
            style.paragraphSpacingBefore = AgentChatHistoryLayoutMetrics.userFooterTopSpacing
        case .assistant:
            style.headIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
            style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
            style.tailIndent = -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        case .system, .tool, .workflowReport, .widget, .scheduledTask:
            style.headIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
            style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
            style.tailIndent = -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        }
        return style
    }

    static func userImageParagraphStyle(
        layoutWidth: CGFloat = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.headIndent = AgentChatHistoryLayoutMetrics.userBubbleLeadingEdge(for: layoutWidth)
        style.firstLineHeadIndent = style.headIndent
        style.tailIndent = -AgentChatHistoryLayoutMetrics.userBubbleTrailingMargin
        style.paragraphSpacing = AgentChatHistoryLayoutMetrics.userImageToBubbleSpacing
        return style
    }

    static func applyBubbleChrome(
        kind: AgentChatHistoryBubbleKind,
        to attributed: NSMutableAttributedString,
        range: NSRange,
        paragraphStyle: NSParagraphStyle,
        userMessageID: UUID? = nil,
        foregroundColor: NSColor?
    ) {
        guard range.length > 0 else { return }
        attributed.addAttribute(.agentChatHistoryBubbleKind, value: NSNumber(value: kind.rawValue), range: range)
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        if let userMessageID {
            attributed.addAttribute(.agentChatHistoryUserMessageID, value: userMessageID.uuidString, range: range)
        }
        let codeParagraphStyle = codeBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryCodeBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: codeParagraphStyle, range: subrange)
            applyCodeBlockVerticalMargins(to: attributed, codeRange: subrange, baseStyle: codeParagraphStyle)
        }
        let tableParagraphStyle = tableBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryTableBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: tableParagraphStyle, range: subrange)
            applyTableBlockVerticalMargins(
                to: attributed,
                tableRange: subrange,
                baseStyle: tableParagraphStyle
            )
        }
        let progressStyle = progressBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryProgressBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: progressStyle, range: subrange)
            applyProgressBlockVerticalMargins(
                to: attributed,
                progressRange: subrange,
                baseStyle: progressStyle
            )
        }
        let headingStyle = headingParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryHeadingLevel, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: headingStyle, range: subrange)
        }
        attributed.enumerateAttribute(.agentChatHistoryListDepth, in: range, options: []) { value, subrange, _ in
            guard let depth = (value as? NSNumber)?.intValue else { return }
            attributed.addAttribute(
                .paragraphStyle,
                value: listParagraphStyle(from: paragraphStyle, depth: depth),
                range: subrange
            )
        }
        guard let foregroundColor else { return }
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            if attributes[.link] == nil {
                attributed.addAttribute(.foregroundColor, value: foregroundColor, range: subrange)
            }
        }
    }

    static func applyBodyChrome(
        to attributed: NSMutableAttributedString,
        range: NSRange,
        paragraphStyle: NSParagraphStyle,
        userMessageID: UUID?
    ) {
        guard range.length > 0 else { return }
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        if let userMessageID {
            attributed.addAttribute(.agentChatHistoryUserMessageID, value: userMessageID.uuidString, range: range)
        }
        let codeParagraphStyle = codeBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryCodeBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: codeParagraphStyle, range: subrange)
            applyCodeBlockVerticalMargins(to: attributed, codeRange: subrange, baseStyle: codeParagraphStyle)
        }
        let tableParagraphStyle = tableBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryTableBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: tableParagraphStyle, range: subrange)
            applyTableBlockVerticalMargins(
                to: attributed,
                tableRange: subrange,
                baseStyle: tableParagraphStyle
            )
        }
        let progressStyle = progressBlockParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryProgressBlockID, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: progressStyle, range: subrange)
            applyProgressBlockVerticalMargins(
                to: attributed,
                progressRange: subrange,
                baseStyle: progressStyle
            )
        }
        let headingStyle = headingParagraphStyle(from: paragraphStyle)
        attributed.enumerateAttribute(.agentChatHistoryHeadingLevel, in: range, options: []) { value, subrange, _ in
            guard value != nil else { return }
            attributed.addAttribute(.paragraphStyle, value: headingStyle, range: subrange)
        }
        attributed.enumerateAttribute(.agentChatHistoryListDepth, in: range, options: []) { value, subrange, _ in
            guard let depth = (value as? NSNumber)?.intValue else { return }
            attributed.addAttribute(
                .paragraphStyle,
                value: listParagraphStyle(from: paragraphStyle, depth: depth),
                range: subrange
            )
        }
    }

    static func appendToolCallGroup(
        _ group: ToolCallHistoryGroup,
        isExpanded: Bool,
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        monoFont: NSFont,
        lineSpacing: CGFloat,
        secondaryColor: NSColor
    ) {
        let start = result.length
        let items = AgentCollapsedToolActivitySummary.items(for: group.calls)
        let displayItems = items.isEmpty
            ? [
                AgentCollapsedToolActivitySummary.Item(
                    systemImage: "wrench.and.screwdriver",
                    text: AgentChatToolSummaryFormatter.collapsedTitle(for: group.calls)
                )
            ]
            : items

        for (index, item) in displayItems.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
            }
            result.append(symbolAttachmentString(
                named: item.systemImage,
                fallback: "•",
                pointSize: max(11, bodyFont.pointSize - 1),
                color: secondaryColor
            ))
            result.append(NSAttributedString(
                string: " \(item.text)",
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: secondaryColor,
                ]
            ))
            // Exceptional outcome receipt ((N条失败) / (N条已拒绝)) rides at the
            // tail of the last activity row. Success needs no extra “完成”:
            // the action summary itself already says what was accomplished.
            // Keep the badge in the same secondary tone as the activity line:
            // command failures during a turn are routine (Agent retries), so a
            // red alarm would overstate the severity.
            if index == displayItems.count - 1, let badge = group.outcomeBadge {
                result.append(NSAttributedString(
                    string: badge,
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: secondaryColor,
                    ]
                ))
            }
        }
        result.addAttributes(
            [
                .link: "agent-chat-history-tool-group",
                .agentChatHistoryToolGroupID: group.id,
            ],
            range: NSRange(location: start, length: result.length - start)
        )
        result.addAttribute(
            .paragraphStyle,
            value: toolGroupHeaderParagraphStyle(lineSpacing: lineSpacing),
            range: NSRange(location: start, length: result.length - start)
        )

        guard isExpanded else {
            applyToolGroupVerticalMargins(
                to: result,
                groupRange: NSRange(location: start, length: result.length - start),
                baseStyle: toolGroupHeaderParagraphStyle(lineSpacing: lineSpacing),
                bodyFontSize: bodyFont.pointSize
            )
            return
        }

        result.append(NSAttributedString(string: "\n", attributes: [.font: monoFont]))
        result.append(NSAttributedString(
            string: AgentChatToolSummaryFormatter.toolCallSummary(for: group.calls, argumentLimit: 220),
            attributes: [
                .font: monoFont,
                .foregroundColor: secondaryColor,
            ]
        ))
        applyBubbleChrome(
            kind: .toolSummary,
            to: result,
            range: NSRange(location: start, length: result.length - start),
            paragraphStyle: toolSummaryParagraphStyle(lineSpacing: lineSpacing),
            foregroundColor: nil
        )
        applyToolGroupVerticalMargins(
            to: result,
            groupRange: NSRange(location: start, length: result.length - start),
            baseStyle: toolSummaryParagraphStyle(lineSpacing: lineSpacing),
            bodyFontSize: bodyFont.pointSize
        )
    }

    /// 工具活动组是「上一段正文的执行回执」：它紧跟发起它的那句话
    /// (上间距小)，和下一段正文之间留出更明显的呼吸(下间距大)，
    /// 让「正文 + 活动行」读成一个块，而不是等距排开的独立行。
    ///
    /// 组内每一行都是独立的 TextKit 段落，所以 before/after 只能落在
    /// 首段和末段上；设在共享样式里会把组内行距一并撑开(和代码块、
    /// 表格同一个坑，见 applyCodeBlockVerticalMargins)。
    private static func applyToolGroupVerticalMargins(
        to attributed: NSMutableAttributedString,
        groupRange: NSRange,
        baseStyle: NSParagraphStyle,
        bodyFontSize: CGFloat
    ) {
        guard groupRange.length > 0 else { return }
        let before = AgentChatHistoryLayoutMetrics.toolActivityGroupSpacingBefore(
            baseFontSize: bodyFontSize
        )
        let after = AgentChatHistoryLayoutMetrics.toolActivityGroupSpacingAfter(
            baseFontSize: bodyFontSize
        )
        let text = attributed.string as NSString
        let firstParagraph = text.paragraphRange(
            for: NSRange(location: groupRange.location, length: 0)
        )
        let lastParagraph = text.paragraphRange(
            for: NSRange(location: NSMaxRange(groupRange) - 1, length: 0)
        )
        if firstParagraph == lastParagraph {
            let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            attributed.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
            return
        }
        let firstStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        firstStyle.paragraphSpacingBefore = before
        attributed.addAttribute(.paragraphStyle, value: firstStyle, range: firstParagraph)
        let lastStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        lastStyle.paragraphSpacing = after
        attributed.addAttribute(.paragraphStyle, value: lastStyle, range: lastParagraph)
    }

    static func shouldShowFooter(
        for message: AgentMessage,
        body: String
    ) -> Bool {
        switch message.role {
        case .user:
            return !body.isEmpty || !message.textAttachments.isEmpty || !message.images.isEmpty
        case .assistant:
            return !body.isEmpty || !message.images.isEmpty
        case .workflowReport:
            // 已结束的 workflow 卡片带最终报告(summary)时给 copy 按钮 ——
            // 研究报告/评审结论是用户最想带走的产物。
            return !message.copyableContent.isEmpty
        case .system, .tool, .widget, .scheduledTask:
            return false
        }
    }

    static func appendTextAttachments(
        _ attachments: [AgentTextAttachment],
        to result: NSMutableAttributedString,
        font: NSFont,
        secondaryColor: NSColor
    ) {
        for (index, attachment) in attachments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            let label = "▣ \(attachment.displayName) · \(attachment.byteLabel)"
            result.append(NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium),
                    .foregroundColor: secondaryColor,
                    .underlineStyle: 0,
                    .link: AgentChatHistoryTextAttachmentLink.value,
                    .agentChatHistoryTextAttachment: attachment,
                ]
            ))
        }
    }

    /// How a message's images are sized in the transcript.
    ///
    /// A user's own upload is metadata — they know what they attached, and
    /// echoing it back at full size pushes the conversation off screen. An
    /// image the assistant produced is *content*: a screenshot the user
    /// has not seen is useless at 96pt, which is why captures used to read
    /// as decorative specks next to the prose describing them.
    enum ImageAttachmentPresentation {
        case thumbnail
        case content(layoutWidth: CGFloat)
    }

    static func appendImageAttachments(
        _ images: [AgentImageAttachment],
        to result: NSMutableAttributedString,
        font: NSFont,
        secondaryColor: NSColor,
        presentation: ImageAttachmentPresentation = .thumbnail
    ) {
        for (index, image) in images.enumerated() {
            if index > 0 {
                switch presentation {
                case .thumbnail:
                    result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
                case .content:
                    // Content images stack; a row of large pictures would
                    // wrap unpredictably mid-attachment.
                    result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                }
            }
            let attachmentStart = result.length
            if let rendered = chatHistoryImage(for: image, presentation: presentation) {
                let attachment = NSTextAttachment()
                attachment.image = rendered
                let baselineOffset: CGFloat
                switch presentation {
                case .thumbnail: baselineOffset = -4
                case .content: baselineOffset = 0
                }
                attachment.bounds = NSRect(
                    x: 0,
                    y: baselineOffset,
                    width: rendered.size.width,
                    height: rendered.size.height
                )
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(
                    string: "▧ Image attachment",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium),
                        .foregroundColor: secondaryColor,
                    ]
                ))
            }
            let imageRange = NSRange(location: attachmentStart, length: result.length - attachmentStart)
            result.addAttributes([
                .link: AgentChatHistoryImageLink.value,
                .agentChatHistoryImageID: image.id.uuidString,
                .cursor: NSCursor.arrow,
            ], range: imageRange)
            if let marker = image.generatedReferenceMarker {
                result.addAttribute(.agentChatHistoryImageReferenceMarker, value: marker, range: imageRange)
            }
            if case .content = presentation, let caption = image.originCaption {
                result.append(NSAttributedString(
                    string: "\n\(caption)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: max(10, font.pointSize - 2)),
                        .foregroundColor: secondaryColor,
                    ]
                ))
            }
        }
    }

    private static func chatHistoryImage(
        for image: AgentImageAttachment,
        presentation: ImageAttachmentPresentation
    ) -> NSImage? {
        switch presentation {
        case .thumbnail:
            return chatHistoryThumbnail(for: image)
        case .content(let layoutWidth):
            return chatHistoryContentImage(for: image, layoutWidth: layoutWidth)
        }
    }

    private static func chatHistoryContentImage(
        for image: AgentImageAttachment,
        layoutWidth: CGFloat
    ) -> NSImage? {
        guard let source = chatHistoryImageSource(for: image) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(MarkdownInlineImage.decodeMaxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let contentWidth = AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(layoutWidth)
        let displaySize = MarkdownInlineImage.displaySize(
            pixelSize: NSSize(width: cgImage.width, height: cgImage.height),
            contentWidth: contentWidth
        )
        return NSImage(cgImage: cgImage, size: displaySize)
    }

    private static func chatHistoryImageSource(for image: AgentImageAttachment) -> CGImageSource? {
        // Never touch `dataBase64` here: for file-backed images it
        // round-trips the whole file through a base64 String on every
        // render. Inline bytes decode directly; file-backed images go
        // through CGImageSourceCreateWithURL.
        if let data = image.inlineImageData,
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            return source
        }
        if let filePath = image.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filePath.isEmpty {
            return CGImageSourceCreateWithURL(URL(fileURLWithPath: filePath) as CFURL, nil)
        }
        return nil
    }

    /// Renders a standalone `![alt](path)` line as a real picture sized to
    /// the chat column, with the alt text as a caption underneath. Remote
    /// sources and unreadable files fall back to the alt-text label —
    /// assistant prose is model-controlled, so nothing here touches the
    /// network. See `MarkdownInlineImage` for the resolution rules.
    static func appendMarkdownImageBlock(
        alt: String,
        source: String,
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        secondaryColor: NSColor,
        layoutWidth: CGFloat
    ) {
        guard let url = MarkdownInlineImage.localFileURL(for: source),
              let image = MarkdownInlineImage.loadImage(at: url) else {
            result.append(NSAttributedString(
                string: MarkdownInlineImage.fallbackLabel(alt: alt, source: source),
                attributes: [
                    .font: NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .medium),
                    .foregroundColor: secondaryColor,
                ]
            ))
            return
        }

        let contentWidth = AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(layoutWidth)
        let displaySize = MarkdownInlineImage.displaySize(
            pixelSize: image.size,
            contentWidth: contentWidth
        )
        let sized = NSImage(size: displaySize)
        sized.addRepresentations(image.representations)

        let attachmentStart = result.length
        let attachment = NSTextAttachment()
        attachment.image = sized
        attachment.bounds = NSRect(
            x: 0,
            y: 0,
            width: displaySize.width,
            height: displaySize.height
        )
        result.append(NSAttributedString(attachment: attachment))
        result.addAttributes([
            .link: url,
            .cursor: NSCursor.pointingHand,
            .toolTip: url.path,
        ], range: NSRange(location: attachmentStart, length: result.length - attachmentStart))

        let trimmedAlt = alt.trimmingCharacters(in: .whitespaces)
        if !trimmedAlt.isEmpty {
            result.append(NSAttributedString(
                string: "\n\(trimmedAlt)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: max(10, bodyFont.pointSize - 2)),
                    .foregroundColor: secondaryColor,
                ]
            ))
        }
    }

    private static func chatHistoryThumbnail(for image: AgentImageAttachment) -> NSImage? {
        guard let source = chatHistoryImageSource(for: image) else { return nil }
        return chatHistoryThumbnail(from: source)
    }

    private static func chatHistoryThumbnail(from source: CGImageSource) -> NSImage? {
        let maxSide = MarkdownInlineImage.thumbnailMaxSide
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide * 2)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rawSize = NSSize(width: cgImage.width, height: cgImage.height)
        let scale = min(1, maxSide / max(rawSize.width, rawSize.height))
        let pointSize = NSSize(
            width: max(1, round(rawSize.width * scale)),
            height: max(1, round(rawSize.height * scale))
        )
        return NSImage(cgImage: cgImage, size: pointSize)
    }

    static func appendMessageFooter(
        for message: AgentMessage,
        isLatestAssistant: Bool,
        isVisible: Bool = true,
        turnReportToolCount: Int? = nil,
        layoutWidth: CGFloat = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        bodyFont: NSFont? = nil,
        lineSpacing: CGFloat = MarkdownSpacing.bodyLine,
        to result: NSMutableAttributedString
    ) {
        let metadataFont = bodyFont ?? AgentChatHistoryFooterChrome.footerFont(baseFontSize: baseFontSize)
        let start = result.length
        // Keep the complete footer in the attributed string so its height is
        // reserved at rest. User metadata and actions are made transparent
        // together until hover.
        let hideStart = start
        if message.role == .user {
            result.append(AgentChatHistoryFooterChrome.label(
                formatTimestamp(message.createdAt),
                baseFontSize: baseFontSize,
                font: metadataFont
            ))
            result.append(AgentChatHistoryFooterChrome.separator(baseFontSize: baseFontSize, font: metadataFont))
        }
        result.append(AgentChatHistoryFooterChrome.copyButton(
            copied: false,
            message: AgentCopyTextSanitizer.sanitize(message.copyableContent),
            isVisible: isVisible,
            baseFontSize: baseFontSize,
            font: metadataFont
        ))

        if message.role == .assistant {
            if let summary = AgentChatMessageMetrics.tokenSummary(for: message) {
                result.append(AgentChatHistoryFooterChrome.separator(baseFontSize: baseFontSize, font: metadataFont))
                result.append(AgentChatHistoryFooterChrome.label(summary, baseFontSize: baseFontSize, font: metadataFont))
            }
            if let route = message.managedRoute {
                result.append(AgentChatHistoryFooterChrome.separator(baseFontSize: baseFontSize, font: metadataFont))
                result.append(AgentChatHistoryFooterChrome.label(
                    route.footerChipText,
                    baseFontSize: baseFontSize,
                    font: metadataFont
                ))
            }
            // 1.103.0-rc11: turn-report 图标(原 AgentTurnPostStrip 左侧)
            // 折进 footer,跟 copy/tokens/retry 同一行;只挂在最后一条
            // assistant 上,无工具调用的轮(toolCount==0)与历史轮都不显示。
            if isLatestAssistant, let count = turnReportToolCount, count > 0 {
                result.append(AgentChatHistoryFooterChrome.separator(baseFontSize: baseFontSize, font: metadataFont))
                result.append(AgentChatHistoryFooterChrome.reportButton(
                    count: count,
                    baseFontSize: baseFontSize,
                    font: metadataFont
                ))
            }
            if isLatestAssistant {
                result.append(AgentChatHistoryFooterChrome.separator(baseFontSize: baseFontSize, font: metadataFont))
                result.append(AgentChatHistoryFooterChrome.retryButton(baseFontSize: baseFontSize, font: metadataFont))
            }
        }

        if !isVisible {
            let footerRange = NSRange(location: hideStart, length: result.length - hideStart)
            result.removeAttribute(.link, range: footerRange)
            result.removeAttribute(.agentChatHistoryMessageCopyText, range: footerRange)
            result.removeAttribute(.agentChatHistoryRetryLastTurn, range: footerRange)
            result.addAttribute(.foregroundColor, value: NSColor.clear, range: footerRange)
        }

        result.addAttribute(
            .paragraphStyle,
            value: footerParagraphStyle(
                for: message.role,
                layoutWidth: layoutWidth,
                lineSpacing: lineSpacing
            ),
            range: NSRange(location: start, length: result.length - start)
        )
    }

    private struct AvatarCacheKey: Hashable {
        let label: String
        let fillDescription: String
    }

    private static let avatarCacheLock = NSLock()
    private static var avatarImageCache: [AvatarCacheKey: NSImage] = [:]

    private static func cachedAvatarImage(label: String, fill: NSColor) -> NSImage {
        let key = AvatarCacheKey(label: label, fillDescription: String(describing: fill))
        avatarCacheLock.lock()
        if let hit = avatarImageCache[key] {
            avatarCacheLock.unlock()
            return hit
        }
        avatarCacheLock.unlock()

        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.count > 2 ? 6.2 : 7.6, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attrs)
        let labelRect = NSRect(
            x: (size.width - labelSize.width) / 2,
            y: (size.height - labelSize.height) / 2 - 0.5,
            width: labelSize.width,
            height: labelSize.height
        )
        label.draw(in: labelRect, withAttributes: attrs)
        image.unlockFocus()

        avatarCacheLock.lock()
        avatarImageCache[key] = image
        avatarCacheLock.unlock()
        return image
    }

    private static func avatarToken(label: String, fill: NSColor) -> NSAttributedString {
        let image = cachedAvatarImage(label: label, fill: fill)
        let size = image.size
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -6, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func transcriptEventIconToken(systemName: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) {
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
        }
        return NSAttributedString(attachment: attachment)
    }

    private static func headerParagraphStyle(for role: AgentRole) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = role == .user ? .right : .left
        style.paragraphSpacing = role == .user
            ? 14
            : (role == .assistant ? 0 : MarkdownSpacing.headerToBody)
        style.lineSpacing = 1
        style.headIndent = role == .user
            ? 150
            : (role == .assistant ? AgentChatHistoryLayoutMetrics.assistantContentHeadIndent : 0)
        style.firstLineHeadIndent = style.headIndent
        style.tailIndent = role == .user
            ? -30
            : (role == .assistant ? -AgentChatHistoryLayoutMetrics.assistantContentTailInset : -16)
        return style
    }

    private static func assistantStatusDividerParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness
        style.maximumLineHeight = AgentChatHistoryLayoutMetrics.assistantStatusDividerThickness
        style.paragraphSpacingBefore = AgentChatHistoryLayoutMetrics.assistantStatusDividerTopSpacing
        style.paragraphSpacing = AgentChatHistoryLayoutMetrics.assistantStatusDividerBottomSpacing
        style.headIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        style.tailIndent = -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        return style
    }

    private static func codeBlockParagraphStyle(from baseStyle: NSParagraphStyle) -> NSParagraphStyle {
        let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        // Char-wrap long code lines (docker commands, URLs) instead of
        // clipping them at the card edge — chat has no horizontal scroll,
        // so clipped text was simply unreadable.
        style.lineBreakMode = .byCharWrapping
        if baseStyle.alignment != .right {
            style.headIndent = baseStyle.headIndent + AgentChatHistoryLayoutMetrics.richBlockTextInset
            style.firstLineHeadIndent = baseStyle.firstLineHeadIndent + AgentChatHistoryLayoutMetrics.richBlockTextInset
            style.tailIndent = baseStyle.tailIndent - AgentChatHistoryLayoutMetrics.richBlockTextInset
        }
        return style
    }

    private static func progressBlockParagraphStyle(from baseStyle: NSParagraphStyle) -> NSParagraphStyle {
        let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.headIndent = baseStyle.headIndent + 12
        style.firstLineHeadIndent = baseStyle.firstLineHeadIndent + 12
        if baseStyle.tailIndent < 0 {
            style.tailIndent = baseStyle.tailIndent - 12
        }
        style.lineSpacing = 5
        style.paragraphSpacing = 0
        return style
    }

    private static func applyProgressBlockVerticalMargins(
        to attributed: NSMutableAttributedString,
        progressRange: NSRange,
        baseStyle: NSParagraphStyle
    ) {
        guard progressRange.length > 0 else { return }
        let ns = attributed.string as NSString
        let firstParagraph = ns.paragraphRange(for: NSRange(location: progressRange.location, length: 0))
        let lastLocation = max(progressRange.location, NSMaxRange(progressRange) - 1)
        let lastParagraph = ns.paragraphRange(for: NSRange(location: lastLocation, length: 0))

        // Collapsed progress cards are a single paragraph (the header line has
        // no trailing newline). In that case the first/last ranges coincide, so
        // the top margin and bottom margin must live on ONE style — otherwise the
        // second addAttribute overwrites the first and the card hugs the text
        // above it. Only the expanded, multi-paragraph card can split the two.
        if firstParagraph == lastParagraph {
            let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 12
            style.paragraphSpacing = 10
            attributed.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSIntersectionRange(firstParagraph, progressRange)
            )
            return
        }

        let firstStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        firstStyle.paragraphSpacingBefore = 12
        attributed.addAttribute(
            .paragraphStyle,
            value: firstStyle,
            range: NSIntersectionRange(firstParagraph, progressRange)
        )

        let lastStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        lastStyle.paragraphSpacing = 10
        attributed.addAttribute(
            .paragraphStyle,
            value: lastStyle,
            range: NSIntersectionRange(lastParagraph, progressRange)
        )
    }

    private static func applyCodeBlockVerticalMargins(
        to attributed: NSMutableAttributedString,
        codeRange: NSRange,
        baseStyle: NSParagraphStyle
    ) {
        guard codeRange.length > 0 else { return }
        let text = attributed.string as NSString
        let firstParagraph = text.paragraphRange(for: NSRange(location: codeRange.location, length: 0))
        let lastParagraph = text.paragraphRange(for: NSRange(location: NSMaxRange(codeRange) - 1, length: 0))
        if firstParagraph == lastParagraph {
            let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = MarkdownSpacing.codeBlockBefore
            style.paragraphSpacing = MarkdownSpacing.codeBlockAfter
            attributed.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
            return
        }
        let firstStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        firstStyle.paragraphSpacingBefore = MarkdownSpacing.codeBlockBefore
        attributed.addAttribute(.paragraphStyle, value: firstStyle, range: firstParagraph)
        let lastStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        lastStyle.paragraphSpacing = MarkdownSpacing.codeBlockAfter
        attributed.addAttribute(.paragraphStyle, value: lastStyle, range: lastParagraph)
    }

    private static func tableBlockParagraphStyle(from baseStyle: NSParagraphStyle) -> NSParagraphStyle {
        let style = codeBlockParagraphStyle(from: baseStyle).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        // Keep each monospace row intact, but make the viewport boundary
        // explicit with an ellipsis. The full underlying text remains
        // selectable/copyable, and clicking the table opens the real
        // horizontally scrollable NSTableView detail window.
        style.lineBreakMode = .byTruncatingTail
        style.lineSpacing = MarkdownSpacing.tableLine
        // Each visual table row is a TextKit paragraph. Block margins must
        // therefore be applied only to the first and last row below; putting
        // them on this shared style inflates every row and makes the normal
        // prose after a table look as though its line height suddenly shrank.
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }

    private static func applyTableBlockVerticalMargins(
        to attributed: NSMutableAttributedString,
        tableRange: NSRange,
        baseStyle: NSParagraphStyle
    ) {
        guard tableRange.length > 0 else { return }
        let text = attributed.string as NSString
        let firstParagraph = text.paragraphRange(for: NSRange(location: tableRange.location, length: 0))
        let lastParagraph = text.paragraphRange(for: NSRange(location: NSMaxRange(tableRange) - 1, length: 0))
        if firstParagraph == lastParagraph {
            let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = MarkdownSpacing.tableParagraphBefore
            style.paragraphSpacing = MarkdownSpacing.tableParagraph
            attributed.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
            return
        }
        let firstStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        firstStyle.paragraphSpacingBefore = MarkdownSpacing.tableParagraphBefore
        attributed.addAttribute(.paragraphStyle, value: firstStyle, range: firstParagraph)
        let lastStyle = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        lastStyle.paragraphSpacing = MarkdownSpacing.tableParagraph
        attributed.addAttribute(.paragraphStyle, value: lastStyle, range: lastParagraph)
    }

    private static func headingParagraphStyle(from baseStyle: NSParagraphStyle) -> NSParagraphStyle {
        let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacingBefore = MarkdownSpacing.headingParagraphBefore
        style.paragraphSpacing = MarkdownSpacing.headingParagraph
        return style
    }

    private static func listParagraphStyle(
        from baseStyle: NSParagraphStyle,
        depth: Int
    ) -> NSParagraphStyle {
        let style = baseStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let nesting = CGFloat(min(max(depth, 0), 4))
            * AgentChatHistoryLayoutMetrics.listNestingIndent
        let leading = baseStyle.firstLineHeadIndent + nesting
        style.firstLineHeadIndent = leading
        style.headIndent = leading + AgentChatHistoryLayoutMetrics.listHangingIndent
        style.paragraphSpacing = AgentChatHistoryLayoutMetrics.listParagraphSpacing
        return style
    }

    private static func toolSummaryParagraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = 3
        style.headIndent = 28
        style.firstLineHeadIndent = 28
        style.tailIndent = -28
        return style
    }

    private static func toolGroupHeaderParagraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 3
        style.lineBreakMode = .byWordWrapping
        // Activity is a compact vertical checklist on the same content column
        // as the answer. One semantic operation per row is far easier to scan
        // than a single long, truncated sentence separated by middle dots.
        style.headIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        style.firstLineHeadIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        style.tailIndent = -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        return style
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let dateStyle: DateFormatter.Style = calendar.isDateInToday(date) ? .none : .short
        return DateFormatter.localizedString(from: date, dateStyle: dateStyle, timeStyle: .short)
    }

}
