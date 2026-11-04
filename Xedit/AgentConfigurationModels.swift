//
//  AgentConfigurationModels.swift
//  WillDeep
//
//  Agent provider configuration models split out of AgentModels.swift.
//

import Foundation

enum AgentModelRoutingMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case flash
    case pro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .flash: return "Flash"
        case .pro: return "Pro"
        }
    }

    var description: String {
        switch self {
        case .auto:
            return "Cost-first routing. Agent turns and compression use Flash unless a session override is selected."
        case .flash:
            return "Always use the lower-cost model slot."
        case .pro:
            return "Always use the stronger model slot."
        }
    }
}

enum AgentModelPurpose {
    case interactive
    case compression
}

struct AgentImageDescriptionConfiguration: Codable, Equatable {
    var providerID: String
    var baseURL: String
    var model: String
    var apiKey: String

    static let `default` = AgentImageDescriptionConfiguration(
        providerID: "dashscope",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        model: "qwen3-vl-plus",
        apiKey: ""
    )

    init(providerID: String, baseURL: String, model: String, apiKey: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? Self.default.providerID
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.default.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    var normalized: AgentImageDescriptionConfiguration {
        var result = self
        result.providerID = result.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = result.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let preset = AgentProviderPreset.preset(id: result.providerID)
        if preset == nil {
            result.providerID = AgentProviderPreset.customID
        }
        if result.baseURL.isEmpty {
            result.baseURL = Self.default.baseURL
        }
        if result.model.isEmpty {
            result.model = Self.default.model
        }
        return result
    }

    var agentConfiguration: AgentConfiguration {
        AgentConfiguration(
            providerID: providerID,
            baseURL: baseURL,
            model: model,
            flashModel: model,
            proModel: model,
            routingMode: .flash,
            imageDescription: self,
            apiKey: apiKey
        ).normalized
    }
}

struct AgentConfiguration: Codable, Equatable {
    var providerID: String
    var baseURL: String
    /// Legacy/current resolved model field. Older settings only stored this.
    var model: String
    var flashModel: String
    var proModel: String
    var routingMode: AgentModelRoutingMode
    var imageDescription: AgentImageDescriptionConfiguration
    var apiKey: String
    /// Optional dedicated model for one-shot conversation-title
    /// summarization. Empty → fall back to `flashModel`. We keep this
    /// separate so users can wire a cheap/fast model (haiku, 4o-mini,
    /// deepseek-chat, qwen-turbo …) for the "give this chat a 12-char
    /// title" task without dragging that model into the main loop.
    var titleModel: String
    /// Optional dedicated model for context compression. Empty → fall back to
    /// `flashModel`. Kept separate from `titleModel` because the two tasks
    /// pull in opposite directions: titling is a 12-character one-shot where
    /// any small model wins, while compression feeds a whole transcript in and
    /// pays for every chunk the summariser's window cannot hold. A large
    /// context window matters more here than raw speed.
    ///
    /// Never point this at a reasoning model. A truncated summary silently
    /// loses conversation state, which is worse than a slow one.
    var compressionModel: String
    /// When `providerID == custom`, this lets the user pin which
    /// transport-protocol family the adapter facade dispatches into.
    /// `nil` (every other preset / older config) falls back to the
    /// preset's `kind` via `providerKind` below. See
    /// `AgentProviderEntry.customKindOverride` for the persisted-side
    /// source of truth.
    var customKindOverride: AgentProviderKind?

    // Ephemeral integration provenance. Deliberately excluded from persisted settings.
    var magpieConnection: AgentMagpieIntegration.Connection? = nil
    var magpieFailure: AgentMagpieIntegration.Failure? = nil

    enum CodingKeys: String, CodingKey {
        case providerID, baseURL, model, flashModel, proModel, routingMode
        case imageDescription, apiKey, titleModel, compressionModel, customKindOverride
    }

    static let `default` = AgentConfiguration(
        providerID: AgentProviderPreset.deepSeekID,
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-flash",
        flashModel: "deepseek-v4-flash",
        proModel: "deepseek-v4-pro",
        routingMode: .auto,
        imageDescription: .default,
        apiKey: "",
        titleModel: "",
        compressionModel: ""
    )

