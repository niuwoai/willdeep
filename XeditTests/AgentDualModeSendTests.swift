//
//  AgentDualModeSendTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@testable import WillDeep

/// ⌥↩ 排队、⌘↩ 立即发送。发送都挂在「正在回复」上，避免测试真的去请求一次 provider。
@Suite("Dual mode send", .serialized)
struct AgentDualModeSendTests {
    private func makeRuntime() -> (AppState, AgentRuntime, UUID) {
        let appState = AppState()
        appState.skillRoutingCatalogForTesting = []
        let session = appState.startNewAgentSession()
        let runtime = appState.activeRuntime!
        return (appState, runtime, session.id)
    }

    @Test @MainActor
    func optionReturnQueuesEvenWhenIdle() {
        let (appState, runtime, sessionID) = makeRuntime()
        defer { AgentSessionStore.delete(id: sessionID) }
        runtime.input = "稍后再说"

        appState.sendAgentMessage(delivery: .enqueue)

        #expect(runtime.queuedMessages.map(\.text) == ["稍后再说"])
        #expect(!runtime.isResponding)
        #expect(runtime.input.isEmpty)
    }

    @Test @MainActor
    func commandReturnWhileBusyMovesTheNewMessageToTheFrontAndCancels() {
        let (appState, runtime, sessionID) = makeRuntime()
        defer { AgentSessionStore.delete(id: sessionID) }
        runtime.queuedMessages = [
            AgentQueuedMessage(text: "先排的"),
            AgentQueuedMessage(text: "后排的"),
        ]
        runtime.isResponding = true
        let task = Task {}
        runtime.requestTask = task
        defer {
            runtime.isResponding = false
            runtime.requestTask = nil
        }
        runtime.input = "现在就发"

        appState.sendAgentMessage(delivery: .sendNow)

        #expect(runtime.queuedMessages.map(\.text) == ["现在就发", "先排的", "后排的"])
        #expect(task.isCancelled)
        #expect(runtime.shouldConsumeQueueAfterStop)
    }

    @Test @MainActor
    func plainReturnWhileBusyStillAppends() {
        let (appState, runtime, sessionID) = makeRuntime()
        defer { AgentSessionStore.delete(id: sessionID) }
        runtime.queuedMessages = [AgentQueuedMessage(text: "先排的")]
        runtime.isResponding = true
        defer { runtime.isResponding = false }
        runtime.input = "跟在后面"

        appState.sendAgentMessage()

        #expect(runtime.queuedMessages.map(\.text) == ["先排的", "跟在后面"])
        #expect(!runtime.shouldConsumeQueueAfterStop)
    }

    @Test @MainActor
    func commandReturnWhileIdleSendsImmediately() {
        let (appState, runtime, sessionID) = makeRuntime()
        defer { AgentSessionStore.delete(id: sessionID) }
        runtime.input = "没人在跑，直接发"

        appState.sendAgentMessage(delivery: .sendNow)
        defer { appState.stopAgentResponse(for: runtime) }

        // 没有在跑的回合，立即发送和裸回车一样走派发：消息进 transcript，回合
        // 进入回复中，队列是空的。
        #expect(runtime.queuedMessages.isEmpty)
        #expect(runtime.input.isEmpty)
        #expect(runtime.isResponding)
        #expect(runtime.messages.contains { $0.isOperatorInput && $0.content == "没人在跑，直接发" })
    }
}
