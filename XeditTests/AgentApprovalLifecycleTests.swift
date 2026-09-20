import Foundation
import Testing
@testable import WillDeep

@Suite("审批生命周期", .serialized)
@MainActor
struct AgentApprovalLifecycleTests {
    @Test("主聊天空闲时发送消息结束后台询问，旧确认不能影响下一条询问")
    func newMessageSupersedesIdleWorkerDecision() async throws {
        let app = AppState()
        app.skillRoutingCatalogForTesting = []
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let first = call(status: .awaitingConfirm)
        runtime.toolCalls = [first]
        let oldDecision = Task { await app.awaitToolDecision(for: runtime, forCallID: first.id) }
        try await waitForRegistration(first.id, runtime: runtime)
        runtime.isResponding = false
        runtime.input = "Leave that operation for now"
        app.sendAgentMessage()
        runtime.requestTask?.cancel()
        #expect(!approved(await oldDecision.value))
        #expect(runtime.toolCalls.first(where: { $0.id == first.id })?.status == .denied)
        #expect(runtime.toolDecisionWaiters[first.id] == nil)

        let second = call(status: .awaitingConfirm)
        runtime.toolCalls.append(second)
        let newDecision = Task { await app.awaitToolDecision(for: runtime, forCallID: second.id) }
        try await waitForRegistration(second.id, runtime: runtime)
        app.resolveAgentToolCallDecision(id: first.id, decision: .approved)
        #expect(runtime.toolDecisionWaiters[second.id] != nil)
        app.resolveAgentToolCallDecision(id: second.id, decision: .approved)
        #expect(approved(await newDecision.value))
        app.resolveAgentToolCallDecision(id: first.id, decision: .approved)
        #expect(runtime.toolCalls.first(where: { $0.id == first.id })?.status == .denied)
    }

