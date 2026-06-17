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
        guard runtime.messages.count > keepRecent else { return }

        runtime.isCompressingContext = true
        let configuration = configurationForContextCompression()
        let head = Array(runtime.messages.prefix(runtime.messages.count - keepRecent))
        let tail = Array(runtime.messages.suffix(keepRecent))

        Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.runContextCompression(
                for: runtime,
                head: head,
                tail: tail,
                configuration: configuration
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
        // Token estimate uses the runtime's own message list, not the
        // currently-displayed conversation; a background runtime can get
        // compressed while its session is not on screen.
        let collapsed = Self.collapseOldToolResults(in: runtime.messages)
        let used = Self.estimateAgentTokens(messages: collapsed, tools: AgentToolRegistry.all)
        let usedFraction = Double(used) / Double(window)
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
        configuration: AgentConfiguration
    ) async {
        defer {
            runtime.isCompressingContext = false
            persistAgentSession(runtime: runtime)
            // Auto-compression can be racing with a queued message; resume
            // the queue once compression resolves so the user doesn't see
            // "queued" forever.
            consumeNextQueuedMessageIfNeeded(for: runtime)
        }

        let transcript = head
            .filter { $0.role != .system }
            .map { message -> String in
                let label: String
                switch message.role {
                case .user: label = "USER"
                case .assistant: label = "ASSISTANT"
                case .tool: label = "TOOL(\(message.toolCallID ?? "?"))"
                case .system: label = "SYSTEM"
                case .workflowReport: label = "WORKFLOW(\(message.workflowReport?.workflowName ?? "?"))"
                }
                return "\(label):\n\(message.content)"
            }
            .joined(separator: "\n\n---\n\n")

        let system = AgentMessage(
            role: .system,
            content: """
            You compress a coding-agent conversation transcript into a tight summary.
            Goal: preserve enough state that the agent can continue without re-reading the old turns.
            Cover, in this order: the user's goal, key decisions, file paths examined or modified, important findings, and any open questions. Skip pleasantries and verbatim quotes. Keep under 300 words. Output plain text, no preamble like "Here's the summary".
            """
        )
        let payload = AgentMessage(
            role: .user,
            content: "Transcript to compress:\n\n\(transcript)"
        )

        let client = AgentClient(configuration: configuration)
        let collector = CompressionSummaryCollector()
        do {
            try await client.streamChat(messages: [system, payload]) { event in
                if case .textDelta(let delta) = event {
                    await collector.append(delta)
                }
            }
        } catch {
            runtime.errorMessage = "Context compression failed: \(error.localizedDescription)"
            runtime.errorDetails = Self.details(for: error)
            return
        }

        let trimmed = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            runtime.errorMessage = "Context compression returned an empty summary; nothing changed."
            runtime.errorDetails = nil
            return
        }

        let summaryMessage = AgentMessage(
            role: .assistant,
            content: "[Earlier conversation summary]\n\n\(trimmed)"
        )
        runtime.messages = [summaryMessage] + tail
        // Tool calls referencing pre-compression assistant messages no
        // longer have a valid messageID; drop them so they stop rendering.
        let liveMessageIDs = Set(runtime.messages.map(\.id))
        runtime.toolCalls.removeAll { !liveMessageIDs.contains($0.messageID) }
    }

    /// Replace the body of older `tool` role messages with a tiny
    /// placeholder so they stop dominating the request payload. The most
    /// recent `keepRecentToolMessages` tool messages are left untouched so
    /// the model can still reason about what it just did.
    nonisolated static func collapseOldToolResults(
        in messages: [AgentMessage],
        keepRecentToolMessages: Int = 4
    ) -> [AgentMessage] {
        let toolIndices = messages.enumerated().compactMap { offset, message in
            message.role == .tool ? offset : nil
        }
        guard toolIndices.count > keepRecentToolMessages else { return messages }
        let collapseUpTo = toolIndices[toolIndices.count - keepRecentToolMessages - 1]

        var copy = messages
        for index in 0...collapseUpTo where copy[index].role == .tool {
            let original = copy[index]
            if original.content.hasPrefix("[tool result hidden") { continue }
            let bytes = original.content.utf8.count
            let placeholder = "[tool result hidden — earlier turn, was \(bytes) bytes; ask the user or re-run the tool if you need it again]"
            copy[index] = AgentMessage(
                id: original.id,
                role: .tool,
                content: placeholder,
                images: original.images,
                toolCalls: original.toolCalls,
                toolCallID: original.toolCallID,
                createdAt: original.createdAt
            )
        }
        return copy
    }
}
