//
//  AppStateAgentLoop.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Owns the heavy Agent-mode runtime path:
//
//    - dispatchAgentMessage + per-provider concurrency gate
//    - prepareImagesForTextOnlyProvider / describe helpers
//    - configurationForCurrentTurn / forContextCompression
//    - consumeNextQueuedMessageIfNeeded / clearAgentConversation
//    - tool-call approve / deny / always-allow / confirm / answer
//    - awaitToolDecision continuation + appendToolMessage
//    - runAgentLoop async streaming loop, setAgentError, retry,
//      dismissAgentError, stopAgentResponse, clearAgentQueue helpers
//    - context compression: estimatedAgentTokens / contextWindow /
//      shouldAutoCompressNow / maybeAutoCompressContext /
//      runContextCompression / collapseOldToolResults
//    - patch proposal accept / reject / capture / apply
//
//  Lives on AppState via extension so call sites in the chat UI and
//  routine scheduler keep writing appState.sendAgentMessage(),
//  appState.runAgentRoutineNow() etc. unchanged. A few private fields
//  on AppState were dropped to internal so this extension can touch
//  them (agentToolDecisionWaiter, agentRequestTask, isApplyingTabSnapshot,
//  knownModificationDates); none of them are visible outside the Xedit
//  target.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
private final class AgentStreamingMessageBuffer {
    private static let flushIntervalNanoseconds: UInt64 = 50_000_000
    private static let immediateFlushCharacterCount = 1_200

    private weak var runtime: AgentRuntime?
    private let assistantID: AgentMessage.ID
    private var pendingContent = ""
    private var pendingReasoning = ""
    private var flushTask: Task<Void, Never>?

    init(runtime: AgentRuntime, assistantID: AgentMessage.ID) {
        self.runtime = runtime
        self.assistantID = assistantID
    }

    func appendTextDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        pendingContent += delta
        scheduleFlush()
        flushIfNeeded()
    }

    func appendReasoningDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        pendingReasoning += delta
        scheduleFlush()
        flushIfNeeded()
    }

    func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        applyPendingDeltas()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushIntervalNanoseconds)
            guard let self else { return }
            self.flushTask = nil
            self.applyPendingDeltas()
        }
    }

    private func flushIfNeeded() {
        guard pendingContent.count + pendingReasoning.count >= Self.immediateFlushCharacterCount else {
            return
        }
        flushPending()
    }

    private func applyPendingDeltas() {
        guard !pendingContent.isEmpty || !pendingReasoning.isEmpty,
              let runtime,
              let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
            pendingContent = ""
            pendingReasoning = ""
            return
        }

        if !pendingContent.isEmpty {
            runtime.messages[index].content += pendingContent
            pendingContent = ""
        }
        if !pendingReasoning.isEmpty {
            var existing = runtime.messages[index].reasoningContent ?? ""
            existing += pendingReasoning
            runtime.messages[index].reasoningContent = existing
            pendingReasoning = ""
        }
    }
}

extension AppState {

