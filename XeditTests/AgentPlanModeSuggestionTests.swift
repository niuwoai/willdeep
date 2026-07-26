//
//  AgentPlanModeSuggestionTests.swift
//  WillDeepTests
//

import Testing
@testable import WillDeep

@Suite
struct AgentPlanModeSuggestionPolicyTests {
    @Test("auto-resolution keeps the requested fifteen-second window")
    func autoResolutionWindow() {
        #expect(AgentPlanModeSuggestionPolicy.autoResolutionSeconds == 15)
    }

    @Test("locally-confident tasks land in the .suggest band")
    func confidentTaskSuggestsBand() {
        let task = "请重构认证模块，同时完成数据库迁移，并补充单元测试。"
        #expect(AgentPlanModeSuggestionPolicy.band(userText: task) == .suggest)
    }

    @Test("mildly complex tasks defer to the flash judge")
    func ambiguousTaskAsksFlash() {
        // A single strong-complexity hint scores 2 → ambiguous → askFlash.
        #expect(AgentPlanModeSuggestionPolicy.band(userText: "帮我重构这个函数") == .askFlash)
    }

    @Test("trivial tasks skip both the banner and the flash judge")
    func trivialTaskSkips() {
        #expect(AgentPlanModeSuggestionPolicy.band(userText: "现在几点了") == .skip)
    }

    @Test("explicit opt-out skips even the flash judge")
    func optOutSkipsBand() {
        let task = "直接做，不要 Plan：重构前后端认证并补充集成测试。"
        #expect(AgentPlanModeSuggestionPolicy.band(userText: task) == .skip)
        #expect(AgentPlanModeSuggestionPolicy.score(userText: task) == nil)
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

    @Test("enumerated multi-step engineering tasks suggest Plan mode")
    func enumeratedTaskSuggestsPlan() {
        // Enumerated (3 steps → +2) plus a refactor signal (+2) and a
        // regression-test signal (+1) clears the raised suggest bar of 4.
        let task = """
        请完成下面的重构工作：
        1. 检查现有会话状态
        2. 重构并发切换逻辑
        3. 运行回归测试
        """
        #expect(AgentPlanModeSuggestionPolicy.shouldSuggest(userText: task))
    }

    @Test("raised bar: a borderline enumerated task defers to the flash judge")
    func borderlineEnumeratedTaskDefersToFlash() {
        // check + fix + run regression tests: scores 3 (verification +1,
        // enumerated +2) — under the old bar of 3 this suggested outright;
        // the 1.202.0 bar of 4 sends it to the flash judge instead.
        let task = """
        请完成下面工作：
        1. 检查现有会话状态
        2. 修复并发切换问题
        3. 运行回归测试
        """
        #expect(AgentPlanModeSuggestionPolicy.band(userText: task) == .askFlash)
        #expect(!AgentPlanModeSuggestionPolicy.shouldSuggest(userText: task))
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
        _ = appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
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
        #expect(runtime.interactionMode == .normal)
        #expect(runtime.errorMessage == L10n.Dispatch.workspaceRequired)
        #expect(runtime.approvalMode == .requestEveryTime)
        #expect(runtime.activeExperts.contains(.browserOps))
    }
}
