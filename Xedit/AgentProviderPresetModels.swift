//
//  AgentProviderPresetModels.swift
//  WillDeep
//
//  Agent provider kind / preset catalogue split out of AgentModels.swift.
//

import Foundation

/// Transport-protocol family a preset speaks. `providerID` identifies
/// the vendor / relay station (OpenRouter, SiliconFlow, …); `kind`
/// identifies *how* we talk to it. Multiple providerIDs share the same
/// kind (every OpenAI-compatible relay → `.openAIChat`), and the same
/// vendor can expose more than one kind (OpenAI exposes both Chat
/// Completions and the newer Responses API).
enum AgentProviderKind: String, Codable, Equatable {
    /// Classic `/v1/chat/completions` SSE — OpenAI, DashScope, DeepSeek,
    /// Kimi, Moonshot, OpenRouter, SiliconFlow, AnyRouter, some.im, and
    /// the catch-all Custom preset all speak this dialect.
    case openAIChat
    /// New `/v1/responses` API — used by o-series reasoning models.
    case openAIResponses
    /// Anthropic native `/v1/messages` — `x-api-key` + `anthropic-version`
    /// headers, a wholly different request/event shape from OpenAI.
    case anthropicMessages
    /// Google AI Studio / Vertex `streamGenerateContent` — `?key=...`
    /// query param auth, function_declarations schema.
    case geminiGenerateContent
}

