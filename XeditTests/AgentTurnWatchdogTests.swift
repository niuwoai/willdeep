import Foundation
import Testing
@testable import WillDeep

/// The host knew the turn had gone quiet and had ended on an unexecuted tool
/// call, and said nothing for fifty minutes. These pin the two rules that
/// break that silence: a stall notice after a fixed quiet period, and a
/// visible, automatically resumed interruption when a turn ends dangling.
@Suite(.serialized)
struct AgentTurnWatchdogTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    // MARK: Stall policy

    @Test("quiet past the threshold is a stall; below it is not")
    func stallThreshold() {
        let limit = AgentTurnWatchdogPolicy.stallThreshold
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastActivityAt: now.addingTimeInterval(-limit), now: now
        ) == limit)
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastActivityAt: now.addingTimeInterval(-limit + 1), now: now
        ) == nil)
    }

    /// Waiting on a person, a slot, or compression is not a stall; only a
    /// turn that should be producing and is not.
    @Test("legitimate waits are never reported as stalls")
    func legitimateWaitsAreExcluded() {
        let old = now.addingTimeInterval(-1_000)
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: false, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastActivityAt: old, now: now
        ) == nil)
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: true, isCompressingContext: false,
            hasBlockingDecision: false, lastActivityAt: old, now: now
        ) == nil)
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: true,
            hasBlockingDecision: false, lastActivityAt: old, now: now
        ) == nil)
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: true, lastActivityAt: old, now: now
        ) == nil)
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastActivityAt: nil, now: now
        ) == nil)
    }

    // MARK: Dangling detection

    private func assistant(calls: [String]) -> AgentMessage {
        AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: calls.map {
                AgentMessageToolCall(externalID: $0, toolName: "run_command", argumentsJSON: "{}")
            }
        )
    }

    private func toolResult(for id: String) -> AgentMessage {
        var message = AgentMessage(role: .tool, content: "ok")
        message.toolCallID = id
        return message
    }

    @Test("a tool call with no result after the last assistant message is dangling")
    func detectsDanglingCalls() {
        let messages = [
            AgentMessage(role: .user, content: "go"),
            assistant(calls: ["a", "b"]),
            toolResult(for: "a"),
        ]
        #expect(AgentTurnWatchdogPolicy.danglingToolCallIDs(in: messages) == ["b"])
    }

    @Test("a fully answered turn and a prose-only turn have nothing dangling")
    func cleanTurnsAreClean() {
        let answered = [
            AgentMessage(role: .user, content: "go"),
            assistant(calls: ["a"]),
            toolResult(for: "a"),
        ]
        #expect(AgentTurnWatchdogPolicy.danglingToolCallIDs(in: answered).isEmpty)
        let prose = [AgentMessage(role: .user, content: "go"), AgentMessage(role: .assistant, content: "done")]
        #expect(AgentTurnWatchdogPolicy.danglingToolCallIDs(in: prose).isEmpty)
    }

    /// Results from an earlier round must not count for a later call that
    /// happens to reuse nothing; only results after the last assistant
    /// message answer it.
    @Test("only results after the last assistant message count")
    func earlierResultsDoNotAnswerLaterCalls() {
        let messages = [
            assistant(calls: ["a"]),
            toolResult(for: "a"),
            assistant(calls: ["a"]),
        ]
        #expect(AgentTurnWatchdogPolicy.danglingToolCallIDs(in: messages) == ["a"])
    }

    @Test("the resume prompt names the lost calls and carries the dedup prefix")
    func resumePromptShape() {
        let prompt = AgentTurnWatchdogPolicy.resumePrompt(danglingToolNames: ["spawn_agent"])
        #expect(prompt.hasPrefix(AgentTurnWatchdogPolicy.resumePromptPrefix))
        #expect(prompt.contains("`spawn_agent`"))
    }

    // MARK: AppState integration

    @MainActor
    private func fixture() throws -> (AppState, AgentRuntime) {
        let app = AppState(
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            loadSessionCatalog: false
        )
        let session = app.startNewAgentSession()
        let runtime = try #require(app.agentRuntimes[session.id])
        return (app, runtime)
    }

    @Test("a quiet turn gets the stall notice, and activity clears it")
    @MainActor
    func stallNoticeAppearsAndClears() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.isResponding = true
        runtime.lastActivityAt = now.addingTimeInterval(-AgentTurnWatchdogPolicy.stallThreshold - 5)

        app.scanAgentTurnsForStalls(now: now)
        #expect(runtime.errorMessage != nil)
        #expect(runtime.errorSeverity == .notice)
        #expect(runtime.isShowingWatchdogStallNotice)

        app.noteAgentTurnActivity(for: runtime, at: now)
        #expect(runtime.errorMessage == nil)
        #expect(!runtime.isShowingWatchdogStallNotice)
        runtime.isResponding = false
    }

    /// A real error already on the banner must not be replaced by the mild
    /// stall notice.
    @Test("the stall notice never overwrites a real error")
    @MainActor
    func stallNoticeYieldsToErrors() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.isResponding = true
        runtime.lastActivityAt = now.addingTimeInterval(-1_000)
        runtime.errorMessage = "provider exploded"
        runtime.errorSeverity = .error

        app.scanAgentTurnsForStalls(now: now)

        #expect(runtime.errorMessage == "provider exploded")
        #expect(!runtime.isShowingWatchdogStallNotice)
        runtime.isResponding = false
    }

    @Test("a turn that ends on a dangling call is flagged, settled, and auto-resumed once")
    @MainActor
    func danglingTurnIsFlaggedAndResumed() async throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        let turnID = UUID()
        runtime.messages = [
            AgentMessage(role: .user, content: "check the server", source: .operatorInput),
            assistant(calls: ["lost"]),
        ]
        runtime.toolCalls = [
            AgentToolCall(
                messageID: runtime.messages[1].id, externalID: "lost", toolName: "run_command",
                arguments: [:], risk: .read, status: .running
            ),
        ]
        runtime.isResponding = false

        app.noteAgentTurnEnded(for: runtime, turnID: turnID)

        #expect(runtime.errorMessage != nil)
        #expect(runtime.errorSeverity == .notice)
        #expect(runtime.toolCalls[0].status == .failed)
        #expect(runtime.turnInterruptionAutoResumeCount == 1)
        // The resume is dispatched on the next main-actor hop as a host
        // instruction carrying the dedup prefix.
        for _ in 0..<50 where !runtime.isResponding && !runtime.messages.contains(where: { $0.source == .hostInstruction }) {
            await Task.yield()
        }
        let resumed = runtime.messages.contains {
            $0.source == .hostInstruction && $0.content.hasPrefix(AgentTurnWatchdogPolicy.resumePromptPrefix)
        }
        #expect(resumed, "no resume instruction was dispatched")
        app.stopAgentResponse(for: runtime)
    }

    @Test("a user stop is not an interruption")
    @MainActor
    func userStopIsNotFlagged() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        let turnID = UUID()
        runtime.userStoppedTurnID = turnID
        runtime.messages = [AgentMessage(role: .user, content: "go"), assistant(calls: ["x"])]

        app.noteAgentTurnEnded(for: runtime, turnID: turnID)

        #expect(runtime.errorMessage == nil)
        #expect(runtime.turnInterruptionAutoResumeCount == 0)
    }

    @Test("automatic resumes stop at the cap")
    @MainActor
    func resumeCap() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.messages = [AgentMessage(role: .user, content: "go"), assistant(calls: ["x"])]
        runtime.turnInterruptionAutoResumeCount = AgentTurnWatchdogPolicy.maximumAutomaticResumes

        app.noteAgentTurnEnded(for: runtime, turnID: UUID())

        #expect(runtime.errorMessage != nil)
        #expect(runtime.turnInterruptionAutoResumeCount == AgentTurnWatchdogPolicy.maximumAutomaticResumes)
    }

    @Test func theNoticeNamesWhoIsActuallySilent() {
        // 派出去的 Worker 没回：回合等的是它，说成「等模型」会让人去查错地方。
        #expect(AgentTurnWatchdogPolicy.stallSubject(
            runningToolName: "spawn_agent",
            runningWorkerName: "调查员",
            lastMessageIsAssistantWithText: false
        ) == .worker("调查员"))
        // 本机工具没回。
        #expect(AgentTurnWatchdogPolicy.stallSubject(
            runningToolName: "run_command",
            runningWorkerName: nil,
            lastMessageIsAssistantWithText: true
        ) == .tool("run_command"))
        // 没有在跑的工具、也还没有正文：请求出去了没回来。
        #expect(AgentTurnWatchdogPolicy.stallSubject(
            runningToolName: nil,
            runningWorkerName: nil,
            lastMessageIsAssistantWithText: false
        ) == .modelFirstToken)
        // 正文已经流了一半又停：连接多半断了。
        #expect(AgentTurnWatchdogPolicy.stallSubject(
            runningToolName: nil,
            runningWorkerName: nil,
            lastMessageIsAssistantWithText: true
        ) == .modelMidStream)
    }

    @Test func theBannerCountsInSecondsAndThenInMinutes() {
        #expect(AgentTurnWatchdogPolicy.formatIdle(91) == L10n.TurnWatchdog.durationMinutes(1, 31))
        #expect(AgentTurnWatchdogPolicy.formatIdle(45) == L10n.TurnWatchdog.durationSeconds(45))
        // 秒数每一跳都要变，否则读秒读了个寂寞。
        #expect(AgentTurnWatchdogPolicy.formatIdle(111) != AgentTurnWatchdogPolicy.formatIdle(112))
    }

    @Test func reassuranceStartsWellBeforeTheBannerAndOnlyForTheModel() {
        let start = Date(timeIntervalSince1970: 1_000)
        func quiet(after seconds: TimeInterval) -> TimeInterval? {
            AgentTurnWatchdogPolicy.quietSeconds(
                isResponding: true,
                isAwaitingProviderSlot: false,
                isCompressingContext: false,
                hasBlockingDecision: false,
                lastVisibleOutputAt: start,
                now: start.addingTimeInterval(seconds)
            )
        }
        #expect(quiet(after: 5) == nil)
        #expect(quiet(after: 15) == 15)
        #expect(AgentTurnWatchdogPolicy.reassuranceThreshold < AgentTurnWatchdogPolicy.stallThreshold)
        // 工具和 Worker 在状态条上本来就有名字和秒表，安抚只给模型那两种。
        #expect(L10n.TurnWatchdog.reassurance(subject: .modelFirstToken) != nil)
        #expect(L10n.TurnWatchdog.reassurance(subject: .modelMidStream) != nil)
        #expect(L10n.TurnWatchdog.reassurance(subject: .tool("run_command")) == nil)
        #expect(L10n.TurnWatchdog.reassurance(subject: .worker("调查员")) == nil)
        // 没有可见输出的时间点就没有安抚：不能从 nil 起算。
        #expect(AgentTurnWatchdogPolicy.quietSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastVisibleOutputAt: nil, now: start
        ) == nil)
    }

    @Test("等待超过阈值后升级为完成状态未确认，不继续显示普通等待提示")
    @MainActor
    func quietResponseBecomesUnconfirmedInsteadOfReassuring() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.isResponding = true
        runtime.lastActivityAt = now
        runtime.lastVisibleOutputAt = now
        app.scanAgentTurnsForStalls(now: now.addingTimeInterval(20))
        #expect(runtime.quietReassurance?.isOverdue == false)
        app.scanAgentTurnsForStalls(now: now.addingTimeInterval(233))
        #expect(runtime.quietReassurance?.isOverdue == true)
        #expect(L10n.TurnWatchdog.reassurance(subject: .modelFirstToken, isOverdue: true)
            != L10n.TurnWatchdog.reassurance(subject: .modelFirstToken))
        app.noteAgentVisibleOutput(for: runtime, at: now.addingTimeInterval(234))
        #expect(runtime.quietReassurance == nil)
        runtime.isResponding = false
    }

    @Test func theBannerCountsDownToTheAutomaticReconnect() {
        let at100 = L10n.TurnWatchdog.nextStep(subject: .modelFirstToken, idle: 100)
        let at150 = L10n.TurnWatchdog.nextStep(subject: .modelFirstToken, idle: 150)
        #expect(at100 != at150)
        #expect(at100.contains(AgentTurnWatchdogPolicy.formatIdle(AgentTurnWatchdogPolicy.automaticReconnectAt - 100)))
        // 过了守卫时限还没断（守卫在另一条线程上）也不能倒数成负数。
        let past = L10n.TurnWatchdog.nextStep(subject: .modelMidStream, idle: 10_000)
        #expect(past.contains(AgentTurnWatchdogPolicy.formatIdle(0)))
        #expect(AgentTurnWatchdogPolicy.automaticReconnectAt > AgentTurnWatchdogPolicy.stallThreshold)
    }
}
