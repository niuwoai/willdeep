import Foundation
import Testing
@testable import WillDeep

/// The failure breaker used to say "stop and summarize for the user" in every
/// mode. Unattended runs (Goal, dispatch node, scheduled routine) are told by
/// their system prompt not to contact the user for ordinary errors, so there
/// the breaker must redirect instead of parking the run until morning.
@MainActor
@Suite("无人值守下的失败熔断提示", .serialized)
struct AgentToolFailureSupervisionTests {
    @Test("无人值守：换方法、阻塞点写进计划、转做其它步骤；只有全部阻塞才汇报")
    func unattendedNoteRedirectsInsteadOfStopping() {
        for (toolFailures, turnFailures) in [(3, 3), (1, 8)] {
            let note = AgentToolFailureGuidance.note(toolName: "web_fetch", toolFailures: toolFailures,
                turnFailures: turnFailures, supervision: .unattended)
            #expect(note.contains("do not stop to ask the user"))
            #expect(note.contains("clearly different approach"))
            #expect(note.contains("`update_plan`"))
            #expect(note.contains("move on to other steps"))
            #expect(note.contains("Only when every remaining step is blocked"))
            #expect(note.contains("spoofed user agents"))
            #expect(!note.contains("what you need from them"))
            #expect(!note.contains("Summarize for the user"))
        }
    }

    @Test("阈值以下两种模式都还是原来的鼓励恢复；交互模式超阈值文案不变")
    func thresholdAndInteractiveCopyUnchanged() {
        for supervision in [AgentToolFailureGuidance.Supervision.interactive, .unattended] {
            #expect(AgentToolFailureGuidance.note(toolName: "run_command", toolFailures: 2, turnFailures: 7,
                supervision: supervision) == AgentToolFailureGuidance.recoverNote)
        }
        let interactive = AgentToolFailureGuidance.note(toolName: "web_fetch", toolFailures: 3, turnFailures: 3,
            supervision: .interactive)
        #expect(interactive == AgentToolFailureGuidance.note(toolName: "web_fetch", toolFailures: 3, turnFailures: 3))
        #expect(interactive.contains("Stop retrying variations. Summarize for the user"))
        #expect(!interactive.contains("update_plan"))
    }

    @Test("按 runtime 判定：普通对话交互；执行中的 Goal、调度节点、定时任务无人值守")
    func supervisionFollowsRuntime() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        #expect(appState.toolFailureSupervision(for: runtime) == .interactive)

        runtime.interactionMode = .goal
        #expect(appState.toolFailureSupervision(for: runtime) == .interactive, "Goal still being defined")
        runtime.currentGoal = AgentGoal(statement: "Ship", checklist: [.init(text: "Verified")])
        #expect(appState.toolFailureSupervision(for: runtime) == .unattended)
        runtime.queuedMessages = [.init(text: "operator", images: [], executionAgent: .willDeep, source: .operatorInput)]
        #expect(appState.toolFailureSupervision(for: runtime) == .interactive, "a human is steering")
        runtime.queuedMessages = []
        runtime.currentGoal?.checklist[0].done = true
        #expect(appState.toolFailureSupervision(for: runtime) == .interactive, "completed Goal")

        runtime.interactionMode = .normal
        runtime.session.originRoutineID = UUID()
        #expect(appState.toolFailureSupervision(for: runtime) == .unattended)
        runtime.session.originRoutineID = nil
        runtime.session.dispatchTaskID = UUID()
        #expect(appState.toolFailureSupervision(for: runtime) == .unattended)
    }

    @Test("挂钩点：Goal 执行中第 3 次失败拿到无人值守版提示")
    func hookAppendsUnattendedNoteInGoal() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.interactionMode = .goal
        runtime.currentGoal = AgentGoal(statement: "Ship", checklist: [.init(text: "Verified")])
        _ = appState.recordToolFailureGuidance(runtime: runtime, toolName: "web_fetch")
        _ = appState.recordToolFailureGuidance(runtime: runtime, toolName: "web_fetch")
        let third = appState.recordToolFailureGuidance(runtime: runtime, toolName: "web_fetch")
        #expect(third.contains("do not stop to ask the user"))
        #expect(!third.contains("Summarize for the user"))
    }
}
