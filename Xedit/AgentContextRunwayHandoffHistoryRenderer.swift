//
//  AgentContextRunwayHandoffHistoryRenderer.swift
//  WillDeep
//
//  Renders a context-runway handover as one card in the TextKit transcript
//  instead of five paragraphs of markdown prose.
//

import AppKit
import Foundation

/// The handover the model writes when the context window fills up is not a
/// reply — it is a baton. As plain markdown it reads like any other long
/// answer, and the one thing a person actually has to decide (continue here,
/// or carry it into a fresh session) used to live in two unlabeled footer
/// icons the size of a comma.
///
/// So the finished handover becomes a card: a title that says the turn
/// stopped because the window filled up rather than because the work is done,
/// the model's own sections in the order it wrote them, the exact text that
/// "continue" will send, and two actions with words on them.
///
/// Streaming is deliberately excluded — mid-stream the sections are half
/// written, and a card that reflows every token is worse than the prose it
/// replaces. `AgentMessageView` keeps rendering the plain stripped body until
/// the turn ends and the message folds into history.
nonisolated enum AgentContextRunwayHandoffHistoryRenderer {
    static let resumeLinkValue = "agent-chat-history-handoff-card-resume"
    static let newSessionLinkValue = "agent-chat-history-handoff-card-new-session"

    /// - Parameters:
    ///   - sections: the human-facing sections, already in written order.
    ///   - relayPrompt: the `NEXT PROMPT` body, shown so nobody has to press
    ///     an action to find out what it is about to send.
    ///   - relayPayload: what "continue in a new session" actually carries —
    ///     the *whole* handover, not just the relay line, because the new
    ///     session has none of this conversation.
    ///   - showsActions: false for superseded handovers and for turns that
    ///     are still running; the card still renders, just without buttons.
    static func attributedString(
        sections: [AgentContextRunwayHandoffDisplay.Section],
        relayPrompt: String,
        relayPayload: String,
        showsActions: Bool,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let chromeFontSize = AgentDesign.chatSupportingFontSize(baseFontSize: baseFontSize)
        appendTitle(chromeFontSize: chromeFontSize, to: result)

        for section in sections {
            appendSection(
                title: L10n.ContextRunwayHandoff.sectionTitle(for: section.label),
                body: section.body,
                chromeFontSize: chromeFontSize,
                baseFontSize: baseFontSize,
                to: result
            )
        }
        if !relayPrompt.isEmpty {
            appendSection(
                title: L10n.ContextRunwayHandoff.sectionNextPrompt,
                body: relayPrompt,
                chromeFontSize: chromeFontSize,
                baseFontSize: baseFontSize,
                to: result
            )
        }
        if showsActions {
            appendActions(
                relayPayload: relayPayload,
                chromeFontSize: chromeFontSize,
                to: result
            )
        }
        if result.length > 0 {
            // Marks the card for `applyBubbleChrome`, which gives it the same
            // inset and vertical margins as the turn-progress card. Paragraph
            // styles set in here would be overwritten by that pass anyway, so
            // the card's own hierarchy is carried by weight and color only.
            result.addAttribute(
                .agentChatHistoryHandoffCard,
                value: NSNumber(value: true),
                range: NSRange(location: 0, length: result.length)
            )
        }
        return result
    }

    // MARK: - Pieces

    private static func appendTitle(
        chromeFontSize: CGFloat,
        to result: NSMutableAttributedString
    ) {
        result.append(symbolAttachmentString(
            named: "arrow.uturn.right.circle",
            fallback: "↪",
            pointSize: 11,
            color: NSColor.secondaryLabelColor
        ))
        result.append(label(
            "  \(L10n.ContextRunwayHandoff.cardTitle)",
            font: NSFont.systemFont(ofSize: chromeFontSize, weight: .semibold),
            color: NSColor.secondaryLabelColor
        ))
    }

    private static func appendSection(
        title: String,
        body: String,
        chromeFontSize: CGFloat,
        baseFontSize: CGFloat,
        to result: NSMutableAttributedString
    ) {
        result.append(NSAttributedString(string: "\n"))
        result.append(label(
            title,
            font: NSFont.systemFont(ofSize: chromeFontSize, weight: .medium),
            color: NSColor.secondaryLabelColor
        ))
        guard !body.isEmpty else { return }
        result.append(NSAttributedString(string: "\n"))
        result.append(label(
            body,
            font: NSFont.systemFont(ofSize: baseFontSize),
            color: NSColor.labelColor
        ))
    }

    private static func appendActions(
        relayPayload: String,
        chromeFontSize: CGFloat,
        to result: NSMutableAttributedString
    ) {
        result.append(NSAttributedString(string: "\n"))
        // 图标语义沿用原 footer 两个按钮:播放三角=在这儿接着干,
        // `square.and.pencil`=跟侧边栏新建会话同一件事。
        appendAction(
            icon: "play.circle",
            fallback: "▶",
            text: L10n.ContextRunwayHandoff.resumeAction,
            linkValue: resumeLinkValue,
            payload: [.agentChatHistoryResumeHandoff: NSNumber(value: true)],
            tooltip: L10n.ContextRunwayHandoff.resumeTooltip,
            chromeFontSize: chromeFontSize,
            to: result
        )
        result.append(label(
            "     ",
            font: NSFont.systemFont(ofSize: chromeFontSize),
            color: NSColor.secondaryLabelColor
        ))
        appendAction(
            icon: "square.and.pencil",
            fallback: "✎",
            text: L10n.ContextRunwayHandoff.newSessionAction,
            linkValue: newSessionLinkValue,
            payload: [.agentChatHistoryHandoffRelayPrompt: relayPayload],
            tooltip: L10n.ContextRunwayHandoff.newSessionTooltip,
            chromeFontSize: chromeFontSize,
            to: result
        )
    }

    private static func appendAction(
        icon: String,
        fallback: String,
        text: String,
        linkValue: String,
        payload: [NSAttributedString.Key: Any],
        tooltip: String,
        chromeFontSize: CGFloat,
        to result: NSMutableAttributedString
    ) {
        let start = result.length
        result.append(symbolAttachmentString(
            named: icon,
            fallback: fallback,
            pointSize: 10,
            color: NSColor.secondaryLabelColor
        ))
        result.append(label(
            "  \(text)",
            font: NSFont.systemFont(ofSize: chromeFontSize, weight: .medium),
            color: NSColor.secondaryLabelColor
        ))
        let range = NSRange(location: start, length: result.length - start)
        var attributes: [NSAttributedString.Key: Any] = payload
        attributes[.link] = linkValue
        attributes[.toolTip] = tooltip
        // Grayscale like every other transcript control: the pointer and the
        // leading glyph carry "this is clickable", and platform link blue
        // inside an assistant bubble reads as a URL.
        attributes[.underlineStyle] = 0
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        result.addAttributes(attributes, range: range)
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }
}
