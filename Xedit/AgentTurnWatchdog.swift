//
//  AgentTurnWatchdog.swift
//  WillDeep
//
//  Breaks silence during long turns.
//
//  A routine log check once took an hour: the work was done in two minutes,
//  the delegate died on a TLS handshake ten minutes later, and the turn then
//  ended with a tool call the model had emitted but nobody executed. For the
//  next fifty minutes the host knew all of that — no token, no tool event,
//  a dangling call at turn end — and said nothing. The user typed "继续".
//
//  Two rules, both host-side, neither trusting the model to report:
//
//  1. Stall notice. A turn that has produced no token and no tool event for
//     `stallThreshold` seconds gets a visible notice naming what it is
//     waiting on. Legitimate long waits (an approval card, a provider slot,
//     compression) are excluded. The notice clears itself the moment
//     activity resumes.
//  2. Dangling tool calls. A turn that ends while its last assistant message
//     still has tool calls without results is not a finished turn — it broke
//     on the way. The host says so, and resumes it once (`.hostInstruction`,
//     deduplicated, capped) rather than handing the cursor back in silence.
//

import Foundation

nonisolated enum AgentTurnWatchdogPolicy {
    /// Silence tolerated before the notice. Ninety seconds is longer than any
    /// provider's time-to-first-token and longer than a normal tool call, and
    /// three ticks of the 30-second scheduler the check rides on.
    static let stallThreshold: TimeInterval = 90
    /// Seconds of *visible* silence before the composer strip starts
    /// reassuring instead of just saying "思考中". Fifteen seconds is past
    /// the point where a user starts wondering and well before anything is
    /// actually wrong: reasoning models routinely take a minute or two to
    /// show their first character.
    static let reassuranceThreshold: TimeInterval = 15
    /// 推理增量多久没来就不再说「正在思考」。推理流是断续的，两段之间隔
    /// 十几秒很常见；但思考结束后模型可能还要好一会儿才写出正文，那段沉默
    /// 不能继续冒充思考。二十秒够宽，也不至于把结束后的等待说成还在想。
    static let thinkingFreshness: TimeInterval = 20
    /// Silence at which the stream idle guard cuts the connection and the
    /// transient ladder reconnects. The stall banner counts down to it so
    /// the user knows the host will act without them.
    static let automaticReconnectAt: TimeInterval = AgentStreamIdleGuard.streamIdleTimeout
    /// How many times a turn that ended on dangling tool calls is resumed
    /// without the user. Two catches a transient; more would loop a turn that
    /// keeps breaking in the same place.
    static let maximumAutomaticResumes = 2
    /// First line of the resume instruction; used to deduplicate against a
    /// queued copy the same way the goal planner does.
    static let resumePromptPrefix = "=== TURN INTERRUPTED — RESUME ==="

    /// No turn can have been silent for longer than it has existed. Both
    /// clocks are stamped inside the round loop, well after `isResponding`
    /// goes true, and neither is cleared on every path a turn can end on —
    /// so between two turns they hold the previous turn's value. The
    /// thirty-second scheduler tick lands in that window often enough that
    /// a freshly sent message was once greeted with "spawn_agent 已经 150 分
    /// 39 秒 没有返回", counted from a turn that had finished two and a half
    /// hours earlier. Clamping to the turn's own start makes the stale value
    /// harmless instead of alarming.
    private static func anchor(_ stamp: Date, turnStartedAt: Date?) -> Date {
        guard let turnStartedAt else { return stamp }
        return max(stamp, turnStartedAt)
    }

    /// Time spent waiting for the operator is not time a tool failed to
    /// return.
    ///
    /// The idle clock starts at the last provider stream event — which is
    /// *before* the approval card is even raised. While the card is up
    /// `hasBlockingDecision` suppresses the banner, but nothing resets the
    /// clock, so the moment the operator clicks approve the next 1 Hz tick
    /// computes an idle of however long they took to decide. Step away for a
    /// coffee and the command is greeted, at the instant it starts running,
    /// with "run_command has not returned for 5 minutes" — plus a retry
    /// button for a command that has not run at all yet.
    ///
    /// Detected on the falling edge rather than by patching every site that
    /// clears a decision: approvals resolve through several paths (the card,
    /// typed confirmation, the fast path in tool batching), and an edge is
    /// one place that covers all of them.
    static func clockResetForClearedBlock(
        wasBlocked: Bool,
        isBlocked: Bool,
        now: Date
    ) -> Date? {
        guard wasBlocked, !isBlocked else { return nil }
        return now
    }

    /// The stall threshold for a turn, widened to whatever budget the running
    /// command actually asked for.
    ///
    /// `run_command` carries `timeout_seconds` (60s by default, up to 600s in
    /// the foreground). Announcing a stall at 90s while the host itself is
    /// prepared to wait 600s reports a problem that, by the host's own
    /// accounting, does not exist yet. Pulling an image or installing
    /// dependencies is exactly the shape that trips this.
    ///
    /// Deliberately not an inference from the command text: the host's slow
    /// command detector does not know `docker pull`, and the card's title is
    /// written by the model, so neither is evidence. The declared budget is.
    static func stallThreshold(runningToolTimeouts: [TimeInterval]) -> TimeInterval {
        max(stallThreshold, runningToolTimeouts.max() ?? 0)
    }

    /// Visible silence long enough for tier-one reassurance, nil when the
    /// turn is either showing output or legitimately parked.
    static func quietSeconds(
        isResponding: Bool,
        isAwaitingProviderSlot: Bool,
        isCompressingContext: Bool,
        hasBlockingDecision: Bool,
        lastVisibleOutputAt: Date?,
        turnStartedAt: Date? = nil,
        now: Date
    ) -> TimeInterval? {
        guard isResponding, !isAwaitingProviderSlot, !isCompressingContext, !hasBlockingDecision,
              let lastVisibleOutputAt else { return nil }
        let quiet = now.timeIntervalSince(anchor(lastVisibleOutputAt, turnStartedAt: turnStartedAt))
        return quiet >= reassuranceThreshold ? quiet : nil
    }

    /// Seconds of silence when the turn should be reported as stalled, nil
    /// when it is either active or legitimately waiting.
    static func stalledSeconds(
        isResponding: Bool,
        isAwaitingProviderSlot: Bool,
        isCompressingContext: Bool,
        hasBlockingDecision: Bool,
        lastActivityAt: Date?,
        turnStartedAt: Date? = nil,
        threshold: TimeInterval = stallThreshold,
        now: Date
    ) -> TimeInterval? {
        guard isResponding, !isAwaitingProviderSlot, !isCompressingContext, !hasBlockingDecision,
              let lastActivityAt else { return nil }
        let idle = now.timeIntervalSince(anchor(lastActivityAt, turnStartedAt: turnStartedAt))
        return idle >= threshold ? idle : nil
    }

    /// What the turn is actually waiting on. The distinction matters because
    /// the four cases have different culprits and different remedies: a
    /// silent Worker is somebody else's process, a silent tool is this
    /// machine, no first token is the request never landing, and a reply
    /// that stops mid-stream is the connection dying with the turn still
    /// open. "Waiting for the model" covered all four and told the user
    /// nothing.
    enum StallSubject: Equatable {
        case worker(String)
        case tool(String)
        /// Request is out (or a tool result was just handed back) and not one
        /// token has come back yet.
        case modelFirstToken
        /// Text was already streaming and then stopped.
        case modelMidStream
    }

    /// Whether a `.running` ledger row belongs to the turn being reported on.
    /// The tool-call ledger spans the whole session, and three early returns
    /// in `noteAgentTurnEnded` leave a broken turn's rows unsettled — so the
    /// newest `.running` row can be hours old and owned by nobody. Naming it
    /// blames a tool that is not running, which is how a stalled *model*
    /// round came out as "the spawn_agent tool has not returned".
    static func isRunningInCurrentTurn(toolStartedAt: Date, turnStartedAt: Date?) -> Bool {
        guard let turnStartedAt else { return true }
        return toolStartedAt >= turnStartedAt
    }

    /// Pure so the four branches can be tested without a runtime.
    static func stallSubject(
        runningToolName: String?,
        runningWorkerName: String?,
        lastMessageIsAssistantWithText: Bool
    ) -> StallSubject {
        if let runningToolName {
            if let runningWorkerName, !runningWorkerName.isEmpty {
                return .worker(runningWorkerName)
            }
            return .tool(runningToolName)
        }
        return lastMessageIsAssistantWithText ? .modelMidStream : .modelFirstToken
    }

    /// Seconds-resolution duration for the banner. The banner is re-rendered
    /// every second while it is up, so this has to read naturally at 91 s as
    /// well as at 40 min.
    static func formatIdle(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return L10n.TurnWatchdog.durationSeconds(total) }
        return L10n.TurnWatchdog.durationMinutes(total / 60, total % 60)
    }

    /// External IDs of tool calls on the last assistant message that have no
    /// tool result after them. Empty when the turn ended cleanly.
    static func danglingToolCallIDs(in messages: [AgentMessage]) -> [String] {
        guard let assistantIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return [] }
        let expected = messages[assistantIndex].toolCalls.map(\.externalID).filter { !$0.isEmpty }
        guard !expected.isEmpty else { return [] }
        let answered = Set(
            messages[(assistantIndex + 1)...].compactMap { $0.role == .tool ? $0.toolCallID : nil }
        )
        return expected.filter { !answered.contains($0) }
    }

    /// Model-facing. Names the calls whose results were lost.
    ///
    /// Deliberately does not claim they never ran. A foreground command on a
    /// remote host is run through `waitUntilExit()` and does not honour task
    /// cancellation, so stopping this side leaves it executing on the far
    /// side; `stopAgentResponse` only reaps registered background jobs. The
    /// old wording ("that call never ran") told the model it was safe to
    /// re-issue, which is how one `docker pull` becomes two.
    static func resumePrompt(danglingToolNames: [String]) -> String {
        let names = danglingToolNames.isEmpty ? "the last tool call" : danglingToolNames.map { "`\($0)`" }.joined(separator: ", ")
        return """
        \(resumePromptPrefix)
        The previous turn ended before \(names) produced a result. Whether it ran is \
        unknown — a foreground command on a remote host keeps going on the far side even \
        after this side stops waiting, so the work may be finished, half-finished, or \
        never started. Before re-issuing anything that is not safe to run twice, check \
        the actual state first (list what exists, query the service, read the log). \
        Then continue the task from where it stopped. Do not repeat work that already \
        has results above.
        """
    }
}