    init(
        providerID: String,
        baseURL: String,
        model: String,
        flashModel: String? = nil,
        proModel: String? = nil,
        routingMode: AgentModelRoutingMode = .auto,
        imageDescription: AgentImageDescriptionConfiguration = .default,
        apiKey: String,
        titleModel: String = "",
        compressionModel: String = "",
        customKindOverride: AgentProviderKind? = nil
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.flashModel = flashModel ?? model
        self.proModel = proModel ?? model
        self.routingMode = routingMode
        self.imageDescription = imageDescription
        self.apiKey = apiKey
        self.titleModel = titleModel
        self.compressionModel = compressionModel
        // Override only applies to Custom — guard here too so callers
        // that forget to filter don't accidentally override a named
        // preset's kind. Matches the same defensive check in
        // `AgentProviderEntry.init`.
        self.customKindOverride = (providerID == AgentProviderPreset.customID) ? customKindOverride : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? AgentConfiguration.default.providerID
        baseURL = try container.decode(String.self, forKey: .baseURL)
        let legacyModel = try container.decodeIfPresent(String.self, forKey: .model) ?? AgentConfiguration.default.model
        model = legacyModel
        flashModel = try container.decodeIfPresent(String.self, forKey: .flashModel) ?? legacyModel
        proModel = try container.decodeIfPresent(String.self, forKey: .proModel) ?? legacyModel
        routingMode = try container.decodeIfPresent(AgentModelRoutingMode.self, forKey: .routingMode) ?? .auto
        imageDescription = try container.decodeIfPresent(AgentImageDescriptionConfiguration.self, forKey: .imageDescription) ?? .default
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        titleModel = try container.decodeIfPresent(String.self, forKey: .titleModel) ?? ""
        // New field — 1.275.0. Older configs have no key → "" → uses flashModel.
        compressionModel = try container.decodeIfPresent(String.self, forKey: .compressionModel) ?? ""
        // New field — 1.56.1. Older configs have no key → nil → uses preset kind.
        let override = try container.decodeIfPresent(AgentProviderKind.self, forKey: .customKindOverride)
        customKindOverride = (providerID == AgentProviderPreset.customID) ? override : nil
    }

    var normalized: AgentConfiguration {
        // Contract values were validated at the read boundary. Preserve complete model IDs.
        if magpieConnection != nil || magpieFailure != nil { return self }
        var result = self
        result.providerID = result.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.flashModel = result.flashModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.proModel = result.proModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.imageDescription = result.imageDescription.normalized
        result.apiKey = result.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result.titleModel = result.titleModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.compressionModel = result.compressionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Migrate retired persisted aliases before any request can use them.
        if result.providerID == AgentProviderPreset.someIMID {
            if SomeIMManagedModel.isRetired(result.model) { result.model = SomeIMManagedModel.autoFlash }
            if SomeIMManagedModel.isRetired(result.flashModel) { result.flashModel = SomeIMManagedModel.autoFlash }
            if SomeIMManagedModel.isRetired(result.proModel) { result.proModel = SomeIMManagedModel.autoPro }
            if SomeIMManagedModel.isRetired(result.titleModel) { result.titleModel = SomeIMManagedModel.autoFlash }
            if SomeIMManagedModel.isRetired(result.compressionModel) { result.compressionModel = SomeIMManagedModel.autoFlash }
        }


        let preset = AgentProviderPreset.preset(id: result.providerID)
        if preset == nil {
            result.providerID = AgentProviderPreset.customID
        }
        if result.baseURL.isEmpty {
            result.baseURL = AgentConfiguration.default.baseURL
        }
        if result.flashModel.isEmpty {
            result.flashModel = preset?.defaultFlashModel ?? result.model
        }
        if result.proModel.isEmpty {
            result.proModel = preset?.defaultProModel ?? result.model
        }
        // Detect a stale model carried over from a previous provider —
        // e.g. user had OpenAI's `gpt-3.5-16k` as flashModel, then
        // switched provider to DeepSeek in Settings. Without this check
        // the chat-mode model picker keeps offering `gpt-3.5-16k` as
        // the "route default", which is just confusing. If the model
        // string contains no hint that matches the current preset,
        // reset to that preset's documented default.
        if let preset, preset.id != AgentProviderPreset.customID {
            if !preset.recognizesModelID(result.flashModel) {
                result.flashModel = preset.defaultFlashModel
            }
            if !preset.recognizesModelID(result.proModel) {
                result.proModel = preset.defaultProModel
            }
            if !preset.recognizesModelID(result.model) {
                result.model = preset.defaultModel
            }
        }
        if result.flashModel.isEmpty {
            result.flashModel = AgentConfiguration.default.flashModel
        }
        if result.proModel.isEmpty {
            result.proModel = AgentConfiguration.default.proModel
        }
        if result.model.isEmpty {
            result.model = result.model(for: .interactive)
        }
        return result
    }

