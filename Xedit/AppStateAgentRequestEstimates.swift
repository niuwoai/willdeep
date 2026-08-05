//
//  AppStateAgentRequestEstimates.swift
//  WillDeep
//
//  Agent request previews, model status, and token/window estimates.
//

import Foundation

extension AppState {
    /// Resolve the exact provider entry pinned to a runtime. Legacy sessions
    /// without an entry UUID fall back to provider id + display name before
    /// using the current default, so existing history remains compatible.
    func providerEntry(for runtime: AgentRuntime) -> AgentProviderEntry? {
        if let entryID = runtime.sessionProviderEntryID,
           let entry = agentProviderLibrary.entries.first(where: { $0.id == entryID }) {
            return entry
        }
        let providerID = runtime.sessionProviderIDOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let providerID, !providerID.isEmpty {
            let storedName = runtime.session.providerDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let storedName, !storedName.isEmpty,
               let exact = agentProviderLibrary.entries.first(where: {
                   $0.providerID == providerID
                       && $0.displayName.caseInsensitiveCompare(storedName) == .orderedSame
               }) {
                return exact
            }
            let matchingEntries = agentProviderLibrary.entries.filter {
                $0.providerID == providerID
            }
            if matchingEntries.count == 1 {
                return matchingEntries.first
            }
        }
        return agentProviderLibrary.active
    }

