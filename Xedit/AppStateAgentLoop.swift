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
        existingUserMessageID: AgentMessage.ID? = nil
    ) {
        resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime)

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
        } else {
            userMessage = AgentMessage(
                role: .user,
                content: text,
                images: images,
                textAttachments: textAttachments
            )
            runtime.messages.append(userMessage)
            runtime.latestTurnRecall = nil
            persistAgentSession(runtime: runtime)
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
        runtime.isResponding = true
        runtime.turnStartedAt = Date()
        runtime.currentTurnAttachedSkills = attachedSkills

        // The user's message was already appended and persisted to disk
        // above, before the slot gate — so even if the turn hangs
        // (slow/flaky proxy) and the app is quit mid-flight, the on-disk
        // session already holds it and `pruneEmptyAgentSessions` can't
        // delete the row as "empty". No second persist needed here.
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
    /// when the runtime is fully idle; if the provider is saturated we bow
    /// out and let a later turn surface it (never enqueue a phantom user
    /// message for this).
    @MainActor
    func resumeAgentLoopForPendingBackgroundCompletions(for runtime: AgentRuntime) {
        guard !runtime.isResponding,
              !runtime.isAwaitingProviderSlot,
              !runtime.isCompressingContext,
              runtime.requestTask == nil else { return }
        guard agentJobRegistry.pendingCompletionCount(forRuntime: runtime.id) > 0 else { return }

        let configuration = configurationForCurrentTurn(for: runtime)
        let providerID = configuration.providerID
        guard acquireProviderSlotIfPossible(providerID: providerID) else { return }

        runtime.isAwaitingProviderSlot = false
        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()

        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self else { return }
            guard let runtime else {
                self.releaseProviderSlot(providerID: providerID)
                return
            }
            await self.runAgentLoop(for: runtime, configuration: configuration)
        }
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
            // A background job can finish in the tiny window between this
            // turn's last drain and its end. If one did — and no queued
            // user message just claimed the runtime above — kick a fresh
            // turn so the completion isn't stranded until the next message.
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }

        let client = AgentClient(configuration: configuration)
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
        let turnBaselineSnapshot = await Self.loadAgentWorktreeSnapshot(for: workspaceURL)
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
            if !finishedMediaTasks.isEmpty, activeRuntime === runtime {
                let focusTask = finishedMediaTasks.first(where: \.needsAttention) ?? finishedMediaTasks.first
                agentMediaTaskPanelScope = focusTask.flatMap(Self.mediaTaskPanelScope)
                agentSidePanelRequest = AgentSidePanelOpenRequest(
                    kind: .mediaTasks,
                    mediaTaskScope: agentMediaTaskPanelScope
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
            if !pendingWidgets.isEmpty, activeRuntime === runtime {
                agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
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
            let activeExperts = runtime.activeExperts
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
                activeExperts: activeExperts,
                promptProfile: promptProfile
            )
            if let remoteRuntimeDescriptor,
               case .remote(_, let remotePath) = workspaceLocation {
                let transportLabel = remoteRuntimeDescriptor.transport == .daemon ? "daemon" : "SSH"
                systemPrompt += """

                === REMOTE WORKSPACE (\(transportLabel)) ===
                - Runtime: \(remoteRuntimeDescriptor.displayName) (\(remoteRuntimeDescriptor.sshTarget))
                - Platform: \(remoteRuntimeDescriptor.platform.displayName) / \(remoteRuntimeDescriptor.arch.displayName)
                - Remote root: \(remotePath)

                Not every tool runs on the remote box. Know the split before you act:

                RUN ON THE REMOTE RUNTIME (these reach \(remoteRuntimeDescriptor.sshTarget)):
                - search_files, grep_files, read_file, list_directory, git_status — read remote files.
                - run_command — executes on the remote box, in the remote root. This is your main hands-on tool here; use it for edits too (e.g. `sed -i`, `python - <<'PY'`, `git apply`, writing heredocs), inspecting processes, services, disk, logs.
                - claude_code / codex_cli / cursor_agent / cline_cli — the delegated CLI runs on the remote box (it must be installed there).

                RUN ON THE LOCAL MAC, NOT the remote box — do NOT use these to change or inspect the remote workspace:
                - create_file / apply_patch — create or patch LOCAL files; they do NOT touch remote files. For remote file creation or edits use run_command.
                - terminal_snapshot / terminal_send_command / terminal_send_control — drive the visible side-panel terminal, which is a LOCAL shell by default (unless the user themselves opened an SSH tab to this host)\(remoteRuntimeDescriptor.transport == .daemon ? "; for a daemon runtime it can never reach the remote box" : ""). To run something on the remote box, use run_command, not the terminal tools.
                - skills / memory / MCP management (list_skills, read_skill, add_memory, create_user_skill, update_user_skill, delete_user_skill, search_mcp_servers, suggest_mcp_server, configure_mcp_server), chrome_*, web_search, web_fetch, generate_image, visual_qa_screenshot — these are about the local WillDeep install / this Mac, not the remote host. web_fetch also can't reach the remote box's private/loopback services.

                Tell the user when an action is local vs remote if it matters.
                """
            }
            if activeExperts.contains(.shortDrama), let latestImageChoice = runtime.latestImageChoice {
                systemPrompt += "\n\n\(latestImageChoice.systemPromptBlock)"
            }
            if let latestImageEditSubmission = runtime.latestImageEditSubmission {
                // Image-edit submission follow-up anchors live in AgentImageEditSubmission:
                // review_item_id: \(reviewItemID)
                // resolve_review_tool: short_drama_resolve_review_item
                // item_id=\(reviewItemID)
                systemPrompt += "\n\n\(latestImageEditSubmission.systemPromptBlock)"
            }
            if let latestMediaTaskCompletion = runtime.latestMediaTaskCompletion {
                systemPrompt += "\n\n\(latestMediaTaskCompletion.systemPromptBlock)"
            }
            if let latestMediaTaskRefresh = runtime.latestMediaTaskRefresh {
                systemPrompt += "\n\n\(latestMediaTaskRefresh.systemPromptBlock)"
            }
            if let latestMediaImport = runtime.latestMediaImport {
                systemPrompt += "\n\n\(latestMediaImport.systemPromptBlock)"
            }
            if let latestWidgetToolAction = runtime.latestWidgetToolAction {
                systemPrompt += "\n\n\(latestWidgetToolAction.systemPromptBlock)"
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
            let history = Self.modelFacingHistory(
                messages: runtime.messages,
                contextSummary: runtime.contextSummary,
                contextSummaryThroughMessageID: runtime.contextSummaryThroughMessageID,
                excludingMessageID: assistantID
            )
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
                            tools: AgentToolRegistry.tools(activeExperts: activeExperts)
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
                let context = AgentToolContext(
                    rootDirectory: workspaceURL,
                    workspaceLocation: workspaceLocation,
                    runtimeDescriptor: remoteRuntimeDescriptor,
                    runtimeID: runtime.id,
                    jobRegistry: agentJobRegistry,
                    mediaTaskRegistry: agentMediaTaskRegistry,
                    shortDramaStore: agentShortDramaStore,
                    sandboxMode: sandboxModeForToolExecution(
                        risk: risk,
                        approvalSource: autoApproval,
                        sandboxDecision: sandboxDecision
                    ),
                    patchProposalSink: { title, diff, applyImmediately in
                        try self.enqueueAgentPatchProposal(
                            for: runtime,
                            messageID: assistantID,
                            title: title,
                            diff: diff,
                            autoApplySource: patchAutoApplySource,
                            applyImmediately: applyImmediately
                        )
                    },
                    patchAutoApplySource: patchAutoApplySource,
                    terminalController: agentTerminalController
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
                            baselineSnapshot: turnBaselineSnapshot
                        )
                    }
                    appendToolMessage(for: runtime, toolCallID: call.externalID, payload: result.payload)
                } catch {
                    let workspaceIssue = diagnoseLocalWorkspaceIfNeeded(
                        after: error,
                        runtime: runtime,
                        workspaceURL: workspaceURL
                    )
                    let errorMessage = workspaceIssue ?? error.localizedDescription
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
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Tool error: \(errorMessage)\n\n(WillDeep: this tool call failed. Do not stop here — diagnose the cause from the exit code/stderr above and try another approach to accomplish the goal. Only give up if you are genuinely blocked, and then explain what you tried and what you still need.)",
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
        guard toolName == "apply_patch" || toolName == "create_file" else { return nil }
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

    /// Execute one `spawn_agent` tool call: synchronous runs await the
    /// child loop and return its report inline; background runs return
    /// a handle and deliver via `subagentReportNotice` on a later round.
    func executeSpawnAgentToolCall(
        _ call: AgentMessageToolCall,
        recordID: AgentToolCall.ID,
        arguments: [String: AgentJSONValue],
        runtime: AgentRuntime,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor?,
        workspaceLocation: WorkspaceLocation?
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
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation,
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
                workspaceURL: workspaceURL,
                runtimeDescriptor: runtimeDescriptor,
                workspaceLocation: workspaceLocation
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

    private func diagnoseLocalWorkspaceIfNeeded(
        after error: Error,
        runtime: AgentRuntime,
        workspaceURL: URL?
    ) -> String? {
        guard workspaceURL != nil else { return nil }
        if let availabilityError = error as? AgentWorkspaceAvailabilityError {
            return availabilityError.localizedDescription
        }
        guard let availability = runtime.diagnoseLocalWorkspaceAfterFailure(),
              availability.blocksLocalWorkspaceUse,
              let message = availability.message else {
            return nil
        }
        runtime.errorMessage = message
        runtime.errorDetails = nil
        persistAgentSession(runtime: runtime)
        return message
    }

}
