//
//  AppStateAgentContextCompression.swift
//  WillDeep
//
//  Owns Agent conversation compression and token-budget predicates. Split
//  from AppStateAgentLoop.swift so the streaming loop stays focused on turn
//  orchestration.
//

import Foundation

extension AppState {
    /// True while context compression is running for the active session.
    /// Delegated to `activeRuntime.isCompressingContext`.
    var isCompressingAgentContext: Bool {
        get { activeRuntime?.isCompressingContext ?? false }
        set { activeRuntime?.isCompressingContext = newValue }
    }

    /// Summarize older conversation history into a single assistant
    /// message to reclaim context budget. Keeps the most recent
    /// `keepRecent` messages verbatim. Runs concurrently with whatever
    /// the user is doing (Send still works once compression resolves).
    func compressAgentContext(keepRecent: Int = 4) {
        guard let runtime = activeRuntime else { return }
        compressAgentContext(for: runtime, keepRecent: keepRecent)
    }

    func compressAgentContext(for runtime: AgentRuntime, keepRecent: Int = 4) {
        guard !runtime.isCompressingContext, !runtime.isResponding else { return }
        guard runtime.messages.count > 1 else { return }

        // 第二次手动按 Compress 时,往往是因为上次 keepRecent=4 留下
        // 的尾部里有 skill prelude / 长 tool result 等大块内容,光靠
        // 头部摘要看不出来效果。再压时把尾部缩到 2,并把已有摘要
        // 一起折进新 head,这样可压面就最大化。
        let hasPriorSummary = (runtime.contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            && runtime.contextSummaryThroughMessageID != nil
        let effectiveKeepRecent = hasPriorSummary ? min(2, keepRecent) : keepRecent
        guard runtime.messages.count > effectiveKeepRecent else { return }

        runtime.isCompressingContext = true
        let configurations = contextCompressionConfigurationCandidates()
        let head = Array(runtime.messages.prefix(runtime.messages.count - effectiveKeepRecent))
        let tail = Array(runtime.messages.suffix(effectiveKeepRecent))
        let priorSummary = hasPriorSummary ? runtime.contextSummary : nil

        Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.runContextCompression(
                for: runtime,
                head: head,
                tail: tail,
                priorSummary: priorSummary,
                configurations: configurations
            )
        }
    }

    /// Pure predicate: true if `maybeAutoCompressContext` would launch a
    /// compression right now for the active runtime. Exposed mainly for
    /// tests; the production caller is `maybeAutoCompressContext` itself.
    var shouldAutoCompressNow: Bool {
        guard let runtime = activeRuntime else { return false }
        return shouldAutoCompressNow(for: runtime)
    }

    func shouldAutoCompressNow(for runtime: AgentRuntime) -> Bool {
        guard !runtime.isCompressingContext, !runtime.isResponding else { return false }
        guard runtime.messages.count > 6 else { return false }
        let window = max(1, agentContextWindow)
        // Estimate the model-facing window, not the local transcript. Once a
        // summary exists, the user can still see every old message locally
        // while the provider request sees only the summary + newer tail.
        let history = Self.modelFacingHistory(
            messages: runtime.messages,
            contextSummary: runtime.contextSummary,
            contextSummaryThroughMessageID: runtime.contextSummaryThroughMessageID
        )
        let collapsed = Self.collapseOldToolResults(in: history)
        let used = Self.estimateAgentTokens(messages: collapsed, tools: AgentToolRegistry.all)
        let fixedToolOverhead = Self.estimateAgentTokens(messages: [], tools: AgentToolRegistry.all)
        let compressibleUsed = max(0, used - fixedToolOverhead)
        let usedFraction = Double(compressibleUsed) / Double(window)
        return usedFraction > 0.75
    }

    /// Auto-compress when token usage crosses 75% and nothing else is in
    /// flight. Invoked from `runAgentLoop`'s defer so it runs between
    /// turns and never interrupts a streaming response.
    func maybeAutoCompressContext() {
        guard let runtime = activeRuntime else { return }
        maybeAutoCompressContext(for: runtime)
    }

    func maybeAutoCompressContext(for runtime: AgentRuntime) {
        guard shouldAutoCompressNow(for: runtime) else { return }
        compressAgentContext(for: runtime)
    }

