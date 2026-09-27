//
//  AgentTranscriptCardHistoryRenderer.swift
//  WillDeep
//
//  定时任务卡片(.scheduledTask)与设计门卡片(.specProposal)在 TextKit
//  历史里的烘焙。
//
//  两种角色的消息 content 恒为空,展示数据全在 `scheduledTask` /
//  `specProposal` 字段上。主 transcript 自 1.155.0-rc16 起把已落定的历史
//  折进一个 NSTextView,AgentModeMessageView 里这两张 SwiftUI 卡片的分支
//  只剩流式 assistant 一个入口,于是历史里只剩「TSK / DSN」头像行:设计门
//  等着用户做的那个决定,用户根本看不见。这里补的是 workflow 卡片
//  (1.155.0-rc9)同款的两条路:
//
//  - 待裁决的设计提案仍走 SwiftUI(`needsLiveSurface`):采纳 / 打开文档 /
//    跳过三个按钮要能点,挂载点在 AgentChatTranscript。
//  - 定时任务卡片与已裁决的提案烘焙成 markdown 正文(标题行、依据)加
//    一行可点的动作或只读的状态;链接属性由
//    AgentChatHistoryNSTextView.textView(_:clickedOnLink:at:) 接。
//

import AppKit
import Foundation

enum AgentChatHistoryScheduledTaskLink {
    static let value = "agent-chat-history-scheduled-task"
}

enum AgentTranscriptCardHistoryRenderer {
    /// 状态行里 SF Symbol 的字号,与交接卡片的动作行一致。
    private static let statusGlyphPointSize: CGFloat = 10

    /// 待裁决(含「先改文档」的 deferred)的设计提案不进 TextKit 历史:
    /// 它的三个按钮要能点,由 AgentChatTranscript 挂成 SwiftUI 卡片。
    /// 裁决一落,消息就折回历史,由 `specProposalBody` 烘焙。
    static func needsLiveSurface(_ message: AgentMessage) -> Bool {
        guard message.role == .specProposal, let proposal = message.specProposal else {
            return false
        }
        return proposal.isPending
    }

    // MARK: - Markdown 正文

    /// 定时任务卡片的正文:一行「**标题** · 调度摘要」,有目标再补一行。
    /// 不放 prompt:那是例程的完整提示词,可能很长,例程详情页里有。
    static func scheduledTaskBody(for card: AgentScheduledTaskCard) -> String {
        var blocks = ["**\(card.title)** · \(card.scheduleSummary)"]
        if let goal = card.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            blocks.append(L10n.ScheduledTaskCard.goalPrefix + goal)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// 设计提案的正文:标题行带文档路径,依据逐条列出。路径写成行内代码,
    /// markdown 渲染时按路径 chip 变成可点链接(点开走
    /// revealAgentReferencedPath),行内代码同时挡住文件名里的下划线被当
    /// 成强调。依据最多 `visibleSignalLimit` 条,其余折成「还有 N 条」,
    /// 与 SwiftUI 卡片一致。结论不在这里:它是一行状态 chrome,见
    /// `specProposalStatusLine`。
    static func specProposalBody(for proposal: AgentSpecProposal) -> String {
        var blocks = ["**\(L10n.SpecGateCard.title)** · `\(proposal.documentPath)`"]
        let limit = AgentSpecProposalCardLayout.visibleSignalLimit
        var signalLines = proposal.signals.prefix(limit).map { "- \($0.evidence)" }
        if proposal.signals.count > limit {
            signalLines.append("- \(L10n.SpecGateCard.moreSignals(proposal.signals.count - limit))")
        }
        if !signalLines.isEmpty {
            blocks.append(signalLines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - 动作 / 状态行

    /// 定时任务的动作或状态行。例程还在就给一个可点的「打开」(链接属性带
    /// 例程 id,点了跳到定时任务页的详情);例程已自完成就画一行灰的
    /// 「已完成」。`isActive == nil` 表示调用方不知道例程还在不在(transcript
    /// 阅读窗口没有 AppState),那就两样都不画,只留正文当记录。
    static func scheduledTaskStatusLine(
        for card: AgentScheduledTaskCard,
        isActive: Bool?,
        baseFontSize: CGFloat
    ) -> NSAttributedString? {
        guard let isActive else { return nil }
        let chromeFontSize = AgentDesign.chatSupportingFontSize(baseFontSize: baseFontSize)
        let result = NSMutableAttributedString()
        if isActive {
            appendAction(
                icon: "clock",
                fallback: "◷",
                text: L10n.ScheduledTaskCard.open,
                linkValue: AgentChatHistoryScheduledTaskLink.value,
                payload: [.agentChatHistoryScheduledTaskID: card.id.uuidString],
                tooltip: helpText(for: card),
                chromeFontSize: chromeFontSize,
                to: result
            )
        } else {
            appendStatus(
                icon: "checkmark.circle",
                fallback: "✓",
                text: L10n.ScheduledTaskCard.completed,
                chromeFontSize: chromeFontSize,
                to: result
            )
        }
        return result
    }

    /// 已裁决的设计提案的结论行:采纳 / 跳过各一句,与 SwiftUI 卡片落定后
    /// 显示的 `settledLabel` 同一份文案。待裁决的没有结论。
    static func specProposalStatusLine(
        for proposal: AgentSpecProposal,
        baseFontSize: CGFloat
    ) -> NSAttributedString? {
        let chromeFontSize = AgentDesign.chatSupportingFontSize(baseFontSize: baseFontSize)
        let result = NSMutableAttributedString()
        switch proposal.choice {
        case .accepted:
            appendStatus(
                icon: "checkmark.circle",
                fallback: "✓",
                text: L10n.SpecGateCard.accepted,
                chromeFontSize: chromeFontSize,
                to: result
            )
        case .dismissed:
            appendStatus(
                icon: "xmark.circle",
                fallback: "✕",
                text: L10n.SpecGateCard.dismissed,
                chromeFontSize: chromeFontSize,
                to: result
            )
        case .deferred, .none:
            return nil
        }
        return result
    }

    private static func helpText(for card: AgentScheduledTaskCard) -> String {
        guard let goal = card.goal, !goal.isEmpty else { return card.prompt }
        return goal
    }

    /// 与交接卡片的动作同款:灰字 + 前导图标承担「可点」,不用系统链接蓝。
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
        appendStatus(
            icon: icon,
            fallback: fallback,
            text: text,
            chromeFontSize: chromeFontSize,
            weight: .medium,
            to: result
        )
        var attributes: [NSAttributedString.Key: Any] = payload
        attributes[.link] = linkValue
        attributes[.toolTip] = tooltip
        attributes[.underlineStyle] = 0
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        result.addAttributes(attributes, range: NSRange(location: start, length: result.length - start))
    }

    private static func appendStatus(
        icon: String,
        fallback: String,
        text: String,
        chromeFontSize: CGFloat,
        weight: NSFont.Weight = .regular,
        to result: NSMutableAttributedString
    ) {
        result.append(symbolAttachmentString(
            named: icon,
            fallback: fallback,
            pointSize: statusGlyphPointSize,
            color: NSColor.secondaryLabelColor
        ))
        result.append(NSAttributedString(
            string: "  \(text)",
            attributes: [
                .font: NSFont.systemFont(ofSize: chromeFontSize, weight: weight),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
    }
}