extension AppState {
    /// Stamp activity on the runtime. Called for every streamed provider
    /// event and every tool result; cheap enough to call per token.
    func noteAgentTurnActivity(for runtime: AgentRuntime, at now: Date = Date()) {
        runtime.lastActivityAt = now
        // A turn that has just started has shown nothing yet; the visible
        // clock starts with the first sign of life so quiet is measured
        // from a real point, not from nil.
        if runtime.lastVisibleOutputAt == nil { runtime.lastVisibleOutputAt = now }
        if runtime.isShowingWatchdogStallNotice {
            runtime.isShowingWatchdogStallNotice = false
            if runtime.errorSeverity == .notice {
                runtime.clearTurnError()
            }
        }
        updateAgentStallTicker()
    }

    /// Stamp something the user could see: a text delta, a tool result, a
    /// Worker round. Implies activity.
    func noteAgentVisibleOutput(for runtime: AgentRuntime, at now: Date = Date()) {
        noteAgentTurnActivity(for: runtime, at: now)
        runtime.lastVisibleOutputAt = now
        if runtime.quietReassurance != nil {
            runtime.quietReassurance = nil
        }
    }

    /// Tier three: the stream idle guard or a dropped connection ended the
    /// request and the transient ladder is about to reconnect. Until now this
    /// happened in silence; the user saw the same frozen state before and
    /// after the reconnect and could not tell the host had done anything.
    func noteAgentTransientReconnect(for runtime: AgentRuntime, attempt: Int, maximum: Int) {
        guard runtime.errorMessage == nil || runtime.isShowingWatchdogStallNotice else { return }
        runtime.errorMessage = L10n.TurnWatchdog.reconnecting(attempt: attempt, maximum: maximum)
        runtime.errorDetails = nil
        runtime.errorSeverity = .notice
        // Same clearing path as the stall notice: the first event of the
        // new request takes it down.
        runtime.isShowingWatchdogStallNotice = true
        runtime.quietReassurance = nil
    }

