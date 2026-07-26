//
//  AgentToolBatchApprovalTests.swift
//  WillDeepTests
//
//  同回合预亮卡 + 全部允许 批量放行的资格过滤与决策派发。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Agent 工具批量放行")
@MainActor
struct AgentToolBatchApprovalTests {

    private func makeCall(
        status: AgentToolCallStatus = .pendingApproval,
        risk: AgentToolRisk = .write,
        toolName: String = "run_command",
        arguments: [String: AgentJSONValue] = ["command": .string("git push origin main")]
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: toolName,
            arguments: arguments,
            risk: risk,
            status: status,
            approvalSource: nil
        )
    }

    private func isApproved(_ decision: AgentToolDecision?) -> Bool {
        if case .approved? = decision { return true }
        return false
    }

    @Test("资格过滤：只覆盖普通 write 审批卡，danger/升权/问答均排除")
    func eligibilityFilter() {
        #expect(AppState.isBatchApprovableAgentToolCall(makeCall()))
        #expect(!AppState.isBatchApprovableAgentToolCall(
            makeCall(status: .awaitingConfirm, risk: .danger)
        ))
        #expect(!AppState.isBatchApprovableAgentToolCall(
            makeCall(status: .awaitingUserAnswer, risk: .userInput, toolName: "ask_user")
        ))
        #expect(!AppState.isBatchApprovableAgentToolCall(makeCall(status: .running)))
        #expect(!AppState.isBatchApprovableAgentToolCall(makeCall(status: .succeeded)))
        #expect(!AppState.isBatchApprovableAgentToolCall(makeCall(status: .denied)))

        // 沙箱升权重试卡与普通审批卡同为 pendingApproval，必须靠参数标记排除。
        var escalationArguments: [String: AgentJSONValue] = ["command": .string("swift build")]
        escalationArguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(true)
        #expect(!AppState.isBatchApprovableAgentToolCall(
            makeCall(arguments: escalationArguments)
        ))
        // 升权流程收尾会把标记落回 false，此时按普通卡处理。
        escalationArguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
        #expect(AppState.isBatchApprovableAgentToolCall(
            makeCall(arguments: escalationArguments)
        ))
    }

    @Test("全部允许：提前决策入 pendingToolDecisions，danger 卡与升权卡不动")
    func batchApproveParksDecisions() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)

        let first = makeCall()
        let second = makeCall(toolName: "create_file", arguments: ["path": .string("a.txt")])
        let danger = makeCall(status: .awaitingConfirm, risk: .danger)
        var escalationArguments: [String: AgentJSONValue] = ["command": .string("swift build")]
        escalationArguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(true)
        let escalation = makeCall(arguments: escalationArguments)
        runtime.toolCalls = [first, second, danger, escalation]

        let ids = appState.batchApprovableAgentToolCallIDs(among: runtime.toolCalls)
        #expect(ids == [first.id, second.id])

        appState.approveAgentToolCalls(ids: ids)

        #expect(isApproved(runtime.pendingToolDecisions[first.id]))
        #expect(isApproved(runtime.pendingToolDecisions[second.id]))
        #expect(runtime.pendingToolDecisions[danger.id] == nil)
        #expect(runtime.pendingToolDecisions[escalation.id] == nil)
        // 没有执行循环在等待时，卡片状态保持 pendingApproval（UI 显示「已提交决定」），
        // 由 awaitToolDecision 快路径按执行顺序消费。
        #expect(runtime.toolCalls[0].status == .pendingApproval)
        #expect(runtime.toolCalls[2].status == .awaitingConfirm)

        // 已提交决策的卡不再计入下一次批量资格。
        #expect(appState.batchApprovableAgentToolCallIDs(among: runtime.toolCalls).isEmpty)
    }

    @Test("全部允许会立即唤醒正在等待的调用，其余按序消费")
    func batchApproveResumesActiveWaiter() async throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)

        let first = makeCall()
        let second = makeCall()
        runtime.toolCalls = [first, second]

        let waiterTask = Task { @MainActor in
            await appState.awaitToolDecision(for: runtime, forCallID: first.id)
        }
        var spins = 0
        while runtime.toolDecisionWaiter == nil, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        #expect(runtime.toolDecisionWaiter != nil)

        appState.approveAgentToolCalls(
            ids: appState.batchApprovableAgentToolCallIDs(among: runtime.toolCalls)
        )

        let decision = await waiterTask.value
        #expect(isApproved(decision))
        // 被等待的调用立刻转入 running；后一个的批准停在决策袋里等它的回合。
        #expect(runtime.toolCalls[0].status == .running)
        #expect(runtime.toolCalls[1].status == .pendingApproval)
        #expect(isApproved(runtime.pendingToolDecisions[second.id]))
    }

    @Test("按新增 Always-Allow 规则重评：同族待批卡全部放行")
    func reevaluationReleasesPinnedSiblings() async throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)

        let first = makeCall()
        let second = makeCall()
        let danger = makeCall(status: .awaitingConfirm, risk: .danger)
        runtime.toolCalls = [first, second, danger]

        // 直接内存注入规则，避免单测写入用户的持久化 Always-Allow 列表。
        let rule = try #require(appState.alwaysAllowedCommand(for: first))
        appState.agentAlwaysAllowedCommands = [rule]

        let task = try #require(
            appState.reevaluatePendingAgentToolApprovals(for: runtime) { call in
                appState.isAgentToolCallAlwaysAllowed(
                    toolName: call.toolName,
                    arguments: call.arguments,
                    risk: call.risk
                )
            }
        )
        await task.value

        #expect(isApproved(runtime.pendingToolDecisions[first.id]))
        #expect(isApproved(runtime.pendingToolDecisions[second.id]))
        #expect(runtime.toolCalls[0].approvalSource == .alwaysAllowList)
        #expect(runtime.toolCalls[1].approvalSource == .alwaysAllowList)
        #expect(runtime.pendingToolDecisions[danger.id] == nil)
        #expect(runtime.toolCalls[2].status == .awaitingConfirm)
    }
}
