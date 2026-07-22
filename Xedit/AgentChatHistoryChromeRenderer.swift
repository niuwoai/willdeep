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
            result.append(transcriptEventIconToken())
        }
        result.append(NSAttributedString(
            string: "  " + content,
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
        result.addAttributes(
            [
                .paragraphStyle: style,
                .agentChatHistoryTranscriptEventNotice: AgentChatHistoryTranscriptEventNotice.value,
            ],
            range: range
        )
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
        layoutWidth: CGFloat = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = MarkdownSpacing.bodyLine
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
        layoutWidth: CGFloat = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = role == .user ? .right : .left
        style.lineSpacing = 1
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
    }

    static func appendToolCallGroup(
        _ group: ToolCallHistoryGroup,
        isExpanded: Bool,
        to result: NSMutableAttributedString,
        monoFont: NSFont,
        secondaryColor: NSColor
    ) {
        let start = result.length
        let titleText = AgentChatToolSummaryFormatter.collapsedTitle(for: group.calls)
        result.append(NSAttributedString(
            string: titleText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: secondaryColor,
                .link: "agent-chat-history-tool-group",
                .agentChatHistoryToolGroupID: group.id,
            ]
        ))
        result.addAttribute(
            .paragraphStyle,
            value: toolGroupHeaderParagraphStyle(),
            range: NSRange(location: start, length: result.length - start)
        )

        guard isExpanded else { return }

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
            paragraphStyle: toolSummaryParagraphStyle(),
            foregroundColor: nil
        )
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
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: secondaryColor,
                    .underlineStyle: 0,
                    .link: AgentChatHistoryTextAttachmentLink.value,
                    .agentChatHistoryTextAttachment: attachment,
                ]
            ))
        }
    }

    static func appendImageAttachments(
        _ images: [AgentImageAttachment],
        to result: NSMutableAttributedString,
        font: NSFont,
        secondaryColor: NSColor
    ) {
        for (index, image) in images.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            let attachmentStart = result.length
            if let thumbnail = chatHistoryThumbnail(for: image) {
                let attachment = NSTextAttachment()
                attachment.image = thumbnail
                attachment.bounds = NSRect(
                    x: 0,
                    y: -4,
                    width: thumbnail.size.width,
                    height: thumbnail.size.height
                )
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(
                    string: "▧ Image attachment",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
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
        }
    }

    private static func chatHistoryThumbnail(for image: AgentImageAttachment) -> NSImage? {
        // Never touch `dataBase64` here: for file-backed images it
        // round-trips the whole file through a base64 String on every
        // render. Inline bytes decode directly; file-backed images go
        // through CGImageSourceCreateWithURL below.
        if let data = image.inlineImageData,
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            return chatHistoryThumbnail(from: source)
        }
        if let filePath = image.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filePath.isEmpty,
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: filePath) as CFURL, nil) {
            return chatHistoryThumbnail(from: source)
        }
        return nil
    }

    private static func chatHistoryThumbnail(from source: CGImageSource) -> NSImage? {
        let maxSide: CGFloat = 96
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
        to result: NSMutableAttributedString
    ) {
        let start = result.length
        // Keep the complete footer in the attributed string so its height is
        // reserved at rest. User metadata and actions are made transparent
        // together until hover.
        let hideStart = start
        if message.role == .user {
            result.append(AgentChatHistoryFooterChrome.label(formatTimestamp(message.createdAt)))
            result.append(AgentChatHistoryFooterChrome.separator)
        }
        result.append(AgentChatHistoryFooterChrome.copyButton(
            copied: false,
            message: message.copyableContent,
            isVisible: isVisible
        ))

        if message.role == .assistant {
            if let summary = AgentChatMessageMetrics.tokenSummary(for: message) {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.label(summary))
            }
            if let route = message.managedRoute {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.label(route.footerChipText))
            }
            // 1.103.0-rc11: turn-report 图标(原 AgentTurnPostStrip 左侧)
            // 折进 footer,跟 copy/tokens/retry 同一行;只挂在最后一条
            // assistant 上,无工具调用的轮(toolCount==0)与历史轮都不显示。
            if isLatestAssistant, let count = turnReportToolCount, count > 0 {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.reportButton(count: count))
            }
            if isLatestAssistant {
                result.append(AgentChatHistoryFooterChrome.separator)
                result.append(AgentChatHistoryFooterChrome.retryButton())
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
            value: footerParagraphStyle(for: message.role, layoutWidth: layoutWidth),
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

    private static func transcriptEventIconToken() -> NSAttributedString {
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: "cube", accessibilityDescription: nil)?
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

    private static func toolSummaryParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = MarkdownSpacing.toolLine
        style.paragraphSpacing = 3
        style.headIndent = 28
        style.firstLineHeadIndent = 28
        style.tailIndent = -28
        return style
    }

    private static func toolGroupHeaderParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = 1
        style.paragraphSpacingBefore = 2
        style.paragraphSpacing = 1
        // Keep the compact activity summary on the same content column as
        // the assistant prose above it. A bespoke 22 pt inset used to place
        // this label 10 pt left of the 32 pt assistant body edge.
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
