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

        ```goal-acceptance
        {"criteria":["Verified","新目标行为通过独立回归"]}
        ```

        ```goal-roadmap
        {"phases":[{"id":"PHASE-1","title":"核心实现","acceptance":["核心路径测试通过"]},{"id":"PHASE-2","title":"发布验收","acceptance":["版本与文档一致"]}]}
        ```

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
                currentGoal: goal
            ))
            runtime.currentPlan = plan
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

        #expect(AppState.goalPlanningGateBlocks(
            toolName: "run_command",
            arguments: arguments,
            risk: .write,
            isActive: runtime.isPlanGateActive
        ))
        #expect(AppState.goalPlanningGateBlocks(
            toolName: "run_command",
            arguments: arguments,
            risk: .danger,
            isActive: runtime.isPlanGateActive
        ))
    }

    @Test("Goal 规划门禁只允许外部执行器的只规划调用")
    func goalPlanningGateAllowsPlanningOnlyDelegation() {
        let planningArguments = [
            "prompt": AgentJSONValue.string("plan only"),
            "permission_mode": AgentJSONValue.string("plan"),
        ]
        #expect(!AppState.goalPlanningGateBlocks(
            toolName: "hermes_cli",
            arguments: planningArguments,
            risk: .write,
            isActive: true
        ))

        let executionArguments = [
            "prompt": AgentJSONValue.string("edit files"),
            "permission_mode": AgentJSONValue.string("workspaceWrite"),
        ]
        #expect(AppState.goalPlanningGateBlocks(
            toolName: "hermes_cli",
            arguments: executionArguments,
            risk: .write,
            isActive: true
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
    func proposalValidationFailuresExplainEachProblem() throws {
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
        // A valid proposal produces zero failures (validates == empty).
        #expect(AgentGoalPlanProposalValidator.validationFailures(content: content, plan: plan).isEmpty)

        // A broken proposal gets actionable, specific reasons — these are
        // fed back to the model, so vagueness here means another dead round.
        let incomplete = AgentPlan(status: .proposed, summary: "", stepTexts: ["do stuff quietly"])
        let failures = AgentGoalPlanProposalValidator.validationFailures(
            content: "no table at all",
            plan: incomplete
        )
        #expect(failures.contains { $0.contains("column headers") })
        #expect(failures.contains { $0.contains("implementation") })
        #expect(failures.contains { $0.contains("acceptance") })
        #expect(failures.contains { $0.contains("do stuff quietly") })

        // A generation-marker miss spells out the exact comment to copy.
        let generationID = UUID()
        let idFailures = AgentGoalPlanProposalValidator.validationFailures(
            content: content,
            plan: plan,
            generationID: generationID
        )
        #expect(idFailures.contains { $0.contains(generationID.uuidString) })
    }

    @Test
    func roadmapParserAndPlanCapsKeepGoalPlanningCoarse() throws {
        let roadmapContent = """
        ```goal-roadmap
        {"phases":[{"id":"PHASE-1","title":"基础能力","acceptance":["核心测试通过"]},{"id":"PHASE-2","title":"发布收口","acceptance":["版本文档一致"]}]}
        ```
        """
        let roadmap = try #require(AgentGoalRoadmapParser.extract(from: roadmapContent))
        #expect(roadmap.phases.count == 2)
        #expect(roadmap.activePhase?.status == .executing)
        #expect(roadmap.phasePositionText == "1/2")

        let oversized = AgentPlan(
            status: .proposed,
            summary: "",
            stepTexts: (1...7).map { "GT-\($0) 负责人开发：实现测试文档版本验收产物" }
        )
        let failures = AgentGoalPhasePlanValidator.validationFailures(plan: oversized)
        #expect(failures.contains { $0.contains("maximum of 6") })

        let unsafeID = roadmapContent.replacingOccurrences(of: "PHASE-1", with: "</phase>")
        #expect(AgentGoalRoadmapParser.extract(from: unsafeID) == nil)

        let session = AgentSession(goalRoadmap: roadmap)
        let restored = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )
        #expect(restored.goalRoadmap == roadmap)

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)
        ) as? [String: Any]
        var malformedObject = try #require(encoded)
        malformedObject["goalRoadmap"] = ["phases": "not-an-array"]
        let malformed = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONSerialization.data(withJSONObject: malformedObject)
        )
        #expect(malformed.goalRoadmap == nil)
    }

    @Test("AI 验收契约按目标规划更新并保留仍适用条目的完成状态")
    func goalAcceptanceParserReconcilesAIManagedCriteria() throws {
        let content = """
        ```goal-acceptance
        {"criteria":["保留的验收","新增的验收"]}
        ```
        """
        let criteria = try #require(
            AgentGoalAcceptanceCriteriaParser.extract(from: content)
        )
        let existing = AgentGoal(
            statement: "更新后的目标",
            checklist: [
                .init(text: "保留的验收", done: true),
                .init(text: "不再适用的验收", done: true),
            ]
        )

        let reconciled = AgentGoalAcceptanceCriteriaParser.reconcile(
            existing,
            with: criteria
        )

        #expect(reconciled.checklist.map(\.text) == ["保留的验收", "新增的验收"])
        #expect(reconciled.checklist[0].done)
        #expect(!reconciled.checklist[1].done)
        #expect(AgentGoalAcceptanceCriteriaParser.validationFailures(
            in: """
            ```goal-acceptance
            {"criteria":["重复","重复"]}
            ```
            """
        ).contains { $0.contains("unique") })
    }

    @Test
    func completedPhaseAdvancesToFreshBoundedPlanningRound() throws {
        let state = AgentGoalPlanningState(
            goalFingerprint: "Ship safely\u{1F}Verified",
            phase: .executing,
            members: []
        )
        let (appState, runtime) = makeAppRuntime(planningState: state)
        runtime.isResponding = true
        runtime.currentPlan = AgentPlan(status: .done, summary: "", stepTexts: ["GT-1 验收完成"])
        runtime.goalRoadmap = AgentGoalRoadmap(phases: [
            .init(id: "PHASE-1", title: "基础实现", acceptanceCriteria: ["测试通过"], status: .executing),
            .init(id: "PHASE-2", title: "发布收口", acceptanceCriteria: ["版本一致"]),
        ])

        #expect(appState.advanceAgentGoalRoadmapIfNeeded(for: runtime))
        #expect(runtime.currentPlan == nil)
        #expect(runtime.goalRoadmap?.activePhaseIndex == 1)
        #expect(runtime.goalRoadmap?.phases[0].status == .completed)
        #expect(runtime.goalRoadmap?.activePhase?.status == .planning)
        let instruction = try #require(runtime.queuedMessages.last)
        #expect(instruction.text.contains("at most 6"))
        #expect(instruction.text.contains("PHASE-2"))
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
            ],
            arbitration: .init(status: .completed, report: "verified planning evidence")
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AgentGoalPlanningState.self, from: encoded)
        #expect(decoded.revisionNote == "缩小范围并补充失败恢复")
    }

    @Test("旧版待批准 Goal Plan 恢复后自动进入执行")
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
        #expect(restored.currentPlan?.status == .approved)
        #expect(restored.goalPlanningState?.phase == .executing)
        #expect(!restored.isPlanGateActive)
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
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _, _ in
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
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _, _ in
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

    @Test("零或一份有效报告由仲裁器补证并继续生成提案", arguments: [0, 1])
    func zeroOrOneValidReportUsesCompensatingArbitration(validCount: Int) async {
        let (appState, runtime) = makeAppRuntime()
        var memberCalls = 0
        var arbitrationCalls = 0
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _, _ in
            if prompt.contains("评审-分歧证据仲裁") {
                arbitrationCalls += 1
                return .init(report: validArbitrationReport(), usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
            }
            defer { memberCalls += 1 }
            let report = memberCalls < validCount ? validMemberReport() : "{}"
            return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        await waitUntil("\(validCount)/3 报告完成补证仲裁") {
            runtime.goalPlanningState?.phase == .readyForProposal
        }
        #expect(arbitrationCalls == 1)
        #expect(runtime.currentPlan == nil)
        #expect(runtime.isPlanGateActive)
        #expect(runtime.goalPlanningState?.arbitration.status == .completed)
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.queuedMessages[0].text.contains("planning and arbitration are complete"))
    }

    @Test("仲裁仅因结构化输出失败时使用保守结果继续生成提案")
    func arbitrationFormatFailureUsesConservativeFallback() async throws {
        let (appState, runtime) = makeAppRuntime()
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _, _ in
            let report = prompt.contains("评审-分歧证据仲裁") ? "" : validMemberReport()
            return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.startAgentGoalPlanningIfNeeded(for: runtime))
        await waitUntil("仲裁格式失败后进入提案合成") {
            runtime.goalPlanningState?.phase == .readyForProposal
        }
        #expect(runtime.goalPlanningState?.members.allSatisfy { $0.report != nil } == true)
        #expect(runtime.goalPlanningState?.arbitration.status == .completed)
        let report = try #require(runtime.goalPlanningState?.arbitration.report)
        let payload = try JSONDecoder().decode(
            AgentGoalPlanningArbitrationPayload.self,
            from: Data(report.utf8)
        )
        #expect(payload.evidenceGaps.contains { $0.contains("结构化输出失败") })
        #expect(payload.stopConditions.contains { $0.contains("必要用户决策") })
        #expect(runtime.currentPlan == nil)
        #expect(runtime.queuedMessages.last?.text.contains("planning and arbitration are complete") == true)
    }

    @Test("仲裁失败重试只重跑仲裁并保留首轮证据")
    func arbitrationRetryPreservesFirstRoundAndOnlyRerunsArbitration() async {
        let (appState, runtime) = makeAppRuntime()
        let probe = GoalPlanningRetryProbe()
        appState.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _, _ in
            if prompt.contains("评审-分歧证据仲裁") {
                let shouldSucceed = await probe.recordArbitrationCall()
                guard shouldSucceed else { throw URLError(.timedOut) }
                return .init(report: validArbitrationReport(), usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
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
        appState.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _ in
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

    @Test("WillDeep 规划合成失败后切换备用 Profile 并重新规划")
    func willDeepPlanningFailureStartsConfiguredFallback() async {
        let primaryID = AgentExecutionProfile.recommendedPlannerID
        let fallbackID = AgentExecutionProfile.recommendedWorkerID
        let goal = AgentGoal(
            statement: "构建经典小游戏平台",
            checklist: [.init(text: "分层 DAG 通过验收")],
            planningProfileID: primaryID,
            planningFallbackProfileIDs: [fallbackID],
            planningAttemptedProfileIDs: [primaryID]
        )
        let state = AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal),
            phase: .readyForProposal,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ],
            arbitration: .init(status: .completed, report: validArbitrationReport())
        )
        let session = AgentSession(
            presentationScope: .dispatchBoard,
            interactionMode: .goal,
            currentGoal: goal,
            goalPlanningState: state
        )
        let runtime = AgentRuntime(session: session)
        // Restored ready-without-plan sessions intentionally normalize to
        // blocked; this test models the live synthesis phase instead.
        runtime.goalPlanningState = state
        runtime.executionAgent = AgentExecutionAgent.willDeep
        runtime.isResponding = true
        let appState = AppState()
        appState.agentSessions = [session]
        appState.agentRuntimes = [session.id: runtime]
        appState.activeAgentSessionID = session.id
        appState.subscribeToActiveRuntime()
        appState.agentSubagentRegistry.runOperation = { [self] prompt, _, _, _, _, _, _, _ in
            let report = prompt.contains("评审-分歧证据仲裁")
                ? validArbitrationReport()
                : validMemberReport(prompt)
            return .init(report: report, usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
        }

        #expect(appState.retryDispatchPlanningAfterWillDeepFailureIfNeeded(for: runtime))
        #expect(runtime.currentGoal?.planningAttemptedProfileIDs == [primaryID, fallbackID])
        #expect(runtime.sessionModelOverride == "deepseek-v4-flash")
        #expect(runtime.sessionProviderIDOverride == AgentProviderPreset.someIMID)

        await waitUntil("备用 Profile 完成重新规划") {
            runtime.goalPlanningState?.phase == .readyForProposal
        }
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

    @Test("有效 Goal Plan 无需确认即进入执行")
    func validGoalPlanStartsExecutingWithoutApproval() {
        let generationID = UUID()
        let state = AgentGoalPlanningState(
            generationID: generationID,
            goalFingerprint: "Ship safely\u{1F}Verified",
            phase: .readyForProposal,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ],
            arbitration: .init(status: .completed, report: validArbitrationReport())
        )
        let (appState, runtime) = makeAppRuntime(planningState: state)
        runtime.goalPlanningState = state
        runtime.messages = [AgentMessage(
            role: .assistant,
            content: "<!-- goal-planning-generation:\(generationID.uuidString) -->\n"
                + validProposalContent()
        )]

        let outcome = appState.captureAgentPlanFromLatestMessage(for: runtime)

        #expect(outcome == .captured)
        #expect(runtime.currentPlan?.status == .approved)
        #expect(runtime.goalPlanningState?.phase == .executing)
        #expect(runtime.currentGoal?.checklist.map(\.text) == [
            "Verified",
            "新目标行为通过独立回归",
        ])
        #expect(!runtime.isPlanGateActive)
    }

    @Test("revision 强制换代会释放旧并发槽并忽略迟到完成")
    func revisionGenerationCancelsOldRunsAndIgnoresStaleCompletion() {
        let (appState, runtime) = makeAppRuntime()
        appState.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _ in
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
        #expect(try #require(runtime.currentPlan).status == .approved)
        #expect(runtime.goalPlanningState?.phase == .executing)
    }

    @Test("done 且 checklist 未完成继续验收同一计划，不重新规划")
    func donePlanContinuesAcceptanceWithoutReplanning() {
        let donePlan = AgentPlan(status: .done, summary: "", stepTexts: ["GT-003 done"])
        let goal = AgentGoal(statement: "Ship safely", checklist: [.init(text: "Verified")])
        let state = AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal),
            phase: .executing,
            members: []
        )
        let (appState, runtime) = makeAppRuntime(
            goal: goal,
            plan: donePlan,
            planningState: state
        )
        runtime.isResponding = true

        appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime)
        #expect(runtime.currentPlan?.status == .done)
        #expect(runtime.goalPlanningState?.phase == .executing)
        #expect(!runtime.isPlanGateActive)
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.queuedMessages[0].text.contains("without creating or replacing a plan"))
        #expect(runtime.queuedMessages[0].text.contains("without restarting Goal Teams"))

        let emptyGoal = AgentGoal(statement: "Goal without checklist")
        let (_, emptyRuntime) = makeAppRuntime(goal: emptyGoal, plan: donePlan)
        appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: emptyRuntime)
        #expect(emptyRuntime.currentPlan?.status == .done)
        #expect(emptyRuntime.goalPlanningState == nil)
        #expect(emptyRuntime.isPlanGateActive)
    }

    @Test("Goal 连续两轮验收无进展会暂停，不会重新规划")
    func repeatedNoProgressPausesWithoutReplanning() {
        let goal = AgentGoal(statement: "Ship safely", checklist: [.init(text: "Verified")])
        let donePlan = AgentPlan(status: .done, summary: "", stepTexts: ["GT-003 done"])
        let state = AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal),
            phase: .executing,
            members: []
        )
        let (appState, runtime) = makeAppRuntime(
            goal: goal,
            plan: donePlan,
            planningState: state
        )

        appState.prepareNextAgentGoalPlanningCycleIfNeeded(
            for: runtime,
            didAdvanceChecklist: false
        )
        #expect(runtime.consecutiveGoalRoundsWithoutChecklistProgress == 1)
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.currentPlan?.status == .done)

        appState.prepareNextAgentGoalPlanningCycleIfNeeded(
            for: runtime,
            didAdvanceChecklist: false
        )
        #expect(runtime.consecutiveGoalRoundsWithoutChecklistProgress == 2)
        #expect(runtime.errorMessage?.contains("连续两轮验收清单没有进展") == true)
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.currentPlan?.status == .done)
        #expect(runtime.goalPlanningState?.phase == .executing)
    }

    @Test("额度中断后保留已完成 Plan，续跑只做 Goal 验收")
    func interruptedDonePlanResumesFinalizationWithoutReplanning() {
        let goal = AgentGoal(
            statement: "Ship safely",
            checklist: [.init(text: "Verified")]
        )
        let donePlan = AgentPlan(
            status: .done,
            summary: "",
            stepTexts: ["GT-003 implement", "GT-004 test"]
        )
        let state = AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal),
            phase: .executing,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ]
        )
        let (appState, runtime) = makeAppRuntime(
            goal: goal,
            plan: donePlan,
            planningState: state
        )

        #expect(!appState.startAgentGoalPlanningIfNeeded(for: runtime))
        #expect(runtime.currentPlan?.status == .done)
        #expect(runtime.goalPlanningState?.phase == .executing)
        #expect(!runtime.isPlanGateActive)
        #expect(!AppState.goalPlanningGateBlocks(
            toolName: "run_command",
            arguments: ["command": .string("swift test")],
            risk: .write,
            isActive: runtime.isPlanGateActive
        ))

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            toolsEnabled: true,
            interactionMode: .goal,
            currentPlan: runtime.currentPlan,
            currentGoal: runtime.currentGoal,
            goalPlanningState: runtime.goalPlanningState,
            globalRules: nil
        )
        #expect(prompt.contains("Resume this exact Goal loop and preserve its progress"))
        #expect(prompt.contains("Do not emit a new `plan`"))
        #expect(prompt.contains("Run only the remaining verification"))
        #expect(!prompt.contains(
            "A valid proposal must include the exact ten-column Teams table"
        ))
    }

    @Test("已完成 Goal 不保留中断验收写权限")
    func completedGoalClosesInterruptedFinalizationGate() {
        let completedGoal = AgentGoal(
            statement: "Ship safely",
            checklist: [.init(text: "Verified", done: true)]
        )
        let donePlan = AgentPlan(
            status: .done,
            summary: "",
            stepTexts: ["GT-003 implement"]
        )
        let state = AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: completedGoal),
            phase: .executing,
            members: [
                .init(roleID: "requirements", displayName: "需求分析-目标边界质疑", status: .completed),
                .init(roleID: "architecture", displayName: "架构-实现路径论证", status: .completed),
                .init(roleID: "testing", displayName: "测试-失败路径审查", status: .completed),
            ]
        )
        let (_, runtime) = makeAppRuntime(
            goal: completedGoal,
            plan: donePlan,
            planningState: state
        )

        #expect(runtime.goalPlanningState?.phase == .completed)
        #expect(runtime.isPlanGateActive)

        // Guard the live-state path too: even before persistence normalization,
        // a stale executing phase must not reopen write tools.
        runtime.goalPlanningState?.phase = .executing
        #expect(runtime.isPlanGateActive)
    }

    @Test("普通模式没有规划门禁，danger 不能借 Goal 研究例外绕过门禁")
    func ordinaryModeAndDangerGateRegression() {
        let approvedInNormalMode = AgentRuntime(session: AgentSession(
            interactionMode: .normal,
            currentPlan: AgentPlan(status: .approved, summary: "", stepTexts: ["A"])
        ))
        #expect(!approvedInNormalMode.isPlanGateActive)

        let publicFetch = ["url": AgentJSONValue.string("https://developer.apple.com/documentation")]
        #expect(AppState.goalPlanningGateBlocks(
            toolName: "web_fetch",
            arguments: publicFetch,
            risk: .danger,
            isActive: true
        ))
        #expect(!AppState.goalPlanningGateBlocks(
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
            (.executing, nil),
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
        #expect(awaiting.currentPlan?.status == .approved)
        #expect(awaiting.goalPlanningState?.phase == .executing)
        #expect(!awaiting.isPlanGateActive)

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