    /// "Retry now" on the stall banner. Stops the turn and re-runs it once
    /// the loop has wound down, instead of making the user wait for the
    /// idle guard to time out on its own.
    func retryStalledAgentTurn() {
        guard let runtime = activeRuntime, runtime.isResponding else { return }
        runtime.retryAfterStopRequested = true
        stopAgentResponse(for: runtime)
    }

    /// Runs on the scheduler tick. Raises the stall notice on runtimes that
    /// have gone quiet and leaves everything else alone.
    func scanAgentTurnsForStalls(now: Date = Date()) {
        for runtime in agentRuntimes.values {
            let blocking = runtime.toolCalls.contains { $0.status.isBlockingForUserDecision }
            // 审批刚解除：把两个时钟推到现在。用户思考的那几分钟不是工具
            // 没返回——在他点下确认之前，命令一个字节都还没跑。
            if let reset = AgentTurnWatchdogPolicy.clockResetForClearedBlock(
                wasBlocked: runtime.wasBlockedOnUserDecision,
                isBlocked: blocking,
                now: now
            ) {
                runtime.lastActivityAt = reset
                runtime.lastVisibleOutputAt = reset
                if runtime.isShowingWatchdogStallNotice {
                    runtime.errorMessage = nil
                    runtime.errorDetails = nil
                    runtime.isShowingWatchdogStallNotice = false
                }
            }
            runtime.wasBlockedOnUserDecision = blocking
            // Tier one: alive but showing nothing. Only ever changes the
            // strip label, and only publishes when the label would change.
            let quiet = AgentTurnWatchdogPolicy.quietSeconds(
                isResponding: runtime.isResponding,
                isAwaitingProviderSlot: runtime.isAwaitingProviderSlot,
                isCompressingContext: runtime.isCompressingContext,
                hasBlockingDecision: blocking,
                lastVisibleOutputAt: runtime.lastVisibleOutputAt,
                turnStartedAt: runtime.turnStartedAt,
                now: now
            )
            if let quiet {
                // 推理正在到达时，这段沉默是「在想」，不是「没消息」。也因此
                // 不升级成「完成状态未确认」——那句话是说给「线路那头没动静」
                // 听的，而这里明明有动静。
                let isThinking = runtime.lastReasoningAt.map {
                    now.timeIntervalSince($0) <= AgentTurnWatchdogPolicy.thinkingFreshness
                } ?? false
                // Anchored, so `since` is the clamped start of the silence
                // rather than a stamp left over from an earlier turn.
                let reassurance = AgentQuietReassurance(
                    subject: watchdogStallSubject(for: runtime),
                    since: now.addingTimeInterval(-quiet),
                    isOverdue: !isThinking && quiet >= AgentTurnWatchdogPolicy.stallThreshold,
                    isThinking: isThinking
                )
                if runtime.quietReassurance != reassurance { runtime.quietReassurance = reassurance }
            } else if runtime.quietReassurance != nil {
                runtime.quietReassurance = nil
            }
            guard let idle = AgentTurnWatchdogPolicy.stalledSeconds(
                isResponding: runtime.isResponding,
                isAwaitingProviderSlot: runtime.isAwaitingProviderSlot,
                isCompressingContext: runtime.isCompressingContext,
                hasBlockingDecision: blocking,
                lastActivityAt: runtime.lastActivityAt,
                turnStartedAt: runtime.turnStartedAt,
                threshold: AgentTurnWatchdogPolicy.stallThreshold(
                    runningToolTimeouts: runtime.toolCalls.compactMap { call in
                        guard call.status == .running,
                              AgentTurnWatchdogPolicy.isRunningInCurrentTurn(
                                  toolStartedAt: call.startedAt, turnStartedAt: runtime.turnStartedAt
                              ) else { return nil }
                        return call.arguments["timeout_seconds"]?.intValue().map(TimeInterval.init)
                    }
                ),
                now: now
            ) else { continue }
            // Never paint over a real error; the stall notice is the mild
            // one and yields to anything already on the banner.
            guard runtime.errorMessage == nil || runtime.isShowingWatchdogStallNotice else { continue }
            let subject = watchdogStallSubject(for: runtime)
            runtime.errorMessage = L10n.TurnWatchdog.stalled(subject: subject, idle: idle)
                + " " + L10n.TurnWatchdog.nextStep(subject: subject, idle: idle)
            runtime.errorDetails = nil
            runtime.errorSeverity = .notice
            runtime.isShowingWatchdogStallNotice = true
        }
        updateAgentStallTicker()
    }

