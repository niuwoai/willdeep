import Foundation
import Testing
@testable import WillDeep

@Suite("重复调用检测：纯逻辑")
struct AgentRepeatedCallGuardTests {
    private let digestA = AgentRepeatedCallGuard.digest("result A")
    private let digestB = AgentRepeatedCallGuard.digest("result B")

    @Test("参数规范化：key 顺序与多余空白不影响，随机字段和宿主私有字段被忽略")
    func normalization() {
        let a = #"{"path":"README.md","limit":20}"#
        let b = "  {\n  \"limit\" : 20,   \"path\" : \"  README.md \" }\n"
        #expect(AgentRepeatedCallGuard.normalizedArguments(a) == AgentRepeatedCallGuard.normalizedArguments(b))
        #expect(AgentRepeatedCallGuard.signature(toolName: "read_file", argumentsJSON: a)
            == AgentRepeatedCallGuard.signature(toolName: "read_file", argumentsJSON: b))
        let noisy = #"{"path":"README.md","limit":20,"nonce":"x1","_sandbox":"workspaceWrite","request_id":"r9"}"#
        #expect(AgentRepeatedCallGuard.normalizedArguments(noisy) == AgentRepeatedCallGuard.normalizedArguments(a))
        #expect(AgentRepeatedCallGuard.signature(toolName: "read_file", argumentsJSON: #"{"path":"other.md","limit":20}"#)
            != AgentRepeatedCallGuard.signature(toolName: "read_file", argumentsJSON: a))
        #expect(AgentRepeatedCallGuard.signature(toolName: "list_directory", argumentsJSON: a)
            != AgentRepeatedCallGuard.signature(toolName: "read_file", argumentsJSON: a))
        #expect(AgentRepeatedCallGuard.normalizedArguments("  not json ") == "not json")
    }

    @Test("阈值：相同调用相同结果逐次累计，第 3 次起提示、第 5 次起算停滞")
    func thresholds() {
        var ledger = AgentRepeatedCallLedger()
        let counts = (1...5).map { _ in
            ledger.observe(toolName: "read_file", argumentsJSON: #"{"path":"a"}"#, outcome: .succeeded(resultDigest: digestA))
        }
        #expect(counts == [1, 2, 3, 4, 5])
        #expect(AgentRepeatedCallGuard.hintThreshold == 3)
        #expect(AgentRepeatedCallGuard.stallThreshold == 5)
        let note = AgentRepeatedCallGuard.note(toolName: "read_file", count: 3, failed: false, countsAgainstGoalProgress: false)
        #expect(note.contains("call #3 of read_file"))
        #expect(note.contains("the result has not changed"))
        #expect(!note.contains("Goal progress"))
        #expect(AgentRepeatedCallGuard.note(toolName: "x", count: 5, failed: true, countsAgainstGoalProgress: true)
            .contains("no longer count as Goal progress"))
    }

    @Test("结果哈希变化即重新计数；连续失败也算重复；成功与失败交替会重置")
    func resultChangeResets() {
        var ledger = AgentRepeatedCallLedger()
        let args = #"{"command":"make test"}"#
        #expect(ledger.observe(toolName: "run_command", argumentsJSON: args, outcome: .succeeded(resultDigest: digestA)) == 1)
        #expect(ledger.observe(toolName: "run_command", argumentsJSON: args, outcome: .succeeded(resultDigest: digestA)) == 2)
        #expect(ledger.observe(toolName: "run_command", argumentsJSON: args, outcome: .succeeded(resultDigest: digestB)) == 1)
        #expect(ledger.observe(toolName: "run_command", argumentsJSON: args, outcome: .failed) == 1)
        #expect(ledger.observe(toolName: "run_command", argumentsJSON: args, outcome: .failed) == 2)
        #expect(ledger.observe(toolName: "run_command", argumentsJSON: args, outcome: .failed) == 3)
        #expect(ledger.observe(toolName: "run_command", argumentsJSON: args, outcome: .succeeded(resultDigest: digestB)) == 1)
    }

    @Test("轮询类工具在白名单里，不计数")
    func pollingToolsAreExempt() {
        var ledger = AgentRepeatedCallLedger()
        for tool in ["get_job_output", "list_jobs", "embedded_browser_wait_for", "git_status", "update_plan", "some_im_poll_media_task"] {
            #expect(AgentRepeatedCallGuard.isExempt(toolName: tool))
            for _ in 0..<6 {
                #expect(ledger.observe(toolName: tool, argumentsJSON: #"{"job_id":"j1"}"#, outcome: .succeeded(resultDigest: digestA)) == nil)
            }
        }
        #expect(ledger.entries.isEmpty)
        #expect(!AgentRepeatedCallGuard.isExempt(toolName: "read_file"))
        #expect(!AgentRepeatedCallGuard.isExempt(toolName: "run_command"))
    }

    @Test("窗口上限：超过上限淘汰最久未见的签名")
    func windowIsBounded() {
        var ledger = AgentRepeatedCallLedger()
        let limit = AgentRepeatedCallGuard.maximumTrackedSignatures
        _ = ledger.observe(toolName: "read_file", argumentsJSON: #"{"path":"first"}"#, outcome: .succeeded(resultDigest: digestA))
        _ = ledger.observe(toolName: "read_file", argumentsJSON: #"{"path":"first"}"#, outcome: .succeeded(resultDigest: digestA))
        for index in 0..<limit {
            _ = ledger.observe(toolName: "read_file", argumentsJSON: #"{"path":"f\#(index)"}"#, outcome: .succeeded(resultDigest: digestA))
        }
        #expect(ledger.entries.count == limit)
        #expect(ledger.observe(toolName: "read_file", argumentsJSON: #"{"path":"first"}"#, outcome: .succeeded(resultDigest: digestA)) == 1)
    }

    @Test("账本随 Goal 编解码，旧 Goal JSON 没有该字段照常解码")
    func codable() throws {
        var goal = AgentGoal(statement: "g", checklist: [.init(text: "c")])
        var ledger = AgentRepeatedCallLedger()
        _ = ledger.observe(toolName: "read_file", argumentsJSON: "{}", outcome: .failed)
        goal.repeatedCallLedger = ledger
        #expect(try JSONDecoder().decode(AgentGoal.self, from: JSONEncoder().encode(goal)) == goal)
        let legacy = try JSONDecoder().decode(AgentGoal.self, from: Data(#"{"statement":"old","checklist":[]}"#.utf8))
        #expect(legacy.repeatedCallLedger == nil)
    }
}

@MainActor
@Suite("重复调用检测：挂钩点", .serialized)
struct AgentRepeatedCallGuardHookTests {
    private func makeRuntime(goal: Bool) throws -> (AppState, AgentRuntime) {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        let runtime = try #require(appState.agentRuntimes[session.id])
        if goal {
            runtime.interactionMode = .goal
            runtime.currentGoal = AgentGoal(statement: "Ship", checklist: [.init(text: "Verified")])
            runtime.currentPlan = AgentPlan(status: .executing, steps: [.init(text: "Work", status: .inProgress)], summary: "")
        }
        return (appState, runtime)
    }

    /// One model call plus its result, the way the tool loop records them.
    private func callAndAnswer(_ app: AppState, _ runtime: AgentRuntime, tool: String = "read_file",
                               arguments: String = #"{"path":"README.md"}"#, payload: String = "same content",
                               status: AgentToolCallStatus = .succeeded) -> String {
        let id = UUID().uuidString
        runtime.messages.append(AgentMessage(role: .assistant, content: "",
            toolCalls: [AgentMessageToolCall(externalID: id, toolName: tool, argumentsJSON: arguments)]))
        app.appendToolMessage(for: runtime, toolCallID: id, payload: payload, outcomeStatus: status, toolName: tool)
        return runtime.messages.last?.content ?? ""
    }

    @Test("普通对话：第 3 次相同调用后面追加提示，只提示不阻断")
    func ordinaryConversationOnlyHints() throws {
        let (app, runtime) = try makeRuntime(goal: false)
        defer { AgentSessionStore.delete(id: runtime.id) }
        let contents = (1...5).map { _ in callAndAnswer(app, runtime) }
        #expect(!contents[0].contains("WillDeep: this is call"))
        #expect(!contents[1].contains("WillDeep: this is call"))
        #expect(contents[2].contains("call #3 of read_file"))
        #expect(contents[4].contains("call #5 of read_file"))
        #expect(!contents[4].contains("Goal progress"))
        #expect(!runtime.repeatedCallStallSinceLastContinuationDecision)
        #expect(!app.settleRepeatedCallStallForContinuationDecision(for: runtime, checklistAdvanced: false))
        // A changed result is new information: the count starts over.
        #expect(!callAndAnswer(app, runtime, payload: "new content").contains("WillDeep: this is call"))
        app.resetRepeatedCallGuardForDispatch(for: runtime, source: .operatorInput)
        #expect(runtime.currentTurnRepeatedCallLedger.entries.isEmpty)
    }

    @Test("Goal：跨续推轮累计，第 5 次起本轮不算进展并推进退避阶梯；人工消息清零")
    func goalStallFeedsBackoffLadder() throws {
        let (app, runtime) = try makeRuntime(goal: true)
        defer { AgentSessionStore.delete(id: runtime.id) }
        for _ in 1...3 { _ = callAndAnswer(app, runtime, status: .failed) }
        // A host continuation is a new turn but the same Goal: keep counting.
        app.resetRepeatedCallGuardForDispatch(for: runtime, source: .hostInstruction)
        _ = callAndAnswer(app, runtime, status: .failed)
        let fifth = callAndAnswer(app, runtime, status: .failed)
        #expect(fifth.contains("call #5 of read_file"))
        #expect(fifth.contains("it has failed every time"))
        #expect(fifth.contains("no longer count as Goal progress"))
        #expect(runtime.currentGoal?.repeatedCallLedger?.entries.first?.count == 5)
        #expect(runtime.repeatedCallStallSinceLastContinuationDecision)

        let before = runtime.consecutiveGoalRoundsWithoutChecklistProgress
        #expect(app.settleRepeatedCallStallForContinuationDecision(for: runtime, checklistAdvanced: false))
        #expect(runtime.consecutiveGoalRoundsWithoutChecklistProgress == before + 1)
        // Consumed: the next decision starts clean.
        #expect(!app.settleRepeatedCallStallForContinuationDecision(for: runtime, checklistAdvanced: false))

        _ = callAndAnswer(app, runtime, status: .failed)
        #expect(!app.settleRepeatedCallStallForContinuationDecision(for: runtime, checklistAdvanced: true),
                "checklist progress outranks the stall")

        app.resetRepeatedCallGuardForDispatch(for: runtime, source: .operatorInput)
        #expect(runtime.currentGoal?.repeatedCallLedger == nil)
        #expect(!callAndAnswer(app, runtime, status: .failed).contains("WillDeep: this is call"))
    }

    @Test("挂钩点跳过轮询工具和被拒绝的调用")
    func hookSkipsPollingAndDenied() throws {
        let (app, runtime) = try makeRuntime(goal: true)
        defer { AgentSessionStore.delete(id: runtime.id) }
        for _ in 1...6 {
            #expect(!callAndAnswer(app, runtime, tool: "get_job_output", arguments: #"{"job_id":"j1"}"#)
                .contains("WillDeep: this is call"))
            #expect(!callAndAnswer(app, runtime, status: .denied).contains("WillDeep: this is call"))
        }
        #expect(runtime.currentGoal?.repeatedCallLedger?.entries.isEmpty != false)
        #expect(!runtime.repeatedCallStallSinceLastContinuationDecision)
    }
}
