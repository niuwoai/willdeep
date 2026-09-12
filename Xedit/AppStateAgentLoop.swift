//
//  AppStateAgentLoop.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Owns the heavy Agent-mode runtime path:
//
//    - runAgentLoop async streaming loop and everything it inlines
//
//  `dispatchAgentMessage` moved to AppStateAgentLoopDispatch.swift when this
//  file crossed the 3000-line hard limit in `scripts/complexity_guard.rb`.
//  Splitting what is left means carving up a 2600-line function body rather
//  than moving a whole declaration, so it stays here until someone takes that
//  on as a refactor with tests, not as a file move.
//
//    - prepareImagesForTextOnlyProvider / describe helpers
//    - consumeNextQueuedMessageIfNeeded
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
//  estimates live in AppStateAgentRequestEstimates.swift. What runAgentLoop
//  delegates to — the read-only parallel tool batch, patch-review path keys
//  and the serial tool-decision handoff — lives in
//  AppStateAgentLoopToolBatching.swift; the background-job completion
//  notice lives in AppStateAgentBackgroundJobNotices.swift and the
//  media-task one in AppStateAgentMediaTaskNotices.swift. Conversation reset,
//  context-runway handoff, and terminal-reveal lifecycle helpers live in
//  AppStateAgentLoopLifecycle.swift.
//

import WillDeepCore
import AppKit
import Foundation

