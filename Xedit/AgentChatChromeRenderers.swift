//
//  AgentChatChromeRenderers.swift
//  WillDeep
//
//  NSAttributedString builders for the two click-targets that ride
//  along inside the chat transcript NSTextView, split out of
//  AgentChatHistoryTextView.swift in rc42:
//
//   - `AgentChatHistoryCodeCopyChrome`: the copy button glyph
//     embedded above every fenced code block. Carries the code body
//     in a custom attributed-string attribute so the NSTextView's
//     `textView(_:clickedOnLink:at:)` delegate can copy it without
//     hunting back through the underlying message model.
//   - `AgentChatHistoryFooterChrome`: the per-assistant-turn footer —
//     copy / retry icon buttons plus the elapsed-time label. Same
//     pattern: glyph + link + sidecar attribute holding the payload
//     the delegate needs.
//
//  Both depend on the NSAttributedString.Key extensions still living
//  in AgentChatHistoryTextView.swift (now internal). Stayed enum-only
//  here — no state, just static builders.
//

import AppKit

enum AgentChatHistoryCodeCopyChrome {
    static let idleText = " Copy"
    static let copiedLabel = "✓ Done"
    static let linkValue = "agent-chat-history-copy-code"

    static func button(copied: Bool, code: String, font: NSFont, color: NSColor) -> NSAttributedString {
        if copied {
            return NSAttributedString(string: copiedLabel, attributes: [
                .font: font,
                .foregroundColor: color,
                .underlineStyle: 0,
                .agentChatHistoryCodeCopyText: code,
            ])
        }

        let result = NSMutableAttributedString()
        result.append(copySymbolString(pointSize: font.pointSize, color: color))
        result.append(NSAttributedString(string: idleText, attributes: [
            .font: font,
            .foregroundColor: color,
            .underlineStyle: 0,
            .agentChatHistoryCodeCopyText: code,
        ]))
        result.addAttributes([
            .link: linkValue,
            .agentChatHistoryCodeCopyText: code,
        ], range: NSRange(location: 0, length: result.length))
        return result
    }
}

enum AgentChatHistoryFooterChrome {
    static let retryLabel = "↻"
    static let copyLinkValue = "agent-chat-history-copy-message"
    static let retryLinkValue = "agent-chat-history-retry-last-turn"
    /// 1.103.0-rc11: 用 `AgentTurnPostStrip` 那行原本承载的 turn-report
    /// 图标搬进 TextKit footer,跟 copy / ◷ / tokens / ↻ 同一行。link
    /// 值供 NSTextView 的 `clickedOnLink` 路由到 popover。
    static let reportLinkValue = "agent-chat-history-show-turn-report"
    /// 上下文跑道交接的两个接力动作。只在最后一条 assistant 消息、且
    /// 这条消息真的是一次 handoff 时出现 —— 正文里的 `NEXT PROMPT:`
    /// 段落被折进这两个图标,别处不再重复。
    static let resumeHandoffLinkValue = "agent-chat-history-resume-handoff"
    static let handoffNewSessionLinkValue = "agent-chat-history-handoff-new-session"

    /// "在本会话继续":把本地化的「继续」填进输入框。
    static func resumeHandoffButton(
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        font: NSFont? = nil
    ) -> NSAttributedString {
        let font = font ?? footerFont(baseFontSize: baseFontSize)
        let result = NSMutableAttributedString(attributedString: resumeSymbolString(
            pointSize: font.pointSize,
            color: NSColor.secondaryLabelColor
        ))
        result.addAttributes([
            .link: resumeHandoffLinkValue,
            .agentChatHistoryResumeHandoff: NSNumber(value: true),
            .toolTip: L10n.ContextRunwayHandoff.resumeTooltip,
        ], range: NSRange(location: 0, length: result.length))
        return result
    }

