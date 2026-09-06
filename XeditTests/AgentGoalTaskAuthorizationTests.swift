import Foundation
import Testing
@testable import WillDeep

@Suite("目标级验证授权", .serialized)
@MainActor
struct AgentGoalTaskAuthorizationTests {
    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let root: URL
        let defaults: UserDefaults
        let suite: String
        var arguments: [String: AgentJSONValue] {
            ["command": .string("ruby verify_test.rb"), "run_in_background": .bool(false)]
        }
        func cleanup() throws {
            runtime.cancelToolDecisions(reason: "Test cleanup")
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
        }
        func matches(arguments: [String: AgentJSONValue]? = nil) async -> Bool {
            await app.goalTaskAuthorizationMatches(runtime: runtime, toolName: "run_command",
                arguments: arguments ?? self.arguments, risk: .write, root: root)
        }
        func context() -> AgentToolContext {
            AgentToolContext(rootDirectory: root,
                taskAuthorizationCheck: app.goalTaskAuthorizationExecutionCheck(runtime: runtime, source: .taskGrant, root: root),
                localCommandEnvironment: AgentToolRunner.localCommandEnvironment(settings: app.editorTerminalSettings),
                sandboxMode: .workspaceWrite)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-grant-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("puts 'verified'\n".utf8).write(to: root.appendingPathComponent("verify_test.rb"))
        let suite = "goal-grant-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults, loadSessionCatalog: false)
        // Other suites persist projects containing the process-wide temporary
        // parent. This fixture is a single-root task, not a child of those
        // unrelated multi-root projects. This assignment is instance-local.
        app.agentProjects = []
        let session = app.startNewAgentSession(inWorkspaceAt: root.path)
        let runtime = try #require(app.runtime(for: session.id))
        runtime.executionAgent = .willDeep
        runtime.interactionMode = .goal
        runtime.approvalMode = .smart
        runtime.currentGoal = .init(statement: "验证这个工作区", checklist: [.init(text: "测试通过")])
        runtime.currentPlan = .init(status: .executing)
        try #require(app.agentWorkspaceRoots(for: runtime.session).count == 1)
        return .init(app: app, runtime: runtime, root: root, defaults: defaults, suite: suite)
    }

