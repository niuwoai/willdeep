//
//  AgentChatHistoryAttributeKeys.swift
//  WillDeep
//
//  Shared TextKit attribute keys for Agent chat history formatting,
//  chrome rendering, and hit-testing.
//

import Foundation

extension NSAttributedString.Key {
    static let agentChatHistoryBubbleKind = NSAttributedString.Key("AgentChatHistoryBubbleKind")
    static let agentChatHistoryCodeBlockID = NSAttributedString.Key("AgentChatHistoryCodeBlockID")
    static let agentChatHistoryCodeBlockBodyID = NSAttributedString.Key("AgentChatHistoryCodeBlockBodyID")
    static let agentChatHistoryCodeCopyText = NSAttributedString.Key("AgentChatHistoryCodeCopyText")
    static let agentChatHistoryMessageCopyText = NSAttributedString.Key("AgentChatHistoryMessageCopyText")
    static let agentChatHistoryRetryLastTurn = NSAttributedString.Key("AgentChatHistoryRetryLastTurn")
    static let agentChatHistoryShowTurnReport = NSAttributedString.Key("AgentChatHistoryShowTurnReport")
    static let agentChatHistoryTableBlockID = NSAttributedString.Key("AgentChatHistoryTableBlockID")
    static let agentChatHistoryTablePayload = NSAttributedString.Key("AgentChatHistoryTablePayload")
    static let agentChatHistoryTextAttachment = NSAttributedString.Key("AgentChatHistoryTextAttachment")
    static let agentChatHistoryFilePath = NSAttributedString.Key("AgentChatHistoryFilePath")
    static let agentChatHistoryImageReferenceMarker = NSAttributedString.Key("AgentChatHistoryImageReferenceMarker")
    static let agentChatHistoryToolGroupID = NSAttributedString.Key("AgentChatHistoryToolGroupID")
    static let agentChatHistoryUserMessageID = NSAttributedString.Key("AgentChatHistoryUserMessageID")
    static let agentChatHistoryHeadingLevel = NSAttributedString.Key("AgentChatHistoryHeadingLevel")
}
