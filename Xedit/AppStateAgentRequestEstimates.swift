//
//  AppStateAgentRequestEstimates.swift
//  WillDeep
//
//  Agent request previews, model status, and token/window estimates.
//

import WillDeepCore
import Foundation

/// Context windows a provider reported for specific models, keyed by
/// lowercased model id.
///
/// `agentContextWindow(model:providerID:)` otherwise infers the window from
/// the model id, and an unrecognised id lands on a conservative 128K. That
/// guess is wrong far more often than it looks: of the nine some.im models
/// that publish a window, six did not match — every miss low, one of them
/// (`kimi-k3`, really 1M) by 87%. Under-reading the window is not harmless,
/// because the gauge, auto-compression at 75%, and the ordered stop at 90%
/// all divide by it.
///
/// Populated from `AgentModelDiscovery` rows whenever a model list is fetched
/// or restored from disk, so it survives launches without a network call.
/// Deliberately a plain process-wide table: `agentContextWindow` is a
/// nonisolated hot-path pure function called from token estimation, and
/// routing it through the main actor or a UserDefaults read would be far more
/// expensive than the lookup it guards.
nonisolated enum AgentModelContextWindowCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var windows: [String: Int] = [:]

    static func window(forModel lowercasedID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return windows[lowercasedID]
    }

    /// Merge in whatever the discoveries report. Rows without a window leave
    /// any previously learned value alone — a provider that stops publishing
    /// the field should not silently demote a model back to the guess.
    static func merge(_ discoveries: [AgentModelDiscovery]) {
        let reported = discoveries.compactMap { discovery -> (String, Int)? in
            guard let window = discovery.contextWindowTokens, window > 0 else { return nil }
            let key = discovery.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return nil }
            return (key, window)
        }
        guard !reported.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (key, window) in reported {
            windows[key] = window
        }
    }

    /// Test-only: drop everything learned so a case can assert the fallback.
    static func _reset() {
        lock.lock()
        defer { lock.unlock() }
        windows.removeAll()
    }
}

nonisolated struct AgentContextTokenUsageSnapshot: Equatable, Sendable {
    static let placeholder = AgentContextTokenUsageSnapshot(
        usedTokens: 0,
        baselineTokens: 0,
        contextWindow: 128_000
    )

    let usedTokens: Int
    let baselineTokens: Int
    let contextWindow: Int

    // 状态栏圆环、Compress 按钮、自动压缩判定与 runway 暂停指令消费的是
    // 同一份快照，也必须共用同一个比值：裸 used / window。历史事故：圆环
    // 按 (used−baseline)/(window−baseline) 双向扣减显示 30%，runway 同时
    // 按裸口径告诉模型 92%，两套百分比无从对齐。对话/基线的细分只进
    // tooltip，不再进任何分子或分母。

    /// Fraction of the model window the next request occupies, clamped to
    /// [0, 1]. Same arithmetic as `AgentContextRunwayPolicy.Snapshot.usedPercent`.
    var usedFraction: Double {
        min(1, max(0, Double(usedTokens) / Double(max(1, contextWindow))))
    }

    /// Baseline clamped to `usedTokens` for display: both are priced from
    /// the same content, but a provider-anchored `usedTokens` can lag a
    /// baseline just recomputed against a larger system prompt.
    var displayBaselineTokens: Int {
        min(max(0, baselineTokens), usedTokens)
    }

    /// Conversation-only share of `usedTokens` (history minus the stable
    /// system prompt + tool schemas). Tooltip detail, never a gauge input.
    var conversationTokens: Int {
        max(0, usedTokens - displayBaselineTokens)
    }

    var remainingTokens: Int {
        max(0, contextWindow - usedTokens)
    }

    /// Manual "Compress" affordance: the same bare fraction as the ring,
    /// plus enough turns for a summary to be worth writing.
    func shouldOfferManualCompression(messageCount: Int) -> Bool {
        usedFraction > 0.5 && messageCount > 6
    }
}

