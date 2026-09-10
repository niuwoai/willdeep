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

    // MARK: 时钟锚点（横幅报出 150 分 39 秒的那次）

    /// 上一轮 20:21 结束，两个半小时后用户发了新消息，横幅立刻说
    /// 「spawn_agent 已经 150 分 39 秒 没有返回」——数的是上一轮的旧戳。
    /// 回合再静默也不可能比它自己的年龄更久。
    @Test("旧回合留下的活动戳被钳到本回合起点")
    func staleActivityStampIsClampedToTheTurnStart() {
        let previousTurn = now.addingTimeInterval(-9_039)
        // 回合刚开始：即便旧戳来自两个半小时前，也不是停摆。
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastActivityAt: previousTurn,
            turnStartedAt: now.addingTimeInterval(-3), now: now
        ) == nil)
        // 本回合自己静默够久了，报的是本回合的时长，不是旧戳的。
        #expect(AgentTurnWatchdogPolicy.stalledSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastActivityAt: previousTurn,
            turnStartedAt: now.addingTimeInterval(-200), now: now
        ) == 200)
        // 同一条钳制也管安抚条，否则状态条会提前跳到「未确认」。
        #expect(AgentTurnWatchdogPolicy.quietSeconds(
            isResponding: true, isAwaitingProviderSlot: false, isCompressingContext: false,
            hasBlockingDecision: false, lastVisibleOutputAt: previousTurn,
            turnStartedAt: now.addingTimeInterval(-3), now: now
        ) == nil)
    }

    @Test("早于本回合的运行中工具不算本回合在跑")
    func runningRowsFromEarlierTurnsAreNotThisTurn() {
        #expect(!AgentTurnWatchdogPolicy.isRunningInCurrentTurn(
            toolStartedAt: now.addingTimeInterval(-9_039), turnStartedAt: now.addingTimeInterval(-3)
        ))
        #expect(AgentTurnWatchdogPolicy.isRunningInCurrentTurn(
            toolStartedAt: now.addingTimeInterval(-30), turnStartedAt: now.addingTimeInterval(-60)
        ))
        // 没有回合起点可比时不做判断，维持旧行为。
        #expect(AgentTurnWatchdogPolicy.isRunningInCurrentTurn(
            toolStartedAt: now.addingTimeInterval(-9_039), turnStartedAt: nil
        ))
    }

    /// 整条复现：台账里躺着上一轮没结算的 spawn_agent，活动戳停在两个半小时前，
    /// 用户刚发出新消息。修好之前这里会立刻弹出那条横幅。
    @Test("刚发出的回合不会被判成停摆两个半小时")
    @MainActor
    func freshTurnIsNotReportedAsStalledSinceThePreviousTurn() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        let previousTurn = now.addingTimeInterval(-9_039)
        runtime.messages = [AgentMessage(role: .user, content: "跑一下这个脚本", source: .operatorInput)]
        runtime.toolCalls = [
            AgentToolCall(
                messageID: runtime.messages[0].id, externalID: "leftover", toolName: "spawn_agent",
                arguments: [:], risk: .read, status: .running, startedAt: previousTurn
            ),
        ]
        runtime.lastActivityAt = previousTurn
        runtime.isResponding = true
        runtime.turnStartedAt = now.addingTimeInterval(-2)

        app.scanAgentTurnsForStalls(now: now)

        #expect(runtime.errorMessage == nil)
        #expect(!runtime.isShowingWatchdogStallNotice)
        runtime.isResponding = false
    }

    @Test("回合结束会把活动戳和可见输出戳一起清掉")
    @MainActor
    func turnEndClearsBothClocks() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.messages = [
            AgentMessage(role: .user, content: "go", source: .operatorInput),
            AgentMessage(role: .assistant, content: "done"),
        ]
        runtime.lastActivityAt = now
        runtime.lastVisibleOutputAt = now

        app.noteAgentTurnEnded(for: runtime, turnID: UUID())

        #expect(runtime.lastActivityAt == nil)
        #expect(runtime.lastVisibleOutputAt == nil)
    }

    // MARK: 思考期的沉默（1.361.0-rc2）

    /// 推理模型可以思考一两分钟才写出第一个字。那段时间只有 reasoning 增量，
    /// 而 `noteAgentVisibleOutput` 只认文本增量，于是状态条说「未收到新输出」
    /// 并在 90 秒后升级成「完成状态未确认」——宿主其实一直在收东西。这句话
    /// 会让人以为线路断了，去按停止或者重发，而模型正在干活。
    @Test("推理增量在到达时说「正在思考」，而不是「未收到新输出」")
    @MainActor
    func thinkingSilenceReadsAsThinking() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.isResponding = true
        runtime.turnStartedAt = now
        runtime.lastActivityAt = now
        runtime.lastVisibleOutputAt = now
        runtime.lastReasoningAt = now.addingTimeInterval(50)

        app.scanAgentTurnsForStalls(now: now.addingTimeInterval(60))
        let quiet = try #require(runtime.quietReassurance)
        #expect(quiet.isThinking)
        // 有动静就不该升级成「完成状态未确认」：那句话是说给线路那头没动静
        // 听的。
        #expect(!quiet.isOverdue)
        #expect(L10n.TurnWatchdog.reassurance(subject: .modelFirstToken, isThinking: true)
            != L10n.TurnWatchdog.reassurance(subject: .modelFirstToken))
        runtime.isResponding = false
    }

    /// 思考结束后模型可能还要好一会儿才写出正文。那段沉默不能继续冒充思考，
    /// 否则「正在思考」会挂在一个真的卡死的回合上。
    @Test("推理停了足够久之后不再冒充思考")
    @MainActor
    func staleReasoningStopsClaimingToThink() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.isResponding = true
        runtime.turnStartedAt = now
        runtime.lastActivityAt = now
        runtime.lastVisibleOutputAt = now
        runtime.lastReasoningAt = now

        let stale = now.addingTimeInterval(AgentTurnWatchdogPolicy.thinkingFreshness + 100)
        app.scanAgentTurnsForStalls(now: stale)
        let quiet = try #require(runtime.quietReassurance)
        #expect(!quiet.isThinking)
        #expect(quiet.isOverdue)
        runtime.isResponding = false
    }

    @Test("从未收到过推理增量时行为不变")
    @MainActor
    func noReasoningKeepsTheOldCopy() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.isResponding = true
        runtime.turnStartedAt = now
        runtime.lastActivityAt = now
        runtime.lastVisibleOutputAt = now

        app.scanAgentTurnsForStalls(now: now.addingTimeInterval(20))
        #expect(runtime.quietReassurance?.isThinking == false)
        #expect(runtime.quietReassurance?.isOverdue == false)
        runtime.isResponding = false
    }

    @Test("回合结束时推理戳和另外两个时钟一起清空")
    @MainActor
    func turnEndClearsTheReasoningClock() throws {
        let (app, runtime) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.messages = [
            AgentMessage(role: .user, content: "go", source: .operatorInput),
            AgentMessage(role: .assistant, content: "done"),
        ]
        runtime.lastActivityAt = now
        runtime.lastVisibleOutputAt = now
        runtime.lastReasoningAt = now

        app.noteAgentTurnEnded(for: runtime, turnID: UUID())

        #expect(runtime.lastReasoningAt == nil)
        #expect(runtime.lastActivityAt == nil)
        #expect(runtime.lastVisibleOutputAt == nil)
    }

    /// 工具和 Worker 在状态条上本来就有名字和秒表，思考这条线只给模型两档。
    @Test("思考文案只给模型两档，工具和 Worker 不变")
    func thinkingCopyIsModelOnly() {
        #expect(L10n.TurnWatchdog.reassurance(subject: .tool("run_command"), isThinking: true) == nil)
        #expect(L10n.TurnWatchdog.reassurance(subject: .worker("调查员"), isThinking: true) == nil)
        #expect(L10n.TurnWatchdog.reassurance(subject: .modelMidStream, isThinking: true) != nil)
    }
}