struct AgentProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Transport-protocol family. See `AgentProviderKind` doc-comment.
    let kind: AgentProviderKind
    let baseURL: String
    let defaultFlashModel: String
    let defaultProModel: String
    let supportsModelFetch: Bool
    let supportsImageInput: Bool
    let requiresAPIKey: Bool
    /// Short list of substrings that identify a model as belonging to
    /// this provider — used by `normalized()` to detect when a stale
    /// flash/pro model name from a previous provider got carried over
    /// after the user switched providers in Settings. Best-effort: an
    /// unrecognised name doesn't crash, it just sticks until the user
    /// picks one from the live model list.
    let modelHints: [String]

    static let openAIID = "openai"
    static let deepSeekID = "deepseek"
    static let ollamaID = "ollama"
    static let customID = "custom"
    static let someIMID = "some-im"

    var defaultModel: String { defaultFlashModel }
    var defaultVisionModel: String {
        if id == "dashscope" {
            return "qwen3-vl-plus"
        }
        // some.im routes vision through its own model, which is not the text
        // default and never was. Falling through to `defaultFlashModel` here
        // only looked harmless while that happened to be a multimodal model;
        // once the text default moved down to the M tier it would have handed
        // the image picker a text-only model.
        if id == Self.someIMID {
            return SomeIMIntegrationSettings.defaultVisionModel
        }
        if id == Self.customID {
            return ""
        }
        return defaultFlashModel
    }

    init(
        id: String,
        displayName: String,
        kind: AgentProviderKind = .openAIChat,
        baseURL: String,
        defaultModel: String,
        defaultFlashModel: String? = nil,
        defaultProModel: String? = nil,
        supportsModelFetch: Bool,
        supportsImageInput: Bool = true,
        requiresAPIKey: Bool = true,
        modelHints: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.defaultFlashModel = defaultFlashModel ?? defaultModel
        self.defaultProModel = defaultProModel ?? defaultModel
        self.supportsModelFetch = supportsModelFetch
        self.supportsImageInput = supportsImageInput
        self.requiresAPIKey = requiresAPIKey
        self.modelHints = modelHints
    }

    /// Quick "does this model name look like it could be one of mine"
    /// check. Custom provider says yes to everything (no opinion); a
    /// preset without hints also says yes (back-compat). Lowercase
    /// substring match against `modelHints`.
    func recognizesModelID(_ rawID: String) -> Bool {
        let id = rawID.lowercased()
        guard !id.isEmpty else { return true }
        guard self.id != Self.customID else { return true }
        guard !modelHints.isEmpty else { return true }
        return modelHints.contains { id.contains($0.lowercased()) }
    }

    static let all: [AgentProviderPreset] = [
        AgentProviderPreset(
            id: openAIID,
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4.1-mini",
            defaultProModel: "gpt-4.1",
            supportsModelFetch: true,
            modelHints: ["gpt-", "o1", "o3", "text-embedding", "davinci"]
        ),
        AgentProviderPreset(
            id: "openai-responses",
            displayName: "OpenAI Responses",
            kind: .openAIResponses,
            // Same origin as classic OpenAI; the adapter just hits
            // `/responses` instead of `/chat/completions`. Keep the
            // `/v1` suffix here — `AgentNetworkSupport.endpoint` will
            // collapse a duplicate when joining `responses`.
            baseURL: "https://api.openai.com/v1",
            // o-series reasoning models are the headline use case
            // for Responses; the cheaper / smaller `o4-mini` is the
            // sensible flash default, with `o3` as the pro tier.
            defaultModel: "o4-mini",
            defaultProModel: "o3",
            supportsModelFetch: true,
            modelHints: ["gpt-", "o1", "o3", "o4"]
        ),
        AgentProviderPreset(
            id: "dashscope",
            displayName: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            defaultProModel: "qwen-max",
            supportsModelFetch: true,
            modelHints: ["qwen", "qwq"]
        ),
        AgentProviderPreset(
            id: deepSeekID,
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-v4-flash",
            defaultProModel: "deepseek-v4-pro",
            supportsModelFetch: true,
            supportsImageInput: false,
            modelHints: ["deepseek"]
        ),
        AgentProviderPreset(
            id: "kimi",
            displayName: "Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2.5",
            supportsModelFetch: true,
            modelHints: ["kimi"]
        ),
        AgentProviderPreset(
            id: "moonshot",
            displayName: "Moonshot",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "moonshot-v1-8k",
            supportsModelFetch: true,
            modelHints: ["moonshot"]
        ),
        AgentProviderPreset(
            id: "claude",
            displayName: "Claude",
            kind: .anthropicMessages,
            // Adapter appends `v1/messages` / `v1/models` itself; the
            // base URL stays at the bare origin so the same field can
            // host enterprise / proxy deployments that mount Anthropic
            // under a different prefix.
            baseURL: "https://api.anthropic.com",
            defaultModel: "claude-sonnet-4-5",
            supportsModelFetch: true,
            modelHints: ["claude", "anthropic"]
        ),
        AgentProviderPreset(
            id: "gemini",
            displayName: "Google Gemini",
            kind: .geminiGenerateContent,
            // Adapter appends `v1beta/models/{model}:streamGenerateContent`
            // (or `:generateContent` for the non-streaming classifier).
            // Base URL stays at the bare origin so enterprise / Vertex
            // proxies that mount Gemini under a custom prefix can reuse
            // the same field without us hardcoding `v1beta`.
            baseURL: "https://generativelanguage.googleapis.com",
            defaultModel: "gemini-2.5-flash",
            defaultProModel: "gemini-2.5-pro",
            supportsModelFetch: true,
            modelHints: ["gemini"]
        ),
        // ---- Relay stations (all OpenAI Chat-compatible) ----
        // OpenRouter aggregates 100+ models behind one API. We default
        // to a free-tier text model so the user can verify the
        // connection without spending budget; chat picker shows
        // alternates from the live /models fetch.
        AgentProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-4o-mini",
            defaultProModel: "anthropic/claude-sonnet-4.5",
            supportsModelFetch: true,
            // Model IDs on OpenRouter are namespaced (`vendor/model`)
            // and span every major lab — a hint list would either be
            // misleadingly narrow or pointlessly broad. Empty list →
            // `recognizesModelID` defaults to true, which is the
            // right call for an aggregator.
            modelHints: []
        ),
        // SiliconFlow (硅基流动) — a popular Chinese relay with cheap
        // access to Qwen / DeepSeek / GLM / Yi / etc.
        AgentProviderPreset(
            id: "siliconflow",
            displayName: "SiliconFlow (硅基流动)",
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModel: "Qwen/Qwen2.5-7B-Instruct",
            defaultProModel: "deepseek-ai/DeepSeek-V3",
            supportsModelFetch: true,
            modelHints: []
        ),
        // AnyRouter — same shape as OpenRouter, different vendor.
        // Base URL placeholder; user should override if their account
        // is on a different shard.
        AgentProviderPreset(
            id: "anyrouter",
            displayName: "AnyRouter",
            baseURL: "https://anyrouter.top/v1",
            defaultModel: "gpt-4o-mini",
            defaultProModel: "claude-sonnet-4-5",
            supportsModelFetch: true,
            modelHints: []
        ),
        // some.im managed relay. Every account can have its own routing
        // config, but the product-facing provider name stays canonical.
        AgentProviderPreset(
            id: "some-im",
            displayName: "some.im",
            baseURL: "https://some.im/v1",
            // M tier by default; the 1M `deepseek-v4-flash` is now what `deep`
            // escalates to, not where every session starts.
            defaultModel: "glm-5",
            defaultProModel: "deepseek-v4-pro",
            supportsModelFetch: true,
            modelHints: []
        ),
        AgentProviderPreset(
            id: ollamaID,
            displayName: "Ollama / Local OpenAI",
            baseURL: "http://127.0.0.1:11434/v1",
            defaultModel: "gemma4:e2b-it-qat",
            defaultProModel: "gemma4:e2b-it-qat",
            supportsModelFetch: true,
            requiresAPIKey: false,
            modelHints: []
        ),
        AgentProviderPreset(
            id: customID,
            displayName: "Custom",
            baseURL: "",
            defaultModel: "",
            supportsModelFetch: true
        )
    ]

    static func preset(id: String) -> AgentProviderPreset? {
        all.first { $0.id == id }
    }

    static func suggestedDisplayName(providerID: String) -> String {
        let normalizedID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return preset(id: normalizedID)?.displayName ?? normalizedID
    }

    static func normalizedDisplayName(providerID: String?, storedDisplayName: String?) -> String? {
        let normalizedID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = storedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedID == someIMID || display == "some.im (Rocky's relay)" {
            return preset(id: someIMID)?.displayName ?? "some.im"
        }
        if !display.isEmpty {
            return display
        }
        if !normalizedID.isEmpty {
            return preset(id: normalizedID)?.displayName ?? normalizedID
        }
        return nil
    }

    static func matchingBaseURL(_ baseURL: String) -> AgentProviderPreset? {
        let normalized = normalizeBaseURL(baseURL)
        return all.first { preset in
            !preset.baseURL.isEmpty && normalizeBaseURL(preset.baseURL) == normalized
        }
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t")).lowercased()
    }
}
