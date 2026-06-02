//
//  AgentGoalChecklistParserTests.swift
//  VeilWriterTests
//
//  Covers AgentGoalChecklistParser.applyEvaluation — the agent's
//  self-evaluation block that flips checklist done/undone state.
//

import Testing
import Foundation
@testable import VeilWriter

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
}
