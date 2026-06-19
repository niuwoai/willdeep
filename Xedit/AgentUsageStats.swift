//
//  AgentUsageStats.swift
//  WillDeep
//
//  Pure analytics over the persisted Agent sessions. Powers the
//  Claude-Code-style stats dashboard shown in place of the empty-chat
//  hero. Nothing here touches disk or talks to a provider — feed it
//  the in-memory `[AgentSession]` and it computes everything else.
//

import Foundation

/// Aggregate metrics for the Agent-mode stats dashboard.
struct AgentUsageOverview: Equatable {
    var sessionCount: Int
    var messageCount: Int
    /// Sum of `AgentMessage.usageTokens` where reported; for messages
    /// without a real usage number we fall back to chars/4 + per-image
    /// budget so old sessions still contribute something.
    var totalTokens: Int
    /// True when at least one message had a real usage number — the UI
    /// labels the total "≈" otherwise.
    var hasAnyRealUsage: Bool
    /// Distinct calendar days (user's current timezone) that saw at
    /// least one message.
    var activeDays: Int
    /// Length of the most recent run of consecutive active days that
    /// includes today (or 0 if today is empty).
    var currentStreak: Int
    /// Length of the longest run of consecutive active days ever.
    var longestStreak: Int
    /// Hour-of-day (0-23) with the most messages. Nil if no messages.
    var peakHour: Int?
    /// Model ID with the most messages routed through it.
    var favoriteModel: String?
}

/// One cell of the GitHub-style heatmap: a calendar day plus its
/// message count.
struct AgentHeatmapCell: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let count: Int
}

struct AgentModelUsageRow: Identifiable, Equatable {
    var id: String { "\(providerID)|\(modelID)" }
    let providerID: String
    let providerName: String
    let modelID: String
    var sessionCount: Int
    var messageCount: Int
    var promptTokens: Int
    var completionTokens: Int
    var cachedPromptTokens: Int
    var cacheWritePromptTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var estimatedTokens: Int
    var estimatedCostUSD: Double?
    var hasEstimatedUsage: Bool
    var isDelegatedExternal: Bool
    var cacheDiagnosticTurns: Int
    var stablePrefixCharactersTotal: Int

    var cacheHitRate: Double {
        guard promptTokens > 0 else { return 0 }
        return Double(cachedPromptTokens) / Double(promptTokens)
    }

    var averageStablePrefixCharacters: Int {
        guard cacheDiagnosticTurns > 0 else { return 0 }
        return stablePrefixCharactersTotal / cacheDiagnosticTurns
    }
}

enum AgentUsageStats {
    /// Build an overview snapshot for the given sessions. Pure function
    /// — same input always produces the same output, no side effects.
    static func overview(for sessions: [AgentSession], now: Date = Date()) -> AgentUsageOverview {
        let allMessages = sessions.flatMap(\.messages)
        let messageCount = allMessages.count
        let sessionCount = sessions.count

        var totalTokens = 0
        var hasAnyRealUsage = false
        for message in allMessages {
            if let usage = message.usageTokens, usage > 0 {
                totalTokens += usage
                hasAnyRealUsage = true
            } else {
                totalTokens += estimateTokens(for: message)
            }
        }

        let calendar = Calendar.current
        let dayKeys: [Date] = allMessages.map { calendar.startOfDay(for: $0.createdAt) }
        let uniqueDays = Set(dayKeys)
        let activeDays = uniqueDays.count

        let streaks = computeStreaks(
            uniqueDays: uniqueDays,
            now: now,
            calendar: calendar
        )

        var hourCounts: [Int: Int] = [:]
        for message in allMessages {
            let hour = calendar.component(.hour, from: message.createdAt)
            hourCounts[hour, default: 0] += 1
        }
        let peakHour = hourCounts.max { $0.value < $1.value }?.key

        var modelCounts: [String: Int] = [:]
        for session in sessions {
            guard let model = session.modelID, !model.isEmpty else { continue }
            modelCounts[model, default: 0] += session.messages.count
        }
        let favoriteModel = modelCounts.max { $0.value < $1.value }?.key

        return AgentUsageOverview(
            sessionCount: sessionCount,
            messageCount: messageCount,
            totalTokens: totalTokens,
            hasAnyRealUsage: hasAnyRealUsage,
            activeDays: activeDays,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            peakHour: peakHour,
            favoriteModel: favoriteModel
        )
    }

