//
//  AgentDispatchGoalAssessmentTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentDispatchGoalAssessmentTests {
    @Test("目标体检解码并清理可编辑验收清单")
    func assessmentDecodesAndNormalizesChecklist() throws {
        let report = """
        {
          "verdict": "needs_revision",
          "summary": "  需要明确目标用户。  ",
          "acceptance_criteria": [
            " 首页可以进入游戏 ",
            "计分会保存",
            "键盘可以操作",
            "计分会保存"
          ],
          "missing_information": [" 目标用户 ", "目标用户", "支持的浏览器"],
          "suggested_goal_statement": " 为休闲玩家制作经典网页小游戏平台 "
        }
        """

        let result = try AgentDispatchGoalAssessmentContract.decode(report)

        #expect(result.verdict == .needsRevision)
        #expect(result.summary == "需要明确目标用户。")
        #expect(result.acceptanceCriteria == ["首页可以进入游戏", "计分会保存", "键盘可以操作"])
        #expect(result.missingInformation == ["目标用户", "支持的浏览器"])
        #expect(result.suggestedGoalStatement == "为休闲玩家制作经典网页小游戏平台")
    }

    @Test("目标体检结构要求可验证清单且拒绝缺失字段")
    func assessmentSchemaRequiresCompletePayload() throws {
        let valid = AgentJSONValue.decode(from: """
        {
          "verdict": "ready",
          "summary": "边界明确",
          "acceptance_criteria": ["A", "B", "C"],
          "missing_information": [],
          "suggested_goal_statement": ""
        }
        """)
        #expect(AgentDispatchGoalAssessmentContract.outputSchema.validate(valid).isEmpty)

        let invalid = AgentJSONValue.decode(from: """
        {
          "verdict": "ready",
          "summary": "边界明确",
          "acceptance_criteria": ["A", "B"]
        }
        """)
        let issues = AgentDispatchGoalAssessmentContract.outputSchema.validate(invalid)
        #expect(issues.contains { $0.contains("acceptance_criteria") })
        #expect(issues.contains { $0.contains("missing_information") })
        #expect(issues.contains { $0.contains("suggested_goal_statement") })
    }

    @Test("目标体检提示词要求收敛诊断且不把实现步骤当验收")
    func assessmentPromptPreservesAdvisoryContract() {
        let prompt = AgentDispatchGoalAssessmentContract.prompt(statement: "做一个平台")

        #expect(prompt.contains("can actually converge"))
        #expect(prompt.contains("Do not turn implementation steps"))
        #expect(prompt.contains("never claim that the user is forbidden to continue"))
        #expect(prompt.contains("predictable user confirmations"))
        #expect(prompt.contains("ordinary Git/worktree repair"))
        #expect(prompt.contains("<goal>\n做一个平台\n</goal>"))
    }

    @Test("目标体检结论不成为创建项目的强制门禁")
    func assessmentVerdictDoesNotBlockCreation() {
        #expect(AgentDispatchGoalSetupPolicy.canCreateProject(
            statement: "做一个平台",
            acceptanceCriteria: ["用户可以完成核心流程"]
        ))
        #expect(!AgentDispatchGoalSetupPolicy.canCreateProject(
            statement: "做一个平台",
            acceptanceCriteria: []
        ))
        #expect(!AgentDispatchGoalSetupPolicy.canCreateProject(
            statement: "   ",
            acceptanceCriteria: ["可运行"]
        ))
    }

    @Test("用户修改目标后旧体检结果会标记过期")
    func changedGoalMarksAssessmentStale() {
        #expect(!AgentDispatchGoalSetupPolicy.assessmentIsStale(
            assessedStatement: "制作小游戏平台",
            currentStatement: "  制作小游戏平台  "
        ))
        #expect(AgentDispatchGoalSetupPolicy.assessmentIsStale(
            assessedStatement: "制作小游戏平台",
            currentStatement: "制作面向儿童的小游戏平台"
        ))
    }
}
