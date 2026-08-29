//
//  AgentComposerLocalPanelTriggerTests.swift
//  WillDeepTests
//

import Testing
@testable import WillDeep

@Suite("Composer 本地面板口令")
@MainActor
struct AgentComposerLocalPanelTriggerTests {
    @Test("两个精确口令只在无附件的新会话中匹配")
    func exactTriggerPolicy() {
        #expect(AgentComposerLocalPanelTrigger.matchingKind(
            input: "  #1983#\n",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: false
        ) == .confirmation)
        #expect(AgentComposerLocalPanelTrigger.matchingKind(
            input: "\t#1984# ",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: false
        ) == .workerMonitor)
        #expect(AgentComposerLocalPanelTrigger.matchingKind(
            input: "请显示 #1983#",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: false
        ) == nil)
        #expect(AgentComposerLocalPanelTrigger.matchingKind(
            input: "#1984#",
            isNewSession: false,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: false
        ) == nil)
        #expect(AgentComposerLocalPanelTrigger.matchingKind(
            input: "#1983#",
            isNewSession: true,
            hasTurnAttachments: true,
            isResponding: false,
            hasExistingPreview: false
        ) == nil)
        #expect(AgentComposerLocalPanelTrigger.matchingKind(
            input: "#1984#",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: true,
            hasExistingPreview: false
        ) == nil)
        #expect(AgentComposerLocalPanelTrigger.matchingKind(
            input: "#1983#",
            isNewSession: true,
            hasTurnAttachments: false,
            isResponding: false,
            hasExistingPreview: true
        ) == nil)
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
        #expect(runtime.localPanelPreviewCalls.map(\.toolName) == [
            "run_command",
            "web_fetch",
            "create_user_skills",
            "embedded_browser_navigate",
            "computer_use_click",
            "ask_user",
        ])
        #expect(runtime.toolCalls.count == 6)
    }

    @Test("#1984# 安装运行、完成和失败三种 Worker 监控卡")
    func workerMonitorTriggerInstallsAllPreviewStates() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = "#1984#"

        appState.sendAgentMessage()

        let calls = runtime.localPanelPreviewCalls
        #expect(runtime.input.isEmpty)
        #expect(runtime.messages.isEmpty)
        #expect(runtime.session.messages.isEmpty)
        #expect(runtime.requestTask == nil)
        #expect(!runtime.isResponding)
        #expect(runtime.queuedMessages.isEmpty)
        #expect(calls.map(\.toolName) == ["spawn_agent", "spawn_agent", "spawn_agent"])
        #expect(calls.map(\.status) == [.running, .succeeded, .failed])
        #expect(calls.map(\.subagentIsWorking) == [true, false, false])
        #expect(calls.allSatisfy { $0.subagentLiveActivity != nil })
        #expect(calls.allSatisfy { $0.subagentRunID == nil })
        #expect(calls.first?.subagentLiveActivity?.utterances.count == 2)
        #expect(calls.last?.errorMessage == L10n.AgentDelegation.monitorPreviewFailureMessage)
        #expect(runtime.toolCalls.count == 3)
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
        #expect(!runtime.hasLocalPanelPreview)
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
        let command = try #require(runtime.localPanelPreviewCalls.first)

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
        runtime.input = "#1984#"
        appState.sendAgentMessage()
        #expect(runtime.hasLocalPanelPreview)

        runtime.input = "请重构认证模块，同时完成数据库迁移，并补充单元测试。"
        appState.sendAgentMessage()

        #expect(!runtime.hasLocalPanelPreview)
        #expect(runtime.toolCalls.isEmpty)
        #expect(runtime.messages.last?.role == .user)
        #expect(runtime.messages.last?.content.contains("请重构认证模块") == true)
    }

    @Test("清空会话会复位口令预览状态")
    func clearingConversationResetsPreviewState() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = "#1984#"
        appState.sendAgentMessage()
        #expect(runtime.hasLocalPanelPreview)

        appState.clearAgentConversation()

        #expect(!runtime.hasLocalPanelPreview)
        #expect(runtime.toolCalls.isEmpty)
        runtime.input = "#1983#"
        appState.sendAgentMessage()
        #expect(runtime.localPanelPreviewCalls.count == 6)
    }
}
