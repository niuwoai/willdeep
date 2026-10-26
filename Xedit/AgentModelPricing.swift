import Foundation

struct AgentModelPrice {
    let providerIDs: Set<String>
    let modelHints: [String]
    let inputPerMillion: Double
    let cachedInputPerMillion: Double?
    let cacheWritePerMillion: Double?
    let outputPerMillion: Double
}

enum AgentModelPricing {
    static let verifiedAt = "2026-10-26"

    static func price(providerID: String, modelID: String, at date: Date? = nil, promptTokens: Int = 0) -> AgentModelPrice? {
        let providerCandidates = providerCandidates(providerID: providerID, modelID: modelID)
        let model = normalizedModelID(modelID)
        if let price = DeepSeekModelPricing.price(model: model, at: date) { return price }
        if matches(model, hint: "claude-haiku-5.5"), promptTokens > 100_000 {
            return AgentModelPrice(providerIDs: ["claude"], modelHints: [model], inputPerMillion: 0.5, cachedInputPerMillion: 0.05, cacheWritePerMillion: 0.625, outputPerMillion: 2.5)
        }

        for provider in providerCandidates {
            if let match = prices.first(where: { price in
                price.providerIDs.contains(provider)
                    && price.modelHints.contains { matches(model, hint: $0) }
            }) {
                return contextualPrice(match, model: model, promptTokens: promptTokens)
            }
        }
        return nil
    }