    func model(for purpose: AgentModelPurpose) -> String {
        switch purpose {
        case .compression:
            return contextCompressionModel()
        case .interactive:
            switch routingMode {
            case .auto, .flash:
                return flashModel
            case .pro:
                return proModel
            }
        }
    }

    /// Model to use for the one-shot "summarize this chat into a 12-char
    /// title" call. Returns `titleModel` if explicitly set, otherwise
    /// falls back to `flashModel` (we never run titling on `proModel` —
    /// the task is trivial and the price gap is real).
    func titleSummaryModel() -> String {
        let trimmed = titleModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? flashModel : trimmed
    }

    /// Model to use for context compression. Returns `compressionModel` if
    /// explicitly set, otherwise `flashModel` — never `proModel`, for the same
    /// reason titling doesn't: the task is mechanical and the price gap is
    /// real, and compression can fire many times in one long session.
    func contextCompressionModel() -> String {
        let trimmed = compressionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? flashModel : trimmed
    }

    func resolved(for purpose: AgentModelPurpose) -> AgentConfiguration {
        var result = normalized
        result.model = result.model(for: purpose)
        return result
    }

    var routingLabel: String {
        "\(routingMode.displayName) · \(model(for: .interactive))"
    }

    var supportsImageInput: Bool {
        guard AgentProviderPreset.preset(id: providerID)?.supportsImageInput ?? true else {
            return false
        }
        // A probe-verified gateway verdict outranks the id denylist in both
        // directions: it catches text-only models the list does not know, and
        // clears ones it guesses wrong.
        if let verdict = someIMGatewayCapabilities?.acceptsImages(over: inferenceProviderKind) {
            return verdict
        }
        return Self.modelAcceptsImageInput(model)
    }

    /// some.im's published capabilities for this model. Scoped to the some.im
    /// provider because the catalogue is keyed by model id alone: a custom
    /// provider exposing the same id is a different upstream.
    var someIMGatewayCapabilities: AgentGatewayModelCapabilities? {
        guard providerID == AgentProviderPreset.someIMID else { return nil }
        return AgentGatewayCapabilityCatalog.capabilities(forModel: model)
    }

    var requiresAPIKey: Bool {
        AgentProviderPreset.preset(id: providerID)?.requiresAPIKey ?? true
    }

    /// Model-level vision gate, layered on top of the provider preset flag.
    ///
    /// A relay provider (e.g. some.im) can host both vision and text-only
    /// models, so the provider-level `supportsImageInput` alone is not
    /// enough: sending an OpenAI `image_url` content part to a text-only
    /// model like `deepseek-v4-flash` fails the whole request with
    /// HTTP 400 "unknown variant `image_url`, expected `text`" — even when
    /// the image sits hundreds of messages back in the history.
    ///
    /// Conservative denylist: only families known to reject image parts
    /// return false; unknown models keep image support so genuinely
    /// multimodal custom models aren't degraded.
    nonisolated static func modelAcceptsImageInput(_ model: String) -> Bool {
        let lower = model.lowercased()
        // DeepSeek chat/coder models are text-only (deepseek-vl is the
        // vision family and keeps image support).
        if lower.contains("deepseek"), !lower.contains("vl") { return false }
        // some.im auto-routing text tier maps to text-only backends.
        if lower.hasPrefix("someim-auto") { return false }
        // some.im coding-plan tiers currently map to text-only backends
        // (deepseek / glm chat models). Managed routing never targets a
        // vision model, so keep the whole family text-only.
        if lower.hasPrefix("someim-coding") { return false }
        return true
    }

    /// Transport-protocol family this configuration speaks. Resolution
    /// order:
    ///   1. For the Custom preset, honour `customKindOverride` if set
    ///      (so a self-hosted Anthropic / Gemini / Responses proxy can
    ///      pick its dialect from the Settings dropdown).
    ///   2. Otherwise look up the preset's intrinsic `kind`.
    ///   3. Unrecognised providerID falls back to `.openAIChat`, which
    ///      matches the historical "everything was OpenAI-compatible"
    ///      behaviour and is safe for pre-existing user libraries.
    var providerKind: AgentProviderKind {
        if providerID == AgentProviderPreset.customID,
           let override = customKindOverride {
            return override
        }
        return AgentProviderPreset.preset(id: providerID)?.kind ?? .openAIChat
    }

