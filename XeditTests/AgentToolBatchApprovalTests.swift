//
//  AgentToolBatchApprovalTests.swift
//  WillDeepTests
//
//  人工审批严格串行：后续调用只排队，当前 continuation 就绪后才展示操作卡。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Agent 工具串行审批")
@MainActor
struct AgentToolBatchApprovalTests {
    private func makeCall(
        status: AgentToolCallStatus = .pendingApproval,
        queued: Bool = false,
        toolName: String = "run_command",
        command: String = "git push origin main"
    ) -> AgentToolCall {
        var arguments: [String: AgentJSONValue] = ["command": .string(command)]
        if queued {
            arguments[AgentSerialToolApprovalQueue.argumentKey] = .bool(true)
        }
        return AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: toolName,
            arguments: arguments,
            risk: .write,
            status: status,
            approvalSource: nil
        )
    }

    private func isApproved(_ decision: AgentToolDecision) -> Bool {
        if case .approved = decision { return true }
        return false
    }

    @Test("后续人工审批以非交互排队行展示")
    func queuedCallPresentation() {
        let call = makeCall(status: .running, queued: true)
        let presentation = AgentToolActivityRowPresentation(call: call)

        #expect(AgentSerialToolApprovalQueue.contains(call))
        #expect(presentation.isQueuedForApproval)
        #expect(presentation.title == "排队等待确认：运行命令")
        #expect(!call.status.isBlockingForUserDecision)
    }

    @Test("非当前调用的提前点击被丢弃，不会进入悬空决定袋")
    func outOfOrderDecisionIsRejected() async throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])

        let first = makeCall()
        let second = makeCall(status: .running, queued: true, command: "git status")
        runtime.toolCalls = [first, second]

        let waiter = Task { @MainActor in
            await appState.awaitToolDecision(for: runtime, forCallID: first.id)
        }
        while runtime.toolDecisionWaiterCallID != first.id {
            await Task.yield()
        }

        appState.approveAgentToolCall(id: second.id)
        #expect(runtime.toolDecisionWaiterCallID == first.id)
        #expect(runtime.pendingToolDecisions.isEmpty)
        #expect(AgentSerialToolApprovalQueue.contains(runtime.toolCalls[1]))

        appState.approveAgentToolCall(id: first.id)
        #expect(isApproved(await waiter.value))
        #expect(runtime.toolCalls[0].status == .running)
    }

    @Test("上一条收口后下一条才接受确认")
    func approvalsAdvanceOneByOne() async throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])

        let first = makeCall()
        let second = makeCall(status: .running, queued: true, command: "git status")
        runtime.toolCalls = [first, second]

        let firstWaiter = Task { @MainActor in
            await appState.awaitToolDecision(for: runtime, forCallID: first.id)
        }
        while runtime.toolDecisionWaiterCallID != first.id { await Task.yield() }
        appState.approveAgentToolCall(id: first.id)
        #expect(isApproved(await firstWaiter.value))

        runtime.toolCalls[1].arguments.removeValue(
            forKey: AgentSerialToolApprovalQueue.argumentKey
        )
        runtime.toolCalls[1].status = .pendingApproval
        let secondWaiter = Task { @MainActor in
            await appState.awaitToolDecision(for: runtime, forCallID: second.id)
        }
        while runtime.toolDecisionWaiterCallID != second.id { await Task.yield() }
        appState.approveAgentToolCall(id: second.id)

        #expect(isApproved(await secondWaiter.value))
        #expect(runtime.toolDecisionWaiter == nil)
        #expect(runtime.toolDecisionWaiterCallID == nil)
        #expect(runtime.pendingToolDecisions.isEmpty)
    }

    @Test("Always-Allow 重评可把同族排队调用转成真正自动批准")
    func reevaluationAutoApprovesQueuedSibling() async throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])

        let queued = makeCall(status: .running, queued: true)
        runtime.toolCalls = [queued]
        let rule = try #require(appState.alwaysAllowedCommand(for: queued))
        appState.agentAlwaysAllowedCommands = [rule]

        let reevaluation = try #require(
            appState.reevaluatePendingAgentToolApprovals(for: runtime) { _ in true }
        )
        await reevaluation.value

        #expect(runtime.toolCalls[0].approvalSource == .alwaysAllowList)
        #expect(!AgentSerialToolApprovalQueue.contains(runtime.toolCalls[0]))
        #expect(runtime.toolCalls[0].status == .running)
        #expect(runtime.pendingToolDecisions.isEmpty)
    }
}