    private static func contextualPrice(_ price: AgentModelPrice, model: String, promptTokens: Int) -> AgentModelPrice {
        let longContextModels = ["gpt-6-sol", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-terra", "gpt-5.6-luna"]
        guard promptTokens > 272_000, longContextModels.contains(where: { matches(model, hint: $0) }) else { return price }
        return AgentModelPrice(providerIDs: price.providerIDs, modelHints: price.modelHints,
                               inputPerMillion: price.inputPerMillion * 2,
                               cachedInputPerMillion: price.cachedInputPerMillion.map { $0 * 2 },
                               cacheWritePerMillion: price.cacheWritePerMillion.map { $0 * 2 },
                               outputPerMillion: price.outputPerMillion * 1.5)
    }

    static func normalizedModelID(_ modelID: String) -> String {
        var model = String(modelID.lowercased().split(separator: "/").last ?? "")
        if model.hasPrefix("auto-") { model.removeFirst(5) }
        for alias in ["gpt-6-1", "gpt-5-6", "gpt-5-5", "gpt-5-4", "gpt-5-3", "gpt-5-2", "gpt-5-1",
                      "claude-opus-5-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
                      "claude-sonnet-5-5", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-haiku-5-5", "claude-haiku-4-5",
                      "claude-fable-5-1", "claude-mythos-5-1"] {
            guard model == alias || model.hasPrefix(alias + "-") else { continue }
            if let dash = alias.lastIndex(of: "-") {
                model.replaceSubrange(dash...dash, with: ".")
            }
            break
        }
        return model
    }

    private static func matches(_ model: String, hint: String) -> Bool {
        if model == hint { return true }
        if hint == "someim-" { return model.hasPrefix(hint) }
        guard model.hasPrefix(hint + "-") else { return false }
        let suffix = String(model.dropFirst(hint.count + 1))
        return suffix == "latest" || suffix.range(of: #"^\d{4}-?\d{2}-?\d{2}$"#, options: .regularExpression) != nil
    }

    private static func providerCandidates(providerID: String, modelID: String) -> [String] {
        var candidates = OrderedStringSet()
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        candidates.append(provider)
        candidates.append(contentsOf: providerAliases[provider] ?? [])

        let model = normalizedModelID(modelID)
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
        // someim-* models also show up under provider "custom" when routed
        // through an OpenAI-compatible relay; anchor them back to some-im.
        if model.contains("someim") {
            candidates.append("some-im")
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
        // Official standard API reference rates, verified 2026-10-26.
        // https://developers.openai.com/api/docs/pricing
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-6-astra"], inputPerMillion: 10, cachedInputPerMillion: 1, cacheWritePerMillion: 12.5, outputPerMillion: 50),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-6-sol"], inputPerMillion: 2, cachedInputPerMillion: 0.2, cacheWritePerMillion: 2.5, outputPerMillion: 10),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-6.1-sol"], inputPerMillion: 2, cachedInputPerMillion: 0.1, cacheWritePerMillion: 2.5, outputPerMillion: 10),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-6-luna"], inputPerMillion: 0.1, cachedInputPerMillion: 0.01, cacheWritePerMillion: 0.125, outputPerMillion: 0.5),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.3-codex"], inputPerMillion: 1.75, cachedInputPerMillion: 0.175, cacheWritePerMillion: nil, outputPerMillion: 14),
        // https://platform.claude.com/docs/en/about-claude/pricing
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-fable-5.1", "claude-mythos-5.1"], inputPerMillion: 10, cachedInputPerMillion: 0.25, cacheWritePerMillion: 12.5, outputPerMillion: 50),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-opus-5.5"], inputPerMillion: 4, cachedInputPerMillion: 0.2, cacheWritePerMillion: 5, outputPerMillion: 20),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-sonnet-5.5"], inputPerMillion: 2, cachedInputPerMillion: 0.1, cacheWritePerMillion: 2.5, outputPerMillion: 10),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-haiku-5.5"], inputPerMillion: 0.1, cachedInputPerMillion: 0.01, cacheWritePerMillion: 0.125, outputPerMillion: 0.5),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-opus-5"], inputPerMillion: 5, cachedInputPerMillion: 0.5, cacheWritePerMillion: 6.25, outputPerMillion: 25),
        AgentModelPrice(providerIDs: ["claude"], modelHints: ["claude-sonnet-5"], inputPerMillion: 2, cachedInputPerMillion: 0.2, cacheWritePerMillion: 2.5, outputPerMillion: 10),
        // gpt-5.6 tiers must precede the broad "gpt-5" family row, otherwise
        // the substring match silently bills them at gpt-5 rates. Cached input
        // is 10% of the standard rate (OpenAI pricing page, 2026-08).
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6-sol"], inputPerMillion: 4.0, cachedInputPerMillion: 0.4, cacheWritePerMillion: 5, outputPerMillion: 20.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6-terra"], inputPerMillion: 2.0, cachedInputPerMillion: 0.2, cacheWritePerMillion: 2.5, outputPerMillion: 12.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6-luna"], inputPerMillion: 0.20, cachedInputPerMillion: 0.02, cacheWritePerMillion: 0.25, outputPerMillion: 1.20),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.6"], inputPerMillion: 5.0, cachedInputPerMillion: 0.5, cacheWritePerMillion: nil, outputPerMillion: 30.0),
        AgentModelPrice(providerIDs: ["openai", "openai-responses"], modelHints: ["gpt-5.5-pro"], inputPerMillion: 30.0, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 180.0),
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

        // some.im 托管系列（someim-auto / someim-code / someim-coding-plan 等）
        // 无公开牌价，按 deepseek-v4-flash 的价目估算。
        AgentModelPrice(providerIDs: ["some-im"], modelHints: ["someim-"], inputPerMillion: 0.14, cachedInputPerMillion: 0.0028, cacheWritePerMillion: nil, outputPerMillion: 0.28),

        // qwen3.7-max/plus — official 阿里云百炼 (DashScope) list price 原价,
        // 元/百万 token, from the console pricing card (2026-06). cny() → USD.
        // Max is a flat rate; Plus is tiered by input length — we store the
        // ≤256K tier (the 256K–1M tier costs more). Limited-time 5折/8折
        // promos are intentionally NOT baked in (we track list price).
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen3.7-max"], inputPerMillion: cny(12.0), cachedInputPerMillion: cny(2.4), cacheWritePerMillion: cny(15.0), outputPerMillion: cny(36.0)),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen3.7-plus"], inputPerMillion: cny(2.0), cachedInputPerMillion: cny(0.4), cacheWritePerMillion: cny(2.5), outputPerMillion: cny(8.0)),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen3-vl-plus", "qwen-vl-plus"], inputPerMillion: 0.11, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.28),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-max", "qwen3-max"], inputPerMillion: 0.28, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 1.11),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-plus", "qwen3-plus", "qwen2.5-plus"], inputPerMillion: 0.11, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.28),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-turbo"], inputPerMillion: 0.042, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.083),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwen-long"], inputPerMillion: 0.042, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.083),
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["qwq"], inputPerMillion: 0.22, cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: 0.88),

        // kimi-k3 — Moonshot official API list price (USD/M, 2026-07); cache
        // hit bills at $0.30/M, flat across the full context window.
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k3"], inputPerMillion: 3.0, cachedInputPerMillion: 0.30, cacheWritePerMillion: nil, outputPerMillion: 15.0),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.7-code-highspeed"], inputPerMillion: cny(13.0), cachedInputPerMillion: cny(2.6), cacheWritePerMillion: nil, outputPerMillion: cny(54.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.7-code"], inputPerMillion: cny(6.5), cachedInputPerMillion: cny(1.3), cacheWritePerMillion: nil, outputPerMillion: cny(27.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.6"], inputPerMillion: cny(6.5), cachedInputPerMillion: cny(1.1), cacheWritePerMillion: nil, outputPerMillion: cny(27.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["kimi-k2.5"], inputPerMillion: cny(4.0), cachedInputPerMillion: cny(0.7), cacheWritePerMillion: nil, outputPerMillion: cny(21.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-128k"], inputPerMillion: cny(10.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(30.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-32k"], inputPerMillion: cny(5.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(20.0)),
        AgentModelPrice(providerIDs: ["kimi", "moonshot"], modelHints: ["moonshot-v1-8k"], inputPerMillion: cny(2.0), cachedInputPerMillion: nil, cacheWritePerMillion: nil, outputPerMillion: cny(10.0)),

        // GLM-5 has two platform prices. Via 阿里云百炼 (DashScope) it is the
        // official CNY list price 原价 (元/百万 token, ≤32K tier, from the
        // console pricing card 2026-06); this dashscope-scoped row matches
        // bailian users first. Via z.ai international it is USD/M (rows below,
        // zhipu/bigmodel-scoped). glm-5.2/5.1 before glm-5 so the substring
        // match hits the specific id first.
        AgentModelPrice(providerIDs: ["dashscope"], modelHints: ["glm-5"], inputPerMillion: cny(4.0), cachedInputPerMillion: cny(0.8), cacheWritePerMillion: nil, outputPerMillion: cny(18.0)),
        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-5.2"], inputPerMillion: 1.4, cachedInputPerMillion: 0.26, cacheWritePerMillion: nil, outputPerMillion: 4.4),
        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-5.1"], inputPerMillion: 1.4, cachedInputPerMillion: 0.26, cacheWritePerMillion: nil, outputPerMillion: 4.4),
        AgentModelPrice(providerIDs: ["zhipu", "bigmodel"], modelHints: ["glm-5"], inputPerMillion: 1.0, cachedInputPerMillion: 0.2, cacheWritePerMillion: nil, outputPerMillion: 3.2),
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
