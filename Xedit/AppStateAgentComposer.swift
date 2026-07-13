//
//  AppStateAgentComposer.swift
//  WillDeep
//
//  Agent composer send path and staged context attachments.
//

import Foundation

extension AppState {
    func sendAgentMessage() {
        // The UI's send button always targets whatever session is on
        // screen — that's the active runtime by definition. If there
        // isn't one, lazily create one so a brand-new install can fire
        // off its first message without manually picking ⌘N first.
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        if refreshChangedAgentSessionDocumentsIfNeeded(in: runtime) {
            return
        }

        let userText = runtime.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = runtime.pendingImages.map { image in
            (try? image.diskBackedCopy()) ?? image
        }
        let textAttachments = runtime.pendingTextAttachments
        let skills = runtime.pendingSkills
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

        let prompt = composeAttachedPrompt(
            userText: userText,
            skills: skills,
            files: files,
            includeWorkspaceOverview: includeWorkspaceOverview,
            documentTaskMode: runtime.documentTaskMode,
            redactSensitiveContent: runtime.redactSensitiveAttachmentContent
        )

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
            }
            return
        }

        dispatchAgentMessageUsingSelectedExecutor(
            executionAgent,
            for: runtime,
            text: prompt,
            images: images,
            textAttachments: textAttachments,
            attachedSkills: skills
        )
    }

    func dispatchAgentMessageUsingSelectedExecutor(
        _ executionAgent: AgentExecutionAgent,
        for runtime: AgentRuntime,
        text: String,
        images: [AgentImageAttachment],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = []
    ) {
        switch executionAgent {
        case .willDeep:
            dispatchAgentMessage(
                for: runtime,
                text: text,
                images: images,
                textAttachments: textAttachments,
                attachedSkills: attachedSkills
            )
        case .claudeCode, .codexCLI:
            dispatchDelegatedAgentMessage(
                for: runtime,
                text: text,
                images: images,
                textAttachments: textAttachments,
                attachedSkills: attachedSkills,
                executionAgent: executionAgent
            )
        }
    }

    func dispatchDelegatedAgentMessage(
        for runtime: AgentRuntime,
        text: String,
        images: [AgentImageAttachment],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        executionAgent: AgentExecutionAgent
    ) {
        guard let toolName = executionAgent.toolName else {
            dispatchAgentMessage(
                for: runtime,
                text: text,
                images: images,
                textAttachments: textAttachments,
                attachedSkills: attachedSkills
            )
            return
        }

        resolvePendingAgentPatchProposalsBeforeNewMessage(for: runtime)

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

        let prompt = delegatedAgentPrompt(
            userText: text,
            conversationMessages: runtime.messages,
            textAttachments: textAttachments,
            images: images,
            imageDescriptions: nil,
            executionAgent: executionAgent,
            workspaceLocation: runtime.workspaceLocation ?? runtime.workspaceRootPath.map { .local(path: $0) }
        )
        let arguments = Self.delegatedAgentArguments(prompt: prompt, executionAgent: executionAgent)
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
                userText: text,
                textAttachments: textAttachments,
                images: images,
                executionAgent: executionAgent,
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
        let baselineTask = workspaceURL.map { workspaceURL in
            Task.detached(priority: .utility) {
                await Self.loadAgentWorktreeSnapshot(
                    for: workspaceURL,
                    captureArtifactFiles: true
                )
            }
        }

        defer {
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
                executionAgent: executionAgent,
                workspaceLocation: workspaceLocation
            )
            arguments["prompt"] = .string(prompt)
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

        if risk != .read && runtime.isPlanGateActive {
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                executionAgent: executionAgent,
                status: .denied,
                result: nil,
                errorMessage: "Plan mode: needs user approval",
                toolPayload: "Blocked: Plan mode is active and no plan has been approved yet."
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
            if Task.isCancelled { return }
            if case .denied(let reason) = decision {
                AgentSandboxAuditLog.append(
                    toolName: toolName,
                    arguments: arguments,
                    decision: sandboxDecision,
                    approvalSource: nil,
                    outcome: "denied"
                )
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
                approvalSource: approvalSource,
                sandboxDecision: sandboxDecision
            )
        )

        do {
            let result = try await AgentToolRunner.run(
                name: toolName,
                arguments: arguments,
                context: context
            )
            AgentSandboxAuditLog.append(
                toolName: toolName,
                arguments: arguments,
                decision: sandboxDecision,
                approvalSource: approvalSource,
                outcome: "succeeded"
            )
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                executionAgent: executionAgent,
                status: .succeeded,
                result: result,
                errorMessage: nil,
                toolPayload: result.payload
            )
            refreshDelegatedAgentWorktreeInBackground(
                runtimeID: runtime.id,
                workspaceURL: workspaceURL,
                baselineTask: baselineTask
            )
        } catch is CancellationError {
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
        guard command.contains("WillDeep Delegated Executor Context Package v1") else {
            return nil
        }
        if command.contains("selected execution agent: \(AgentExecutionAgent.codexCLI.displayName)") {
            return .codexCLI
        }
        if command.contains("selected execution agent: \(AgentExecutionAgent.claudeCode.displayName)") {
            return .claudeCode
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
        executionAgent: AgentExecutionAgent,
        workspaceLocation: WorkspaceLocation?
    ) -> String {
        var blocks: [String] = [
            """
            WillDeep Delegated Executor Context Package v1

            You are being invoked from WillDeep Composer as the selected execution agent: \(executionAgent.displayName).
            Work on the user's task end-to-end in the current workspace. If you change files, run the most relevant verification you can and summarize what changed.
            Keep raw logs, long command output, and implementation scratch notes outside the final response block. WillDeep keeps the full tool output separately; the main conversation should only receive a compact user-facing answer.

            At the end of your stdout, emit exactly one final response block by writing `WILLDEEP_FINAL_RESPONSE_BEGIN`, then your concise user-facing answer, then `WILLDEEP_FINAL_RESPONSE_END`. Do not copy placeholder text.
            """
        ]
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
            } else {
                blocks.append("WillDeep is preparing descriptions for \(images.count) image attachment(s) before this delegated CLI task runs.")
            }
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
        executionAgent: AgentExecutionAgent
    ) -> [String: AgentJSONValue] {
        var arguments: [String: AgentJSONValue] = [
            "prompt": .string(prompt),
            "run_in_background": .bool(true),
        ]
        if let permissionMode = executionAgent.defaultPermissionMode {
            arguments["permission_mode"] = .string(permissionMode)
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
        redactSensitiveContent: Bool = true
    ) -> String {
        guard !skills.isEmpty || !files.isEmpty || includeWorkspaceOverview else { return userText }
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
        guard !agentPendingSkills.contains(where: { $0.identifier == skill.identifier }) else { return }
        agentPendingSkills.append(skill)
    }

    func detachAgentSkill(identifier: String) {
        agentPendingSkills.removeAll { $0.identifier == identifier }
    }

    func attachAgentFile(url: URL) {
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
            if existing.parseStatus == .ready,
               existing.sourceFileSize == metadata.size,
               existing.sourceModifiedAt == metadata.modifiedAt {
                runtime.documentAttachments[existingIndex] = existing
                runtime.pendingFiles.append(existing)
                runtime.persist(touchUpdatedAt: false)
                return
            }
        }

        var attachment = AgentFileAttachment(url: standardized, relativePath: relative)
        attachment.sourceFileSize = metadata.size
        attachment.sourceModifiedAt = metadata.modifiedAt
        runtime.pendingFiles.append(attachment)
        runtime.documentAttachments.removeAll { $0.id == attachment.id }
        runtime.documentAttachments.append(attachment)
        runtime.persist(touchUpdatedAt: false)
        analyzeAgentFileAttachment(id: attachment.id, url: standardized, for: runtime)
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
        files[index].excludedSectionIDs = included ? [] : Set(analysis.sections.map(\.id))
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
        let excluded = included ? Set<String>() : Set(analysis.sections.map(\.id))
        runtime.documentAttachments[index].excludedSectionIDs = excluded
        if let pendingIndex = runtime.pendingFiles.firstIndex(where: { $0.id == fileID }) {
            runtime.pendingFiles[pendingIndex].excludedSectionIDs = excluded
        }
        runtime.persist(touchUpdatedAt: false)
    }

    private func analyzeAgentFileAttachment(id: String, url: URL, for runtime: AgentRuntime) {
        Task { [weak runtime] in
            do {
                let analysis = try await AgentDocumentAttachmentParser.analyze(url: url)
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
            analyzeAgentFileAttachment(id: file.id, url: file.url, for: runtime)
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
