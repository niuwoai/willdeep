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

    /// Visible silence long enough for tier-one reassurance, nil when the
    /// turn is either showing output or legitimately parked.
    static func quietSeconds(
        isResponding: Bool,
        isAwaitingProviderSlot: Bool,
        isCompressingContext: Bool,
        hasBlockingDecision: Bool,
        lastVisibleOutputAt: Date?,
        now: Date
    ) -> TimeInterval? {
        guard isResponding, !isAwaitingProviderSlot, !isCompressingContext, !hasBlockingDecision,
              let lastVisibleOutputAt else { return nil }
        let quiet = now.timeIntervalSince(lastVisibleOutputAt)
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
        now: Date
    ) -> TimeInterval? {
        guard isResponding, !isAwaitingProviderSlot, !isCompressingContext, !hasBlockingDecision,
              let lastActivityAt else { return nil }
        let idle = now.timeIntervalSince(lastActivityAt)
        return idle >= stallThreshold ? idle : nil
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

    /// Model-facing. Names the calls that were lost so the model re-issues
    /// them instead of assuming they ran.
    static func resumePrompt(danglingToolNames: [String]) -> String {
        let names = danglingToolNames.isEmpty ? "the last tool call" : danglingToolNames.map { "`\($0)`" }.joined(separator: ", ")
        return """
        \(resumePromptPrefix)
        The previous turn ended before \(names) produced a result; that call never ran. \
        Continue the task from where it stopped: re-issue the call if it is still needed, \
        otherwise proceed with the next step. Do not repeat work that already has results above.
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
            // Tier one: alive but showing nothing. Only ever changes the
            // strip label, and only publishes when the label would change.
            let isQuiet = AgentTurnWatchdogPolicy.quietSeconds(
                isResponding: runtime.isResponding,
                isAwaitingProviderSlot: runtime.isAwaitingProviderSlot,
                isCompressingContext: runtime.isCompressingContext,
                hasBlockingDecision: blocking,
                lastVisibleOutputAt: runtime.lastVisibleOutputAt,
                now: now
            ) != nil
            if isQuiet, let since = runtime.lastVisibleOutputAt {
                let reassurance = AgentQuietReassurance(
                    subject: watchdogStallSubject(for: runtime), since: since,
                    isOverdue: now.timeIntervalSince(since) >= AgentTurnWatchdogPolicy.stallThreshold
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
        let running = runtime.toolCalls.last(where: { $0.status == .running })
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