    func dispatchAgentMessage(
        for runtime: AgentRuntime,
        text: String,
        images: [AgentImageAttachment],
        textAttachments: [AgentTextAttachment] = []
    ) {
        let configuration = configurationForCurrentTurn(for: runtime)
        let providerID = configuration.providerID

        // Concurrency gate: cap simultaneous turns per provider so a
        // routine fleet can't blow past the provider's rate limit. If
        // the slot isn't open, queue this dispatch — `releaseProviderSlot`
        // drains pending entries FIFO as turns finish.
        guard acquireProviderSlotIfPossible(providerID: providerID) else {
            pendingDispatchQueue.append(
                PendingDispatch(
                    runtimeID: runtime.id,
                    text: text,
                    images: images,
                    textAttachments: textAttachments,
                    providerID: providerID,
                    enqueuedAt: Date()
                )
            )
            return
        }

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()

        let userMessage = AgentMessage(
            role: .user,
            content: text,
            images: images,
            textAttachments: textAttachments
        )
        runtime.messages.append(userMessage)
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

    /// Try to claim a slot for `providerID`. Returns true if the cap
    /// wasn't reached and a slot was reserved; false if the caller
    /// should queue. Always pairs with `releaseProviderSlot(providerID:)`
    /// from the turn loop's defer so counts stay accurate even on
    /// thrown errors / cancellation.
    func acquireProviderSlotIfPossible(providerID: String) -> Bool {
        let current = inFlightCountByProvider[providerID] ?? 0
        guard current < perProviderConcurrencyLimit else { return false }
        inFlightCountByProvider[providerID] = current + 1
        return true
    }

    func releaseProviderSlot(providerID: String) {
        let current = inFlightCountByProvider[providerID] ?? 0
        if current <= 1 {
            inFlightCountByProvider.removeValue(forKey: providerID)
        } else {
            inFlightCountByProvider[providerID] = current - 1
        }
        // Drain any pending entries that can now grab the freshly
        // released slot. Walk once: each released slot can promote at
        // most one queued entry for the same provider; entries for
        // other providers stay in line.
        drainPendingDispatchQueue()
    }

    func drainPendingDispatchQueue() {
        guard !pendingDispatchQueue.isEmpty else { return }
        var remaining: [PendingDispatch] = []
        remaining.reserveCapacity(pendingDispatchQueue.count)
        // Walk in FIFO order; promote the first entry per provider
        // that fits under the cap, leave the rest queued.
        var promotedByProvider: Set<String> = []
        for entry in pendingDispatchQueue {
            if promotedByProvider.contains(entry.providerID) {
                remaining.append(entry)
                continue
            }
            let current = inFlightCountByProvider[entry.providerID] ?? 0
            guard current < perProviderConcurrencyLimit else {
                remaining.append(entry)
                continue
            }
            guard let runtime = agentRuntimes[entry.runtimeID] else {
                // Runtime was torn down (session deleted) — drop it.
                continue
            }
            promotedByProvider.insert(entry.providerID)
            dispatchAgentMessage(
                for: runtime,
                text: entry.text,
                images: entry.images,
                textAttachments: entry.textAttachments
            )
        }
        pendingDispatchQueue = remaining
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

    /// Resolve the configuration to use for this turn. Honours the per-
    /// session concrete model override if one is set; otherwise follows the
    /// global Flash/Pro route. Takes the runtime so concurrent runs each
    /// pick up their own override rather than whatever happened to be on
    /// the currently-selected one.
    func configurationForCurrentTurn(for runtime: AgentRuntime) -> AgentConfiguration {
        var configuration = agentConfiguration.normalized.resolved(for: .interactive)
        if let override = runtime.sessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            configuration.model = override
        }
        return configuration.normalized
    }

    func configurationForContextCompression() -> AgentConfiguration {
        agentConfiguration.normalized.resolved(for: .compression)
    }

    func consumeNextQueuedMessageIfNeeded(for runtime: AgentRuntime) {
        // Wait for any in-flight compression to finish — otherwise the
        // user's queued message would race a compression that just got
        // kicked off in the same defer block.
        guard !runtime.isResponding, !runtime.isCompressingContext else { return }
        guard let next = runtime.queuedMessages.first else { return }
        runtime.queuedMessages.removeFirst()
        dispatchAgentMessage(
            for: runtime,
            text: next.text,
            images: next.images,
            textAttachments: next.textAttachments
        )
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


    /// the actual Agent request shape instead of only counting visible chat
    /// bubbles, so system context, tool schemas, collapsed tool history, and
    /// provider-ready message normalization are all represented.
    ///
    /// 带 memo：消息条数 / 会话不变时 1 秒内直接回缓存值——这是个给
    /// 状态栏圆环看的估算值，不需要逐 token 精确；全量重算的成本见
    /// `agentTokenEstimateCache` 的注释。
    var estimatedAgentTokens: Int {
        let now = Date()
        let messageCount = agentMessages.count
        let sessionID = activeAgentSessionID
        if let cached = agentTokenEstimateCache,
           cached.messageCount == messageCount,
           cached.sessionID == sessionID,
           now.timeIntervalSince(cached.at) < 1.0 {
            return cached.value
        }
        let requestMessages = estimatedAgentRequestMessages
        let tools = AgentToolRegistry.all
        let value = Self.estimateAgentTokens(messages: requestMessages, tools: tools)
        agentTokenEstimateCache = (messageCount, sessionID, value, now)
        return value
    }

    var activeAgentModelID: String {
        if let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           agentModelIsCompatibleWithActiveProvider(override) {
            return override
        }
        return agentConfiguration.normalized.model(for: .interactive)
    }

    var agentModelStatusText: String {
        if let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           agentModelIsCompatibleWithActiveProvider(override) {
            return "Override · \(override)"
        }
        return agentConfiguration.normalized.routingLabel
    }

    var estimatedAgentRequestMessages: [AgentMessage] {
        let systemPrompt = AgentContextBuilder.systemPrompt(
            rootDirectory: rootDirectory,
            openedFileURL: openedFileURL,
            fileContent: fileContent,
            selectedText: selectedText,
            language: effectiveLanguage,
            toolsEnabled: true,
            interactionMode: agentInteractionMode,
            approvalMode: agentApprovalMode,
            currentPlan: agentCurrentPlan,
            currentGoal: agentCurrentGoal
        )
        let collapsedHistory = Self.collapseOldToolResults(in: agentMessages)
        return AgentClient.providerReadyMessages([
            AgentMessage(role: .system, content: systemPrompt)
        ] + collapsedHistory, supportsImages: agentConfiguration.normalized.supportsImageInput)
    }

    nonisolated static func estimateAgentTokens(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor]
    ) -> Int {
        var total = 0

        for message in AgentClient.providerReadyMessages(messages) {
            total += 4
            total += estimateTextTokens(message.role.rawValue)
            total += estimateTextTokens(message.modelContent)
            total += message.images.count * 600
            for call in message.toolCalls {
                total += 12
                total += estimateTextTokens(call.externalID)
                total += estimateTextTokens(call.toolName)
                total += estimateTextTokens(call.argumentsJSON)
            }
            if let toolCallID = message.toolCallID {
                total += estimateTextTokens(toolCallID)
            }
        }

        if !tools.isEmpty {
            total += 16
            for tool in tools {
                total += 24
                total += estimateTextTokens(tool.name)
                total += estimateTextTokens(tool.description)
                for parameter in tool.parameters {
                    total += 8
                    total += estimateTextTokens(parameter.name)
                    total += estimateTextTokens(parameter.type.rawValue)
                    total += estimateTextTokens(parameter.description)
                }
            }
        }

        total += 2
        return total
    }

    nonisolated static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var asciiNonWhitespace = 0
        var cjkScalars = 0
        var otherScalars = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.value <= 0x7F {
                asciiNonWhitespace += 1
            } else if isCJKScalar(scalar) {
                cjkScalars += 1
            } else {
                otherScalars += 1
            }
        }