    /// Resolve the configuration to use for this turn. Honours the per-
    /// session concrete model override if one is set; otherwise follows the
    /// global Flash/Pro route. Takes the runtime so concurrent runs each
    /// pick up their own override rather than whatever happened to be on
    /// the currently-selected one.
    func configurationForCurrentTurn(for runtime: AgentRuntime) -> AgentConfiguration {
        var configuration: AgentConfiguration
        if let entry = providerEntry(for: runtime) {
            configuration = entry.makeConfiguration(
                imageDescription: agentConfiguration.imageDescription
            ).normalized.resolved(for: .interactive)
        } else if runtime.sessionProviderIDOverride == AgentProviderPreset.someIMID {
                let settings = SomeIMIntegrationStore.loadSettings().normalized
                let entry = AgentProviderEntry(
                    providerID: AgentProviderPreset.someIMID,
                    baseURL: settings.baseURL,
                    apiKey: SomeIMIntegrationStore.loadAPIKey(),
                    flashPrimary: SomeIMIntegrationSettings.defaultTextModel,
                    proPrimary: SomeIMIntegrationSettings.defaultTextModel,
                    routingMode: .flash
                )
                configuration = entry.makeConfiguration(
                    imageDescription: agentConfiguration.imageDescription
                ).normalized.resolved(for: .interactive)
        } else {
            configuration = agentConfiguration.normalized.resolved(for: .interactive)
        }
        if let override = runtime.sessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            configuration.model = override
        }
        return configuration.normalized
    }

    func configurationForContextCompression() -> AgentConfiguration {
        agentConfiguration.normalized.resolved(for: .compression)
    }

    /// the actual Agent request shape instead of only counting visible chat
    /// bubbles, so system context, tool schemas, collapsed tool history, and
    /// provider-ready message normalization are all represented.
    ///
    /// 带 memo：消息条数 / 会话不变时 1 秒内直接回缓存值——这是个给
    /// 状态栏圆环看的估算值，不需要逐 token 精确；全量重算的成本见
    /// `agentTokenEstimateCache` 的注释。
    /// The tool set the next real request will actually send — filtered by
    /// active experts / interaction mode / executor, exactly like the loop's
    /// streamChat call. Estimating with the full registry counted the
    /// short-drama, chrome, and delegated-CLI blocks that are usually
    /// absent, overstating the ring and tripping 75% auto-compression early.
    var estimatedAgentToolset: [AgentToolDescriptor] {
        guard let runtime = activeRuntime else { return AgentToolRegistry.all }
        return AgentToolRegistry.tools(
            activeExperts: runtime.activeExperts,
            interactionMode: runtime.interactionMode,
            executionAgent: runtime.executionAgent
        )
    }

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
        let tools = estimatedAgentToolset
        let value = Self.estimateAgentTokens(messages: requestMessages, tools: tools)
        agentTokenEstimateCache = (messageCount, sessionID, value, now)
        return value
    }

    var activeAgentModelID: String {
        if let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        guard let runtime = activeRuntime else {
            return agentConfiguration.normalized.model(for: .interactive)
        }
        return configurationForCurrentTurn(for: runtime).model(for: .interactive)
    }

    var agentModelStatusText: String {
        if let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           agentModelIsCompatibleWithActiveProvider(override) {
            return "Override · \(override)"
        }
        return agentConfiguration.normalized.routingLabel
    }

    /// The stable `system` message the model receives. Per-turn workspace,
    /// mode, file, selection, and memory context is attached to the latest
    /// user message by `estimatedAgentPromptComponents`. Split out of
    /// `estimatedAgentRequestMessages`
    /// so the composer ring can price the conversation-free baseline with
    /// the exact same stable system content, which makes the baseline cancel
    /// cleanly out of `used`; dynamic turn context is intentionally counted
    /// with the conversation that carries it.
    var estimatedAgentSystemMessage: AgentMessage {
        estimatedAgentPromptComponents.systemMessage
    }

    private var estimatedAgentPromptComponents: (systemMessage: AgentMessage, turnContext: String) {
        let now = Date()
        let messageCount = agentMessages.count
        let sessionID = activeAgentSessionID
        if let cached = agentSystemMessageCache,
           cached.messageCount == messageCount,
           cached.sessionID == sessionID,
           now.timeIntervalSince(cached.at) < 1.0 {
            return (cached.systemMessage, cached.turnContext)
        }
        let prompt = buildEstimatedAgentPromptComponents()
        agentSystemMessageCache = (
            messageCount,
            sessionID,
            prompt.systemMessage,
            prompt.turnContext,
            now
        )
        return prompt
    }

    /// Uncached construction behind `estimatedAgentPromptComponents`. Builds the
    /// full system prompt and runs memory retrieval (both touch UserDefaults /
    /// project rules), so callers must go through the cached accessor above —
    /// this is the expensive path the switch used to run twice.
    private func buildEstimatedAgentPromptComponents() -> (
        systemMessage: AgentMessage,
        turnContext: String
    ) {
        let promptProfile = AgentSystemPromptProfile.automatic(
            modelID: activeAgentModelID,
            providerID: agentConfiguration.normalized.providerID
        )
        var assembledPrompt = AgentContextBuilder.systemPrompt(
            rootDirectory: rootDirectory,
            openedFileURL: openedFileURL,
            fileContent: fileContent,
            selectedText: selectedText,
            language: effectiveLanguage,
            toolsEnabled: true,
            interactionMode: agentInteractionMode,
            executionAgent: agentExecutionAgent,
            approvalMode: agentApprovalMode,
            currentPlan: agentCurrentPlan,
            currentGoal: agentCurrentGoal,
            promptProfile: promptProfile
        )
        let settings = AgentMemorySettingsStore.loadSettings()
        let memoryResults = AgentMemoryEngine.retrieve(
            query: Self.memoryRetrievalQuery(
                messages: agentMessages,
                openedFileURL: openedFileURL,
                selectedText: selectedText
            ),
            records: AgentMemorySettingsStore.loadRecords(),
            settings: settings,
            rootDirectory: rootDirectory,
            openedFileURL: openedFileURL,
            selectedText: selectedText
        )
        if let memoryContext = AgentMemoryEngine.contextBlock(for: memoryResults) {
            assembledPrompt += "\n\n\(memoryContext)"
        }
        let components = AgentContextBuilder.requestComponents(from: assembledPrompt)
        var configuration = agentConfiguration.normalized
        configuration.model = activeAgentModelID
        let systemPrompt = AgentLocalModelPrompting.applyLanguageInstruction(
            to: components.systemPrompt,
            configuration: configuration
        )
        return (
            AgentMessage(role: .system, content: systemPrompt),
            components.turnContext
        )
    }

    var estimatedAgentRequestMessages: [AgentMessage] {
        // 估算口径必须与发往模型的 history 对齐:已经存在的 context
        // summary 在请求阶段会把旧消息折叠成一段 system 摘要,本地
        // estimator 也得用同一个 modelFacingHistory,不然「Compress」
        // 跑完后 ring 还是 100%,用户会以为压缩没生效。
        let modelFacing = Self.modelFacingHistory(
            messages: agentMessages,
            contextSummary: activeRuntime?.contextSummary,
            contextSummaryThroughMessageID: activeRuntime?.contextSummaryThroughMessageID
        )
        let collapsedHistory = Self.collapseOldToolResults(in: modelFacing)
        let prompt = estimatedAgentPromptComponents
        let contextualHistory = AgentContextBuilder.appendingTurnContext(
            prompt.turnContext,
            to: collapsedHistory
        )
        return AgentClient.providerReadyMessages(
            [prompt.systemMessage] + contextualHistory,
            supportsImages: agentConfiguration.normalized.supportsImageInput
        )
    }

    /// Fixed overhead present before the user sends a single message: the
    /// system prompt (incl. injected memory) and every tool schema, with no
    /// conversation history. The composer ring subtracts this so a fresh
    /// chat reads 0% and fills as the *conversation* grows — see
    /// `ContextRingIndicator`. Cached on the same key as the full estimate
    /// so it isn't rebuilt (system prompt + memory retrieval) every redraw.
    var estimatedAgentBaselineTokens: Int {
        let now = Date()
        let messageCount = agentMessages.count
        let sessionID = activeAgentSessionID
        if let cached = agentBaselineEstimateCache,
           cached.messageCount == messageCount,
           cached.sessionID == sessionID,
           now.timeIntervalSince(cached.at) < 1.0 {
            return cached.value
        }
        let value = Self.estimateAgentTokens(
            messages: [estimatedAgentSystemMessage],
            tools: estimatedAgentToolset
        )
        agentBaselineEstimateCache = (messageCount, sessionID, value, now)
        return value
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
        if model.contains("gpt-5.5") { return 1_050_000 } // gpt-5.5 / -pro: ~1M window
        if model.contains("gpt-5") { return 400_000 }
        if model.contains("gpt-4.1") { return 1_000_000 }
        if model.contains("gpt-4o") || model.contains("o1") || model.contains("o3") || model.contains("o4") { return 128_000 }
        if model.contains("claude") {
            // Version-aware: the current flagship line — Fable/Mythos 5,
            // Opus 4.6/4.7/4.8, Sonnet 4.6 — ships a 1M context window at
            // standard pricing (verified against Anthropic docs, 2026-06).
            // Haiku and the older Opus/Sonnet 4.0–4.5 line stay at the classic
            // 200K. Match both dash (`opus-4-8`) and dot (`opus-4.8`) id forms.
            if model.contains("fable-5") || model.contains("mythos-5")
                || model.contains("opus-4-6") || model.contains("opus-4.6")
                || model.contains("opus-4-7") || model.contains("opus-4.7")
                || model.contains("opus-4-8") || model.contains("opus-4.8")
                || model.contains("sonnet-4-6") || model.contains("sonnet-4.6") {
                return 1_000_000
            }
            return 200_000
        }
        if model.contains("deepseek") {
            // Version-aware: the bare-`deepseek`→64k default was stale. v4
            // (e.g. deepseek-v4-pro / -flash) ships a 1M window; the current
            // v3.1/v3.2/reasoner/chat line is 128k; only genuinely legacy
            // builds stay at the conservative 64k fallback (under-estimating
            // is merely an early-100% gauge, whereas over-estimating risks a
            // real provider overflow). Explicit `-128k`/`-64k`/`1m` id
            // suffixes are already handled by the substring checks above.
            if model.contains("v4") { return 1_000_000 }
            if model.contains("v3.1") || model.contains("v3.2")
                || model.contains("reasoner") || model.contains("deepseek-chat") {
                return 128_000
            }
            return 64_000
        }
        if model.contains("qwen-long") { return 1_000_000 }
        if model.contains("qwen3.7") { return 1_000_000 } // qwen3.7-max/plus: 1M window
        if model.contains("qwen") || model.contains("dashscope") { return 128_000 }
        if model.contains("kimi") || model.contains("moonshot") {
            // Kimi K2 line (k2.5 / k2.6 / k2.7-code) is 256K. Legacy
            // moonshot-v1-{8k,32k,128k} are already resolved by the explicit
            // size-suffix checks near the top of this function.
            if model.contains("kimi-k2") || model.contains("k2.5")
                || model.contains("k2.6") || model.contains("k2.7") {
                return 262_144
            }
            return 128_000
        }
        // Zhipu GLM-5 line: glm-5.2 is 1M; glm-5 / glm-5.1 are 200K; older
        // glm (4.x / chatglm) default to 128K.
        if model.contains("glm-5.2") { return 1_000_000 }
        if model.contains("glm-5") { return 200_000 }
        if model.contains("glm-") || model.contains("chatglm") { return 128_000 }
        if model.contains("gpt-3.5") { return 16_000 }
        if providerID == "openai" { return 128_000 }
        return 128_000
    }
}
