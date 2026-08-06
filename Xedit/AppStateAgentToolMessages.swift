//
//  AppStateAgentToolMessages.swift
//  WillDeep
//
//  Subagent tool execution and tool-message persistence helpers extracted
//  from AppStateAgentLoop.swift so the streaming loop stays below the
//  repository's hard file-size limit.
//

import Foundation

extension AppState {
    func denyPlanProgressReconciliationToolCall(
        _ call: AgentMessageToolCall,
        messageID: UUID,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        runtime: AgentRuntime
    ) {
        let errorMessage = "Unavailable during Plan status reconciliation"
        let record = AgentToolCall(
            messageID: messageID,
            externalID: call.externalID,
            toolName: call.toolName,
            arguments: arguments,
            risk: risk,
            status: .denied,
            errorMessage: errorMessage
        )
        runtime.toolCalls.append(record)
        appendToolMessage(
            for: runtime,
            toolCallID: call.externalID,
            payload: "Blocked: Plan status reconciliation permits only read-only inspection. Use existing evidence or read-only status tools, then emit the required progress block without repeating execution.",
            source: .systemNotice,
            outcomeStatus: .denied,
            errorMessage: errorMessage
        )
    }

    /// Record whether a `/subagent` turn actually delegated.
    ///
    /// `.required` cannot be enforced in code (see `AgentDelegationPolicy`),
    /// so instead of silently pretending the directive held, the turn's user
    /// message keeps an honest verdict that the transcript marker renders.
    /// `.forbidden` needs no audit — the tool table already guaranteed it.
    func auditDelegationPolicyForFinishedTurn(in runtime: AgentRuntime) {
        let policy = runtime.currentTurnDelegationPolicy
        runtime.currentTurnDelegationPolicy = .automatic
        guard policy == .required else { return }
        guard let index = runtime.messages.lastIndex(where: {
            $0.role == .user && $0.delegationPolicy == .required
        }) else { return }

        let unhonored = !policy.isHonored(spawnCallCount: runtime.currentTurnSpawnAgentCallCount)
        guard runtime.messages[index].delegationPolicyUnhonored != unhonored else { return }
        runtime.messages[index].delegationPolicyUnhonored = unhonored
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
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
        // Counted before any validation: a `/subagent` turn that tried to
        // delegate and failed still honored the directive.
        runtime.currentTurnSpawnAgentCallCount += 1

        func finishRecord(status: AgentToolCallStatus, summary: String, payload: String, errorMessage: String? = nil) {
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                runtime.toolCalls[index].status = status
                runtime.toolCalls[index].errorMessage = errorMessage
                runtime.toolCalls[index].subagentProgress = nil
                if status == .succeeded {
                    runtime.toolCalls[index].result = AgentToolResult(summary: summary, payload: payload)
                }
            }
            appendToolMessage(
                for: runtime,
                toolCallID: call.externalID,
                payload: payload,
                source: status == .succeeded ? .toolOutput : .systemNotice,
                outcomeStatus: status,
                errorMessage: errorMessage
            )
        }

        // Stamp the child's effective model + a live progress line onto the
        // tool-call record so the card can show "用的哪个子代理 · 进度到哪了"
        // instead of an opaque spinner. Both fields are render-only.
        func updateSubagent(model: String? = nil, progress: String? = nil) {
            guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else { return }
            if let model { runtime.toolCalls[index].subagentModel = model }
            if let progress { runtime.toolCalls[index].subagentProgress = progress }
        }

