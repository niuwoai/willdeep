import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite(.serialized)
struct AgentKernelDurableRetentionTests {
    @Test("host resolution preserves user attention and cannot be overwritten by a stale model ACK")
    func resolvedAtSourceIsNotModelConsumption() {
        let runtimeID = UUID()
        defer { cleanup(runtimeID) }
        let kernel = AgentRuntimeKernel(loadPersisted: false)
        let original = kernel.publish(AgentKernelEvent(runtimeID: runtimeID, source: .backgroundJob,
            kind: .backgroundJobFailed, title: "fixture", payload: "result", requiresUserAction: true))
        #expect(kernel.confirmEventPersistenceForHandoff(original))
        let lease = UUID()
        _ = kernel.consumePendingModelEvents(for: runtimeID, leaseID: lease)
        kernel.resolveModelDeliveriesAtSource([original.id])
        kernel.acknowledge([original.id], leaseID: lease)
        kernel.acknowledge([original.id])
        kernel.releaseModelDeliveryLeases(for: runtimeID, leaseID: lease)
        #expect(AgentKernelEventStore.flushPendingWrites(for: [runtimeID]).isEmpty)
        let restored = AgentRuntimeKernel()
        let event = restored.events.first { $0.id == original.id }
        #expect(event?.resolutionActor == .host && event?.resolutionOutcome == .resolvedAtSource)
        #expect(event?.isAwaitingUserAction == true)
        #expect(event?.hasOutstandingDurableDelivery == false)
        #expect(event?.acknowledgedAt == nil)
        #expect(restored.consumePendingModelEvents(for: runtimeID).isEmpty)
    }

    @Test("durable pending and leased results survive pressure and kernel reload")
    func retainsPendingAndLeased() {
        for leased in [false, true] {
            let runtimeID = UUID()
            defer { cleanup(runtimeID) }
            let kernel = AgentRuntimeKernel(loadPersisted: false)
            let original = kernel.publish(event(runtimeID, key: "original"))
            #expect(kernel.confirmEventPersistenceForHandoff(original))
            if leased { _ = kernel.consumePendingModelEvents(for: runtimeID, limit: 1, leaseID: UUID()) }
            flood(kernel, runtimeID)
            #expect(kernel.events.contains { $0.id == original.id && $0.hasOutstandingDurableDelivery })
            #expect(AgentKernelEventStore.flushPendingWrites(for: [runtimeID]).isEmpty)
            let restored = AgentRuntimeKernel()
            #expect(restored.events.contains { $0.id == original.id && $0.isPendingForModel })
        }
    }

    @Test("capacity denial retains old deliveries and correct consumption makes room")
    func capacityBackpressure() {
        let runtimeID = UUID()
        defer { cleanup(runtimeID) }
        let kernel = AgentRuntimeKernel(loadPersisted: false)
        var retained: [UUID] = []
        for index in 0..<AgentKernelEventPolicy.maximumEventsPerRuntime {
            let published = kernel.publish(event(runtimeID, key: "held-\(index)"))
            #expect(kernel.confirmEventPersistenceForHandoff(published))
            retained.append(published.id)
        }
        #expect(!kernel.canAdmitDurableDelivery(runtimeID: runtimeID, dedupeKey: "new"))
        let rejected = kernel.publish(event(runtimeID, key: "new"))
        #expect(!kernel.confirmEventPersistenceForHandoff(rejected))
        #expect(Set(kernel.events.map(\.id)) == Set(retained))
        let lease = UUID()
        let consumed = kernel.consumePendingModelEvents(for: runtimeID, limit: 1, leaseID: lease)
        kernel.acknowledge(consumed.map(\.id), leaseID: UUID())
        #expect(!kernel.canAdmitDurableDelivery(runtimeID: runtimeID, dedupeKey: "new"))
        kernel.acknowledge(consumed.map(\.id), leaseID: lease)
        #expect(kernel.canAdmitDurableDelivery(runtimeID: runtimeID, dedupeKey: "new"))
        let accepted = kernel.publish(event(runtimeID, key: "new"))
        #expect(kernel.confirmEventPersistenceForHandoff(accepted))
        #expect(kernel.events.count == AgentKernelEventPolicy.maximumEventsPerRuntime)
    }

    @Test("producer cannot forge durable admission or overwrite an outstanding result")
    func producerCannotForgeOwnership() {
        let runtimeID = UUID()
        defer { cleanup(runtimeID) }
        let kernel = AgentRuntimeKernel(loadPersisted: false)
        var forged = event(runtimeID, key: "forged")
        forged.durableModelDeliveryRequired = true
        #expect(!kernel.publish(forged).hasOutstandingDurableDelivery)
        let original = kernel.publish(event(runtimeID, key: "original"))
        #expect(kernel.confirmEventPersistenceForHandoff(original))
        var replacement = event(runtimeID, key: "original")
        replacement.payload = "replacement"
        let duplicate = kernel.publish(replacement)
        #expect(duplicate.id == original.id)
        #expect(duplicate.payload == original.payload)
        #expect(duplicate.hasOutstandingDurableDelivery)
    }

    private func event(_ runtimeID: UUID, key: String) -> AgentKernelEvent {
        AgentKernelEvent(runtimeID: runtimeID, source: .backgroundJob,
                         kind: .backgroundJobCompleted, title: "fixture", payload: "result",
                         dedupeKey: key, dedupeScope: .journal)
    }

    private func flood(_ kernel: AgentRuntimeKernel, _ runtimeID: UUID) {
        for index in 0...AgentKernelEventPolicy.maximumEventsPerRuntime {
            kernel.publish(event(runtimeID, key: "flood-\(index)"))
        }
    }

    private func cleanup(_ runtimeID: UUID) {
        _ = AgentKernelEventStore.flushPendingWrites(for: [runtimeID])
        AgentKernelEventStore.deleteAsync(runtimeID: runtimeID)
        _ = AgentKernelEventStore.flushPendingWrites(for: [runtimeID])
    }
}
