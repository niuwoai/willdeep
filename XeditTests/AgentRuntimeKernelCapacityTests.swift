import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentRuntimeKernelCapacityTests {
    @Test("global capacity preserves a high-priority event across many runtimes")
    func globalCapacityAcrossRuntimes() {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let important = kernel.publish(event(runtimeID: UUID(), priority: .urgent))
        for _ in 0..<AgentKernelEventPolicy.maximumEventsAcrossKernel {
            kernel.publish(event(runtimeID: UUID(), priority: .background))
        }
        #expect(kernel.events.count == AgentKernelEventPolicy.maximumEventsAcrossKernel)
        #expect(kernel.events.contains { $0.id == important.id })
    }

    @Test("per-runtime pruning does not remove another runtime's pending event")
    func runtimeCapacityIsolation() {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let other = kernel.publish(event(runtimeID: UUID(), priority: .background))
        let busy = UUID()
        for _ in 0...AgentKernelEventPolicy.maximumEventsPerRuntime {
            kernel.publish(event(runtimeID: busy, priority: .normal))
        }
        #expect(kernel.events.count == AgentKernelEventPolicy.maximumEventsPerRuntime + 1)
        #expect(kernel.events.contains { $0.id == other.id })
    }

    @Test("settled history is reclaimed before equally prioritized pending work")
    func settledHistoryFirst() {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let runtime = UUID()
        let settled = kernel.publish(event(runtimeID: runtime, priority: .normal))
        kernel.acknowledge([settled.id])
        let pending = kernel.publish(event(runtimeID: runtime, priority: .normal))
        for _ in 1..<AgentKernelEventPolicy.maximumEventsPerRuntime {
            kernel.publish(event(runtimeID: runtime, priority: .normal))
        }
        #expect(kernel.events.count == AgentKernelEventPolicy.maximumEventsPerRuntime)
        #expect(!kernel.events.contains { $0.id == settled.id })
        #expect(kernel.events.contains { $0.id == pending.id })
    }

    private func event(runtimeID: UUID, priority: AgentKernelEventPriority) -> AgentKernelEvent {
        AgentKernelEvent(runtimeID: runtimeID, source: .system, kind: .hostNotice,
                         priority: priority, title: "capacity fixture", payload: "")
    }
}