    /// "开新会话继续":新建会话并把接力提示词填进它的输入框。提示词
    /// 挂在 sidecar 属性上,点击时不必回头再解析一遍消息正文。
    static func handoffNewSessionButton(
        relayPrompt: String,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        font: NSFont? = nil
    ) -> NSAttributedString {
        let font = font ?? footerFont(baseFontSize: baseFontSize)
        let result = NSMutableAttributedString(attributedString: newSessionSymbolString(
            pointSize: font.pointSize,
            color: NSColor.secondaryLabelColor
        ))
        result.addAttributes([
            .link: handoffNewSessionLinkValue,
            .agentChatHistoryHandoffRelayPrompt: relayPrompt,
            .toolTip: L10n.ContextRunwayHandoff.newSessionTooltip,
        ], range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Per-message report trigger. 仅在 `appendMessageFooter` 判定
    /// `isLatestAssistant && toolCount > 0` 时插入,否则不显示。
    static func reportButton(
        count: Int,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        font: NSFont? = nil
    ) -> NSAttributedString {
        let font = font ?? footerFont(baseFontSize: baseFontSize)
        let result = NSMutableAttributedString(attributedString: reportSymbolString(
            pointSize: font.pointSize,
            color: NSColor.secondaryLabelColor
        ))
        result.append(NSAttributedString(string: " \(count)", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .underlineStyle: 0,
        ]))
        result.addAttributes([
            .link: reportLinkValue,
            .agentChatHistoryShowTurnReport: NSNumber(value: true),
        ], range: NSRange(location: 0, length: result.length))
        return result
    }

    static func copyButton(
        copied: Bool,
        message: String,
        isVisible: Bool = true,
        paragraphStyle: NSParagraphStyle? = nil,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        font: NSFont? = nil
    ) -> NSAttributedString {
        let font = font ?? footerFont(baseFontSize: baseFontSize)
        let idleColor = isVisible ? NSColor.secondaryLabelColor : NSColor.clear
        var attributes = copyLinkAttributes(color: copied ? NSColor.systemGreen : idleColor)
        attributes[.agentChatHistoryMessageCopyText] = message
        if let paragraphStyle {
            attributes[.paragraphStyle] = paragraphStyle
        }

        let symbol: NSAttributedString
        if copied {
            symbol = checkmarkSymbolString(pointSize: font.pointSize, color: NSColor.systemGreen)
        } else {
            attributes[.link] = copyLinkValue
            symbol = copySymbolString(pointSize: font.pointSize, color: idleColor)
        }
        let result = NSMutableAttributedString(attributedString: symbol)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func retryButton(
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        font: NSFont? = nil
    ) -> NSAttributedString {
        var attributes = retryLinkAttributes(
            color: NSColor.secondaryLabelColor,
            font: font ?? footerFont(baseFontSize: baseFontSize)
        )
        attributes[.link] = retryLinkValue
        attributes[.agentChatHistoryRetryLastTurn] = NSNumber(value: true)
        return NSAttributedString(string: retryLabel, attributes: attributes)
    }

    static func separator(
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        font: NSFont? = nil
    ) -> NSAttributedString {
        NSAttributedString(
            string: "  ",
            attributes: [
                .font: font ?? footerFont(baseFontSize: baseFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    static func label(
        _ text: String,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        font: NSFont? = nil
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font ?? footerFont(baseFontSize: baseFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    static func elapsedLabel(
        _ text: String,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault
    ) -> NSAttributedString {
        let font = footerFont(baseFontSize: baseFontSize)
        let result = NSMutableAttributedString(string: "◷", attributes: [
            .font: iconFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        result.append(NSAttributedString(string: " \(text)", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    static func footerFont(baseFontSize: CGFloat) -> NSFont {
        NSFont.systemFont(
            ofSize: AgentDesign.chatSupportingFontSize(
                baseFontSize: baseFontSize,
                visualMinimum: 11
            ),
            weight: .medium
        )
    }

    private static var iconFont: NSFont {
        NSFont.systemFont(ofSize: 18, weight: .semibold)
    }

    private static var retryIconFont: NSFont {
        NSFont.systemFont(ofSize: 13, weight: .semibold)
    }

    private static func copyLinkAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        iconLinkAttributes(color: color)
    }

    private static func iconLinkAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: iconFont,
            .foregroundColor: color,
            .underlineStyle: 0,
        ]
    }

    private static func retryLinkAttributes(color: NSColor, font: NSFont = retryIconFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .underlineStyle: 0,
        ]
    }
}

private func copySymbolString(pointSize: CGFloat, color: NSColor) -> NSAttributedString {
    symbolAttachmentString(named: "square.on.square", fallback: "⧉", pointSize: pointSize, color: color)
}

private func checkmarkSymbolString(pointSize: CGFloat, color: NSColor) -> NSAttributedString {
    symbolAttachmentString(named: "checkmark", fallback: "✓", pointSize: pointSize, color: color)
}

/// Same `doc.text` 图标语义,跟 `AgentTurnPostStrip` 原来的
/// `list.bullet.clipboard` 含义对齐:点开 = 看本轮工具/Approvals/
/// Learning/Tokens/Mode 报告。
private func reportSymbolString(pointSize: CGFloat, color: NSColor) -> NSAttributedString {
    symbolAttachmentString(named: "doc.text", fallback: "▤", pointSize: pointSize, color: color)
}

/// 「在这儿接着干」——播放三角是继续执行最没有歧义的图标语义。
private func resumeSymbolString(pointSize: CGFloat, color: NSColor) -> NSAttributedString {
    symbolAttachmentString(named: "play.circle", fallback: "▶", pointSize: pointSize, color: color)
}

/// 「换个新会话接着干」——跟侧边栏新建会话用同一个 `square.and.pencil`
/// 语义,用户在两处看到的是同一件事。
private func newSessionSymbolString(pointSize: CGFloat, color: NSColor) -> NSAttributedString {
    symbolAttachmentString(named: "square.and.pencil", fallback: "✎", pointSize: pointSize, color: color)
}

/// Footer chrome for rendered Markdown tables in the history NSTextView.
/// The "open the table in a standalone window" affordance is a small icon
/// (no text label), tinted to match the link color, carrying the same
/// `.link` tap target the delegate already routes to the detail window.
enum AgentChatHistoryTableChrome {
    static func openInWindowIcon(pointSize: CGFloat, color: NSColor) -> NSAttributedString {
        symbolAttachmentString(named: "arrow.up.right.square", fallback: "⤢", pointSize: pointSize, color: color)
    }
}

/// Render an SF Symbol as a color-tinted inline text attachment, with a
/// unicode glyph fallback if the symbol is unavailable.
func symbolAttachmentString(
    named name: String,
    fallback: String,
    pointSize: CGFloat,
    color: NSColor
) -> NSAttributedString {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
        return NSAttributedString(string: fallback, attributes: [
            .font: NSFont.systemFont(ofSize: pointSize, weight: .regular),
            .foregroundColor: color,
            .underlineStyle: 0,
        ])
    }

    let size = NSSize(width: ceil(pointSize + 1), height: ceil(pointSize + 1))
    let tinted = NSImage(size: size)
    tinted.lockFocus()
    image.draw(
        in: NSRect(origin: .zero, size: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    color.setFill()
    NSRect(origin: .zero, size: size).fill(using: .sourceIn)
    tinted.unlockFocus()
    tinted.isTemplate = false

    let attachment = NSTextAttachment()
    attachment.image = tinted
    attachment.bounds = NSRect(x: 0, y: -2, width: size.width, height: size.height)
    return NSAttributedString(attachment: attachment)
}
