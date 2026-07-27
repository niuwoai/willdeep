//
//  AppStateAgentLoop.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Owns the heavy Agent-mode runtime path:
//
//    - dispatchAgentMessage
//    - prepareImagesForTextOnlyProvider / describe helpers
//    - consumeNextQueuedMessageIfNeeded / clearAgentConversation
//    - tool-call approve / deny / always-allow / confirm / answer
//    - awaitToolDecision continuation + appendToolMessage
//    - runAgentLoop async streaming loop
//
//  Lives on AppState via extension so call sites in the chat UI and
//  routine scheduler keep writing appState.sendAgentMessage(),
//  appState.runAgentRoutineNow() etc. unchanged. A few private fields
//  on AppState were dropped to internal so this extension can touch
//  them (agentToolDecisionWaiter, agentRequestTask, isApplyingTabSnapshot,
//  knownModificationDates); none of them are visible outside the Xedit
//  target. Agent error presentation / retry policy lives in
//  AppStateAgentErrors.swift; context compression and patch application
//  live in AppStateAgentContextCompression.swift and
//  AppStateAgentPatches.swift. Provider dispatch gating lives in
//  AppStateAgentDispatchQueue.swift; request previews / token-window
//  estimates live in AppStateAgentRequestEstimates.swift.
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

        reconcileSomeIMProviderFromSharedSession()
        ensureActiveProviderIsUsableForChatSelection()
        repairSomeIMProviderCredentialsForTurnIfNeeded(for: runtime)
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
                source: source
            )
            runtime.messages.append(userMessage)
            runtime.latestTurnRecall = nil
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
                    enqueuedAt: Date()
                )
            )
            return
        }

        runtime.isAwaitingProviderSlot = false
        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.errorRequiresSomeIMLogin = false
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
                self.releaseProviderSlot(
                    for: runtime,
                    claimID: providerSlotClaim.id,
                    providerID: providerID
                )
                self.consumeNextQueuedMessageIfNeeded(for: runtime)
                return
            }
            await self.runAgentLoop(
                for: runtime,
                configuration: configuration,
                providerSlotClaimID: providerSlotClaim.id,
                turnID: turnID
            )
        }
    }

    func prepareImagesForTextOnlyProvider(
        for runtime: AgentRuntime,
        userMessageID: AgentMessage.ID,
        mainConfiguration: AgentConfiguration,
        imageDescriptionConfiguration: AgentConfiguration
    ) async throws {
        guard !mainConfiguration.supportsImageInput else { return }
        guard let index = runtime.messages.firstIndex(where: { $0.id == userMessageID }) else { return }
        let images = runtime.messages[index].images
        guard !images.isEmpty else { return }

        let description = try await describeImagesForTextOnlyProvider(
            images,
            configuration: imageDescriptionConfiguration
        )

        guard !Task.isCancelled,
              let liveIndex = runtime.messages.firstIndex(where: { $0.id == userMessageID }) else {
            return
        }
        runtime.messages[liveIndex].content = Self.contentByAppendingImageDescription(
            to: runtime.messages[liveIndex].content,
            description: description,
            imageCount: images.count,
            providerID: imageDescriptionConfiguration.providerID,
            model: imageDescriptionConfiguration.model
        )
        persistAgentSession(runtime: runtime)
    }

    func describeImagesForTextOnlyProvider(
        _ images: [AgentImageAttachment],
        configuration: AgentConfiguration
    ) async throws -> String {
        var lastError: Error?
        for candidate in imageDescriptionConfigurationCandidates(fallback: configuration) {
            do {
                return try await requestImageDescription(images, configuration: candidate)
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError {
            throw lastError
        }
        return try await requestImageDescription(images, configuration: configuration)
    }

    private func requestImageDescription(
        _ images: [AgentImageAttachment],
        configuration: AgentConfiguration
    ) async throws -> String {
        let normalized = configuration.normalized
        guard normalized.supportsImageInput else {
            throw AgentClientError.serverStatus(
                AgentProviderHTTPError(
                    statusCode: 400,
                    method: "POST",
                    url: normalized.baseURL,
                    providerID: normalized.providerID,
                    model: normalized.model,
                    requestSummary: "Image description provider does not support image input.",
                    requestBody: "(not sent)",
                    responseBody: "Choose an image-capable provider/model for Image Understanding."
                )
            )
        }

        let prompt = """
        Describe each attached image for a coding agent that cannot see images directly.
        Return concise but information-dense notes. For screenshots, include visible UI text, error messages, dialogs, file names, code snippets, tables, controls, layout, and anything likely relevant to debugging or implementation.
        If there are multiple images, number them as Image 1, Image 2, etc.
        """
        let message = AgentMessage(role: .user, content: prompt, images: images)
        let messages: [AgentMessage]
        if AgentLocalModelPrompting.prefersLocalLanguageInstruction(normalized) {
            messages = AgentLocalModelPrompting.messagesWithLanguageInstruction(
                systemPrompt: "You describe images for a coding agent.",
                userMessages: [message],
                configuration: normalized
            )
        } else {
            messages = [message]
        }
        let collector = CompressionSummaryCollector()
        try await AgentClient(configuration: normalized).streamChat(messages: messages) { event in
            if case .textDelta(let delta) = event {
                await collector.append(delta)
            }
        }
        let result = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw AgentClientError.invalidResponse
        }
        return result
    }

    nonisolated static func contentByAppendingImageDescription(
        to content: String,
        description: String,
        imageCount: Int,
        providerID: String,
        model: String
    ) -> String {
        let header = "[Image description generated by \(providerID) / \(model) for \(imageCount) attached image\(imageCount == 1 ? "" : "s")]"
        let block = "\(header)\n\(description)"
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? block : "\(content)\n\n\(block)"
    }

    func consumeNextQueuedMessageIfNeeded(for runtime: AgentRuntime) {
        // Wait for any in-flight compression to finish — otherwise the
        // user's queued message would race a compression that just got
        // kicked off in the same defer block.
        guard !runtime.isResponding, !runtime.isCompressingContext else { return }
        guard let next = runtime.queuedMessages.first else { return }
        runtime.queuedMessages.removeFirst()
        dispatchAgentMessageUsingSelectedExecutor(
            next.executionAgent,
            for: runtime,
            text: next.text,
            images: next.images,
            textAttachments: next.textAttachments,
            attachedSkills: next.attachedSkills,
            source: next.source
        )
    }

    /// Auto-resume the agent when a background `run_command` job finishes
    /// AFTER the turn that spawned it has already ended.
    ///
    /// Background completions are pull-based: they're queued into the
    /// registry's `pendingCompletionEvents` and only surfaced when
    /// `runAgentLoop` drains them at the top of a round. But the model
    /// typically says "I'll run this and check the results" and then ends
    /// its turn — so when the job (often a FAILURE) finishes seconds or
    /// minutes later, no turn is active to drain it, and the result just
    /// sits there until the user happens to send another message. From the
    /// user's side: "nothing happened." This kicks a fresh turn so the
    /// model actually sees the completion and reacts.
    ///
    /// An active turn already drains completions itself, so we only kick
    /// when the runtime is fully idle. Every guard that makes us bow out
    /// here has a matching re-trigger later, so a completion can never be
    /// stranded: `isResponding`/`requestTask` → the turn's defer resumes;
    /// `isAwaitingProviderSlot` → the queued dispatch drains completions
    /// at the top of its loop; `isCompressingContext` → compression's
    /// defer resumes; slot saturation → `releaseProviderSlot` sweeps all
    /// runtimes via `resumeAgentLoopsWithPendingBackgroundCompletions()`.
    /// (Never enqueue a phantom user message for this.)
    @MainActor
    func resumeAgentLoopForPendingBackgroundCompletions(for runtime: AgentRuntime) {
        guard !runtime.isResponding,
              !runtime.isAwaitingProviderSlot,
              !runtime.isCompressingContext,
              runtime.requestTask == nil else { return }
        guard hasPendingBackgroundWakeups(for: runtime) else { return }

        repairSomeIMProviderCredentialsForTurnIfNeeded(for: runtime)
        let configuration = configurationForCurrentTurn(for: runtime)
        let providerID = configuration.providerID
        guard acquireProviderSlotIfPossible(providerID: providerID) else { return }

        runtime.isAwaitingProviderSlot = false
        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.latestComputerUseActivity = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()
        let turnID = UUID()
        runtime.activeTurnID = turnID
        runtime.activeTurnConfiguration = configuration
        runtime.userStoppedTurnID = nil
        let providerSlotClaim = claimProviderSlot(for: runtime, providerID: providerID)

        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self else { return }
            guard let runtime else {
                self.releaseProviderSlot(providerID: providerID)
                return
            }
            await self.runAgentLoop(
                for: runtime,
                configuration: configuration,
                providerSlotClaimID: providerSlotClaim.id,
                turnID: turnID
            )
        }
    }

    /// True when any background channel has a finished-but-unsurfaced
    /// event for this runtime: shell jobs, media tasks, or subagent
    /// reports. All three ride the same top-of-round drain in
    /// `runAgentLoop`, so any of them justifies a wake-up turn.
    @MainActor
    func hasPendingBackgroundWakeups(for runtime: AgentRuntime) -> Bool {
        agentJobRegistry.pendingCompletionCount(forRuntime: runtime.id) > 0
            || agentMediaTaskRegistry.pendingCompletionCount(forRuntime: runtime.id) > 0
            || agentSubagentRegistry.pendingReportCount(forParentRuntime: runtime.id) > 0
            || !runtime.pendingWorkflowCompletionReportIDs.isEmpty
    }

    /// Sweep every live runtime and kick a wake-up turn for any with
    /// stranded background completions. Called from `releaseProviderSlot`
    /// so completions that lost the slot race (their resume bailed while
    /// another session held the slot) surface as soon as capacity frees
    /// up — without this, a job finishing for an idle session B while
    /// session A monopolizes the provider stayed silent forever.
    @MainActor
    func resumeAgentLoopsWithPendingBackgroundCompletions() {
        for runtime in agentRuntimes.values where hasPendingBackgroundWakeups(for: runtime) {
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }
    }

    func clearAgentConversation() {
        agentRequestTask?.cancel()
        if let runtime = activeRuntime {
            for cleanupTask in runtime.stopCleanupTasks.values {
                cleanupTask.cancel()
            }
            runtime.stopCleanupTasks.removeAll()
            runtime.activeTurnID = nil
            runtime.activeTurnConfiguration = nil
            runtime.userStoppedTurnID = nil
            cancelAllWorkflows(for: runtime)
            let runtimeID = runtime.id
            agentSubagentRegistry.cancelAll(forParentRuntime: runtimeID)
        }
        agentMessages.removeAll()
        agentPatchProposals.removeAll()
        activeRuntime?.clearLocalConfirmationPreview()
        agentToolCalls.removeAll()
        agentQueuedMessages.removeAll()
        agentPendingImages.removeAll()
        agentPendingTextAttachments.removeAll()
        activeRuntime?.latestComputerUseActivity = nil
        agentErrorMessage = nil
        agentErrorDetails = nil
        agentToolDecisionWaiter?.resume(returning: .denied(reason: "Conversation cleared"))
        agentToolDecisionWaiter = nil
        activeRuntime?.pendingToolDecisions.removeAll()
        isAgentResponding = false
        agentTurnStartedAt = nil
        persistActiveAgentSession()
    }

    /// Stable local key for a runtime's workspace, mirroring
    /// `AgentSession.workspaceSidebarGroupKey` but from the live runtime
    /// location. Fed only to `AgentWorkspaceIdentityStore` for local UUID
    /// lookup — never transmitted.
    // Not `private`: WorkflowEngine wiring in AppStateAgentWorkflows.swift builds
    // the same some.im context and needs this key.
    static func managedWorkspaceKey(for runtime: AgentRuntime) -> String {
        if let sidebarWorkspaceRootPath = runtime.session.sidebarWorkspaceRootPath,
           !sidebarWorkspaceRootPath.isEmpty {
            return sidebarWorkspaceRootPath
        }
        let location = runtime.workspaceLocation ?? runtime.workspaceRootPath.map { .local(path: $0) }
        switch location {
        case .local(let path):
            return path.isEmpty ? AgentSession.noWorkspaceSidebarGroupKey : path
        case .remote(let runtimeID, let path):
            return "remote:\(runtimeID.uuidString):\(RemotePathValidator.normalizedWorkspaceRoot(path))"
        case .none:
            return AgentSession.noWorkspaceSidebarGroupKey
        }
    }

    @MainActor
    func runAgentLoop(
        for runtime: AgentRuntime,
        configuration: AgentConfiguration,
        providerSlotClaimID: UUID,
        turnID: UUID
    ) async {
        // This turn just went live (isResponding was set true by the caller).
        // Refresh the same-checkout collision hint so the foreground composer
        // reflects a background session now working in its directory.
        refreshAgentWorkspaceCollision()
        _ = startAgentGoalPlanningIfNeeded(for: runtime)
        defer {
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
            // Turn finished — one fewer concurrent worker on this checkout.
            refreshAgentWorkspaceCollision()
            captureAgentPlanFromLatestMessage(for: runtime)
            let didDefineGoal = captureAgentGoalDefinitionFromLatestMessage(for: runtime)
            captureAgentGoalEvaluationFromLatestMessage(for: runtime)
            prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime)
            startAgentGoalPlanningAfterCaptureIfNeeded(didDefineGoal, for: runtime)
            persistAgentSession(runtime: runtime)
            if !shouldConsumeQueueAfterStop {
                maybeAutoCompressContext(for: runtime)
            }
            consumeNextQueuedMessageIfNeeded(for: runtime)
            // Always release the provider slot last so the queue drain
            // sees a fully cleared `isResponding` and won't refuse to
            // dispatch a queued user message that's for the same runtime.
            releaseProviderSlot(
                for: runtime,
                claimID: providerSlotClaimID,
                providerID: configuration.providerID
            )
            // A background job can finish in the tiny window between this
            // turn's last drain and its end. If one did — and no queued
            // user message just claimed the runtime above — kick a fresh
            // turn so the completion isn't stranded until the next message.
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }

        // some.im context headers (session id + workspace id) ride on every
        // some.im request this turn — main stream, route judge, model fetch.
        // Provider-gated in the adapter, so non-some.im providers never see them.
        let someIMContext: SomeIMRequestContext? = {
            guard configuration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
            )
            return SomeIMRequestContext(sessionID: runtime.id.uuidString, workspaceID: workspaceID)
        }()

        // "省心托管" dynamic routing. Resolved ONCE per user turn, BEFORE the
        // tool-call loop, so the whole loop reuses a single model — no
        // mid-turn re-judging that could desync tool_call pairing. The judge
        // shares this turn's already-held provider slot; `routeJudge` never
        // acquires/releases a slot and never throws, so the `defer` above
        // still owns every release path.
        var turnConfiguration = configuration
        var managedRouteDecision: AgentManagedRouteDecision?
        // The judge's explicit complexity verdict (nil on fallback turns).
        // Floor writes later in the turn — including the output-quality
        // escalation — must derive from this, never from a hedge-inflated
        // effective tier.
        var managedJudgeExplicitTier: AgentManagedCapabilityTier?
        if runtime.managedRouting != nil,
           configuration.providerID == AgentProviderPreset.someIMID {
            let floor = runtime.managedRouting?.minimumTier ?? .low
            // isOperatorInput: hidden host carriers (empty content, per-turn
            // context reminders) are `.user` role but must never stand in for
            // what the human actually asked — a wake-up turn would otherwise
            // send the judge an empty message.
            let latestOperatorMessage = runtime.messages.last(where: { $0.isOperatorInput })
            let judgeInput = SomeIMRouteJudgeInput(
                latestUserMessage: latestOperatorMessage?.content ?? "",
                hasImages: latestOperatorMessage?.images.isEmpty == false,
                hasTextAttachments: latestOperatorMessage?.textAttachments.isEmpty == false,
                workspaceAvailable: runtime.workspaceLocation != nil || (runtime.workspaceRootPath?.isEmpty == false),
                selectedFileLanguage: openedFileURL.flatMap { $0.pathExtension.isEmpty ? nil : $0.pathExtension },
                interactionMode: "\(runtime.interactionMode)",
                approvalMode: "\(runtime.approvalMode)",
                toolsEnabled: true,
                conversationSummary: runtime.contextSummary
            )
            let judgeClient = AgentClient(configuration: configuration, someIMContext: someIMContext)
            let hasCodingPlan = await refreshedSomeIMCodingPlanStatusIfNeeded().isActiveNow
            let resolution = await SomeIMManagedRouting.route(
                input: judgeInput,
                floor: floor,
                hasCodingPlan: hasCodingPlan
            ) { system, user, maxTokens in
                await judgeClient.routeJudge(
                    model: SomeIMManagedModel.judge,
                    systemPrompt: system,
                    userPayload: user,
                    maxTokens: maxTokens
                )
            }
            turnConfiguration.model = resolution.model
            runtime.noteManagedSelectedModel(resolution.model)
            managedRouteDecision = AgentManagedRouteDecision(
                selectedModel: resolution.model,
                tier: resolution.effectiveTier,
                domain: resolution.verdict.domain,
                complexity: resolution.verdict.complexity,
                didFallback: resolution.usedFallback
            )
            // Only a real judge verdict raises the persisted floor — a network
            // fallback must not lock the session into a high tier. Use the
            // judge's explicit tier, not `effectiveTier`: the low-confidence
            // conservative escalation applies to this turn's model choice only
            // and must never be written into the only-goes-up floor.
            if !resolution.usedFallback {
                managedJudgeExplicitTier = resolution.persistedFloorTier
                runtime.raiseManagedFloor(to: resolution.persistedFloorTier, reason: resolution.verdict.reason)
            }
        }
        if runtime.activeTurnID == turnID {
            runtime.activeTurnConfiguration = turnConfiguration
        }

        // `var` so a managed output-quality failure can swap in an escalated
        // client and re-run the round (see the no-tool-call guard below).
        var client = AgentClient(configuration: turnConfiguration, someIMContext: someIMContext)
        // Resolve the runtime's workspace path for tool execution —
        // never read AppState.rootDirectory here. Concurrent runtimes
        // can be running against different workspaces; the window's
        // current folder is a UI concept, not a session concept.
        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let workspaceURL: URL?
        do {
            workspaceURL = try runtime.localWorkspaceURLForOptimisticUse()
        } catch {
            runtime.errorMessage = error.localizedDescription
            runtime.errorDetails = nil
            runtime.messages.append(
                AgentMessage(
                    role: .assistant,
                    content: error.localizedDescription,
                    origin: .nativeModel
                )
            )
            return
        }
        let remoteRuntimeDescriptor: RuntimeDescriptor? = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let turnBaselineSnapshot = await Self.loadAgentWorktreeSnapshot(
            for: workspaceURL
        )
        if workspaceURL != nil {
            runtime.worktreeChanges = turnBaselineSnapshot.changes.filtering(paths: runtime.agentEditedPaths)
        }
        let memoryState = AgentMemoryState()
        defer {
            captureTurnEndLearning(
                for: runtime,
                memoryState: memoryState,
                workspaceURL: workspaceURL
            )
        }
        let memoryQuery = Self.memoryRetrievalQuery(
            messages: runtime.messages,
            openedFileURL: openedFileURL,
            selectedText: selectedText
        )
        let retrievedMemories = memoryState.retrieveMemories(
            query: memoryQuery,
            rootDirectory: workspaceURL,
            openedFileURL: openedFileURL,
            selectedText: selectedText
        )
        runtime.latestTurnRecall = Self.buildTurnRecallSnapshot(
            query: memoryQuery,
            retrievedMemories: retrievedMemories,
            attachedSkills: runtime.currentTurnAttachedSkills
        )
        let memoryContextBlock = AgentMemoryEngine.contextBlock(for: retrievedMemories)

        // Managed-routing output quality caps its escalation at one retry per
        // user turn (design doc §"重试限制").
        var didQualityRetry = false
        var planAutomaticContinuationCount = 0
        var consecutivePlanRepliesWithoutProgress = 0
        var didAdvancePlanSinceLastContinuationDecision = false
        let designToCodeToolCallBaseline = runtime.toolCalls.count
        let latestUserImages = runtime.messages.last(where: { $0.isOperatorInput })?.images ?? []
        let requiresDesignToCodeAcceptance = workspaceURL != nil && AgentDesignToCode.isActive(
            skills: runtime.currentTurnAttachedSkills,
            images: latestUserImages
        )
        var designToCodeGateContinuationCount = 0

        for toolRound in 0..<Self.maxAgentToolRounds {
            // `run_workflow` is asynchronous, but unlike the workflow card its
            // final report must return to the model that delegated the work.
            // Consume the owning runtime's pending ids into normal system
            // messages so every provider adapter receives the result without
            // exposing the raw card object itself.
            let finishedWorkflows = consumePendingWorkflowCompletions(for: runtime)
            for report in finishedWorkflows {
                runtime.messages.append(
                    AgentMessage(
                        role: .system,
                        content: Self.workflowCompletionNotice(for: report)
                    )
                )
            }

            // Background-job completion notices. Pulled at the top of
            // each round so the model sees any "job xyz finished"
            // notification right before it speaks — see
            // AgentBackgroundJobs.swift for the contract. We persist
            // these as `.system` messages so all four provider adapters
            // handle them (OpenAI-Chat accepts inline system; the
            // Anthropic adapter folds them into the top-level `system`
            // field; Gemini / Responses do the same coalescing).
            let pendingCompletions = agentJobRegistry.consumePendingCompletions(forRuntime: runtime.id)
            for finishedJob in pendingCompletions {
                // For jobs that need attention (failed / timed out / launch
                // failed) inline a secret-redacted tail of the captured
                // output so the model can diagnose the failure in this same
                // turn instead of spending a round calling get_job_output.
                // Success / killed jobs keep the lighter byte-count hint.
                let recentOutput: String? = {
                    guard finishedJob.needsAttention, finishedJob.outputByteCount > 0 else { return nil }
                    let tail = agentJobRegistry.output(id: finishedJob.id, tailLines: 40)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tail.isEmpty else { return nil }
                    let scrubbed = AgentSandboxPolicy.scrub(tail)
                    return scrubbed.count > 4000 ? "…" + String(scrubbed.suffix(4000)) : scrubbed
                }()
                runtime.messages.append(
                    AgentMessage(
                        role: .system,
                        content: Self.backgroundJobCompletionNotice(
                            for: finishedJob,
                            recentOutput: recentOutput
                        )
                    )
                )
            }

            let finishedMediaTasks = agentMediaTaskRegistry.consumePendingCompletions(forRuntime: runtime.id)
            for task in finishedMediaTasks {
                recordAgentMediaTaskCompletion(task: task, runtimeID: runtime.id)
                runtime.messages.append(
                    AgentMessage(
                        role: .system,
                        content: Self.mediaTaskCompletionNotice(for: task)
                    )
                )
            }
            // Completion is surfaced by the conversation's media summary
            // card. Do not steal the user's side panel while they are reading
            // or editing something else; the card opens the focused media
            // workspace on demand.

            // Background subagent reports ride the same channel as job
            // completions: queued by AgentSubagentRegistry, surfaced as
            // a system message at the top of the next round.
            let finishedSubagents = agentSubagentRegistry.consumePendingReports(forParentRuntime: runtime.id)
            for finishedRun in finishedSubagents {
                runtime.messages.append(
                    AgentMessage(
                        role: .system,
                        content: Self.subagentReportNotice(for: finishedRun)
                    )
                )
            }

            // 1.84.0-rc1: drain `show_widget` queue the same way. Each
            // queued AgentWidget becomes a `.widget` message; the card
            // view renders it inline in the transcript and the LLM
            // never sees the raw HTML again (clients all skip .widget).
            let pendingWidgets = AgentWidgetRegistry.shared.consumePending(forRuntime: runtime.id)
            for widget in pendingWidgets {
                runtime.messages.append(
                    AgentMessage(role: .widget, content: "", widget: widget)
                )
            }
            if !pendingWidgets.isEmpty, activeRuntime === runtime {
                agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
            }

            // schedule_task queue: each queued card becomes a `.scheduledTask`
            // message rendered inline. Same pipeline as widgets; the LLM never
            // sees it (all clients skip .scheduledTask).
            let pendingScheduledTasks = AgentScheduledTaskRegistry.shared.consumePending(forRuntime: runtime.id)
            for card in pendingScheduledTasks {
                runtime.messages.append(
                    AgentMessage(role: .scheduledTask, content: "", scheduledTask: card)
                )
            }

            // Bind every model request to the exact local Git state it was
            // allowed to reason about. A later guarded Git mutation compares
            // against this revision after approval and while holding the
            // repository lease. This is intentionally per model round, not
            // per user turn: edits from earlier tools in the same turn become
            // the next round's legitimate baseline.
            let roundWorkspaceRevision = await AgentWorkspaceRevisionCapture.capture(for: workspaceURL)

            let assistantMessage = AgentMessage(
                role: .assistant,
                content: "",
                origin: .nativeModel
            )
            runtime.messages.append(assistantMessage)
            let assistantID = assistantMessage.id
            // Stamp the wall-clock start so we can attach an elapsed
            // seconds value to the message footer once the stream
            // finishes. We use the moment we hand the request off to
            // the client — pre-network — because that's what the user
            // perceives as "how long did the agent take".
            let turnStartedAt = Date()

            // Build the system prompt against the runtime's workspace,
            // not whatever the window happens to be focused on. The
            // active tab / selection still come from AppState — that's
            // window-level context the user can flip while another
            // session is running, and the model just sees it as
            // "what's on screen right now".
            let promptProfile = AgentSystemPromptProfile.automatic(for: configuration)
            let activeExperts = runtime.activeExperts
            var assembledPrompt = AgentContextBuilder.systemPrompt(
                rootDirectory: workspaceURL,
                openedFileURL: openedFileURL,
                fileContent: fileContent,
                selectedText: selectedText,
                language: effectiveLanguage,
                toolsEnabled: true,
                interactionMode: runtime.interactionMode,
                executionAgent: runtime.executionAgent,
                approvalMode: runtime.approvalMode,
                currentPlan: runtime.currentPlan,
                currentGoal: runtime.currentGoal,
                goalPlanningState: runtime.goalPlanningState,
                currentSessionTitle: runtime.session.title,
                currentSessionTitleIsLocked: runtime.session.titleIsUserSet,
                activeExperts: activeExperts,
                promptProfile: promptProfile
            )
            if let remoteRuntimeDescriptor,
               case .remote(_, let remotePath) = workspaceLocation {
                let transportLabel = remoteRuntimeDescriptor.transport == .daemon ? "daemon" : "SSH"
                assembledPrompt += """

                === REMOTE WORKSPACE (\(transportLabel)) ===
                - Runtime: \(remoteRuntimeDescriptor.displayName) (\(remoteRuntimeDescriptor.sshTarget))
                - Platform: \(remoteRuntimeDescriptor.platform.displayName) / \(remoteRuntimeDescriptor.arch.displayName)
                - Remote root: \(remotePath)

                Not every tool runs on the remote box. Know the split before you act:

                RUN ON THE REMOTE RUNTIME (these reach \(remoteRuntimeDescriptor.sshTarget)):
                - search_files, grep_files, read_file, list_directory, git_status — read remote files.
                - run_command — executes on the remote box, in the remote root. This is your main hands-on tool here; use it for edits too (e.g. targeted `sed` / `perl` replacements, checked-in scripts, `git apply` with an existing patch file, explicit file transfer, or a small auditable heredoc/patch fallback when transfer tools such as rz/sz cannot be installed), inspecting processes, services, disk, logs. Avoid heredoc/here-string file creation as the first choice, but it is an allowed fallback when no safer auditable path exists.
                - claude_code / codex_cli / cursor_agent / cline_cli — the delegated CLI runs on the remote box (it must be installed there).

                RUN ON THE LOCAL MAC, NOT the remote box — do NOT use these to change or inspect the remote workspace:
                - create_file / edit_file / apply_patch — create or edit LOCAL files; they do NOT touch remote files. For remote file creation or edits use run_command.
                - terminal_snapshot / terminal_send_command / terminal_send_control / terminal_list_tabs / terminal_select_tab — drive the ACTIVE side-panel terminal tab, the one the user currently sees. It is a LOCAL shell by default (unless an SSH tab is active)\(remoteRuntimeDescriptor.transport == .daemon ? "; for a daemon runtime it can never reach the remote box" : ""). To run something on the remote box, use run_command, not the terminal tools.
                - skills / memory / MCP management (list_skills, read_skill, add_memory, create_user_skill, update_user_skill, delete_user_skill, search_mcp_servers, suggest_mcp_server, configure_mcp_server), chrome_*, computer_use_*, web_search, web_fetch, generate_image, visual_qa_screenshot, capture_screenshot — these are about the local WillDeep install / this Mac, not the remote host. web_fetch also can't reach the remote box's private/loopback services.

                Tell the user when an action is local vs remote if it matters.
                """
            }
            if activeExperts.contains(.shortDrama), let latestImageChoice = runtime.latestImageChoice {
                assembledPrompt += "\n\n\(latestImageChoice.systemPromptBlock)"
            }
            if let latestImageEditSubmission = runtime.latestImageEditSubmission {
                // Image-edit submission follow-up anchors live in AgentImageEditSubmission:
                // review_item_id: \(reviewItemID)
                // resolve_review_tool: short_drama_resolve_review_item
                // item_id=\(reviewItemID)
                assembledPrompt += "\n\n\(latestImageEditSubmission.systemPromptBlock)"
            }
            if let latestMediaTaskCompletion = runtime.latestMediaTaskCompletion {
                assembledPrompt += "\n\n\(latestMediaTaskCompletion.systemPromptBlock)"
            }
            if let latestMediaTaskRefresh = runtime.latestMediaTaskRefresh {
                assembledPrompt += "\n\n\(latestMediaTaskRefresh.systemPromptBlock)"
            }
            if let latestMediaImport = runtime.latestMediaImport {
                assembledPrompt += "\n\n\(latestMediaImport.systemPromptBlock)"
            }
            if let latestWidgetToolAction = runtime.latestWidgetToolAction {
                assembledPrompt += "\n\n\(latestWidgetToolAction.systemPromptBlock)"
            }
            if let memoryContextBlock {
                assembledPrompt += "\n\n\(memoryContextBlock)"
            }
            let promptComponents = AgentContextBuilder.requestComponents(from: assembledPrompt)
            // allowRefresh only on the dispatch's first round: rounds 2+ of
            // the same tool loop keep already-sent history byte-stable, and
            // mid-turn notices (plan continuation, design gate, background
            // completions) must not each spawn another full-context carrier.
            AgentContextBuilder.attachTurnContextIfNeeded(
                promptComponents.turnContext,
                to: &runtime.messages,
                insertingBefore: assistantID,
                allowRefresh: toolRound == 0
            )
            let systemPrompt = AgentLocalModelPrompting.applyLanguageInstruction(
                to: promptComponents.systemPrompt,
                configuration: configuration
            )
            let cacheDiagnostics = AgentContextBuilder.cacheDiagnostics(
                for: systemPrompt,
                toolsEnabled: true,
                promptProfile: promptProfile
            )
            if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                runtime.messages[index].requestPrefixHash = cacheDiagnostics.hash
                runtime.messages[index].requestStablePrefixCharacters = cacheDiagnostics.stableCharacters
            }
            let history = Self.modelFacingHistory(
                messages: runtime.messages,
                contextSummary: runtime.contextSummary,
                contextSummaryThroughMessageID: runtime.contextSummaryThroughMessageID,
                excludingMessageID: assistantID
            )
            // No second attach on the request copy: `attachTurnContextIfNeeded`
            // above already persisted this turn's context onto `runtime.messages`
            // (setting the fresh user message's modelContext, or inserting a
            // hidden host carrier on notification-only wake-ups), so the
            // model-facing history and the next turn's replay share bytes.
            let collapsedHistory = Self.collapseOldToolResults(in: history)
            let requestMessages = [AgentMessage(role: .system, content: systemPrompt)] + collapsedHistory

            var finishReason: String?
            var latestToolCalls: [AgentMessageToolCall] = []
            let streamBuffer = AgentStreamingMessageBuffer(runtime: runtime, assistantID: assistantID)

            do {
                var retryCount = 0
                while true {
                    do {
                        try await client.streamChat(
                            messages: requestMessages,
                            tools: AgentToolRegistry.tools(
                                activeExperts: activeExperts,
                                interactionMode: runtime.interactionMode,
                                executionAgent: runtime.executionAgent
                            )
                        ) { event in
                            await MainActor.run { [weak runtime] in
                                guard let runtime,
                                      let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
                                    return
                                }
                                switch event {
                                case .textDelta(let delta):
                                    streamBuffer.appendTextDelta(delta)
                                case .reasoningDelta(let delta):
                                    streamBuffer.appendReasoningDelta(delta)
                                case .toolCallsUpdated(let calls):
                                    streamBuffer.flushPending()
                                    runtime.messages[index].toolCalls = calls
                                    latestToolCalls = calls
                                case .finishedTurn(let reason):
                                    streamBuffer.flushPending()
                                    finishReason = reason
                                case .usageReported(let prompt, let completion, let total, let cachedPrompt, let cacheWritePrompt, let reasoning):
                                    streamBuffer.flushPending()
                                    runtime.messages[index].usageTokens = total
                                    runtime.messages[index].promptTokens = prompt > 0 ? prompt : nil
                                    runtime.messages[index].completionTokens = completion > 0 ? completion : nil
                                    runtime.messages[index].cachedPromptTokens = cachedPrompt
                                    runtime.messages[index].cacheWritePromptTokens = cacheWritePrompt
                                    runtime.messages[index].reasoningTokens = reasoning > 0 ? reasoning : nil
                                }
                            }
                        }
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        streamBuffer.flushPending()
                        guard shouldRetryTransientGoalNetworkError(
                            error,
                            for: runtime,
                            assistantID: assistantID,
                            retryCount: retryCount
                        ) || shouldRetryTLSHandshakeError(
                            error,
                            for: runtime,
                            assistantID: assistantID,
                            retryCount: retryCount
                        ) else {
                            throw error
                        }
                        retryCount += 1
                        let retryDelay = Self.isTLSHandshakeError(error)
                            ? Self.tlsHandshakeRetryDelayNanoseconds
                            : Self.goalTransientNetworkRetryDelayNanoseconds
                        try await Task.sleep(nanoseconds: retryDelay)
                    }
                }
                streamBuffer.flushPending()
            } catch is CancellationError {
                streamBuffer.flushPending()
                finalizeInterruptedAssistantMessage(
                    id: assistantID,
                    in: runtime,
                    startedAt: turnStartedAt
                )
                return
            } catch {
                streamBuffer.flushPending()
                if Self.isStoppedTurnCancellation(error, runtime: runtime, turnID: turnID) {
                    finalizeInterruptedAssistantMessage(
                        id: assistantID,
                        in: runtime,
                        startedAt: turnStartedAt
                    )
                    return
                }
                setAgentError(error, for: runtime)
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty {
                    runtime.messages.remove(at: index)
                    AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
                }
                return
            }

            // Snapshot the assistant's final tool_calls list (the .toolCallsUpdated
            // closure may not have published the very last fragment yet if the
            // stream ended on the same chunk).
            if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                if latestToolCalls.isEmpty {
                    latestToolCalls = runtime.messages[index].toolCalls
                } else {
                    runtime.messages[index].toolCalls = latestToolCalls
                }
                runtime.messages[index].elapsedSeconds = Date().timeIntervalSince(turnStartedAt)
                runtime.messages[index].managedRoute = managedRouteDecision
            }

            // A tool-using model round can already contain the progress for
            // the previous tool results. Apply it before running the next
            // calls so completed steps visibly tick off during long plans,
            // rather than waiting for the final prose-only reply.
            if !latestToolCalls.isEmpty {
                let statusesBeforeRound = runtime.currentPlan?.steps.map(\.status)
                captureAgentPlanFromLatestMessage(for: runtime)
                let statusesAfterRound = runtime.currentPlan?.steps.map(\.status)
                if statusesBeforeRound != statusesAfterRound {
                    didAdvancePlanSinceLastContinuationDecision = true
                }
            }

            // No tool calls → assistant finished talking. Capture patches and return.
            guard !latestToolCalls.isEmpty else {
                // Phase 2: managed-routing output quality check + single
                // escalation retry. Only for a managed some.im turn that
                // produced text, hasn't already retried, and can still climb a
                // tier. On failure we discard this output and re-run the round
                // one tier up: the outer loop rebuilds provider-ready history
                // from `runtime.messages` (excluding the removed message), so a
                // retry that emits tool calls flows into the tool path and
                // history stays intact. The judge shares this turn's slot.
                if !didQualityRetry,
                   runtime.managedRouting != nil,
                   configuration.providerID == AgentProviderPreset.someIMID,
                   let escalatedModel = SomeIMManagedModel.escalated(from: turnConfiguration.model),
                   let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   !runtime.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       || !(runtime.messages[index].reasoningContent ?? "").isEmpty {
                    let assistantText = runtime.messages[index].content
                    let reasoningText = runtime.messages[index].reasoningContent
                    let latestUserMessage = runtime.messages.last(where: { $0.isOperatorInput })?.content ?? ""
                    let qualityConfig = turnConfiguration
                    let qualityContext = someIMContext
                    let decision = await SomeIMManagedRouting.outputQuality(
                        assistantText: assistantText,
                        reasoningText: reasoningText,
                        latestUserMessage: latestUserMessage,
                        model: turnConfiguration.model,
                        finishReason: finishReason
                    ) { system, user, maxTokens in
                        await AgentClient(configuration: qualityConfig, someIMContext: qualityContext)
                            .routeJudge(
                                model: SomeIMManagedModel.judge,
                                systemPrompt: system,
                                userPayload: user,
                                maxTokens: maxTokens
                            )
                    }
                    if decision.shouldRetry {
                        didQualityRetry = true
                        if let dropIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                            runtime.messages.remove(at: dropIndex)
                        }
                        turnConfiguration.model = escalatedModel
                        client = AgentClient(configuration: turnConfiguration, someIMContext: someIMContext)
                        let escalatedTier = SomeIMManagedModel.tier(of: escalatedModel)
                        if let escalatedTier {
                            // Cap the persisted floor at one step above the
                            // judge's EXPLICIT verdict. The retry model itself
                            // may climb from a hedge-inflated tier (low judged
                            // with low confidence → turn ran high → retry runs
                            // premium), but locking the session at premium when
                            // the judge never said high defeats the
                            // hedge-stays-per-turn rule.
                            let floorTier: AgentManagedCapabilityTier
                            if let judgeTier = managedJudgeExplicitTier {
                                floorTier = min(escalatedTier, judgeTier.next ?? judgeTier)
                            } else {
                                floorTier = escalatedTier
                            }
                            runtime.raiseManagedFloor(to: floorTier, reason: "output-quality:\(decision.failureType)")
                        }
                        runtime.noteManagedSelectedModel(escalatedModel)
                        // Carry the escalation into this turn's route metadata so
                        // the retried message's footer shows the climbed tier.
                        managedRouteDecision?.didEscalate = true
                        managedRouteDecision?.failureType = decision.failureType
                        managedRouteDecision?.selectedModel = escalatedModel
                        if let escalatedTier {
                            managedRouteDecision?.tier = escalatedTier
                        }
                        continue
                    }
                }
                if requiresDesignToCodeAcceptance,
                   designToCodeGateContinuationCount < AgentDesignToCode.maximumGateContinuations,
                   let notice = AgentDesignToCode.completionGateNotice(
                       toolCalls: runtime.toolCalls.dropFirst(designToCodeToolCallBaseline)
                   ) {
                    designToCodeGateContinuationCount += 1
                    if let dropIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                        runtime.messages.remove(at: dropIndex)
                    }
                    runtime.messages.append(AgentMessage(role: .system, content: notice))
                    continue
                }
                attachRecentGeneratedToolImages(to: assistantID, in: runtime)
                captureAgentPatchProposals(for: runtime, fromMessageID: assistantID)
                // A stream can end "successfully" having produced nothing
                // (provider hiccup, content filter, empty stop). Drop the
                // placeholder like the error/cancel paths do — if it stays
                // in history, the next request encodes it as a bare
                // {"role":"assistant"} and the server rejects with 400.
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].images.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty,
                   (runtime.messages[index].reasoningContent ?? "").isEmpty {
                    runtime.messages.remove(at: index)
                    AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
                    // Zero-event streams already throw `emptyStream` from the
                    // adapter and surface via the catch path. This is the
                    // other empty case — the stream finished cleanly but the
                    // model produced nothing at all. Never leave dead air:
                    // reuse the same actionable, retryable error so the user
                    // always gets feedback instead of a silent no-reply.
                    setAgentError(
                        AgentClientError.emptyStream(
                            providerID: configuration.providerID,
                            model: turnConfiguration.model
                        ),
                        for: runtime
                    )
                    return
                }

                let planStatusesBeforeReply = runtime.currentPlan?.steps.map(\.status)
                let planCaptureOutcome = captureAgentPlanFromLatestMessage(for: runtime)
                if planCaptureOutcome == .proposalRejectedNeedsRetry {
                    // A correction notice listing the validation failures was
                    // appended; give the model an immediate round to resend
                    // the proposal instead of ending the turn deadlocked.
                    continue
                }
                captureAgentGoalEvaluationFromLatestMessage(for: runtime)
                prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime)
                let planStatusesAfterReply = runtime.currentPlan?.steps.map(\.status)
                if didAdvancePlanSinceLastContinuationDecision
                    || planStatusesBeforeReply != planStatusesAfterReply {
                    consecutivePlanRepliesWithoutProgress = 0
                } else {
                    consecutivePlanRepliesWithoutProgress += 1
                }
                didAdvancePlanSinceLastContinuationDecision = false

                switch AgentPlanAutoContinuationPolicy.decision(
                    for: runtime.currentPlan,
                    automaticContinuationCount: planAutomaticContinuationCount,
                    consecutiveNoProgressReplies: consecutivePlanRepliesWithoutProgress,
                    hasQueuedUserMessages: !runtime.queuedMessages.isEmpty
                ) {
                case .continueExecution:
                    planAutomaticContinuationCount += 1
                    runtime.messages.append(
                        AgentMessage(
                            role: .system,
                            content: AgentPlanAutoContinuationPolicy.continuationNotice(
                                finishReason: finishReason
                            )
                        )
                    )
                    continue
                case .pauseAfterNoProgress:
                    runtime.errorMessage = "Plan 自动续跑已暂停：连续两轮没有检测到步骤进展。请检查计划，或补充说明后继续。"
                    runtime.errorDetails = nil
                case .pauseAfterLimit:
                    runtime.errorMessage = "Plan 自动续跑已达到 8 轮安全上限。请检查当前产物与步骤状态后继续。"
                    runtime.errorDetails = nil
                case .stop:
                    break
                }
                return
            }

            // Execute every tool call, gating on the user when necessary.
            var anyDenied = false
            var changedWorkspacePath: String?
            // Git status refreshes are coalesced: instead of one blocking
            // `git status` subprocess after EVERY write-ish tool (a round
            // with six edits paid six), non-artifact refreshes set this flag
            // and run once after the round's tools finish. Attribution is
            // unchanged — the diff is always taken against the same
            // turn-level baseline.
            var roundNeedsGitStatusRefresh = false

            // Stage 1 — surface the whole round before running any of it.
            // Every tool call is parsed, risk-classified, auto-approval-
            // resolved, and appended to the transcript up front, so all the
            // approval cards this round needs light up at once (and can be
            // resolved in one click via 全部允许) instead of appearing one by
            // one as each earlier call finishes. Execution stays strictly
            // sequential in stage 2 below; decisions submitted ahead of
            // execution are parked in `runtime.pendingToolDecisions` and
            // consumed by `awaitToolDecision`'s fast path.
            struct StagedRoundToolCall {
                let call: AgentMessageToolCall
                let arguments: [String: AgentJSONValue]
                let risk: AgentToolRisk
                let sandboxDecision: AgentSandboxDecision
                let autoApproval: AgentToolApprovalSource?
                let recordID: AgentToolCall.ID
            }
            var stagedCalls: [StagedRoundToolCall] = []
            for call in latestToolCalls {
                // Parse argumentsJSON into a dict for downstream risk/dispatch.
                // The model occasionally emits malformed JSON (especially on
                // partial streams or wrong tool schemas). Pre-rc37 we
                // silently degraded to `[:]`, which meant the tool ran with
                // zero arguments and produced confusing failures further
                // downstream. Now: empty body is treated as `{}`; a
                // structurally-valid object is used as-is; anything else is
                // surfaced as an explicit `.failed` tool call so the
                // assistant can see the malformed payload it produced and
                // re-emit a fixed call.
                let argsDict: [String: AgentJSONValue]
                if call.argumentsJSON.isEmpty {
                    argsDict = [:]
                } else {
                    let decoded = AgentJSONValue.decode(from: call.argumentsJSON)
                    if case .object(let dict) = decoded {
                        argsDict = dict
                    } else {
                        let record = AgentToolCall(
                            messageID: assistantID,
                            externalID: call.externalID,
                            toolName: call.toolName,
                            arguments: [:],
                            risk: .read,
                            status: .failed,
                            approvalSource: nil
                        )
                        var failed = record
                        failed.errorMessage = "Invalid JSON in tool arguments"
                        runtime.toolCalls.append(failed)
                        appendToolMessage(
                            for: runtime,
                            toolCallID: call.externalID,
                            payload: "Tool arguments JSON could not be parsed; re-emit the call with valid JSON. Raw payload: \(call.argumentsJSON.prefix(400))",
                            outcomeStatus: .failed,
                            errorMessage: failed.errorMessage
                        )
                        continue
                    }
                }

                // Goal mode must stay autonomous. Workspace rebinding is not
                // advertised there; this is the final guard for stale
                // provider schemas or hallucinated calls. Session rename is
                // allowed and auto-approved below so the chat title can keep
                // up with a long-running goal without pausing it.
                if runtime.interactionMode == .goal,
                   call.toolName == "change_workspace" {
                    let blocked = AgentToolCall(
                        messageID: assistantID,
                        externalID: call.externalID,
                        toolName: call.toolName,
                        arguments: argsDict,
                        risk: .write,
                        status: .denied,
                        approvalSource: nil
                    )
                    var record = blocked
                    record.errorMessage = "Unavailable in Goal mode"
                    runtime.toolCalls.append(record)
                        appendToolMessage(
                            for: runtime,
                            toolCallID: call.externalID,
                            payload: "Unavailable in Goal mode: workspace change is suppressed so the active goal cannot be paused. Continue working in the current workspace.",
                            source: .systemNotice,
                            outcomeStatus: .denied,
                            errorMessage: record.errorMessage
                    )
                    continue
                }

                let risk = AgentToolRegistry.risk(
                    for: call.toolName,
                    arguments: argsDict,
                    rootDirectory: workspaceURL
                )
                let sandboxDecision = AgentSandboxPolicy.decision(
                    toolName: call.toolName,
                    arguments: argsDict,
                    rootDirectory: workspaceURL
                )

                let autoApproval = await autoApprovalSource(
                    toolName: call.toolName,
                    arguments: argsDict,
                    risk: risk,
                    rootDirectory: workspaceURL,
                    interactionMode: runtime.interactionMode,
                    approvalMode: runtime.approvalMode,
                    conversationAllowedToolSignatures: runtime.conversationAllowedToolSignatures
                )
                let isAlwaysAllowed = autoApproval != nil
                let initialStatus: AgentToolCallStatus
                if isAlwaysAllowed {
                    initialStatus = .running
                } else {
                    switch risk {
                    case .read: initialStatus = .running
                    case .write: initialStatus = .pendingApproval
                    case .danger: initialStatus = .awaitingConfirm
                    case .userInput: initialStatus = .awaitingUserAnswer
                    }
                }

                var displayArgsDict = argsDict
                if call.toolName == "run_command",
                   let remoteRuntimeDescriptor,
                   case .remote(_, let remotePath) = workspaceLocation {
                    displayArgsDict["_runtime"] = .string("\(remoteRuntimeDescriptor.displayName) (\(remoteRuntimeDescriptor.sshTarget))")
                    displayArgsDict["_cwd"] = .string(remotePath)
                }
                if call.toolName == "run_command" || sandboxDecision.mode == .escalated {
                    displayArgsDict["_sandbox"] = .string(sandboxDecision.mode.rawValue)
                    displayArgsDict["_approval_reason"] = .string(sandboxDecision.reason)
                    if let prefixRule = sandboxDecision.prefixRule, !prefixRule.isEmpty {
                        displayArgsDict["_prefix_rule"] = .string(prefixRule.joined(separator: " "))
                    }
                }

                let record = AgentToolCall(
                    messageID: assistantID,
                    externalID: call.externalID,
                    toolName: call.toolName,
                    arguments: displayArgsDict,
                    risk: risk,
                    status: initialStatus,
                    approvalSource: autoApproval
                )
                runtime.toolCalls.append(record)
                let recordID = record.id

                // rc2: if the user isn't looking at the app when a tool
                // call needs them (approve / confirm / answer), surface
                // a system banner so they don't sit on a stalled turn.
                // No-op when the app is the active foreground app or
                // when the call auto-ran via .running.
                AgentToolApprovalNotifier.notifyIfBackgrounded(
                    toolName: record.toolName,
                    arguments: record.arguments,
                    status: initialStatus
                )

                // Plan approval gate blocks writes until the user approves,
                // while still allowing validated public web GETs needed to
                // research that plan. Blocked calls go back as tool errors so
                // the model knows to stop and emit a plan. Resolved during
                // staging (synchronously, right after the record is appended)
                // so a gated call never sits on screen as an approvable card.
                // `ask_user` is exempt exactly as in the old serial flow,
                // where its handler ran ahead of this gate.
                if risk != .userInput,
                   Self.planGateBlocks(
                    toolName: call.toolName,
                    arguments: argsDict,
                    risk: risk,
                    isActive: runtime.isPlanGateActive
                ) {
                    anyDenied = true
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Plan approval required"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Blocked: no current plan has explicit user approval. Complete the required planning flow, then stop and wait for approval.",
                        source: .systemNotice,
                        outcomeStatus: .denied,
                        errorMessage: "Plan approval required"
                    )
                    continue
                }

                stagedCalls.append(StagedRoundToolCall(
                    call: call,
                    arguments: argsDict,
                    risk: risk,
                    sandboxDecision: sandboxDecision,
                    autoApproval: autoApproval,
                    recordID: recordID
                ))
            }

            // Stage 2 — run the staged calls strictly in order, waiting on
            // each pending user decision individually. A decision the user
            // already submitted (per card, or via the batch 全部允许 action)
            // is consumed instantly by `awaitToolDecision`'s fast path.
            //
            // Because staging pre-created records for calls that have not
            // executed yet (including auto-approved ones already showing
            // `.running`), every early exit out of this loop must settle the
            // unexecuted remainder — otherwise a cancelled turn leaves
            // zombie spinner/approval cards behind. In the old serial flow
            // those records simply did not exist yet.
            func settleUnexecutedStagedCalls(from index: Int, reason: String) {
                guard index < stagedCalls.count else { return }
                for pending in stagedCalls[index...] {
                    runtime.pendingToolDecisions.removeValue(forKey: pending.recordID)
                    guard let recordIndex = runtime.toolCalls.firstIndex(where: { $0.id == pending.recordID }) else {
                        continue
                    }
                    let status = runtime.toolCalls[recordIndex].status
                    if status == .running || status.isBlockingForUserDecision {
                        runtime.toolCalls[recordIndex].status = .denied
                        runtime.toolCalls[recordIndex].errorMessage = reason
                    }
                }
            }
            // Consecutive read-tier staged calls collected for concurrent
            // execution. The system prompt already tells the model to batch
            // independent reads into one reply; honoring that with a fan-out
            // turns N sequential grep/read round-trips into one. Records
            // were appended during staging, so collection here only defers
            // execution — order in `runtime.toolCalls` is already fixed.
            var pendingParallelReads: [AgentPendingParallelRead] = []
            // Shared AgentToolContext builder for the concurrent read batch
            // and the serial path below. Captures this round's workspace
            // binding plus the `changedWorkspacePath` slot the
            // workspace-change sink writes into.
            func makeToolContext(
                sandboxMode: AgentSandboxMode,
                patchAutoApplySource: AgentToolApprovalSource?
            ) -> AgentToolContext {
                AgentToolContext(
                    rootDirectory: workspaceURL,
                    workspaceLocation: workspaceLocation,
                    runtimeDescriptor: remoteRuntimeDescriptor,
                    runtimeID: runtime.id,
                    turnID: runtime.activeTurnID,
                    jobRegistry: agentJobRegistry,
                    mediaTaskRegistry: agentMediaTaskRegistry,
                    shortDramaStore: agentShortDramaStore,
                    sessionQueueSnapshotProvider: {
                        AgentSessionQueueSnapshot(
                            queuedMessages: runtime.queuedMessages,
                            pendingDispatches: self.pendingDispatchQueue
                                .filter { $0.runtimeID == runtime.id }
                                .map { entry in
                                    AgentQueuedDispatchSnapshot(
                                        userMessageID: entry.userMessageID,
                                        text: entry.text,
                                        imageCount: entry.images.count,
                                        textAttachmentCount: entry.textAttachments.count,
                                        skillCount: entry.attachedSkills.count,
                                        providerID: entry.providerID,
                                        enqueuedAt: entry.enqueuedAt
                                    )
                                }
                        )
                    },
                    workspaceSessionsSnapshotProvider: {
                        self.workspaceSessionSnapshots(for: runtime)
                    },
                    sessionTitleSuggestionProvider: {
                        await self.sessionTitleSuggestionSnapshot(for: runtime)
                    },
                    sandboxMode: sandboxMode,
                    patchProposalSink: { title, diff, applyImmediately in
                        let proposal = try self.enqueueAgentPatchProposal(
                            for: runtime,
                            messageID: assistantID,
                            title: title,
                            diff: diff,
                            autoApplySource: patchAutoApplySource,
                            applyImmediately: applyImmediately
                        )
                        return await self.awaitAgentPatchDecision(proposal, runtime: runtime)
                    },
                    // edit_file matches old_string against the same content
                    // the patch applier will later apply to (open tab buffer
                    // first, then disk) so tab-vs-disk drift can't break it.
                    editableContentProvider: { url in
                        try self.editableContent(forAgentPatchURL: url)
                    },
                    patchAutoApplySource: patchAutoApplySource,
                    terminalController: agentTerminalController,
                    sessionRenameSink: { title in
                        try self.renameAgentSessionAfterApproval(
                            runtimeID: runtime.id,
                            to: title
                        )
                    },
                    workspaceChangeSink: { path in
                        let appliedPath = try self.changeAgentSessionWorkspaceAfterApproval(
                            runtimeID: runtime.id,
                            to: path
                        )
                        changedWorkspacePath = appliedPath
                        return appliedPath
                    }
                )
            }
            for (stagedIndex, staged) in stagedCalls.enumerated() {
                let call = staged.call
                let argsDict = staged.arguments
                let risk = staged.risk
                let sandboxDecision = staged.sandboxDecision
                let autoApproval = staged.autoApproval
                let isAlwaysAllowed = autoApproval != nil
                let recordID = staged.recordID

                // Fan out consecutive read-tier calls instead of paying each
                // one serially. Only whitelisted pure local workspace reads
                // qualify: they always auto-run (`.read` never awaits an
                // approval card or the plan gate) and never enter the
                // sandbox-escalation flow, which prompts through the single
                // per-runtime decision waiter that concurrent calls must not
                // share. Remote workspaces stay serial so the SSH backend
                // never sees interleaved requests.
                if changedWorkspacePath == nil,
                   remoteRuntimeDescriptor == nil,
                   risk == .read,
                   Self.parallelReadBatchToolNames.contains(call.toolName) {
                    pendingParallelReads.append(
                        AgentPendingParallelRead(
                            externalID: call.externalID,
                            toolName: call.toolName,
                            arguments: argsDict,
                            sandboxDecision: sandboxDecision,
                            recordID: recordID,
                            context: makeToolContext(
                                sandboxMode: sandboxModeForToolExecution(
                                    risk: risk,
                                    approvalSource: autoApproval,
                                    sandboxDecision: sandboxDecision
                                ),
                                patchAutoApplySource: nil
                            )
                        )
                    )
                    continue
                }

                // Anything not batched settles the pending reads first so
                // tool messages keep the model's original call order.
                if await executeParallelReadBatch(&pendingParallelReads, runtime: runtime) {
                    settleUnexecutedStagedCalls(from: stagedIndex, reason: "Response stopped")
                    return
                }

                // A successful workspace rebind invalidates the root captured
                // for this model round. Answer every remaining tool_call so
                // provider history stays structurally valid, but do not run it
                // against either the stale or newly rebound directory. The
                // record already exists from staging — settle it in place,
                // dropping any decision the user parked on it early.
                if let changedWorkspacePath {
                    runtime.pendingToolDecisions.removeValue(forKey: recordID)
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Skipped after workspace change"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Skipped: the workspace changed to \(changedWorkspacePath). Continue with workspace tools after the user's next message.",
                        source: .systemNotice,
                        outcomeStatus: .denied,
                        errorMessage: "Skipped after workspace change"
                    )
                    continue
                }

                if risk == .userInput {
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    if Task.isCancelled {
                        settleUnexecutedStagedCalls(from: stagedIndex, reason: "Cancelled")
                        return
                    }
                    let answer: String
                    switch decision {
                    case .answered(let typed):
                        answer = typed
                    case .denied(let reason):
                        anyDenied = true
                        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                            runtime.toolCalls[index].status = .denied
                            runtime.toolCalls[index].errorMessage = reason
                        }
                        appendToolMessage(
                            for: runtime,
                            toolCallID: call.externalID,
                            payload: "User skipped the question.",
                            source: .systemNotice,
                            outcomeStatus: .denied,
                            errorMessage: reason
                        )
                        continue
                    case .approved:
                        answer = ""
                    }
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .succeeded
                        runtime.toolCalls[index].result = AgentToolResult(
                            summary: answer.isEmpty ? "(no answer)" : "answered",
                            payload: answer
                        )
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: answer,
                        source: .userAnswer,
                        outcomeStatus: .succeeded
                    )
                    continue
                }

                if risk != .read && !isAlwaysAllowed {
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    if Task.isCancelled {
                        settleUnexecutedStagedCalls(from: stagedIndex, reason: "Cancelled")
                        return
                    }
                    if case .denied(let reason) = decision {
                        anyDenied = true
                        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                            runtime.toolCalls[index].status = .denied
                            runtime.toolCalls[index].errorMessage = reason
                        }
                        AgentSandboxAuditLog.append(
                            toolName: call.toolName,
                            arguments: argsDict,
                            decision: sandboxDecision,
                            approvalSource: nil,
                            outcome: "denied"
                        )
                        appendToolMessage(
                            for: runtime,
                            toolCallID: call.externalID,
                            payload: "Tool call denied by the user.",
                            source: .systemNotice,
                            outcomeStatus: .denied,
                            errorMessage: reason
                        )
                        continue
                    }
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .running
                        if runtime.toolCalls[index].approvalSource == nil {
                            runtime.toolCalls[index].approvalSource = sandboxDecision.mode == .escalated ? .escalated : .user
                        }
                    }
                }

                // `spawn_agent` can't run through AgentToolRunner — it
                // needs the turn's provider configuration plus the
                // subagent registry, both of which only exist up here.
                // Pass `turnConfiguration`, not the base `configuration`:
                // under someIM managed routing the turn's effective model was
                // resolved by the judge (and possibly output-quality escalated)
                // into `turnConfiguration.model`. Handing the child the base
                // `configuration` would silently drop it to the flash tier while
                // the parent runs the escalated tier. Outside managed routing
                // `turnConfiguration == configuration`, so behaviour is unchanged.
                if call.toolName == "spawn_agent" {
                    await executeSpawnAgentToolCall(
                        call,
                        recordID: recordID,
                        arguments: argsDict,
                        runtime: runtime,
                        configuration: turnConfiguration,
                        workspaceURL: workspaceURL,
                        runtimeDescriptor: remoteRuntimeDescriptor,
                        workspaceLocation: workspaceLocation
                    )
                    continue
                }

                let patchAutoApplySource = patchAutoApplySource(
                    forToolName: call.toolName,
                    runtime: runtime
                )
                let context = makeToolContext(
                    sandboxMode: sandboxModeForToolExecution(
                        risk: risk,
                        approvalSource: autoApproval,
                        sandboxDecision: sandboxDecision
                    ),
                    patchAutoApplySource: patchAutoApplySource
                )
                var effectiveArguments = argsDict
                var delegatedControl: (
                    executionAgent: AgentExecutionAgent,
                    runID: UUID,
                    baselineTask: Task<AgentWorktreeSnapshot, Never>?
                )?
                if let executionAgent = AgentExecutionAgent(
                    delegatedToolName: call.toolName
                ), let objective = argsDict["prompt"]?.stringValue()?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !objective.isEmpty {
                    let contract = AgentDelegatedTaskControl.makeContract(
                        objective: objective,
                        executor: executionAgent,
                        goal: runtime.currentGoal
                    )
                    runtime.delegatedTaskRuns.insert(
                        AgentDelegatedTaskRun(contract: contract),
                        at: 0
                    )
                    if runtime.delegatedTaskRuns.count > 20 {
                        runtime.delegatedTaskRuns.removeLast(
                            runtime.delegatedTaskRuns.count - 20
                        )
                    }
                    effectiveArguments["prompt"] = .string(
                        """
                        \(objective)

                        \(AgentDelegatedTaskControl.executorInstructions(contract: contract))
                        """
                    )
                    effectiveArguments["run_in_background"] = .bool(false)
                    effectiveArguments["use_visible_terminal"] = .bool(true)
                    effectiveArguments["visible_terminal_label"] = .string(
                        "\(executionAgent.displayName) · \(L10n.DelegatedTask.sectionTitle)"
                    )
                    effectiveArguments["timeout_seconds"] = .number(
                        Double(contract.timeoutSeconds)
                    )
                    let delegatedBaselineTask = workspaceURL.map { workspaceURL in
                        Task.detached(priority: .utility) {
                            await Self.loadAgentWorktreeSnapshot(for: workspaceURL)
                        }
                    }
                    delegatedControl = (
                        executionAgent: executionAgent,
                        runID: contract.id,
                        baselineTask: delegatedBaselineTask
                    )
                    persistAgentSession(runtime: runtime)
                }
                let guardedMutation: AgentGuardedGitMutation? = {
                    guard call.toolName == "run_command",
                          let command = argsDict["command"]?.stringValue() else {
                        return nil
                    }
                    return AgentWorkspaceMutationPolicy.guardedMutation(in: command)
                }()
                var workspaceMutationLease: AgentWorkspaceMutationLease?
                do {
                    if let guardedMutation, let workspaceURL {
                        if guardedMutation.actions.count > 1 {
                            throw AgentWorkspaceMutationGuardError.multipleGitMutations(guardedMutation.actions)
                        }
                        if argsDict["run_in_background"]?.boolValue() == true {
                            throw AgentWorkspaceMutationGuardError.backgroundGitMutation(guardedMutation.displayName)
                        }

                        // Capture once before waiting for the lease only to
                        // discover the common repository identity. The second
                        // capture, after acquisition, is the authoritative CAS
                        // comparison and closes races between WillDeep sessions.
                        let preLeaseRevision = await AgentWorkspaceRevisionCapture.capture(for: workspaceURL)
                        let leaseIdentity = roundWorkspaceRevision?.repositoryCommonDirectoryPath
                            ?? preLeaseRevision?.repositoryCommonDirectoryPath
                            ?? workspaceURL.standardizedFileURL.path
                        workspaceMutationLease = try await AgentWorkspaceMutationLease.acquire(
                            repositoryIdentity: leaseIdentity
                        )

                        let liveRevision = await AgentWorkspaceRevisionCapture.capture(for: workspaceURL)
                        guard let expectedRevision = roundWorkspaceRevision,
                              let liveRevision else {
                            throw AgentWorkspaceMutationGuardError.workspaceChanged(
                                action: guardedMutation.displayName,
                                details: ["WillDeep could not capture a stable Git revision for this workspace"],
                                activeSessions: []
                            )
                        }
                        guard liveRevision == expectedRevision else {
                            let details: [String]
                            details = liveRevision.difference(from: expectedRevision).summaryLines
                            let activeSessionTitles = workspaceSessionSnapshots(for: runtime)
                                .filter {
                                    !$0.isActive
                                        && ($0.isResponding
                                            || $0.isAwaitingProviderSlot
                                            || $0.queuedMessageCount > 0)
                                }
                                .map(\.title)
                            throw AgentWorkspaceMutationGuardError.workspaceChanged(
                                action: guardedMutation.displayName,
                                details: details.isEmpty ? ["repository revision changed"] : details,
                                activeSessions: activeSessionTitles
                            )
                        }
                    }

                    let producesArtifacts = Self.toolProducesSessionArtifacts(call.toolName)
                    var toolBaselineSnapshot = turnBaselineSnapshot
                    if producesArtifacts, let workspaceURL {
                        toolBaselineSnapshot.artifactFileSignatures = await Task.detached(
                            priority: .utility
                        ) {
                            Self.agentArtifactFileSignatures(in: workspaceURL)
                        }.value
                    }

                    let result: AgentToolResult
                    if let delegatedControl {
                        let outcome = try await runDelegatedTaskWithAcceptance(
                            toolName: call.toolName,
                            initialArguments: effectiveArguments,
                            executionAgent: delegatedControl.executionAgent,
                            delegatedRunID: delegatedControl.runID,
                            runtime: runtime,
                            context: context,
                            workspaceURL: workspaceURL,
                            baselineTask: delegatedControl.baselineTask
                        )
                        guard outcome.accepted else {
                            anyDenied = true
                            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                                runtime.toolCalls[index].status = .failed
                                runtime.toolCalls[index].result = outcome.result
                                runtime.toolCalls[index].errorMessage = outcome.errorMessage
                            }
                            AgentSandboxAuditLog.append(
                                toolName: call.toolName,
                                arguments: effectiveArguments,
                                decision: sandboxDecision,
                                approvalSource: autoApproval,
                                outcome: "acceptance_failed"
                            )
                            appendToolMessage(
                                for: runtime,
                                toolCallID: call.externalID,
                                payload: outcome.result.payload,
                                outcomeStatus: .failed,
                                errorMessage: outcome.errorMessage
                            )
                            continue
                        }
                        result = outcome.result
                    } else {
                        switch try await runToolHandlingSandboxEscalation(
                            toolName: call.toolName,
                            arguments: effectiveArguments,
                            displayArguments: argsDict,
                            recordID: recordID,
                            runtime: runtime,
                            context: context,
                            workspaceLocation: workspaceLocation
                        ) {
                        case .succeeded(let value):
                            result = value
                        case .escalationDeclined(let reason, let denialDetail):
                            anyDenied = true
                            withExtendedLifetime(workspaceMutationLease) {}
                            workspaceMutationLease = nil
                            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                                runtime.toolCalls[index].status = .denied
                                runtime.toolCalls[index].errorMessage = reason
                                runtime.toolCalls[index].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
                            }
                            AgentSandboxAuditLog.append(
                                toolName: call.toolName,
                                arguments: argsDict,
                                decision: sandboxDecision,
                                approvalSource: nil,
                                outcome: "sandbox_escalation_denied"
                            )
                            appendToolMessage(
                                for: runtime,
                                toolCallID: call.externalID,
                                payload: """
                                Sandbox blocked this command and the user declined to re-run it outside the sandbox.
                                Original sandbox denial:
                                \(denialDetail)
                                """,
                                source: .systemNotice,
                                outcomeStatus: .denied,
                                errorMessage: reason
                            )
                            continue
                        }
                    }
                    withExtendedLifetime(workspaceMutationLease) {}
                    // Release before doing UI bookkeeping; only the verified
                    // mutation itself belongs inside the repository lease.
                    workspaceMutationLease = nil
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .succeeded
                        runtime.toolCalls[index].result = result
                        if let patchAutoApplySource {
                            runtime.toolCalls[index].approvalSource = patchAutoApplySource
                        }
                        runtime.toolCalls[index].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
                    }
                    runtime.recordComputerUseActivity(toolName: call.toolName, images: result.images)
                    if call.toolName == "terminal_create_shortcut",
                       !terminalShortcutResultRequiresChatPasswordCard(result) {
                        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .terminal)
                    }
                    let effectiveApprovalSource = runtime.toolCalls.first(where: { $0.id == recordID })?.approvalSource
                        ?? autoApproval
                        ?? patchAutoApplySource
                    AgentSandboxAuditLog.append(
                        toolName: call.toolName,
                        arguments: argsDict,
                        decision: sandboxDecision,
                        approvalSource: effectiveApprovalSource,
                        outcome: "succeeded"
                    )
                    if call.toolName != "change_workspace",
                       call.toolName == "run_command" || risk != .read || patchAutoApplySource != nil {
                        if producesArtifacts {
                            // Artifact harvesting needs this tool's own
                            // artifact baseline — refresh inline as before.
                            await refreshGitStatusAfterAgentTool(
                                for: runtime,
                                workspaceURL: workspaceURL,
                                baselineSnapshot: toolBaselineSnapshot,
                                producesArtifacts: true
                            )
                        } else {
                            roundNeedsGitStatusRefresh = true
                        }
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: result.payload,
                        images: result.images,
                        outcomeStatus: .succeeded
                    )
                } catch is CancellationError {
                    workspaceMutationLease = nil
                    if let delegatedControl {
                        updateDelegatedTaskRun(
                            id: delegatedControl.runID,
                            runtime: runtime
                        ) { run in
                            run.phase = .cancelled
                            run.finishedAt = Date()
                            run.lastError = "Response stopped"
                        }
                    }
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Response stopped"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Tool execution stopped with the current Agent turn.",
                        source: .systemNotice,
                        outcomeStatus: .denied,
                        errorMessage: "Response stopped"
                    )
                    settleUnexecutedStagedCalls(from: stagedIndex + 1, reason: "Response stopped")
                    return
                } catch {
                    // Deinit unlocks and closes the cross-process flock.
                    // This is a no-op for ordinary, unguarded tools.
                    workspaceMutationLease = nil
                    let workspaceIssue = diagnoseLocalWorkspaceIfNeeded(
                        after: error,
                        runtime: runtime,
                        workspaceURL: workspaceURL
                    )
                    let errorMessage = workspaceIssue ?? error.localizedDescription
                    if let delegatedControl {
                        updateDelegatedTaskRun(
                            id: delegatedControl.runID,
                            runtime: runtime
                        ) { run in
                            run.phase = .failed
                            run.finishedAt = Date()
                            run.lastError = errorMessage
                        }
                    }
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .failed
                        runtime.toolCalls[index].errorMessage = errorMessage
                    }
                    AgentSandboxAuditLog.append(
                        toolName: call.toolName,
                        arguments: argsDict,
                        decision: sandboxDecision,
                        approvalSource: runtime.toolCalls.first(where: { $0.id == recordID })?.approvalSource
                            ?? autoApproval
                            ?? patchAutoApplySource,
                        outcome: "failed"
                    )
                    // If the command actually ran under seatbelt, say so
                    // explicitly — the escalation card only covers denials
                    // the heuristic recognizes; everything else used to
                    // reach the model as a bare stderr it would blindly
                    // retry. `_sandbox` on the record reflects the mode the
                    // command really ran with (escalation retries overwrite
                    // it), so a post-escalation failure gets no note.
                    var sandboxNote = ""
                    if let toolError = error as? AgentToolError,
                       case .commandFailed = toolError {
                        let recordedMode = runtime.toolCalls.first(where: { $0.id == recordID })?
                            .arguments["_sandbox"]?.stringValue()
                            .flatMap(AgentSandboxMode.init(rawValue:))
                        if let note = AgentSandboxPolicy.sandboxedFailureNote(
                            toolName: call.toolName,
                            command: argsDict["command"]?.stringValue(),
                            effectiveMode: recordedMode ?? context.sandboxMode
                        ) {
                            sandboxNote = "\n\n" + note
                        }
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Tool error: \(errorMessage)\(sandboxNote)\n\n(WillDeep: this tool call failed. Do not stop here — diagnose the cause from the exit code/stderr above and try another approach to accomplish the goal. Only give up if you are genuinely blocked, and then explain what you tried and what you still need.)",
                        source: .systemNotice,
                        outcomeStatus: .failed,
                        errorMessage: errorMessage
                    )
                }
            }

            // A round that ended on read calls still has an unflushed batch.
            if await executeParallelReadBatch(&pendingParallelReads, runtime: runtime) {
                return
            }

            if roundNeedsGitStatusRefresh {
                await refreshGitStatusAfterAgentTool(
                    for: runtime,
                    workspaceURL: workspaceURL,
                    baselineSnapshot: turnBaselineSnapshot,
                    producesArtifacts: false
                )
            }

            if let changedWorkspacePath {
                let format = String(
                    localized: "agent.workspace-change.completed",
                    defaultValue: "Workspace changed to %@. Send your next message to continue in the new workspace."
                )
                runtime.messages.append(
                    AgentMessage(
                        role: .assistant,
                        content: String(format: format, changedWorkspacePath),
                        origin: .nativeModel
                    )
                )
                return
            }

            if anyDenied, finishReason == "stop" {
                // Model already decided it was done; don't loop further.
                return
            }
            // Otherwise: loop again so the model can react to the tool outputs.
        }

        runtime.errorMessage = "Agent paused after \(Self.maxAgentToolRounds) tool-call rounds to avoid an accidental loop. Send another message to continue."
        runtime.errorDetails = nil
    }

    /// Read-tier tools safe to execute concurrently inside one model round:
    /// pure local workspace reads with no side effects. `.read` risk already
    /// guarantees auto-run (no approval card, no plan gate), and none of
    /// these can enter the sandbox-escalation flow — that flow suspends on
    /// the runtime's single tool-decision waiter, which concurrent calls
    /// must never share. `run_command` stays serial even when classified
    /// read-only for exactly that reason; `spawn_agent` has its own
    /// dispatch path and is likewise excluded.
    nonisolated static let parallelReadBatchToolNames: Set<String> = [
        "read_file", "search_files", "grep_files", "list_directory", "glob", "git_status"
    ]

    /// One read-tier staged call collected for concurrent execution. Risk,
    /// sandbox decision, tool record, and execution context are all resolved
    /// at collection time; only `AgentToolRunner.run` itself fans out.
    struct AgentPendingParallelRead {
        let externalID: String
        let toolName: String
        let arguments: [String: AgentJSONValue]
        let sandboxDecision: AgentSandboxDecision
        let recordID: AgentToolCall.ID
        let context: AgentToolContext
    }

    /// Execute a collected batch of read-tier tool calls concurrently and
    /// fold the outcomes back in the model's original call order — records
    /// in `runtime.toolCalls` were already appended in order during staging,
    /// and tool messages are appended in order here. Returns `true` when the
    /// enclosing turn must stop (cancellation), mirroring the serial path's
    /// early return.
    private func executeParallelReadBatch(
        _ batch: inout [AgentPendingParallelRead],
        runtime: AgentRuntime
    ) async -> Bool {
        guard !batch.isEmpty else { return false }
        let entries = batch
        batch.removeAll()

        var outcomes = [Result<AgentToolResult, Error>?](repeating: nil, count: entries.count)
        if entries.count == 1 {
            // Single read: skip the group machinery, byte-identical to the
            // old serial execution.
            do {
                outcomes[0] = .success(
                    try await AgentToolRunner.run(
                        name: entries[0].toolName,
                        arguments: entries[0].arguments,
                        context: entries[0].context
                    )
                )
            } catch {
                outcomes[0] = .failure(error)
            }
        } else {
            await withTaskGroup(of: (Int, Result<AgentToolResult, Error>).self) { group in
                for (index, entry) in entries.enumerated() {
                    let toolName = entry.toolName
                    let arguments = entry.arguments
                    let context = entry.context
                    group.addTask {
                        do {
                            let result = try await AgentToolRunner.run(
                                name: toolName,
                                arguments: arguments,
                                context: context
                            )
                            return (index, .success(result))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                for await (index, outcome) in group {
                    outcomes[index] = outcome
                }
            }
        }

        var stopTurn = false
        for (index, entry) in entries.enumerated() {
            switch outcomes[index] {
            case .success(let result):
                if let recordIndex = runtime.toolCalls.firstIndex(where: { $0.id == entry.recordID }) {
                    runtime.toolCalls[recordIndex].status = .succeeded
                    runtime.toolCalls[recordIndex].result = result
                    runtime.toolCalls[recordIndex].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
                }
                runtime.recordComputerUseActivity(toolName: entry.toolName, images: result.images)
                AgentSandboxAuditLog.append(
                    toolName: entry.toolName,
                    arguments: entry.arguments,
                    decision: entry.sandboxDecision,
                    approvalSource: nil,
                    outcome: "succeeded"
                )
                appendToolMessage(
                    for: runtime,
                    toolCallID: entry.externalID,
                    payload: result.payload,
                    images: result.images,
                    outcomeStatus: .succeeded
                )
            case .failure(is CancellationError), nil:
                // User stopped the turn mid-batch. Answer this call like the
                // serial cancel path so no record is left spinning, and stop
                // the turn after the whole batch is folded back.
                stopTurn = true
                if let recordIndex = runtime.toolCalls.firstIndex(where: { $0.id == entry.recordID }) {
                    runtime.toolCalls[recordIndex].status = .denied
                    runtime.toolCalls[recordIndex].errorMessage = "Response stopped"
                }
                appendToolMessage(
                    for: runtime,
                    toolCallID: entry.externalID,
                    payload: "Tool execution stopped with the current Agent turn.",
                    source: .systemNotice,
                    outcomeStatus: .denied,
                    errorMessage: "Response stopped"
                )
            case .failure(let error):
                let workspaceIssue = diagnoseLocalWorkspaceIfNeeded(
                    after: error,
                    runtime: runtime,
                    workspaceURL: entry.context.rootDirectory
                )
                let errorMessage = workspaceIssue ?? error.localizedDescription
                if let recordIndex = runtime.toolCalls.firstIndex(where: { $0.id == entry.recordID }) {
                    runtime.toolCalls[recordIndex].status = .failed
                    runtime.toolCalls[recordIndex].errorMessage = errorMessage
                }
                AgentSandboxAuditLog.append(
                    toolName: entry.toolName,
                    arguments: entry.arguments,
                    decision: entry.sandboxDecision,
                    approvalSource: nil,
                    outcome: "failed"
                )
                appendToolMessage(
                    for: runtime,
                    toolCallID: entry.externalID,
                    payload: "Tool error: \(errorMessage)\n\n(WillDeep: this tool call failed. Do not stop here — diagnose the cause from the exit code/stderr above and try another approach to accomplish the goal. Only give up if you are genuinely blocked, and then explain what you tried and what you still need.)",
                    source: .systemNotice,
                    outcomeStatus: .failed,
                    errorMessage: errorMessage
                )
            }
        }
        return stopTurn
    }

    private func patchAutoApplySource(
        forToolName toolName: String,
        runtime: AgentRuntime
    ) -> AgentToolApprovalSource? {
        guard toolName == "apply_patch" || toolName == "edit_file" || toolName == "create_file" else { return nil }
        if runtime.interactionMode == .goal {
            return .goalMode
        }
        if runtime.interactionMode != .plan,
           runtime.approvalMode == .workspaceAccess {
            return .workspaceAccess
        }
        return nil
    }

    /// Suspend until the user resolves the tool call. Three resume paths:
    ///   1. The call is already resolved by the time we register
    ///      (race: user clicked Deny while a prior tool was still running) —
    ///      resume immediately from the synchronous fast-path.
    ///   2. UI delivers an .approved / .denied / .answered — `resumeToolDecision`
    ///      pulls `toolDecisionWaiter` off the runtime and resumes it.
    ///   3. The enclosing Task is cancelled (session deleted, app shutdown,
    ///      user hit Stop) — `withTaskCancellationHandler` reaches in and
    ///      resumes with .denied so the caller unwinds cleanly. Pre-rc38
    ///      this path leaked: the continuation was stored but never resumed,
    ///      hanging the tool dispatch loop on the next user action.
    func awaitToolDecision(for runtime: AgentRuntime, forCallID id: AgentToolCall.ID) async -> AgentToolDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let decision = runtime.pendingToolDecisions.removeValue(forKey: id) {
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == id }),
                       runtime.toolCalls[index].status.isBlockingForUserDecision {
                        switch decision {
                        case .approved, .answered:
                            runtime.toolCalls[index].status = .running
                        case .denied(let reason):
                            runtime.toolCalls[index].status = .denied
                            runtime.toolCalls[index].errorMessage = reason
                        }
                    }
                    continuation.resume(returning: decision)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(returning: .denied(reason: "Cancelled"))
                    return
                }
                if let call = runtime.toolCalls.first(where: { $0.id == id }),
                   call.status != .pendingApproval, call.status != .awaitingConfirm,
                   call.status != .awaitingUserAnswer {
                    if call.status == .denied {
                        continuation.resume(returning: .denied(reason: call.errorMessage ?? "User denied"))
                    } else {
                        continuation.resume(returning: .approved)
                    }
                    return
                }
                runtime.toolDecisionWaiterCallID = id
                runtime.toolDecisionWaiter = continuation
            }
        } onCancel: {
            // The cancellation handler runs synchronously off the cancelling
            // task — it's nonisolated, so we hop back to the main actor to
            // touch the runtime's continuation slot.
            Task { @MainActor [weak runtime] in
                guard let runtime else { return }
                if let waiter = runtime.toolDecisionWaiter,
                   runtime.toolDecisionWaiterCallID == nil || runtime.toolDecisionWaiterCallID == id {
                    runtime.toolDecisionWaiter = nil
                    runtime.toolDecisionWaiterCallID = nil
                    runtime.pendingToolDecisions.removeValue(forKey: id)
                    waiter.resume(returning: .denied(reason: "Cancelled"))
                }
            }
        }
    }

    /// Append a `tool` message to runtime.messages, running it through
    /// `AgentInjectionDefense` first. Default `source` is `.toolOutput`
    /// — the conservative case where the payload contains arbitrary
    /// bytes from the workspace / MCP / shell, any of which could carry
    /// injection markers. Callers that hand-author the payload string
    /// (denial notices, plan-mode blocks) should pass `.systemNotice`
    /// to skip the neutralizer; the `ask_user` reply path should pass
    /// `.userAnswer` so the content gets wrapped in `<user_answer>` and
    /// the model can tell a typed reply apart from a tool result.
    /// Build the `<background-task-notification>` body the agent loop
    /// pushes into the model when a backgrounded `run_command` job
    /// finishes. Kept short and unambiguous: the model should react to
    /// it (summarize, follow up, kick off next steps) or quietly note
    /// it depending on the originating user intent.
    ///
    /// `recentOutput` is an already-tailed, already-secret-redacted slice
    /// the caller inlines for jobs that need attention (failed / timed out
    /// / launch failed). Surfacing *why* a job failed in the notice itself
    /// saves the model a `get_job_output` round-trip before it can react —
    /// without it, a backgrounded `docker build` that fails just reads as
    /// "exit=1, 5 KB captured" and the model has to fetch the log to learn
    /// anything. Pass `nil` (the default) for success / killed jobs, which
    /// keep the lighter byte-count hint.
    nonisolated static func backgroundJobCompletionNotice(
        for job: AgentBackgroundJob,
        recentOutput: String? = nil
    ) -> String {
        let durationText: String = {
            let total = Int(job.duration.rounded())
            if total < 60 { return "\(total)s" }
            let m = total / 60, s = total % 60
            if m < 60 { return "\(m)m\(s)s" }
            let h = m / 60, mm = m % 60
            return "\(h)h\(mm)m"
        }()
        let exitText = job.exitCode.map { "exit=\($0)" } ?? "exit=?"
        let trimmedCommand = job.command.count > 200
            ? String(job.command.prefix(200)) + "…"
            : job.command
        let outputHint = job.outputByteCount > 0
            ? "\(job.outputByteCount) bytes of output captured — call `get_job_output(job_id: \"\(job.displayHandle)\")` to read."
            : "no output captured."

        var lines = [
            "<background-task-notification>",
            "Background job \(job.displayHandle) finished while you were not in this turn.",
            "Command: \(trimmedCommand)",
            "Status: \(job.status.rawValue) (\(exitText)), duration \(durationText).",
            outputHint
        ]
        if let recentOutput, !recentOutput.isEmpty {
            lines.append("Recent output (tail, secrets redacted):")
            lines.append("```")
            lines.append(recentOutput)
            lines.append("```")
        }
        lines.append("</background-task-notification>")
        return lines.joined(separator: "\n")
    }

    nonisolated static func mediaTaskCompletionNotice(for task: AgentMediaTask) -> String {
        let artifactLines: [String] = task.artifacts.isEmpty
            ? ["Artifacts: none."]
            : ["Artifacts:"] + task.artifacts.map { "- \($0.title): \($0.filePath)" }
        let anchorLines = mediaTaskAnchorLines(for: task)
        let followUpLines = mediaTaskFollowUpLines(for: task)
        let actionLines = mediaTaskActionLines(for: task)
        var lines = [
            "<media-task-notification>",
            "Remote media task \(task.displayHandle) finished while you were not in this turn.",
            "Provider: \(task.provider.displayName)",
            "Kind: \(task.kind.displayName)",
            "Title: \(task.title)",
            "Status: \(task.status.rawValue).",
            "Created at: \(mediaTaskNoticeTimestamp(task.createdAt))",
            "Updated at: \(mediaTaskNoticeTimestamp(task.updatedAt))"
        ]
        if let finishedAt = task.finishedAt {
            lines.append("Finished at: \(mediaTaskNoticeTimestamp(finishedAt))")
        }
        if let model = task.model, !model.isEmpty {
            lines.append("Model: \(model)")
        }
        if let remoteTaskID = task.remoteTaskID, !remoteTaskID.isEmpty {
            lines.append("Remote task id: \(remoteTaskID)")
        }
        if let statusURL = task.statusURL, !statusURL.isEmpty {
            lines.append("Status URL: \(statusURL)")
        }
        if let cancelURL = task.cancelURL, !cancelURL.isEmpty {
            lines.append("Cancel URL: \(cancelURL)")
        }
        if let sourceImagePath = task.sourceImagePath, !sourceImagePath.isEmpty {
            lines.append("Source image: \(sourceImagePath)")
        }
        if let maskPath = task.maskPath, !maskPath.isEmpty {
            lines.append("Mask: \(maskPath)")
        }
        if let message = task.statusMessage, !message.isEmpty {
            lines.append("Status message: \(message)")
        }
        if !anchorLines.isEmpty {
            lines.append("Anchors:")
            lines.append(contentsOf: anchorLines)
        }
        lines.append(contentsOf: artifactLines)
        if !followUpLines.isEmpty {
            lines.append("Suggested follow-up:")
            lines.append(contentsOf: followUpLines)
        }
        if !actionLines.isEmpty {
            lines.append("Structured action context:")
            lines.append(contentsOf: actionLines)
        }
        lines.append("</media-task-notification>")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func mediaTaskAnchorLines(for task: AgentMediaTask) -> [String] {
        var lines: [String] = []
        if let projectID = cleanMediaTaskNoticeValue(task.projectID) ?? cleanMediaTaskNoticeValue(task.projectPath) {
            lines.append("- project_id: \(projectID)")
        }
        if let episodeID = cleanMediaTaskNoticeValue(task.episodeID) {
            lines.append("- episode_id: \(episodeID)")
        }
        if let shotID = cleanMediaTaskNoticeValue(task.shotID) {
            lines.append("- shot_id: \(shotID)")
        }
        if let assetKind = cleanMediaTaskNoticeValue(task.assetKind) {
            lines.append("- asset_kind: \(assetKind)")
        }
        if let assetID = cleanMediaTaskNoticeValue(task.assetID) {
            lines.append("- asset_id: \(assetID)")
        }
        if let reviewItemID = cleanMediaTaskNoticeValue(task.reviewItemID) {
            lines.append("- review_item_id: \(reviewItemID)")
        }
        return lines
    }

    nonisolated private static func mediaTaskPanelScope(for task: AgentMediaTask) -> AgentMediaTaskScope? {
        let projectID = cleanMediaTaskNoticeValue(task.projectID) ?? cleanMediaTaskNoticeValue(task.projectPath)
        let episodeID = cleanMediaTaskNoticeValue(task.episodeID)
        let shotID = cleanMediaTaskNoticeValue(task.shotID)
        let assetKind = cleanMediaTaskNoticeValue(task.assetKind)
        let assetID = cleanMediaTaskNoticeValue(task.assetID)
        let reviewItemID = cleanMediaTaskNoticeValue(task.reviewItemID)
        if let reviewItemID {
            return AgentMediaTaskScope(
                label: "检查项任务：\(task.title)",
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID,
                reviewItemID: reviewItemID
            )
        }
        if let shotID {
            return AgentMediaTaskScope(
                label: "分镜任务：\(task.title)",
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID
            )
        }
        if let assetKind, let assetID {
            let assetLabel = assetKind == "scene" ? "场景资产任务" : "人物资产任务"
            return AgentMediaTaskScope(
                label: "\(assetLabel)：\(task.title)",
                projectID: projectID,
                assetKind: assetKind,
                assetID: assetID
            )
        }
        if let projectID {
            return AgentMediaTaskScope(
                label: "项目任务：\(task.title)",
                projectID: projectID
            )
        }
        return nil
    }

    nonisolated private static func mediaTaskActionLines(for task: AgentMediaTask) -> [String] {
        var lines = [
            "<media-task-action>",
            "task_id: \(task.displayHandle)",
            "task_uuid: \(task.id.uuidString)",
            "status: \(task.status.rawValue)",
            "provider: \(task.provider.rawValue)",
            "kind: \(task.kind.rawValue)",
            "created_at: \(mediaTaskNoticeTimestamp(task.createdAt))",
            "updated_at: \(mediaTaskNoticeTimestamp(task.updatedAt))"
        ]
        if let finishedAt = task.finishedAt {
            lines.append("finished_at: \(mediaTaskNoticeTimestamp(finishedAt))")
        }
        let projectID = cleanMediaTaskNoticeValue(task.projectID) ?? cleanMediaTaskNoticeValue(task.projectPath)
        let episodeID = cleanMediaTaskNoticeValue(task.episodeID)
        let shotID = cleanMediaTaskNoticeValue(task.shotID)
        let assetKind = cleanMediaTaskNoticeValue(task.assetKind)
        let assetID = cleanMediaTaskNoticeValue(task.assetID)
        let reviewItemID = cleanMediaTaskNoticeValue(task.reviewItemID)
        let statusURL = cleanMediaTaskNoticeValue(task.statusURL)
        let cancelURL = cleanMediaTaskNoticeValue(task.cancelURL)
        let statusEndpointSuffix = cleanMediaTaskNoticeValue(task.statusEndpointSuffix)
        let cancelEndpointSuffix = cleanMediaTaskNoticeValue(task.cancelEndpointSuffix)
        let sourceImagePath = cleanMediaTaskNoticeValue(task.sourceImagePath)
        let maskPath = cleanMediaTaskNoticeValue(task.maskPath)
        if let statusURL { lines.append("status_url: \(statusURL)") }
        if let cancelURL { lines.append("cancel_url: \(cancelURL)") }
        if let statusEndpointSuffix { lines.append("status_endpoint_suffix: \(statusEndpointSuffix)") }
        if let cancelEndpointSuffix { lines.append("cancel_endpoint_suffix: \(cancelEndpointSuffix)") }
        if let sourceImagePath { lines.append("source_image_path: \(sourceImagePath)") }
        if let maskPath { lines.append("mask_path: \(maskPath)") }
        if let projectID { lines.append("project_id: \(projectID)") }
        if let episodeID { lines.append("episode_id: \(episodeID)") }
        if let shotID { lines.append("shot_id: \(shotID)") }
        if let assetKind { lines.append("asset_kind: \(assetKind)") }
        if let assetID { lines.append("asset_id: \(assetID)") }
        if let reviewItemID { lines.append("review_item_id: \(reviewItemID)") }
        if let scopeArguments = mediaTaskNoticeScopeArguments(
            projectID: projectID,
            episodeID: episodeID,
            shotID: shotID,
            assetKind: assetKind,
            assetID: assetID,
            reviewItemID: reviewItemID
        ) {
            lines.append("open_scope_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_scope_tasks_arguments: \(scopeArguments)")
            lines.append("refresh_scope_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_scope_tasks_arguments: \(scopeArguments)")
        }

        if task.status == .succeeded {
            if let projectID, let episodeID, let shotID {
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot")
                let candidateImagePaths = task.artifacts.filter(Self.isImageArtifact).map(\.filePath)
                if candidateImagePaths.count > 1 {
                    lines.append("candidate_tool: short_drama_show_image_choice_widget")
                    let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
                    lines.append("candidate_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)")
                    let candidateImages = candidateImagePaths.joined(separator: " | ")
                    lines.append("candidate_image_paths: \(candidateImages)")
                    lines.append("candidate_preview_tool: show_image_choice_widget")
                    lines.append("candidate_preview_arguments: image_paths=\(candidateImages), project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)")
                } else if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                    lines.append("select_primary_tool: short_drama_select_shot_artifact")
                    lines.append("select_primary_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(artifact.filePath)")
                }
                if let videoArtifact = task.artifacts.first(where: Self.isVideoArtifact) {
                    lines.append("completed_video_path: \(videoArtifact.filePath)")
                    lines.append("completed_video_action: continue_from_completed_video_artifact")
                    lines.append("open_shot_tasks_tool: short_drama_open_media_tasks")
                    lines.append("open_shot_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot")
                    lines.append("refresh_shot_tasks_tool: short_drama_refresh_media_tasks")
                    lines.append("refresh_shot_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot")
                    lines.append("storyboard_widget_tool: short_drama_show_storyboard_widget")
                    lines.append("storyboard_widget_arguments: project_id=\(projectID), episode_id=\(episodeID)")
                }
                if isImageFollowUpKind(task.kind) {
                    if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                        let reviewSuffix = reviewItemID.map { ", review_item_id=\($0)" } ?? ""
                        let artifactArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(artifact.filePath)\(reviewSuffix)"
                        lines.append("video_from_image_tool: generate_video_from_image")
                        lines.append("video_from_image_arguments: image_path=\(artifact.filePath), project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID)\(reviewSuffix)")
                        lines.append("edit_tool: short_drama_open_image_editor")
                        lines.append("edit_arguments: \(artifactArguments), operation=inpaint")
                        lines.append("erase_tool: short_drama_open_image_editor")
                        lines.append("erase_arguments: \(artifactArguments), operation=erase")
                        lines.append("upscale_tool: short_drama_upscale_shot_artifact")
                        lines.append("upscale_arguments: \(artifactArguments)")
                    }
                    lines.append("video_tool: short_drama_generate_shot_media")
                    lines.append("video_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), kind=video_generation")
                }
                if let reviewItemID {
                    lines.append("open_review_tasks_tool: short_drama_open_media_tasks")
                    lines.append("open_review_tasks_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=review_item, review_item_id=\(reviewItemID)")
                    lines.append("resolve_review_tool: short_drama_resolve_review_item")
                    lines.append("resolve_review_arguments: project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), item_id=\(reviewItemID)")
                }
            } else if let projectID, let assetKind, let assetID {
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)")
                lines.append("refresh_tasks_tool: short_drama_refresh_media_tasks")
                lines.append("refresh_tasks_arguments: project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)")
                lines.append("generate_asset_reference_tool: short_drama_generate_asset_media")
                lines.append("generate_asset_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                    lines.append("attach_reference_tool: short_drama_attach_asset_reference_image")
                    lines.append("attach_reference_arguments: project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID), image_path=\(artifact.filePath)")
                    lines.append("edit_tool: open_image_editor")
                    lines.append("edit_arguments: image_path=\(artifact.filePath), operation=inpaint, project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                    lines.append("erase_tool: open_image_editor")
                    lines.append("erase_arguments: image_path=\(artifact.filePath), operation=erase, project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                    lines.append("upscale_tool: upscale_image")
                    lines.append("upscale_arguments: image_path=\(artifact.filePath), project_id=\(projectID), asset_kind=\(assetKind), asset_id=\(assetID)")
                }
                lines.append("next_step: use this reference image when generating related short-drama shots.")
            } else if isImageFollowUpKind(task.kind) {
                let imageArtifacts = task.artifacts.filter(Self.isImageArtifact)
                if imageArtifacts.count > 1 {
                    let imagePaths = imageArtifacts.map(\.filePath).joined(separator: " | ")
                    lines.append("candidate_tool: show_image_choice_widget")
                    lines.append("candidate_arguments: image_paths=\(imagePaths)")
                } else if let artifact = imageArtifacts.first {
                    lines.append("edit_tool: open_image_editor")
                    lines.append("edit_arguments: image_path=\(artifact.filePath), operation=inpaint")
                    lines.append("erase_tool: open_image_editor")
                    lines.append("erase_arguments: image_path=\(artifact.filePath), operation=erase")
                    lines.append("upscale_tool: upscale_image")
                    lines.append("upscale_arguments: image_path=\(artifact.filePath)")
                    lines.append("video_from_image_tool: generate_video_from_image")
                    lines.append("video_from_image_arguments: image_path=\(artifact.filePath)")
                }
                lines.append("next_step: attach one artifact to chat, open it in the image editor, upscale it, generate video from it, or import it into a short-drama shot or asset.")
            }
        } else {
            if let sourceImagePath, let maskPath, isImageFollowUpKind(task.kind) {
                let operation = task.kind == .imageErase ? "erase" : "inpaint"
                if let projectID, let episodeID, let shotID {
                    lines.append("reopen_editor_tool: short_drama_open_image_editor")
                    var reopenArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), artifact_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
                    if let reviewItemID {
                        reopenArguments += ", review_item_id=\(reviewItemID)"
                    }
                    lines.append("reopen_editor_arguments: \(reopenArguments)")
                } else {
                    lines.append("reopen_editor_tool: open_image_editor")
                    var reopenArguments = "image_path=\(sourceImagePath), mask_path=\(maskPath), operation=\(operation)"
                    if let projectID {
                        reopenArguments += ", project_id=\(projectID)"
                    }
                    if let assetKind {
                        reopenArguments += ", asset_kind=\(assetKind)"
                    }
                    if let assetID {
                        reopenArguments += ", asset_id=\(assetID)"
                    }
                    if let reviewItemID {
                        reopenArguments += ", review_item_id=\(reviewItemID)"
                    }
                    lines.append("reopen_editor_arguments: \(reopenArguments)")
                }
            }
            if projectID != nil {
                lines.append("retry_tool: short_drama_retry_media_task")
                lines.append("retry_arguments: task_id=\(task.displayHandle)")
            }
            if let projectID {
                let scopeArguments: String
                if let episodeID, let shotID {
                    scopeArguments = "project_id=\(projectID), episode_id=\(episodeID), shot_id=\(shotID), scope=shot"
                } else if let assetKind, let assetID {
                    scopeArguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
                } else {
                    scopeArguments = "project_id=\(projectID), scope=project"
                }
                lines.append("open_tasks_tool: short_drama_open_media_tasks")
                lines.append("open_tasks_arguments: \(scopeArguments)")
            }
        }

        if !task.artifacts.isEmpty {
            lines.append("artifact_paths:")
            lines.append(contentsOf: task.artifacts.prefix(12).map { "- \($0.filePath)" })
            if task.artifacts.count > 12 {
                lines.append("- ... \(task.artifacts.count - 12) more")
            }
        }
        lines.append("</media-task-action>")
        return lines
    }

    nonisolated private static func mediaTaskNoticeScopeArguments(
        projectID: String?,
        episodeID: String?,
        shotID: String?,
        assetKind: String?,
        assetID: String?,
        reviewItemID: String?
    ) -> String? {
        guard projectID != nil || episodeID != nil || shotID != nil || assetKind != nil || assetID != nil || reviewItemID != nil else {
            return nil
        }
        var pairs: [String] = []
        if let projectID { pairs.append("project_id=\(projectID)") }
        if let episodeID { pairs.append("episode_id=\(episodeID)") }
        if let shotID { pairs.append("shot_id=\(shotID)") }
        if let reviewItemID {
            pairs.append("scope=review_item")
            pairs.append("review_item_id=\(reviewItemID)")
        } else if let assetKind, let assetID {
            pairs.append("scope=asset")
            pairs.append("asset_kind=\(assetKind)")
            pairs.append("asset_id=\(assetID)")
        } else if shotID != nil {
            pairs.append("scope=shot")
        } else if episodeID != nil {
            pairs.append("scope=episode")
        } else {
            pairs.append("scope=project")
        }
        return pairs.joined(separator: ", ")
    }

    nonisolated private static func mediaTaskFollowUpLines(for task: AgentMediaTask) -> [String] {
        guard task.status == .succeeded else {
            return ["- If the task failed or was canceled, explain the provider message and ask whether to retry or adjust the prompt."]
        }
        var lines: [String] = []
        if cleanMediaTaskNoticeValue(task.shotID) != nil {
            let imageArtifacts = task.artifacts.filter(Self.isImageArtifact)
            if imageArtifacts.count > 1 {
                lines.append("- For multiple image candidates, call `short_drama_show_image_choice_widget` so the user can pick the shot primary image.")
            } else if let artifact = imageArtifacts.first {
                lines.append("- For a single accepted storyboard image, call `short_drama_select_shot_artifact` with `artifact_path: \"\(artifact.filePath)\"` when the user wants it as the shot primary image.")
            }
            if let videoArtifact = task.artifacts.first(where: Self.isVideoArtifact) {
                lines.append("- This completed video is available at `\(videoArtifact.filePath)`; open or refresh the same shot media tasks, then return to `short_drama_show_storyboard_widget` to continue reviewing the episode.")
            }
            if task.kind == .imageGeneration || task.kind == .imageEdit || task.kind == .imageInpaint || task.kind == .imageErase || task.kind == .imageUpscale {
                lines.append("- To continue production from a chosen keyframe, call `generate_video_from_image` with the artifact `image_path` and the same shot anchors; include `review_item_id` too when this task is linked to a review item. If the shot primary image is already selected and no explicit artifact path is needed, `short_drama_generate_shot_media(kind: \"video_generation\")` is also valid.")
                lines.append("- To refine the image, call `short_drama_open_image_editor` for mask redraw/erase, or `short_drama_upscale_shot_artifact` for enlargement.")
            }
            if cleanMediaTaskNoticeValue(task.reviewItemID) != nil {
                lines.append("- To inspect all tasks for the same review item, call `short_drama_open_media_tasks(scope: \"review_item\")` with the same project/episode/shot anchors and `review_item_id`.")
                lines.append("- This task is linked to a review item; after confirming the artifact fixes the issue, call `short_drama_resolve_review_item` with the same project/episode/shot anchors and `review_item_id`.")
            }
        } else if cleanMediaTaskNoticeValue(task.assetID) != nil {
            if let artifact = task.artifacts.first(where: Self.isImageArtifact) {
                lines.append("- To save this result as an asset reference image, call `short_drama_attach_asset_reference_image` with `image_path: \"\(artifact.filePath)\"` and the same asset anchors.")
                lines.append("- To refine this asset reference, call `open_image_editor` for redraw/erase or `upscale_image`; keep the same `project_id`, `asset_kind`, and `asset_id` so completed artifacts return to the asset.")
            }
            lines.append("- This result is anchored to a character or scene asset; use it as reference context for later `short_drama_generate_shot_media` calls.")
        } else if task.kind == .imageGeneration || task.kind == .imageEdit || task.kind == .imageInpaint || task.kind == .imageErase || task.kind == .imageUpscale {
            if task.artifacts.filter(Self.isImageArtifact).count > 1 {
                lines.append("- For multiple image candidates outside a short-drama shot, call `show_image_choice_widget` with the artifact paths so the user can choose one before editing, upscaling, or generating video.")
            }
            lines.append("- Offer to attach one artifact to chat, open it in the image editor with `open_image_editor`, upscale it with `upscale_image`, generate video from it with `generate_video_from_image`, or import it into a short-drama shot/asset.")
        }
        return lines
    }

    nonisolated private static func isImageFollowUpKind(_ kind: AgentMediaTaskKind) -> Bool {
        kind == .imageGeneration || kind == .imageEdit || kind == .imageInpaint || kind == .imageErase || kind == .imageUpscale
    }

    nonisolated private static func mediaTaskNoticeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    nonisolated private static func isImageArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }
        let pathExtension = URL(fileURLWithPath: artifact.filePath).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(pathExtension)
    }

    nonisolated private static func isVideoArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("video/") {
            return true
        }
        let pathExtension = URL(fileURLWithPath: artifact.filePath).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(pathExtension)
    }

    nonisolated private static func cleanMediaTaskNoticeValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

}
