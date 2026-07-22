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
}
