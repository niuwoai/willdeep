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
        var startedAt: [Date] = []
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

        let wallStart = Date()
        let stopped = await appState.executeParallelSpawnBatch(
            &batch,
            runtime: runtime,
            configuration: appState.agentConfiguration,
            workspaceURL: nil,
            runtimeDescriptor: nil,
            workspaceLocation: nil
        ) { entry in
            startedAt.append(Date())
            try? await Task.sleep(nanoseconds: 300_000_000)
            entry.messageBuffer.message = AgentDeferredSpawnToolMessage(
                toolCallID: entry.call.externalID,
                payload: entry.call.externalID,
                source: .toolOutput,
                outcomeStatus: .succeeded,
                errorMessage: nil
            )
        }

        #expect(!stopped)
        #expect(Date().timeIntervalSince(wallStart) < 0.5)
        #expect(startedAt.count == 2)
        if startedAt.count == 2 {
            #expect(abs(startedAt[0].timeIntervalSince(startedAt[1])) < 0.1)
        }
        #expect(runtime.messages.map(\.toolCallID) == ["spawn-first", "spawn-second"])
        #expect(runtime.messages.map(\.content).allSatisfy { !$0.isEmpty })
    }
}
