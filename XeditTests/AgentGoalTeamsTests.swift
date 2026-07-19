//
//  AgentGoalTeamsTests.swift
//  WillDeepTests
//

import Testing
import Foundation
@testable import WillDeep

private actor GoalPlanningRetryProbe {
    private(set) var memberCalls = 0
    private(set) var arbitrationCalls = 0
    private var arbitrationShouldSucceed = false

    func recordMemberCall() {
        memberCalls += 1
    }

    func recordArbitrationCall() -> Bool {
        arbitrationCalls += 1
        return arbitrationShouldSucceed
    }

    func allowArbitrationSuccess() {
        arbitrationShouldSucceed = true
    }
}

@Suite
@MainActor
struct AgentGoalTeamsTests {
    private func makeAppRuntime(
        goal: AgentGoal? = AgentGoal(statement: "Ship safely", checklist: [.init(text: "Verified")]),
        plan: AgentPlan? = nil,
        planningState: AgentGoalPlanningState? = nil,
        isResponding: Bool = true
    ) -> (AppState, AgentRuntime) {
        let appState = AppState()
        let session = AgentSession(
            interactionMode: .goal,
            currentPlan: plan,
            currentGoal: goal,
            goalPlanningState: planningState
        )
        let runtime = AgentRuntime(session: session)
        runtime.isResponding = isResponding
        appState.agentSessions = [session]
        appState.agentRuntimes = [session.id: runtime]
        appState.activeAgentSessionID = session.id
        appState.subscribeToActiveRuntime()
        return (appState, runtime)
    }

