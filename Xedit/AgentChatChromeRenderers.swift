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

    /// Per-message report trigger. 仅在 `appendMessageFooter` 判定
    /// `isLatestAssistant && toolCount > 0` 时插入,否则不显示。
    static func reportButton(count: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: reportSymbolString(
            pointSize: 13,
            color: NSColor.secondaryLabelColor
        ))
        result.append(NSAttributedString(string: " \(count)", attributes: [
            .font: footerFont,
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
        paragraphStyle: NSParagraphStyle? = nil
    ) -> NSAttributedString {
        let idleColor = isVisible ? NSColor.secondaryLabelColor : NSColor.clear
        var attributes = copyLinkAttributes(color: copied ? NSColor.systemGreen : idleColor)
        attributes[.agentChatHistoryMessageCopyText] = message
        if let paragraphStyle {
            attributes[.paragraphStyle] = paragraphStyle
        }

        let symbol: NSAttributedString
        if copied {
            symbol = checkmarkSymbolString(pointSize: 13, color: NSColor.systemGreen)
        } else {
            attributes[.link] = copyLinkValue
            symbol = copySymbolString(pointSize: 13, color: idleColor)
        }
        let result = NSMutableAttributedString(attributedString: symbol)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func retryButton() -> NSAttributedString {
        var attributes = retryLinkAttributes(color: NSColor.secondaryLabelColor)
        attributes[.link] = retryLinkValue
        attributes[.agentChatHistoryRetryLastTurn] = NSNumber(value: true)
        return NSAttributedString(string: retryLabel, attributes: attributes)
    }

    static var separator: NSAttributedString {
        NSAttributedString(
            string: "  ",
            attributes: [
                .font: footerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    static func label(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: footerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    static func elapsedLabel(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "◷", attributes: [
            .font: iconFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        result.append(NSAttributedString(string: " \(text)", attributes: [
            .font: footerFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    static var footerFont: NSFont {
        NSFont.systemFont(ofSize: 11, weight: .medium)
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

    private static func retryLinkAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: retryIconFont,
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