    private func call(status: AgentToolCallStatus = .pendingApproval) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(), externalID: UUID().uuidString,
            toolName: "terminal_send_command", arguments: ["command": .string("pwd")],
            risk: .write, status: status, approvalSource: nil
        )
    }

    private func waitForRegistration(_ id: UUID, runtime: AgentRuntime) async throws {
        for _ in 0..<1_000 {
            if runtime.toolDecisionWaiters[id] != nil { return }
            await Task.yield()
        }
        try #require(runtime.toolDecisionWaiters[id] != nil)
    }

    private func approved(_ decision: AgentToolDecision) -> Bool {
        if case .approved = decision { return true }
        return false
    }

    @Test("原生 Worker 的特权工具在父会话等待确认并进入 Dock 计数")
    func nativeWorkerApprovalUsesParentQueueAndDockCount() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        defer { runtime.cancelToolDecisions(reason: "Test cleanup") }

        let approval = Task {
            try await app.resolveSubagentToolApproval(
                toolName: "call_mcp_tool",
                arguments: [
                    "server": .string("test-server"),
                    "tool": .string("mutate")
                ],
                risk: .danger,
                workerName: "通用工具",
                runtime: runtime,
                messageID: UUID(),
                rootDirectory: nil
            )
        }

        var recordID: UUID?
        for _ in 0..<1_000 {
            if let record = runtime.toolCalls.first(where: { $0.externalID.hasPrefix("subagent:") }) {
                recordID = record.id
                if runtime.toolDecisionWaiters[record.id] != nil { break }
            }
            await Task.yield()
        }
        let id = try #require(recordID)
        try await waitForRegistration(id, runtime: runtime)
        #expect(runtime.toolCalls.first(where: { $0.id == id })?.subagentWorkerName == "通用工具")
        #expect(AgentSessionApprovalBadgeLogic.pendingApprovalRequestCount(
            session: runtime.session,
            toolCallStatuses: runtime.toolCalls.map(\.status)
        ) == 1)

        app.approveAgentToolCall(id: id)
        #expect(try await approval.value)
        #expect(runtime.toolCalls.first(where: { $0.id == id })?.status == .succeeded)
        #expect(AgentSessionApprovalBadgeLogic.pendingApprovalRequestCount(
            session: runtime.session,
            toolCallStatuses: runtime.toolCalls.map(\.status)
        ) == 0)
    }

    @Test("原生 Worker 的只读命令不创建审批卡")
    func nativeWorkerReadSkipsApprovalQueue() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])

        let approved = try await app.resolveSubagentToolApproval(
            toolName: "run_command",
            arguments: ["command": .string("sed -n '1,70p' vendor/example.php")],
            risk: .read,
            workerName: "实现",
            runtime: runtime,
            messageID: UUID(),
            rootDirectory: nil
        )

        #expect(approved)
        #expect(runtime.toolCalls.isEmpty)
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("Worker 只把非只读命令送交父会话审核")
    func workerCommandReviewBoundary() {
        #expect(!AgentSubagentRunner.shouldRequestParentCommandReview(
            risk: .read,
            isStrictReadOnlyShellTrade: false
        ))
        #expect(AgentSubagentRunner.shouldRequestParentCommandReview(
            risk: .write,
            isStrictReadOnlyShellTrade: false
        ))
        #expect(AgentSubagentRunner.shouldRequestParentCommandReview(
            risk: .danger,
            isStrictReadOnlyShellTrade: false
        ))
        #expect(!AgentSubagentRunner.shouldRequestParentCommandReview(
            risk: .write,
            isStrictReadOnlyShellTrade: true
        ))
    }

    @Test("运维 Worker 的 run_command 地板是凭证档，其它工种维持原判")
    func opsRunnerCommandSandboxFloor() {
        let ops = AgentSubagentProfileCatalog.opsRunnerID
        let scout = AgentSubagentProfileCatalog.scoutID
        // ssh host "journalctl …" 因远程命令只读被分到 readOnlyNetwork；
        // 该档 seatbelt 拒读 ~/.ssh，ssh 必然认证失败，ops_runner 必须抬到凭证档。
        #expect(AgentSubagentRunner.runCommandSandboxMode(
            profileID: ops, classifiedMode: .readOnlyNetwork, isCommandApproved: false
        ) == .workspaceWriteNetworkCredentialed)
        #expect(AgentSubagentRunner.runCommandSandboxMode(
            profileID: ops, classifiedMode: .readOnly, isCommandApproved: false
        ) == .workspaceWriteNetworkCredentialed)
        // 未获准的修改类命令不因工种而升档——它压根到不了执行这一步，
        // 但这里仍不能让地板替审批做决定，保持与其它工种一致。
        #expect(AgentSubagentRunner.runCommandSandboxMode(
            profileID: ops, classifiedMode: .workspaceWrite, isCommandApproved: false
        ) == .workspaceWriteNetworkCredentialed)
        // 已获准且分类为 escalated 的命令不被地板压低。
        #expect(AgentSubagentRunner.runCommandSandboxMode(
            profileID: ops, classifiedMode: .escalated, isCommandApproved: true
        ) == .escalated)
        // 其它工种：原来的规则一字不变。
        #expect(AgentSubagentRunner.runCommandSandboxMode(
            profileID: scout, classifiedMode: .readOnlyNetwork, isCommandApproved: false
        ) == .readOnlyNetwork)
        #expect(AgentSubagentRunner.runCommandSandboxMode(
            profileID: scout, classifiedMode: .workspaceWrite, isCommandApproved: false
        ) == .readOnly)
        #expect(AgentSubagentRunner.runCommandSandboxMode(
            profileID: scout, classifiedMode: .workspaceWrite, isCommandApproved: true
        ) == .workspaceWrite)
    }

    @Test("完全访问自动批准原生 Worker 的普通高风险命令")
    func nativeWorkerFullAccessApprovesDangerWithoutPrompt() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        runtime.approvalMode = .fullAccess

        let approved = try await app.resolveSubagentToolApproval(
            toolName: "run_command",
            arguments: ["command": .string("rm -rf ./build")],
            risk: .danger,
            workerName: "实现",
            runtime: runtime,
            messageID: UUID(),
            rootDirectory: nil
        )

        #expect(approved)
        let record = try #require(runtime.toolCalls.last)
        #expect(record.approvalSource == .fullAccess)
        #expect(record.status == .succeeded)
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("委派执行器的只读命令不创建审批卡")
    func delegatedExecutorReadSkipsApprovalQueue() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let request = AgentDelegatedApprovalRequest(
            id: UUID().uuidString,
            executor: .codexCLI,
            kind: .command,
            command: "grep -n 'function items' vendor/example.php",
            cwd: nil,
            reason: nil,
            filePaths: [],
            requestedPermissions: nil,
            allowsSessionApproval: false
        )

        let decision = await app.resolveDelegatedExecutorApproval(
            request,
            runtime: runtime,
            messageID: UUID(),
            rootDirectory: nil
        )

        if case .accept = decision {
            // Expected.
        } else {
            Issue.record("只读命令应直接接受")
        }
        #expect(runtime.toolCalls.isEmpty)
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("完全访问自动批准委派执行器的普通高风险命令")
    func delegatedExecutorFullAccessApprovesDangerWithoutPrompt() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        runtime.approvalMode = .fullAccess
        let request = AgentDelegatedApprovalRequest(
            id: UUID().uuidString,
            executor: .codexCLI,
            kind: .command,
            command: "rm -rf ./build",
            cwd: nil,
            reason: nil,
            filePaths: [],
            requestedPermissions: nil,
            allowsSessionApproval: false
        )

        let decision = await app.resolveDelegatedExecutorApproval(
            request,
            runtime: runtime,
            messageID: UUID(),
            rootDirectory: nil
        )

        if case .accept = decision {
            // Expected.
        } else {
            Issue.record("完全访问应自动接受普通高风险命令")
        }
        let record = try #require(runtime.toolCalls.last)
        #expect(record.approvalSource == .fullAccess)
        #expect(record.status == .succeeded)
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("同会话两个审批互不覆盖，终端确认仅消费自己的等待且不能重复批准")
    func overlappingApprovals() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let first = call(), second = call()
        runtime.toolCalls = [first, second]
        defer { runtime.cancelToolDecisions(reason: "Test cleanup") }
        let one = Task { await app.awaitToolDecision(for: runtime, forCallID: first.id) }
        let two = Task { await app.awaitToolDecision(for: runtime, forCallID: second.id) }
        try await waitForRegistration(first.id, runtime: runtime)
        try await waitForRegistration(second.id, runtime: runtime)
        app.approveAgentToolCall(id: first.id)
        #expect(approved(await one.value))
        app.approveAgentToolCall(id: first.id)
        #expect(runtime.toolDecisionWaiters[second.id] != nil)
        #expect(runtime.toolCalls[1].status == .pendingApproval)
        app.approveAgentToolCall(id: second.id)
        #expect(approved(await two.value))
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("发送新消息时关闭全部审批与排队卡，不留下侧栏等待徽标")
    func closeAllApprovals() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let first = call(), second = call(status: .awaitingConfirm)
        var queued = call(status: .running)
        queued.arguments[AgentSerialToolApprovalQueue.argumentKey] = .bool(true)
        runtime.toolCalls = [first, second, queued]
        defer { runtime.cancelToolDecisions(reason: "Test cleanup") }
        let one = Task { await app.awaitToolDecision(for: runtime, forCallID: first.id) }
        let two = Task { await app.awaitToolDecision(for: runtime, forCallID: second.id) }
        try await waitForRegistration(first.id, runtime: runtime)
        try await waitForRegistration(second.id, runtime: runtime)
        #expect(app.closeBlockingAgentToolDecision(for: runtime, reason: "New message sent"))
        #expect(!approved(await one.value))
        #expect(!approved(await two.value))
        #expect(runtime.toolCalls.allSatisfy { $0.status == .denied })
        #expect(!runtime.toolCalls.contains(where: AgentSerialToolApprovalQueue.contains))
        #expect(!AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session, toolCallStatuses: runtime.toolCalls.map(\.status)
        ))
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("取消一个审批只清理该卡，不影响另一个等待")
    func cancellationIsScoped() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let first = call(), second = call()
        runtime.toolCalls = [first, second]
        defer { runtime.cancelToolDecisions(reason: "Test cleanup") }
        let one = Task { await app.awaitToolDecision(for: runtime, forCallID: first.id) }
        let two = Task { await app.awaitToolDecision(for: runtime, forCallID: second.id) }
        try await waitForRegistration(first.id, runtime: runtime)
        try await waitForRegistration(second.id, runtime: runtime)
        one.cancel()
        #expect(!approved(await one.value))
        #expect(runtime.toolCalls[0].status == .denied)
        #expect(runtime.toolDecisionWaiters[second.id] != nil)
        app.approveAgentToolCall(id: second.id)
        #expect(approved(await two.value))
    }

    @Test("注册前已取消也会结束待确认状态")
    func cancellationBeforeRegistration() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let pending = call()
        runtime.toolCalls = [pending]
        let task = Task { await app.awaitToolDecision(for: runtime, forCallID: pending.id) }
        task.cancel()
        #expect(!approved(await task.value))
        #expect(runtime.toolCalls[0].status == .denied)
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("过期取消令牌不能关闭新注册的审批")
    func staleCancellation() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let pending = call()
        runtime.toolCalls = [pending]
        defer { runtime.cancelToolDecisions(reason: "Test cleanup") }
        let task = Task { await app.awaitToolDecision(for: runtime, forCallID: pending.id) }
        try await waitForRegistration(pending.id, runtime: runtime)
        runtime.cancelToolDecision(id: pending.id, token: UUID(), reason: "Old task")
        #expect(runtime.toolDecisionWaiters[pending.id] != nil)
        app.approveAgentToolCall(id: pending.id)
        #expect(approved(await task.value))
    }

    @Test("重复注册不覆盖原来的审批")
    func duplicateRegistration() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let pending = call()
        runtime.toolCalls = [pending]
        defer { runtime.cancelToolDecisions(reason: "Test cleanup") }
        let task = Task { await app.awaitToolDecision(for: runtime, forCallID: pending.id) }
        try await waitForRegistration(pending.id, runtime: runtime)
        let originalToken = runtime.toolDecisionWaiters[pending.id]?.token
        #expect(!approved(await app.awaitToolDecision(for: runtime, forCallID: pending.id)))
        #expect(runtime.toolDecisionWaiters[pending.id]?.token == originalToken)
        app.approveAgentToolCall(id: pending.id)
        #expect(approved(await task.value))
    }

    @Test("缺失或已完成的卡片不被当作自动批准", arguments: [AgentToolCallStatus.succeeded, .failed, .denied, .running])
    func settledApprovalIsRejected(status: AgentToolCallStatus) async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let settled = call(status: status)
        runtime.toolCalls = [settled]
        #expect(!approved(await app.awaitToolDecision(for: runtime, forCallID: settled.id)))
        #expect(!approved(await app.awaitToolDecision(for: runtime, forCallID: UUID())))
        #expect(runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("插入用户消息后未决审批仍可交互，已完成旧工具不重新出现", arguments: [true, false])
    func approvalSurvivesNewMessage(isResponding: Bool) throws {
        let pending = call(), settled = call(status: .succeeded)
        let messages = [
            AgentMessage(role: .user, content: "Inspect workspace"),
            AgentMessage(id: settled.messageID, role: .assistant, content: "Done"),
            AgentMessage(id: pending.messageID, role: .assistant, content: "Confirm command"),
            AgentMessage(role: .user, content: "One more detail")
        ]
        let presentation = try #require(AgentActiveTurnToolCallPresentation.make(
            messages: messages, toolCalls: [settled, pending], isResponding: isResponding
        ))
        #expect(presentation.calls.map(\.id) == [pending.id])
        #expect(presentation.anchorMessageID == pending.messageID)
    }
}