extension AppState {
    @MainActor
    func runAgentLoop(
        for runtime: AgentRuntime,
        configuration: AgentConfiguration,
        providerSlotClaimID: UUID,
        turnID: UUID
    ) async {
        guard !Task.isCancelled, runtime.acceptsResponseEvents(for: turnID) else {
            finishAgentLoopTurn(for: runtime, turnID: turnID, providerSlotClaimID: providerSlotClaimID,
                                providerID: configuration.providerID, shouldResumePendingEvents: false)
            return
        }
        // This turn just went live (isResponding was set true by the caller).
        // Refresh the same-checkout collision hint so the foreground composer
        // reflects a background session now working in its directory.
        refreshAgentWorkspaceCollision()
        _ = startAgentGoalPlanningIfNeeded(for: runtime)
        // 本回合的遥测累计。回合内可能跑多轮 provider 请求（工具调用循环），
        // token 累加、降级次数累加；下面的 defer 在每条退出路径上提交一次。
        // 只记供应商、模型、耗时、token 和结构化错误码——不碰任何消息内容。
        let turnTelemetry = AgentTurnTelemetry(
            providerID: configuration.providerID,
            requestedModel: configuration.model,
            resolvedModel: configuration.model,
            credentialSource: AgentTelemetry.credentialSource(
                providerID: configuration.providerID,
                baseURL: configuration.baseURL,
                hasAPIKey: !configuration.apiKey.isEmpty
            )
        )
        // Local turn-timing probe. A background wake-up mints a fresh turn id
        // and therefore a fresh probe; `turnStartedAt` was stamped at dispatch
        // (or at the wake-up), so the pre-stream span includes routing, the
        // optional preflight and prompt assembly.
        if runtime.currentTurnTiming?.turnID != turnID {
            runtime.currentTurnTiming = AgentTurnTimingProbe(
                sessionID: runtime.id,
                turnID: turnID,
                dispatchedAt: runtime.turnStartedAt ?? Date(),
                providerID: configuration.providerID,
                model: configuration.model,
                routeProfileID: runtime.currentTurnRouteDecision?.profileID,
                routeConfidence: runtime.currentTurnRouteDecision?.confidence,
                delegationPolicy: runtime.currentTurnDelegationPolicy.rawValue
            )
        }
        var shouldResumePendingEventsAtTurnEnd = true
        defer {
            AgentTelemetry.recordTurnFinished(turnTelemetry)
            // The parallel scout belongs to this turn: cancel it if it is
            // still running, drop an undelivered report, then write the
            // turn's timing line. Runs before the wake-up probes below so a
            // scout can never be mistaken for pending background work.
            if runtime.activeTurnID == turnID {
                finalizeTurnTiming(
                    for: runtime,
                    turnID: turnID,
                    outcome: String(describing: turnTelemetry.status)
                )
            }
            // Any event still leased here was not acknowledged by a completed
            // provider request. Put it back before the final wakeup probe so a
            // cancellation, transport failure, or host preemption can retry in
            // this process rather than waiting for an app restart.
            agentRuntimeKernel.releaseModelDeliveryLeases(
                for: runtime.id,
                leaseID: turnID
            )
            let computerUseLeaseID: AgentComputerUseLease.ID? = {
                guard let lease = AgentComputerUseCoordinator.shared.state.lease,
                      lease.owner.runtimeID == runtime.id,
                      lease.owner.turnID == turnID else {
                    return nil
                }
                return lease.id
            }()
            AgentComputerUseCoordinator.shared.finishTurn(
                runtimeID: runtime.id,
                turnID: turnID
            )
            // Computer Use approvals are intentionally turn-scoped. The
            // exclusive lease binds calls to one target during this turn;
            // retaining `computer_use:*` into a later turn would silently
            // authorize a different target or newly consequential action.
            if runtime.activeTurnID == turnID {
                runtime.conversationAllowedToolSignatures.remove("computer_use:*")
            }
            if let computerUseLeaseID {
                Task {
                    try? await AgentComputerUseBridge.shared.endControlSession(
                        controlLeaseID: computerUseLeaseID.uuidString.lowercased()
                    )
                }
            }
            // Design gate: hand over the card, or stand down. Runs before the
            // turn is finished off so the card is in the transcript by the
            // time the composer becomes available again — a gate that locks
            // write tools without showing what it is waiting for is just a
            // broken session.
            finalizeSpecGateTurn(for: runtime)
            finishAgentLoopTurn(
                for: runtime, turnID: turnID, providerSlotClaimID: providerSlotClaimID,
                providerID: configuration.providerID,
                shouldResumePendingEvents: shouldResumePendingEventsAtTurnEnd
            )
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
            beginGoalExecutionBudgetIfNeeded(for: runtime)
            let judgeClient = AgentClient(configuration: configuration, session: agentLoopInferenceEnvironment?.session,
                someIMContext: someIMContext, requestLedger: modelRequestLedger(for: runtime))
            let routeJudge = AgentGoalRouteJudge(client: judgeClient, executionBudget: auxiliaryModelExecutionBudget(for: runtime))
            // Routing must never wait on the account control plane. The
            // launch timer owns refreshes; a stale value is still a better
            // latency trade than blocking the first provider request.
            let hasCodingPlan = someIMCodingPlanStatus.isActiveNow
            if someIMCodingPlanStatus.isStale {
                refreshSomeIMCodingPlanStatus(force: false)
            }
            let resolution = await SomeIMManagedRouting.route(
                input: judgeInput,
                floor: floor,
                hasCodingPlan: hasCodingPlan
            ) { system, user, maxTokens in
                await routeJudge.text(model: SomeIMManagedModel.judge, system: system, user: user, maxTokens: maxTokens)
            }
            if stopAfterRouteJudge(routeJudge, runtime: runtime) { return }
            // Captured BEFORE noteManagedSelectedModel overwrites it — the
            // escalation check below compares against the tier the session
            // actually ran on last turn.
            let previousManagedModel = runtime.managedRouting?.lastSelectedModel
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
            // 升档前压缩（见 muchtoken docs/someim-32b-compressor.md）：
            // 切到高档模型本来就必然使前缀缓存失效，此刻压缩零缓存损失，
            // 却直接削减高档模型要摄入的 input。只在 turn 开始的路由升档
            // 处做；输出质检的 mid-turn 升档重跑不压——一轮之内不改写
            // 历史，避免 tool_call 配对漂移。低于阈值或压缩失败都原文
            // 照发，不阻塞本轮。
            if Self.managedEscalationCrossesTier(
                previousModel: previousManagedModel,
                newTier: resolution.effectiveTier
            ) {
                await compressBeforeManagedEscalationIfNeeded(
                    for: runtime,
                    escalatedModel: resolution.model,
                    providerID: turnConfiguration.providerID
                )
            }
        }
        if runtime.activeTurnID == turnID {
            runtime.activeTurnConfiguration = turnConfiguration
        }
        // 省心托管路由（以及后面的质检升档）会改掉实际执行的模型；
        // 遥测记的是「最后真正跑的那个」，与 requested 不同即计一次改派。
        turnTelemetry.providerID = turnConfiguration.providerID
        turnTelemetry.noteResolvedModel(turnConfiguration.model)

        // `var` so a managed output-quality failure can swap in an escalated
        // client and re-run the round (see the no-tool-call guard below).
        var client = AgentClient(
            configuration: turnConfiguration,
            session: agentLoopInferenceEnvironment?.session,
            someIMContext: someIMContext,
            openAIResponsesContinuationState: runtime.openAIResponsesContinuationState,
            requestLedger: modelRequestLedger(for: runtime)
        )
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
            shouldResumePendingEventsAtTurnEnd = false
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
        async let turnBaselineSnapshotTask = Self.loadAgentWorktreeSnapshot(
            for: workspaceURL
        )
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
        // Everything scoring did not surface, one hook line each. Cheap enough
        // to send every turn, and it is what makes `read_memory` reachable —
        // the model cannot ask for a memory it was never told exists.
        let memoryIndexBlock = AgentMemoryEngine.indexBlock(
            records: memoryState.memories,
            excluding: Set(retrievedMemories.map(\.record.id)),
            settings: memoryState.settings,
            rootDirectory: workspaceURL
        )
        // Git status and memory retrieval are independent. Let the subprocess
        // run while the host scores local memories instead of serializing both
        // ahead of the first provider request.
        let turnBaselineSnapshot = await turnBaselineSnapshotTask
        if workspaceURL != nil {
            runtime.worktreeChanges = turnBaselineSnapshot.changes.filtering(paths: runtime.agentEditedPaths)
        }

        // Managed-routing output quality caps its escalation at one retry per
        // user turn (design doc §"重试限制").
        var didQualityRetry = false
        var planAutomaticContinuationCount = 0
        var consecutivePlanRepliesWithoutProgress = 0
        var didAdvancePlanSinceLastContinuationDecision = false
        var isPlanProgressReconciliationActive = false
        /// Baseline for "did anything actually run since the last plan
        /// continuation decision". Only `.succeeded` calls count: a
        /// reconciliation round denies write tools, and those denials must
        /// not read back as evidence of progress.
        var succeededToolCallCountAtLastContinuationDecision = runtime.toolCalls
            .filter { $0.status == .succeeded }
            .count
        let designToCodeToolCallBaseline = runtime.toolCalls.count
        let latestUserImages = runtime.messages.last(where: { $0.isOperatorInput })?.images ?? []
        let requiresDesignToCodeAcceptance = workspaceURL != nil && AgentDesignToCode.isActive(
            skills: runtime.currentTurnAttachedSkills,
            images: latestUserImages
        )
        var designToCodeGateContinuationCount = 0
        var didRequestContextRunwayHandoff = false
        /// Rounds already spent making the model answer the handoff with prose
        /// instead of a tool call. Bounded by `maximumHandoverRetries`.
        var contextRunwayHandoverRetryCount = 0
        /// Plan-on-demand asks once per turn; crossing the threshold again
        /// after the model ignored the first request must not nag every round.
        var didRequestPlanOnDemand = false
        let planOnDemandToolCallBaseline = runtime.toolCalls.count
        /// Host-side progress accounting for an executing plan: rounds since
        /// the last successful `update_plan`, and how many such calls this
        /// turn has seen so a new one can be detected without a callback.
        var toolRoundsSinceLastPlanUpdate = 0
        var planUpdateCallsSeen = 0

        for toolRound in 0..<Self.maxAgentToolRounds {
            beginGoalExecutionBudgetIfNeeded(for: runtime)
            // The host kernel is the single prioritized interrupt queue. It
            // persists events across restarts and delivers them only at a
            // model/tool boundary. Legacy registries are still drained below
            // for compatibility; resource ids prevent double delivery while
            // producers migrate onto the kernel.
            let kernelEvents = consumeAdmittedKernelEvents(for: runtime, leaseID: turnID)
            let kernelResourceKeys = Set(kernelEvents.compactMap { event -> String? in
                guard let resourceID = event.metadata["resource_id"] else { return nil }
                return "\(event.source.rawValue):\(resourceID)"
            })
            for event in kernelEvents {
                let marker = "<runtime-event id=\"\(event.id.uuidString)\""
                if !runtime.messages.contains(where: {
                    $0.source == .hostInstruction && $0.content.contains(marker)
                }) {
                    runtime.messages.append(
                        AgentMessage(
                            role: .user,
                            content: agentRuntimeKernel.modelNotice(for: event),
                            source: .hostInstruction
                        )
                    )
                }
            }

            // `run_workflow` is asynchronous, but unlike the workflow card its
            // final report must return to the model that delegated the work.
            // Consume the owning runtime's pending ids into normal system
            // messages so every provider adapter receives the result without
            // exposing the raw card object itself.
            let finishedWorkflows = consumePendingWorkflowCompletions(for: runtime)
            for report in finishedWorkflows {
                guard !kernelResourceKeys.contains("workflow:\(report.id.uuidString)"),
                      !agentRuntimeKernel.hasPendingEvent(
                          runtimeID: runtime.id,
                          source: .workflow,
                          resourceID: report.id
                      ) else { continue }
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
            appendPendingBackgroundJobCompletions(for: runtime, excluding: kernelResourceKeys)

            let finishedMediaTasks = agentMediaTaskRegistry.consumePendingCompletions(forRuntime: runtime.id)
            for task in finishedMediaTasks {
                recordAgentMediaTaskCompletion(task: task, runtimeID: runtime.id)
                guard !kernelResourceKeys.contains("media_task:\(task.id.uuidString)"),
                      !agentRuntimeKernel.hasPendingEvent(
                          runtimeID: runtime.id,
                          source: .mediaTask,
                          resourceID: task.id
                      ) else {
                    continue
                }
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
                guard !kernelResourceKeys.contains("worker:\(finishedRun.id.uuidString)"),
                      !agentRuntimeKernel.hasPendingEvent(
                          runtimeID: runtime.id,
                          source: .worker,
                          resourceID: finishedRun.id
                      ) else {
                    continue
                }
                runtime.messages.append(
                    AgentMessage(
                        role: .system,
                        content: Self.subagentReportNotice(for: finishedRun)
                    )
                )
            }

            // The turn's own parallel scout reports through here too — never
            // through the registry's pending-report queue, so it can never
            // wake this runtime once the turn has ended.
            if let scoutReport = takeSpeculativeScoutReportIfReady(for: runtime) {
                runtime.messages.append(AgentMessage(role: .system, content: scoutReport))
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
            async let roundWorkspaceRevisionTask = AgentWorkspaceRevisionCapture.capture(for: workspaceURL)

            let assistantMessage = AgentMessage(
                role: .assistant,
                content: "",
                requestIsLocal: AgentLocalModelPrompting.isLocalProvider(turnConfiguration),
                origin: .nativeModel,
                requestModelID: turnConfiguration.model,
                requestProviderID: turnConfiguration.providerID,
                requestProviderDisplayName: runtime.session.providerDisplayName
            )
            runtime.messages.append(assistantMessage)
            let assistantID = assistantMessage.id
            // Cancellation, provider retry, or any other early exit must not
            // strand a visible patch card in the non-interactive collecting
            // state.
            defer {
                runtime.collectingPatchReviewMessageIDs.remove(assistantID)
            }
            // Stamp the wall-clock start so we can attach an elapsed
            // seconds value to the message footer once the stream
            // finishes. We use the moment we hand the request off to
            // the client — pre-network — because that's what the user
            // perceives as "how long did the agent take".
            let turnStartedAt = Date()
            runtime.lastActivityAt = turnStartedAt

            // Build the system prompt against the runtime's workspace,
            // not whatever the window happens to be focused on. The
            // active tab / selection still come from AppState — that's
            // window-level context the user can flip while another
            // session is running, and the model just sees it as
            // "what's on screen right now".
            let promptProfile = AgentSystemPromptProfile.automatic(for: configuration)
            let activeExperts = runtime.activeExperts
            // Accessibility is granted to the ComputerUseHelper process, so
            // the sticky bridge marker (set the first time the helper
            // reports the grant) is the truthful cheap signal; before that,
            // the protocol text would be dead weight on every request.
            let promptCapabilities = AgentPromptCapabilities(
                activeExperts: activeExperts,
                computerUseGranted: AgentComputerUseBridge.accessibilityEverGranted,
                sandboxEnabled: !runtime.localSandboxDisabled
            )
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
                planProgressFormatViolation: latestTurnHasUnparsableProgressBlock(for: runtime),
                currentGoal: runtime.currentGoal,
                goalPlanningState: runtime.goalPlanningState,
                goalRoadmap: runtime.goalRoadmap,
                currentSessionTitle: runtime.session.title,
                currentSessionTitleIsLocked: runtime.session.titleIsUserSet,
                workspaceSessions: workspaceSessionSnapshots(for: runtime),
                activeExperts: activeExperts,
                promptProfile: promptProfile,
                capabilities: promptCapabilities
            )
            let projectWorkspaceRoots = agentWorkspaceRoots(for: runtime.session)
            if projectWorkspaceRoots.count > 1 {
                assembledPrompt += """

                === PROJECT WORKSPACE ROOTS ===
                This Project explicitly authorizes all folders below. Relative paths resolve against the first root; use an absolute path for another root.
                \(projectWorkspaceRoots.map { "- \($0.path)" }.joined(separator: "\n"))
                """
            }
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
                - claude_code / codex_cli / hermes_cli / cursor_agent / cline_cli / opencode_cli — the delegated CLI runs on the remote box (it must be installed there).

                RUN ON THE LOCAL MAC, NOT the remote box — do NOT use these to change or inspect the remote workspace:
                - create_file / edit_file / apply_patch — create or edit LOCAL files; they do NOT touch remote files. For remote file creation or edits use run_command.
                - terminal_snapshot / terminal_send_command / terminal_send_control / terminal_list_tabs / terminal_select_tab — drive the ACTIVE side-panel terminal tab, the one the user currently sees. It is a LOCAL shell by default (unless an SSH tab is active)\(remoteRuntimeDescriptor.transport == .daemon ? "; for a daemon runtime it can never reach the remote box" : ""). To run something on the remote box, use run_command, not the terminal tools.
                - \(AgentTerminalAutomationPolicy.userOnlyShortcutPlaybackRule)
                - skills / memory / MCP management (list_skills, read_skill, add_memory, create_user_skill, create_user_skills, update_user_skill, delete_user_skill, search_mcp_servers, suggest_mcp_server, configure_mcp_server), chrome_*, computer_use_*, web_search, web_fetch, generate_image, visual_qa_screenshot, capture_screenshot — these are about the local WillDeep install / this Mac, not the remote host. web_fetch also can't reach the remote box's private/loopback services.

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
            if let memoryIndexBlock {
                assembledPrompt += "\n\n\(memoryIndexBlock)"
            }
            // Per-turn `/subagent` / `/no-subagent` directive. `.forbidden`
            // is already enforced by the tool table below; this paragraph
            // only stops the model from burning a round on a call that the
            // transport would reject.
            if let delegationInstruction = runtime.currentTurnDelegationPolicy.systemPromptInstruction {
                assembledPrompt += "\n\n\(delegationInstruction)"
            }
            // The runtime's classification of this turn's request. Advisory
            // by design — it names the trade that fits so delegating is the
            // short path rather than the detour, and says so where the model
            // reads instructions rather than where the user reads their own
            // words.
            if let routeSteering = runtime.currentTurnRouteSteering {
                assembledPrompt += "\n\n\(routeSteering)"
            }
            // Design gate. Appended here rather than inside
            // AgentContextBuilder.systemPrompt so it lands after the dynamic
            // context marker: the cached stable prefix is untouched and none
            // of the three profile snapshot hashes move.
            if let gateBlock = runtime.specGateState.systemPromptBlock {
                assembledPrompt += "\n\n\(gateBlock)"
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
            let history = modelFacingHistory(for: runtime, excludingMessageID: assistantID)
            // No second attach on the request copy: `attachTurnContextIfNeeded`
            // above already persisted this turn's context onto `runtime.messages`
            // (setting the fresh user message's modelContext, or inserting a
            // hidden host carrier on notification-only wake-ups), so the
            // model-facing history and the next turn's replay share bytes.
            var collapsedHistory = Self.collapseOldToolResults(in: history)
            let requestTools = AgentToolRegistry.tools(
                activeExperts: activeExperts,
                interactionMode: runtime.interactionMode,
                executionAgent: runtime.executionAgent,
                delegationPolicy: runtime.currentTurnDelegationPolicy,
                loadedPacks: runtime.loadedToolPacks,
                // 已启用插件带的 MCP 工具，从缓存读，不在这里拉 tools/list：
                // 那会把 stdio 子进程拉起来，而这是每回合都走的路径。
                pluginMCPTools: AgentPluginMCPToolCatalog.descriptors(
                    activeServers: AgentMCPServerDirectory.list()
                )
            )
            let requestWithoutRunwayHandoff = [AgentMessage(role: .system, content: systemPrompt)]
                + collapsedHistory
            let estimatedRequestTokens = Self.estimateAgentTokens(
                messages: requestWithoutRunwayHandoff,
                tools: requestTools
            )
            runtime.contextSystemPromptTokenEstimate = Self.estimateTextTokens(systemPrompt)
            let providerAnchoredTokens = Self.providerAnchoredUsedTokens(
                messages: runtime.messages,
                contextSummaryThroughMessageID: runtime.contextSummaryThroughMessageID
            )
            let contextWindow = Self.agentContextWindow(
                model: turnConfiguration.model,
                providerID: turnConfiguration.providerID
            )
            let runwayDecision = AgentContextRunwayPolicy.evaluate(
                usedTokens: max(estimatedRequestTokens, providerAnchoredTokens ?? 0),
                contextWindow: contextWindow,
                toolRound: toolRound,
                handoffAlreadyRequested: didRequestContextRunwayHandoff
            )
            if case .handoff(let snapshot) = runwayDecision {
                let handoffInstruction = AgentMessage(
                    role: .user,
                    content: AgentContextRunwayPolicy.handoffPrompt(snapshot: snapshot),
                    source: .hostInstruction
                )
                if let assistantIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                    runtime.messages.insert(handoffInstruction, at: assistantIndex)
                }
                collapsedHistory.append(handoffInstruction)
                // Tool schemas deliberately stay declared. Dropping them used
                // to look like the strongest possible "no new work" — a
                // transport fact rather than a request the model could ignore
                // — but a model that decides to call a tool anyway calls it
                // anyway, and a provider whose tool-call parser is off because
                // the request declared no tools hands that call back as raw
                // markup inside `content`. The call is lost, the handover
                // never gets written, and compression runs regardless. So the
                // schemas stay (the window cost is schema-sized, while the
                // handover it protects is a few hundred tokens) and refusal
                // moves to where it can answer back: this loop, below.
                didRequestContextRunwayHandoff = true
            }
            // Plans on demand: ordinary turns start without a checklist, and
            // this is where a long turn earns one. Evaluated after the runway
            // decision because a handoff round may do no new work at all,
            // plan included.
            if !didRequestContextRunwayHandoff, !didRequestPlanOnDemand {
                let succeededWriteCalls = runtime.toolCalls
                    .dropFirst(planOnDemandToolCallBaseline)
                    .filter { $0.status == .succeeded && $0.risk != .read }
                    .count
                let hasActivePlan = runtime.currentPlan.map {
                    $0.status == .proposed || $0.status == .approved || $0.status == .executing
                } ?? false
                if AgentPlanOnDemandPolicy.shouldRequestPlan(
                    toolRound: toolRound,
                    succeededWriteCalls: succeededWriteCalls,
                    hasActivePlan: hasActivePlan,
                    interactionMode: runtime.interactionMode,
                    isUnattendedDispatchTask: runtime.isUnattendedDispatchTask
                ) {
                    let notice = AgentMessage(
                        role: .system,
                        content: AgentPlanOnDemandPolicy.requestNotice(toolRound: toolRound)
                    )
                    if let assistantIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                        runtime.messages.insert(notice, at: assistantIndex)
                    }
                    collapsedHistory.append(notice)
                    didRequestPlanOnDemand = true
                }
            }
            // Progress accounting for an executing plan. The model is asked
            // to call `update_plan` at every step change and mostly does so
            // only at the end of the turn; the host keeps count and asks
            // after `roundThreshold` silent rounds. Appended as the newest
            // host instruction, not a system message: every added `.system`
            // message rewrites the provider's cached system blob.
            if toolRound > 0 {
                let planUpdateCalls = runtime.toolCalls
                    .dropFirst(planOnDemandToolCallBaseline)
                    .filter { $0.toolName == "update_plan" && $0.status == .succeeded }
                    .count
                if planUpdateCalls > planUpdateCallsSeen {
                    planUpdateCallsSeen = planUpdateCalls
                    toolRoundsSinceLastPlanUpdate = 0
                } else {
                    toolRoundsSinceLastPlanUpdate += 1
                }
                let hasExecutingPlan = runtime.currentPlan.map {
                    $0.status == .executing && $0.interruptedAt == nil
                } ?? false
                if AgentPlanProgressNudgePolicy.shouldNudge(
                    roundsSinceLastUpdate: toolRoundsSinceLastPlanUpdate,
                    hasActivePlan: hasExecutingPlan,
                    isUnattendedDispatchTask: runtime.isUnattendedDispatchTask
                ) {
                    let nudge = AgentMessage(
                        role: .user,
                        content: AgentPlanProgressNudgePolicy.notice(
                            roundsSinceLastUpdate: toolRoundsSinceLastPlanUpdate
                        ),
                        source: .hostInstruction
                    )
                    if let assistantIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                        runtime.messages.insert(nudge, at: assistantIndex)
                    }
                    collapsedHistory.append(nudge)
                    toolRoundsSinceLastPlanUpdate = 0
                }
            }
            let requestMessages = [AgentMessage(role: .system, content: systemPrompt)] + collapsedHistory
            // Capture starts at the round boundary but joins only after prompt
            // assembly, preserving the guarded-mutation CAS point without
            // putting the Git subprocess wholly on the critical path.
            let roundWorkspaceRevision = await roundWorkspaceRevisionTask

            var finishReason: String?
            var latestToolCalls: [AgentMessageToolCall] = []
            let streamBuffer = AgentStreamingMessageBuffer(runtime: runtime, assistantID: assistantID)

            do {
                var retryCount = 0
                turnTelemetry.noteRequestStarted()
                runtime.currentTurnTiming?.noteRequestSent()
                while true {
                    do {
                        try await client.streamChat(
                            messages: requestMessages,
                            tools: requestTools,
                            executionBudget: modelExecutionBudget(for: runtime)
                        ) { event in
                            await MainActor.run { [weak runtime] in
                                guard let runtime,
                                      !Task.isCancelled,
                                      runtime.acceptsResponseEvents(for: turnID),
                                      let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
                                    return
                                }
                                // Every streamed event is proof of life for
                                // the turn watchdog, keepalives included.
                                self.noteAgentTurnActivity(for: runtime)
                                switch event {
                                case .requestIdentified(let requestID):
                                    turnTelemetry.noteRequestID(requestID)
                                case .textDelta(let delta):
                                    if !delta.isEmpty { self.noteAgentVisibleOutput(for: runtime) }
                                    if !delta.isEmpty, runtime.messages[index].firstResponseSeconds == nil {
                                        runtime.messages[index].firstResponseSeconds = Date().timeIntervalSince(turnStartedAt)
                                        runtime.currentTurnTiming?.noteFirstToken()
                                    }
                                    streamBuffer.appendTextDelta(delta)
                                case .reasoningDelta(let delta):
                                    // 推理不是可见输出（把它算进去，状态条会在
                                    // 一屏思考文本上宣布「已经在写了」），但它
                                    // 证明模型在动。分开记一个戳，让状态条能说
                                    // 「正在思考」而不是「什么也没收到」。
                                    if !delta.isEmpty { runtime.lastReasoningAt = Date() }
                                    if !delta.isEmpty, runtime.messages[index].firstResponseSeconds == nil {
                                        runtime.messages[index].firstResponseSeconds = Date().timeIntervalSince(turnStartedAt)
                                        runtime.currentTurnTiming?.noteFirstToken()
                                    }
                                    streamBuffer.appendReasoningDelta(delta)
                                case .toolCallsUpdated(let calls):
                                    // Rides the streaming buffer's overlay/slow
                                    // tier: argument-fragment growth no longer
                                    // publishes the whole messages array at
                                    // ~10 Hz (see updateToolCalls).
                                    streamBuffer.updateToolCalls(calls)
                                    latestToolCalls = calls
                                case .sourceReferencesUpdated(let references):
                                    streamBuffer.flushPending()
                                    runtime.messages[index].sourceReferences = references
                                case .finishedTurn(let reason):
                                    streamBuffer.flushPending()
                                    finishReason = reason
                                case .usageReported(let prompt, let completion, let total, let cachedPrompt, let cacheWritePrompt, let reasoning):
                                    streamBuffer.flushPending()
                                    turnTelemetry.addUsage(promptTokens: prompt, completionTokens: completion)
                                    runtime.messages[index].usageTokens = total
                                    runtime.messages[index].promptTokens = prompt > 0 ? prompt : nil
                                    runtime.messages[index].completionTokens = completion > 0 ? completion : nil
                                    runtime.messages[index].cachedPromptTokens = cachedPrompt
                                    runtime.messages[index].cacheWritePromptTokens = cacheWritePrompt
                                    runtime.messages[index].reasoningTokens = reasoning > 0 ? reasoning : nil
                                }
                            }
                        }
                        try Task.checkCancellation()
                        guard runtime.acceptsResponseEvents(for: turnID) else { throw CancellationError() }
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        streamBuffer.flushPending()
                        try Task.checkCancellation()
                        guard runtime.acceptsResponseEvents(for: turnID) else { throw CancellationError() }
                        guard shouldRetryTransientNetworkError(
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
                        let retryDelay = transientRetryDelayNanoseconds(
                            for: error,
                            runtime: runtime,
                            attempt: retryCount
                        )
                        noteAgentTransientReconnect(
                            for: runtime,
                            attempt: retryCount,
                            maximum: Self.isTLSHandshakeError(error)
                                ? Self.maxTLSHandshakeRetries
                                : (transientNetworkRetryLane(for: runtime)?.maximumRetries ?? retryCount)
                        )
                        try await Task.sleep(nanoseconds: retryDelay)
                    }
                }
                streamBuffer.flushPending()
                // A delivery lease becomes handled only after the provider has
                // accepted and completed a request containing the event. If the
                // process dies earlier, kernel reconstruction returns the lease
                // to pending; the stable event id prevents a duplicate system
                // carrier in the transcript.
                agentRuntimeKernel.acknowledge(
                    agentRuntimeKernel.leasedModelEventIDs(
                        for: runtime.id,
                        leaseID: turnID
                    ),
                    leaseID: turnID
                )
                await retryDeferredDaemonTerminalDeliveries()
            } catch is CancellationError {
                shouldResumePendingEventsAtTurnEnd = false
                if runtime.userStoppedTurnID == turnID {
                    agentKernelPreemptedRuntimeIDs.remove(runtime.id)
                }
                streamBuffer.flushPending()
                turnTelemetry.noteCancelled(reason: telemetryCancellationReason(for: runtime, turnID: turnID))
                finalizeInterruptedAssistantMessage(
                    id: assistantID,
                    in: runtime,
                    startedAt: turnStartedAt
                )
                return
            } catch {
                shouldResumePendingEventsAtTurnEnd = false
                streamBuffer.flushPending()
                if Task.isCancelled || !runtime.acceptsResponseEvents(for: turnID)
                    || Self.isStoppedTurnCancellation(error, runtime: runtime, turnID: turnID) {
                    agentKernelPreemptedRuntimeIDs.remove(runtime.id)
                    turnTelemetry.noteCancelled(reason: telemetryCancellationReason(for: runtime, turnID: turnID))
                    finalizeInterruptedAssistantMessage(
                        id: assistantID,
                        in: runtime,
                        startedAt: turnStartedAt
                    )
                    return
                }
                if error is AgentToolExecutionBudgetError,
                   stopExpiredGoalToolRound(for: runtime, assistantID: assistantID) { return }
                if stopOnModelAdmissionFailure(error, runtime: runtime, assistantID: assistantID) { return }
                turnTelemetry.noteFailure(error)
                setAgentError(error, for: runtime)
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty {
                    runtime.messages.remove(at: index)
                    AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
                }
                _ = retryDispatchPlanningAfterWillDeepFailureIfNeeded(for: runtime)
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
                // Some OpenAI-compatible gateways emit only whitespace in
                // `content` before a tool call. Normalize the settled round so
                // persistence, provider replay, and every transcript surface
                // agree that this is a tool-only assistant message.
                if !runtime.messages[index].content.isEmpty,
                   !runtime.messages[index].hasRenderableTextContent {
                    runtime.messages[index].content = ""
                }
                runtime.messages[index].elapsedSeconds = Date().timeIntervalSince(turnStartedAt)
                runtime.messages[index].managedRoute = managedRouteDecision
                runtime.messages[index].requestModelID = managedRouteDecision?.selectedModel
                    ?? turnConfiguration.model
                runtime.messages[index].requestProviderID = turnConfiguration.providerID
                runtime.messages[index].requestIsLocal = AgentLocalModelPrompting.isLocalProvider(turnConfiguration)
                runtime.messages[index].requestProviderDisplayName = AgentProviderPreset.normalizedDisplayName(
                    providerID: turnConfiguration.providerID,
                    storedDisplayName: runtime.session.providerDisplayName
                )
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
                if !didRequestContextRunwayHandoff,
                   !didQualityRetry,
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
                    let qualityJudge = AgentGoalRouteJudge(client: AgentClient(configuration: qualityConfig,
                        session: agentLoopInferenceEnvironment?.session, someIMContext: qualityContext,
                        requestLedger: modelRequestLedger(for: runtime)), executionBudget: auxiliaryModelExecutionBudget(for: runtime))
                    let decision = await SomeIMManagedRouting.outputQuality(
                        assistantText: assistantText,
                        reasoningText: reasoningText,
                        latestUserMessage: latestUserMessage,
                        model: turnConfiguration.model,
                        finishReason: finishReason
                    ) { system, user, maxTokens in
                        await qualityJudge.text(model: SomeIMManagedModel.judge, system: system, user: user, maxTokens: maxTokens)
                    }
                    if stopAfterRouteJudge(qualityJudge, runtime: runtime) { return }
                    if decision.shouldRetry {
                        didQualityRetry = true
                        if let dropIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                            runtime.messages.remove(at: dropIndex)
                        }
                        turnConfiguration.model = escalatedModel
                        turnTelemetry.noteResolvedModel(escalatedModel)
                        client = AgentClient(
                            configuration: turnConfiguration,
                            session: agentLoopInferenceEnvironment?.session,
                            someIMContext: someIMContext,
                            openAIResponsesContinuationState: runtime.openAIResponsesContinuationState,
                            requestLedger: modelRequestLedger(for: runtime)
                        )
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
                if !didRequestContextRunwayHandoff,
                   requiresDesignToCodeAcceptance,
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
                attachRecentVisibleToolImages(to: assistantID, in: runtime)
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
                    _ = retryDispatchPlanningAfterWillDeepFailureIfNeeded(for: runtime)
                    return
                }

                if didRequestContextRunwayHandoff {
                    // Second line of defence for the same failure: a provider
                    // that never parsed the call hands its raw syntax back as
                    // text. The call is already gone by the time it gets here,
                    // so keep whatever prose preceded it, drop the markup
                    // rather than persist and replay it, and — while the retry
                    // budget lasts — ask for the handover again.
                    if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                       let leak = AgentLeakedToolCallText.detect(in: runtime.messages[index].content) {
                        runtime.messages[index].content = leak.cleanedText
                        if leak.cleanedText.isEmpty,
                           runtime.messages[index].images.isEmpty,
                           runtime.messages[index].toolCalls.isEmpty,
                           (runtime.messages[index].reasoningContent ?? "").isEmpty {
                            // Never leave a bare {"role":"assistant"} behind:
                            // the next request would be rejected with a 400.
                            runtime.messages.remove(at: index)
                            AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
                        }
                        if contextRunwayHandoverRetryCount < AgentContextRunwayPolicy.maximumHandoverRetries {
                            contextRunwayHandoverRetryCount += 1
                            runtime.messages.append(
                                AgentMessage(
                                    role: .system,
                                    content: AgentContextRunwayPolicy.discardedMarkupNotice()
                                )
                            )
                            continue
                        }
                    }
                    concludeContextRunwayHandoff(for: runtime, finishReason: finishReason)
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
                if AgentDispatchPlanHandoffPolicy.shouldHandoffToTaskRuntimes(
                    captureOutcome: planCaptureOutcome,
                    presentationScope: runtime.session.presentationScope
                ) {
                    // The project session owns planning only. Executing this
                    // Plan again in the parent chat bypasses task worktrees,
                    // dependency gates, merge nodes, and per-Worker routing.
                    // Persist the accepted DAG and hand it to coordinator-
                    // owned child runtimes, then end the planner turn.
                    persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
                    synchronizeDispatchBoard()
                    _ = launchReadyDispatchTasks(goalID: runtime.id)
                    return
                }
                let goalChecklistCount = runtime.currentGoal?.checklist.count
                let hasValidClosedGoalCheck = runtime.messages
                    .first(where: { $0.id == assistantID })
                    .map {
                        AgentGoalChecklistParser.containsEvaluationBlock(
                            in: $0.content,
                            checklistCount: goalChecklistCount,
                            finishReason: finishReason
                        )
                    } ?? false
                let assistantReplyContainsGoalCheck = hasValidClosedGoalCheck
                var didAdvanceGoalChecklist = false
                if assistantReplyContainsGoalCheck {
                    didAdvanceGoalChecklist = await captureAndVerifyAgentGoalEvaluation(
                        for: runtime,
                        finishReason: finishReason
                    )
                }
                let didAdvanceGoalPhase = advanceAgentGoalRoadmapIfNeeded(for: runtime)
                if assistantReplyContainsGoalCheck, !didAdvanceGoalPhase {
                    // Advance only from this round's explicit Goal
                    // evaluation. A stale checklist plus an interrupted
                    // response must resume finalization, not erase the
                    // completed Plan and launch Goal Teams again.
                    prepareNextAgentGoalPlanningCycleIfNeeded(
                        for: runtime,
                        didAdvanceChecklist: didAdvanceGoalChecklist
                    )
                } else if !didAdvanceGoalPhase,
                          runtime.interactionMode == .goal,
                          runtime.currentPlan?.status == .done,
                          runtime.currentGoal?.checklist.contains(where: { !$0.done }) == true {
                    // Missing Goal evidence must continue the same acceptance
                    // loop rather than silently ending or creating a new Plan.
                    prepareNextAgentGoalPlanningCycleIfNeeded(
                        for: runtime,
                        didAdvanceChecklist: false
                    )
                }
                let planStatusesAfterReply = runtime.currentPlan?.steps.map(\.status)
                // `update_plan` lands during tool execution, i.e. after the
                // before/after snapshot pair above was taken, so a turn that
                // reported only through the tool would otherwise be counted
                // as "no progress" and eventually hard-paused.
                if didAdvancePlanSinceLastContinuationDecision
                    || runtime.planAdvancedByToolSinceLastContinuationDecision
                    || planStatusesBeforeReply != planStatusesAfterReply {
                    consecutivePlanRepliesWithoutProgress = 0
                    isPlanProgressReconciliationActive = false
                } else {
                    consecutivePlanRepliesWithoutProgress += 1
                }
                didAdvancePlanSinceLastContinuationDecision = false
                runtime.planAdvancedByToolSinceLastContinuationDecision = false

                // A missing status block is not the same as a stalled run.
                // Count the tool calls that actually succeeded since the last
                // decision, and check for background jobs still running, so a
                // demonstrably live execution keeps getting nudged for a
                // status block instead of being hard-paused.
                let succeededToolCallCount = runtime.toolCalls
                    .filter { $0.status == .succeeded }
                    .count
                let progressEvidence = AgentPlanAutoContinuationPolicy.ProgressEvidence(
                    didExecuteTools: succeededToolCallCount
                        > succeededToolCallCountAtLastContinuationDecision,
                    hasRunningBackgroundJobs: agentJobRegistry
                        .hasProgressRelevantAliveJobs(forRuntime: runtime.id)
                )
                succeededToolCallCountAtLastContinuationDecision = succeededToolCallCount
                let requiresGoalCompletion = runtime.interactionMode == .goal
                    && runtime.currentGoal.map {
                        $0.checklist.isEmpty
                            || $0.checklist.contains(where: { !$0.done })
                    } == true
                // A spent Goal budget already asked the model for an orderly
                // handover snapshot. Auto-continuing the handover turn would
                // contradict that instruction round after round — "stop all
                // substantive work" followed by an injected "keep executing".
                // The budget banner and Play (which resets wrapUpDispatched)
                // own resumption from here.
                let goalBudgetSpent = runtime.interactionMode == .goal
                    && runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true

                switch AgentPlanAutoContinuationPolicy.decision(
                    for: runtime.currentPlan,
                    automaticContinuationCount: planAutomaticContinuationCount,
                    consecutiveNoProgressReplies: consecutivePlanRepliesWithoutProgress,
                    hasQueuedUserMessages: !runtime.queuedMessages.isEmpty,
                    allowsAutomaticExecution: !runtime.currentTurnPlanningOnly && !goalBudgetSpent,
                    requiresGoalCompletion: requiresGoalCompletion,
                    evidence: progressEvidence
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
                case .reconcileProgress:
                    planAutomaticContinuationCount += 1
                    isPlanProgressReconciliationActive = true
                    runtime.messages.append(
                        AgentMessage(
                            role: .system,
                            content: AgentPlanAutoContinuationPolicy.progressReconciliationNotice(
                                finishReason: finishReason,
                                hasRunningBackgroundJobs: progressEvidence.hasRunningBackgroundJobs
                            )
                        )
                    )
                    continue
                case .pauseAfterNoProgress:
                    // Both pauses hand control back to the user without
                    // anything having failed — see AgentBannerSeverity.
                    runtime.errorMessage = L10n.PlanContinuation.missingProgressPaused
                    runtime.errorDetails = nil
                    runtime.errorSeverity = .notice
                case .pauseAfterLimit:
                    // A Goal with budget left is not out of runway just because
                    // the round counter ran out — budget is the only hard
                    // boundary. It queues its own continuation (or an orderly
                    // wrap-up) as a host instruction, which starts the next
                    // turn on its own; this turn still ends here, so the
                    // banner is simply skipped rather than the loop extended.
                    if !continueGoalOnBudgetInsteadOfRoundLimit(for: runtime) {
                        runtime.errorMessage = L10n.PlanContinuation.safetyLimitPaused
                        runtime.errorDetails = nil
                        runtime.errorSeverity = .notice
                    }
                case .stop:
                    break
                }
                return
            }

            // A handoff round keeps its tool schemas so the provider still
            // parses calls into structure, but nothing may actually run: the
            // window has no room left for tool output, and the turn exists
            // only to produce the handover. Refuse here, tell the model where
            // its request belongs instead, and give it a bounded number of
            // rounds to come back with prose.
            if didRequestContextRunwayHandoff {
                let refusedToolNames = latestToolCalls.map(\.toolName)
                latestToolCalls = []
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                    // Clearing the calls also keeps history replayable: an
                    // assistant message with tool_calls and no matching tool
                    // results is a 400 on every OpenAI-compatible provider.
                    runtime.messages[index].toolCalls = []
                    if runtime.messages[index].content.isEmpty,
                       runtime.messages[index].images.isEmpty,
                       (runtime.messages[index].reasoningContent ?? "").isEmpty {
                        runtime.messages.remove(at: index)
                        AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
                    }
                }
                if contextRunwayHandoverRetryCount < AgentContextRunwayPolicy.maximumHandoverRetries {
                    contextRunwayHandoverRetryCount += 1
                    runtime.messages.append(
                        AgentMessage(
                            role: .system,
                            content: AgentContextRunwayPolicy.refusedToolCallNotice(
                                toolNames: refusedToolNames
                            )
                        )
                    )
                    continue
                }
                // Out of retries. End the turn the way a prose handover does
                // rather than spending the rest of the window on the argument.
                concludeContextRunwayHandoff(for: runtime, finishReason: finishReason)
                return
            }

