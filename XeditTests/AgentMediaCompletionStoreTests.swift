import Foundation
import Testing
@testable import WillDeep

@MainActor
struct AgentMediaCompletionStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-completion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func task() -> AgentMediaTask {
        AgentMediaTask(provider: .local, kind: .imageGeneration, title: "fixture",
            runtimeID: UUID(), ownerTurnID: UUID(), status: .succeeded)
    }

    @Test("终态、交接确认和处理完成独立持久，重载不丢正文")
    func phasesSurviveReload() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentMediaCompletionStore(directory: url)
        let task = task()
        let prepared = try store.prepare(task)
        #expect(!prepared.handedOff && !prepared.settled)
        try store.acknowledge(id: task.id)
        let reloaded = AgentMediaCompletionStore(directory: url)
        let handedOff = try #require(try reloaded.delivery(id: task.id))
        #expect(handedOff.handedOff && !handedOff.settled)
        #expect(try reloaded.outstanding().count == 1)
        try reloaded.settle(id: task.id)
        let settled = try #require(try store.delivery(id: task.id))
        #expect(settled.settled && settled.task == task)
        #expect(try store.outstanding().isEmpty)
    }

    @Test("轮询重试只保留首次终态，不重置已交接状态")
    func repeatedPrepareDoesNotReopenDelivery() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = AgentMediaCompletionStore(directory: url)
        let second = AgentMediaCompletionStore(directory: url)
        let original = task()
        _ = try first.prepare(original)
        try first.acknowledge(id: original.id)
        var later = original
        later.updatedAt = original.updatedAt.addingTimeInterval(20)
        let retry = try second.prepare(later)
        #expect(retry.task == original && retry.handedOff)
        later.ownerTurnID = UUID()
        #expect(throws: (any Error).self) { try second.prepare(later) }
        #expect(try first.delivery(id: original.id)?.task == original)
    }

    @Test("交接确认写盘失败时终态仍待交付")
    func failedAcknowledgementRetainsTerminal() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentMediaCompletionStore(directory: url)
        let task = task()
        _ = try store.prepare(task)
        let ackURL = url.appendingPathComponent("\(task.id.uuidString).ack")
        try FileManager.default.createDirectory(at: ackURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.acknowledge(id: task.id) }
        try FileManager.default.removeItem(at: ackURL)
        let pending = try #require(try store.delivery(id: task.id))
        #expect(!pending.handedOff && !pending.settled)
        try store.acknowledge(id: task.id)
        #expect(try store.delivery(id: task.id)?.handedOff == true)
    }

    @Test("损坏终态不能被新的结果覆盖")
    func corruptReceiptFailsClosed() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentMediaCompletionStore(directory: url)
        let task = task()
        _ = try store.prepare(task)
        let file = url.appendingPathComponent("\(task.id.uuidString).json")
        let corrupt = Data("not a receipt".utf8)
        try corrupt.write(to: file)
        #expect(throws: (any Error).self) { try store.prepare(task) }
        #expect(throws: (any Error).self) { try store.acknowledge(id: task.id) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test("待交付任务超过旧历史上限仍可重载和重放")
    func pendingTasksSurviveHistoryPressure() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("tasks.json")
        let registry = AgentMediaTaskRegistry(fileURL: file)
        let runtimeID = UUID()
        let count = 105
        for index in 0..<count {
            registry.create(provider: .local, kind: .imageGeneration,
                title: "fixture \(index)", runtimeID: runtimeID, ownerTurnID: UUID(), status: .succeeded)
        }
        let restored = AgentMediaTaskRegistry(fileURL: file)
        #expect(restored.tasks.count == count)
        #expect(try restored.completionStore.outstanding().count == count)
        var replayed: Set<UUID> = []
        restored.onTaskFinished = { replayed.insert($0.id) }
        restored.retryPendingCompletionNotifications()
        #expect(replayed.count == count)
        #expect(restored.pendingCompletionCount(forRuntime: runtimeID) == 0)
    }

    @Test("另一个窗口的旧列表不影响独立终态恢复")
    func completionSurvivesMissingHistoryEntry() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("tasks.json")
        let first = AgentMediaTaskRegistry(fileURL: file)
        let stale = AgentMediaTaskRegistry(fileURL: file)
        let completed = first.create(provider: .local, kind: .imageGeneration,
            title: "finished", runtimeID: UUID(), ownerTurnID: UUID(), status: .succeeded)
        stale.create(provider: .local, kind: .imageGeneration, title: "unrelated")
        let restored = AgentMediaTaskRegistry(fileURL: file)
        #expect(!restored.tasks.contains { $0.id == completed.id })
        var replayed: Set<UUID> = []
        restored.onTaskFinished = { replayed.insert($0.id) }
        restored.retryPendingCompletionNotifications()
        #expect(replayed == [completed.id])
    }
}
