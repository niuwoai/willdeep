import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("侧边栏终端执行偏好")
struct AgentVisibleTerminalPreferenceTests {
    @Test("终端选择持久保存并恢复工具包，浏览器选择不改变执行偏好")
    func preferenceSurvivesSessionRestoration() throws {
        let runtime = AgentRuntime(session: .init())
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.applyPanelExecutionPreference(from: [.browser])
        #expect(!runtime.prefersVisibleTerminal)
        #expect(!runtime.loadedToolPacks.contains(.terminal))
        runtime.applyPanelExecutionPreference(from: [.terminal])
        runtime.pendingPanelStateMentions = []
        runtime.persist(touchUpdatedAt: false)
        let saved = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(runtime.session))
        let restored = AgentRuntime(session: saved)
        #expect(restored.prefersVisibleTerminal)
        #expect(restored.loadedToolPacks.contains(.terminal))
        #expect(!AgentRuntime(session: .init()).prefersVisibleTerminal)
    }

    @Test("老会话缺少执行偏好字段时不自动启用")
    func legacySessionKeepsDefault() throws {
        let data = try JSONEncoder().encode(AgentSession(prefersVisibleTerminal: true))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "prefersVisibleTerminal")
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.prefersVisibleTerminal)
    }

    @Test("排队消息保留面板选择，尚未派发时不修改当前执行偏好")
    func queuedMentionRetainsPreference() throws {
        let f = try AgentGoalMainLoopTests().fixture()
        defer { f.cleanup() }
        f.runtime.isResponding = true
        f.runtime.input = "Inspect the workspace"
        f.runtime.pendingPanelStateMentions = [.terminal]
        f.app.sendAgentMessage()
        #expect(!f.runtime.prefersVisibleTerminal)
        #expect(f.runtime.pendingPanelStateMentions.isEmpty)
        #expect(f.runtime.queuedMessages.first?.panelStateMentions == [.terminal])
    }
}
