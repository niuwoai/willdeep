import AppKit
import Testing
@testable import WillDeep

@Suite("用户回合过程折叠", .serialized)
@MainActor
struct AgentTurnProcessPresentationTests {
    private func sample() -> [AgentMessage] {
        [AgentMessage(role: .user, content: "完成这个任务"),
         AgentMessage(role: .assistant, content: "中间步骤：检查文件"),
         AgentMessage(role: .assistant, content: "中间步骤：执行测试"),
         AgentMessage(role: .assistant, content: "最终结果：已完成，测试通过")]
    }

    @Test("默认只显示最终结果，展开状态参与缓存并可重新收起")
    func renderCollapsedAndExpanded() throws {
        let messages = sample()
        let group = try #require(AgentTurnProcessPresentation.groups(in: messages, isLatestTurnActive: false).first)
        let collapsed = AgentChatHistoryRenderer.render(messages: messages, isDark: false, foldsCompletedTurnProcess: true)
        let expanded = AgentChatHistoryRenderer.render(messages: messages, isDark: false, foldsCompletedTurnProcess: true, expandedProcessGroupIDs: [group.id])
        #expect(!collapsed.string.contains("中间步骤"))
        #expect(collapsed.string.contains("最终结果"))
        #expect(collapsed.string.contains(L10n.TurnProcess.messages(2)))
        #expect(expanded.string.contains("检查文件"))
        #expect(expanded.string.contains("执行测试"))
        #expect(AgentChatHistoryRenderer.render(messages: messages, isDark: false, foldsCompletedTurnProcess: true).string == collapsed.string)
    }

    @Test("真实 TextKit 点击可展开并再次收起，搜索能临时查找中间内容")
    func clickDisclosure() throws {
        let view = AgentChatHistoryNSTextView()
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
        view.foldsCompletedTurnProcess = true
        let messages = sample()
        view.applyMessages(messages, isDark: false)
        func click() throws {
            let storage = try #require(view.textStorage)
            var location: Int?
            storage.enumerateAttribute(.agentChatHistoryProcessGroupID, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value != nil { location = range.location; stop.pointee = true }
            }
            let index = try #require(location)
            #expect(view.textView(view, clickedOnLink: AgentTurnProcessPresentation.linkValue, at: index))
        }
        #expect(!view.string.contains("中间步骤"))
        try click()
        #expect(view.string.contains("中间步骤"))
        try click()
        #expect(!view.string.contains("中间步骤"))
        view.foldsCompletedTurnProcess = false
        view.applyMessages(messages, isDark: false)
        #expect(view.string.contains("中间步骤"))
        view.foldsCompletedTurnProcess = true
        view.applyMessages(messages, isDark: false)
        #expect(!view.string.contains("中间步骤"))
    }

    @Test("运行中或已停止的任务不折叠，历史回合仍可各自展开")
    func activeStoppedAndMultipleTurns() {
        let messages = sample()
        #expect(AgentTurnProcessPresentation.groups(in: messages, isLatestTurnActive: true).isEmpty)
        var stopped = AgentMessage(role: .system, content: "已停止")
        stopped.transcriptEvent = .responseStopped
        #expect(AgentTurnProcessPresentation.groups(in: messages + [stopped], isLatestTurnActive: false).isEmpty)
        let second = sample()
        let groups = AgentTurnProcessPresentation.groups(in: messages + second, isLatestTurnActive: true)
        #expect(groups.count == 1)
        #expect(groups.first?.id == messages[0].id.uuidString)
        #expect(AgentTurnProcessPresentation.groups(in: messages + second, isLatestTurnActive: false).count == 2)
    }