    /// Transport used for model inference. GPT-family ids always use Chat
    /// Completions because several OpenAI-compatible relays expose those
    /// models without implementing the Responses `store` contract. Native
    /// Anthropic/Gemini configurations remain pinned to their own wire
    /// formats; supported DeepSeek V4 routes (Flash and Pro) keep Responses
    /// behavior.
    var inferenceProviderKind: AgentProviderKind {
        let configuredKind = providerKind
        guard configuredKind == .openAIChat || configuredKind == .openAIResponses else {
            return configuredKind
        }
        if Self.isGPTFamilyModel(model) {
            return .openAIChat
        }
        if usesDeepSeekV4ResponsesBehavior {
            return .openAIResponses
        }
        // No gateway route serves this model over the configured dialect but
        // the other OpenAI dialect has one: use it instead of sending a request
        // the gateway can only reject with capability_not_supported.
        if let fallback = someIMGatewayCapabilities?.fallbackKind(for: configuredKind) {
            return fallback
        }
        return configuredKind
    }

    nonisolated static func isGPTFamilyModel(_ model: String) -> Bool {
        let tokens = model.lowercased().split { !$0.isLetter && !$0.isNumber }
        return tokens.contains { token in
            for prefix in ["gpt", "chatgpt"] where token.hasPrefix(prefix) {
                let suffix = token.dropFirst(prefix.count)
                if suffix.isEmpty || suffix.first?.isNumber == true {
                    return true
                }
            }
            return false
        }
    }

    /// Concrete DeepSeek V4 model ids that speak the Responses API on both
    /// DeepSeek itself and the some.im gateway. Flash and Pro are the only
    /// two tiers the gateway serves natively over `/v1/responses`.
    private static let deepSeekV4ResponsesModelIDs: Set<String> = [
        "deepseek-v4-flash",
        "deepseek-v4-pro"
    ]

    /// Model ids backed by DeepSeek V4 (Flash or Pro) on the some.im gateway.
    /// The unsuffixed coding-plan id is retained for server-side/legacy aliases;
    /// managed routing selects `someim-coding-plan-low` for the low tier and
    /// `someim-coding-plan-high` / `someim-code-high` / `someim-auto-pro` for
    /// the high tier. Premium aliases resolve to non-DeepSeek backends and
    /// stay on Chat Completions.
    private static let someIMDeepSeekV4ResponsesModelIDs: Set<String> = deepSeekV4ResponsesModelIDs.union([
        SomeIMManagedModel.judge,
        SomeIMManagedModel.securityGuard,
        SomeIMManagedModel.autoFlash,
        SomeIMManagedModel.autoPro
    ])

    var isDeepSeekV4ResponsesModel: Bool {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if providerID == AgentProviderPreset.deepSeekID {
            return Self.deepSeekV4ResponsesModelIDs.contains(normalizedModel)
        }
        if providerID == AgentProviderPreset.someIMID {
            return Self.someIMDeepSeekV4ResponsesModelIDs.contains(normalizedModel)
        }
        return false
    }

    var usesDeepSeekV4ResponsesBehavior: Bool {
        isDeepSeekV4ResponsesModel
    }

    /// The some.im safety alias owns its fixed system policy on the gateway.
    /// Keeping this check provider-scoped prevents a custom provider that
    /// happens to expose the same model id from silently losing its system
    /// prompt.
    var usesServerManagedSafetyJudge: Bool {
        providerID == AgentProviderPreset.someIMID
            && model.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(SomeIMManagedModel.securityGuard) == .orderedSame
    }

    /// The some.im context compressor owns its fixed compression prompt on
    /// the gateway (replace mode). Provider-scoped for the same reason as
    /// `usesServerManagedSafetyJudge`: a custom provider exposing the same
    /// model id must not silently lose the compression instruction.
    var usesServerManagedCompressionPrompt: Bool {
        providerID == AgentProviderPreset.someIMID
            && model.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(SomeIMManagedModel.contextCompressor) == .orderedSame
    }

    var usesWillDeepGatewayResponsesState: Bool {
        providerID == AgentProviderPreset.someIMID && isDeepSeekV4ResponsesModel
    }

    var usesStatelessDeepSeekResponses: Bool {
        providerID == AgentProviderPreset.deepSeekID && isDeepSeekV4ResponsesModel
    }

    /// DeepSeek V4 Flash Responses routes can execute hosted web search in
    /// the inference service. The adapter keeps the local function tool as a
    /// compatibility fallback when an older relay explicitly rejects it.
    var prefersHostedWebSearch: Bool {
        isDeepSeekV4ResponsesModel
    }
}