    @MainActor
    func runContextCompression(
        for runtime: AgentRuntime,
        head: [AgentMessage],
        tail: [AgentMessage],
        priorSummary: String? = nil,
        configurations: [AgentConfiguration]
    ) async {
        defer {
            runtime.isCompressingContext = false
            persistAgentSession(runtime: runtime)
            // Auto-compression can be racing with a queued message; resume
            // the queue once compression resolves so the user doesn't see
            // "queued" forever.
            consumeNextQueuedMessageIfNeeded(for: runtime)
            // A background job/media task/subagent finishing while
            // `isCompressingContext` was set had its auto-resume guarded
            // off — and auto-compression runs in the turn's defer BEFORE
            // that defer's own resume attempt, so this is a common window,
            // not an edge case. Re-kick now that compression resolved (a
            // no-op if the queued-message consume above claimed the
            // runtime; that turn drains completions itself).
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }

        let transcriptBody = head
            .filter { $0.role != .system }
            .map { message -> String in
                let label: String
                switch message.role {
                case .user: label = "USER"
                case .assistant: label = "ASSISTANT"
                case .tool: label = "TOOL(\(message.toolCallID ?? "?"))"
                case .system: label = "SYSTEM"
                case .workflowReport: label = "WORKFLOW(\(message.workflowReport?.workflowName ?? "?"))"
                case .widget: label = "WIDGET(\(message.widget?.title ?? "?"))"
                case .scheduledTask: label = "SCHEDULED_TASK(\(message.scheduledTask?.title ?? "?"))"
                }
                return "\(label):\n\(message.content)"
            }
            .joined(separator: "\n\n---\n\n")
        let transcript: String = {
            guard let prior = priorSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prior.isEmpty else {
                return transcriptBody
            }
            return """
            EARLIER SUMMARY (from prior compression — fold into the new summary, don't drop):
            \(prior)

            ---

            \(transcriptBody)
            """
        }()

        let system = AgentMessage(
            role: .system,
            content: """
            You compress a coding-agent conversation transcript into a tight summary.
            Goal: preserve enough state that the agent can continue without re-reading the old turns.
            Output exactly these sections in this order, omitting bullets that do not apply:

            User goal:
            - ...

            Decisions and constraints:
            - ...

            Files and commands:
            - ...

            Current state:
            - ...

            Open questions / next steps:
            - ...

            Skip pleasantries and verbatim quotes. Keep under 300 words. Output plain text only.
            """
        )
        let payload = AgentMessage(
            role: .user,
            content: "Transcript to compress:\n\n\(transcript)"
        )

        var lastError: Error?
        for configuration in configurations {
            let client = AgentClient(configuration: configuration)
            let collector = CompressionSummaryCollector()
            let messages = AgentLocalModelPrompting.messagesWithLanguageInstruction(
                systemPrompt: system.content,
                userMessages: [payload],
                configuration: configuration
            )
            do {
                try await client.streamChat(messages: messages) { event in
                    if case .textDelta(let delta) = event {
                        await collector.append(delta)
                    }
                }
                let trimmed = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    lastError = AgentClientError.serverStatus(
                        AgentProviderHTTPError(
                            statusCode: 502,
                            method: "POST",
                            url: configuration.baseURL,
                            providerID: configuration.providerID,
                            model: configuration.model,
                            requestSummary: "Context compression returned an empty summary.",
                            requestBody: "(streamed request)",
                            responseBody: "(empty)"
                        )
                    )
                    continue
                }
                runtime.contextSummary = trimmed
                runtime.contextSummaryThroughMessageID = head.last?.id
                return
            } catch {
                lastError = error
                continue
            }
        }