        let asciiTokens = Int(ceil(Double(asciiNonWhitespace) / 4.0))
        let otherTokens = Int(ceil(Double(otherScalars) * 0.8))
        return max(1, asciiTokens + cjkScalars + otherTokens)
    }

    nonisolated static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
    }

    /// Heuristic context-window budget for the active model. Falls back to
    /// a modern 128k window for unknown models so custom OpenAI-compatible
    /// models don't look full after one ordinary turn.
    var agentContextWindow: Int {
        Self.agentContextWindow(
            model: activeAgentModelID,
            providerID: agentConfiguration.providerID
        )
    }

    nonisolated static func agentContextWindow(model rawModel: String, providerID rawProviderID: String = "") -> Int {
        let model = rawModel.lowercased()
        let providerID = rawProviderID.lowercased()
        // Substring match — vendors include variants like `-32k`, `-128k` in the id.
        if model.contains("1m") || model.contains("-1m") || model.contains("1000k") { return 1_000_000 }
        if model.contains("512k") { return 512_000 }
        if model.contains("400k") { return 400_000 }
        if model.contains("200k") { return 200_000 }
        if model.contains("128k") || model.contains("-128k") { return 128_000 }
        if model.contains("64k") { return 64_000 }
        if model.contains("32k") { return 32_000 }
        if model.contains("16k") { return 16_000 }
        if model.contains("8k") { return 8_000 }
        // Known family defaults.
        if model.contains("gpt-5") { return 400_000 }
        if model.contains("gpt-4.1") { return 1_000_000 }
        if model.contains("gpt-4o") || model.contains("o1") || model.contains("o3") || model.contains("o4") { return 128_000 }
        if model.contains("claude") { return 200_000 }
        if model.contains("deepseek") { return 64_000 }
        if model.contains("qwen-long") { return 1_000_000 }
        if model.contains("qwen") || model.contains("dashscope") { return 128_000 }
        if model.contains("kimi") || model.contains("moonshot") { return 128_000 }
        if model.contains("gpt-3.5") { return 16_000 }
        if providerID == "openai" { return 128_000 }
        return 128_000
    }

    func approveAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func alwaysAllowAgentToolCall(id: AgentToolCall.ID) {
        guard let call = agentToolCalls.first(where: { $0.id == id }) else { return }
        if let rule = alwaysAllowedCommand(for: call) {
            addAgentAlwaysAllowedCommand(rule)
        }
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func denyAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .denied(reason: "User denied"))
    }

    func confirmAgentToolCall(id: AgentToolCall.ID, typedConfirmation: String) -> Bool {
        let expected = "confirm"
        guard typedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected else {
            return false
        }
        resolveAgentToolCallDecision(id: id, decision: .approved)
        return true
    }

    /// Resolve an `ask_user` call with the user's typed answer. Empty
    /// strings still resume the loop (so the model can react to "no answer
    /// provided"); use `denyAgentToolCall` to skip outright.
    func answerAgentToolCall(id: AgentToolCall.ID, answer: String) {
        resolveAgentToolCallDecision(id: id, decision: .answered(answer))
    }

    func removeAgentAlwaysAllowedCommand(id: AgentAlwaysAllowedCommand.ID) {
        agentAlwaysAllowedCommands.removeAll { $0.id == id }
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    func clearAgentAlwaysAllowedCommands() {
        agentAlwaysAllowedCommands = []
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    func addAgentAlwaysAllowedCommand(_ command: AgentAlwaysAllowedCommand) {
        guard !agentAlwaysAllowedCommands.contains(where: { $0.commandSignature == command.commandSignature }) else {
            return
        }
        agentAlwaysAllowedCommands.append(command)
        agentAlwaysAllowedCommands.sort { $0.commandSignature < $1.commandSignature }
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    func alwaysAllowedCommand(for call: AgentToolCall) -> AgentAlwaysAllowedCommand? {
        guard let signature = AgentToolAuthorization.signature(for: call) else {
            return nil
        }
        return AgentAlwaysAllowedCommand(commandSignature: signature)
    }

    func isAgentToolCallAlwaysAllowed(toolName: String, arguments: [String: AgentJSONValue], risk: AgentToolRisk) -> Bool {
        guard risk == .write,
              let signature = AgentToolAuthorization.signature(toolName: toolName, arguments: arguments) else {
            return false
        }
        return agentAlwaysAllowedCommands.contains { $0.commandSignature == signature }
    }

    /// Resolve auto-approval for a write-tier tool call. Returns the
    /// source that approved it, or `nil` to mean "user must decide".
    /// Cheap paths (user allowlist, static SafeCommand) run inline; the
    /// LLM judge round-trips only when nothing cheaper matched.
    func autoApprovalSource(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        rootDirectory: URL?,
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart
    ) async -> AgentToolApprovalSource? {
        guard risk == .write else { return nil }

        if approvalMode == .requestEveryTime {
            return nil
        }

        let sandboxDecision = AgentSandboxPolicy.decision(
            toolName: toolName,
            arguments: arguments,
            rootDirectory: rootDirectory
        )
        if sandboxDecision.mode == .escalated {
            if isAgentToolCallAlwaysAllowed(toolName: toolName, arguments: arguments, risk: risk) {
                return .alwaysAllowList
            }
            return nil
        }

        // 0. Goal mode: the whole point is running to the goal without
        //    babysitting, so write-tier calls auto-approve. Two things
        //    deliberately stay out of this fast path: danger-tier calls
        //    never reach this function (risk guard above) and keep their
        //    explicit Confirm gate, and MCP tools on servers the user
        //    marked untrusted still fall through to per-call approval.
        if interactionMode == .goal {
            if toolName == "call_mcp_tool" {
                if let server = arguments["server"]?.stringValue(),
                   AgentMCPSettingsStore.isServerTrusted(name: server) {
                    return .goalMode
                }
                // Untrusted / unidentified server → user decides.
            } else {
                return .goalMode
            }
        }

        if approvalMode == .workspaceAccess,
           workspaceAccessCanAutoApprove(toolName: toolName, arguments: arguments) {
            return .workspaceAccess
        }

        // 1. User-pinned signatures (Always Allow button) — honored
        //    unless the call targets an MCP server the user has marked
        //    as untrusted. rc3 added the per-server trust flag so the
        //    user can pin an MCP tool early, then later demote the whole
        //    server (e.g. after an upstream package update) without
        //    having to find and unpin every individual tool — every call
        //    snaps back to the per-call Allow/Deny gate immediately.
        if isAgentToolCallAlwaysAllowed(toolName: toolName, arguments: arguments, risk: risk) {
            if toolName == "call_mcp_tool",
               let server = arguments["server"]?.stringValue(),
               !AgentMCPSettingsStore.isServerTrusted(name: server) {
                // Untrusted server: fall through. The MCP auto block
                // below re-checks trust and returns nil, so the call
                // lands on the per-call gate.
            } else {
                return .alwaysAllowList
            }
        }

        // MCP tool calls on servers the user has NOT marked untrusted
        // get the same two-tier auto-approval as shell commands:
        //   1. read-looking tool names (get_/list_/search_/…) pass the
        //      static heuristic at zero cost,
        //   2. everything else goes to the LLM judge with the call
        //      rendered as a pseudo command line.
        // Both tiers sit behind the same master toggle as the shell
        // paths; untrusted servers always fall back to the user.
        if toolName == "call_mcp_tool" {
            guard let server = arguments["server"]?.stringValue(),
                  let tool = arguments["tool"]?.stringValue() else {
                return nil
            }
            switch AgentMCPSettingsStore.trustLevel(name: server) {
            case .untrusted:
                return nil
            case .fullyTrusted:
                // Explicit per-server promotion ("my own MCP") — like an
                // Always-Allow pin, it doesn't sit behind the safe-command
                // master toggle.
                return .trustedServer
            case .standard:
                guard autoApproveSafeCommands else { return nil }
                if AgentToolAuthorization.mcpToolNameLooksReadOnly(tool) {
                    return .staticAllowlist
                }
                let pseudoCommand = AgentToolAuthorization.mcpJudgePseudoCommand(
                    server: server,
                    tool: tool,
                    argumentsJSON: arguments["arguments_json"]?.stringValue() ?? "{}"
                )
                let client = AgentClient(configuration: configurationForSafetyJudge())
                return await client.judgeCommandSafety(command: pseudoCommand) ? .llmJudge : nil
            }
        }

        // The remaining auto paths (SafeCommand allowlist + LLM judge)
        // are shell-specific — only `run_command` participates.
        guard toolName == "run_command" else { return nil }

        // The remaining auto paths require both a command argument and
        // the user opting in via the master toggle.
        guard autoApproveSafeCommands,
              let command = arguments["command"]?.stringValue() else {
            return nil
        }

        // 2. Static read-only allowlist (zero latency, zero cost).
        switch SafeCommand.classify(command: command) {
        case .alwaysSafe:
            return .staticAllowlist
        case .alwaysDangerous:
            return nil
        case .needsJudgment:
            break
        }

        // 3. LLM judge. Lightweight non-streaming request; defaults to
        //    "no" on network errors so the user still gates anything we
        //    couldn't certify. We deliberately route the classifier
        //    through the Flash tier (not whatever model the current
        //    turn happens to be using) — it's a single-word YES/NO,
        //    cheap & fast on Flash, and we don't want Pro tokens spent
        //    on every "is `ls` safe?" check.
        let configuration = configurationForSafetyJudge()
        let client = AgentClient(configuration: configuration)
        let safe = await client.judgeCommandSafety(command: command)
        return safe ? .llmJudge : nil
    }

    private func workspaceAccessCanAutoApprove(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        switch toolName {
        case "run_command", "kill_job", "claude_code", "codex_cli", "cursor_agent", "web_fetch":
            return true
        case "call_mcp_tool":
            guard let server = arguments["server"]?.stringValue() else {
                return false
            }
            return AgentMCPSettingsStore.trustLevel(name: server) == .fullyTrusted
        default:
            return false
        }
    }

    private func sandboxModeForToolExecution(
        risk: AgentToolRisk,
        approvalSource: AgentToolApprovalSource?,
        sandboxDecision: AgentSandboxDecision
    ) -> AgentSandboxMode {
        if sandboxDecision.mode == .escalated {
            return .escalated
        }
        if risk == .read {
            return .readOnly
        }
        switch approvalSource {
        case .workspaceAccess, .goalMode, .alwaysAllowList, .trustedServer, .user:
            return .workspaceWrite
        case .escalated:
            return .escalated
        case .staticAllowlist, .llmJudge, .none:
            return sandboxDecision.mode
        }
    }

    /// Configuration used for the auto-approval safety judge. Always
    /// resolves to the active library entry's **Flash** model — small,
    /// cheap, fast — regardless of what tier the current turn is on.
    /// Falls back to the regular per-turn configuration if Flash isn't
    /// set (e.g. a custom provider entry only filled in a Pro model),
    /// because some classification is still better than no
    /// classification.
    func configurationForSafetyJudge() -> AgentConfiguration {
        var configuration = agentConfiguration.normalized.resolved(for: .interactive)
        let flash = configuration.flashModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flash.isEmpty {
            configuration.model = flash
        }
        return configuration.normalized
    }

    func resolveAgentToolCallDecision(id: AgentToolCall.ID, decision: AgentToolDecision) {
        guard let index = agentToolCalls.firstIndex(where: { $0.id == id }) else { return }
        guard agentToolCalls[index].status == .pendingApproval
            || agentToolCalls[index].status == .awaitingConfirm
            || agentToolCalls[index].status == .awaitingUserAnswer else {
            return
        }
        if case .denied(let reason) = decision {
            agentToolCalls[index].status = .denied
            agentToolCalls[index].errorMessage = reason
        }
        agentToolDecisionWaiter?.resume(returning: decision)
        agentToolDecisionWaiter = nil
    }

    @MainActor
    func runAgentLoop(for runtime: AgentRuntime, configuration: AgentConfiguration) async {
        defer {
            runtime.isResponding = false
            runtime.turnStartedAt = nil
            runtime.requestTask = nil
            captureAgentPlanFromLatestMessage(for: runtime)
            captureAgentGoalDefinitionFromLatestMessage(for: runtime)
            captureAgentGoalEvaluationFromLatestMessage(for: runtime)
            persistAgentSession(runtime: runtime)
            maybeAutoCompressContext(for: runtime)
            consumeNextQueuedMessageIfNeeded(for: runtime)
            // Always release the provider slot last so the queue drain
            // sees a fully cleared `isResponding` and won't refuse to
            // dispatch a queued user message that's for the same runtime.
            releaseProviderSlot(providerID: configuration.providerID)
        }

        let client = AgentClient(configuration: configuration)
        // Resolve the runtime's workspace path for tool execution —
        // never read AppState.rootDirectory here. Concurrent runtimes
        // can be running against different workspaces; the window's
        // current folder is a UI concept, not a session concept.
        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let workspaceURL = workspaceLocation?.localPath.map { URL(fileURLWithPath: $0) }
        let remoteRuntimeDescriptor: RuntimeDescriptor? = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let turnBaselineSnapshot = await Self.loadAgentWorktreeSnapshot(for: workspaceURL)
        let turnBaselineChanges = turnBaselineSnapshot.changes
        if workspaceURL != nil {
            runtime.worktreeChanges = turnBaselineChanges
        }

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
                runtime.messages.append(
                    AgentMessage(
                        role: .system,
                        content: Self.backgroundJobCompletionNotice(for: finishedJob)
                    )
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

            let assistantMessage = AgentMessage(role: .assistant, content: "")
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
                currentGoal: runtime.currentGoal
            )
            if let remoteRuntimeDescriptor,
               case .remote(_, let remotePath) = workspaceLocation {
                systemPrompt += """

                Remote workspace:
                - Runtime: \(remoteRuntimeDescriptor.displayName) (\(remoteRuntimeDescriptor.sshTarget))
                - Platform: \(remoteRuntimeDescriptor.platform.displayName) / \(remoteRuntimeDescriptor.arch.displayName)
                - Root: \(remotePath)
                - Tools and shell commands execute on the remote runtime through SSH. Tell the user when a command is remote if it matters.
                """
            }
            let history = runtime.messages.filter { $0.id != assistantID }
            let collapsedHistory = Self.collapseOldToolResults(in: history)
            let requestMessages = [AgentMessage(role: .system, content: systemPrompt)] + collapsedHistory

            var finishReason: String?
            var latestToolCalls: [AgentMessageToolCall] = []
            let streamBuffer = AgentStreamingMessageBuffer(runtime: runtime, assistantID: assistantID)

            do {
                try await client.streamChat(
                    messages: requestMessages,
                    tools: AgentToolRegistry.all
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
                        workspaceURL: workspaceURL
                    )
                    continue
                }

                let context = AgentToolContext(
                    rootDirectory: workspaceURL,
                    workspaceLocation: workspaceLocation,
                    runtimeDescriptor: remoteRuntimeDescriptor,
                    runtimeID: runtime.id,
                    jobRegistry: agentJobRegistry,
                    sandboxMode: sandboxModeForToolExecution(
                        risk: risk,
                        approvalSource: autoApproval,
                        sandboxDecision: sandboxDecision
                    )
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
                    }
                    AgentSandboxAuditLog.append(
                        toolName: call.toolName,
                        arguments: argsDict,
                        decision: sandboxDecision,
                        approvalSource: runtime.toolCalls.first(where: { $0.id == recordID })?.approvalSource ?? autoApproval,
                        outcome: "succeeded"
                    )
                    if call.toolName == "run_command" || risk != .read {
                        await refreshGitStatusAfterAgentTool(
                            for: runtime,
                            workspaceURL: workspaceURL,
                            baselineFingerprint: turnBaselineSnapshot.fingerprint
                        )
                    }
                    appendToolMessage(for: runtime, toolCallID: call.externalID, payload: result.payload)
                } catch {
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .failed
                        runtime.toolCalls[index].errorMessage = error.localizedDescription
                    }
                    AgentSandboxAuditLog.append(
                        toolName: call.toolName,
                        arguments: argsDict,
                        decision: sandboxDecision,
                        approvalSource: runtime.toolCalls.first(where: { $0.id == recordID })?.approvalSource ?? autoApproval,
                        outcome: "failed"
                    )
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Tool error: \(error.localizedDescription)",
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

    func setAgentError(_ error: Error, for runtime: AgentRuntime) {
        runtime.errorMessage = Self.friendlyMessage(for: error)
        runtime.errorDetails = Self.details(for: error)
    }

    /// Translate the raw `Error` thrown by `AgentClient` into a one-line
    /// Chinese caption that tells the user what happened and what to do
    /// next. Falls back to `localizedDescription` for the long tail of
    /// errors we don't specifically classify. The "Details" disclosure
    /// still surfaces the full provider payload for debugging.
    static func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "连接模型超时（120 秒内没收到数据）。可能是网络慢、代理掉线，或者模型本身排队。点击「重试」再试一次，或检查网络/代理。"
            case .notConnectedToInternet:
                return "当前似乎没有网络。检查 Wi-Fi 或网线后点「重试」。"
            case .networkConnectionLost:
                return "连接被中途断开。可能是网络抖动或代理重置。点「重试」再发一次。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "无法连接到模型服务（DNS / 主机解析失败）。检查 Settings 里的 Base URL 是否正确，或代理是否能访问到该域名。"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "TLS / 证书校验失败。如果你在使用自签代理或镜像服务，需要先信任对应证书。"
            case .cancelled:
                return "请求被取消。"
            default:
                return "网络请求失败：\(urlError.localizedDescription)。点「重试」再发一次。"
            }
        }
        if let clientError = error as? AgentClientError {
            switch clientError {
            case .missingAPIKey:
                return "尚未配置 API Key。先到 Settings → Agent 里填好再发请求。"
            case .invalidBaseURL:
                return "Agent Base URL 不合法，先到 Settings 检查一下。"
            case .invalidResponse:
                return "模型返回了无法识别的内容（非标准 SSE/JSON）。如果反复出现，多半是 Base URL 指向了不兼容的服务。"
            case .serverStatus(let provider):
                let code = provider.statusCode
                let hint: String
                switch code {
                case 401, 403: hint = "鉴权失败，检查 API Key 是否正确、是否过期。常见原因是从浏览器/密码管理器复制时带了首尾空格或换行——回到 Settings → Agent 把 key 重新粘贴一次（保存时会自动去掉空白）。也确认 Base URL 是否与该 Key 对应的服务匹配。"
                case 404:      hint = "接口路径找不到，检查 Base URL 与模型名是否匹配。"
                case 408, 504: hint = "上游网关超时。稍等片刻点「重试」即可。"
                case 429:      hint = "触发限流（QPS / 配额）。等几秒再点「重试」，或换一个更宽松的模型。"
                case 500...599: hint = "模型服务端 5xx 错误。多半是临时抽风，点「重试」。"
                default:       hint = "查看「Details」里的响应体定位原因。"
                }
                return "模型服务返回 HTTP \(code)。\(hint)"
            case .unsupportedProviderKind(let kind):
                return "当前 provider 使用的传输协议（\(kind.rawValue)）在这个版本里还没接通。到 Settings → Agent Providers 里换一个支持的 provider，或等下个版本。"
            }
        }
        return error.localizedDescription
    }

    /// Whether the error banner should expose a "Retry" affordance.
    /// We allow retry whenever the loop is idle and there's at least one
    /// user message in the history — i.e. there's something to retry.
    var canRetryLastAgentTurn: Bool {
        guard !isAgentResponding, !isCompressingAgentContext else { return false }
        guard agentMessages.contains(where: { $0.role == .user }) else { return false }
        return true
    }

    /// Re-run `runAgentLoop` against the existing conversation. The user's
    /// last message is already in `agentMessages` (it stays in the history
    /// even when the assistant turn errors out), so we just kick the loop
    /// again with the current configuration. Used by the error card's
    /// "Retry" button when the previous turn died on a timeout or other
    /// transient network error.
    func retryLastAgentTurn() {
        guard canRetryLastAgentTurn,
              let runtime = activeRuntime else { return }
        let configuration = configurationForCurrentTurn(for: runtime)

        // Same gate as the dispatch path — a retry counts against the
        // provider quota just like a fresh send. Queueing is fine: when
        // a slot frees, the queue drain will pick up the runtime's
        // existing transcript and re-run.
        guard acquireProviderSlotIfPossible(providerID: configuration.providerID) else {
            // Retry button on the error card while the cap is busy:
            // do nothing rather than silently queue a re-run, because
            // the user's expectation is "right now" — leave the error
            // visible so they can click again in a moment.
            return
        }

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()

        runtime.requestTask?.cancel()
        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self else { return }
            guard let runtime else {
                self.releaseProviderSlot(providerID: configuration.providerID)
                return
            }
            await self.runAgentLoop(for: runtime, configuration: configuration)
        }
    }

    /// Dismiss the error banner without retrying — used by the "Close"
    /// (×) affordance on the error card. Keeps the user's last message in
    /// history so they can edit/copy and re-send manually.
    func dismissAgentError() {
        agentErrorMessage = nil
        agentErrorDetails = nil
    }

    static func details(for error: Error) -> AgentErrorDetails? {
        guard case AgentClientError.serverStatus(let providerError) = error else {
            return nil
        }
        return AgentErrorDetails(sections: [
            AgentErrorDetails.Section(
                title: "Request",
                text: """
                Method: \(providerError.method)
                URL: \(providerError.url)
                Provider: \(providerError.providerID)
                Model: \(providerError.model)
                """
            ),
            AgentErrorDetails.Section(title: "Input Messages", text: providerError.requestSummary),
            AgentErrorDetails.Section(title: "Request Body", text: providerError.requestBody),
            AgentErrorDetails.Section(
                title: "Response",
                text: """
                HTTP \(providerError.statusCode)

                \(providerError.responseBody.isEmpty ? "(empty response body)" : providerError.responseBody)
                """
            )
        ])
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
    nonisolated static func backgroundJobCompletionNotice(for job: AgentBackgroundJob) -> String {
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
        return """
        <background-task-notification>
        Background job \(job.displayHandle) finished while you were not in this turn.
        Command: \(trimmedCommand)
        Status: \(job.status.rawValue) (\(exitText)), duration \(durationText).
        \(outputHint)
        </background-task-notification>
        """
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
        workspaceURL: URL?
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
                workspaceURL: workspaceURL
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
        // currently-displayed conversation — a background runtime can
        // get compressed while its session is not on screen.
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
            // Auto-compression can be racing with a queued message —
            // resume the queue once compression resolves so the user
            // doesn't see "queued" forever.
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
        // Find tool message indices.
        let toolIndices = messages.enumerated().compactMap { offset, message in
            message.role == .tool ? offset : nil
        }
        guard toolIndices.count > keepRecentToolMessages else { return messages }
        let collapseUpTo = toolIndices[toolIndices.count - keepRecentToolMessages - 1]

        var copy = messages
        for index in 0...collapseUpTo where copy[index].role == .tool {
            let original = copy[index]
            // Already collapsed.
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

    func rejectAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let index = agentPatchProposals.firstIndex(where: { $0.id == id }) else { return }
        agentPatchProposals[index].status = .rejected
        agentPatchProposals[index].statusMessage = "Rejected"
    }

    func applyAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let index = agentPatchProposals.firstIndex(where: { $0.id == id }) else { return }

        do {
            try applyAgentPatch(agentPatchProposals[index].diff)
            agentPatchProposals[index].status = .applied
            agentPatchProposals[index].statusMessage = "Applied"
        } catch {
            agentPatchProposals[index].status = .failed
            agentPatchProposals[index].statusMessage = error.localizedDescription
        }
    }

    func captureAgentPatchProposals(for runtime: AgentRuntime, fromMessageID messageID: UUID) {
        guard let message = runtime.messages.first(where: { $0.id == messageID }) else { return }
        let diffs = AgentPatchApplier.extractDiffBlocks(from: message.content)
        guard !diffs.isEmpty else { return }

        let existingDiffs = Set(runtime.patchProposals.map(\.diff))
        for (offset, diff) in diffs.enumerated() where !existingDiffs.contains(diff) {
            let title = diffs.count == 1 ? "Agent Patch" : "Agent Patch \(offset + 1)"
            runtime.patchProposals.append(
                AgentPatchProposal(messageID: messageID, title: title, diff: diff)
            )
        }
    }

    func applyAgentPatch(_ diff: String) throws {
        guard let rootDirectory else {
            throw AgentPatchError.noWorkspace
        }

        let changes = try AgentPatchApplier.parse(diff)
        let root = rootDirectory.standardizedFileURL
        let rootPath = root.path
        var pendingWrites: [(url: URL, content: String, relativePath: String)] = []

        for change in changes {
            let url = try resolveAgentPatchURL(change.path, root: root, rootPath: rootPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentPatchError.missingFile(change.path)
            }

            let currentContent = try editableContent(forAgentPatchURL: url)
            let newContent = try AgentPatchApplier.apply(change, to: currentContent)
            let relativePath = Self.relativeWorkspacePath(for: url, root: root, rootPath: rootPath)
            pendingWrites.append((url, newContent, relativePath))
        }

        for pendingWrite in pendingWrites {
            try pendingWrite.content.write(to: pendingWrite.url, atomically: true, encoding: .utf8)
            applyAgentPatchedContent(pendingWrite.content, to: pendingWrite.url)
        }

        // Mark this session as having had the Agent actually touch files so
        // the worktree-change card can show. Fresh sessions with no applied
        // patch never get the card, even if the repo has unrelated diffs.
        if !pendingWrites.isEmpty {
            agentSessionDidEditFiles = true
            // Record each written path so the card stays scoped to files
            // Agent actually touched in THIS session — never the user's
            // own diffs or untracked build artifacts.
            var edited = agentEditedRelativePaths
            for write in pendingWrites where !write.relativePath.isEmpty {
                edited.insert(write.relativePath)
            }
            agentEditedRelativePaths = edited
            persistActiveAgentSession()
        }

        refreshGitStatus()
        persistSession()
    }

    nonisolated static func relativeWorkspacePath(for url: URL, root: URL, rootPath: String) -> String {
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(rootPath + "/") else { return "" }
        return String(standardized.dropFirst(rootPath.count + 1))
    }

    func resolveAgentPatchURL(_ path: String, root: URL, rootPath: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        let filePath = url.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            throw AgentPatchError.pathOutsideWorkspace(path)
        }
        return url
    }

    func editableContent(forAgentPatchURL url: URL) throws -> String {
        if let tab = tabs.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            return tab.content
        }

        let data = try Self.readFileData(from: url, allowLargeFile: true)
        return Self.decodeText(from: data)
    }

    func applyAgentPatchedContent(_ content: String, to url: URL) {
        let standardizedPath = url.standardizedFileURL.path

        for index in tabs.indices where tabs[index].url.standardizedFileURL.path == standardizedPath {
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].isEdited = false
        }

        if openedFileURL?.standardizedFileURL.path == standardizedPath {
            isApplyingTabSnapshot = true
            fileContent = content
            isEdited = false
            isApplyingTabSnapshot = false
            bumpEditorRenderRevision()
            bumpEditorHighlightRevision()
            updateWindowTitle(url: url, isEdited: false)
        }

        knownModificationDates[url] = Self.modificationDate(at: url)
        hasExternalFileChanges = false
    }
}
