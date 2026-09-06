import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite(.serialized)
struct AgentDispatchOutcomeRevisionTests {
    @Test("规划或父验收变化自动撤销旧证据，普通进度同步与重载不反复失效", arguments: ["node", "commands", "parent", "removed"])
    func projectedDefinitionInvalidation(change: String) throws {
        let suite = "projection-revision-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentDispatchStore(defaults: defaults)
        let coordinator = AgentDispatchCoordinator(store: store)
        let ids = (0..<3).map { _ in UUID() }
        var session = AgentSession(title: "Project", workspaceRootPath: "/tmp/projection-fixture",
            presentationScope: .dispatchBoard, currentGoal: .init(statement: "Deliver",
                checklist: [.init(text: "All verified")], dispatchPlan: .init(nodes: ids.enumerated().map { i, id in
                    .init(id: id, key: "N\(i)", title: "Node \(i)", dependencyIDs: i == 1 ? [ids[0]] : [],
                        primaryProfileID: nil, fallbackProfileIDs: [], acceptanceCriteria: ["Original"],
                        verificationCommands: ["ruby verify.rb"])
                })))
        coordinator.synchronize(with: [session])
        coordinator.updateGoal(id: session.id) { goal in
            goal.isPaused = true
            for i in goal.tasks.indices {
                goal.tasks[i].state = .merged
                goal.tasks[i].runtimeSessionID = UUID()
                goal.tasks[i].operatorAcceptedAt = Date()
            }
        }
        session.currentGoal?.checklist[0].done = true
        coordinator.synchronize(with: [session])
        #expect(coordinator.goals[0].isComplete)
        #expect(coordinator.goals[0].tasks.allSatisfy { $0.deliveryRevisionID == nil })
        let independent = coordinator.goals[0].tasks[2]
        switch change {
        case "node": session.currentGoal?.dispatchPlan?.nodes[0].acceptanceCriteria = ["New requirement"]
        case "commands": session.currentGoal?.dispatchPlan?.nodes[0].verificationCommands = ["ruby stronger.rb"]
        case "parent": session.currentGoal?.checklist[0].text = "New parent acceptance"
        default:
            session.currentGoal?.dispatchPlan?.nodes.removeFirst()
            session.currentGoal?.dispatchPlan?.nodes[0].dependencyIDs = []
        }
        coordinator.synchronize(with: [session])
        let revised = coordinator.goals[0]
        #expect(!revised.isComplete && revised.isPaused)
        for task in revised.tasks where change == "parent" || task.id != ids[2] {
            #expect(task.deliveryRevisionID != nil && task.operatorAcceptedAt == nil)
            #expect(task.pendingOutcomeRevision == true)
            #expect(task.state == (task.dependencyIDs.isEmpty ? .queued : .blocked))
        }
        if change != "parent" { #expect(revised.tasks.last == independent) }
        if change == "commands" { #expect(revised.tasks[0].verificationCommands == ["ruby stronger.rb"]) }
        let reopened = AgentDispatchCoordinator(store: store)
        reopened.synchronize(with: [session])
        #expect(reopened.goals[0] == revised)
    }

    @Test("编辑使依赖链证据失效，同步及重载保留人工要求，取消与暂停不被绕过", arguments: [false, true])
    func editsSurviveProjectionAndInvalidateDependents(cancelled: Bool) throws {
        let suite = "outcome-revision-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentDispatchStore(defaults: defaults)
        let coordinator = AgentDispatchCoordinator(store: store)
        let ids = (0..<4).map { _ in UUID() }
        let nodes = ids.enumerated().map { index, id in
            AgentGoalDispatchPlan.Node(id: id, key: "N\(index)", title: "Node \(index)",
                dependencyIDs: index == 1 || index == 2 ? [ids[index - 1]] : [],
                primaryProfileID: nil, fallbackProfileIDs: [], acceptanceCriteria: ["Original \(index)"])
        }
        let session = AgentSession(title: "Project", workspaceRootPath: "/tmp/revision-fixture",
            presentationScope: .dispatchBoard, currentGoal: .init(statement: "Deliver project",
                checklist: [.init(text: "Accepted")], dispatchPlan: .init(nodes: nodes)))
        coordinator.synchronize(with: [session])
        coordinator.updateGoal(id: session.id) { goal in
            goal.isPaused = true
            for index in goal.tasks.indices {
                goal.tasks[index].state = cancelled && index == 1 ? .cancelled : .merged
                goal.tasks[index].runtimeSessionID = UUID()
                goal.tasks[index].operatorAcceptedAt = Date()
            }
        }
        let independent = try #require(coordinator.goals.first?.tasks.last)
        #expect(coordinator.updateTaskOutcome(goalID: session.id, taskID: ids[0],
            title: " Updated outcome ", acceptanceCriteria: [" New requirement "]))
        let revised = try #require(coordinator.goals.first)
        #expect(revised.tasks[0].state == .queued)
        #expect(revised.tasks[1].state == (cancelled ? .cancelled : .blocked))
        #expect(revised.tasks[2].state == .blocked)
        #expect(revised.tasks[3] == independent)
        #expect(revised.tasks.prefix(3).allSatisfy { $0.deliveryRevisionID != nil && $0.operatorAcceptedAt == nil })
        #expect(revised.isPaused && !revised.isComplete)
        #expect(revised.tasks[1].pendingOutcomeRevision == !cancelled)
        let epochs = revised.tasks.map(\.deliveryRevisionID)
        for _ in 0..<3 { coordinator.synchronize(with: [session]) }
        let reopened = AgentDispatchCoordinator(store: store)
        reopened.synchronize(with: [session])
        let restored = try #require(reopened.goals.first)
        #expect(restored.tasks[0].title == "Updated outcome")
        #expect(restored.tasks[0].acceptanceCriteria == ["New requirement"])
        #expect(restored.tasks.map(\.deliveryRevisionID) == epochs)
        #expect(restored.tasks.map(\.state) == revised.tasks.map(\.state))
        #expect(reopened.updateTaskOutcome(goalID: session.id, taskID: ids[0],
            title: "Updated outcome", acceptanceCriteria: ["New requirement"]))
        #expect(reopened.goals.first?.tasks.map(\.deliveryRevisionID) == epochs)
    }

    @Test("未启动项目编辑不授权自动执行，过期编辑计划不能覆盖新合同")
    func draftEditAndStaleRevision() throws {
        let suite = "outcome-draft-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AgentDispatchCoordinator(store: AgentDispatchStore(defaults: defaults))
        let id = UUID()
        let session = AgentSession(title: "Draft", workspaceRootPath: "/tmp/revision-fixture",
            presentationScope: .dispatchBoard, currentGoal: .init(statement: "Original goal",
                checklist: [.init(text: "Accepted")], dispatchPlan: .init(nodes: [
                    .init(id: id, key: "N", title: "Original", dependencyIDs: [], primaryProfileID: nil,
                        fallbackProfileIDs: [], acceptanceCriteria: ["Original check"])])))
        coordinator.synchronize(with: [session])
        let revision = try #require(coordinator.prepareOutcomeRevision(goalID: session.id,
            taskID: id, title: "New", acceptanceCriteria: ["New check"]))
        #expect(coordinator.applyOutcomeRevision(revision))
        #expect(coordinator.goals.first?.tasks.first?.pendingOutcomeRevision == false)
        #expect(!coordinator.applyOutcomeRevision(revision))
        #expect(!coordinator.updateTaskOutcome(goalID: session.id, taskID: id, title: " ", acceptanceCriteria: []))
    }
}
