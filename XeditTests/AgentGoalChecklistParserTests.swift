//
//  AgentGoalChecklistParserTests.swift
//  WillDeepTests
//
//  Covers AgentGoalChecklistParser.applyEvaluation — the agent's
//  self-evaluation block that flips checklist done/undone state.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentGoalChecklistParserTests {
    private func goal(_ count: Int, done: Set<Int> = []) -> AgentGoal {
        AgentGoal(
            statement: "Test goal",
            checklist: (1...count).map { i in
                AgentGoal.Item(text: "item \(i)", done: done.contains(i))
            }
        )
    }

    @Test
    func extractsGoalDefinitionBlock() {
        let reply = """
        我先把目标确认下来。

        ```goal
        Goal: Ship remote runtime support end to end
        Acceptance:
        - SSH runtime can run commands
        - Daemon runtime can read files
        - Version and docs are updated
        ```
        """
        let parsed = AgentGoalParser.extract(from: reply)
        #expect(parsed?.statement == "Ship remote runtime support end to end")
        #expect(parsed?.checklist.map(\.text) == [
            "SSH runtime can run commands",
            "Daemon runtime can read files",
            "Version and docs are updated",
        ])
    }

    @Test
    func goalDefinitionSupportsNumberedChecklist() {
        let reply = """
        ```goal
        Goal: Improve approval UX
        Checklist:
        1. Composer exposes approval mode
        2. Session persists the choice
        ```
        """
        let parsed = AgentGoalParser.extract(from: reply)
        #expect(parsed?.statement == "Improve approval UX")
        #expect(parsed?.checklist.map(\.text) == [
            "Composer exposes approval mode",
            "Session persists the choice",
        ])
    }

    @Test
    func flipsItemsDoneAndUndone() {
        let g = goal(3)
        let reply = """
        Working on it.

        ```goal-check
        1: done
        3: done
        ```
        """
        let next = AgentGoalChecklistParser.applyEvaluation(to: g, from: reply)
        #expect(next != nil)
        #expect(next?.checklist[0].done == true)
        #expect(next?.checklist[1].done == false)
        #expect(next?.checklist[2].done == true)
    }

    @Test
    func canUndoneAPreviouslyDoneItem() {
        let g = goal(2, done: [1, 2])
        let reply = """
        ```goal-check
        2: undone
        ```
        """
        let next = AgentGoalChecklistParser.applyEvaluation(to: g, from: reply)
        #expect(next?.checklist[0].done == true)   // unchanged
        #expect(next?.checklist[1].done == false)  // flipped back
    }

    @Test
    func unknownTokensAndOutOfRangeIgnored() {
        let g = goal(2)
        let reply = """
        ```goal-check
        99: done
        1: warp-speed
        2: done
        ```
        """
        let next = AgentGoalChecklistParser.applyEvaluation(to: g, from: reply)
        #expect(next?.checklist[0].done == false)
        #expect(next?.checklist[1].done == true)
    }

    @Test
    func noBlockReturnsNil() {
        let g = goal(1)
        #expect(AgentGoalChecklistParser.applyEvaluation(to: g, from: "Just prose.") == nil)
    }

    @Test
    func proseDoesNotCountAsCurrentRoundEvaluation() {
        #expect(!AgentGoalChecklistParser.containsEvaluationBlock(
            in: "The provider stopped before Goal verification."
        ))
    }

    @Test
    func noChangesBlockStillCountsAsCurrentRoundEvaluation() {
        let reply = """
        Verification finished without changing checklist state.

        ```goal-check
        # no changes
        ```
        """
        #expect(AgentGoalChecklistParser.containsEvaluationBlock(in: reply))
    }

    @Test
    func truncatedGoalCheckCannotAdvanceGoalLifecycle() {
        let reply = """
        Verification was cut off.

        ```goal-check
        1: done
        """
        #expect(!AgentGoalChecklistParser.containsEvaluationBlock(
            in: reply,
            checklistCount: 1
        ))
        #expect(AgentGoalChecklistParser.applyEvaluation(
            to: goal(1),
            from: reply
        ) == nil)
    }

    @Test
    func emptyUnknownAndOutOfRangeGoalChecksAreInvalid() {
        let empty = """
        ```goal-check
        ```
        """
        let invalid = """
        ```goal-check
        1: warp-speed
        99: done
        ```
        """
        #expect(!AgentGoalChecklistParser.containsEvaluationBlock(
            in: empty,
            checklistCount: 2
        ))
        #expect(!AgentGoalChecklistParser.containsEvaluationBlock(
            in: invalid,
            checklistCount: 2
        ))
    }

    @Test
    func closedInRangeGoalCheckIsValidEvenWhenStateDoesNotChange() {
        let reply = """
        ```goal-check
        2: undone
        ```
        """
        #expect(AgentGoalChecklistParser.containsEvaluationBlock(
            in: reply,
            checklistCount: 2
        ))
    }

    @Test
    func lengthTruncatedReplyCannotAdvanceEvenWithAClosedGoalCheck() {
        let reply = """
        ```goal-check
        1: done
        ```
        """
        #expect(!AgentGoalChecklistParser.containsEvaluationBlock(
            in: reply,
            checklistCount: 1,
            finishReason: "length"
        ))
        #expect(AgentGoalChecklistParser.applyEvaluation(
            to: goal(1),
            from: reply,
            finishReason: "length"
        ) == nil)
    }

    /// A no-op block (every entry already matches current state)
    /// returns nil so the caller can skip persistence.
    @Test
    func noOpBlockReturnsNil() {
        let g = goal(2, done: [1])
        let reply = """
        ```goal-check
        1: done
        2: undone
        ```
        """
        #expect(AgentGoalChecklistParser.applyEvaluation(to: g, from: reply) == nil)
    }

    @Test
    func toleratesAliasFormatting() {
        let g = goal(4)
        let reply = """
        ```goal-check
        - 1. complete
        2) yes
        item 3: ✓
        4 ok
        ```
        """
        let next = AgentGoalChecklistParser.applyEvaluation(to: g, from: reply)
        #expect(next?.checklist[0].done == true)
        #expect(next?.checklist[1].done == true)
        #expect(next?.checklist[2].done == true)
        #expect(next?.checklist[3].done == true)
    }

    @Test
    func blockedFlipsPreviouslyDoneItemBack() {
        let g = goal(2, done: [1])
        let reply = """
        Goal self-check: blocked because the verification command failed.

        ```goal-check
        1: blocked
        # no changes for item 2
        ```
        """
        let next = AgentGoalChecklistParser.applyEvaluation(to: g, from: reply)
        #expect(next?.checklist[0].done == false)
        #expect(next?.checklist[1].done == false)
    }

    @Test
    func activeGoalPromptRequiresTurnEndSelfCheck() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: URL(fileURLWithPath: "/tmp/project"),
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .goal,
            currentGoal: goal(2)
        )
        #expect(prompt.contains("Turn-end self-check (REQUIRED on every Goal-mode assistant reply after the goal is defined)"))
        #expect(prompt.contains("Goal self-check"))
        #expect(prompt.contains("# no changes"))
        #expect(prompt.contains("compact delivery summary"))
        #expect(prompt.contains("Do not repeat command transcripts, failed attempts, raw tool output"))
    }

    /// 规划阶段的提示词里出现过 “host-coordinated / host-owned flow”，模型把它
    /// 直译成「等待宿主放行」回给用户——而根本没有这么一个放行动作，用户只能
    /// 对着屏幕找一个不存在的按钮。措辞本身就是这个 bug。
    @Test("Goal 规划阶段不把自己描述成在等谁放行")
    func goalPlanningPromptNeverClaimsToAwaitRelease() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: URL(fileURLWithPath: "/tmp/project"),
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .goal,
            currentGoal: goal(2)
        )

        // 这段是规划阶段（还没有已验证的 Plan）才会注入的。
        #expect(prompt.contains("Goal Teams planning is already running automatically"))
        #expect(prompt.contains("Nobody has to approve anything"))
        #expect(prompt.contains("Never tell the user you are waiting to be unblocked"))
        // 否定式断言：等价重构可以换说法，但不该把“宿主”这个概念放回去。
        #expect(!prompt.contains("host-coordinated"))
        #expect(!prompt.contains("host-owned"))
    }

    /// planning 卡住时旧提示词只让模型「解释证据缺口」，于是它反复解释、
    /// 反复被拒，用户不知道那张 Goal 卡片上的「重试规划」才是出路。
    @Test("Goal 规划被阻断时把出路说给用户听")
    func blockedGoalPlanningPointsAtRetry() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: URL(fileURLWithPath: "/tmp/project"),
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .goal,
            currentGoal: goal(2),
            goalPlanningState: AgentGoalPlanningState(
                goalFingerprint: "goal",
                phase: .blocked,
                members: []
            )
        )

        #expect(prompt.contains("Independent planning is blocked"))
        #expect(prompt.contains("Retry planning"))
        #expect(prompt.contains("Do not describe this as waiting for permission"))
    }

    /// 被门禁拦下的工具回灌给模型的那段话。它决定了用户读到的那句解释。
    @Test("门禁回灌文案不留下“等人放行”的暗示")
    func goalGateNoticeLeavesNoPermissionNarrative() {
        for payload in [
            AgentGoalGateNotice.blockedToolPayload,
            AgentGoalGateNotice.blockedDelegationPayload,
        ] {
            #expect(payload.contains("This is automatic"))
            #expect(payload.contains("no user approval, release, or authorization is involved"))
            #expect(payload.contains("Never tell the user you are waiting to be unblocked"))
            // 模型此前正是从 “host” 推断出「宿主」这个不存在的角色。
            #expect(!payload.lowercased().contains("host"))
        }
    }

    @Test
    func activeGoalPlanRunsUnattendedAndSelfRecoversOrdinaryFailures() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: URL(fileURLWithPath: "/tmp/project"),
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .goal,
            currentPlan: AgentPlan(
                status: .approved,
                steps: [AgentPlan.Step(text: "完成实现并验证")],
                summary: ""
            ),
            currentGoal: goal(2)
        )

        #expect(prompt.contains("A validated Goal-backed Plan is active"))
        #expect(prompt.contains("Treat the run as unattended"))
        #expect(prompt.contains("ordinary Git/worktree"))
        #expect(prompt.contains("Re-contact the user only for missing authority or credentials"))
    }

    @Test
    func workspaceGoalAwarenessPreventsDuplicateGoalCreation() {
        let existingSessionID = UUID()
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: URL(fileURLWithPath: "/tmp/project"),
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            currentSessionTitle: "新会话",
            workspaceSessions: [
                AgentWorkspaceSessionSnapshot(
                    id: existingSessionID,
                    title: "登录重构调度台",
                    workspaceRootPath: "/tmp/project",
                    workspaceDisplayName: "project",
                    presentationScope: .dispatchBoard,
                    isActive: false,
                    isPinned: false,
                    isArchived: false,
                    isResponding: true,
                    isAwaitingProviderSlot: false,
                    queuedMessageCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 2_000),
                    lastActivityAt: Date(timeIntervalSince1970: 2_000),
                    interactionMode: .goal,
                    approvalMode: .smart,
                    executionAgent: .willDeep,
                    titleIsUserSet: true,
                    goalStatement: "重构登录流程",
                    goalCompletedItemCount: 1,
                    goalTotalItemCount: 3,
                    goalIsComplete: false,
                    goalPlanningPhase: .executing,
                    dispatchParentProjectID: nil,
                    dispatchTaskID: nil,
                    isDispatchProject: true,
                    isDispatchPaused: false
                )
            ]
        )

        #expect(prompt.contains("=== WORKSPACE GOAL AWARENESS ==="))
        #expect(prompt.contains("[dispatch-project, running] 登录重构调度台"))
        #expect(prompt.contains(existingSessionID.uuidString))
        #expect(prompt.contains("Do not emit a new `goal` block"))
        #expect(prompt.contains("only one non-paused unfinished dispatch project"))
    }
}