    private func watchdogStallSubject(for runtime: AgentRuntime) -> AgentTurnWatchdogPolicy.StallSubject {
        let running = runtime.toolCalls.last {
            $0.status == .running
                && AgentTurnWatchdogPolicy.isRunningInCurrentTurn(
                    toolStartedAt: $0.startedAt, turnStartedAt: runtime.turnStartedAt
                )
        }
        let worker = running?.toolName == "spawn_agent"
            ? (running?.subagentWorkerName ?? running?.subagentLiveActivity?.workerName)
            : nil
        let tail = runtime.messages.last
        return AgentTurnWatchdogPolicy.stallSubject(
            runningToolName: running?.toolName,
            runningWorkerName: worker,
            lastMessageIsAssistantWithText: tail?.role == .assistant
                && !(tail?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
    }

    /// The banner counts. A number frozen at "111 s" while the wait keeps
    /// growing reads like the app is stuck too; a moving number is the
    /// cheapest proof that the host is still watching. The ticker runs
    /// while any turn is responding — it is what promotes a quiet turn to
    /// reassurance at fifteen seconds and to the banner at ninety — and
    /// stops with the last turn. Each tick is a handful of comparisons; it
    /// publishes only when a label or a notice actually changes.
    func updateAgentStallTicker() {
        let live = agentRuntimes.values.contains { $0.isResponding || $0.isShowingWatchdogStallNotice }
        guard live else {
            agentStallTickerTask?.cancel()
            agentStallTickerTask = nil
            return
        }
        guard agentStallTickerTask == nil else { return }
        agentStallTickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.agentRuntimes.values.contains(where: { $0.isResponding || $0.isShowingWatchdogStallNotice }) else {
                    self.agentStallTickerTask = nil
                    return
                }
                self.scanAgentTurnsForStalls()
            }
        }
    }