private nonisolated struct AgentTokenEstimateWorkload: Sendable {
    var fixedTokens = 2
    var texts: [String] = []
}

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
        if let environment = agentLoopInferenceEnvironment { return environment.configuration.normalized }
        let configuration = (sessionProviderConfiguration(for: runtime) ?? agentConfiguration.normalized)
            .resolved(for: .interactive)
        return Self.applyingSessionModelOverride(runtime.sessionModelOverride, to: configuration)
    }

    /// The provider a runtime is pinned to, before any per-purpose model
    /// resolution. `nil` means "no session pin — use the Settings default".
    func sessionProviderConfiguration(for runtime: AgentRuntime) -> AgentConfiguration? {
        if let entry = providerEntry(for: runtime) {
            return entry.makeConfiguration(
                imageDescription: agentConfiguration.imageDescription
            ).normalized
        }
        guard runtime.sessionProviderIDOverride == AgentProviderPreset.someIMID else { return nil }
        let settings = SomeIMIntegrationStore.loadSettings().normalized
        let entry = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            baseURL: settings.baseURL,
            apiKey: SomeIMIntegrationStore.loadAPIKey(),
            flashPrimary: SomeIMIntegrationSettings.defaultTextModel,
            proPrimary: SomeIMIntegrationSettings.defaultTextModel,
            routingMode: .flash
        )
        return entry.makeConfiguration(
            imageDescription: agentConfiguration.imageDescription
        ).normalized
    }

    /// Base configuration for a runtime's auxiliary requests (compression,
    /// titling, input suggestions). These used to read the global Settings
    /// provider unconditionally, so a session pinned to provider B still
    /// sent its history to provider A with A's key. Same provider as
    /// Settings → keep Settings (it carries the explicit compression / title
    /// models); a different pinned provider → that provider, whose flash
    /// model then serves as the compression and title model.
    func auxiliaryBaseConfiguration(for runtime: AgentRuntime?) -> AgentConfiguration {
        let global = agentConfiguration.normalized
        guard agentLoopInferenceEnvironment == nil,
              let runtime,
              let session = sessionProviderConfiguration(for: runtime) else {
            return global
        }
        return Self.auxiliaryBaseConfiguration(global: global, session: session)
    }

    static func auxiliaryBaseConfiguration(
        global: AgentConfiguration,
        session: AgentConfiguration
    ) -> AgentConfiguration {
        let sameProvider = session.providerID == global.providerID
            && session.baseURL == global.baseURL
            && session.apiKey == global.apiKey
        return sameProvider ? global : session
    }

    /// `.normalized` resets any model its preset doesn't recognise to the
    /// preset default — meant for stale Settings values carried across a
    /// provider switch. A per-session override is an explicit choice (the
    /// picker, a Routine, a dispatch node, a Goal plan member), so it is
    /// written back *after* normalising; otherwise e.g. a Routine pinned to
    /// `o4-mini` on the OpenAI preset silently ran `gpt-4.1-mini`.
    static func applyingSessionModelOverride(
        _ rawOverride: String?,
        to configuration: AgentConfiguration
    ) -> AgentConfiguration {
        var result = configuration.normalized
        guard let override = rawOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return result
        }
        result.model = override
        return result
    }

    func configurationForContextCompression() -> AgentConfiguration {
        agentConfiguration.normalized.resolved(for: .compression)
    }

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
            executionAgent: runtime.executionAgent,
            delegationPolicy: runtime.currentTurnDelegationPolicy,
            loadedPacks: runtime.loadedToolPacks
        )
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
            planProgressFormatViolation: activeRuntime.map {
                latestTurnHasUnparsableProgressBlock(for: $0)
            } ?? false,
            currentGoal: agentCurrentGoal,
            promptProfile: promptProfile,
            // Mirror the real request assembly so the estimate matches what
            // the loop will actually send.
            capabilities: AgentPromptCapabilities(
                activeExperts: agentActiveExperts,
                computerUseGranted: AgentComputerUseBridge.accessibilityEverGranted,
                sandboxEnabled: activeRuntime.map { !$0.localSandboxDisabled } ?? true,
                browserPackLoaded: activeRuntime?.loadedToolPacks.contains(.browserWeb) ?? false
            )
        )
        let settings = AgentMemorySettingsStore.loadSettings()
        // Loaded once: retrieval and the index below both need the full set,
        // and this runs on every composer keystroke that refreshes the gauge.
        let memoryRecords = AgentMemorySettingsStore.loadRecords()
        let memoryResults = AgentMemoryEngine.retrieve(
            query: Self.memoryRetrievalQuery(
                messages: agentMessages,
                openedFileURL: openedFileURL,
                selectedText: selectedText
            ),
            records: memoryRecords,
            settings: settings,
            rootDirectory: rootDirectory,
            openedFileURL: openedFileURL,
            selectedText: selectedText
        )
        if let memoryContext = AgentMemoryEngine.contextBlock(for: memoryResults) {
            assembledPrompt += "\n\n\(memoryContext)"
        }
        // Kept in step with the real assembly in `runAgentLoop`; an estimate
        // that omits a block the request actually sends under-reports the
        // window and is how a "fits comfortably" preview turns into a 400.
        if let memoryIndex = AgentMemoryEngine.indexBlock(
            records: memoryRecords,
            excluding: Set(memoryResults.map(\.record.id)),
            settings: settings,
            rootDirectory: rootDirectory
        ) {
            assembledPrompt += "\n\n\(memoryIndex)"
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

    private func estimatedAgentRequestMessages(
        prompt: (systemMessage: AgentMessage, turnContext: String)
    ) -> [AgentMessage] {
        // 估算口径必须与发往模型的 history 对齐:已经存在的 context
        // summary 在请求阶段会把旧消息折叠成一段 system 摘要,本地
        // estimator 也得用同一个 modelFacingHistory,不然「Compress」
        // 跑完后 ring 还是 100%,用户会以为压缩没生效。
        let modelFacing = activeRuntime.map { modelFacingHistory(for: $0) } ?? Self.modelFacingHistory(
            messages: agentMessages,
            contextSummary: nil,
            contextSummaryThroughMessageID: nil
        )
        let collapsedHistory = Self.collapseOldToolResults(in: modelFacing)
        let contextualHistory = AgentContextBuilder.appendingTurnContext(
            prompt.turnContext,
            to: collapsedHistory
        )
        return AgentClient.providerReadyMessages(
            [prompt.systemMessage] + contextualHistory,
            supportsImages: agentConfiguration.normalized.supportsImageInput
        )
    }

    /// Builds the exact request-shaped inputs on the main actor, then moves the
    /// expensive Unicode scan to a utility worker. The status bar calls this
    /// only after relevant state has settled, never during `body` evaluation.
    @MainActor
    func estimateAgentContextUsageSnapshot(
        for sessionID: AgentSession.ID
    ) async -> AgentContextTokenUsageSnapshot? {
        guard activeAgentSessionID == sessionID else { return nil }

        let prompt = buildEstimatedAgentPromptComponents()
        let tools = estimatedAgentToolset
        let requestMessages = estimatedAgentRequestMessages(prompt: prompt)
        let usedWorkload = Self.makeTokenEstimateWorkload(
            messages: requestMessages,
            tools: tools,
            normalizeMessages: false
        )
        let baselineWorkload = Self.makeTokenEstimateWorkload(
            messages: [prompt.systemMessage],
            tools: tools,
            normalizeMessages: true
        )
        let contextWindow = agentContextWindow
        let historyForAnchor = agentMessages
        let summaryThroughID = activeRuntime?.contextSummaryThroughMessageID
        let summaryInstalledAt = activeRuntime?.contextSummaryInstalledAt

        let worker = Task.detached(priority: .utility) { () -> AgentContextTokenUsageSnapshot? in
            let estimated = Self.estimateAgentTokens(workload: usedWorkload)
            guard !Task.isCancelled else { return nil }
            let baselineTokens = Self.estimateAgentTokens(workload: baselineWorkload)
            guard !Task.isCancelled else { return nil }
            let anchored = Self.providerAnchoredUsedTokens(
                messages: historyForAnchor,
                contextSummaryThroughMessageID: summaryThroughID,
                contextSummaryInstalledAt: summaryInstalledAt
            )
            guard !Task.isCancelled else { return nil }
            return AgentContextTokenUsageSnapshot(
                usedTokens: max(estimated, anchored ?? 0),
                baselineTokens: baselineTokens,
                contextWindow: contextWindow
            )
        }
        let snapshot = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled, activeAgentSessionID == sessionID else { return nil }
        return snapshot
    }

    /// Anchor the local estimate to the provider's own `prompt_tokens` for the
    /// most recent request, plus a local estimate for everything appended
    /// since. A character heuristic can only approximate a real BPE tokenizer,
    /// and the gap is what let a 1M-window session read 54% while the provider
    /// rejected it at 1.62M tokens — the true number was already on
    /// `AgentMessage.promptTokens`, the gauge just never looked at it.
    ///
    /// Returns `nil` when no usable reading exists, including when a
    /// compression landed at or after the reading: that summary already shrank
    /// what the provider sees, so the old figure would pin the gauge high
    /// forever and hide the very compression that fixed it.
    nonisolated static func providerAnchoredUsedTokens(
        messages: [AgentMessage],
        contextSummaryThroughMessageID: AgentMessage.ID?,
        contextSummaryInstalledAt: Date? = nil
    ) -> Int? {
        guard let anchorIndex = messages.lastIndex(where: {
            $0.role == .assistant && ($0.promptTokens ?? 0) > 0
        }) else { return nil }
        let anchorTokens = messages[anchorIndex].promptTokens ?? 0

        if let throughID = contextSummaryThroughMessageID,
           let summaryIndex = messages.firstIndex(where: { $0.id == throughID }),
           summaryIndex >= anchorIndex {
            return nil
        }
        // Position is not enough. Compression runs between turns, so the
        // summary marker sits *behind* the newest request while the
        // compression itself happened *after* it: that reading priced a
        // history the provider will never see again. 2026-09-23: a session
        // sat at 68% right after "compression finished" for exactly this
        // reason — the ring was quoting the pre-compression request.
        if let installedAt = contextSummaryInstalledAt,
           messages[anchorIndex].createdAt <= installedAt {
            return nil
        }

        // From the anchor inclusive: `prompt_tokens` priced the request that
        // produced this assistant turn, so its own reply is new weight too.
        let appended = modelFacingHistory(
            messages: Array(messages[anchorIndex...]),
            contextSummary: nil,
            contextSummaryThroughMessageID: nil
        )
        // Tools and the system prompt are already inside `anchorTokens`.
        let delta = estimateAgentTokens(
            messages: collapseOldToolResults(in: appended),
            tools: []
        )
        return anchorTokens + delta
    }

    nonisolated static func estimateAgentTokens(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor]
    ) -> Int {
        estimateAgentTokens(
            workload: makeTokenEstimateWorkload(
                messages: messages,
                tools: tools,
                normalizeMessages: true
            )
        )
    }

    private nonisolated static func makeTokenEstimateWorkload(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor],
        normalizeMessages: Bool
    ) -> AgentTokenEstimateWorkload {
        var workload = AgentTokenEstimateWorkload()
        let preparedMessages = normalizeMessages
            ? AgentClient.providerReadyMessages(messages)
            : messages

        for message in preparedMessages {
            workload.fixedTokens += 4 + (message.images.count * 600)
            workload.texts.append(message.role.rawValue)
            workload.texts.append(message.modelContent)
            for call in message.toolCalls {
                workload.fixedTokens += 12
                workload.texts.append(call.externalID)
                workload.texts.append(call.toolName)
                workload.texts.append(call.argumentsJSON)
            }
            if let toolCallID = message.toolCallID {
                workload.texts.append(toolCallID)
            }
        }

        if !tools.isEmpty {
            workload.fixedTokens += 16
            for tool in tools {
                workload.fixedTokens += 24
                workload.texts.append(tool.name)
                workload.texts.append(tool.description)
                for parameter in tool.parameters {
                    workload.fixedTokens += 8
                    workload.texts.append(parameter.name)
                    workload.texts.append(parameter.type.rawValue)
                    workload.texts.append(parameter.description)
                }
            }
        }
        return workload
    }

    private nonisolated static func estimateAgentTokens(
        workload: AgentTokenEstimateWorkload
    ) -> Int {
        var total = workload.fixedTokens
        for text in workload.texts {
            guard !Task.isCancelled else { return total }
            total += estimateTextTokens(text)
        }
        return total
    }

    /// Character-class heuristic. The previous口径 (`ascii / 4`, whitespace
    /// free) was tuned on English prose and under-counted an agent transcript
    /// by ~3x: tool-call ids, UUIDs, paths, JSON and terminal output are
    /// symbol-dense (real tokenizers land near 2 chars/token there), and the
    /// indentation/newlines that dominate code and logs were priced at zero.
    /// A 1M-window session read as 54% full while the provider rejected the
    /// request at 1.62M tokens. Whitespace is now billed and ASCII is split
    /// into prose-like letters vs dense symbols; `providerAnchoredUsedTokens`
    /// still corrects the remainder against real provider usage.
    nonisolated static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var asciiLetters = 0
        var asciiDense = 0
        var whitespaceScalars = 0
        var cjkScalars = 0
        var otherScalars = 0

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                whitespaceScalars += 1
            } else if scalar.value <= 0x7F {
                let value = scalar.value
                let isLetter = (value >= 0x41 && value <= 0x5A)
                    || (value >= 0x61 && value <= 0x7A)
                if isLetter {
                    asciiLetters += 1
                } else {
                    asciiDense += 1
                }
            } else if isCJKScalar(scalar) {
                cjkScalars += 1
            } else {
                otherScalars += 1
            }
        }

        let total = Double(asciiLetters) / 4.0
            + Double(asciiDense) / 2.0
            + Double(whitespaceScalars) / 4.0
            + Double(cjkScalars)
            + Double(otherScalars) * 0.8
        return max(1, Int(ceil(total)))
    }

    nonisolated static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
    }

    /// Heuristic context-window budget for the active session. Falls back to
    /// a modern 128k window for unknown models so custom OpenAI-compatible
    /// models don't look full after one ordinary turn.
    var agentContextWindow: Int {
        guard let runtime = activeRuntime else {
            let configuration = agentConfiguration.normalized
            return Self.agentContextWindow(
                model: configuration.model(for: .interactive),
                providerID: configuration.providerID
            )
        }
        return agentContextWindow(for: runtime)
    }

    /// Window for one specific runtime, resolved from the provider entry and
    /// model override pinned to that session — not from the Settings-wide
    /// default provider and never from whichever session happens to be
    /// frontmost. Background sessions previously borrowed the active
    /// session's window as their auto-compression denominator.
    func agentContextWindow(for runtime: AgentRuntime) -> Int {
        let configuration = configurationForCurrentTurn(for: runtime)
        // `.model`, not `model(for:)`: the property is the fully resolved
        // per-turn model — session override included — and is exactly what
        // the runway policy divides by (`turnConfiguration.model`). The
        // routing accessor reads flash/pro fields and would ignore
        // `sessionModelOverride`.
        return Self.agentContextWindow(
            model: configuration.model,
            providerID: configuration.providerID
        )
    }

    nonisolated static func agentContextWindow(model rawModel: String, providerID rawProviderID: String = "") -> Int {
        let model = rawModel.lowercased()
        let providerID = rawProviderID.lowercased()
        // A window the provider actually published beats anything guessed from
        // the id. Everything below this line is inference.
        if let reported = AgentModelContextWindowCatalog.window(forModel: model) {
            return reported
        }
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
