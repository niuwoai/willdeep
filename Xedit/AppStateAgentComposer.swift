//
//  AppStateAgentComposer.swift
//  WillDeep
//
//  Agent composer send path and staged context attachments.
//

import Foundation

nonisolated enum AgentComposerLocalPanelTrigger {
    static let exactInput = "#1983#"

    static func isExactInput(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == exactInput
    }

    static func matches(
        input: String,
        isNewSession: Bool,
        hasTurnAttachments: Bool,
        isResponding: Bool,
        hasExistingPreview: Bool
    ) -> Bool {
        isExactInput(input)
            && isNewSession
            && !hasTurnAttachments
            && !isResponding
            && !hasExistingPreview
    }
}

extension AppState {
    func sendAgentMessage() {
        // The UI's send button always targets whatever session is on
        // screen — that's the active runtime by definition. If there
        // isn't one, lazily create one so a brand-new install can fire
        // off its first message without manually picking ⌘N first.
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        if runtime.interactionMode == .goal,
           runtime.workspaceLocation == nil,
           (runtime.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            runtime.errorMessage = L10n.Dispatch.workspaceRequired
            return
        }
        if refreshChangedAgentSessionDocumentsIfNeeded(in: runtime) {
            return
        }

        let userText = runtime.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTurnAttachments = !runtime.pendingImages.isEmpty
            || !runtime.pendingTextAttachments.isEmpty
            || !runtime.pendingSkills.isEmpty
            || !runtime.pendingFiles.isEmpty
            || runtime.pendingIncludeWorkspaceOverview
        if AgentComposerLocalPanelTrigger.isExactInput(runtime.input) {
            guard AgentComposerLocalPanelTrigger.matches(
                input: runtime.input,
                isNewSession: runtime.isEmpty,
                hasTurnAttachments: hasTurnAttachments,
                isResponding: runtime.isResponding,
                hasExistingPreview: runtime.hasLocalConfirmationPreview
            ) else {
                // `#1983#` is reserved for this local surface. In an existing
                // or busy session it intentionally does nothing instead of
                // falling through into a model request.
                return
            }
            runtime.input = ""
            runtime.installLocalConfirmationPreview(
                localConfirmationPreviewCalls(for: runtime)
            )
            return
        }

        let images = runtime.pendingImages.map { image in
            (try? image.diskBackedCopy()) ?? image
        }
        let textAttachments = runtime.pendingTextAttachments
        let skills = AgentSkillAutoActivation.mergedSkills(
            userText: userText,
            workspaceRootPath: runtime.workspaceRootPath ?? rootDirectory?.standardizedFileURL.path,
            manuallySelectedSkills: runtime.pendingSkills,
            hasVisualTargetAttachment: !images.isEmpty
        )
        let pendingFiles = runtime.pendingFiles
        let files = mergedAgentDocumentContextFiles(
            sessionDocuments: runtime.documentAttachments,
            knowledgeFolders: runtime.knowledgeFolders,
            pendingFiles: pendingFiles
        )
        let includeWorkspaceOverview = runtime.pendingIncludeWorkspaceOverview
        let executionAgent = runtime.executionAgent
        guard !userText.isEmpty
                || !images.isEmpty
                || !textAttachments.isEmpty
                || !skills.isEmpty
                || !pendingFiles.isEmpty
                || includeWorkspaceOverview else { return }

        // The preview is a transient, local-only surface. As soon as the user
        // starts a real turn, remove its synthetic cards before any normal
        // activity accounting or approval routing runs.
        runtime.clearLocalConfirmationPreview()

        let prompt = composeAttachedPrompt(
            userText: userText,
            skills: skills,
            files: files,
            includeWorkspaceOverview: includeWorkspaceOverview,
            documentTaskMode: runtime.documentTaskMode,
            redactSensitiveContent: runtime.redactSensitiveAttachmentContent,
            imagePaths: AgentDesignToCode.sourcePaths(from: images)
        )

        if skills.contains(where: { $0.identifier == AgentDesignToCode.webSkillIdentifier }) {
            runtime.activeExperts.formUnion(AgentDesignToCode.webExperts)
        }

        runtime.input = ""
        runtime.pendingImages = []
        runtime.pendingTextAttachments = []
        runtime.pendingSkills = []
        runtime.pendingFiles = []
        runtime.pendingIncludeWorkspaceOverview = false

        if runtime.isResponding {
            runtime.queuedMessages.append(
                AgentQueuedMessage(
                    text: prompt,
                    images: images,
                    textAttachments: textAttachments,
                    attachedSkills: skills,
                    executionAgent: executionAgent
                )
            )
            if closeBlockingAgentToolDecision(for: runtime, reason: "New message sent") {
                runtime.shouldConsumeQueueAfterStop = true
                runtime.requestTask?.cancel()
                scheduleQueuedMessageConsumptionAfterCancellation(for: runtime)
            }
            return
        }

        dispatchAgentMessageUsingSelectedExecutor(
            executionAgent,
            for: runtime,
            text: prompt,
            images: images,
            textAttachments: textAttachments,
            attachedSkills: skills,
            source: .operatorInput
        )
    }

    private func localConfirmationPreviewCalls(for runtime: AgentRuntime) -> [AgentToolCall] {
        let messageID = UUID()
        var commandArguments: [String: AgentJSONValue] = [
            "command": .string("git status --short"),
        ]
        if let workspacePath = runtime.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspacePath.isEmpty {
            commandArguments["cwd"] = .string(workspacePath)
        }

        return [
            AgentToolCall(
                messageID: messageID,
                externalID: "local-confirmation-preview-command",
                toolName: "run_command",
                arguments: commandArguments,
                risk: .danger,
                status: .awaitingConfirm
            ),
            AgentToolCall(
                messageID: messageID,
                externalID: "local-confirmation-preview-web",
                toolName: "web_fetch",
                arguments: ["url": .string("https://example.com/guide")],
                risk: .write,
                status: .pendingApproval
            ),
            AgentToolCall(
                messageID: messageID,
                externalID: "local-confirmation-preview-browser",
                toolName: "embedded_browser_navigate",
                arguments: ["url": .string("https://example.com")],
                risk: .write,
                status: .pendingApproval
            ),
            AgentToolCall(
                messageID: messageID,
                externalID: "local-confirmation-preview-computer-use",
                toolName: "computer_use_click",
                arguments: [
                    "x": .number(640),
                    "y": .number(420),
                ],
                risk: .write,
                status: .pendingApproval
            ),
        ]
    }

    func dispatchAgentMessageUsingSelectedExecutor(
        _ executionAgent: AgentExecutionAgent,
        for runtime: AgentRuntime,
        text: String,
        images: [AgentImageAttachment],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        source: AgentMessageSource = .operatorInput
    ) {
        switch executionAgent {
        case .willDeep:
            dispatchAgentMessage(
                for: runtime,
                text: text,
                images: images,
                textAttachments: textAttachments,
                attachedSkills: attachedSkills,
                source: source
            )
        case .claudeCode, .codexCLI, .cursorAgent, .clineCLI:
            dispatchDelegatedAgentMessage(
                for: runtime,
                text: text,
                images: images,
                textAttachments: textAttachments,
                attachedSkills: attachedSkills,
                executionAgent: executionAgent,
                source: source
            )
        }
    }

    func dispatchDelegatedAgentMessage(
        for runtime: AgentRuntime,
        text: String,
        images: [AgentImageAttachment],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        executionAgent: AgentExecutionAgent,
        source: AgentMessageSource = .operatorInput
    ) {
        guard let toolName = executionAgent.toolName else {
            dispatchAgentMessage(
                for: runtime,
                text: text,
                images: images,
                textAttachments: textAttachments,
                attachedSkills: attachedSkills,
                source: source
            )
            return
        }

        runtime.currentTurnPlanningOnly = source == .operatorInput
            && AgentExecutionIntentPolicy.requestsPlanningOnly(text)
        let delegatedUserText = AgentPlanContinuationPolicy.delegatedExecutionTask(
            userText: text,
            currentPlan: runtime.currentPlan
        )

        resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime)

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.latestComputerUseActivity = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()
        runtime.currentTurnAttachedSkills = attachedSkills

        let userMessage = AgentMessage(
            role: .user,
            content: text,
            images: images,
            textAttachments: textAttachments,
            source: source
        )
        runtime.messages.append(userMessage)
        runtime.latestTurnRecall = nil