    /// Produce a GitHub-style heatmap: `weekCount` columns of 7 rows
    /// each (Mon..Sun), counting messages per day in the user's local
    /// timezone. Defaults to 12 weeks. Returned in column-major order
    /// (oldest column first); the caller renders left → right.
    static func heatmap(
        for sessions: [AgentSession],
        weekCount: Int = 12,
        now: Date = Date()
    ) -> [[AgentHeatmapCell]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let earliestStart = calendar.date(byAdding: .day, value: -(weekCount * 7 - 1), to: today) else {
            return []
        }

        let messages = sessions.flatMap(\.messages)
        var perDay: [Date: Int] = [:]
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            if day < earliestStart { continue }
            perDay[day, default: 0] += 1
        }

        var columns: [[AgentHeatmapCell]] = []
        for week in 0..<weekCount {
            var column: [AgentHeatmapCell] = []
            for day in 0..<7 {
                let offset = week * 7 + day
                guard let date = calendar.date(byAdding: .day, value: offset, to: earliestStart) else { continue }
                let count = perDay[date] ?? 0
                column.append(AgentHeatmapCell(date: date, count: count))
            }
            columns.append(column)
        }
        return columns
    }

    /// Number of "War and Peace"s the user has burned through, for the
    /// fun-fact line in the dashboard footer. War and Peace ≈ 587k words ≈ 783k
    /// tokens at our chars/4 heuristic. We just call it 780k for round numbers.
    static func warAndPeaceEquivalents(tokenTotal: Int) -> Double {
        guard tokenTotal > 0 else { return 0 }
        return Double(tokenTotal) / 780_000.0
    }

    static func modelUsage(for sessions: [AgentSession]) -> [AgentModelUsageRow] {
        var rows: [String: AgentModelUsageRow] = [:]

        for session in sessions {
            var seenKeysInSession = Set<String>()

            for message in session.messages where message.role == .assistant {
                let identity = usageIdentity(for: message, session: session)
                let key = "\(identity.provider.id)|\(identity.modelID)"
                var row = rows[key] ?? AgentModelUsageRow(
                    providerID: identity.provider.id,
                    providerName: identity.provider.name,
                    modelID: identity.modelID,
                    sessionCount: 0,
                    messageCount: 0,
                    promptTokens: 0,
                    completionTokens: 0,
                    cachedPromptTokens: 0,
                    cacheWritePromptTokens: 0,
                    reasoningTokens: 0,
                    totalTokens: 0,
                    estimatedTokens: 0,
                    estimatedCostUSD: nil,
                    hasEstimatedUsage: false,
                    isDelegatedExternal: identity.isDelegatedExternal,
                    cacheDiagnosticTurns: 0,
                    stablePrefixCharactersTotal: 0
                )
                if seenKeysInSession.insert(key).inserted {
                    row.sessionCount += 1
                }
                let usage = usageBreakdown(for: message)
                row.messageCount += 1
                row.promptTokens += usage.prompt
                row.completionTokens += usage.completion
                row.cachedPromptTokens += usage.cachedPrompt
                row.cacheWritePromptTokens += usage.cacheWritePrompt
                row.reasoningTokens += usage.reasoning
                row.totalTokens += usage.total
                row.estimatedTokens += usage.estimated
                row.hasEstimatedUsage = row.hasEstimatedUsage || usage.isEstimated
                if let stable = message.requestStablePrefixCharacters, stable > 0 {
                    row.cacheDiagnosticTurns += 1
                    row.stablePrefixCharactersTotal += stable
                }
                row.isDelegatedExternal = row.isDelegatedExternal || identity.isDelegatedExternal
                row.estimatedCostUSD = estimatedCostUSD(for: row)
                rows[key] = row
            }
        }

        return rows.values
            .filter { $0.messageCount > 0 || $0.totalTokens > 0 }
            .sorted {
                let lhs = $0.estimatedCostUSD ?? -1
                let rhs = $1.estimatedCostUSD ?? -1
                if lhs != rhs { return lhs > rhs }
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                if $0.providerName != $1.providerName { return $0.providerName < $1.providerName }
                return $0.modelID < $1.modelID
            }
    }

    // MARK: - Internals

    private static func estimateTokens(for message: AgentMessage) -> Int {
        var total = max(0, message.modelContent.count / 4)
        // Reasoning content costs tokens too even when the provider
        // doesn't split it out.
        if let reasoning = message.reasoningContent {
            total += reasoning.count / 4
        }
        // Tool-call argument bodies are part of the wire payload.
        for call in message.toolCalls {
            total += call.argumentsJSON.count / 4
        }
        // Per-image flat budget aligning with AppState.estimatedAgentTokens.
        total += message.images.count * 600
        return total
    }

    private static func normalizedModelID(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown-model" : trimmed
    }

    private static func providerSnapshot(for session: AgentSession, modelID: String) -> (id: String, name: String) {
        if let providerID = session.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            let display = session.providerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                providerID,
                display?.isEmpty == false
                    ? display!
                    : AgentProviderPreset.preset(id: providerID)?.displayName ?? providerID
            )
        }

        let inferred = inferProviderID(from: modelID)
        return (inferred, AgentProviderPreset.preset(id: inferred)?.displayName ?? inferred)
    }

    private static func usageIdentity(
        for message: AgentMessage,
        session: AgentSession
    ) -> (provider: (id: String, name: String), modelID: String, isDelegatedExternal: Bool) {
        if message.origin == .delegatedExternal {
            let label = message.originLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = label?.isEmpty == false ? label! : "External CLI"
            return (("delegated-external", "Delegated CLI"), model, true)
        }
        let modelID = normalizedModelID(session.modelID)
        return (providerSnapshot(for: session, modelID: modelID), modelID, false)
    }

    private static func inferProviderID(from modelID: String) -> String {
        let id = modelID.lowercased()
        if id.contains("deepseek") { return AgentProviderPreset.deepSeekID }
        if id.contains("claude") || id.contains("anthropic") { return "claude" }
        if id.contains("gemini") { return "gemini" }
        if id.contains("qwen") || id.contains("qwq") { return "dashscope" }
        if id.contains("kimi") { return "kimi" }
        if id.contains("moonshot") { return "moonshot" }
        if id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") {
            return AgentProviderPreset.openAIID
        }
        return AgentProviderPreset.customID
    }

    private static func usageBreakdown(for message: AgentMessage) -> (
        prompt: Int,
        completion: Int,
        cachedPrompt: Int,
        cacheWritePrompt: Int,
        reasoning: Int,
        total: Int,
        estimated: Int,
        isEstimated: Bool
    ) {
        let cached = max(0, message.cachedPromptTokens ?? 0)
        let cacheWrite = max(0, message.cacheWritePromptTokens ?? 0)
        let reasoning = max(0, message.reasoningTokens ?? 0)

        if let prompt = message.promptTokens,
           let completion = message.completionTokens {
            let total = message.usageTokens ?? (prompt + completion)
            return (prompt, completion, cached, cacheWrite, reasoning, max(total, prompt + completion), 0, false)
        }

        if let total = message.usageTokens, total > 0 {
            let completionEstimate = max(1, message.modelContent.count / 4 + (message.reasoningContent?.count ?? 0) / 4)
            let completion = min(total, completionEstimate)
            return (max(0, total - completion), completion, cached, cacheWrite, reasoning, total, total, true)
        }

        let estimated = estimateTokens(for: message)
        return (0, estimated, cached, cacheWrite, reasoning, estimated, estimated, true)
    }

    private static func estimatedCostUSD(for row: AgentModelUsageRow) -> Double? {
        guard !row.isDelegatedExternal else { return nil }
        guard let price = AgentModelPricing.price(providerID: row.providerID, modelID: row.modelID) else {
            return nil
        }
        let cached = min(row.cachedPromptTokens, row.promptTokens)
        let uncachedPrompt = max(0, row.promptTokens - cached)
        let inputCost = Double(uncachedPrompt) * price.inputPerMillion / 1_000_000.0
        let cachedCost = Double(cached) * (price.cachedInputPerMillion ?? price.inputPerMillion) / 1_000_000.0
        let cacheWriteCost = Double(row.cacheWritePromptTokens) * (price.cacheWritePerMillion ?? price.inputPerMillion) / 1_000_000.0
        let outputCost = Double(row.completionTokens) * price.outputPerMillion / 1_000_000.0
        return inputCost + cachedCost + cacheWriteCost + outputCost
    }

    private static func computeStreaks(
        uniqueDays: Set<Date>,
        now: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        guard !uniqueDays.isEmpty else { return (0, 0) }

        let sortedDays = uniqueDays.sorted()
        var longest = 1
        var run = 1
        for index in 1..<sortedDays.count {
            let prev = sortedDays[index - 1]
            let curr = sortedDays[index]
            if let next = calendar.date(byAdding: .day, value: 1, to: prev), next == curr {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        // Current streak only counts if today is active (and walks
        // backward day-by-day from today).
        let today = calendar.startOfDay(for: now)
        var current = 0
        var cursor = today
        while uniqueDays.contains(cursor) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        return (current, longest)
    }
}

private struct AgentModelPrice {
    let providerIDs: Set<String>
    let modelHints: [String]
    let inputPerMillion: Double
    let cachedInputPerMillion: Double?
    let cacheWritePerMillion: Double?
    let outputPerMillion: Double
}

private enum AgentModelPricing {
    static func price(providerID: String, modelID: String) -> AgentModelPrice? {
        let providerCandidates = providerCandidates(providerID: providerID, modelID: modelID)
        let model = modelID.lowercased()

        for provider in providerCandidates {
            if let match = prices.first(where: { price in
                price.providerIDs.contains(provider)
                    && price.modelHints.contains { model.contains($0) }
            }) {
                return match
            }
        }
        return nil
    }

    private static func providerCandidates(providerID: String, modelID: String) -> [String] {
        var candidates = OrderedStringSet()
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        candidates.append(provider)
        candidates.append(contentsOf: providerAliases[provider] ?? [])

        let model = modelID.lowercased()
        if model.contains("deepseek") {
            candidates.append(AgentProviderPreset.deepSeekID)
        }
        if model.contains("qwen") || model.contains("qwq") {
            candidates.append("dashscope")
        }
        if model.contains("claude") || model.contains("anthropic") {
            candidates.append("claude")
        }
        if model.contains("gemini") {
            candidates.append("gemini")
        }
        if model.contains("kimi") {
            candidates.append("kimi")
        }
        if model.contains("moonshot") {
            candidates.append("moonshot")
        }
        if model.contains("glm-") || model.contains("chatglm") {
            candidates.append("zhipu")
            candidates.append("bigmodel")
        }
        if model.hasPrefix("gpt-") || model.contains("/gpt-") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            candidates.append(AgentProviderPreset.openAIID)
            candidates.append("openai-responses")
        }
        return candidates.values.filter { !$0.isEmpty }
    }

    private static let providerAliases: [String: [String]] = [
        "openai-chat": [AgentProviderPreset.openAIID],
        "openai-compatible": [AgentProviderPreset.openAIID],
        "openai-responses": [AgentProviderPreset.openAIID],
        "custom": [AgentProviderPreset.openAIID, "dashscope", AgentProviderPreset.deepSeekID, "claude", "gemini", "kimi", "moonshot", "zhipu", "bigmodel"],
        "dashscope-intl": ["dashscope"],
        "aliyun": ["dashscope"],
        "alibaba": ["dashscope"],
        "qwen": ["dashscope"],
        "deepseek-ai": [AgentProviderPreset.deepSeekID],
        "anthropic": ["claude"],
        "google": ["gemini"],
        "moonshot-ai": ["kimi", "moonshot"],
        "z.ai": ["zhipu", "bigmodel"],
        "zai": ["zhipu", "bigmodel"],
        "zhipuai": ["zhipu", "bigmodel"],
        "chatglm": ["zhipu", "bigmodel"],
        "glm": ["zhipu", "bigmodel"]
    ]

    private static func cny(_ yuanPerMillion: Double) -> Double {
        yuanPerMillion / 7.2
    }

    // Built-in public price cache. Prices are USD per 1M tokens unless noted
    // by the provider's public API pricing page. Keep model-specific rows
    // before broader family rows so substring matching stays deterministic.
    private static let prices: [AgentModelPrice] = [
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.5"], inputPerMillion: 5.0, cachedInputPerMillion: 0.5, cacheWritePerMillion: nil, outputPerMillion: 30.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.4-mini"], inputPerMillion: 0.75, cachedInputPerMillion: 0.075, cacheWritePerMillion: nil, outputPerMillion: 4.5),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.4"], inputPerMillion: 2.5, cachedInputPerMillion: 0.25, cacheWritePerMillion: nil, outputPerMillion: 15.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5-mini"], inputPerMillion: 0.25, cachedInputPerMillion: 0.025, cacheWritePerMillion: nil, outputPerMillion: 2.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5-nano"], inputPerMillion: 0.05, cachedInputPerMillion: 0.005, cacheWritePerMillion: nil, outputPerMillion: 0.4),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5-codex", "gpt-5"], inputPerMillion: 1.25, cachedInputPerMillion: 0.125, cacheWritePerMillion: nil, outputPerMillion: 10.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4.1-mini"], inputPerMillion: 0.40, cachedInputPerMillion: 0.10, cacheWritePerMillion: nil, outputPerMillion: 1.60),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4.1-nano"], inputPerMillion: 0.10, cachedInputPerMillion: 0.025, cacheWritePerMillion: nil, outputPerMillion: 0.40),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4.1"], inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: nil, outputPerMillion: 8.00),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4o-mini"], inputPerMillion: 0.15, cachedInputPerMillion: 0.075, cacheWritePerMillion: nil, outputPerMillion: 0.60),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-4o"], inputPerMillion: 2.50, cachedInputPerMillion: 1.25, cacheWritePerMillion: nil, outputPerMillion: 10.00),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["o4-mini"], inputPerMillion: 1.10, cachedInputPerMillion: 0.275, cacheWritePerMillion: nil, outputPerMillion: 4.40),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["o3-mini"], inputPerMillion: 1.10, cachedInputPerMillion: 0.55, cacheWritePerMillion: nil, outputPerMillion: 4.40),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["o3"], inputPerMillion: 2.00, cachedInputPerMillion: 0.50, cacheWritePerMillion: nil, outputPerMillion: 8.00),

        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-fable-5", "claude-mythos-5"], inputPerMillion: 10.0, cachedInputPerMillion: 1.0, cacheWritePerMillion: 12.5, outputPerMillion: 50.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-opus-4.8", "claude-opus-4.7", "claude-opus-4.6", "claude-opus-4.5"], inputPerMillion: 5.0, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 25.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-opus-4.1", "claude-opus-4"], inputPerMillion: 15.0, cachedInputPerMillion: 1.5, cacheWritePerMillion: 18.75, outputPerMillion: 75.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-sonnet-4.6", "claude-sonnet-4.5", "claude-sonnet-4"], inputPerMillion: 3.0, cachedInputPerMillion: 0.3, cacheWritePerMillion: 3.75, outputPerMillion: 15.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-haiku-4.5"], inputPerMillion: 1.0, cachedInputPerMillion: 0.1, cacheWritePerMillion: 1.25, outputPerMillion: 5.0),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-3-5-haiku", "claude-haiku-3.5"], inputPerMillion: 0.8, cachedInputPerMillion: 0.08, cacheWritePerMillion: 1.0, outputPerMillion: 4.0),

        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-3"], inputPerMillion: 2.0, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 12.0),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.5-pro"], inputPerMillion: 1.25, cachedInputPerMillion: 0.125, cacheWritePerMillion: nil, outputPerMillion: 10.0),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.5-flash-lite"], inputPerMillion: 0.10, cachedInputPerMillion: 0.01, cacheWritePerMillion: nil, outputPerMillion: 0.40),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.5-flash"], inputPerMillion: 0.30, cachedInputPerMillion: 0.03, cacheWritePerMillion: nil, outputPerMillion: 2.50),
        AgentModelPrice(providerIDs: ["gemini"], modelHints: ["gemini-2.0-flash-lite"], inputPerMillion: 0.10, cachedInputPerMillion: 0.025, cacheWritePerMillion: nil, outputPerMillion: 0.40),

        AgentModelPrice(providerIDs: ["deepseek"], modelHints: ["deepseek-v4-pro"], inputPerMillion: 0.435, cachedInputPerMillion: 0.003625, cacheWritePerMillion: nil, outputPerMillion: 0.87),
        AgentModelPrice(providerIDs: ["deepseek"], modelHints: ["deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"], inputPerMillion: 0.14, cachedInputPerMillion: 0.0028, cacheWritePerMillion: nil, outputPerMillion: 0.28),

        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen3-vl-plus", "qwen-vl-plus"], inputPerMillion: 0.11, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.28),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-max", "qwen3-max"], inputPerMillion: 0.28, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 1.11),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-plus", "qwen3-plus", "qwen2.5-plus"], inputPerMillion: 0.11, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.28),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-turbo"], inputPerMillion: 0.042, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.083),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-long"], inputPerMillion: 0.042, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.083),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwq"], inputPerMillion: 0.22, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.88),

        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.7-code-highspeed"], inputPerMillion: cny(13.0), cachedInputPerMillion: cny(2.6), cacheWritePerMillion: nil, outputPerMillion: cny(54.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.7-code"], inputPerMillion: cny(6.5), cachedInputPerMillion: cny(1.3), cacheWritePerMillion: nil, outputPerMillion: cny(27.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.6"], inputPerMillion: cny(6.5), cachedInputPerMillion: cny(1.1), cacheWritePerMillion: nil, outputPerMillion: cny(27.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.5"], inputPerMillion: cny(4.0), cachedInputPerMillion: cny(0.7), cacheWritePerMillion: nil, outputPerMillion: cny(21.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-128k"], inputPerMillion: cny(10.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(30.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-32k"], inputPerMillion: cny(5.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(20.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-8k"], inputPerMillion: cny(2.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(10.0)),

        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-4.5"], inputPerMillion: cny(0.8), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(2.0))
    ]
}

private struct OrderedStringSet {
    private(set) var values: [String] = []

    mutating func append(_ value: String) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }

    mutating func append(contentsOf newValues: [String]) {
        for value in newValues {
            append(value)
        }
    }
}
