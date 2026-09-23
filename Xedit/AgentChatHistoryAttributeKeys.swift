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
    /// 围栏代码块头上「运行」图标携带的命令原文（已净化零宽断点）。
    /// 只有 AgentChatRunnableCommand 放行的块才带这个属性。
    static let agentChatHistoryRunCommandText = NSAttributedString.Key("AgentChatHistoryRunCommandText")
    /// 同上，「送进侧边栏终端」图标携带的命令原文。
    static let agentChatHistoryTerminalCommandText = NSAttributedString.Key(
        "AgentChatHistoryTerminalCommandText"
    )
    static let agentChatHistoryMessageCopyText = NSAttributedString.Key("AgentChatHistoryMessageCopyText")
    static let agentChatHistoryRetryLastTurn = NSAttributedString.Key("AgentChatHistoryRetryLastTurn")
    static let agentChatHistoryShowTurnReport = NSAttributedString.Key("AgentChatHistoryShowTurnReport")
    static let agentChatHistoryTableBlockID = NSAttributedString.Key("AgentChatHistoryTableBlockID")
    static let agentChatHistoryTablePayload = NSAttributedString.Key("AgentChatHistoryTablePayload")
    /// `[NSNumber]` of tab-stop offsets (points from the first column's text
    /// origin, one per column after the first). The chrome pass turns them
    /// into `NSTextTab`s on the table's paragraphs and the layout manager
    /// draws the column separators from the same positions.
    static let agentChatHistoryTableColumns = NSAttributedString.Key("AgentChatHistoryTableColumns")
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
    /// 同一轮 Agent 输出的所有消息共用的 key（该轮最后一条可见回复的 id）。
    static let agentChatHistoryAssistantTurnKey = NSAttributedString.Key("AgentChatHistoryAssistantTurnKey")
    /// footer 里的完成时间标签，值同上。平时透明占位，悬停到这一轮时才显色。
    static let agentChatHistoryTurnTimestamp = NSAttributedString.Key("AgentChatHistoryTurnTimestamp")
    static let agentChatHistoryHeadingLevel = NSAttributedString.Key("AgentChatHistoryHeadingLevel")
    static let agentChatHistoryListDepth = NSAttributedString.Key("AgentChatHistoryListDepth")
    static let agentChatHistoryProgressBlockID = NSAttributedString.Key("AgentChatHistoryProgressBlockID")
    static let agentChatHistoryProgressToggleID = NSAttributedString.Key("AgentChatHistoryProgressToggleID")
    static let agentChatHistoryProgressShowPlan = NSAttributedString.Key("AgentChatHistoryProgressShowPlan")
    /// 整张上下文交接卡片的范围标记，供 bubble chrome 给它卡片级的缩进
    /// 和上下外边距（跟回合进度卡片同一套）。
    static let agentChatHistoryHandoffCard = NSAttributedString.Key("AgentChatHistoryHandoffCard")
    static let agentChatHistoryResumeHandoff = NSAttributedString.Key("AgentChatHistoryResumeHandoff")
    static let agentChatHistoryHandoffRelayPrompt = NSAttributedString.Key("AgentChatHistoryHandoffRelayPrompt")
}
