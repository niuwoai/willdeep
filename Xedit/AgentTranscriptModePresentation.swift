//
//  AgentTranscriptModePresentation.swift
//  WillDeep
//
//  The persisted transcript is the audit log. The chat pane is a projection:
//  while a turn runs it shows every public assistant update, then folds the
//  settled turn down to its final answer. Search can temporarily reveal the
//  original process without mutating or re-saving the conversation.
//

import Foundation

nonisolated enum AgentTranscriptModePresentation {
    /// Produces the ordinary chat-pane projection.
    ///
    /// Tool result payloads and hidden host instructions should be filtered
    /// before this boundary. Folding only changes the returned collection;
    /// persisted messages remain byte-for-byte intact.
    static func projectedMessages(
        from messages: [AgentMessage],
        isLatestTurnActive: Bool,
        revealsIntermediateMessages: Bool = false,
        protectedAssistantMessageIDs: Set<AgentMessage.ID> = []
    ) -> [AgentMessage] {
        guard !revealsIntermediateMessages else { return messages }

        var projected: [AgentMessage] = []
        var turn: [AgentMessage] = []

        func appendTurn(_ turn: [AgentMessage], isActive: Bool) {
            guard !turn.isEmpty else { return }
            guard !isActive else {
                projected.append(contentsOf: turn)
                return
            }

            let finalAssistantID = turn.last(where: isFinalAnswerCandidate)?.id
            for message in turn {
                guard message.role == .assistant else {
                    projected.append(message)
                    continue
                }
                if message.id == finalAssistantID
                    || shouldAlwaysRemainVisible(message)
                    || protectedAssistantMessageIDs.contains(message.id) {
                    projected.append(message)
                }
            }
        }

        for message in messages {
            if message.isOperatorInput {
                appendTurn(turn, isActive: false)
                turn = [message]
            } else if turn.isEmpty {
                // Events and legacy assistant messages that predate a user
                // boundary are not safe to classify as intermediate output.
                projected.append(message)
            } else {
                turn.append(message)
            }
        }
        appendTurn(turn, isActive: isLatestTurnActive)
        return projected
    }

    /// Compatibility entry point for standalone readers and other callers
    /// that explicitly need the complete persisted transcript.
    static func modeInvariantMessages(from messages: [AgentMessage]) -> [AgentMessage] {
        projectedMessages(
            from: messages,
            isLatestTurnActive: false,
            revealsIntermediateMessages: true
        )
    }

    private static func isFinalAnswerCandidate(_ message: AgentMessage) -> Bool {
        message.role == .assistant
            && (message.hasRenderableTextContent || !message.images.isEmpty)
    }

    private static func shouldAlwaysRemainVisible(_ message: AgentMessage) -> Bool {
        if !message.images.isEmpty { return true }
        guard let receipts = message.settledToolReceipts else { return false }
        return receipts.values.contains { status in
            switch status {
            case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer, .failed, .denied:
                return true
            case .running, .succeeded:
                return false
            }
        }
    }
}
