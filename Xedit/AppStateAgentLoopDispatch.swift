//
//  AppStateAgentLoopDispatch.swift
//  WillDeep
//
//  Split out of AppStateAgentLoop.swift when that file crossed the 3000-line
//  hard limit in `scripts/complexity_guard.rb` (3046 lines), which fails the
//  gate on its first step and so stops the unit tests from running at all.
//
//  Owns `dispatchAgentMessage`: the entry point that turns a user message into
//  a turn — provider slot claim, runtime selection, the queued-message hand
//  off — and then calls `runAgentLoop`. Only the function moved; not one line
//  of its body changed. The loop itself stays in AppStateAgentLoop.swift,
//  where splitting further means carving up a 2600-line function body rather
//  than moving a whole declaration, and that is a refactor with real
//  regression risk, not a file move.
//

import AppKit
import Foundation

extension AppState {
    func dispatchAgentMessage(
        for runtime: AgentRuntime,
        text: String,
        images: [AgentImageAttachment],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        existingUserMessageID: AgentMessage.ID? = nil,
        source: AgentMessageSource = .operatorInput
    ) {
        guard magpieIntegrationHome != nil, agentLoopInferenceEnvironment == nil else {
            dispatchPreparedAgentMessage(for: runtime, text: text, images: images,
                textAttachments: textAttachments, attachedSkills: attachedSkills,
                existingUserMessageID: existingUserMessageID, source: source)
            return
        }
        let preparationID = UUID()
        magpieTurnPreparationIDs[runtime.id] = preparationID
        runtime.requestTask?.cancel()
        // The bounded read can take 100ms. The composer must treat that wait as
        // busy so another send queues instead of launching a duplicate turn.
        runtime.isResponding = true
        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            defer {
                if self.magpieTurnPreparationIDs[runtime.id] == preparationID {
                    self.magpieTurnPreparationIDs.removeValue(forKey: runtime.id)
                    runtime.isResponding = false
                    runtime.requestTask = nil
                    if runtime.errorMessage != nil || Task.isCancelled {
                        self.recordChildSessionCompletionIfNeeded(
                            for: runtime, wasUserStopped: Task.isCancelled
                        )
                    }
                }
            }
            do {
                try await self.prepareMagpieConnectionForTurn(runtime)
                try Task.checkCancellation()
                guard self.magpieTurnPreparationIDs[runtime.id] == preparationID else { return }
                self.magpieTurnPreparationIDs.removeValue(forKey: runtime.id)
                runtime.isResponding = false
                runtime.requestTask = nil
                self.dispatchPreparedAgentMessage(for: runtime, text: text, images: images,
                    textAttachments: textAttachments, attachedSkills: attachedSkills,
                    existingUserMessageID: existingUserMessageID, source: source)
            } catch {
                guard self.magpieTurnPreparationIDs[runtime.id] == preparationID else { return }
                if existingUserMessageID == nil {
                    runtime.messages.append(AgentMessage(role: .user, content: text, images: images,
                        textAttachments: textAttachments, source: source))
                }
                if !(error is CancellationError) {
                    runtime.errorMessage = error.localizedDescription
                    runtime.errorDetails = nil
                }
                runtime.session.automaticWakeSuppressedAfterUserStop = true
                self.persistAgentSession(runtime: runtime)
                self.recordRoutineRunCompletionIfNeeded(for: runtime)
            }
        }
    }

    private func dispatchPreparedAgentMessage(
        for runtime: AgentRuntime,
        text: String,
        images: [AgentImageAttachment],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        existingUserMessageID: AgentMessage.ID? = nil,
        source: AgentMessageSource = .operatorInput
    ) {
        if source != .operatorInput && dispatchContinuationIsSuspended(runtime) { return }
        do { runtime.runtimeParameters = try runtimeParametersForNewTurn() }
        catch {
            runtime.errorMessage = error.localizedDescription
            runtime.errorDetails = nil
            runtime.session.automaticWakeSuppressedAfterUserStop = true
            return
        }
        runtime.deepAdmissionObservation.deepCalls = 0
        applySharedGoalLimits(for: runtime)
        guard runtime.runtimeParameters != nil else { return }
        // A message — the user's or the host's — supersedes a Goal wait, even
        // one that has to queue for a provider slot first.
        cancelGoalWake(for: runtime, reason: "dispatch")
        runtime.currentTurnPlanningOnly = source == .operatorInput
            && AgentExecutionIntentPolicy.requestsPlanningOnly(text)
        // Slash-staged delegation directive applies to exactly this turn.
        let delegationPolicy: AgentDelegationPolicy = runtime.session.parentSessionID == nil
            ? runtime.resolvedComposerDelegationPolicy : .forbidden
        runtime.pendingDelegationPolicy = .automatic
        runtime.currentTurnDelegationPolicy = delegationPolicy
        runtime.currentTurnSpawnAgentCallCount = 0
        runtime.currentTurnAutoDispatchedCommands = []
        runtime.currentTurnAttemptedWorkerProfiles = []
        runtime.completedForegroundOpsInspection = false
        runtime.currentTurnEmittedReadOnlyHandoffHint = false
        runtime.currentTurnToolFailureCounts = [:]
        resetRepeatedCallGuardForDispatch(for: runtime, source: source)
        releaseFinishedForegroundWorker(for: runtime)
        // Classified from what the user actually typed. Tool-loop
        // continuations and system notices re-enter here with the same
        // runtime; routing those would classify WillDeep's own plumbing.
        // 操作员点名优先于一切分类：关键词和模型都是在猜，这条是明确指令。
        // 单槽位，消费即清空——点名只作用于这一回合。
        let pinnedWorker = runtime.pendingWorkerProfileID
        runtime.pendingWorkerProfileID = nil
        let routeDecision: AgentRequestRouter.Decision?
        if runtime.session.parentSessionID != nil {
            routeDecision = nil
        } else if source == .operatorInput, let pinnedWorker, delegationPolicy != .forbidden {
            routeDecision = AgentRequestRouter.pinnedDecision(profileID: pinnedWorker)
        } else {
            routeDecision = source == .operatorInput
                ? AgentRequestRouter.routedDecision(for: text, delegationPolicy: delegationPolicy,
                    sharedConfig: runtime.runtimeParameters?.routingConfig ?? AgentSharedRuntimeConfig())
                : nil
        }
        runtime.currentTurnRouteDecision = routeDecision
        runtime.currentTurnRouteSteering = routeDecision?.steering(for: delegationPolicy)
        if source == .operatorInput {
            runtime.session.automaticWakeSuppressedAfterUserStop = false
            runtime.consecutiveGoalRoundsWithoutChecklistProgress = 0
            // A human steering the session starts a fresh budget of automatic
            // runway resumes. The ceiling exists to stop an unattended loop,
            // not to ration what the user asks for directly.
            runtime.contextRunwayResumeCount = 0
            runtime.pendingContextRunwayResume = false
        }
        resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime)

        let shouldArmGoalRecovery = AgentGoalLaunchRecoveryPolicy.shouldArmExecutionCheckpoint(
            interactionMode: runtime.interactionMode,
            executionAgent: runtime.executionAgent,
            goal: runtime.currentGoal,
            plan: runtime.currentPlan
        )
        let didChangeGoalRecoveryCheckpoint: Bool
        if shouldArmGoalRecovery, runtime.goalTurnRecoveryCheckpoint == nil {
            runtime.goalTurnRecoveryCheckpoint = AgentGoalTurnRecoveryCheckpoint()
            didChangeGoalRecoveryCheckpoint = true
        } else if !shouldArmGoalRecovery, runtime.goalTurnRecoveryCheckpoint != nil {
            runtime.goalTurnRecoveryCheckpoint = nil
            didChangeGoalRecoveryCheckpoint = true
        } else {
            didChangeGoalRecoveryCheckpoint = false
        }

        if agentLoopInferenceEnvironment == nil {
            reconcileSomeIMProviderFromSharedSession()
            ensureActiveProviderIsUsableForChatSelection()
            repairSomeIMProviderCredentialsForTurnIfNeeded(for: runtime)
        }
        let configuration = configurationForCurrentTurn(for: runtime)
        let providerID = configuration.providerID

        // Show the user's message immediately — BEFORE the provider
        // concurrency gate. Pre-rc this append lived after the slot
        // check, so a message that couldn't grab a slot went into the
        // invisible `pendingDispatchQueue` while the composer cleared:
        // the user saw their text vanish with nothing in the transcript
        // ("like nothing happened"). Appending first guarantees the
        // message is always on screen; the queue only delays the network
        // call, never the display. On a drain re-dispatch the message is
        // already present, so reuse it via `existingUserMessageID`.
        //
        // Retire the previous turn's failure here rather than after the gates
        // below: the persist that follows this block is the one that reaches
        // disk, so clearing later would leave a stale `lastTurnFailure` in the
        // file (and a resurrected banner) whenever the new dispatch parks in
        // the provider queue instead of starting immediately.
        runtime.clearTurnError()
        let userMessage: AgentMessage
        if let existingUserMessageID,
           let existing = runtime.messages.first(where: { $0.id == existingUserMessageID }) {
            userMessage = existing
            if didChangeGoalRecoveryCheckpoint {
                persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            }
        } else {
            userMessage = AgentMessage(
                role: .user,
                content: text,
                images: images,
                textAttachments: textAttachments,
                source: source,
                delegationPolicy: delegationPolicy.isExplicit ? delegationPolicy : nil
            )
            runtime.messages.append(userMessage)
            runtime.latestTurnRecall = nil
            // A new user turn starts a fresh reporting window: last turn's
            // `update_plan` calls no longer outrank this turn's fences.
            runtime.planStepsSettledByToolThisTurn.removeAll()
            persistAgentSession(runtime: runtime)
        }

        // some.im login gate: a session created on 「省心托管」can outlive its
        // login (logout here or in another app sharing the Keychain group, or
        // an expired token). Sending anyway would fire an unauthenticated relay
        // request that returns an empty stream and gets silently dropped at the
        // "stream ended empty" branch below — the user sees no reply and no
        // error. Stop here with an actionable, re-sendable error instead. The
        // user's message is already on screen (appended above); we neither grab
        // a provider slot nor start a turn.
        guard !someIMLoginRequiredForTurn(for: runtime, providerID: providerID) else {
            runtime.isAwaitingProviderSlot = false
            runtime.goalTurnRecoveryCheckpoint = nil
            setSomeIMLoginRequiredError(for: runtime)
            persistAgentSession(runtime: runtime)
            // A routine that fires while logged out never starts a turn, so
            // nothing downstream would ever settle its run record.
            recordRoutineRunCompletionIfNeeded(for: runtime)
            return
        }

        // Concurrency gate: cap simultaneous turns per provider so a
        // routine fleet can't blow past the provider's rate limit. If
        // the slot isn't open, queue this dispatch — `releaseProviderSlot`
        // drains pending entries FIFO as turns finish. The message is
        // already visible above; we only defer the request here.
        guard acquireProviderSlotIfPossible(providerID: providerID) else {
            runtime.isAwaitingProviderSlot = true
            pendingDispatchQueue.append(
                PendingDispatch(
                    runtimeID: runtime.id,
                    userMessageID: userMessage.id,
                    text: text,
                    images: images,
                    textAttachments: textAttachments,
                    attachedSkills: attachedSkills,
                    providerID: providerID,
                    enqueuedAt: Date(),
                    source: source
                )
            )
            return
        }

        runtime.isAwaitingProviderSlot = false
        runtime.clearTurnError()
        runtime.latestComputerUseActivity = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()
        runtime.currentTurnAttachedSkills = attachedSkills
        let turnID = UUID()
        runtime.activeTurnID = turnID
        runtime.activeTurnConfiguration = configuration
        runtime.userStoppedTurnID = nil
        let providerSlotClaim = claimProviderSlot(for: runtime, providerID: providerID)

        // The user's message was already appended and persisted to disk
        // above, before the slot gate — so even if the turn hangs
        // (slow/flaky proxy) and the app is quit mid-flight, the on-disk
        // session already holds it even if the app quits mid-flight.
        // No second persist is needed here.
        let imageDescriptionConfiguration = agentConfiguration.normalized.imageDescription.agentConfiguration

        runtime.requestTask?.cancel()
        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self else { return }
            guard let runtime else {
                // The session can be deleted after claiming a provider slot
                // but before the Task starts. In that case runAgentLoop's
                // defer never executes, so release the slot here.
                self.releaseProviderSlot(providerID: providerID)
                return
            }
            do {
                try await self.prepareImagesForTextOnlyProvider(
                    for: runtime,
                    userMessageID: userMessage.id,
                    mainConfiguration: configuration,
                    imageDescriptionConfiguration: imageDescriptionConfiguration
                )
            } catch is CancellationError {
                guard runtime.activeTurnID == turnID else {
                    self.releaseProviderSlot(for: runtime, claimID: providerSlotClaim.id, providerID: providerID)
                    return
                }
                let shouldConsumeQueueAfterStop = runtime.shouldConsumeQueueAfterStop
                runtime.isResponding = false
                runtime.turnStartedAt = nil
                runtime.requestTask = nil
                if runtime.activeTurnID == turnID {
                    runtime.activeTurnID = nil
                    runtime.activeTurnConfiguration = nil
                    runtime.userStoppedTurnID = nil
                }
                runtime.goalTurnRecoveryCheckpoint = nil
                runtime.shouldConsumeQueueAfterStop = false
                self.persistAgentSession(runtime: runtime)
                self.releaseProviderSlot(
                    for: runtime,
                    claimID: providerSlotClaim.id,
                    providerID: providerID
                )
                if shouldConsumeQueueAfterStop {
                    self.consumeNextQueuedMessageIfNeeded(for: runtime)
                }
                return
            } catch {
                guard runtime.activeTurnID == turnID else {
                    self.releaseProviderSlot(for: runtime, claimID: providerSlotClaim.id, providerID: providerID)
                    return
                }
                if Self.isStoppedTurnCancellation(error, runtime: runtime, turnID: turnID) {
                    let shouldConsumeQueueAfterStop = runtime.shouldConsumeQueueAfterStop
                    runtime.isResponding = false
                    runtime.turnStartedAt = nil
                    runtime.requestTask = nil
                    runtime.activeTurnID = nil
                    runtime.activeTurnConfiguration = nil
                    runtime.userStoppedTurnID = nil
                    runtime.goalTurnRecoveryCheckpoint = nil
                    runtime.shouldConsumeQueueAfterStop = false
                    self.persistAgentSession(runtime: runtime)
                    self.releaseProviderSlot(
                        for: runtime,
                        claimID: providerSlotClaim.id,
                        providerID: providerID
                    )
                    if shouldConsumeQueueAfterStop {
                        self.consumeNextQueuedMessageIfNeeded(for: runtime)
                    }
                    return
                }
                self.setAgentError(error, for: runtime)
                runtime.isResponding = false
                runtime.turnStartedAt = nil
                runtime.requestTask = nil
                if runtime.activeTurnID == turnID {
                    runtime.activeTurnID = nil
                    runtime.activeTurnConfiguration = nil
                    runtime.userStoppedTurnID = nil
                }
                runtime.goalTurnRecoveryCheckpoint = nil
                self.persistAgentSession(runtime: runtime)
                // This path dies before `runAgentLoop` is ever entered, so its
                // defer — the usual place a routine run gets settled — never
                // runs. Without this the record would sit at `running` until
                // the next launch reconciled it into `interrupted`, hiding a
                // real failure behind a vaguer one.
                self.recordRoutineRunCompletionIfNeeded(for: runtime)
                self.releaseProviderSlot(
                    for: runtime,
                    claimID: providerSlotClaim.id,
                    providerID: providerID
                )
                self.consumeNextQueuedMessageIfNeeded(for: runtime)
                return
            }
            // Before the first provider call, not inside the tool loop: the
            // whole point is that the expensive model reads findings rather
            // than deriving them. The report folds into
            // currentTurnRouteSteering, which runAgentLoop reads when it
            // assembles the system prompt.
            if source == .operatorInput {
                // Keyword routing already produced a decision synchronously.
                // Only a genuinely ambiguous fallback may consult an already
                // warm local model before the optional preflight reads it.
                await self.refineRouteDecisionWithModelIfNeeded(
                    for: runtime,
                    requestText: text
                )
                // Privileged keyword routes get a second opinion, started now
                // and collected later. It runs alongside everything below and
                // the first provider request; nothing waits on it here.
                await self.startRouteVetoIfNeeded(for: runtime, requestText: text)
                // Design gate: decide whether this request wanted a written
                // design first. Records every decision to spec-gate.jsonl;
                // only interrupts when the operator turned enforcement on.
                // See docs/SPEC_FIRST_GATE_DESIGN.md.
                await self.evaluateSpecGate(for: runtime, requestText: text)
                // The serial preflight dispatches a worker from the routed
                // decision, so a veto that lands after it would be too late
                // to matter. Collect it here — this path is opt-in and
                // already synchronous, so the wait costs nothing the
                // operator has not already accepted. With the preflight off
                // (the default) the veto is collected at the tool boundary
                // instead and the first token is untouched.
                if runtime.runtimeParameters?.autoDispatchReadOnly == true {
                    await self.resolveRouteVetoIfPending(for: runtime)
                }
                let codingPlan = await self.runReadOnlyPreflightIfNeeded(
                    for: runtime,
                    requestText: text,
                    configuration: configuration,
                    userMessageID: userMessage.id
                )
                if let codingPlan {
                    let pipelineResult = await self.runAutomaticCodingPipelineIfEligible(
                        for: runtime,
                        requestText: text,
                        userMessageID: userMessage.id,
                        plan: codingPlan,
                        parentConfiguration: configuration
                    )
                    switch pipelineResult {
                    case .delivered(let message):
                        self.completeAutomaticCodingTurn(
                            for: runtime,
                            message: message,
                            configuration: configuration,
                            providerSlotClaimID: providerSlotClaim.id,
                            turnID: turnID
                        )
                        return
                    case .needsParent(let note):
                        runtime.currentTurnRouteSteering = [
                            runtime.currentTurnRouteSteering,
                            note,
                        ].compactMap { $0 }.joined(separator: "\n\n")
                    case .notEligible:
                        break
                    }
                }
                // The serial preflight (when enabled) already delivered its
                // findings above. Otherwise a read-only route gets its scout
                // in parallel with the first provider request: the root model
                // streams immediately and reads the report at a tool boundary.
                if codingPlan == nil {
                    self.startSpeculativeScoutIfEligible(
                        for: runtime,
                        requestText: text,
                        configuration: configuration,
                        userMessageID: userMessage.id
                    )
                }
            }
            await self.runAgentLoop(
                for: runtime,
                configuration: configuration,
                providerSlotClaimID: providerSlotClaim.id,
                turnID: turnID
            )
        }
    }
}