    @Test("分页省略用户气泡时仍从完整上下文恢复回合边界，旧记录无用户边界保持原样")
    func paginationAndLegacy() {
        let messages = sample()
        let visible = Array(messages.dropFirst())
        #expect(AgentTurnProcessPresentation.groups(in: visible, contextMessages: messages, isLatestTurnActive: false).count == 1)
        #expect(AgentTurnProcessPresentation.groups(in: visible, isLatestTurnActive: false).isEmpty)
        let rendered = AgentChatHistoryRenderer.render(messages: visible, isDark: false, assistantTurnContextMessages: messages, foldsCompletedTurnProcess: true)
        #expect(!rendered.string.contains("中间步骤"))
        #expect(rendered.string.contains("最终结果"))
    }

    @Test("待确认消息和独立产物不会被收进过程")
    func pendingActionsStayVisible() {
        var messages = sample()
        messages[1].settledToolReceipts = ["approval": .pendingApproval]
        let artifact = AgentMessage(role: .assistant, content: "独立图片产物", images: [
            AgentImageAttachment(mimeType: "image/png", dataBase64: "")
        ])
        messages.insert(artifact, at: 2)
        let group = AgentTurnProcessPresentation.groups(in: messages, isLatestTurnActive: false).first
        #expect(group?.processMessageIDs.contains(messages[1].id) == false)
        #expect(group?.processMessageIDs.contains(artifact.id) == false)
        let rendered = AgentChatHistoryRenderer.render(messages: messages, isDark: false, foldsCompletedTurnProcess: true)
        #expect(rendered.string.contains("检查文件"))
        #expect(rendered.string.contains("独立图片产物"))
        #expect(!rendered.string.contains("执行测试"))
    }

    @Test("生成浅色深色与窄面板的收起和展开效果图")
    func renderVisualSamples() throws {
        for width: CGFloat in [560, 300] {
            for dark in [false, true] {
                for expanded in [false, true] {
                    let messages = sample()
                    let group = try #require(AgentTurnProcessPresentation.groups(in: messages, isLatestTurnActive: false).first)
                    let view = AgentChatHistoryNSTextView()
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 500)
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    view.foldsCompletedTurnProcess = true
                    view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                    view.backgroundColor = dark ? .black : .white
                    view.linkTextAttributes = [.underlineStyle: 0, .cursor: NSCursor.arrow]
                    view.applyMessages(messages, isDark: dark)
                    if expanded, let storage = view.textStorage {
                        var index: Int?
                        storage.enumerateAttribute(.agentChatHistoryProcessGroupID, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                            if value as? String == group.id { index = range.location; stop.pointee = true }
                        }
                        #expect(view.textView(view, clickedOnLink: AgentTurnProcessPresentation.linkValue, at: try #require(index)))
                    }
                    view.layoutManager?.ensureLayout(for: view.textContainer!)
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: "/private/tmp/turn-process-\(Int(width))-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "collapsed").png"))
                }
            }
        }
    }

    @Test("待确认工具不会被合并进相邻的已折叠工具组")
    func pendingToolGroupStaysVisible() {
        var messages = sample()
        messages[1].toolCalls = [AgentMessageToolCall(externalID: "settled", toolName: "settled_tool", argumentsJSON: "{}")]
        messages[1].settledToolReceipts = ["settled": .succeeded]
        messages[2].content = ""
        messages[2].toolCalls = [AgentMessageToolCall(externalID: "pending", toolName: "pending_tool", argumentsJSON: "{}")]
        messages[2].settledToolReceipts = ["pending": .awaitingConfirm]
        let rendered = AgentChatHistoryRenderer.render(messages: messages, isDark: false, foldsCompletedTurnProcess: true)
        var pendingGroupVisible = false
        rendered.enumerateAttribute(.agentChatHistoryToolGroupID, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value as? String == messages[2].id.uuidString { pendingGroupVisible = true }
        }
        #expect(pendingGroupVisible)
        let expandedTool = AgentChatHistoryRenderer.render(messages: messages, isDark: false,
            expandedToolGroupIDs: [messages[2].id.uuidString], foldsCompletedTurnProcess: true)
        #expect(expandedTool.string.contains("pending_tool"))
        #expect(!rendered.string.contains("settled_tool"))
        #expect(rendered.string.contains("最终结果"))
    }

}