    private func validMemberReport(_ conclusion: String = "结论") -> String {
        let payload = AgentGoalPlanningMemberPayload(
            conclusion: conclusion,
            evidence: ["Xedit/AgentRuntime.swift:isPlanGateActive"],
            evidenceGaps: [],
            risks: ["回归风险"],
            recommendations: ["增加自动化测试"]
        )
        let data = try! JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private func validArbitrationReport() -> String {
        let payload = AgentGoalPlanningArbitrationPayload(
            consensus: ["确认门禁"],
            disagreements: ["重试时机"],
            evidenceGaps: ["真实网络未覆盖"],
            acceptedRecommendations: ["采用受控三成员编排"],
            rejectedRecommendations: ["拒绝多数票决策"],
            remainingRisks: ["恢复竞态"],
            stopConditions: ["少于两份有效报告"]
        )
        let data = try! JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private func validProposalContent() -> String {
        """
        | Member | Skill/Subagent | Goal Slice | Claimed Tasks | Locked Scope | Deliverable | Done Criteria | Docs/Tasklist Updates | Test Owner | Validator |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | 开发-Goal Teams | goal_backend | 状态机 | GT-003 | Xedit | 生产实现 | 构建通过 | tasklist | 测试-Goal Teams | 评审-Goal Teams |

        ```plan
        1. GT-003 负责人开发-Goal Teams：实现代码产物
        2. GT-004 负责人测试-Goal Teams：运行测试产物
        3. GT-005 负责人文档-Goal Teams：更新文档产物
        4. GT-006 负责人发布-Goal Teams：处理版本产物
        5. GT-007 负责人评审-Goal Teams：完成验收产物
        ```
        """
    }

    private func waitUntil(
        _ description: String,
        predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("等待超时：\(description)")
    }

    @Test
    func goalPlanGateOnlyUnlocksApprovedOrExecutingPlans() {
        let goal = AgentGoal(statement: "Ship safely", checklist: [.init(text: "Verified")])
        let lockedPlans: [AgentPlan?] = [
            nil,
            AgentPlan(status: .proposed, summary: "", stepTexts: ["A"]),
            AgentPlan(status: .rejected, summary: "", stepTexts: ["A"]),
            AgentPlan(status: .done, summary: "", stepTexts: ["A"]),
        ]
        for plan in lockedPlans {
            let runtime = AgentRuntime(session: AgentSession(
                interactionMode: .goal,
                currentPlan: plan,
                currentGoal: goal
            ))
            #expect(runtime.isPlanGateActive)
        }

        for status in [AgentPlan.Status.approved, .executing] {
            let runtime = AgentRuntime(session: AgentSession(
                interactionMode: .goal,
                currentPlan: AgentPlan(status: status, summary: "", stepTexts: ["A"]),
                currentGoal: goal
            ))
            #expect(!runtime.isPlanGateActive)
        }
    }

    @Test
    func goalSetupAlsoLocksWrites() {
        let runtime = AgentRuntime(session: AgentSession(interactionMode: .goal))
        #expect(runtime.currentGoal == nil)
        #expect(runtime.isPlanGateActive)
    }

    @Test("Goal setup 的生产门禁同时阻断普通 write 与 danger")
    func goalSetupBlocksWriteAndDangerAtProductionGate() {
        let runtime = AgentRuntime(session: AgentSession(interactionMode: .goal))
        let arguments = ["command": AgentJSONValue.string("swift build")]

        #expect(AppState.planGateBlocks(
            toolName: "run_command",
            arguments: arguments,
            risk: .write,
            isActive: runtime.isPlanGateActive
        ))
        #expect(AppState.planGateBlocks(
            toolName: "run_command",
            arguments: arguments,
            risk: .danger,
            isActive: runtime.isPlanGateActive
        ))
    }

    @Test
    func restoringRunningPlanningStateInterruptsAndBlocks() {
        let state = AgentGoalPlanningState(
            goalFingerprint: "goal",
            phase: .collecting,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed, report: "{}"),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .running),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .pending),
            ]
        )
        let runtime = AgentRuntime(session: AgentSession(
            interactionMode: .goal,
            currentGoal: AgentGoal(statement: "goal"),
            goalPlanningState: state
        ))
        #expect(runtime.goalPlanningState?.phase == .blocked)
        #expect(runtime.goalPlanningState?.members[0].status == .completed)
        #expect(runtime.goalPlanningState?.members[1].status == .interrupted)
        #expect(runtime.goalPlanningState?.members[2].status == .interrupted)
        #expect(runtime.isPlanGateActive)
    }

    @Test
    func unknownPlanningPhaseDoesNotBreakWholeSessionDecode() throws {
        let state = AgentGoalPlanningState(
            goalFingerprint: "goal",
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑"),
                .init(roleID: "architecture", displayName: "架构-实现路径论证"),
                .init(roleID: "testing", displayName: "测试-失败路径审查"),
            ]
        )
        let session = AgentSession(
            interactionMode: .goal,
            currentGoal: AgentGoal(statement: "goal"),
            goalPlanningState: state
        )
        let encoded = try JSONEncoder().encode(session)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var planning = try #require(object["goalPlanningState"] as? [String: Any])
        planning["phase"] = "future_phase"
        object["goalPlanningState"] = planning
        let mutated = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: mutated)
        #expect(decoded.goalPlanningState?.phase == .blocked)
        #expect(decoded.currentGoal?.statement == "goal")
    }

    @Test
    func proposalValidatorRequiresTenColumnsAndCompleteContract() throws {
        let content = """
        | Member | Skill/Subagent | Goal Slice | Claimed Tasks | Locked Scope | Deliverable | Done Criteria | Docs/Tasklist Updates | Test Owner | Validator |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | 开发-Goal Teams | goal_backend | 状态机 | GT-003 | Xedit | 生产实现 | 构建通过 | tasklist | 测试-Goal Teams | 评审-Goal Teams |

        ```plan
        1. GT-003 负责人开发-Goal Teams：实现代码产物
        2. GT-004 负责人测试-Goal Teams：运行测试产物
        3. GT-005 负责人文档-Goal Teams：更新文档产物
        4. GT-006 负责人发布-Goal Teams：版本处理 N/A，理由是由 Lead 统一更新
        5. GT-007 负责人评审-Goal Teams：完成验收产物
        ```
        """
        let plan = try #require(AgentPlanParser.extract(from: content))
        #expect(AgentGoalPlanProposalValidator.validates(content: content, plan: plan))

        let missingColumn = content.replacingOccurrences(of: "| Validator |", with: "|")
        #expect(!AgentGoalPlanProposalValidator.validates(content: missingColumn, plan: plan))

        let missingDataRow = content.replacingOccurrences(
            of: "| 开发-Goal Teams | goal_backend | 状态机 | GT-003 | Xedit | 生产实现 | 构建通过 | tasklist | 测试-Goal Teams | 评审-Goal Teams |\n",
            with: ""
        )
        #expect(!AgentGoalPlanProposalValidator.validates(content: missingDataRow, plan: plan))

        let malformedSeparator = content.replacingOccurrences(
            of: "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
            with: "| --- | --- | --- | --- | --- | --- | --- | --- | --- | not-a-separator |"
        )
        #expect(!AgentGoalPlanProposalValidator.validates(content: malformedSeparator, plan: plan))

        let incomplete = AgentPlan(status: .proposed, summary: "", stepTexts: ["GT-003 实现代码"])
        #expect(!AgentGoalPlanProposalValidator.validates(content: content, plan: incomplete))
    }

    @Test
    func revisionGuidanceSurvivesPlanningStateRoundTrip() throws {
        let state = AgentGoalPlanningState(
            goalFingerprint: "goal",
            revisionNote: "缩小范围并补充失败恢复",
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ]
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AgentGoalPlanningState.self, from: encoded)
        #expect(decoded.revisionNote == "缩小范围并补充失败恢复")
    }

    @Test("完整 Goal Teams 账本与 proposed Plan 可持久化并安全恢复")
    func completePlanningLedgerAndPlanRoundTrip() throws {
        let generationID = UUID()
        let plan = AgentPlan(status: .proposed, summary: "Goal Teams", stepTexts: ["GT-003 实现"])
        let state = AgentGoalPlanningState(
            generationID: generationID,
            goalFingerprint: AgentGoalPlanningState.fingerprint(
                for: AgentGoal(statement: "goal", checklist: [.init(text: "验收")])
            ),
            revisionNote: "保留首轮证据",
            phase: .awaitingApproval,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed, report: validMemberReport("需求结论")),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed, report: validMemberReport("架构结论")),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .failed, errorMessage: "测试成员超时"),
            ],
            arbitration: .init(status: .completed, report: validArbitrationReport())
        )
        let session = AgentSession(
            interactionMode: .goal,
            currentPlan: plan,
            currentGoal: AgentGoal(statement: "goal", checklist: [.init(text: "验收")]),
            goalPlanningState: state
        )

        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.currentPlan == plan)
        #expect(decoded.goalPlanningState == state)

        let restored = AgentRuntime(session: decoded)
        let restoredMemberReport = restored.goalPlanningState?.members[0].report
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(AgentGoalPlanningMemberPayload.self, from: $0) }
        let expectedMemberReport = try JSONDecoder().decode(
            AgentGoalPlanningMemberPayload.self,
            from: Data(validMemberReport("需求结论").utf8)
        )
        let restoredArbitrationReport = restored.goalPlanningState?.arbitration.report
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(AgentGoalPlanningArbitrationPayload.self, from: $0) }
        let expectedArbitrationReport = try JSONDecoder().decode(
            AgentGoalPlanningArbitrationPayload.self,
            from: Data(validArbitrationReport().utf8)
        )
        #expect(restored.goalPlanningState?.generationID == generationID)
        #expect(restoredMemberReport == expectedMemberReport)
        #expect(restored.goalPlanningState?.members[2].errorMessage == "测试成员超时")
        #expect(restoredArbitrationReport == expectedArbitrationReport)
        #expect(restored.goalPlanningState?.phase == .awaitingApproval)
        #expect(restored.isPlanGateActive)
    }

    @Test
    func goalPlanningPromptNeverAdvertisesAutomaticWriteApproval() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            toolsEnabled: true,
            interactionMode: .goal,
            currentGoal: AgentGoal(statement: "goal"),
            goalPlanningState: AgentGoalPlanningState(
                goalFingerprint: "goal",
                members: [
                    .init(roleID: "requirements", displayName: "需求分析-目标边界质疑"),
                    .init(roleID: "architecture", displayName: "架构-实现路径论证"),
                    .init(roleID: "testing", displayName: "测试-失败路径审查"),
                ]
            )
        )
        #expect(prompt.contains("exactly three independent read-only members"))
        #expect(prompt.contains("write-tier tools are locked"))
        #expect(!prompt.contains("Write-tier tool calls are auto-approved"))
    }

    @Test("受控首轮恰好启动三成员，逐成员完成不进入通用 parent wake")
    func controlledThreeMemberRunSuppressesPerMemberWake() async {
        let (appState, runtime) = makeAppRuntime()
        var arbitrationCalls = 0
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _ in
            let report: String
            if prompt.contains("评审-分歧证据仲裁") {
                arbitrationCalls += 1
                report = validArbitrationReport()
            } else {
                report = validMemberReport(prompt)
            }
            return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        let members = try! #require(runtime.goalPlanningState?.members)
        #expect(members.count == 3)
        #expect(Set(members.map(\.displayName)).count == 3)
        #expect(Set(members.compactMap(\.runID)).count == 3)
        #expect(appState.agentSubagentRegistry.activeCount(forParentRuntime: runtime.id) == 3)
        #expect(appState.agentSubagentRegistry.pendingReportCount(forParentRuntime: runtime.id) == 0)

        await waitUntil("三成员完成并仲裁") {
            runtime.goalPlanningState?.phase == .readyForProposal
        }
        #expect(runtime.goalPlanningState?.members.allSatisfy { $0.status == .completed } == true)
        #expect(arbitrationCalls == 1)
        #expect(appState.agentSubagentRegistry.pendingReportCount(forParentRuntime: runtime.id) == 0)
        #expect(runtime.queuedMessages.count == 1)
    }

    @Test("两份有效报告允许仲裁，并在输入中保留失败身份")
    func twoOfThreeReportsAllowArbitrationWithFailureEvidence() async {
        let (appState, runtime) = makeAppRuntime()
        var arbitrationPrompt = ""
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _ in
            if prompt.contains("评审-分歧证据仲裁") {
                arbitrationPrompt = prompt
                return .init(report: validArbitrationReport(), usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
            }
            let report = prompt.contains("测试-失败路径审查") ? "{}" : validMemberReport()
            return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        await waitUntil("2/3 降级仲裁完成") {
            runtime.goalPlanningState?.phase == .readyForProposal
        }
        #expect(runtime.goalPlanningState?.members.filter { $0.status == .completed }.count == 2)
        #expect(runtime.goalPlanningState?.members.filter { $0.status == .failed }.count == 1)
        #expect(arbitrationPrompt.contains("测试-失败路径审查"))
        #expect(arbitrationPrompt.contains("FAILED:"))
        #expect(runtime.currentPlan == nil)
    }

    @Test("零或一份有效报告保持 blocked，不调用仲裁且不可 proposed", arguments: [0, 1])
    func zeroOrOneValidReportBlocksPlanning(validCount: Int) async {
        let (appState, runtime) = makeAppRuntime()
        var memberCalls = 0
        var arbitrationCalls = 0
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _ in
            if prompt.contains("评审-分歧证据仲裁") {
                arbitrationCalls += 1
                return .init(report: validArbitrationReport(), usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
            }
            defer { memberCalls += 1 }
            let report = memberCalls < validCount ? validMemberReport() : "{}"
            return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        await waitUntil("\(validCount)/3 报告进入 blocked") {
            runtime.goalPlanningState?.phase == .blocked
        }
        #expect(arbitrationCalls == 0)
        #expect(runtime.currentPlan == nil)
        #expect(runtime.isPlanGateActive)
        #expect(runtime.goalPlanningState?.arbitration.errorMessage?.contains("fewer than two") == true)
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.queuedMessages[0].text.contains("planning is blocked"))
    }

    @Test("仲裁空输出可见且不能进入 proposed")
    func arbitrationFailureIsVisibleAndNonProposed() async {
        let (appState, runtime) = makeAppRuntime()
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _ in
            let report = prompt.contains("评审-分歧证据仲裁") ? "" : validMemberReport()
            return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        await waitUntil("仲裁失败进入 blocked") {
            runtime.goalPlanningState?.phase == .blocked
        }
        #expect(runtime.goalPlanningState?.members.allSatisfy { $0.report != nil } == true)
        #expect(runtime.goalPlanningState?.arbitration.status == .failed)
        #expect(runtime.goalPlanningState?.arbitration.errorMessage?.isEmpty == false)
        #expect(runtime.currentPlan == nil)
        #expect(runtime.queuedMessages.last?.text.contains("arbitration_failure") == true)
    }

    @Test("仲裁失败重试只重跑仲裁并保留首轮证据")
    func arbitrationRetryPreservesFirstRoundAndOnlyRerunsArbitration() async {
        let (appState, runtime) = makeAppRuntime()
        let probe = GoalPlanningRetryProbe()
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _ in
            if prompt.contains("评审-分歧证据仲裁") {
                let shouldSucceed = await probe.recordArbitrationCall()
                let report = shouldSucceed ? validArbitrationReport() : ""
                return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
            }
            await probe.recordMemberCall()
            return .init(report: validMemberReport(prompt), usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        await waitUntil("首次仲裁失败") {
            runtime.goalPlanningState?.phase == .blocked
        }
        let firstRoundReports = runtime.goalPlanningState?.members.compactMap { member in
            member.report?.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(AgentGoalPlanningMemberPayload.self, from: $0)
            }
        }
        #expect(await probe.memberCalls == 3)
        #expect(await probe.arbitrationCalls == 1)

        await probe.allowArbitrationSuccess()
        appState.retryAgentGoalPlanning()
        await waitUntil("仅重跑仲裁后成功") {
            runtime.goalPlanningState?.phase == .readyForProposal
        }

        #expect(await probe.memberCalls == 3)
        #expect(await probe.arbitrationCalls == 2)
        let retriedReports = runtime.goalPlanningState?.members.compactMap { member in
            member.report?.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(AgentGoalPlanningMemberPayload.self, from: $0)
            }
        }
        #expect(retriedReports == firstRoundReports)
        #expect(runtime.currentPlan == nil)
    }

    @Test("Goal 捕获后只自动启动一次三成员规划")
    func goalCaptureAutoStartsPlanningOnce() {
        let (appState, runtime) = makeAppRuntime(goal: nil)
        appState.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .init(report: "", usageTokens: 0, roundCount: 0, toolInvocationCount: 0)
        }
        runtime.messages = [AgentMessage(role: .assistant, content: """
        ```goal
        Goal: Ship Goal Teams safely
        Acceptance:
        - Planning is verified
        ```
        """)]

        let didDefineGoal = appState.captureAgentGoalDefinitionFromLatestMessage(for: runtime)
        appState.startAgentGoalPlanningAfterCaptureIfNeeded(didDefineGoal, for: runtime)
        #expect(didDefineGoal)
        #expect(runtime.goalPlanningState?.members.count == 3)
        let firstGeneration = runtime.goalPlanningState?.generationID

        let duplicateCapture = appState.captureAgentGoalDefinitionFromLatestMessage(for: runtime)
        appState.startAgentGoalPlanningAfterCaptureIfNeeded(duplicateCapture, for: runtime)
        #expect(!duplicateCapture)
        #expect(runtime.goalPlanningState?.generationID == firstGeneration)
        #expect(appState.agentSubagentRegistry.activeCount(forParentRuntime: runtime.id) == 3)
        appState.agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
    }

    @Test("ready 之前的提前 Plan 不会被捕获为 proposed")
    func earlyPlanIsRejectedBeforePlanningReadiness() {
        let state = AgentGoalPlanningState(
            goalFingerprint: "Ship safely\u{1F}Verified",
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑"),
                .init(roleID: "architecture", displayName: "架构-实现路径论证"),
                .init(roleID: "testing", displayName: "测试-失败路径审查"),
            ]
        )
        let (appState, runtime) = makeAppRuntime(planningState: state)
        runtime.messages = [AgentMessage(role: .assistant, content: validProposalContent())]

        appState.captureAgentPlanFromLatestMessage(for: runtime)
        #expect(runtime.currentPlan == nil)
        #expect(runtime.goalPlanningState?.phase == .blocked)
        #expect(runtime.isPlanGateActive)
    }

    @Test("Goal Plan 明确确认后派发 progress 与 goal-check 双合同")
    func approvedGoalPlanQueuesProgressAndGoalCheckContract() {
        let plan = AgentPlan(status: .proposed, summary: "", stepTexts: ["GT-003 实现"])
        let state = AgentGoalPlanningState(
            goalFingerprint: "Ship safely\u{1F}Verified",
            phase: .awaitingApproval,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ],
            arbitration: .init(status: .completed, report: validArbitrationReport())
        )
        let (appState, runtime) = makeAppRuntime(plan: plan, planningState: state)

        appState.confirmAgentPlanAndExecute()
        #expect(runtime.currentPlan?.status == .approved)
        #expect(runtime.goalPlanningState?.phase == .executing)
        let instruction = runtime.queuedMessages.last?.text ?? ""
        #expect(instruction.contains("```progress"))
        #expect(instruction.contains("```goal-check"))
    }

    @Test("拒绝清空 Plan、保留 Goal并创建新代次，旧回复不能复活")
    func rejectStartsNewGenerationAndDefendsAgainstStalePlan() {
        let oldGeneration = UUID()
        let plan = AgentPlan(status: .proposed, summary: "", stepTexts: ["GT-003 实现"])
        let state = AgentGoalPlanningState(
            generationID: oldGeneration,
            goalFingerprint: "Ship safely\u{1F}Verified",
            phase: .awaitingApproval,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ],
            arbitration: .init(status: .completed, report: validArbitrationReport())
        )
        let (appState, runtime) = makeAppRuntime(plan: plan, planningState: state)
        let originalGoal = runtime.currentGoal
        appState.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .init(report: "", usageTokens: 0, roundCount: 0, toolInvocationCount: 0)
        }

        appState.rejectAgentPlan()
        #expect(runtime.currentPlan == nil)
        #expect(runtime.currentGoal == originalGoal)
        #expect(runtime.goalPlanningState?.generationID != oldGeneration)
        #expect(runtime.goalPlanningState?.phase == .collecting)
        #expect(runtime.isPlanGateActive)

        runtime.messages.append(AgentMessage(role: .assistant, content: validProposalContent()))
        appState.captureAgentPlanFromLatestMessage(for: runtime)
        appState.confirmAgentPlanAndExecute()
        #expect(runtime.currentPlan == nil)
        #expect(runtime.goalPlanningState?.phase == .collecting)
        appState.agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
    }

    @Test("revision 强制换代会释放旧并发槽并忽略迟到完成")
    func revisionGenerationCancelsOldRunsAndIgnoresStaleCompletion() {
        let (appState, runtime) = makeAppRuntime()
        appState.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .init(report: "", usageTokens: 0, roundCount: 0, toolInvocationCount: 0)
        }
        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        let oldState = try! #require(runtime.goalPlanningState)
        let oldRunID = try! #require(oldState.members.first?.runID)

        appState.requestPlanRevision(note: "缩小范围")
        let newState = try! #require(runtime.goalPlanningState)
        #expect(newState.generationID != oldState.generationID)
        #expect(newState.revisionNote == "缩小范围")
        #expect(appState.agentSubagentRegistry.activeCount(forParentRuntime: runtime.id) == 3)

        let stale = AgentSubagentRun(
            id: oldRunID,
            shortID: "stale1",
            label: "stale",
            prompt: "stale",
            parentRuntimeID: runtime.id,
            model: "fake",
            startedAt: Date(),
            status: .completed,
            finishedAt: Date(),
            report: validMemberReport()
        )
        #expect(appState.handleAgentGoalPlanningSubagentCompletion(stale))
        #expect(runtime.goalPlanningState == newState)
        appState.agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
    }

    @Test("旧 synthesis 即使撞上新代次 ready 也不能被捕获")
    func staleSynthesisCannotBindToNewReadyGeneration() throws {
        let oldGeneration = UUID()
        let newGeneration = UUID()
        let state = AgentGoalPlanningState(
            generationID: newGeneration,
            goalFingerprint: "Ship safely\u{1F}Verified",
            phase: .readyForProposal,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ],
            arbitration: .init(status: .completed, report: validArbitrationReport())
        )
        let (appState, runtime) = makeAppRuntime(planningState: nil)
        runtime.goalPlanningState = state
        runtime.messages = [AgentMessage(
            role: .assistant,
            content: "<!-- goal-planning-generation:\(oldGeneration.uuidString) -->\n" + validProposalContent()
        )]

        appState.captureAgentPlanFromLatestMessage(for: runtime)
        #expect(runtime.currentPlan == nil)
        #expect(runtime.goalPlanningState?.phase == .readyForProposal)

        runtime.messages.append(AgentMessage(
            role: .assistant,
            content: "<!-- goal-planning-generation:\(newGeneration.uuidString) -->\n" + validProposalContent()
        ))
        appState.captureAgentPlanFromLatestMessage(for: runtime)
        #expect(try #require(runtime.currentPlan).status == .proposed)
        #expect(runtime.goalPlanningState?.phase == .awaitingApproval)
    }

    @Test("done 且 checklist 未完成自动重规划；空 checklist 不循环")
    func donePlanReplansOnlyForIncompleteNonEmptyChecklist() {
        let donePlan = AgentPlan(status: .done, summary: "", stepTexts: ["GT-003 done"])
        let (appState, runtime) = makeAppRuntime(plan: donePlan)
        appState.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .init(report: "", usageTokens: 0, roundCount: 0, toolInvocationCount: 0)
        }

        appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime)
        #expect(runtime.currentPlan == nil)
        #expect(runtime.goalPlanningState?.phase == .collecting)
        #expect(runtime.isPlanGateActive)
        appState.agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)

        let emptyGoal = AgentGoal(statement: "Goal without checklist")
        let (_, emptyRuntime) = makeAppRuntime(goal: emptyGoal, plan: donePlan)
        appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: emptyRuntime)
        #expect(emptyRuntime.currentPlan?.status == .done)
        #expect(emptyRuntime.goalPlanningState == nil)
        #expect(emptyRuntime.isPlanGateActive)
    }

    @Test("普通 Plan 行为不回归，danger 不能借研究例外绕过门禁")
    func ordinaryPlanAndDangerGateRegression() {
        let proposed = AgentRuntime(session: AgentSession(
            interactionMode: .plan,
            currentPlan: AgentPlan(status: .proposed, summary: "", stepTexts: ["A"])
        ))
        let approved = AgentRuntime(session: AgentSession(
            interactionMode: .plan,
            currentPlan: AgentPlan(status: .approved, summary: "", stepTexts: ["A"])
        ))
        #expect(proposed.isPlanGateActive)
        #expect(!approved.isPlanGateActive)

        let publicFetch = ["url": AgentJSONValue.string("https://developer.apple.com/documentation")]
        #expect(AppState.planGateBlocks(
            toolName: "web_fetch",
            arguments: publicFetch,
            risk: .danger,
            isActive: true
        ))
        #expect(!AppState.planGateBlocks(
            toolName: "web_fetch",
            arguments: publicFetch,
            risk: .danger,
            isActive: false
        ))
    }

    @Test("approved Goal Plan 下每次 danger 都不能自动批准")
    func approvedGoalPlanStillRequiresEveryDangerConfirmation() async {
        let plan = AgentPlan(status: .approved, summary: "", stepTexts: ["GT-003 实现"])
        let (appState, runtime) = makeAppRuntime(plan: plan)
        #expect(!runtime.isPlanGateActive)

        for _ in 0..<2 {
            let source = await appState.autoApprovalSource(
                toolName: "run_command",
                arguments: ["command": .string("rm -rf /tmp/willdeep-goal-test")],
                risk: .danger,
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-test-workspace"),
                interactionMode: .goal
            )
            #expect(source == nil)
        }
    }

    @Test("未来 schema 与整体损坏的持久化状态均可解码且 blocked")
    func unknownOrMalformedSchemaDefaultsToObservableBlockedState() throws {
        let state = AgentGoalPlanningState(
            goalFingerprint: "goal",
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑"),
                .init(roleID: "architecture", displayName: "架构-实现路径论证"),
                .init(roleID: "testing", displayName: "测试-失败路径审查"),
            ]
        )
        let session = AgentSession(
            interactionMode: .goal,
            currentGoal: AgentGoal(statement: "goal"),
            goalPlanningState: state
        )
        let encoded = try JSONEncoder().encode(session)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var planning = try #require(object["goalPlanningState"] as? [String: Any])
        planning["schemaVersion"] = AgentGoalPlanningState.currentSchemaVersion + 1
        object["goalPlanningState"] = planning
        let futureData = try JSONSerialization.data(withJSONObject: object)
        let future = try JSONDecoder().decode(AgentSession.self, from: futureData)
        #expect(future.goalPlanningState?.phase == .blocked)

        object["goalPlanningState"] = "corrupted"
        let malformedData = try JSONSerialization.data(withJSONObject: object)
        let malformed = try JSONDecoder().decode(AgentSession.self, from: malformedData)
        #expect(malformed.goalPlanningState?.phase == .blocked)
        #expect(malformed.goalPlanningState?.arbitration.errorMessage?.contains("malformed") == true)
        #expect(malformed.currentGoal?.statement == "goal")
    }

    @Test("恢复时 ready 静默态与 Plan/phase 矛盾都收紧为 blocked")
    func restoreBlocksSilentReadyAndContradictoryPlanPhases() {
        let members = [
            AgentGoalPlanningState.Member(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
            AgentGoalPlanningState.Member(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
            AgentGoalPlanningState.Member(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
        ]
        let cases: [(AgentGoalPlanningState.Phase, AgentPlan?)] = [
            (.readyForProposal, nil),
            (.awaitingApproval, nil),
            (.awaitingApproval, AgentPlan(status: .approved, summary: "", stepTexts: ["A"])),
            (.executing, nil),
            (.executing, AgentPlan(status: .proposed, summary: "", stepTexts: ["A"])),
            (.completed, AgentPlan(status: .approved, summary: "", stepTexts: ["A"])),
        ]

        for (phase, plan) in cases {
            let state = AgentGoalPlanningState(
                goalFingerprint: "goal",
                phase: phase,
                members: members
            )
            let runtime = AgentRuntime(session: AgentSession(
                interactionMode: .goal,
                currentPlan: plan,
                currentGoal: AgentGoal(statement: "goal"),
                goalPlanningState: state
            ))
            #expect(runtime.goalPlanningState?.phase == .blocked)
            #expect(runtime.isPlanGateActive)
        }

        let awaiting = AgentRuntime(session: AgentSession(
            interactionMode: .goal,
            currentPlan: AgentPlan(status: .proposed, summary: "", stepTexts: ["A"]),
            currentGoal: AgentGoal(statement: "goal"),
            goalPlanningState: AgentGoalPlanningState(
                goalFingerprint: "goal",
                phase: .awaitingApproval,
                members: members
            )
        ))
        #expect(awaiting.goalPlanningState?.phase == .awaitingApproval)
        #expect(awaiting.isPlanGateActive)

        let staleGoalRuntime = AgentRuntime(session: AgentSession(
            interactionMode: .goal,
            currentPlan: AgentPlan(status: .approved, summary: "", stepTexts: ["A"]),
            currentGoal: AgentGoal(statement: "new goal"),
            goalPlanningState: AgentGoalPlanningState(
                goalFingerprint: "old goal",
                phase: .executing,
                members: members
            )
        ))
        #expect(staleGoalRuntime.goalPlanningState?.phase == .blocked)
        #expect(staleGoalRuntime.currentPlan == nil)
        #expect(staleGoalRuntime.isPlanGateActive)
    }
}
