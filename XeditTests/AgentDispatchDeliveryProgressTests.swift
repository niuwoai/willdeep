import Foundation
import Testing
@testable import WillDeep

@MainActor
struct AgentDispatchDeliveryProgressTests {
    private func goal(_ states: [AgentDispatchTaskState]) -> AgentDispatchGoal {
        .init(id: UUID(), sessionID: UUID(), title: "Delivery", statement: "Verify delivery",
            tasks: states.map { .init(title: $0.rawValue, state: $0) }, executorChoice: .automatic,
            targetChoice: .automatic, isPaused: false, commands: [], createdAt: Date(), updatedAt: Date())
    }

    @Test("只有 merged 计入节点交付，accepted 仍待交付", arguments: AgentDispatchTaskState.allCases)
    func eachState(_ state: AgentDispatchTaskState) {
        let value = goal([state])
        #expect(value.deliveredTaskCount == (state == .merged ? 1 : 0))
        #expect(value.hasDeliveredAllTasks == (state == .merged))
        #expect(value.progressFraction == (state == .merged ? 1 : 0))
        #expect(value.isComplete == value.hasDeliveredAllTasks)
    }

    @Test("空项目不能显示交付完成")
    func empty() {
        let empty = goal([])
        #expect(empty.deliveredTaskCount == 0)
        #expect(!empty.hasDeliveredAllTasks && empty.progressFraction == 0)
        #expect(!empty.isComplete)
    }

    @Test("混合节点保持部分进度且不能释放项目执行槽")
    func mixed() {
        let mixed = goal([.accepted, .merged, .failed, .cancelled])
        #expect(mixed.deliveredTaskCount == 1)
        #expect(!mixed.hasDeliveredAllTasks && mixed.progressFraction == 0.25)
        #expect(!mixed.isComplete)
    }

    @Test("所有节点交付后保持既有完成判定")
    func delivered() {
        let delivered = goal([.merged, .merged])
        #expect(delivered.deliveredTaskCount == 2)
        #expect(delivered.hasDeliveredAllTasks && delivered.progressFraction == 1)
        #expect(delivered.isComplete)
    }

    @Test("已交付节点重新进入执行状态后撤回交付完成显示")
    func reopened() {
        var value = goal([.merged, .merged])
        value.tasks[0].state = .accepted
        #expect(value.deliveredTaskCount == 1)
        #expect(!value.hasDeliveredAllTasks)
        #expect(value.progressFraction == 0.5)
        #expect(!value.isComplete)
    }
}
