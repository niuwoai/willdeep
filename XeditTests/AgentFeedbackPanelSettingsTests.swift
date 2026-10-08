import Foundation
import Testing
@testable import WillDeep

@Suite("回合反馈面板设置")
@MainActor
struct AgentFeedbackPanelSettingsTests {
    @Test("首次使用默认显示；关闭后重读仍关闭，再开启可恢复")
    func defaultAndPersistence() throws {
        let suite = "feedback-panel-test.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        #expect(AgentSettingsStore.loadFeedbackPanelEnabled(from: storage))
        AgentSettingsStore.saveFeedbackPanelEnabled(false, to: storage)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(!AgentSettingsStore.loadFeedbackPanelEnabled(from: reopened))
        AgentSettingsStore.saveFeedbackPanelEnabled(true, to: reopened)
        #expect(AgentSettingsStore.loadFeedbackPanelEnabled(from: storage))
    }
}