    /// Called from the turn's closing `defer`, after the loop has released
    /// its state but before the session is persisted. Detects a turn that
    /// broke on an unexecuted tool call, tells the user, and schedules one
    /// automatic resume.
    func noteAgentTurnEnded(for runtime: AgentRuntime, turnID: UUID) {
        runtime.isShowingWatchdogStallNotice = false
        runtime.quietReassurance = nil
        runtime.lastVisibleOutputAt = nil
        runtime.lastReasoningAt = nil
        // Both clocks die with the turn. Leaving this one behind is what let
        // the next turn be reported as silent since the last one — the two
        // fields are read together and must be cleared together.
        runtime.lastActivityAt = nil
        updateAgentStallTicker()
        if runtime.retryAfterStopRequested {
            runtime.retryAfterStopRequested = false
            // The stop's own bookkeeping (interrupted message, persisted
            // session) finishes in this same defer; re-run on the next hop.
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime, self.activeRuntime === runtime else { return }
                if runtime.errorSeverity == .notice { runtime.clearTurnError() }
                self.retryLastAgentTurn()
            }
            return
        }
        guard runtime.userStoppedTurnID != turnID,
              runtime.errorMessage == nil,
              !runtime.toolCalls.contains(where: { $0.status.isBlockingForUserDecision }) else { return }
        let dangling = AgentTurnWatchdogPolicy.danglingToolCallIDs(in: runtime.messages)
        guard !dangling.isEmpty else {
            runtime.turnInterruptionAutoResumeCount = 0
            return
        }
        let names = runtime.messages.last(where: { $0.role == .assistant })?.toolCalls
            .filter { dangling.contains($0.externalID) }
            .map(\.toolName) ?? []
        // Settle the records so the pill and the Dock do not keep counting
        // work that will never happen.
        for index in runtime.toolCalls.indices
        where dangling.contains(runtime.toolCalls[index].externalID) && runtime.toolCalls[index].status == .running {
            runtime.toolCalls[index].status = .failed
        }

        runtime.errorMessage = L10n.TurnWatchdog.interrupted(toolNames: names)
        runtime.errorDetails = nil
        runtime.errorSeverity = .notice

        guard runtime.turnInterruptionAutoResumeCount < AgentTurnWatchdogPolicy.maximumAutomaticResumes else { return }
        runtime.turnInterruptionAutoResumeCount += 1
        let prompt = AgentTurnWatchdogPolicy.resumePrompt(danglingToolNames: names)
        // The defer that called us is still unwinding; dispatch once it has
        // fully released the turn (isResponding, the provider slot, the queue).
        Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime, !runtime.isResponding else { return }
            if runtime.queuedMessages.contains(where: {
                $0.source == .hostInstruction && $0.text.hasPrefix(AgentTurnWatchdogPolicy.resumePromptPrefix)
            }) { return }
            self.dispatchAgentMessage(for: runtime, text: prompt, images: [], source: .hostInstruction)
        }
    }
}
