import Foundation
import Testing
@testable import WillDeep

@MainActor
struct AgentMediaOwnershipTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("媒体完成及磁盘重载保留原轮次")
    func ownerSurvivesCompletionAndReload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.json")
        let runtimeID = UUID(), turnID = UUID()
        let registry = AgentMediaTaskRegistry(fileURL: file)
        let task = registry.create(provider: .local, kind: .imageGeneration,
            title: "fixture", runtimeID: runtimeID, ownerTurnID: turnID)
        registry.update(id: task.id, status: .succeeded)
        let restored = try #require(AgentMediaTaskRegistry(fileURL: file).tasks.first)
        #expect(restored.ownerTurnID == turnID)
        #expect(restored.runtimeID == runtimeID)
        #expect(restored.status == .succeeded)
    }

    @Test("旧任务缺少轮次字段时保持未知，不绑定当前轮次")
    func legacyTaskHasNoInferredOwner() throws {
        let task = AgentMediaTask(provider: .local, kind: .imageGeneration,
            title: "legacy", runtimeID: UUID())
        let data = try JSONEncoder().encode(task)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ownerTurnID"] == nil)
        let restored = try JSONDecoder().decode(AgentMediaTask.self, from: data)
        #expect(restored.ownerTurnID == nil)
    }

    @Test("持久媒体通知不能通过兼容队列绕过交接")
    func durableCompletionCannotUseLegacyQueue() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = AgentMediaTaskRegistry(fileURL: directory.appendingPathComponent("tasks.json"))
        let runtimeID = UUID()
        let task = registry.create(provider: .local, kind: .imageGeneration,
            title: "fixture", runtimeID: runtimeID, ownerTurnID: UUID())
        registry.update(id: task.id, status: .succeeded)
        #expect(registry.pendingCompletionCount(forRuntime: runtimeID) == 0)
        #expect(registry.hasOutstandingCompletion(forRuntime: runtimeID))
        registry.markCompletionSurfaced(id: task.id, forRuntime: runtimeID)
        #expect(registry.consumePendingCompletions(forRuntime: runtimeID).isEmpty)
        #expect(registry.tasks.contains { $0.id == task.id && $0.status == .succeeded })
    }

    @Test("停止标记跨注册表重载，其他轮次不受影响")
    func stoppedOwnerSurvivesRegistryReload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtimeID = UUID(), turnID = UUID()
        let registry = AgentJobRegistry(daemonStartDirectory: directory)
        #expect(registry.revokeTurn(runtimeID: runtimeID, turnID: turnID))
        let restored = AgentJobRegistry(daemonStartDirectory: directory)
        #expect(try restored.completionOwnerWasStopped(runtimeID: runtimeID, turnID: turnID))
        #expect(try !restored.completionOwnerWasStopped(runtimeID: runtimeID, turnID: UUID()))
        #expect(try !restored.completionOwnerWasStopped(runtimeID: UUID(), turnID: turnID))
    }
}
