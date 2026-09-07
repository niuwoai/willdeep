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
    /// How many times a turn that ended on dangling tool calls is resumed
    /// without the user. Two catches a transient; more would loop a turn that
    /// keeps breaking in the same place.
    static let maximumAutomaticResumes = 2
    /// First line of the resume instruction; used to deduplicate against a
    /// queued copy the same way the goal planner does.
    static let resumePromptPrefix = "=== TURN INTERRUPTED — RESUME ==="

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
        if runtime.isShowingWatchdogStallNotice {
            runtime.isShowingWatchdogStallNotice = false
            if runtime.errorSeverity == .notice {
                runtime.clearTurnError()
            }
        }
    }

    /// Runs on the scheduler tick. Raises the stall notice on runtimes that
    /// have gone quiet and leaves everything else alone.
    func scanAgentTurnsForStalls(now: Date = Date()) {
        for runtime in agentRuntimes.values {
            let blocking = runtime.toolCalls.contains { $0.status.isBlockingForUserDecision }
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
            runtime.errorMessage = L10n.TurnWatchdog.stalled(seconds: Int(idle), waitingOn: watchdogWaitDescription(for: runtime))
            runtime.errorDetails = nil
            runtime.errorSeverity = .notice
            runtime.isShowingWatchdogStallNotice = true
        }
    }

    private func watchdogWaitDescription(for runtime: AgentRuntime) -> String {
        if let running = runtime.toolCalls.last(where: { $0.status == .running }) {
            if running.toolName == "spawn_agent",
               let worker = running.subagentWorkerName ?? running.subagentLiveActivity?.workerName {
                return L10n.TurnWatchdog.waitingOnWorker(worker)
            }
            return L10n.TurnWatchdog.waitingOnTool(running.toolName)
        }
        return L10n.TurnWatchdog.waitingOnModel
    }

    /// Called from the turn's closing `defer`, after the loop has released
    /// its state but before the session is persisted. Detects a turn that
    /// broke on an unexecuted tool call, tells the user, and schedules one
    /// automatic resume.
    func noteAgentTurnEnded(for runtime: AgentRuntime, turnID: UUID) {
        runtime.isShowingWatchdogStallNotice = false
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
