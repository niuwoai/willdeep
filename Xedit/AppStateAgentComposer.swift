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

        let userText = runtime.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = runtime.pendingImages
        let textAttachments = runtime.pendingTextAttachments
        let skills = runtime.pendingSkills
        let files = runtime.pendingFiles
        let includeWorkspaceOverview = runtime.pendingIncludeWorkspaceOverview
        let executionAgent = runtime.executionAgent
        guard !userText.isEmpty
                || !images.isEmpty
                || !textAttachments.isEmpty
                || !skills.isEmpty
                || !files.isEmpty
                || includeWorkspaceOverview else { return }

        let prompt = composeAttachedPrompt(
            userText: userText,
            skills: skills,
            files: files,
            includeWorkspaceOverview: includeWorkspaceOverview
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
                await Self.loadAgentWorktreeSnapshot(for: workspaceURL)
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
            let imageDescriptions: String
            do {
                let configuration = agentConfiguration.normalized.imageDescription.agentConfiguration
                imageDescriptions = try await describeImagesForTextOnlyProvider(
                    images,
                    configuration: configuration
                )
            } catch {
                imageDescriptions = "Image description failed: \(error.localizedDescription)"
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
            source: status == .succeeded ? .toolOutput : .systemNotice
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

    func composeAttachedPrompt(
        userText: String,
        skills: [AgentSkillEntry],
        files: [AgentFileAttachment],
        includeWorkspaceOverview: Bool
    ) -> String {
        guard !skills.isEmpty || !files.isEmpty || includeWorkspaceOverview else { return userText }
        var blocks: [String] = []
        blocks.append("The user attached the following context for this turn — treat it as task setup, not verbatim user text:")

        if includeWorkspaceOverview {
            blocks.append(workspaceOverviewBlock())
        }

        for skill in skills {
            let body = AgentSkillDirectory.loadBody(for: skill) ?? "(skill body unavailable)"
            blocks.append("""
            ### Skill: \(skill.identifier)
            > \(skill.description)

            \(body)
            """)
        }

        for file in files {
            let body = readAttachedFileBody(at: file.url)
            let renderedBody = AgentLocalAttachmentRetriever.renderAttachment(
                relativePath: file.relativePath,
                body: body,
                query: userText
            )
            blocks.append("""
            ### File: \(file.relativePath)

            \(renderedBody)
            """)
        }

        if !userText.isEmpty {
            blocks.append("---")
            blocks.append(userText)
        }
        return blocks.joined(separator: "\n\n")
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
        let standardized = url.standardizedFileURL
        guard !agentPendingFiles.contains(where: { $0.url.standardizedFileURL == standardized }) else { return }
        let relative: String = {
            guard let root = rootDirectory?.standardizedFileURL.path else { return standardized.lastPathComponent }
            let path = standardized.path
            guard path.hasPrefix(root) else { return standardized.lastPathComponent }
            let rel = String(path.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? standardized.lastPathComponent : rel
        }()
        agentPendingFiles.append(AgentFileAttachment(url: standardized, relativePath: relative))
    }

    func detachAgentFile(id: String) {
        agentPendingFiles.removeAll { $0.id == id }
    }

    func addAgentTextAttachment(content rawContent: String) {
        let content = AgentTextAttachment.sanitizedPastedContent(rawContent)
        guard !content.isEmpty else { return }
        agentPendingTextAttachments.append(
            AgentTextAttachment(filename: L10n.AgentTextAttachment.pastedFilename, content: content)
        )
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
