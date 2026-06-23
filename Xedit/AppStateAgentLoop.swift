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
        attachedSkills: [AgentSkillEntry] = []
    ) {
        resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime)

        let configuration = configurationForCurrentTurn(for: runtime)
        let providerID = configuration.providerID

        // Concurrency gate: cap simultaneous turns per provider so a
        // routine fleet can't blow past the provider's rate limit. If
        // the slot isn't open, queue this dispatch — `releaseProviderSlot`
        // drains pending entries FIFO as turns finish.
        guard acquireProviderSlotIfPossible(providerID: providerID) else {
            pendingDispatchQueue.append(
                PendingDispatch(
                    runtimeID: runtime.id,
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

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()
        runtime.currentTurnAttachedSkills = attachedSkills

        let userMessage = AgentMessage(
            role: .user,
            content: text,
            images: images,
            textAttachments: textAttachments
        )
        runtime.messages.append(userMessage)
        runtime.latestTurnRecall = nil
        // Persist the user's message to disk the instant it's sent —
        // BEFORE the turn runs. The turn's `defer` persist only fires
        // when the loop finishes; if the turn hangs (slow/flaky proxy)
        // and the app is quit mid-flight, that defer never runs and the
        // only on-disk copy is the empty "New Chat" placeholder — which
        // `pruneEmptyAgentSessions` later deletes as a stray empty row,
        // taking the whole conversation with it. Writing here guarantees
        // the session always has the user's message on disk and can never
        // be pruned as "empty" after a send.
        persistAgentSession(runtime: runtime)
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
            await self.prepareImagesForTextOnlyProvider(
                for: runtime,
                userMessageID: userMessage.id,
                mainConfiguration: configuration,
                imageDescriptionConfiguration: imageDescriptionConfiguration
            )
            await self.runAgentLoop(for: runtime, configuration: configuration)
        }
    }

    func prepareImagesForTextOnlyProvider(
        for runtime: AgentRuntime,
        userMessageID: AgentMessage.ID,
        mainConfiguration: AgentConfiguration,
        imageDescriptionConfiguration: AgentConfiguration
    ) async {
        guard !mainConfiguration.supportsImageInput else { return }
        guard let index = runtime.messages.firstIndex(where: { $0.id == userMessageID }) else { return }
        let images = runtime.messages[index].images
        guard !images.isEmpty else { return }

        let description: String
        do {
            description = try await describeImagesForTextOnlyProvider(
                images,
                configuration: imageDescriptionConfiguration
            )
        } catch {
            description = "Image description failed before sending to \(mainConfiguration.providerID): \(error.localizedDescription)"
        }

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
    }

    func describeImagesForTextOnlyProvider(
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
        let collector = CompressionSummaryCollector()
        try await AgentClient(configuration: normalized).streamChat(messages: [message]) { event in
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
            attachedSkills: next.attachedSkills
        )
    }

    func clearAgentConversation() {
        agentRequestTask?.cancel()
        if let runtimeID = activeRuntime?.id {
            agentSubagentRegistry.cancelAll(forParentRuntime: runtimeID)
        }
        agentMessages.removeAll()
        agentPatchProposals.removeAll()
        agentToolCalls.removeAll()
        agentQueuedMessages.removeAll()
        agentPendingImages.removeAll()
        agentPendingTextAttachments.removeAll()
        agentErrorMessage = nil
        agentErrorDetails = nil
        agentToolDecisionWaiter?.resume(returning: .denied(reason: "Conversation cleared"))
        agentToolDecisionWaiter = nil
        isAgentResponding = false
        agentTurnStartedAt = nil
        persistActiveAgentSession()
    }

    @MainActor
    func runAgentLoop(for runtime: AgentRuntime, configuration: AgentConfiguration) async {
        defer {
            let shouldConsumeQueueAfterStop = runtime.shouldConsumeQueueAfterStop
            runtime.isResponding = false
            runtime.turnStartedAt = nil
            runtime.requestTask = nil
            runtime.shouldConsumeQueueAfterStop = false
            captureAgentPlanFromLatestMessage(for: runtime)
            captureAgentGoalDefinitionFromLatestMessage(for: runtime)
            captureAgentGoalEvaluationFromLatestMessage(for: runtime)
            persistAgentSession(runtime: runtime)
            if !shouldConsumeQueueAfterStop {
                maybeAutoCompressContext(for: runtime)
            }
            consumeNextQueuedMessageIfNeeded(for: runtime)
            // Always release the provider slot last so the queue drain
            // sees a fully cleared `isResponding` and won't refuse to
            // dispatch a queued user message that's for the same runtime.
            releaseProviderSlot(providerID: configuration.providerID)
        }

        let client = AgentClient(configuration: configuration)
        // Resolve the runtime's workspace path for tool execution —
        // never read AppState.rootDirectory here. Concurrent runtimes
        // can be running against different workspaces; the window's
        // current folder is a UI concept, not a session concept.
        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let workspaceURL = workspaceLocation?.localPath.map { URL(fileURLWithPath: $0) }
        let remoteRuntimeDescriptor: RuntimeDescriptor? = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let turnBaselineSnapshot = await Self.loadAgentWorktreeSnapshot(for: workspaceURL)
        let turnBaselineChanges = turnBaselineSnapshot.changes
        if workspaceURL != nil {
            runtime.worktreeChanges = turnBaselineChanges
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

        for _ in 0..<Self.maxAgentToolRounds {
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
                runtime.messages.append(
                    AgentMessage(
                        role: .system,
                        content: Self.backgroundJobCompletionNotice(for: finishedJob)
                    )
                )
            }

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
            var systemPrompt = AgentContextBuilder.systemPrompt(
                rootDirectory: workspaceURL,
                openedFileURL: openedFileURL,
                fileContent: fileContent,
                selectedText: selectedText,
                language: effectiveLanguage,
                toolsEnabled: true,
                interactionMode: runtime.interactionMode,
                approvalMode: runtime.approvalMode,
                currentPlan: runtime.currentPlan,
                currentGoal: runtime.currentGoal,
                promptProfile: promptProfile
            )
            if let remoteRuntimeDescriptor,
               case .remote(_, let remotePath) = workspaceLocation {
                systemPrompt += """

                Remote workspace:
                - Runtime: \(remoteRuntimeDescriptor.displayName) (\(remoteRuntimeDescriptor.sshTarget))
                - Platform: \(remoteRuntimeDescriptor.platform.displayName) / \(remoteRuntimeDescriptor.arch.displayName)
                - Root: \(remotePath)
                - Tools and shell commands execute on the remote runtime through SSH. Tell the user when a command is remote if it matters.
                """
            }
            if let memoryContextBlock {
                systemPrompt += "\n\n\(memoryContextBlock)"
            }
            let cacheDiagnostics = AgentContextBuilder.cacheDiagnostics(
                for: systemPrompt,
                toolsEnabled: true,
                promptProfile: promptProfile
            )
            if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                runtime.messages[index].requestPrefixHash = cacheDiagnostics.hash
                runtime.messages[index].requestStablePrefixCharacters = cacheDiagnostics.stableCharacters
            }
            let history = runtime.messages.filter { $0.id != assistantID }
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
                            tools: AgentToolRegistry.all
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
                                    runtime.messages[index].cachedPromptTokens = cachedPrompt > 0 ? cachedPrompt : nil
                                    runtime.messages[index].cacheWritePromptTokens = cacheWritePrompt > 0 ? cacheWritePrompt : nil
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
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty {
                    runtime.messages.remove(at: index)
                }
                return
            } catch {
                streamBuffer.flushPending()
                setAgentError(error, for: runtime)
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty {
                    runtime.messages.remove(at: index)
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
            }

            // No tool calls → assistant finished talking. Capture patches and return.
            guard !latestToolCalls.isEmpty else {
                captureAgentPatchProposals(for: runtime, fromMessageID: assistantID)
                // A stream can end "successfully" having produced nothing
                // (provider hiccup, content filter, empty stop). Drop the
                // placeholder like the error/cancel paths do — if it stays
                // in history, the next request encodes it as a bare
                // {"role":"assistant"} and the server rejects with 400.
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty,
                   (runtime.messages[index].reasoningContent ?? "").isEmpty {
                    runtime.messages.remove(at: index)
                }
                return
            }

            // Execute every tool call, gating on the user when necessary.
            var anyDenied = false
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
                            payload: "Tool arguments JSON could not be parsed; re-emit the call with valid JSON. Raw payload: \(call.argumentsJSON.prefix(400))"
                        )
                        continue
                    }
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
                    approvalMode: runtime.approvalMode
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

                if risk == .userInput {
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    if Task.isCancelled { return }
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
                            source: .systemNotice
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
                        source: .userAnswer
                    )
                    continue
                }

                // Plan mode: block any write/exec tool until the user has
                // approved a plan. The reply goes back as a tool error so
                // the model knows to stop and emit a plan.
                if risk != .read && runtime.isPlanGateActive {
                    anyDenied = true
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Plan mode: needs user approval"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Blocked: Plan mode is active and no plan has been approved yet. Emit a ```plan``` block listing the steps you intend to take, then stop and wait for the user to approve.",
                        source: .systemNotice
                    )
                    continue
                }

                if risk != .read && !isAlwaysAllowed {
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    if Task.isCancelled { return }
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
                            source: .systemNotice
                        )
                        continue
                    }
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .running
                        runtime.toolCalls[index].approvalSource = sandboxDecision.mode == .escalated ? .escalated : .user
                    }
                }

                // `spawn_agent` can't run through AgentToolRunner — it
                // needs the turn's provider configuration plus the
                // subagent registry, both of which only exist up here.
                if call.toolName == "spawn_agent" {
                    await executeSpawnAgentToolCall(
                        call,
                        recordID: recordID,
                        arguments: argsDict,
                        runtime: runtime,
                        configuration: configuration,
                        workspaceURL: workspaceURL
                    )
                    continue
                }

                let patchAutoApplySource = patchAutoApplySource(
                    forToolName: call.toolName,
                    runtime: runtime
                )
                let context = AgentToolContext(
                    rootDirectory: workspaceURL,
                    workspaceLocation: workspaceLocation,
                    runtimeDescriptor: remoteRuntimeDescriptor,
                    runtimeID: runtime.id,
                    jobRegistry: agentJobRegistry,
                    sandboxMode: sandboxModeForToolExecution(
                        risk: risk,
                        approvalSource: autoApproval,
                        sandboxDecision: sandboxDecision
                    ),
                    patchProposalSink: { title, diff in
                        try self.enqueueAgentPatchProposal(
                            for: runtime,
                            messageID: assistantID,
                            title: title,
                            diff: diff,
                            autoApplySource: patchAutoApplySource
                        )
                    },
                    patchAutoApplySource: patchAutoApplySource
                )
                do {
                    let result = try await AgentToolRunner.run(
                        name: call.toolName,
                        arguments: argsDict,
                        context: context
                    )
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .succeeded
                        runtime.toolCalls[index].result = result
                        if let patchAutoApplySource {
                            runtime.toolCalls[index].approvalSource = patchAutoApplySource
                        }
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
                    if call.toolName == "run_command" || risk != .read || patchAutoApplySource != nil {
                        await refreshGitStatusAfterAgentTool(
                            for: runtime,
                            workspaceURL: workspaceURL,
                            baselineFingerprint: turnBaselineSnapshot.fingerprint
                        )
                    }
                    appendToolMessage(for: runtime, toolCallID: call.externalID, payload: result.payload)
                } catch {
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .failed
                        runtime.toolCalls[index].errorMessage = error.localizedDescription
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
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Tool error: \(error.localizedDescription)",
                        source: .systemNotice
                    )
                }
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

    private func patchAutoApplySource(
        forToolName toolName: String,
        runtime: AgentRuntime
    ) -> AgentToolApprovalSource? {
        guard toolName == "apply_patch" else { return nil }
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
                runtime.toolDecisionWaiter = continuation
            }
        } onCancel: {
            // The cancellation handler runs synchronously off the cancelling
            // task — it's nonisolated, so we hop back to the main actor to
            // touch the runtime's continuation slot.
            Task { @MainActor [weak runtime] in
                guard let runtime else { return }
                if let waiter = runtime.toolDecisionWaiter {
                    runtime.toolDecisionWaiter = nil
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
    nonisolated static func backgroundJobCompletionNotice(for job: AgentBackgroundJob) -> String {
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
        return """
        <background-task-notification>
        Background job \(job.displayHandle) finished while you were not in this turn.
        Command: \(trimmedCommand)
        Status: \(job.status.rawValue) (\(exitText)), duration \(durationText).
        \(outputHint)
        </background-task-notification>
        """
    }

    /// Execute one `spawn_agent` tool call: synchronous runs await the
    /// child loop and return its report inline; background runs return
    /// a handle and deliver via `subagentReportNotice` on a later round.
    func executeSpawnAgentToolCall(
        _ call: AgentMessageToolCall,
        recordID: AgentToolCall.ID,
        arguments: [String: AgentJSONValue],
        runtime: AgentRuntime,
        configuration: AgentConfiguration,
        workspaceURL: URL?
    ) async {
        func finishRecord(status: AgentToolCallStatus, summary: String, payload: String, errorMessage: String? = nil) {
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                runtime.toolCalls[index].status = status
                runtime.toolCalls[index].errorMessage = errorMessage
                if status == .succeeded {
                    runtime.toolCalls[index].result = AgentToolResult(summary: summary, payload: payload)
                }
            }
            appendToolMessage(
                for: runtime,
                toolCallID: call.externalID,
                payload: payload,
                source: status == .succeeded ? .toolOutput : .systemNotice
            )
        }

        let prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            finishRecord(
                status: .failed,
                summary: "missing prompt",
                payload: "Tool error: \(AgentSubagentError.missingPrompt.localizedDescription)",
                errorMessage: AgentSubagentError.missingPrompt.localizedDescription
            )
            return
        }

        let label: String = {
            if let raw = arguments["label"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return String(raw.prefix(60))
            }
            return String(prompt.prefix(40))
        }()
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? false

        var childConfiguration = configuration
        if let modelOverride = arguments["model"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelOverride.isEmpty {
            childConfiguration.model = modelOverride
        }

        if runInBackground {
            do {
                let run = try agentSubagentRegistry.startBackground(
                    prompt: prompt,
                    label: label,
                    configuration: childConfiguration,
                    workspaceURL: workspaceURL,
                    parentRuntimeID: runtime.id
                )
                finishRecord(
                    status: .succeeded,
                    summary: "started \(run.displayHandle)",
                    payload: "Subagent \(run.displayHandle) (\(label)) started in the background on model \(childConfiguration.model). Its report will arrive as a <subagent-report> system message when it finishes — keep working on other things or end your turn; do not poll."
                )
            } catch {
                finishRecord(
                    status: .failed,
                    summary: "spawn failed",
                    payload: "Tool error: \(error.localizedDescription)",
                    errorMessage: error.localizedDescription
                )
            }
            return
        }

        do {
            let outcome = try await AgentSubagentRunner.run(
                prompt: prompt,
                configuration: childConfiguration,
                workspaceURL: workspaceURL
            )
            let stats = "(subagent \(label): \(outcome.roundCount) round\(outcome.roundCount == 1 ? "" : "s"), \(outcome.toolInvocationCount) tool call\(outcome.toolInvocationCount == 1 ? "" : "s")\(outcome.usageTokens > 0 ? ", \(outcome.usageTokens) tokens" : ""))"
            finishRecord(
                status: .succeeded,
                summary: stats,
                payload: "\(outcome.report)\n\n\(stats)"
            )
        } catch is CancellationError {
            finishRecord(
                status: .failed,
                summary: "cancelled",
                payload: "Subagent cancelled.",
                errorMessage: "Cancelled"
            )
        } catch {
            finishRecord(
                status: .failed,
                summary: "subagent failed",
                payload: "Tool error: \(error.localizedDescription)",
                errorMessage: error.localizedDescription
            )
        }
    }

    nonisolated static func subagentReportNotice(for run: AgentSubagentRun) -> String {
        let durationText: String = {
            let total = Int(run.duration.rounded())
            if total < 60 { return "\(total)s" }
            let m = total / 60, s = total % 60
            if m < 60 { return "\(m)m\(s)s" }
            let h = m / 60, mm = m % 60
            return "\(h)h\(mm)m"
        }()
        return """
        <subagent-report>
        Subagent \(run.displayHandle) (\(run.label)) finished: \(run.status.rawValue), duration \(durationText), \(run.roundCount) rounds, \(run.toolInvocationCount) tool calls.
        Report:
        \(run.report)
        </subagent-report>
        """
    }

    func appendToolMessage(
        for runtime: AgentRuntime,
        toolCallID: String,
        payload: String,
        source: AgentInjectionDefense.ToolMessageSource = .toolOutput
    ) {
        let sanitized = AgentInjectionDefense.sanitizedToolMessageContent(
            payload: payload,
            source: source
        )
        let limited: String
        let maxPayload = 24_000
        if sanitized.count > maxPayload {
            limited = String(sanitized.prefix(maxPayload)) + "\n...[tool output truncated]"
        } else {
            limited = sanitized
        }
        runtime.messages.append(
            AgentMessage(role: .tool, content: limited, toolCallID: toolCallID)
        )
    }

}
