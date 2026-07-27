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
                workspaceLocation: workspaceLocation,
                onProgress: { round, toolInvocations in
                    let toolPart = toolInvocations > 0 ? " · \(toolInvocations) 次工具" : ""
                    updateSubagent(progress: "第 \(round)/\(AgentSubagentRunner.maxRounds) 轮\(toolPart)")
                }
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

    func attachRecentGeneratedToolImages(to assistantID: UUID, in runtime: AgentRuntime) {
        guard let assistantIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        let images = recentGeneratedToolImages(before: assistantIndex, in: runtime.messages)
        guard !images.isEmpty else { return }
        let existingIDs = Set(runtime.messages[assistantIndex].images.map(\.id))
        let newImages = images.filter { !existingIDs.contains($0.id) }
        guard !newImages.isEmpty else { return }
        runtime.messages[assistantIndex].images.append(contentsOf: newImages)
    }

    private func recentGeneratedToolImages(
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
                let generated = message.images.filter { $0.source == .generated }
                if !generated.isEmpty {
                    grouped.append(generated)
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