            if stopExpiredGoalToolRound(for: runtime, assistantID: assistantID) { return }
            if captureDispatchDecisions(runtime: runtime, messageID: assistantID, calls: latestToolCalls) { return }

            // Execute every tool call, gating on the user when necessary.
            runtime.currentTurnTiming?.noteToolBoundary()
            var anyDenied = false
            var changedWorkspacePath: String?
            // Git status refreshes are coalesced: instead of one blocking
            // `git status` subprocess after EVERY write-ish tool (a round
            // with six edits paid six), non-artifact refreshes set this flag
            // and run once after the round's tools finish. Attribution is
            // unchanged — the diff is always taken against the same
            // turn-level baseline.
            var roundNeedsGitStatusRefresh = false

            // Stage 1 — parse and classify the whole round before execution.
            // Calls that need a human decision remain visibly queued; stage 2
            // promotes exactly one call to an interactive approval card only
            // when its continuation is ready. This keeps transcript context
            // visible without accepting decisions that no waiter can consume.
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

                if let validationError = AgentToolRegistry.argumentValidationError(
                    for: call.toolName,
                    arguments: argsDict
                ) {
                    let record = AgentToolCall(
                        messageID: assistantID,
                        externalID: call.externalID,
                        toolName: call.toolName,
                        arguments: argsDict,
                        risk: .read,
                        status: .failed,
                        approvalSource: nil
                    )
                    var failed = record
                    failed.errorMessage = validationError
                    runtime.toolCalls.append(failed)
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "\(validationError) Re-emit the tool call with arguments matching its schema. No action was executed and no user approval is needed.",
                        outcomeStatus: .failed,
                        errorMessage: validationError
                    )
                    continue
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
                    rootDirectory: workspaceURL,
                    additionalWorkspaceRoots: Array(
                        self.agentWorkspaceRoots(for: runtime.session).dropFirst()
                    )
                )
                if isPlanProgressReconciliationActive,
                   !AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(risk) {
                    anyDenied = true
                    denyPlanProgressReconciliationToolCall(
                        call, messageID: assistantID, arguments: argsDict, risk: risk, runtime: runtime
                    )
                    continue
                }
                let sandboxDecision = AgentSandboxPolicy.decision(
                    toolName: call.toolName,
                    arguments: argsDict,
                    rootDirectory: workspaceURL,
                    additionalWorkspaceRoots: Array(
                        self.agentWorkspaceRoots(for: runtime.session).dropFirst()
                    )
                )

                // A dispatch-board child has no operator attached. Never
                // create an input card that can strand the scheduler; feed a
                // deterministic denial back so the agent can choose a safe
                // fallback or finish with a concrete blocked reason.
                if runtime.isUnattendedDispatchTask, risk == .userInput {
                    recordUnattendedInputDenial(call, messageID: assistantID, arguments: argsDict, risk: risk, runtime: runtime)
                    continue
                }

                let autoApproval: AgentToolApprovalSource?
                if let unattendedApproval = Self.unattendedDispatchApprovalSource(
                    risk: risk,
                    isUnattendedDispatchTask: runtime.isUnattendedDispatchTask
                ) {
                    autoApproval = unattendedApproval
                } else {
                    do { autoApproval = try await checkedAutoApprovalSource(
                        toolName: call.toolName,
                        arguments: argsDict,
                        risk: risk,
                        rootDirectory: workspaceURL,
                        additionalWorkspaceRoots: Array(
                            self.agentWorkspaceRoots(for: runtime.session).dropFirst()
                        ),
                        interactionMode: runtime.interactionMode,
                        approvalMode: runtime.approvalMode,
                        conversationAllowedToolSignatures: runtime.conversationAllowedToolSignatures,
                        environmentTrustDeclarations: runtime.environmentTrustDeclarations,
                        computerUseOwner: runtime.computerUseOwner, latestUserMessage: runtime.messages.last(where: { $0.isOperatorInput })?.content ?? "", taskRuntime: runtime
                    ) } catch {
                        stopApprovalToolRound(error, runtime: runtime, assistantID: assistantID)
                        return
                    }
                }
                let isAlwaysAllowed = autoApproval != nil
                // Manual decisions are activated only when stage 2 reaches
                // this exact call. Pre-creating every card as interactive let
                // users approve a later call while the single continuation
                // still belonged to an earlier one, leaving a misleading
                // "decision submitted" spinner that could never make progress.
                let requiresSerialApproval = !isAlwaysAllowed && risk != .read
                let initialStatus: AgentToolCallStatus = .running

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
                if requiresSerialApproval {
                    displayArgsDict[AgentSerialToolApprovalQueue.argumentKey] = .bool(true)
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

                if runtime.currentTurnPlanningOnly,
                   AgentExecutionIntentPolicy.blocksExecution(risk: risk) {
                    anyDenied = true
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Planning-only request"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Blocked: the operator explicitly requested planning or analysis without execution. Return the plan and stop; do not ask for approval.",
                        source: .systemNotice,
                        outcomeStatus: .denied,
                        errorMessage: "Planning-only request"
                    )
                    continue
                }

                // Design gate. Same shape as planning-only above and
                // deliberately a separate branch: the two states want
                // different things from the model, and collapsing them would
                // tell a gated turn to "return the plan and stop" when what
                // it owes is a document. File tools are `.read` risk, so this
                // never blocks writing the design itself.
                if runtime.specGateState.blocksExecution,
                   AgentExecutionIntentPolicy.blocksExecution(risk: risk) {
                    anyDenied = true
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Design gate"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: runtime.specGateState == .awaitingUserReview
                            ? "Blocked: the design document is written and the operator has not answered yet. Do not implement and do not ask for approval — they answer on the card."
                            : "Blocked: this task was gated for a written design first. Create the design document under `docs/`, then stop. Do not ask for approval and do not start implementing.",
                        source: .systemNotice,
                        outcomeStatus: .denied,
                        errorMessage: "Design gate"
                    )
                    continue
                }

                if let refusal = AgentWorkerRouteGuard.refusal(
                    toolName: call.toolName,
                    risk: risk,
                    decision: runtime.currentTurnRouteDecision,
                    delegationPolicy: runtime.currentTurnDelegationPolicy,
                    attemptedProfiles: runtime.currentTurnAttemptedWorkerProfiles
                ) {
                    anyDenied = true
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Delegate-first worker route"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: refusal,
                        source: .systemNotice,
                        outcomeStatus: .denied,
                        errorMessage: "Delegate-first worker route"
                    )
                    continue
                }

                // Goal evidence planning blocks writes until the host validates
                // a plan, while all read-tier research tools remain available.
                // Resolved during
                // staging (synchronously, right after the record is appended)
                // so a gated call never sits on screen as an approvable card.
                // `ask_user` is exempt exactly as in the old serial flow,
                // where its handler ran ahead of this gate.
                if risk != .userInput,
                   Self.goalPlanningGateBlocks(
                    toolName: call.toolName,
                    arguments: argsDict,
                    risk: risk,
                    isActive: runtime.isPlanGateActive
                ) {
                    anyDenied = true
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = L10n.GoalPlanning.gateBlockedTool
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: AgentGoalGateNotice.blockedToolPayload,
                        source: .systemNotice,
                        outcomeStatus: .denied,
                        errorMessage: L10n.GoalPlanning.gateBlockedTool
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

            // Stage 2 — run the staged calls strictly in order, promoting and
            // waiting on at most one human decision at a time. Trusted policy
            // decisions may still use `awaitToolDecision`'s internal fast path.
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
            // Foreground read-only workers are turn-owned just like ordinary
            // read tools. Run consecutive spawns together, but defer their
            // tool messages until every result is ready so provider history
            // retains the model's original call order.
            var pendingParallelSpawns: [AgentPendingParallelSpawn] = []
            // Shared AgentToolContext builder for the concurrent read batch
            // and the serial path below. Captures this round's workspace
            // binding plus the `changedWorkspacePath` slot the
            // workspace-change sink writes into.
            var needsPatchReviewBoundary = false
            var pendingPatchReviewPathKeys: Set<String>? = []
            func awaitPatchReviewBoundary() async {
                // Seal before suspending. The UI can now enable Apply /
                // Reject, and a very fast click is still safe because the
                // waiter re-reads cards that were already resolved.
                runtime.collectingPatchReviewMessageIDs.remove(assistantID)
                _ = await awaitPendingAgentPatchProposals(
                    forMessageID: assistantID,
                    runtime: runtime
                )
            }
            func makeToolContext(
                sandboxMode: AgentSandboxMode,
                patchAutoApplySource: AgentToolApprovalSource?,
                taskAuthorizationSource: AgentToolApprovalSource? = nil,
                automaticBackgroundSandboxRetryApprovalSource: AgentToolApprovalSource? = nil,
                delegatedProgressSink: (@MainActor (AgentDelegatedTerminalProgressUpdate) -> Void)? = nil
            ) -> AgentToolContext {
                let delegatedApprovalHandler: (@MainActor (AgentDelegatedApprovalRequest) async -> AgentDelegatedApprovalDecision)?
                if runtime.isUnattendedDispatchTask {
                    delegatedApprovalHandler = nil
                } else {
                    delegatedApprovalHandler = { request in
                        await self.resolveDelegatedExecutorApproval(
                            request,
                            runtime: runtime,
                            messageID: assistantID,
                            rootDirectory: workspaceURL
                        )
                    }
                }
                return AgentToolContext(
                    rootDirectory: workspaceURL,
                    additionalWorkspaceRoots: Array(
                        self.agentWorkspaceRoots(for: runtime.session).dropFirst()
                    ),
                    workspaceLocation: workspaceLocation,
                    runtimeDescriptor: remoteRuntimeDescriptor,
                    runtimeID: runtime.id,
                    turnID: runtime.activeTurnID,
                    goalPhaseID: runtime.goalRoadmap?.activePhase?.id,
                    isGoalMode: runtime.interactionMode == .goal,
                    executionBudget: self.toolExecutionBudget(for: runtime),
                    taskAuthorizationCheck: self.goalTaskAuthorizationExecutionCheck(runtime: runtime, source: taskAuthorizationSource, root: workspaceURL),
                    computerUseSessionTitle: runtime.session.title,
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
                    sessionManagementHandler: { request in
                        try await self.handleSessionManagement(request, callerID: runtime.id)
                    },
                    sessionTitleSuggestionProvider: {
                        await self.sessionTitleSuggestionSnapshot(for: runtime)
                    },
                    sessionPersistenceBarrier: {
                        self.persistAgentSession(
                            runtime: runtime,
                            touchUpdatedAt: false,
                            moveToFront: false
                        )
                        AgentSessionStore.flushPendingWrites()
                    },
                    contextMessageReader: self.contextMessageReader(for: runtime),
                    localCommandEnvironment: AgentToolRunner.localCommandEnvironment(
                        settings: editorTerminalSettings
                    ),
                    sandboxMode: sandboxMode,
                    automaticBackgroundSandboxRetryApprovalSource: automaticBackgroundSandboxRetryApprovalSource,
                    // The main loop can spawn subagents; hints that end in
                    // spawn_agent are only rendered for it.
                    canSpawnSubagents: true,
                    isUnattendedDispatchTask: runtime.isUnattendedDispatchTask,
                    patchProposalSink: { title, diff, applyImmediately, workspaceRoot in
                        try self.enqueueAgentPatchProposal(
                            for: runtime,
                            messageID: assistantID,
                            title: title,
                            diff: diff,
                            workspaceRoot: workspaceRoot,
                            autoApplySource: patchAutoApplySource,
                            applyImmediately: applyImmediately
                        )
                    },
                    // edit_file matches old_string against the same content
                    // the patch applier will later apply to (open tab buffer
                    // first, then disk) so tab-vs-disk drift can't break it.
                    editableContentProvider: { url in
                        try self.editableContent(forAgentPatchURL: url)
                    },
                    delegatedFileWriteHandler: workspaceURL.map { workspaceRoot in
                        { @MainActor @Sendable url, content in
                            try self.writeDelegatedAgentContent(
                                content,
                                to: url,
                                runtime: runtime,
                                workspaceRoot: workspaceRoot
                            )
                        }
                    },
                    patchAutoApplySource: patchAutoApplySource,
                    terminalController: agentTerminalController,
                    delegatedProgressSink: delegatedProgressSink,
                    sessionRenameSink: { title in
                        try self.renameAgentSessionFromTool(
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
                    },
                    delegatedApprovalHandler: delegatedApprovalHandler,
                    toolPackActivationSink: { requested in
                        runtime.loadedToolPacks.formUnion(requested)
                        return runtime.loadedToolPacks
                    }
                )
            }
            for (stagedIndex, staged) in stagedCalls.enumerated() {
                let call = staged.call
                let argsDict = staged.arguments
                let risk = staged.risk
                let sandboxDecision = staged.sandboxDecision
                let autoApproval = runtime.toolCalls.first(where: { $0.id == staged.recordID })?.approvalSource
                    ?? staged.autoApproval
                let isAlwaysAllowed = autoApproval != nil
                let recordID = staged.recordID
                let currentPatchReviewPathKeys = Self.patchReviewPathKeys(
                    toolName: call.toolName,
                    arguments: argsDict
                )
                let isPatchReviewTool = Self.patchReviewToolNames.contains(call.toolName)
                let overlapsPendingPatchReview = {
                    guard isPatchReviewTool,
                          let pendingPatchReviewPathKeys,
                          let currentPatchReviewPathKeys else {
                        return isPatchReviewTool
                    }
                    return !pendingPatchReviewPathKeys.isDisjoint(with: currentPatchReviewPathKeys)
                }()

                // File-edit tools enqueue review proposals without blocking
                // inside the first tool. Before any different kind of tool
                // or an overlapping file edit runs, settle the accumulated
                // disjoint edits as one review group. The overlap boundary is
                // important: a second edit to the same path must read the
                // first approved result, not the stale pre-review content.
                if needsPatchReviewBoundary,
                   !isPatchReviewTool || overlapsPendingPatchReview {
                    await awaitPatchReviewBoundary()
                    needsPatchReviewBoundary = false
                    pendingPatchReviewPathKeys = []
                    if Task.isCancelled {
                        settleUnexecutedStagedCalls(from: stagedIndex, reason: "Cancelled")
                        return
                    }
                }

                let isParallelForegroundReadOnlySpawn = changedWorkspacePath == nil
                    && call.toolName == "spawn_agent"
                    && risk == .read
                    && !AgentSubagentSchedulingPolicy.runsInBackground(argsDict)
                    && runtime.currentTurnDelegationPolicy != .forbidden

                // A write worker, interactive tool, or ordinary read marks a
                // hard ordering boundary. Finish the preceding read-only
                // workers before allowing that call to run.
                if !isParallelForegroundReadOnlySpawn,
                   await executeParallelSpawnBatch(
                       &pendingParallelSpawns,
                       runtime: runtime,
                       configuration: turnConfiguration,
                       workspaceURL: workspaceURL,
                       runtimeDescriptor: remoteRuntimeDescriptor,
                       workspaceLocation: workspaceLocation
                   ) {
                    settleUnexecutedStagedCalls(from: stagedIndex, reason: "Response stopped")
                    return
                }

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
                                    sandboxDecision: sandboxDecision,
                                    isUnattendedDispatchTask: runtime.isUnattendedDispatchTask,
                                    localSandboxDisabled: runtime.localSandboxDisabled
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

                if isParallelForegroundReadOnlySpawn {
                    pendingParallelSpawns.append(
                        AgentPendingParallelSpawn(
                            call: call,
                            arguments: argsDict,
                            recordID: recordID,
                            messageBuffer: AgentSpawnToolMessageBuffer()
                        )
                    )
                    continue
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
                    activateSerialToolDecision(
                        recordID: recordID,
                        status: .awaitingUserAnswer,
                        runtime: runtime
                    )
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    if runtime.toolCalls.first(where: { $0.id == recordID })?.status == .failed {
                        finishHostStoppedToolRound(runtime: runtime, assistantID: assistantID, recordID: recordID)
                        return
                    }
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
                    activateSerialToolDecision(
                        recordID: recordID,
                        status: risk == .danger ? .awaitingConfirm : .pendingApproval,
                        runtime: runtime
                    )
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    if runtime.toolCalls.first(where: { $0.id == recordID })?.status == .failed {
                        finishHostStoppedToolRound(runtime: runtime, assistantID: assistantID, recordID: recordID)
                        return
                    }
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
                        if Self.isCommandShapedTool(call.toolName) {
                            cachedJudgeHistoryBuiltAt = nil
                        }
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

                if isPatchReviewTool {
                    runtime.collectingPatchReviewMessageIDs.insert(assistantID)
                }
                let patchAutoApplySource = patchAutoApplySource(
                    forToolName: call.toolName,
                    runtime: runtime
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
                    effectiveArguments["use_visible_terminal"] = .bool(
                        !executionAgent.supportsStructuredExecution
                    )
                    effectiveArguments["visible_terminal_label"] = .string(
                        "\(executionAgent.displayName) · \(L10n.DelegatedTask.sectionTitle)"
                    )
                    effectiveArguments["timeout_seconds"] = .number(
                        Double(contract.timeoutSeconds)
                    )
                    effectiveArguments["delegated_task_id"] = .string(
                        contract.id.uuidString
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
                if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                    runtime.toolCalls[index].arguments = effectiveArguments
                }
                let liveProgressSink: (@MainActor (AgentDelegatedTerminalProgressUpdate) -> Void)?
                if let delegatedControl {
                    liveProgressSink = { update in
                        self.updateDelegatedTerminalProgress(
                            id: delegatedControl.runID,
                            runtime: runtime,
                            update: update
                        )
                    }
                } else {
                    liveProgressSink = nil
                }
                let currentApprovalSource = runtime.toolCalls
                    .first(where: { $0.id == recordID })?
                    .approvalSource
                    ?? autoApproval
                let automaticBackgroundSandboxRetrySource = Self
                    .automaticBackgroundSandboxRetryApprovalSource(
                        approvalMode: runtime.approvalMode,
                        existingApprovalSource: currentApprovalSource,
                        isUnattendedDispatchTask: runtime.isUnattendedDispatchTask
                    )
                let context = makeToolContext(
                    sandboxMode: sandboxModeForToolExecution(
                        risk: risk,
                        approvalSource: currentApprovalSource,
                        sandboxDecision: sandboxDecision,
                        isUnattendedDispatchTask: runtime.isUnattendedDispatchTask,
                        localSandboxDisabled: runtime.localSandboxDisabled
                    ),
                    patchAutoApplySource: patchAutoApplySource,
                    taskAuthorizationSource: currentApprovalSource,
                    automaticBackgroundSandboxRetryApprovalSource: automaticBackgroundSandboxRetrySource,
                    delegatedProgressSink: liveProgressSink
                )
                let didRevealTerminal = revealTerminalPanelForToolExecution(
                    toolName: call.toolName,
                    runtime: runtime
                )
                if didRevealTerminal {
                    // Let SwiftUI commit the side-panel transition before the
                    // command/control mutation reaches the PTY. The terminal
                    // operation remains audited and automatic in Full Access,
                    // but it never happens behind a hidden panel.
                    await Task.yield()
                }
                // Only tabs absent from this snapshot can have been created by
                // the AI tool below. If one appears, surface Terminal even when
                // the operator had closed the panel in the meantime.
                let terminalTabIDsBeforeTool = Set(agentTerminalController.tabs.map(\.id))
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

                        // Resolve only the common repository identity before
                        // waiting for the lease. The full capture after
                        // acquisition is the authoritative CAS comparison and
                        // closes races between WillDeep sessions.
                        let preLeaseIdentity = await AgentWorkspaceRevisionCapture.repositoryIdentity(
                            for: workspaceURL
                        )
                        let leaseIdentity = roundWorkspaceRevision?.repositoryCommonDirectoryPath
                            ?? preLeaseIdentity
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

                    // 写入前查一次台账：这个文件在本会话读过之后被外部改过吗。
                    // 只取证不拦路（设计文档 §5 第 1 条）——台账误报时最坏是
                    // 模型多看一句话，不是用户改不了文件。必须在工具执行**之前**
                    // 取，否则 Agent 自己刚写的那一笔会被当成外部漂移。
                    let pendingDriftNotice: String? = {
                        guard Self.fileWritingToolNames.contains(call.toolName),
                              let path = argsDict["path"]?.stringValue() else { return nil }
                        guard let root = workspaceURL
                            ?? runtime.workspaceRootPath.map({ URL(fileURLWithPath: $0) }) else { return nil }
                        let absolute = path.hasPrefix("/")
                            ? path
                            : root.appendingPathComponent(path).standardizedFileURL.path
                        return fileDriftNotice(for: runtime, absolutePath: absolute)
                    }()

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
                            cachedJudgeHistoryBuiltAt = nil
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
                        runtime.toolCalls[index].commandExitCode = result.commandExitCode
                        if let patchAutoApplySource {
                            runtime.toolCalls[index].approvalSource = patchAutoApplySource
                        }
                        runtime.toolCalls[index].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
                    }
                    recordFileObservations(
                        for: runtime, toolName: call.toolName, arguments: argsDict, result: result
                    )
                    runtime.recordComputerUseActivity(toolName: call.toolName, images: result.images)
                    runtime.deepAdmissionObservation.recordToolSuccess(call.toolName)
                    let agentCreatedTerminalTabs = agentTerminalController.tabs.filter {
                        !terminalTabIDsBeforeTool.contains($0.id)
                    }
                    if let createdTab = agentCreatedTerminalTabs.last {
                        _ = try? agentTerminalController.selectTab(id: createdTab.id)
                        _ = openPanelTab(for: createdTab, runtime: runtime)
                        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .terminal)
                    } else if call.toolName == "terminal_create_shortcut",
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
                    if Self.isCommandShapedTool(call.toolName),
                       effectiveApprovalSource == .user || effectiveApprovalSource == .escalated {
                        // Invalidate after the audit append as well as at the
                        // click boundary. Concurrent judge work cannot rebuild
                        // and retain a stale history snapshot in between.
                        cachedJudgeHistoryBuiltAt = nil
                    }
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
                        // 漂移说明追加在正文末尾而不是改 result：AgentToolResult
                        // 的 payload 是 let，而且这句话是宿主的交代，不是工具
                        // 自己的输出。
                        payload: pendingDriftNotice.map { "\(result.payload)\n\n\($0)" } ?? result.payload,
                        images: result.images,
                        outcomeStatus: .succeeded,
                        toolName: call.toolName,
                        toolCommand: argsDict["command"]?.stringValue()
                    )
                    if isPatchReviewTool {
                        needsPatchReviewBoundary = true
                        if let currentPatchReviewPathKeys,
                           let existingPathKeys = pendingPatchReviewPathKeys {
                            pendingPatchReviewPathKeys = existingPathKeys.union(currentPatchReviewPathKeys)
                        } else {
                            // An unparseable target is deliberately
                            // unbatchable with the next file operation.
                            pendingPatchReviewPathKeys = nil
                        }
                    }
                } catch is CancellationError {
                    shouldResumePendingEventsAtTurnEnd = false
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
                    if isPatchReviewTool,
                       runtime.patchProposals.contains(where: {
                           $0.messageID == assistantID && $0.status == .pending
                       }) {
                        // A file tool normally returns immediately after
                        // enqueueing its proposal. Preserve the review
                        // boundary even if later result construction throws.
                        needsPatchReviewBoundary = true
                        if let currentPatchReviewPathKeys,
                           let existingPathKeys = pendingPatchReviewPathKeys {
                            pendingPatchReviewPathKeys = existingPathKeys.union(
                                currentPatchReviewPathKeys
                            )
                        } else {
                            pendingPatchReviewPathKeys = nil
                        }
                    }
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
                        runtime.toolCalls[index].commandExitCode = (error as? AgentToolError)?.completedCommandExitCode
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
                    // Interception first: when the failure is a bounded repair
                    // job we run the worker ourselves and report its verdict.
                    // The suggestion is the fallback for everything that is
                    // not auto-dispatchable — a hint the parent has already
                    // been measured ignoring.
                    let exitCode = (error as? AgentToolError)?.completedCommandExitCode
                    let autoDispatched = await autoDispatchWorkerForFailedCommand(
                        toolName: call.toolName,
                        arguments: argsDict,
                        exitCode: exitCode,
                        failureOutput: errorMessage,
                        runtime: runtime,
                        configuration: turnConfiguration,
                        workspaceURL: workspaceURL,
                        runtimeDescriptor: remoteRuntimeDescriptor,
                        workspaceLocation: workspaceLocation,
                        assistantMessageID: assistantID
                    )
                    let dispatchHint = autoDispatched ?? AgentWorkerDispatchHint.hint(
                        toolName: call.toolName,
                        arguments: argsDict,
                        exitCode: exitCode,
                        failureOutput: errorMessage
                    ) ?? ""
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Tool error: \(errorMessage)\(sandboxNote)\n\n(WillDeep: this tool call failed. Do not stop here — diagnose the cause from the exit code/stderr above and try another approach to accomplish the goal. Only give up if you are genuinely blocked, and then explain what you tried and what you still need.)\(dispatchHint)",
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
            if await executeParallelSpawnBatch(
                &pendingParallelSpawns,
                runtime: runtime,
                configuration: turnConfiguration,
                workspaceURL: workspaceURL,
                runtimeDescriptor: remoteRuntimeDescriptor,
                workspaceLocation: workspaceLocation
            ) {
                return
            }

            // A round ending with file edits has no following non-patch tool
            // to create the review boundary. Wait here after every adjacent
            // proposal is visible, before asking the provider for another
            // response (which could otherwise repeat the same edit).
            if needsPatchReviewBoundary {
                await awaitPatchReviewBoundary()
                if Task.isCancelled {
                    return
                }
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

        if continueGoalOnBudgetInsteadOfRoundLimit(for: runtime, boundary: .toolRoundLimit) { return }
        runtime.errorMessage = "Agent paused after \(Self.maxAgentToolRounds) tool-call rounds to avoid an accidental loop. Send another message to continue."
        runtime.errorDetails = nil
    }

}
