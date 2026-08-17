//
//  AgentComposerLocalPanelTriggerTests.swift
//  WillDeepTests
//

import Testing
@testable import WillDeep

@Suite("Composer #1983# 本地确认面板")
@MainActor
struct AgentComposerLocalPanelTriggerTests {
    @Test("精确口令只在无附件的新会话中匹配")
    func exactTriggerPolicy() {
        #expect(AgentComposerLocalPanelTrigger.matches(
            input: "  #1983#\n",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: false
        ))
        #expect(!AgentComposerLocalPanelTrigger.matches(
            input: "请显示 #1983#",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: false
        ))
        #expect(!AgentComposerLocalPanelTrigger.matches(
            input: "#1983#",
            isNewSession: false,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: false
        ))
        #expect(!AgentComposerLocalPanelTrigger.matches(
            input: "#1983#",
            isNewSession: true,
            hasTurnAttachments: true,
            isResponding: false,
            hasExistingPreview: false
        ))
        #expect(!AgentComposerLocalPanelTrigger.matches(
            input: "#1983#",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: true,
            hasExistingPreview: false
        ))
        #expect(!AgentComposerLocalPanelTrigger.matches(
            input: "#1983#",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: true
        ))
    }

    @Test("发送口令只安装本地面板，不创建消息或请求")
    func triggerInstallsLocalPanelsWithoutDispatch() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = "#1983#"

        appState.sendAgentMessage()

        #expect(runtime.input.isEmpty)
        #expect(runtime.messages.isEmpty)
        #expect(runtime.session.messages.isEmpty)
        #expect(runtime.requestTask == nil)
        #expect(!runtime.isResponding)
        #expect(runtime.queuedMessages.isEmpty)
        #expect(runtime.localConfirmationPreviewCalls.map(\.toolName) == [
            "run_command",
            "web_fetch",
            "create_user_skills",
            "embedded_browser_navigate",
            "computer_use_click",
            "ask_user",
        ])
        #expect(runtime.toolCalls.count == 6)
    }

    @Test("旧会话中的保留口令不会触发，也不会发送给 AI")
    func reservedInputNeverFallsThroughInExistingSession() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.messages = [AgentMessage(role: .user, content: "已有消息")]
        runtime.input = "#1983#"

        appState.sendAgentMessage()

        #expect(runtime.messages.count == 1)
        #expect(runtime.input == "#1983#")
        #expect(!runtime.hasLocalConfirmationPreview)
        #expect(runtime.requestTask == nil)
        #expect(runtime.queuedMessages.isEmpty)
    }

    @Test("预览审批不会执行工具或写入始终允许规则")
    func previewApprovalIsSafe() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        let initialAlwaysAllowedCommands = appState.agentAlwaysAllowedCommands
        runtime.input = "#1983#"
        appState.sendAgentMessage()
        let command = try #require(runtime.localConfirmationPreviewCalls.first)

        appState.alwaysAllowAgentToolCall(id: command.id)

        #expect(runtime.toolCalls.first(where: { $0.id == command.id })?.status == .succeeded)
        #expect(appState.agentAlwaysAllowedCommands == initialAlwaysAllowedCommands)
        #expect(runtime.pendingToolDecisions.isEmpty)
        #expect(runtime.requestTask == nil)
        #expect(runtime.messages.isEmpty)
    }

    @Test("真实输入开始前会清除本地预览")
    func realInputClearsPreviewBeforePreflight() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = "#1983#"
        appState.sendAgentMessage()
        #expect(runtime.hasLocalConfirmationPreview)

        runtime.input = "请重构认证模块，同时完成数据库迁移，并补充单元测试。"
        appState.sendAgentMessage()

        #expect(!runtime.hasLocalConfirmationPreview)
        #expect(runtime.toolCalls.isEmpty)
        #expect(runtime.messages.last?.role == .user)
        #expect(runtime.messages.last?.content.contains("请重构认证模块") == true)
    }

    @Test("清空会话会复位口令预览状态")
    func clearingConversationResetsPreviewState() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = "#1983#"
        appState.sendAgentMessage()
        #expect(runtime.hasLocalConfirmationPreview)

        appState.clearAgentConversation()

        #expect(!runtime.hasLocalConfirmationPreview)
        #expect(runtime.toolCalls.isEmpty)
        runtime.input = "#1983#"
        appState.sendAgentMessage()
        #expect(runtime.localConfirmationPreviewCalls.count == 6)
    }
}