        if let lastError {
            runtime.errorMessage = "Context compression failed: \(lastError.localizedDescription)"
            runtime.errorDetails = Self.details(for: lastError)
        } else {
            runtime.errorMessage = "Context compression failed: no usable summary provider is configured."
            runtime.errorDetails = nil
        }
    }

    /// Returns the transcript slice that should be sent to the model. Local
    /// `messages` remain complete; compression only swaps the already-covered
    /// prefix for a synthetic system summary in the request payload.
    nonisolated static func modelFacingHistory(
        messages: [AgentMessage],
        contextSummary: String?,
        contextSummaryThroughMessageID: AgentMessage.ID?,
        excludingMessageID: AgentMessage.ID? = nil
    ) -> [AgentMessage] {
        let visible = messages.filter { $0.id != excludingMessageID }
        guard let summary = contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty,
              let throughID = contextSummaryThroughMessageID,
              let markerIndex = visible.firstIndex(where: { $0.id == throughID }) else {
            return visible
        }

        let summaryMessage = AgentMessage(
            role: .system,
            content: "Earlier conversation summary for context only; the local transcript is preserved in full.\n\n\(summary)"
        )
        return [summaryMessage] + Array(visible.dropFirst(markerIndex + 1))
    }

    /// Replace model-facing `tool` message bodies with compact summaries
    /// while preserving the persisted transcript/tool-card payloads. Short
    /// results remain verbatim; long current-turn results keep head/tail
    /// snippets and metadata; older long results collapse to tiny stable
    /// placeholders. This keeps provider prompts small and more cacheable
    /// without breaking assistant→tool_call_id pairing.
    nonisolated static func collapseOldToolResults(
        in messages: [AgentMessage],
        keepRecentToolMessages: Int = 2
    ) -> [AgentMessage] {
        let latestUserIndex = messages.lastIndex { $0.role == .user } ?? messages.count
        let toolNameByExternalID = toolNameLookup(in: messages)
        let olderToolIndices = messages.enumerated().compactMap { offset, message in
            message.role == .tool && offset < latestUserIndex ? offset : nil
        }
        let collapsedOlderToolIndices = olderToolIndices.count > keepRecentToolMessages
            ? Set(olderToolIndices.prefix(olderToolIndices.count - keepRecentToolMessages))
            : Set<Int>()

        var copy = messages
        for index in copy.indices where copy[index].role == .tool {
            let original = copy[index]
            let isOlderCollapsed = collapsedOlderToolIndices.contains(index)
            let isBeforeLatestUser = index < latestUserIndex
            let toolName = original.toolCallID.flatMap { toolNameByExternalID[$0] }
            let nextContent = modelFacingToolResultContent(
                original.content,
                toolName: toolName,
                aggressivelyCollapse: isOlderCollapsed,
                preferCompactSummary: isBeforeLatestUser
            )
            guard nextContent != original.content else { continue }
            copy[index] = AgentMessage(
                id: original.id,
                role: .tool,
                content: nextContent,
                reasoningContent: original.reasoningContent,
                images: original.images,
                textAttachments: original.textAttachments,
                toolCalls: original.toolCalls,
                toolCallID: original.toolCallID,
                usageTokens: original.usageTokens,
                promptTokens: original.promptTokens,
                completionTokens: original.completionTokens,
                cachedPromptTokens: original.cachedPromptTokens,
                cacheWritePromptTokens: original.cacheWritePromptTokens,
                reasoningTokens: original.reasoningTokens,
                elapsedSeconds: original.elapsedSeconds,
                origin: original.origin,
                originLabel: original.originLabel,
                requestPrefixHash: original.requestPrefixHash,
                requestStablePrefixCharacters: original.requestStablePrefixCharacters,
                createdAt: original.createdAt
            )
        }
        return copy
    }

    nonisolated private static func toolNameLookup(in messages: [AgentMessage]) -> [String: String] {
        var lookup: [String: String] = [:]
        for message in messages where message.role == .assistant {
            for call in message.toolCalls {
                lookup[call.externalID] = call.toolName
            }
        }
        return lookup
    }

    nonisolated static func modelFacingToolResultContent(
        _ content: String,
        toolName: String?,
        aggressivelyCollapse: Bool = false,
        preferCompactSummary: Bool = false
    ) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return content }

        let bytes = trimmed.utf8.count
        if aggressivelyCollapse {
            return "[tool result summarized for model context — tool=\(toolName ?? "unknown"), original_bytes=\(bytes), earlier_turn=true]"
        }

        let verbatimLimit = preferCompactSummary ? 1_200 : 2_400
        guard trimmed.count > verbatimLimit else { return content }

        let snippetLimit = preferCompactSummary ? 700 : 1_800
        let head = String(trimmed.prefix(snippetLimit))
        let tail: String = {
            guard trimmed.count > snippetLimit * 2 else { return "" }
            return String(trimmed.suffix(snippetLimit))
        }()
        var lines = [
            "[tool result summarized for model context]",
            "tool: \(toolName ?? "unknown")",
            "original_bytes: \(bytes)",
            "summary_policy: \(preferCompactSummary ? "older-turn compact" : "current-turn head-tail")",
            "",
            "head:",
            head
        ]
        if !tail.isEmpty {
            lines.append("")
            lines.append("tail:")
            lines.append(tail)
        }
        lines.append("")
        lines.append("[Full tool output remains available in the transcript/tool result; re-run or fetch targeted details if needed.]")
        return lines.joined(separator: "\n")
    }
}
