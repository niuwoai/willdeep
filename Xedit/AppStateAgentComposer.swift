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

        rejectPendingAgentPatchProposals(
            for: runtime,
            statusMessage: "Superseded by a newer message."
        )

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
            textAttachments: textAttachments,
            images: images,
            imageDescriptions: nil,
            executionAgent: executionAgent,
            workspaceLocation: runtime.workspaceLocation ?? runtime.workspaceRootPath.map { .local(path: $0) }
        )
        let arguments = delegatedAgentArguments(prompt: prompt, executionAgent: executionAgent)
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
        let workspaceURL = workspaceLocation?.localPath.map { URL(fileURLWithPath: $0) }
        let remoteRuntimeDescriptor: RuntimeDescriptor? = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let baseline = await Self.loadAgentWorktreeSnapshot(for: workspaceURL)

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
            runtime.toolCalls[index].status = .pendingApproval
        }
        AgentToolApprovalNotifier.notifyIfBackgrounded(
            toolName: toolName,
            arguments: arguments,
            status: .pendingApproval
        )

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
        let autoApproval = await autoApprovalSource(
            toolName: toolName,
            arguments: arguments,
            risk: risk,
            rootDirectory: workspaceURL,
            interactionMode: runtime.interactionMode,
            approvalMode: runtime.approvalMode
        )

        if risk != .read && runtime.isPlanGateActive {
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                status: .denied,
                result: nil,
                errorMessage: "Plan mode: needs user approval",
                toolPayload: "Blocked: Plan mode is active and no plan has been approved yet."
            )
            return
        }

        if risk != .read && autoApproval == nil {
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
            await refreshGitStatusAfterAgentTool(
                for: runtime,
                workspaceURL: workspaceURL,
                baselineFingerprint: baseline.fingerprint
            )
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                status: .succeeded,
                result: result,
                errorMessage: nil,
                toolPayload: result.payload
            )
        } catch is CancellationError {
            finishDelegatedAgentRecord(
                runtime: runtime,
                recordID: recordID,
                externalID: externalID,
                status: .failed,
                result: nil,
                errorMessage: "Cancelled",
                toolPayload: "Delegated agent cancelled."
            )
        } catch {
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
                status: .failed,
                result: nil,
                errorMessage: error.localizedDescription,
                toolPayload: "Tool error: \(error.localizedDescription)"
            )
        }
    }

    private func finishDelegatedAgentRecord(
        runtime: AgentRuntime,
        recordID: AgentToolCall.ID,
        externalID: String,
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
    }

    private func delegatedAgentPrompt(
        userText: String,
        textAttachments: [AgentTextAttachment],
        images: [AgentImageAttachment],
        imageDescriptions: String?,
        executionAgent: AgentExecutionAgent,
        workspaceLocation: WorkspaceLocation?
    ) -> String {
        var blocks: [String] = [
            "You are being invoked from WillDeep Composer as the selected execution agent: \(executionAgent.displayName).",
            "Work on the user's task end-to-end in the current workspace. If you change files, run the most relevant verification you can and summarize what changed.",
        ]
        if let path = workspaceLocation?.path, !path.isEmpty {
            blocks.append("Workspace: \(path)")
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
        blocks.append("---")
        blocks.append(userText)
        return blocks.joined(separator: "\n\n")
    }

    private func delegatedAgentArguments(
        prompt: String,
        executionAgent: AgentExecutionAgent
    ) -> [String: AgentJSONValue] {
        var arguments: [String: AgentJSONValue] = [
            "prompt": .string(prompt),
            "run_in_background": .bool(true),
            "timeout_seconds": .number(1800),
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
            blocks.append("""
            ### File: \(file.relativePath)

            \(body)
            """)
        }

        if !userText.isEmpty {
            blocks.append("---")
            blocks.append(userText)
        }
        return blocks.joined(separator: "\n\n")
    }

    func readAttachedFileBody(at url: URL) -> String {
        let maxChars = 20_000
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
