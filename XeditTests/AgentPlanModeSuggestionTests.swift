//
//  AgentPlanModeSuggestionTests.swift
//  WillDeepTests
//

import Testing
@testable import WillDeep

@Suite
struct AgentPlanModeSuggestionPolicyTests {
    @Test("auto-resolution keeps the requested eight-second window")
    func autoResolutionWindow() {
        #expect(AgentPlanModeSuggestionPolicy.autoResolutionSeconds == 8)
    }

    @Test("simple local tasks do not interrupt with a Plan suggestion")
    func simpleTasksStayInNormalMode() {
        #expect(!AgentPlanModeSuggestionPolicy.shouldSuggest(userText: "修复登录按钮颜色"))
        #expect(!AgentPlanModeSuggestionPolicy.shouldSuggest(userText: "Refactor this small function"))
    }

    @Test("multi-scope engineering tasks suggest Plan mode")
    func complexTaskSuggestsPlan() {
        let task = "请重构认证模块，同时完成数据库迁移，并补充单元测试。"
        #expect(AgentPlanModeSuggestionPolicy.shouldSuggest(userText: task))
    }

    @Test("enumerated multi-step tasks suggest Plan mode")
    func enumeratedTaskSuggestsPlan() {
        let task = """
        请完成下面工作：
        1. 检查现有会话状态
        2. 修复并发切换问题
        3. 运行回归测试
        """
        #expect(AgentPlanModeSuggestionPolicy.shouldSuggest(userText: task))
    }

    @Test("explicit opt-out is respected")
    func explicitOptOutSkipsSuggestion() {
        let task = "直接做，不要 Plan：重构前后端认证并补充集成测试。"
        #expect(!AgentPlanModeSuggestionPolicy.shouldSuggest(userText: task))
    }

    @Test("attachments only strengthen an already meaningful task")
    func attachmentContextIsConservative() {
        #expect(!AgentPlanModeSuggestionPolicy.shouldSuggest(userText: "总结这些文件", attachmentCount: 3))
        #expect(AgentPlanModeSuggestionPolicy.shouldSuggest(
            userText: "请重构认证逻辑并补充测试",
            attachmentCount: 2
        ))
    }
}

@Suite
@MainActor
struct AgentPlanModeSuggestionSendTests {
    @Test("complex sends are parked without clearing the composer")
    func complexSendIsParked() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = Self.complexTask
        let initialMessageCount = runtime.messages.count

        appState.sendAgentMessage()
        defer { appState.cancelAgentPlanModeSuggestion() }

        #expect(runtime.pendingPlanModeSuggestion != nil)
        #expect(runtime.planModeSuggestionAutoResolveTask != nil)
        #expect(runtime.input == Self.complexTask)
        #expect(runtime.messages.count == initialMessageCount)
    }

    @Test("repeated sends cannot bypass a pending suggestion")
    func repeatedSendStaysParked() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = Self.complexTask

        appState.sendAgentMessage()
        let suggestionID = try #require(runtime.pendingPlanModeSuggestion?.id)
        appState.sendAgentMessage()
        defer { appState.cancelAgentPlanModeSuggestion() }

        #expect(runtime.pendingPlanModeSuggestion?.id == suggestionID)
        #expect(runtime.input == Self.complexTask)
        #expect(runtime.messages.isEmpty)
    }

    @Test("manual mode changes cancel the pending countdown")
    func modeChangeCancelsSuggestion() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        runtime.input = Self.complexTask

        appState.sendAgentMessage()
        appState.setAgentInteractionMode(.goal)

        #expect(runtime.interactionMode == .goal)
        #expect(runtime.pendingPlanModeSuggestion == nil)
        #expect(runtime.planModeSuggestionAutoResolveTask == nil)
        #expect(runtime.messages.isEmpty)
    }

    private static let complexTask = "请重构认证模块，同时完成数据库迁移，并补充单元测试。"
}

@Suite
@MainActor
struct AgentNoWorkspaceInteractiveControlTests {
    @Test("session-scoped composer controls materialize one unbound draft")
    func controlsCreateAndReuseUnboundDraft() throws {
        let appState = AppState()
        #expect(appState.activeRuntime == nil)

        appState.setAgentExecutionAgent(.codexCLI)
        let runtime = try #require(appState.activeRuntime)
        let sessionID = runtime.id

        #expect(runtime.workspaceLocation == nil)
        #expect(runtime.workspaceRootPath == nil)
        #expect(runtime.executionAgent == .codexCLI)

        appState.setAgentInteractionMode(.goal)
        appState.setAgentApprovalMode(.requestEveryTime)
        appState.activateAgentExpert(.browserOps)

        #expect(appState.activeAgentSessionID == sessionID)
        #expect(runtime.interactionMode == .goal)
        #expect(runtime.approvalMode == .requestEveryTime)
        #expect(runtime.activeExperts.contains(.browserOps))
    }
}
