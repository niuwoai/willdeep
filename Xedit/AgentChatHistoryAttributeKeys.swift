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
    static let agentChatHistoryAssistantStatusDividerColor = NSAttributedString.Key(
        "AgentChatHistoryAssistantStatusDividerColor"
    )
    static let agentChatHistoryCodeBlockID = NSAttributedString.Key("AgentChatHistoryCodeBlockID")
    static let agentChatHistoryCodeBlockBodyID = NSAttributedString.Key("AgentChatHistoryCodeBlockBodyID")
    static let agentChatHistoryCodeCopyText = NSAttributedString.Key("AgentChatHistoryCodeCopyText")
    static let agentChatHistoryMessageCopyText = NSAttributedString.Key("AgentChatHistoryMessageCopyText")
    static let agentChatHistoryRetryLastTurn = NSAttributedString.Key("AgentChatHistoryRetryLastTurn")
    static let agentChatHistoryShowTurnReport = NSAttributedString.Key("AgentChatHistoryShowTurnReport")
    static let agentChatHistoryTableBlockID = NSAttributedString.Key("AgentChatHistoryTableBlockID")
    static let agentChatHistoryTablePayload = NSAttributedString.Key("AgentChatHistoryTablePayload")
    static let agentChatHistoryInlineCodeChipColor = NSAttributedString.Key("AgentChatHistoryInlineCodeChipColor")
    static let agentChatHistoryTextAttachment = NSAttributedString.Key("AgentChatHistoryTextAttachment")
    static let agentChatHistoryFilePath = NSAttributedString.Key("AgentChatHistoryFilePath")
    static let agentChatHistoryAttachmentCitation = NSAttributedString.Key("AgentChatHistoryAttachmentCitation")
    static let agentChatHistoryTranscriptEventNotice = NSAttributedString.Key("AgentChatHistoryTranscriptEventNotice")
    static let agentChatHistoryImageID = NSAttributedString.Key("AgentChatHistoryImageID")
    static let agentChatHistoryImageReferenceMarker = NSAttributedString.Key("AgentChatHistoryImageReferenceMarker")
    static let agentChatHistoryToolGroupID = NSAttributedString.Key("AgentChatHistoryToolGroupID")
    static let agentChatHistoryUserMessageID = NSAttributedString.Key("AgentChatHistoryUserMessageID")
    static let agentChatHistoryMessageID = NSAttributedString.Key("AgentChatHistoryMessageID")
    static let agentChatHistoryHeadingLevel = NSAttributedString.Key("AgentChatHistoryHeadingLevel")
    static let agentChatHistoryListDepth = NSAttributedString.Key("AgentChatHistoryListDepth")
    static let agentChatHistoryProgressBlockID = NSAttributedString.Key("AgentChatHistoryProgressBlockID")
    static let agentChatHistoryProgressToggleID = NSAttributedString.Key("AgentChatHistoryProgressToggleID")
    static let agentChatHistoryProgressShowPlan = NSAttributedString.Key("AgentChatHistoryProgressShowPlan")
    static let agentChatHistoryResumeHandoff = NSAttributedString.Key("AgentChatHistoryResumeHandoff")
    static let agentChatHistoryHandoffRelayPrompt = NSAttributedString.Key("AgentChatHistoryHandoffRelayPrompt")
}
