import Foundation
import AppKit

/// A view-only grouping of public messages. It never changes the saved conversation.
nonisolated enum AgentTurnProcessPresentation {
    static let linkValue = "agent-chat-history-turn-process"

    struct Group {
        let id: String
        let anchorID: UUID
        let processMessageIDs: Set<UUID>
    }

    static func groups(in messages: [AgentMessage], contextMessages: [AgentMessage]? = nil,
                       isLatestTurnActive: Bool) -> [Group] {
        let visible = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [Group] = []
        var turn: [AgentMessage] = []
        var userID: UUID?
        func finish(active: Bool) {
            guard !active, let userID,
                  !turn.contains(where: { $0.transcriptEvent == .responseStopped }),
                  let finalIndex = turn.lastIndex(where: {
                      $0.role == .assistant && $0.hasRenderableTextContent && $0.toolCalls.isEmpty
                  }), finalIndex == turn.lastIndex(where: { $0.role == .assistant }) else { return }
            let process = turn[..<finalIndex].filter {
                $0.role == .assistant && $0.transcriptEvent == nil && $0.images.isEmpty
                    && $0.textAttachments.isEmpty && !hasPendingAction($0)
                    && ($0.hasRenderableTextContent || !$0.toolCalls.isEmpty)
            }
            guard let first = process.first else { return }
            groups.append(Group(id: userID.uuidString, anchorID: first.id,
                                processMessageIDs: Set(process.map(\.id))))
        }
        for message in contextMessages ?? messages {
            if message.isOperatorInput {
                finish(active: false)
                userID = message.id
                turn = []
            } else if userID != nil, let displayed = visible[message.id] {
                turn.append(displayed)
            }
        }
        finish(active: isLatestTurnActive)
        return groups
    }

    private static func hasPendingAction(_ message: AgentMessage) -> Bool {
        message.settledToolReceipts?.values.contains {
            [.pendingApproval, .awaitingConfirm, .awaitingUserAnswer, .running].contains($0)
        } == true
    }
}

extension AgentChatHistoryRenderer {
    static func appendTurnProcessDisclosure(_ group: AgentTurnProcessPresentation.Group,
                                           expanded: Bool, to result: NSMutableAttributedString,
                                           bodyFont: NSFont, layoutWidth: CGFloat) {
        if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
        let style = NSMutableParagraphStyle()
        style.headIndent = AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
        style.firstLineHeadIndent = style.headIndent
        style.tailIndent = -AgentChatHistoryLayoutMetrics.assistantContentTailInset
        style.lineBreakMode = .byTruncatingTail
        style.paragraphSpacing = 6
        let text = (expanded ? "▾ " : "▸ ") + L10n.TurnProcess.messages(group.processMessageIDs.count)
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: max(11, bodyFont.pointSize - 1)),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
            .link: AgentTurnProcessPresentation.linkValue,
            .agentChatHistoryProcessGroupID: group.id
        ]))
    }
}
