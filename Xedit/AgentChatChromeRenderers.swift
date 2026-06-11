//
//  AgentChatChromeRenderers.swift
//  VeilWriter
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
    static let idleLabel = "▭▭ Copy"
    static let copiedLabel = "✓ Done"
    static let linkValue = "agent-chat-history-copy-code"

    static func button(copied: Bool, code: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let label = copied ? copiedLabel : idleLabel
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .underlineStyle: 0,
            .agentChatHistoryCodeCopyText: code,
        ]
        if !copied {
            attributes[.link] = linkValue
        }
        let result = NSMutableAttributedString(string: label, attributes: attributes)
        if !copied {
            result.addAttribute(.kern, value: -4.5, range: NSRange(location: 0, length: 2))
        }
        return result
    }
}

enum AgentChatHistoryFooterChrome {
    static let copyIdleLabel = "▭▭"
    static let copyCopiedLabel = "✓"
    static let retryLabel = "↻"
    static let copyLinkValue = "agent-chat-history-copy-message"
    static let retryLinkValue = "agent-chat-history-retry-last-turn"

    static func copyButton(copied: Bool, message: String) -> NSAttributedString {
        let label = copied ? copyCopiedLabel : copyIdleLabel
        var attributes = copyLinkAttributes(color: copied ? NSColor.systemGreen : NSColor.secondaryLabelColor)
        attributes[.agentChatHistoryMessageCopyText] = message
        if !copied {
            attributes[.link] = copyLinkValue
        }
        let result = NSMutableAttributedString(string: label, attributes: attributes)
        if !copied {
            result.addAttribute(.kern, value: -4.5, range: NSRange(location: 0, length: 2))
        }
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
