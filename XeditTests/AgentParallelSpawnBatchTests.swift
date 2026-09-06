import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentParallelSpawnBatchTests {
    @Test("foreground read-only workers overlap and preserve tool-message order")
    func foregroundReadOnlyWorkersOverlap() async {
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession())
        let startBarrier = SpawnStartBarrier()
        var events: [String] = []
        var overlappingStarts: [Bool] = []
        let messageID = UUID()
        let first = AgentMessageToolCall(
            externalID: "spawn-first",
            toolName: "spawn_agent",
            argumentsJSON: #"{"prompt":"first"}"#
        )
        let second = AgentMessageToolCall(
            externalID: "spawn-second",
            toolName: "spawn_agent",
            argumentsJSON: #"{"prompt":"second"}"#
        )
        let firstRecord = AgentToolCall(
            messageID: messageID,
            externalID: first.externalID,
            toolName: first.toolName,
            arguments: ["prompt": .string("first")],
            risk: .read,
            status: .running
        )
        let secondRecord = AgentToolCall(
            messageID: messageID,
            externalID: second.externalID,
            toolName: second.toolName,
            arguments: ["prompt": .string("second")],
            risk: .read,
            status: .running
        )
        runtime.toolCalls = [firstRecord, secondRecord]
        var batch = [
            AppState.AgentPendingParallelSpawn(
                call: first,
                arguments: ["prompt": .string("first")],
                recordID: firstRecord.id,
                messageBuffer: AgentSpawnToolMessageBuffer()
            ),
            AppState.AgentPendingParallelSpawn(
                call: second,
                arguments: ["prompt": .string("second")],
                recordID: secondRecord.id,
                messageBuffer: AgentSpawnToolMessageBuffer()
            ),
        ]

        let stopped = await appState.executeParallelSpawnBatch(
            &batch,
            runtime: runtime,
            configuration: appState.agentConfiguration,
            workspaceURL: nil,
            runtimeDescriptor: nil,
            workspaceLocation: nil
        ) { entry in
            events.append("start:\(entry.call.externalID)")
            let overlapped = await startBarrier.waitForBoth()
            overlappingStarts.append(overlapped)
            events.append("finish:\(entry.call.externalID)")
            entry.messageBuffer.message = AgentDeferredSpawnToolMessage(
                toolCallID: entry.call.externalID,
                payload: entry.call.externalID,
                source: .toolOutput,
                outcomeStatus: .succeeded,
                errorMessage: nil
            )
        }

        #expect(!stopped)
        // Assert causal overlap, not this machine's scheduling latency. In a
        // serial implementation the first worker times out before the second
        // can start, so both the barrier result and event order reject it.
        #expect(overlappingStarts == [true, true])
        #expect(Set(events.prefix(2)) == ["start:spawn-first", "start:spawn-second"])
        #expect(events.count == 4)
        #expect(runtime.messages.map(\.toolCallID) == ["spawn-first", "spawn-second"])
        #expect(runtime.messages.map(\.content).allSatisfy { !$0.isEmpty })
    }

    @MainActor
    private final class SpawnStartBarrier {
        private var arrivals = 0
        private var waiter: CheckedContinuation<Bool, Never>?
        private var timeout: Task<Void, Never>?

        func waitForBoth() async -> Bool {
            arrivals += 1
            if arrivals == 2 {
                resolve(true)
                return true
            }
            return await withCheckedContinuation { continuation in
                waiter = continuation
                // Failure escape only; normal execution does not wait for a
                // timer. Do not leave a serial regression hanging the suite.
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    self?.resolve(false)
                }
            }
        }

        private func resolve(_ overlapped: Bool) {
            timeout?.cancel()
            timeout = nil
            let pending = waiter
            waiter = nil
            pending?.resume(returning: overlapped)
        }
    }
}