        // Bind the run to both the live card and the persisted assistant
        // message: the former drives the inspector button this session, the
        // latter is what survives a reopen.
        func bindSubagentRun(_ runID: UUID) {
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                runtime.toolCalls[index].subagentRunID = runID
            }
            bindSubagentRunToPersistedToolCall(
                runID: runID,
                externalID: call.externalID,
                runtime: runtime
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
        updateSubagent(model: childConfiguration.model, progress: "启动中…")

        if runInBackground {
            do {
                let run = try agentSubagentRegistry.startBackground(
                    prompt: prompt,
                    label: label,
                    configuration: childConfiguration,
                    workspaceURL: workspaceURL,
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation,
                    parentRuntimeID: runtime.id,
                    originatingTurnID: runtime.activeTurnID
                )
                bindSubagentRun(run.id)
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

        // Synchronous runs bypass the registry, so mint the inspector
        // identity here — without it this run would finish with a report and
        // no reviewable record, which is the gap the inspector exists to fix.
        let runID = UUID()
        let startedAt = Date()
        bindSubagentRun(runID)

        func persist(status: AgentSubagentRun.Status, outcome: AgentSubagentRunner.Outcome?, report: String) {
            AppState.persistSubagentTranscript(
                AgentSubagentTranscript(
                    runID: runID,
                    label: label,
                    prompt: AgentSubagentTranscript.clamped(
                        prompt,
                        to: AgentSubagentTranscript.Limits.promptCharacters
                    ).text,
                    model: childConfiguration.model,
                    status: status,
                    rounds: outcome?.rounds ?? [],
                    report: AgentSubagentTranscript.clamped(
                        report,
                        to: AgentSubagentTranscript.Limits.reportCharacters
                    ).text,
                    usageTokens: outcome?.usageTokens ?? 0,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    didTruncate: outcome?.didTruncate ?? false
                )
            )
        }

        do {
            let outcome = try await AgentSubagentRunner.run(
                prompt: prompt,
                configuration: childConfiguration,
                workspaceURL: workspaceURL,
                runtimeDescriptor: runtimeDescriptor,
                workspaceLocation: workspaceLocation,
                onProgress: { round, toolInvocations in
                    let toolPart = toolInvocations > 0 ? " · \(toolInvocations) 次工具" : ""
                    updateSubagent(progress: "第 \(round)/\(AgentSubagentRunner.maxRounds) 轮\(toolPart)")
                }
            )
            let stats = "(subagent \(label): \(outcome.roundCount) round\(outcome.roundCount == 1 ? "" : "s"), \(outcome.toolInvocationCount) tool call\(outcome.toolInvocationCount == 1 ? "" : "s")\(outcome.usageTokens > 0 ? ", \(outcome.usageTokens) tokens" : ""))"
            persist(status: .completed, outcome: outcome, report: outcome.report)
            finishRecord(
                status: .succeeded,
                summary: stats,
                payload: "\(outcome.report)\n\n\(stats)"
            )
        } catch is CancellationError {
            // No outcome to record, but the prompt/model/timing still explain
            // what was cancelled — better than an inspector button that opens
            // onto nothing.
            persist(status: .cancelled, outcome: nil, report: "(subagent cancelled)")
            finishRecord(
                status: .failed,
                summary: "cancelled",
                payload: "Subagent cancelled.",
                errorMessage: "Cancelled"
            )
        } catch {
            persist(status: .failed, outcome: nil, report: "Subagent failed: \(error.localizedDescription)")
            finishRecord(
                status: .failed,
                summary: "subagent failed",
                payload: "Tool error: \(error.localizedDescription)",
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Copy the run id onto the persisted assistant tool call so reopening
    /// the session still resolves the inspector record. `runtime.toolCalls`
    /// is render-only state and does not survive a restart.
    func bindSubagentRunToPersistedToolCall(
        runID: UUID,
        externalID: String,
        runtime: AgentRuntime
    ) {
        guard let messageIndex = runtime.messages.lastIndex(where: { message in
            message.toolCalls.contains { $0.externalID == externalID }
        }) else { return }
        guard let callIndex = runtime.messages[messageIndex].toolCalls
            .firstIndex(where: { $0.externalID == externalID }) else { return }
        runtime.messages[messageIndex].toolCalls[callIndex].subagentRunID = runID
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    /// Writes off the main actor: a long child loop's record can run to
    /// hundreds of KB, and this is autosave-adjacent work the UI must not
    /// wait on.
    nonisolated static func persistSubagentTranscript(_ transcript: AgentSubagentTranscript) {
        Task.detached(priority: .utility) {
            AgentSubagentTranscriptStore.save(transcript)
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
        images: [AgentImageAttachment] = [],
        source: AgentInjectionDefense.ToolMessageSource = .toolOutput,
        outcomeStatus: AgentToolCallStatus? = nil,
        errorMessage: String? = nil
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
        // Images ride on the tool message so vision-capable providers
        // re-see them every turn (Anthropic re-attaches as tool_result
        // image blocks). Text-only providers ignore `images` and use the
        // sanitized text payload.
        runtime.messages.append(
            AgentMessage(
                role: .tool,
                content: limited,
                images: images,
                toolCallID: toolCallID,
                toolCallStatus: outcomeStatus,
                toolErrorMessage: errorMessage
            )
        )
    }

    func attachRecentVisibleToolImages(to assistantID: UUID, in runtime: AgentRuntime) {
        guard let assistantIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        let images = recentVisibleToolImages(before: assistantIndex, in: runtime.messages)
        guard !images.isEmpty else { return }
        let existingIDs = Set(runtime.messages[assistantIndex].images.map(\.id))
        let newImages = images.filter { !existingIDs.contains($0.id) }
        guard !newImages.isEmpty else { return }
        runtime.messages[assistantIndex].images.append(contentsOf: newImages)
    }

    private func recentVisibleToolImages(
        before assistantIndex: Int,
        in messages: [AgentMessage]
    ) -> [AgentImageAttachment] {
        guard assistantIndex > 0 else { return [] }
        var grouped: [[AgentImageAttachment]] = []
        var index = assistantIndex - 1
        while index >= 0 {
            let message = messages[index]
            if message.role == .assistant {
                break
            }
            if message.role == .tool {
                let visible = message.images.filter {
                    $0.source == .generated || $0.source == .capture
                }
                if !visible.isEmpty {
                    grouped.append(visible)
                }
            }
            index -= 1
        }
        return grouped.reversed().flatMap { $0 }
    }

    func diagnoseLocalWorkspaceIfNeeded(
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

    func terminalShortcutResultRequiresChatPasswordCard(_ result: AgentToolResult) -> Bool {
        guard let data = result.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if object["has_pending_protected_input"] as? Bool == true {
            return true
        }
        if let pendingCount = object["pending_protected_input_count"] as? Int,
           pendingCount > 0 {
            return true
        }
        return false
    }
}