    @Test("多根项目及外部执行器不能取得原生单根验证授权")
    func multiRootProjectAndExternalExecutorRemainGated() throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let call = pending(f)
        #expect(f.app.canOfferGoalTaskAuthorization(id: call.id))
        let project = AgentProject(displayName: "Fixture project", folderPaths: [
            f.root.path, f.root.appendingPathComponent("additional-root").path
        ])
        f.app.agentProjects = [project]
        f.runtime.session.projectID = project.id
        #expect(f.app.agentWorkspaceRoots(for: f.runtime.session).count == 2)
        #expect(!f.app.canOfferGoalTaskAuthorization(id: call.id))
        f.runtime.session.projectID = nil
        #expect(f.app.canOfferGoalTaskAuthorization(id: call.id))
        f.runtime.executionAgent = .codexCLI
        #expect(!f.app.canOfferGoalTaskAuthorization(id: call.id))
    }

    private func pending(_ f: Fixture, arguments: [String: AgentJSONValue]? = nil, externalID: String? = nil) -> AgentToolCall {
        var display = arguments ?? f.arguments
        let decision = AgentSandboxPolicy.decision(toolName: "run_command", arguments: display, rootDirectory: f.root)
        display["_sandbox"] = .string(decision.mode.rawValue)
        display["_approval_reason"] = .string(decision.reason)
        let call = AgentToolCall(messageID: UUID(), externalID: externalID ?? UUID().uuidString,
            toolName: "run_command", arguments: display, risk: .write, status: .pendingApproval)
        f.runtime.toolCalls.append(call)
        return call
    }

    private func waiter(_ f: Fixture, call: AgentToolCall) async throws -> Task<AgentToolDecision, Never> {
        let task = Task { await f.app.awaitToolDecision(for: f.runtime, forCallID: call.id) }
        for _ in 0..<1_000 {
            if f.runtime.toolDecisionWaiters[call.id] != nil { return task }
            await Task.yield()
        }
        task.cancel()
        throw AgentToolError.invalidArgument("Approval waiter did not register")
    }

    private func grant(_ f: Fixture) async throws {
        let call = pending(f)
        let decision = try await waiter(f, call: call)
        try #require(f.app.canOfferGoalTaskAuthorization(id: call.id))
        await f.app.allowAgentVerifierForGoal(id: call.id)
        try #require(f.runtime.currentGoal?.taskAuthorizations?.count == 1)
        if case .approved = await decision.value {} else { Issue.record("Explicit task grant should approve its own waiter") }
    }

    @Test("明确授权才生成权限；不污染全局白名单，可往返持久化")
    func explicitGrantAndPersistence() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        #expect(await !f.matches())
        let prior = f.app.agentAlwaysAllowedCommands
        try await grant(f)
        #expect(await f.matches())
        #expect(f.app.agentAlwaysAllowedCommands == prior)
        let goal = try #require(f.runtime.currentGoal)
        #expect(try JSONDecoder().decode(AgentGoal.self, from: JSONEncoder().encode(goal)) == goal)
        let source = await f.app.autoApprovalSource(toolName: "run_command", arguments: f.arguments,
            risk: .write, rootDirectory: f.root, interactionMode: .goal, taskRuntime: f.runtime)
        #expect(source == .taskGrant)
        #expect(f.runtime.toolCalls.last?.approvalSource == .taskGrant)
    }

    @Test("一次目标授权合并相同待审命令，不合并不同命令、外部 CLI 或 typed 卡")
    func coalescesOnlyMatchingNativeCalls() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let first = pending(f), second = pending(f)
        let different = pending(f, arguments: ["command": .string("ruby other_test.rb"), "run_in_background": .bool(false)])
        let delegated = pending(f, externalID: "delegated:other")
        let typed = pending(f)
        f.runtime.toolCalls[f.runtime.toolCalls.count - 1].status = .awaitingConfirm
        let one = try await waiter(f, call: first), two = try await waiter(f, call: second)
        await f.app.allowAgentVerifierForGoal(id: first.id)
        try #require(f.runtime.toolCalls.first(where: { $0.id == first.id })?.approvalSource == .taskGrant)
        try #require(f.runtime.toolCalls.first(where: { $0.id == second.id })?.approvalSource == .taskGrant)
        if case .approved = await one.value {} else { Issue.record("First waiter was not approved") }
        if case .approved = await two.value {} else { Issue.record("Matching waiter was not approved") }
        for call in [different, delegated] {
            #expect(f.runtime.toolCalls.first(where: { $0.id == call.id })?.status == .pendingApproval)
        }
        #expect(f.runtime.toolCalls.first(where: { $0.id == typed.id })?.status == .awaitingConfirm)
        #expect(!f.app.canOfferGoalTaskAuthorization(id: delegated.id))
        #expect(!f.app.canOfferGoalTaskAuthorization(id: typed.id))
    }

    @Test("脚本和新建清单会使授权失效，普通成果文件变化不需要再授权")
    func fingerprintsExecutionInputs() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try await grant(f)
        try Data("ordinary work".utf8).write(to: f.root.appendingPathComponent("result.txt"))
        #expect(await f.matches())
        try Data("source 'https://example.invalid'".utf8).write(to: f.root.appendingPathComponent("Gemfile"))
        #expect(await !f.matches())
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Gemfile"))
        #expect(await f.matches())
        try Data("puts 'changed'".utf8).write(to: f.root.appendingPathComponent("verify_test.rb"))
        #expect(await !f.matches())
    }

    @Test("严格模式、计划期、目标变更、工作区变更和停止不能复用旧授权")
    func lifecycleInvalidation() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try await grant(f)
        f.runtime.approvalMode = .requestEveryTime
        #expect(await !f.matches())
        f.runtime.approvalMode = .smart
        f.runtime.currentTurnPlanningOnly = true
        #expect(await !f.matches())
        f.runtime.currentTurnPlanningOnly = false
        f.runtime.currentGoal?.statement = "另一个目标"
        #expect(await !f.matches())
        f.runtime.currentGoal?.statement = "验证这个工作区"
        #expect(await f.matches())
        #expect(await !f.app.goalTaskAuthorizationMatches(runtime: f.runtime, toolName: "run_command",
            arguments: f.arguments, risk: .write, root: f.root.appendingPathComponent("other")))
        f.app.stopAgentResponse(for: f.runtime)
        #expect(f.runtime.currentGoal?.taskAuthorizations == nil)
        #expect(await !f.matches())
    }

    @Test("已取消审批不能被迟到的目标授权按钮复活")
    func cancelledWaiterIsNotRevived() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let call = pending(f)
        let decision = try await waiter(f, call: call)
        decision.cancel()
        _ = await decision.value
        await f.app.allowAgentVerifierForGoal(id: call.id)
        #expect(f.runtime.currentGoal?.taskAuthorizations == nil)
        #expect(f.runtime.toolCalls.last?.status == .denied)
    }

    @Test("真正执行入口再次核对，脚本改变或沙箱提升后不运行")
    func actualToolExecutionBoundary() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try await grant(f)
        let context = f.context()
        let result = try await AgentToolRunner.run(name: "run_command", arguments: f.arguments, context: context)
        #expect(result.commandExitCode == 0)
        #expect(result.payload.contains("verified"))
        await #expect(throws: (any Error).self) {
            _ = try await AgentToolRunner.run(name: "run_command", arguments: f.arguments,
                                             context: context.withSandboxMode(.escalated))
        }
        try Data("File.write('must-not-exist', 'ran')".utf8).write(to: f.root.appendingPathComponent("verify_test.rb"))
        await #expect(throws: (any Error).self) {
            _ = try await AgentToolRunner.run(name: "run_command", arguments: f.arguments,
                                             context: context.withAdditionalSecretRedactionValues(["fixture"]))
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("must-not-exist").path))
        #expect(AppState.automaticBackgroundSandboxRetryApprovalSource(approvalMode: .smart,
                    existingApprovalSource: .taskGrant, isUnattendedDispatchTask: true) == nil)
    }

    @Test("不会把复杂 shell、网络、后台、解释器注入或未知执行参数算成验证授权",
          arguments: ["ruby verify_test.rb; curl example.invalid", "ruby -r./verify_test.rb", "ruby ../verify_test.rb",
                      "curl https://example.invalid", "git push", "yarn install"])
    func rejectsOtherCommands(command: String) throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let call = pending(f, arguments: ["command": .string(command), "run_in_background": .bool(false)])
        #expect(!f.app.canOfferGoalTaskAuthorization(id: call.id))
    }

    @Test("后台、额外工作目录、过大或非法超时不进入范围")
    func rejectsExpandedArguments() throws {
        let f = try fixture(); defer { try? f.cleanup() }
        for (key, value) in [("run_in_background", AgentJSONValue.bool(true)), ("cwd", .string("/tmp")),
                             ("timeout_seconds", .number(1e300)), ("timeout_seconds", .number(601))] {
            var arguments = f.arguments
            arguments[key] = value
            let call = pending(f, arguments: arguments)
            #expect(!f.app.canOfferGoalTaskAuthorization(id: call.id))
        }
    }

    @Test("串行队列复用授权而不提前制造人工决定")
    func serialQueueReuse() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let first = pending(f), queued = pending(f)
        f.runtime.toolCalls[1].status = .running
        f.runtime.toolCalls[1].arguments[AgentSerialToolApprovalQueue.argumentKey] = .bool(true)
        let decision = try await waiter(f, call: first)
        await f.app.allowAgentVerifierForGoal(id: first.id)
        try #require(f.runtime.toolCalls.first(where: { $0.id == first.id })?.approvalSource == .taskGrant)
        _ = await decision.value
        let record = try #require(f.runtime.toolCalls.first(where: { $0.id == queued.id }))
        #expect(record.approvalSource == .taskGrant)
        #expect(!AgentSerialToolApprovalQueue.contains(record))
        #expect(f.runtime.pendingToolDecisions[queued.id] == nil)
    }

    @Test("超时预算、过期权限及完成的目标不会续用授权")
    func expiredOrFinished() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try await grant(f)
        f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 1, segmentStartedAt: .distantPast)
        #expect(await !f.matches())
        f.runtime.currentGoal?.continuationBudget = nil
        f.runtime.currentGoal?.checklist[0].done = true
        #expect(await !f.matches())
        f.runtime.currentGoal?.checklist[0].done = false
        let old = try #require(f.runtime.currentGoal?.taskAuthorizations?.first)
        f.runtime.currentGoal?.taskAuthorizations = [.init(id: old.id, issuerCallID: old.issuerCallID,
            sessionID: old.sessionID, contractDigest: old.contractDigest, workspacePath: old.workspacePath,
            requestDigest: old.requestDigest, environmentDigest: old.environmentDigest,
            inputDigests: old.inputDigests, grantedAt: .distantPast, expiresAt: .distantPast)]
        #expect(await !f.matches())
    }

    @Test("执行上下文的环境变更不能绕过授权校验")
    func changedExecutionEnvironmentRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try await grant(f)
        let context = AgentToolContext(rootDirectory: f.root,
            taskAuthorizationCheck: f.app.goalTaskAuthorizationExecutionCheck(runtime: f.runtime, source: .taskGrant, root: f.root),
            localCommandEnvironment: ["PATH": "/tmp"], sandboxMode: .workspaceWrite)
        await #expect(throws: (any Error).self) {
            _ = try await AgentToolRunner.run(name: "run_command", arguments: f.arguments, context: context)
        }
    }

    @Test("沙箱拒绝不会把目标内授权升级成无沙箱重试")
    func sandboxDenialDoesNotEscalate() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try await grant(f)
        let id = try #require(f.runtime.toolCalls.last?.id)
        let error = AgentToolError.commandFailed(1, "Operation not permitted")
        #expect(AgentSandboxPolicy.looksLikeSandboxDenial(error: error, sandboxMode: .workspaceWrite))
        let resolution = await f.app.resolveSandboxEscalation(for: error, toolName: "run_command", arguments: f.arguments,
            recordID: id, runtime: f.runtime, currentSandboxMode: .workspaceWrite, isRemoteWorkspace: false, alreadyAttempted: false)
        #expect(resolution == .notApplicable)
        #expect(f.runtime.toolDecisionWaiters.isEmpty)
    }

    @Test("符号链接入口不能取得持久任务授权")
    func symlinkEntryRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let script = f.root.appendingPathComponent("verify_test.rb")
        try FileManager.default.moveItem(at: script, to: f.root.appendingPathComponent("implementation.rb"))
        try FileManager.default.createSymbolicLink(atPath: script.path, withDestinationPath: "implementation.rb")
        let call = pending(f)
        let decision = try await waiter(f, call: call)
        await f.app.allowAgentVerifierForGoal(id: call.id)
        #expect(f.runtime.currentGoal?.taskAuthorizations == nil)
        #expect(f.runtime.toolCalls.last?.status == .pendingApproval)
        #expect(f.runtime.toolCalls.last?.errorMessage == L10n.GoalAuthorization.unavailable)
        decision.cancel()
        _ = await decision.value
    }

    @Test("验证授权明确收窄旧构建命令的网络凭证启发式，实际启动必须有沙箱")
    func grantUsesNarrowerSandbox() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let decision = AgentSandboxPolicy.decision(toolName: "run_command", arguments: f.arguments, rootDirectory: f.root)
        #expect(decision.mode == .workspaceWriteNetworkCredentialed)
        try await grant(f)
        let mode = f.app.sandboxModeForToolExecution(risk: .write, approvalSource: .taskGrant,
                                                   sandboxDecision: decision, isUnattendedDispatchTask: true)
        #expect(mode == .workspaceWrite)
        #expect(AgentSandboxPolicy.deniesNetwork(mode))
        let launch = AgentSandboxPolicy.shellLaunch(command: "ruby verify_test.rb", mode: mode, rootDirectory: f.root)
        #expect(launch.executableURL.path == "/usr/bin/sandbox-exec")
        #expect(!AgentSandboxPolicy.canEnforceLocalTaskVerification(command: "ruby verify_test.rb", mode: .escalated))
    }
}
