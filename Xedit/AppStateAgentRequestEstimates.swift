//
//  AppStateAgentRequestEstimates.swift
//  WillDeep
//
//  Agent request previews, model status, and token/window estimates.
//

import Foundation

extension AppState {
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
        var systemPrompt = AgentContextBuilder.systemPrompt(
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
            systemPrompt += "\n\n\(memoryContext)"
        }
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
}
