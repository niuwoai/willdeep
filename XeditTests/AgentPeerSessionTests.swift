//
//  AgentPeerSessionTests.swift
//  WillDeepTests
//
//  会话互通：list_workspace_sessions 的「在做什么」字段，与 send_session_message
//  的目标解析、限长、限流和提示格式。设计见 docs/SESSION_COLLABORATION_AND_HANDOFF.md。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Peer sessions")
nonisolated struct AgentPeerSessionTests {
    private static func snapshot(
        id: UUID = UUID(),
        title: String = "会话",
        isArchived: Bool = false,
        currentStepText: String? = nil,
        lastUserRequest: String? = nil
    ) -> AgentWorkspaceSessionSnapshot {
        AgentWorkspaceSessionSnapshot(
            id: id,
            title: title,
            workspaceRootPath: "/tmp/Project",
            workspaceDisplayName: "Project",
            presentationScope: .workspace,
            isActive: false,
            isPinned: false,
            isArchived: isArchived,
            isResponding: true,
            isAwaitingProviderSlot: false,
            queuedMessageCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            interactionMode: .normal,
            approvalMode: .smart,
            executionAgent: .willDeep,
            titleIsUserSet: false,
            goalStatement: nil,
            goalCompletedItemCount: 0,
            goalTotalItemCount: 0,
            goalIsComplete: false,
            goalPlanningPhase: nil,
            dispatchParentProjectID: nil,
            dispatchTaskID: nil,
            isDispatchProject: false,
            isDispatchPaused: false,
            planCompletedStepCount: 1,
            planTotalStepCount: 3,
            currentStepText: currentStepText,
            lastUserRequest: lastUserRequest
        )
    }

    @Test("活动摘要取进行中的步骤和最后一条人打的请求")
    func activitySummary() {
        let plan = AgentPlan(status: .executing, steps: [
            .init(text: "读代码", status: .done),
            .init(text: "改登录", status: .inProgress),
            .init(text: "跑测试", status: .pending)
        ])
        var hostNote = AgentMessage(role: .user, content: "计划已批准，开始执行")
        hostNote.source = .hostInstruction
        let messages = [
            AgentMessage(role: .user, content: "修一下登录\n  超时的问题"),
            AgentMessage(role: .assistant, content: "好的"),
            hostNote
        ]
        let activity = AgentPeerSessionActivity(plan: plan, messages: messages)
        #expect(activity.planCompletedStepCount == 1)
        #expect(activity.planTotalStepCount == 3)
        #expect(activity.currentStepText == "改登录")
        // 宿主指令不算用户请求；换行被压平。
        #expect(activity.lastUserRequest == "修一下登录 超时的问题")
    }

    @Test("没有进行中的步骤时退到第一个待办；长请求截断")
    func activityFallbacks() {
        let plan = AgentPlan(status: .executing, steps: [.init(text: "a", status: .done), .init(text: "b")])
        let long = String(repeating: "长", count: 400)
        let activity = AgentPeerSessionActivity(plan: plan, messages: [AgentMessage(role: .user, content: long)])
        #expect(activity.currentStepText == "b")
        #expect(activity.lastUserRequest?.count == AgentPeerSessionActivity.requestExcerptLimit + 1)
        #expect(AgentPeerSessionActivity(plan: nil, messages: []).lastUserRequest == nil)
    }

    @Test("目标解析：完整 id、≥8 位前缀、自己、归档、歧义")
    func resolveTarget() {
        let sender = UUID()
        let peer = Self.snapshot(title: "同伴")
        let archived = Self.snapshot(isArchived: true)
        let me = Self.snapshot(id: sender)
        let candidates = [peer, archived, me]

        #expect((try? AgentPeerMessageTool.resolveTarget(reference: peer.id.uuidString, senderID: sender, candidates: candidates).get())?.id == peer.id)
        let prefix = String(peer.id.uuidString.prefix(8)).lowercased()
        #expect((try? AgentPeerMessageTool.resolveTarget(reference: prefix, senderID: sender, candidates: candidates).get())?.id == peer.id)
        #expect(AgentPeerMessageTool.resolveTarget(reference: String(prefix.prefix(4)), senderID: sender, candidates: candidates) == .failure(.targetNotFound(String(prefix.prefix(4)))))
        #expect(AgentPeerMessageTool.resolveTarget(reference: sender.uuidString, senderID: sender, candidates: candidates) == .failure(.targetIsSelf))
        #expect(AgentPeerMessageTool.resolveTarget(reference: archived.id.uuidString, senderID: sender, candidates: candidates) == .failure(.targetArchived))
        #expect(AgentPeerMessageTool.resolveTarget(reference: " ", senderID: sender, candidates: candidates) == .failure(.missingTarget))

        let twinA = Self.snapshot(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
        let twinB = Self.snapshot(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!)
        #expect(AgentPeerMessageTool.resolveTarget(reference: "aaaaaaaa", senderID: sender, candidates: [twinA, twinB]) == .failure(.ambiguousTarget("aaaaaaaa")))
    }

    @Test("消息超长直接拒绝，不截断")
    func messageLimit() {
        #expect(AgentPeerMessageTool.validateMessage("  \n") == .failure(.emptyMessage))
        let exact = String(repeating: "字", count: AgentPeerMessageTool.maximumCharacters)
        #expect(AgentPeerMessageTool.validateMessage(exact) == .success(exact))
        #expect(AgentPeerMessageTool.validateMessage(exact + "多") == .failure(.messageTooLong(AgentPeerMessageTool.maximumCharacters + 1)))
    }

    @Test("同一对会话十分钟内最多 5 条，窗口过后恢复，反方向独立计数")
    func throttle() {
        var throttle = AgentPeerMessageThrottle()
        let a = UUID(), b = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        for offset in 0..<AgentPeerMessageThrottle.maximumPerWindow {
            let admitted = throttle.admit(sender: a, receiver: b, now: start.addingTimeInterval(Double(offset)))
            #expect(admitted)
        }
        let overLimit = throttle.admit(sender: a, receiver: b, now: start.addingTimeInterval(10))
        let reverse = throttle.admit(sender: b, receiver: a, now: start.addingTimeInterval(10))
        let afterWindow = throttle.admit(sender: a, receiver: b, now: start.addingTimeInterval(AgentPeerMessageThrottle.window + 1))
        #expect(!overLimit)
        #expect(reverse)
        #expect(afterWindow)
    }

    @Test("提示里标明来源、不可越权，标题里的引号被中和")
    func noticeFormat() {
        let sender = UUID()
        let notice = AgentPeerMessageTool.notice(senderID: sender, senderTitle: "修\"登录\"\n问题", message: "我在改 Login.swift，先别动")
        #expect(notice.contains("from_title=\"修'登录' 问题\""))
        #expect(notice.contains("我在改 Login.swift，先别动"))
        #expect(notice.contains("not the user"))
        #expect(notice.contains("session_id: \"\(sender.uuidString)\""))
    }

    @Test("send_session_message 在会话自动化工具包里，不占核心工具位")
    @MainActor
    func toolRegistration() {
        #expect(AgentToolRegistry.descriptor(for: AgentPeerMessageTool.name) != nil)
        #expect(!AgentToolPackCatalog.coreToolNames.contains(AgentPeerMessageTool.name))
        #expect(AgentToolPackCatalog.packID(for: AgentPeerMessageTool.name) == .sessionAutomation)
    }

    @Test("list_workspace_sessions 输出当前步骤、计划进度和最近请求")
    @MainActor
    func listIncludesActivity() async throws {
        let peer = Self.snapshot(title: "同伴", currentStepText: "改登录", lastUserRequest: "修一下登录")
        let context = AgentToolContext(rootDirectory: nil, workspaceSessionsSnapshotProvider: { [peer] })
        let result = try await AgentToolRunner.run(name: "list_workspace_sessions", arguments: [:], context: context)
        #expect(result.payload.contains("plan=1/3"))
        #expect(result.payload.contains("current_step=改登录"))
        #expect(result.payload.contains("last_request=修一下登录"))
        #expect(result.payload.contains("\"current_step\":\"改登录\""))
        #expect(result.payload.contains("\"plan_total_step_count\":3"))
    }
}