        let delegatedContract = AgentDelegatedTaskControl.makeContract(
            objective: delegatedUserText,
            executor: executionAgent,
            goal: runtime.currentGoal
        )
        runtime.delegatedTaskRuns.insert(
            AgentDelegatedTaskRun(contract: delegatedContract),
            at: 0
        )
        if runtime.delegatedTaskRuns.count > 20 {
            runtime.delegatedTaskRuns.removeLast(runtime.delegatedTaskRuns.count - 20)
        }
        let prompt = delegatedAgentPrompt(
            userText: delegatedUserText,
            conversationMessages: runtime.messages,
            textAttachments: textAttachments,
            images: images,
            imageDescriptions: nil,
            imageFilePaths: [],
            executionAgent: executionAgent,
            workspaceLocation: runtime.workspaceLocation ?? runtime.workspaceRootPath.map { .local(path: $0) },
            contract: delegatedContract
        )
        let arguments = Self.delegatedAgentArguments(
            prompt: prompt,
            executionAgent: executionAgent,
            contract: delegatedContract,
            planningOnly: runtime.currentTurnPlanningOnly
        )
        let externalID = "composer-\(executionAgent.rawValue)-\(UUID().uuidString)"
        let assistantMessage = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: externalID,
                    toolName: toolName,
                    argumentsJSON: Self.agentArgumentsJSONString(arguments)
                )
            ]
        )
        runtime.messages.append(assistantMessage)

        let record = AgentToolCall(
            messageID: assistantMessage.id,
            externalID: externalID,
            toolName: toolName,
            arguments: arguments,
            risk: .write,
            status: .running
        )
        runtime.toolCalls.append(record)
        let recordID = record.id
        persistAgentSession(runtime: runtime)

        runtime.requestTask?.cancel()
        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.runDelegatedAgentToolCall(
                toolName: toolName,
                arguments: arguments,
                userText: delegatedUserText,
                textAttachments: textAttachments,
                images: images,
                executionAgent: executionAgent,
                delegatedRunID: delegatedContract.id,
                recordID: recordID,
                externalID: externalID,
                runtime: runtime
            )
        }
    }

    @MainActor
    private func runDelegatedAgentToolCall(
        toolName: String,
        arguments initialArguments: [String: AgentJSONValue],
        userText: String,
        textAttachments: [AgentTextAttachment],
        images: [AgentImageAttachment],
        executionAgent: AgentExecutionAgent,
        delegatedRunID: UUID,
        recordID: AgentToolCall.ID,
        externalID: String,
        runtime: AgentRuntime
    ) async {
        var arguments = initialArguments
        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let workspaceURL: URL?
        do {
            workspaceURL = try runtime.localWorkspaceURLForOptimisticUse()
        } catch {
            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.phase = .failed
                run.finishedAt = Date()
                run.lastError = error.localizedDescription
            }
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                executionAgent: executionAgent,
                status: .failed,
                result: nil,
                errorMessage: error.localizedDescription,
                toolPayload: "Delegated agent failed: \(error.localizedDescription)"
            )
            return
        }
        let remoteRuntimeDescriptor: RuntimeDescriptor? = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let delegatedImageBundle: AgentDelegatedImageBundle?
        if !images.isEmpty, workspaceLocation?.remoteRuntimeID == nil {
            delegatedImageBundle = try? AgentDelegatedImageBundle.create(images: images)
        } else {
            delegatedImageBundle = nil
        }
        let baselineTask = workspaceURL.map { workspaceURL in
            Task.detached(priority: .utility) {
                await Self.loadAgentWorktreeSnapshot(for: workspaceURL)
            }
        }

        defer {
            delegatedImageBundle?.removeAll()
            runtime.isResponding = false
            runtime.turnStartedAt = nil
            runtime.requestTask = nil
            persistAgentSession(runtime: runtime)
            consumeNextQueuedMessageIfNeeded(for: runtime)
        }

        if !images.isEmpty {
            let imageDescriptions: String?
            do {
                let configuration = agentConfiguration.normalized.imageDescription.agentConfiguration
                imageDescriptions = try await describeImagesForTextOnlyProvider(
                    images,
                    configuration: configuration
                )
            } catch {
                imageDescriptions = nil
            }
            let prompt = delegatedAgentPrompt(
                userText: userText,
                conversationMessages: runtime.messages,
                textAttachments: textAttachments,
                images: images,
                imageDescriptions: imageDescriptions,
                imageFilePaths: delegatedImageBundle?.fileURLs.map(\.path) ?? [],
                executionAgent: executionAgent,
                workspaceLocation: workspaceLocation,
                contract: delegatedTaskRun(
                    id: delegatedRunID,
                    runtime: runtime
                )?.contract
            )
            arguments["prompt"] = .string(prompt)
            if let delegatedImageBundle {
                arguments["image_paths"] = .array(
                    delegatedImageBundle.fileURLs.map { .string($0.path) }
                )
            }
            if let messageIndex = runtime.messages.firstIndex(where: {
                $0.toolCalls.contains(where: { $0.externalID == externalID })
            }), let callIndex = runtime.messages[messageIndex].toolCalls.firstIndex(where: { $0.externalID == externalID }) {
                runtime.messages[messageIndex].toolCalls[callIndex].argumentsJSON = Self.agentArgumentsJSONString(arguments)
            }
        }
        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
            runtime.toolCalls[index].arguments = arguments
        }

        let risk = AgentToolRegistry.risk(
            for: toolName,
            arguments: arguments,
            rootDirectory: workspaceURL
        )
        let sandboxDecision = AgentSandboxPolicy.decision(
            toolName: toolName,
            arguments: arguments,
            rootDirectory: workspaceURL
        )
        let autoApproval = Self.delegatedComposerApprovalSource(risk: risk)

        if Self.goalPlanningGateBlocks(
            toolName: toolName,
            arguments: arguments,
            risk: risk,
            isActive: runtime.isPlanGateActive
        ) {
            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.phase = .cancelled
                run.finishedAt = Date()
                run.lastError = "Goal planning validation required"
            }
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                executionAgent: executionAgent,
                status: .denied,
                result: nil,
                errorMessage: "Goal planning validation required",
                toolPayload: "Blocked: Goal evidence planning has not produced a validated execution plan yet."
            )
            return
        }

        if risk != .read && autoApproval == nil {
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                runtime.toolCalls[index].status = .pendingApproval
            }
            AgentToolApprovalNotifier.notifyIfBackgrounded(
                toolName: toolName,
                arguments: arguments,
                status: .pendingApproval
            )
            let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
            if Task.isCancelled {
                updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                    run.phase = .cancelled
                    run.finishedAt = Date()
                    run.lastError = L10n.DelegatedTask.interrupted
                }
                return
            }
            if case .denied(let reason) = decision {
                AgentSandboxAuditLog.append(
                    toolName: toolName,
                    arguments: arguments,
                    decision: sandboxDecision,
                    approvalSource: nil,
                    outcome: "denied"
                )
                updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                    run.phase = .cancelled
                    run.finishedAt = Date()
                    run.lastError = reason
                }
                finishDelegatedAgentRecord(
                    runtime: runtime,
                    recordID: recordID,
                    externalID: externalID,
                    executionAgent: executionAgent,
                    status: .denied,
                    result: nil,
                    errorMessage: reason,
                    toolPayload: "Delegated agent call denied by the user."
                )
                return
            }
        }

        let approvalSource: AgentToolApprovalSource? = autoApproval
            ?? (risk == .read ? nil : (sandboxDecision.mode == .escalated ? .escalated : .user))
        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
            runtime.toolCalls[index].status = .running
            runtime.toolCalls[index].approvalSource = approvalSource
        }

        if arguments["use_visible_terminal"]?.boolValue() == true {
            var sidePanelState = runtime.sidePanelState
            sidePanelState.kind = .terminal
            sidePanelState.lastViewedAt = Date()
            runtime.sidePanelState = sidePanelState
            persistAgentSidePanelState(runtime: runtime)
        }

        let context = AgentToolContext(
            rootDirectory: workspaceURL,
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: remoteRuntimeDescriptor,
            runtimeID: runtime.id,
            turnID: runtime.activeTurnID,
            jobRegistry: agentJobRegistry,
            mediaTaskRegistry: agentMediaTaskRegistry,
            shortDramaStore: agentShortDramaStore,
            sessionPersistenceBarrier: {
                self.persistAgentSession(
                    runtime: runtime,
                    touchUpdatedAt: false,
                    moveToFront: false
                )
                AgentSessionStore.flushPendingWrites()
            },
            localCommandEnvironment: AgentToolRunner.localCommandEnvironment(
                settings: editorTerminalSettings
            ),
            sandboxMode: sandboxModeForToolExecution(
                risk: risk,
                approvalSource: approvalSource,
                sandboxDecision: sandboxDecision
            ),
            terminalController: agentTerminalController,
            delegatedProgressSink: { update in
                self.updateDelegatedTerminalProgress(
                    id: delegatedRunID,
                    runtime: runtime,
                    update: update
                )
            }
        )

        do {
            let outcome = try await runDelegatedTaskWithAcceptance(
                toolName: toolName,
                initialArguments: arguments,
                executionAgent: executionAgent,
                delegatedRunID: delegatedRunID,
                runtime: runtime,
                context: context,
                workspaceURL: workspaceURL,
                baselineTask: baselineTask
            )
            AgentSandboxAuditLog.append(
                toolName: toolName,
                arguments: arguments,
                decision: sandboxDecision,
                approvalSource: approvalSource,
                outcome: outcome.accepted ? "accepted" : "acceptance_failed"
            )
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                executionAgent: executionAgent,
                status: outcome.accepted ? .succeeded : .failed,
                result: outcome.result,
                errorMessage: outcome.accepted ? nil : outcome.errorMessage,
                toolPayload: outcome.result.payload
            )
            refreshDelegatedAgentWorktreeInBackground(
                runtimeID: runtime.id,
                workspaceURL: workspaceURL,
                baselineTask: baselineTask
            )
        } catch is CancellationError {
            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.phase = .cancelled
                run.finishedAt = Date()
                run.lastError = "Cancelled"
            }
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                executionAgent: executionAgent,
                status: .failed,
                result: nil,
                errorMessage: "Cancelled",
                toolPayload: "Delegated agent cancelled."
            )
        } catch {
            let errorMessage = diagnoseDelegatedLocalWorkspaceIfNeeded(
                after: error,
                runtime: runtime,
                workspaceURL: workspaceURL
            ) ?? error.localizedDescription
            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.phase = .failed
                run.finishedAt = Date()
                run.lastError = errorMessage
            }
            AgentSandboxAuditLog.append(
                toolName: toolName,
                arguments: arguments,
                decision: sandboxDecision,
                approvalSource: approvalSource,
                outcome: "failed"
            )
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                executionAgent: executionAgent,
                status: .failed,
                result: nil,
                errorMessage: errorMessage,
                toolPayload: "Tool error: \(errorMessage)"
            )
        }
    }

    struct DelegatedAcceptanceOutcome {
        let accepted: Bool
        let result: AgentToolResult
        let errorMessage: String?
    }

    @MainActor
    func runDelegatedTaskWithAcceptance(
        toolName: String,
        initialArguments: [String: AgentJSONValue],
        executionAgent: AgentExecutionAgent,
        delegatedRunID: UUID,
        runtime: AgentRuntime,
        context: AgentToolContext,
        workspaceURL: URL?,
        baselineTask: Task<AgentWorktreeSnapshot, Never>?
    ) async throws -> DelegatedAcceptanceOutcome {
        guard let contract = delegatedTaskRun(id: delegatedRunID, runtime: runtime)?.contract else {
            let result = try await AgentToolRunner.run(
                name: toolName,
                arguments: initialArguments,
                context: context
            )
            return DelegatedAcceptanceOutcome(accepted: true, result: result, errorMessage: nil)
        }

        var arguments = initialArguments
        var lastExecutionResult: AgentToolResult?
        var lastAcceptance: AgentDelegatedWillDeepAcceptance?

        for attempt in 1...contract.maxAttempts {
            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.phase = .executing
                run.attempt = attempt
                run.startedAt = run.startedAt ?? Date()
                run.finishedAt = nil
                run.lastError = nil
            }

            let executionResult = try await AgentToolRunner.run(
                name: toolName,
                arguments: arguments,
                context: context
            )
            lastExecutionResult = executionResult

            let currentSnapshot = await Self.loadAgentWorktreeSnapshot(
                for: workspaceURL
            )
            let baselineSnapshot = await baselineTask?.value ?? AgentWorktreeSnapshot(
                status: GitRepositoryStatus(),
                changes: AgentWorktreeChangeSummary(),
                fingerprint: "",
                fileSignatures: [:]
            )
            let changedPaths = Self.agentWorktreePathsChangedSinceBaseline(
                baseline: baselineSnapshot,
                current: currentSnapshot
            ).sorted()

            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.phase = .selfVerifying
                run.changedPaths = changedPaths
            }

            let executorEvidence: AgentDelegatedExecutorEvidence?
            if contract.requiresFreshSelfReview {
                let reviewPrompt = AgentDelegatedTaskControl.freshReviewPrompt(
                    contract: contract,
                    changedPaths: changedPaths,
                    executionOutput: executionResult.payload
                )
                var reviewArguments = Self.delegatedAgentArguments(
                    prompt: reviewPrompt,
                    executionAgent: executionAgent
                )
                reviewArguments["permission_mode"] = .string("plan")
                reviewArguments["run_in_background"] = .bool(false)
                reviewArguments["use_visible_terminal"] = .bool(true)
                reviewArguments["visible_terminal_label"] = .string(
                    "\(executionAgent.displayName) · \(L10n.DelegatedTask.selfReview)"
                )
                reviewArguments["timeout_seconds"] = .number(Double(contract.timeoutSeconds))
                let reviewResult = try? await AgentToolRunner.run(
                    name: toolName,
                    arguments: reviewArguments,
                    context: context
                )
                executorEvidence = reviewResult.flatMap {
                    AgentDelegatedTaskControl.parseExecutorEvidence(from: $0.payload)
                }
            } else {
                executorEvidence = AgentDelegatedTaskControl.parseExecutorEvidence(
                    from: executionResult.payload
                )
            }

            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.executorEvidence = executorEvidence
                run.phase = .willDeepVerifying
            }

            let rerunChecks = await runDelegatedWillDeepVerification(
                contract: contract,
                evidence: executorEvidence,
                context: context,
                workspaceURL: workspaceURL
            )
            let acceptance = AgentDelegatedTaskControl.structuralAcceptance(
                contract: contract,
                evidence: executorEvidence,
                changedPaths: changedPaths,
                rerunChecks: rerunChecks
            )
            lastAcceptance = acceptance

            updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
                run.willDeepAcceptance = acceptance
                run.phase = acceptance.accepted ? .readyForDelivery : .reworkRequired
                run.finishedAt = acceptance.accepted ? Date() : nil
                run.lastError = acceptance.accepted ? nil : acceptance.summary
            }

            if acceptance.accepted {
                let payload = Self.delegatedAcceptedPayload(
                    executionAgent: executionAgent,
                    executionResult: executionResult,
                    acceptance: acceptance,
                    attempt: attempt
                )
                return DelegatedAcceptanceOutcome(
                    accepted: true,
                    result: AgentToolResult(
                        summary: "\(executionAgent.displayName) · \(L10n.DelegatedTask.accepted)",
                        payload: payload
                    ),
                    errorMessage: nil
                )
            }

            guard attempt < contract.maxAttempts else { break }
            arguments["prompt"] = .string(
                AgentDelegatedTaskControl.reworkPrompt(
                    contract: contract,
                    findings: acceptance.findings,
                    attempt: attempt
                )
            )
            arguments["visible_terminal_label"] = .string(
                "\(executionAgent.displayName) · \(L10n.DelegatedTask.rework)"
            )
        }

        let executionResult = lastExecutionResult ?? AgentToolResult(
            summary: L10n.DelegatedTask.failed,
            payload: L10n.DelegatedTask.noExecutionOutput
        )
        let acceptance = lastAcceptance ?? AgentDelegatedWillDeepAcceptance(
            accepted: false,
            summary: L10n.DelegatedTask.acceptanceUnavailable,
            checks: [],
            findings: [L10n.DelegatedTask.acceptanceUnavailable],
            verifiedAt: Date()
        )
        updateDelegatedTaskRun(id: delegatedRunID, runtime: runtime) { run in
            run.phase = .failed
            run.finishedAt = Date()
            run.lastError = acceptance.summary
        }
        let findings = acceptance.findings.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let payload = """
        \(executionResult.payload)

        --- WillDeep acceptance ---
        \(acceptance.summary)
        \(findings)
        """
        return DelegatedAcceptanceOutcome(
            accepted: false,
            result: AgentToolResult(
                summary: "\(executionAgent.displayName) · \(L10n.DelegatedTask.rejected)",
                payload: payload
            ),
            errorMessage: acceptance.summary
        )
    }

    @MainActor
    private func runDelegatedWillDeepVerification(
        contract: AgentDelegatedTaskContract,
        evidence: AgentDelegatedExecutorEvidence?,
        context: AgentToolContext,
        workspaceURL: URL?
    ) async -> [AgentDelegatedHostCheck] {
        let commands = AgentDelegatedTaskControl.verificationCommands(
            contract: contract,
            evidence: evidence
        )
        guard !commands.isEmpty else {
            return [
                AgentDelegatedHostCheck(
                    id: "host-rerun",
                    label: L10n.DelegatedTask.hostRerun,
                    status: .skipped,
                    detail: L10n.DelegatedTask.noSafeVerificationCommand
                )
            ]
        }

        var checks: [AgentDelegatedHostCheck] = []
        for (offset, command) in commands.enumerated() {
            guard AgentDelegatedTaskControl.isSafeVerificationCommand(
                command,
                workspaceURL: workspaceURL
            ) else {
                checks.append(
                    AgentDelegatedHostCheck(
                        id: "host-rerun-\(offset + 1)",
                        label: L10n.DelegatedTask.hostRerun,
                        status: .inconclusive,
                        detail: L10n.DelegatedTask.unsafeVerificationCommand,
                        command: command
                    )
                )
                continue
            }
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: workspaceURL
            )
            do {
                let result = try await AgentToolRunner.run(
                    name: "run_command",
                    arguments: [
                        "command": .string(command),
                        "run_in_background": .bool(false),
                        "timeout_seconds": .number(900)
                    ],
                    context: context.withSandboxMode(decision.mode)
                )
                checks.append(
                    AgentDelegatedHostCheck(
                        id: "host-rerun-\(offset + 1)",
                        label: L10n.DelegatedTask.hostRerun,
                        status: .passed,
                        detail: result.summary,
                        command: command,
                        exitCode: 0
                    )
                )
            } catch {
                checks.append(
                    AgentDelegatedHostCheck(
                        id: "host-rerun-\(offset + 1)",
                        label: L10n.DelegatedTask.hostRerun,
                        status: .failed,
                        detail: error.localizedDescription,
                        command: command
                    )
                )
            }
        }
        return checks
    }

    private func delegatedTaskRun(
        id: UUID,
        runtime: AgentRuntime
    ) -> AgentDelegatedTaskRun? {
        runtime.delegatedTaskRuns.first(where: { $0.id == id })
    }

    func updateDelegatedTaskRun(
        id: UUID,
        runtime: AgentRuntime,
        update: (inout AgentDelegatedTaskRun) -> Void
    ) {
        guard let index = runtime.delegatedTaskRuns.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&runtime.delegatedTaskRuns[index])
        syncDelegatedToolProgress(
            run: runtime.delegatedTaskRuns[index],
            runtime: runtime
        )
        persistAgentSession(runtime: runtime)
    }

    private func syncDelegatedToolProgress(
        run: AgentDelegatedTaskRun,
        runtime: AgentRuntime
    ) {
        guard let callIndex = runtime.toolCalls.firstIndex(where: {
            $0.arguments["delegated_task_id"]?.stringValue() == run.id.uuidString
        }) else {
            return
        }
        var progress = runtime.toolCalls[callIndex].delegatedProgress
            ?? AgentDelegatedLiveProgress(
                maximumAttempts: run.contract.maxAttempts
            )
        progress.phase = run.phase
        progress.attempt = run.attempt
        progress.maximumAttempts = run.contract.maxAttempts
        runtime.toolCalls[callIndex].delegatedProgress = progress
    }

    func updateDelegatedTerminalProgress(
        id: UUID,
        runtime: AgentRuntime,
        update: AgentDelegatedTerminalProgressUpdate
    ) {
        guard let run = delegatedTaskRun(id: id, runtime: runtime),
              let callIndex = runtime.toolCalls.firstIndex(where: {
                  $0.arguments["delegated_task_id"]?.stringValue() == id.uuidString
              }) else {
            return
        }
        var progress = runtime.toolCalls[callIndex].delegatedProgress
            ?? AgentDelegatedLiveProgress(
                phase: run.phase,
                attempt: run.attempt,
                maximumAttempts: run.contract.maxAttempts
            )
        progress.terminalTabID = update.terminalTabID
        if let currentActivity = update.currentActivity {
            progress.currentActivity = currentActivity
        }
        if let recentOutput = update.recentOutput {
            progress.recentOutput = recentOutput
        }
        runtime.toolCalls[callIndex].delegatedProgress = progress
    }

    nonisolated private static func delegatedAcceptedPayload(
        executionAgent: AgentExecutionAgent,
        executionResult: AgentToolResult,
        acceptance: AgentDelegatedWillDeepAcceptance,
        attempt: Int
    ) -> String {
        let handoff = delegatedAgentFinalResponse(from: executionResult.payload)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = handoff.isEmpty
            ? delegatedAgentVisibleOutputFallback(executionResult.payload)
            : handoff
        return """
        \(executionResult.payload)

        WILLDEEP_FINAL_RESPONSE_BEGIN
        \(body)

        \(L10n.DelegatedTask.acceptancePassed(attempt))
        WILLDEEP_FINAL_RESPONSE_END
        """
    }

    private func diagnoseDelegatedLocalWorkspaceIfNeeded(
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

    nonisolated static func delegatedComposerApprovalSource(
        risk: AgentToolRisk
    ) -> AgentToolApprovalSource? {
        risk == .read ? nil : .user
    }

    @MainActor
    private func refreshDelegatedAgentWorktreeInBackground(
        runtimeID: AgentSession.ID,
        workspaceURL: URL?,
        baselineTask: Task<AgentWorktreeSnapshot, Never>?
    ) {
        Task { @MainActor [weak self] in
            let baselineSnapshot = await baselineTask?.value ?? AgentWorktreeSnapshot(
                status: GitRepositoryStatus(),
                changes: AgentWorktreeChangeSummary(),
                fingerprint: "",
                fileSignatures: [:]
            )
            guard let self,
                  let runtime = self.agentRuntimes[runtimeID] else {
                return
            }
            await self.refreshGitStatusAfterAgentTool(
                for: runtime,
                workspaceURL: workspaceURL,
                baselineSnapshot: baselineSnapshot
            )
        }
    }

    func surfaceDelegatedBackgroundJobCompletionIfNeeded(_ job: AgentBackgroundJob) {
        guard let executionAgent = Self.delegatedExecutionAgent(forBackgroundJobCommand: job.command),
              let runtime = agentRuntimes[job.runtimeID] else {
            return
        }
        if surfacedDelegatedBackgroundJobIDs.contains(job.id) {
            agentJobRegistry.markCompletionSurfaced(id: job.id, forRuntime: job.runtimeID)
            return
        }

        surfacedDelegatedBackgroundJobIDs.insert(job.id)
        let output = agentJobRegistry.output(id: job.id)
        let content = Self.delegatedBackgroundJobCompletionContent(
            executionAgent: executionAgent,
            job: job,
            output: output
        )
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            agentJobRegistry.markCompletionSurfaced(id: job.id, forRuntime: job.runtimeID)
            return
        }

        runtime.messages.append(
            AgentMessage(
                role: .assistant,
                content: trimmed,
                origin: .delegatedExternal,
                originLabel: executionAgent.displayName
            )
        )
        persistAgentSession(runtime: runtime)
        agentJobRegistry.markCompletionSurfaced(id: job.id, forRuntime: job.runtimeID)
    }

    private func finishDelegatedAgentRecord(
        runtime: AgentRuntime,
        recordID: AgentToolCall.ID,
        externalID: String,
        executionAgent: AgentExecutionAgent,
        status: AgentToolCallStatus,
        result: AgentToolResult?,
        errorMessage: String?,
        toolPayload: String
    ) {
        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
            runtime.toolCalls[index].status = status
            runtime.toolCalls[index].result = result
            runtime.toolCalls[index].errorMessage = errorMessage
        }
        appendToolMessage(
            for: runtime,
            toolCallID: externalID,
            payload: toolPayload,
            source: status == .succeeded ? .toolOutput : .systemNotice,
            outcomeStatus: status,
            errorMessage: errorMessage
        )
        let visibleContent = Self.delegatedAgentVisibleContent(
            executionAgent: executionAgent,
            status: status,
            result: result,
            errorMessage: errorMessage,
            toolPayload: toolPayload
        )
        if !visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runtime.messages.append(
                AgentMessage(
                    role: .assistant,
                    content: visibleContent,
                    origin: .delegatedExternal,
                    originLabel: executionAgent.displayName
                )
            )
        }
    }

    static func delegatedAgentVisibleContent(
        executionAgent: AgentExecutionAgent,
        status: AgentToolCallStatus,
        result: AgentToolResult?,
        errorMessage: String?,
        toolPayload: String
    ) -> String {
        let label = executionAgent.displayName
        switch status {
        case .succeeded:
            if let notice = delegatedAgentBackgroundStartNotice(
                executionAgent: executionAgent,
                result: result,
                toolPayload: toolPayload
            ) {
                return notice
            }
            let output = delegatedAgentReadableOutput(from: result?.payload ?? toolPayload)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                return delegatedAgentFinalResponse(from: output)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? delegatedAgentVisibleOutputFallback(output)
            }
            return result?.summary.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "\(label) finished."
        case .failed:
            let detail = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Unknown error"
            let output = delegatedAgentReadableOutput(from: toolPayload)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty || output == detail {
                return "\(label) failed: \(detail)"
            }
            return "\(label) failed: \(detail)\n\n\(delegatedAgentVisibleErrorFallback(output))"
        case .denied:
            let detail = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "The delegated agent call was not approved."
            return "\(label) did not run: \(detail)"
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer, .running:
            return ""
        }
    }

    static func delegatedAgentBackgroundStartNotice(
        executionAgent: AgentExecutionAgent,
        result: AgentToolResult?,
        toolPayload: String
    ) -> String? {
        let payload = toolPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.hasPrefix("Started background job ") else { return nil }

        let firstLine = payload.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let handle = firstLine
            .replacingOccurrences(of: "Started background job ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = executionAgent.displayName
        if handle.isEmpty {
            return "\(label) 已在后台运行。完成后会自动回写结果。"
        }
        return "\(label) 已在后台运行（\(handle)）。完成后会自动回写结果。"
    }

    static func delegatedExecutionAgent(
        forBackgroundJobCommand command: String
    ) -> AgentExecutionAgent? {
        guard command.contains("WillDeep Delegated Executor Context Package v2")
                || command.contains("WillDeep Delegated Executor Context Package v1") else {
            return nil
        }
        for executionAgent in AgentExecutionAgent.allCases where executionAgent.toolName != nil {
            if command.contains("selected execution agent: \(executionAgent.displayName)") {
                return executionAgent
            }
        }
        return nil
    }

    static func delegatedBackgroundJobCompletionContent(
        executionAgent: AgentExecutionAgent,
        job: AgentBackgroundJob,
        output: String
    ) -> String {
        let label = executionAgent.displayName
        let readableOutput = delegatedAgentReadableOutput(from: output)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if job.status == .completed {
            if let final = delegatedAgentFinalResponse(from: readableOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty {
                return final
            }
            if !readableOutput.isEmpty {
                return delegatedAgentVisibleOutputFallback(readableOutput)
            }
            return "\(label) 已完成（\(job.displayHandle)），但没有捕获到输出。"
        }

        let prefix: String
        switch job.status {
        case .running:
            prefix = "\(label) 后台任务仍在运行（\(job.displayHandle)）。"
        case .failed:
            let exitText = job.exitCode.map { "exit \($0)" } ?? "exit unknown"
            prefix = "\(label) 后台任务失败（\(job.displayHandle)，\(exitText)）。"
        case .killed:
            prefix = "\(label) 后台任务已停止（\(job.displayHandle)）。"
        case .timedOut:
            prefix = "\(label) 后台任务超时（\(job.displayHandle)）。"
        case .launchFailed:
            prefix = "\(label) 后台任务启动失败（\(job.displayHandle)）。"
        case .completed:
            prefix = "\(label) 已完成（\(job.displayHandle)）。"
        }

        let final = delegatedAgentFinalResponse(from: readableOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let detail = final ?? (
            readableOutput.isEmpty
                ? ""
                : delegatedAgentVisibleErrorFallback(readableOutput)
        )
        if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return prefix
        }
        return "\(prefix)\n\n\(detail)"
    }

    nonisolated static func delegatedAgentReadableOutput(from payload: String) -> String {
        let stdoutMarker = "--- stdout ---"
        let stderrMarker = "--- stderr ---"
        guard let stdoutRange = payload.range(of: stdoutMarker),
              let stderrRange = payload.range(of: stderrMarker, range: stdoutRange.upperBound..<payload.endIndex) else {
            return payload
        }
        let stdout = String(payload[stdoutRange.upperBound..<stderrRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        return String(payload[stderrRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func delegatedAgentFinalResponse(from output: String) -> String {
        let startMarker = "WILLDEEP_FINAL_RESPONSE_BEGIN"
        let endMarker = "WILLDEEP_FINAL_RESPONSE_END"
        let placeholder = "<concise user-facing answer, change summary, verification, and any important caveats>"
        var searchEnd = output.endIndex
        while let startRange = output.range(of: startMarker, options: .backwards, range: output.startIndex..<searchEnd) {
            let bodyStart = startRange.upperBound
            let bodyEnd = output.range(of: endMarker, range: bodyStart..<output.endIndex)?.lowerBound ?? output.endIndex
            let body = String(output[bodyStart..<bodyEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty && body != placeholder {
                return body
            }
            searchEnd = startRange.lowerBound
        }
        return ""
    }

    nonisolated static func delegatedAgentVisibleOutputFallback(_ output: String) -> String {
        let maxCharacters = 6_000
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return """
        \(trimmed[..<end])

        [Output truncated for the main conversation. Full delegated executor stdout is preserved in the tool result.]
        """
    }

    nonisolated static func delegatedAgentVisibleErrorFallback(_ output: String) -> String {
        let maxCharacters = 2_400
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -maxCharacters)
        return """
        [Earlier delegated executor output omitted. Full stdout/stderr is preserved in the tool result.]

        \(trimmed[start...])
        """
    }

    nonisolated static func delegatedConversationContextBlock(
        from messages: [AgentMessage],
        currentUserText: String
    ) -> String? {
        let current = currentUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [(role: String, content: String)] = []
        for message in messages {
            guard message.role == .user || message.role == .assistant else { continue }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            candidates.append((message.role.rawValue, content))
        }
        if let last = candidates.last, last.role == AgentRole.user.rawValue, last.content == current {
            candidates.removeLast()
        }
        let recent = candidates.suffix(6)
        guard !recent.isEmpty else { return nil }

        var lines: [String] = []
        var usedCharacters = 0
        let totalLimit = 3_600
        let perMessageLimit = 700
        for item in recent {
            let clipped = Self.clippedDelegatedContext(item.content, limit: perMessageLimit)
            let line = "- \(item.role): \(clipped)"
            guard usedCharacters + line.count <= totalLimit else {
                lines.append("- [Earlier context omitted to keep the delegated prompt compact.]")
                break
            }
            lines.append(line)
            usedCharacters += line.count
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func clippedDelegatedContext(_ value: String, limit: Int) -> String {
        let singleLine = value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        let end = singleLine.index(singleLine.startIndex, offsetBy: limit)
        return "\(singleLine[..<end]) [truncated]"
    }

    private func delegatedAgentPrompt(
        userText: String,
        conversationMessages: [AgentMessage],
        textAttachments: [AgentTextAttachment],
        images: [AgentImageAttachment],
        imageDescriptions: String?,
        imageFilePaths: [String],
        executionAgent: AgentExecutionAgent,
        workspaceLocation: WorkspaceLocation?,
        contract: AgentDelegatedTaskContract? = nil
    ) -> String {
        var blocks: [String] = [
            """
            WillDeep Delegated Executor Context Package v2

            You are being invoked from WillDeep Composer as the selected execution agent: \(executionAgent.displayName).
            Work on the user's task end-to-end in the current workspace. WillDeep owns the task contract, supervises execution, runs an independent fresh review, and performs the final acceptance gate.
            Keep raw logs, long command output, and implementation scratch notes outside the final response block. WillDeep keeps the full tool output separately; the main conversation should only receive a compact user-facing answer.

            At the end of your stdout, emit exactly one final response block by writing `WILLDEEP_FINAL_RESPONSE_BEGIN`, then your concise user-facing answer, then `WILLDEEP_FINAL_RESPONSE_END`. Do not copy placeholder text.
            """
        ]
        if let contract {
            blocks.append(AgentDelegatedTaskControl.executorInstructions(contract: contract))
        }
        if let path = workspaceLocation?.path, !path.isEmpty {
            blocks.append("Workspace: \(path)")
        }
        if let conversationContext = Self.delegatedConversationContextBlock(
            from: conversationMessages,
            currentUserText: userText
        ) {
            blocks.append("""
            ### Recent WillDeep conversation summary

            The delegated CLI cannot see the WillDeep chat history. Use this compact summary for continuity; the current user task appears later and takes priority.

            \(conversationContext)
            """)
        }
        if !images.isEmpty {
            if let imageDescriptions, !imageDescriptions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append("""
                ### Image descriptions generated by WillDeep VL model

                \(imageDescriptions)
                """)
            } else if !imageFilePaths.isEmpty {
                blocks.append("WillDeep VL description was unavailable. Inspect the original image files below directly.")
            } else {
                blocks.append("WillDeep could not prepare a VL description or a local image copy. Continue using the available text context and report that visual details could not be inspected.")
            }
        }
        if !imageFilePaths.isEmpty {
            let fileList = imageFilePaths.enumerated().map { offset, path in
                "- Image \(offset + 1): \(path)"
            }.joined(separator: "\n")
            blocks.append("""
            ### Original image attachment files

            These are permission-scoped temporary copies of the original attachments. Inspect them directly for pixel-level details; the VL description above is a fallback and may omit fine text, colors, or spacing.

            \(fileList)
            """)
        }
        if !textAttachments.isEmpty {
            blocks.append(textAttachments.map(\.modelBlock).joined(separator: "\n\n"))
        }
        blocks.append("### Current user task")
        blocks.append(userText)
        return blocks.joined(separator: "\n\n")
    }

    static func delegatedAgentArguments(
        prompt: String,
        executionAgent: AgentExecutionAgent,
        contract: AgentDelegatedTaskContract? = nil,
        planningOnly: Bool = false
    ) -> [String: AgentJSONValue] {
        var arguments: [String: AgentJSONValue] = [
            "prompt": .string(prompt),
            "run_in_background": .bool(false),
            "use_visible_terminal": .bool(true),
            "visible_terminal_label": .string(executionAgent.displayName),
        ]
        if planningOnly {
            arguments["permission_mode"] = .string("plan")
        } else if let permissionMode = executionAgent.defaultPermissionMode {
            arguments["permission_mode"] = .string(permissionMode)
        }
        if let contract {
            arguments["delegated_task_id"] = .string(contract.id.uuidString)
            arguments["max_attempts"] = .number(Double(contract.maxAttempts))
            arguments["timeout_seconds"] = .number(Double(contract.timeoutSeconds))
            arguments["verification_policy"] = .string(
                contract.requiresFreshSelfReview ? "double" : "self"
            )
        }
        return arguments
    }

    nonisolated private static func agentArgumentsJSONString(_ arguments: [String: AgentJSONValue]) -> String {
        let raw = arguments.mapValues(\.rawAny)
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    func activeRuntimeAfterCreatingNewSession() -> AgentRuntime? {
        _ = startNewAgentSession()
        return activeRuntime
    }

    @discardableResult
    func appendAgentInputTextCreatingSessionIfNeeded(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if activeRuntime == nil {
            if let id = activeAgentSessionID {
                _ = runtime(for: id)
                subscribeToActiveRuntime()
            }
            if activeRuntime == nil {
                _ = activeRuntimeAfterCreatingNewSession()
            }
        }

        guard let runtime = activeRuntime else { return false }
        runtime.input = runtime.input.isEmpty ? trimmed : runtime.input + " " + trimmed
        return true
    }

    @discardableResult
    func appendVoiceTranscriptCreatingSessionIfNeeded(_ transcript: String) async -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let mode = UserPreferences.shared.transcriptCleanupMode
        guard mode.usesAI else {
            return appendAgentInputTextCreatingSessionIfNeeded(trimmed)
        }

        let modelID = agentConfiguration.normalized.titleSummaryModel()
        let configurations = titleSummaryConfigurationCandidates(remoteModelID: modelID)
        let polished = await VoiceTranscriptPolisher.polish(
            transcript: trimmed,
            mode: mode,
            configurations: configurations
        )
        return appendAgentInputTextCreatingSessionIfNeeded(polished ?? trimmed)
    }

    func composeAttachedPrompt(
        userText: String,
        skills: [AgentSkillEntry],
        files: [AgentFileAttachment],
        includeWorkspaceOverview: Bool,
        documentTaskMode: AgentDocumentTaskMode = .automatic,
        redactSensitiveContent: Bool = true,
        imagePaths: [String] = []
    ) -> String {
        let designToCodeBlock = AgentDesignToCode.promptBlock(skills: skills, imagePaths: imagePaths)
        guard !skills.isEmpty || !files.isEmpty || includeWorkspaceOverview || designToCodeBlock != nil else { return userText }
        var blocks: [String] = []
        blocks.append(AgentAttachedPromptProtocol.preludeHeader)

        if includeWorkspaceOverview {
            blocks.append(workspaceOverviewBlock())
        }

        for skill in skills {
            let body = (AgentSkillDirectory.loadBody(for: skill) ?? "(skill body unavailable)")
                .replacingOccurrences(
                    of: AgentAttachedPromptProtocol.userTextBoundary,
                    with: AgentAttachedPromptProtocol.escapedUserTextBoundary
                )
            blocks.append("""
            ### Skill: \(skill.identifier)
            > \(skill.description)

            \(body)
            """)
        }

        if let designToCodeBlock {
            blocks.append(designToCodeBlock)
        }

        // Surface the file-backed paths of the user's uploaded/attached images so
        // the model can EDIT them in place. Without this the model only ever sees
        // the pixels (or, on text-only managed models, a text description) and has
        // no path to pass to the edit tool — so "把我的照片改成…、保持人脸" ends in
        // the model asking the user to re-upload or silently doing nothing.
        if !imagePaths.isEmpty {
            let lines = imagePaths.enumerated()
                .map { index, path in "- image_\(index + 1): `\(path)`" }
                .joined(separator: "\n")
            blocks.append("""
            ### Attached Images — File-Backed Paths

            The user's uploaded/attached images are saved locally at:
            \(lines)

            If the user asks to edit, restyle, retouch, or transform one of THESE \
            uploaded images (e.g. "改成正式照片/穿西装", "保持人脸", "换个背景"), call \
            the `edit_generated_image` tool with `image_path` set to the matching \
            path above and a `prompt` describing the change. It edits any local \
            image via some.im `images/edits`. Do NOT ask the user to re-upload, and \
            do NOT use `generate_image` for this — that synthesizes a brand-new \
            image from text and will not preserve the person/subject in the upload.
            """)
        }

        if !files.isEmpty {
            blocks.append(documentTaskInstruction(
                mode: documentTaskMode,
                userText: userText,
                files: files
            ))
        }

        for file in files {
            let renderedBody: String
            if let analysis = file.analysis {
                renderedBody = AgentLocalAttachmentRetriever.renderAttachment(
                    relativePath: file.relativePath,
                    sections: file.includedSections,
                    query: userText,
                    containsPotentialPromptInjection: analysis.containsPotentialPromptInjection,
                    warnings: analysis.warnings
                )
            } else {
                let body = readAttachedFileBody(at: file.url)
                renderedBody = AgentLocalAttachmentRetriever.renderAttachment(
                    relativePath: file.relativePath,
                    body: body,
                    query: userText
                )
            }
            let protectedBody = redactSensitiveContent
                ? AgentSensitiveContentRedactor.redact(renderedBody)
                : renderedBody
            blocks.append("""
            ### File: \(file.relativePath)

            \(protectedBody)
            """)
        }

        if !userText.isEmpty {
            blocks.append(AgentAttachedPromptProtocol.userTextBoundary)
            blocks.append(userText)
        }
        return blocks.joined(separator: "\n\n")
    }

    func setAgentDocumentTaskMode(_ mode: AgentDocumentTaskMode) {
        guard let runtime = activeRuntime else { return }
        runtime.documentTaskMode = mode
        runtime.persist(touchUpdatedAt: false)
    }

    func setAgentSensitiveAttachmentRedaction(_ enabled: Bool) {
        guard let runtime = activeRuntime else { return }
        runtime.redactSensitiveAttachmentContent = enabled
        runtime.persist(touchUpdatedAt: false)
    }

    func agentDocumentSendPreview() -> AgentDocumentSendPreview? {
        guard let runtime = activeRuntime else { return nil }
        let files = mergedAgentDocumentContextFiles(
            sessionDocuments: runtime.documentAttachments,
            knowledgeFolders: runtime.knowledgeFolders,
            pendingFiles: runtime.pendingFiles
        )
        guard !files.isEmpty else { return nil }
        let unredacted = composeAttachedPrompt(
            userText: runtime.input.trimmingCharacters(in: .whitespacesAndNewlines),
            skills: [],
            files: files,
            includeWorkspaceOverview: false,
            documentTaskMode: runtime.documentTaskMode,
            redactSensitiveContent: false
        )
        let findings = AgentSensitiveContentRedactor.findings(in: unredacted)
        let rendered = runtime.redactSensitiveAttachmentContent
            ? AgentSensitiveContentRedactor.redact(unredacted)
            : unredacted
        return AgentDocumentSendPreview(text: rendered, findings: findings)
    }

    private func documentTaskInstruction(
        mode: AgentDocumentTaskMode,
        userText: String,
        files: [AgentFileAttachment]
    ) -> String {
        let resolvedMode: AgentDocumentTaskMode
        if mode == .automatic {
            let query = userText.lowercased()
            if files.count >= 2, query.contains("比较") || query.contains("compare") || query.contains("差异") {
                resolvedMode = .compare
            } else if files.contains(where: { $0.analysis?.documentKind == .spreadsheet }),
                      query.contains("分析") || query.contains("统计") || query.contains("公式") || query.contains("analy") {
                resolvedMode = .spreadsheetAnalysis
            } else if query.contains("总结") || query.contains("摘要") || query.contains("summar") {
                resolvedMode = .summarize
            } else if query.contains("证据") || query.contains("依据") || query.contains("evidence") {
                resolvedMode = .evidenceExtraction
            } else if files.contains(where: { AgentComposerAttachmentSupport.textExtensions.contains($0.url.pathExtension.lowercased()) }),
                      query.contains("审查") || query.contains("review") || query.contains("bug") {
                resolvedMode = .codeReview
            } else {
                resolvedMode = .automatic
            }
        } else {
            resolvedMode = mode
        }

        switch resolvedMode {
        case .automatic:
            return "Document task mode: automatic. Answer the user's actual request and cite every document-backed claim with the exact [Source: file; locator] marker provided below."
        case .summarize:
            return "Document task mode: summarize. Produce a structured summary that preserves important qualifications and cite each major point with an exact [Source: file; locator] marker."
        case .compare:
            return "Document task mode: compare. Compare the supplied documents point by point, distinguish missing information from real differences, and cite both sides with exact [Source: file; locator] markers."
        case .spreadsheetAnalysis:
            return "Document task mode: spreadsheet analysis. Respect sheet names, formulas, cached values, headers, and hidden-sheet notices; cite every numerical conclusion with an exact [Source: file; sheet/lines] marker."
        case .codeReview:
            return "Document task mode: code review. Identify correctness, security, and maintainability issues without inventing repository context; cite findings with exact [Source: file; lines] markers."
        case .evidenceExtraction:
            return "Document task mode: evidence extraction. Separate direct evidence from inference, quote only short necessary fragments, and attach an exact [Source: file; locator] marker to every evidence item."
        }
    }

    func readAttachedFileBody(at url: URL) -> String {
        if let officeBody = AgentOfficeAttachmentReader.read(url: url) {
            return officeBody
        }

        let maxChars = 120_000
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return "```\n(file unreadable or binary)\n```"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.count > maxChars {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
            body = "\(trimmed[..<idx])\n\n[truncated at \(maxChars) chars]"
        } else {
            body = trimmed
        }
        return "```\n\(body)\n```"
    }

    func workspaceOverviewBlock() -> String {
        guard let root = rootDirectory else {
            return "### Workspace\n(no folder is currently open)"
        }
        let rootPath = root.standardizedFileURL.path
        let entries = quickOpenFiles
            .prefix(120)
            .map { url -> String in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
                let rel = String(path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return rel.isEmpty ? url.lastPathComponent : rel
            }
        let extraCount = max(0, quickOpenFiles.count - 120)
        let extraLine = extraCount > 0 ? "\n…and \(extraCount) more files" : ""
        return """
        ### Workspace
        Root: \(rootPath)
        Files (first \(entries.count)):
        ```
        \(entries.joined(separator: "\n"))\(extraLine)
        ```
        """
    }

    func attachAgentSkill(_ skill: AgentSkillEntry) {
        ensureActiveAgentSessionForInteractiveControl()
        guard !agentPendingSkills.contains(where: { $0.identifier == skill.identifier }) else { return }
        agentPendingSkills.append(skill)
    }

    func preparePendingImagesForDesignToCode() {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession(),
              !runtime.pendingImages.isEmpty else { return }
        let prompt = L10n.Composer.designToCodePrompt
        if runtime.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runtime.input = prompt
        } else if !runtime.input.contains(prompt) {
            runtime.input += "\n\n\(prompt)"
        }
        runtime.pendingSkills = AgentSkillAutoActivation.mergedSkills(
            userText: runtime.input,
            workspaceRootPath: runtime.workspaceRootPath ?? rootDirectory?.standardizedFileURL.path,
            manuallySelectedSkills: runtime.pendingSkills,
            hasVisualTargetAttachment: true
        )
        // This button is an explicit user choice, so its behavior must not
        // depend on whether a localized prompt happens to match a keyword.
        // Deterministically attach one visual implementation skill from the
        // actual workspace shape.
        if !runtime.pendingSkills.contains(where: AgentDesignToCode.isVisualImplementationSkill) {
            let workspacePath = runtime.workspaceRootPath ?? rootDirectory?.standardizedFileURL.path
            let identifier = AgentDesignToCode.preferredSkillIdentifier(workspaceRootPath: workspacePath)
            if let skill = AgentSkillDirectory.bundledSkill(identifier: identifier) {
                runtime.pendingSkills.append(skill)
            }
        }
        if runtime.pendingSkills.contains(where: { $0.identifier == AgentDesignToCode.webSkillIdentifier }) {
            runtime.activeExperts.formUnion(AgentDesignToCode.webExperts)
            // Mount the browser workbench before the turn starts so the Agent can
            // navigate, capture, and visually accept static or dev-server output
            // without falling back to an external `open` command.
            agentSidePanelKind = .embeddedBrowser
        }
        runtime.persist(touchUpdatedAt: false)
    }

    func startDesignToCodeFromSlashArguments(_ args: String) {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        let parsed = ImageWorkflowSupport.parse(args)
        guard let rawPath = parsed.positional.first else {
            runtime.errorMessage = "Usage: /screenshot-to-code <path> [framework=react] [context=\"where this screen lives\"]"
            return
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let imageURL = (expanded as NSString).isAbsolutePath
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : (runtime.workspaceRootPath.map { URL(fileURLWithPath: $0) } ?? rootDirectory)?
                .appendingPathComponent(expanded)
                .standardizedFileURL
        guard let imageURL,
              let data = try? Data(contentsOf: imageURL),
              (try? ImageWorkflowSupport.loadImage(path: imageURL.path)) != nil else {
            runtime.errorMessage = "Could not read UI screenshot: \(rawPath)"
            return
        }
        AgentDesignToCode.prepareRuntimeForSlashExecution(
            runtime,
            framework: parsed.options["framework"]
        )
        if runtime.activeExperts.contains(.browserOps) {
            agentSidePanelKind = .embeddedBrowser
        }
        let mimeType: String = switch imageURL.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "heic", "heif": "image/heic"
        case "tif", "tiff": "image/tiff"
        default: "image/png"
        }
        addAgentImage(data: data, mimeType: mimeType)
        let framework = parsed.options["framework"].map { " Target framework: \($0)." } ?? ""
        let productContext = parsed.options["context"].map { " Product context: \($0)." } ?? ""
        runtime.input = L10n.Composer.designToCodePrompt + framework + productContext
        preparePendingImagesForDesignToCode()
        sendAgentMessage()
    }

    func detachAgentSkill(identifier: String) {
        agentPendingSkills.removeAll { $0.identifier == identifier }
    }

    func attachAgentFile(url: URL, treatsUnknownTypeAsText: Bool = false) {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        let standardized = url.standardizedFileURL
        guard !runtime.pendingFiles.contains(where: { $0.url.standardizedFileURL == standardized }) else { return }
        let relative: String = {
            guard let root = runtime.workspaceRootPath ?? rootDirectory?.standardizedFileURL.path else {
                return standardized.lastPathComponent
            }
            let path = standardized.path
            guard path.hasPrefix(root) else { return standardized.lastPathComponent }
            let rel = String(path.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? standardized.lastPathComponent : rel
        }()
        let metadata = agentAttachmentSourceMetadata(for: standardized)
        if let existingIndex = runtime.documentAttachments.firstIndex(where: { $0.id == standardized.path }) {
            var existing = runtime.documentAttachments[existingIndex]
            existing.isEnabled = true
            let alreadyForcedToText = existing.treatsUnknownTypeAsText == true
            if treatsUnknownTypeAsText {
                existing.treatsUnknownTypeAsText = true
            }
            let forceTextNeedsReparse = treatsUnknownTypeAsText && !alreadyForcedToText
            if existing.parseStatus == .ready,
               existing.sourceFileSize == metadata.size,
               existing.sourceModifiedAt == metadata.modifiedAt,
               !forceTextNeedsReparse {
                runtime.documentAttachments[existingIndex] = existing
                runtime.pendingFiles.append(existing)
                runtime.persist(touchUpdatedAt: false)
                return
            }
        }

        var attachment = AgentFileAttachment(url: standardized, relativePath: relative)
        attachment.sourceFileSize = metadata.size
        attachment.sourceModifiedAt = metadata.modifiedAt
        attachment.treatsUnknownTypeAsText = treatsUnknownTypeAsText ? true : nil
        runtime.pendingFiles.append(attachment)
        runtime.documentAttachments.removeAll { $0.id == attachment.id }
        runtime.documentAttachments.append(attachment)
        runtime.persist(touchUpdatedAt: false)
        analyzeAgentFileAttachment(
            id: attachment.id,
            url: standardized,
            treatsUnknownTypeAsText: treatsUnknownTypeAsText,
            for: runtime
        )
    }

    func detachAgentFile(id: String) {
        guard let runtime = activeRuntime else { return }
        runtime.pendingFiles.removeAll { $0.id == id }
        runtime.documentAttachments.removeAll { $0.id == id }
        runtime.persist(touchUpdatedAt: false)
    }

    func toggleAgentFileSection(fileID: String, sectionID: String) {
        guard let index = agentPendingFiles.firstIndex(where: { $0.id == fileID }) else { return }
        var files = agentPendingFiles
        if files[index].excludedSectionIDs.contains(sectionID) {
            files[index].excludedSectionIDs.remove(sectionID)
        } else {
            files[index].excludedSectionIDs.insert(sectionID)
        }
        agentPendingFiles = files
        synchronizePendingAgentFileSelection(fileID: fileID, excludedSectionIDs: files[index].excludedSectionIDs)
    }

    func setAllAgentFileSections(fileID: String, included: Bool) {
        guard let index = agentPendingFiles.firstIndex(where: { $0.id == fileID }),
              let analysis = agentPendingFiles[index].analysis else { return }
        var files = agentPendingFiles
        files[index].excludedSectionIDs = included ? [] : Set(analysis.sectionSummaries.map(\.id))
        agentPendingFiles = files
        synchronizePendingAgentFileSelection(fileID: fileID, excludedSectionIDs: files[index].excludedSectionIDs)
    }

    var hasParsingAgentFileAttachments: Bool {
        agentPendingFiles.contains { $0.parseStatus == .parsing }
            || agentSessionDocuments.contains { $0.isEnabled && $0.parseStatus == .parsing }
            || agentKnowledgeFolders.contains { $0.isEnabled && $0.status == .indexing }
    }

    func toggleAgentSessionDocumentEnabled(id: String) {
        guard let runtime = activeRuntime,
              let index = runtime.documentAttachments.firstIndex(where: { $0.id == id }) else { return }
        runtime.documentAttachments[index].isEnabled.toggle()
        runtime.persist(touchUpdatedAt: false)
    }

    func removeAgentSessionDocument(id: String) {
        detachAgentFile(id: id)
    }

    func toggleAgentSessionDocumentSection(fileID: String, sectionID: String) {
        guard let runtime = activeRuntime,
              let index = runtime.documentAttachments.firstIndex(where: { $0.id == fileID }) else { return }
        if runtime.documentAttachments[index].excludedSectionIDs.contains(sectionID) {
            runtime.documentAttachments[index].excludedSectionIDs.remove(sectionID)
        } else {
            runtime.documentAttachments[index].excludedSectionIDs.insert(sectionID)
        }
        let excluded = runtime.documentAttachments[index].excludedSectionIDs
        if let pendingIndex = runtime.pendingFiles.firstIndex(where: { $0.id == fileID }) {
            runtime.pendingFiles[pendingIndex].excludedSectionIDs = excluded
        }
        runtime.persist(touchUpdatedAt: false)
    }

    func setAllAgentSessionDocumentSections(fileID: String, included: Bool) {
        guard let runtime = activeRuntime,
              let index = runtime.documentAttachments.firstIndex(where: { $0.id == fileID }),
              let analysis = runtime.documentAttachments[index].analysis else { return }
        let excluded = included ? Set<String>() : Set(analysis.sectionSummaries.map(\.id))
        runtime.documentAttachments[index].excludedSectionIDs = excluded
        if let pendingIndex = runtime.pendingFiles.firstIndex(where: { $0.id == fileID }) {
            runtime.pendingFiles[pendingIndex].excludedSectionIDs = excluded
        }
        runtime.persist(touchUpdatedAt: false)
    }

    private func analyzeAgentFileAttachment(
        id: String,
        url: URL,
        treatsUnknownTypeAsText: Bool,
        for runtime: AgentRuntime
    ) {
        Task { [weak runtime] in
            do {
                let analysis = try await AgentDocumentAttachmentParser
                    .analyze(url: url, forceText: treatsUnknownTypeAsText)
                    .externalizedOrInline()
                guard let runtime else { return }
                if let index = runtime.pendingFiles.firstIndex(where: { $0.id == id }) {
                    runtime.pendingFiles[index].analysis = analysis
                    runtime.pendingFiles[index].parseStatus = .ready
                    runtime.pendingFiles[index].parseError = nil
                }
                if let index = runtime.documentAttachments.firstIndex(where: { $0.id == id }) {
                    runtime.documentAttachments[index].analysis = analysis
                    runtime.documentAttachments[index].parseStatus = .ready
                    runtime.documentAttachments[index].parseError = nil
                }
                runtime.persist(touchUpdatedAt: false)
            } catch {
                guard let runtime else { return }
                if let index = runtime.pendingFiles.firstIndex(where: { $0.id == id }) {
                    runtime.pendingFiles[index].parseStatus = .failed
                    runtime.pendingFiles[index].parseError = error.localizedDescription
                }
                if let index = runtime.documentAttachments.firstIndex(where: { $0.id == id }) {
                    runtime.documentAttachments[index].parseStatus = .failed
                    runtime.documentAttachments[index].parseError = error.localizedDescription
                }
                runtime.persist(touchUpdatedAt: false)
            }
        }
    }

    private func mergedAgentDocumentContextFiles(
        sessionDocuments: [AgentFileAttachment],
        knowledgeFolders: [AgentKnowledgeFolder],
        pendingFiles: [AgentFileAttachment]
    ) -> [AgentFileAttachment] {
        var byID: [String: AgentFileAttachment] = [:]
        for file in sessionDocuments where file.isEnabled && file.parseStatus == .ready {
            byID[file.id] = file
        }
        for file in pendingFiles where file.parseStatus == .ready {
            byID[file.id] = file
        }
        for folder in knowledgeFolders where folder.isEnabled && folder.status == .ready {
            for file in folder.documents where file.parseStatus == .ready {
                byID[file.id] = file
            }
        }
        return byID.values.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func synchronizePendingAgentFileSelection(fileID: String, excludedSectionIDs: Set<String>) {
        guard let runtime = activeRuntime else { return }
        if let index = runtime.documentAttachments.firstIndex(where: { $0.id == fileID }) {
            runtime.documentAttachments[index].excludedSectionIDs = excludedSectionIDs
            runtime.persist(touchUpdatedAt: false)
        }
    }

    private func refreshChangedAgentSessionDocumentsIfNeeded(in runtime: AgentRuntime) -> Bool {
        var startedParsing = false
        for index in runtime.documentAttachments.indices where runtime.documentAttachments[index].isEnabled {
            let file = runtime.documentAttachments[index]
            let metadata = agentAttachmentSourceMetadata(for: file.url)
            guard metadata.size != file.sourceFileSize || metadata.modifiedAt != file.sourceModifiedAt else { continue }
            runtime.documentAttachments[index].sourceFileSize = metadata.size
            runtime.documentAttachments[index].sourceModifiedAt = metadata.modifiedAt
            runtime.documentAttachments[index].parseStatus = .parsing
            runtime.documentAttachments[index].analysis = nil
            runtime.documentAttachments[index].parseError = nil
            analyzeAgentFileAttachment(
                id: file.id,
                url: file.url,
                treatsUnknownTypeAsText: file.treatsUnknownTypeAsText == true,
                for: runtime
            )
            startedParsing = true
        }
        if startedParsing {
            runtime.persist(touchUpdatedAt: false)
        }
        return startedParsing
    }

    private func agentAttachmentSourceMetadata(for url: URL) -> (size: Int64?, modifiedAt: Date?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize.map(Int64.init), values?.contentModificationDate)
    }

    func addAgentTextAttachment(content rawContent: String) {
        let content = AgentTextAttachment.sanitizedPastedContent(rawContent)
        guard !content.isEmpty else { return }
        agentPendingTextAttachments.append(
            AgentTextAttachment(filename: L10n.AgentTextAttachment.pastedFilename, content: content)
        )
    }

    func addAgentChatSelectionToTask(_ rawContent: String) {
        let content = AgentTextAttachment.sanitizedPastedContent(rawContent)
        guard !content.isEmpty else { return }
        if activeRuntime == nil {
            _ = activeRuntimeAfterCreatingNewSession()
        }
        agentPendingTextAttachments.append(
            AgentTextAttachment(filename: L10n.AgentSelection.chatExcerptFilename, content: content)
        )
        isAgentPanelVisible = true
        agentComposerFocusRevision += 1
    }

    func appendGeneratedImageReferenceToAgentInput(_ marker: String) {
        let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if activeRuntime == nil {
            _ = activeRuntimeAfterCreatingNewSession()
        }
        guard let runtime = activeRuntime else { return }
        let current = runtime.input.trimmingCharacters(in: .whitespacesAndNewlines)
        runtime.input = current.isEmpty ? trimmed : "\(current)\n\n\(trimmed)"
        isAgentPanelVisible = true
        agentComposerFocusRevision += 1
    }

    func addEditorSelectionToAgentConversation(_ selection: AgentEditorSelectionContext) {
        stageEditorSelection(selection, prefillQuestion: false)
    }

    func askAgentAboutEditorSelection(_ selection: AgentEditorSelectionContext) {
        stageEditorSelection(selection, prefillQuestion: true)
    }

    func removeAgentTextAttachment(id: AgentTextAttachment.ID) {
        agentPendingTextAttachments.removeAll { $0.id == id }
    }

    func prefillAgentJobInspectionPrompt(for job: AgentBackgroundJob) {
        let prompt = L10n.AgentJobs.inspectOutputPrompt(job.displayHandle)
        let trimmedInput = agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            agentInput = prompt
        } else if !agentInput.contains(job.displayHandle) {
            agentInput += "\n\n\(prompt)"
        }
        agentComposerFocusRevision += 1
    }

    private func stageEditorSelection(_ selection: AgentEditorSelectionContext, prefillQuestion: Bool) {
        let content = AgentTextAttachment.sanitizedPastedContent(selection.text)
        guard !content.isEmpty else { return }

        if activeRuntime == nil {
            _ = activeRuntimeAfterCreatingNewSession()
        }

        let attachment = AgentTextAttachment(
            filename: editorSelectionAttachmentFilename(selection),
            content: editorSelectionAttachmentContent(selection, content: content)
        )
        agentPendingTextAttachments.append(attachment)

        if prefillQuestion && agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            agentInput = L10n.AgentSelection.askPrompt
        }

        isAgentPanelVisible = true
        agentComposerFocusRevision += 1
    }

    private func editorSelectionAttachmentFilename(_ selection: AgentEditorSelectionContext) -> String {
        let filePart = openedFileURL?.lastPathComponent ?? L10n.AgentSelection.untitledFile
        let linePart = selection.startLine == selection.endLine
            ? "\(selection.startLine)"
            : "\(selection.startLine)-\(selection.endLine)"
        let raw = "\(L10n.AgentSelection.filenamePrefix) \(filePart) L\(linePart).txt"
        return raw
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
    }

    private func editorSelectionAttachmentContent(
        _ selection: AgentEditorSelectionContext,
        content: String
    ) -> String {
        let path = openedFileURL.map { relativePathForAgentSelection($0) } ?? L10n.AgentSelection.untitledFile
        let lineRange = selection.startLine == selection.endLine
            ? "\(selection.startLine)"
            : "\(selection.startLine)-\(selection.endLine)"
        return """
        Selection from active editor
        File: \(path)
        Lines: \(lineRange)
        Language: \(effectiveLanguage?.displayName ?? L10n.EditorStatusBar.plainText)

        \(content)
        """
    }

    private func relativePathForAgentSelection(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        guard let root = rootDirectory?.standardizedFileURL.path else {
            return standardized.path
        }
        let path = standardized.path
        guard path.hasPrefix(root) else { return standardized.path }
        let relative = String(path.dropFirst(root.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? standardized.lastPathComponent : relative
    }

    func toggleAgentWorkspaceOverview() {
        agentPendingIncludeWorkspaceOverview.toggle()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
