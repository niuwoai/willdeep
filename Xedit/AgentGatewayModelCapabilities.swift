//
//  AgentGatewayModelCapabilities.swift
//  WillDeep
//
//  Per-protocol capabilities the some.im gateway publishes on
//  `/v1/model-capabilities` (`protocols` + `capability_verification`).
//

import Foundation

/// What the gateway says one model can do over each inbound protocol.
///
/// Only `verified == true` entries are authority. An unverified entry is
/// usually the gateway's default declaration (text-only modalities, every
/// tool_choice form), so reading its `false` as "unsupported" would switch
/// off features that work. Callers therefore get `nil` — "no verdict, keep
/// your own heuristic" — unless the gateway backs the answer with a probe.
nonisolated struct AgentGatewayModelCapabilities: Codable, Equatable, Sendable {
    nonisolated struct ProtocolCapability: Codable, Equatable, Sendable {
        var mode: String
        var verified: Bool
        var streaming: Bool
        var functionTools: Bool
        var toolChoices: [String]
        var strictJSONSchema: Bool
        var imageInput: Bool

        init(
            mode: String = "",
            verified: Bool = false,
            streaming: Bool = false,
            functionTools: Bool = false,
            toolChoices: [String] = [],
            strictJSONSchema: Bool = false,
            imageInput: Bool = false
        ) {
            self.mode = mode
            self.verified = verified
            self.streaming = streaming
            self.functionTools = functionTools
            self.toolChoices = toolChoices
            self.strictJSONSchema = strictJSONSchema
            self.imageInput = imageInput
        }

        /// Every field is optional on the wire: a newer gateway may drop or add
        /// fields, and one odd entry must not cost the whole catalogue.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = (try? container.decodeIfPresent(String.self, forKey: .mode)) ?? ""
            verified = (try? container.decodeIfPresent(Bool.self, forKey: .verified)) ?? false
            streaming = (try? container.decodeIfPresent(Bool.self, forKey: .streaming)) ?? false
            functionTools = (try? container.decodeIfPresent(Bool.self, forKey: .functionTools)) ?? false
            toolChoices = (try? container.decodeIfPresent([String].self, forKey: .toolChoices)) ?? []
            strictJSONSchema = (try? container.decodeIfPresent(Bool.self, forKey: .strictJSONSchema)) ?? false
            imageInput = (try? container.decodeIfPresent(Bool.self, forKey: .imageInput)) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case mode, verified, streaming
            case functionTools = "function_tools"
            case toolChoices = "tool_choices"
            case strictJSONSchema = "strict_json_schema"
            case imageInput = "image_input"
        }
    }

    static let chatCompletionsKey = "chat_completions"
    static let responsesKey = "responses"
    static let anthropicMessagesKey = "anthropic_messages"

    /// Keyed by gateway protocol name (`chat_completions`, `responses`,
    /// `anthropic_messages`). A missing key means no route can serve it.
    var protocols: [String: ProtocolCapability]
    /// `all_verified` / `partial` / `unverified`; empty when not reported.
    var coverage: String

    static func protocolKey(for kind: AgentProviderKind) -> String? {
        switch kind {
        case .openAIChat: return chatCompletionsKey
        case .openAIResponses: return responsesKey
        case .anthropicMessages: return anthropicMessagesKey
        default: return nil
        }
    }

    func capability(for kind: AgentProviderKind) -> ProtocolCapability? {
        Self.protocolKey(for: kind).flatMap { protocols[$0] }
    }

    /// Probe-backed answer to "can this model take image input over `kind`",
    /// or nil when the gateway has no verified verdict.
    func acceptsImages(over kind: AgentProviderKind) -> Bool? {
        guard let capability = capability(for: kind), capability.verified else { return nil }
        return capability.imageInput
    }

    /// When no gateway route can serve `kind` for this model but another
    /// OpenAI dialect can, the dialect to use instead. Only Chat Completions
    /// and Responses are swapped: those two share credentials, base URL and
    /// the rest of the adapter stack, so switching between them is safe.
    func fallbackKind(for kind: AgentProviderKind) -> AgentProviderKind? {
        guard !protocols.isEmpty,
              kind == .openAIChat || kind == .openAIResponses,
              capability(for: kind) == nil else { return nil }
        let other: AgentProviderKind = kind == .openAIChat ? .openAIResponses : .openAIChat
        return capability(for: other) == nil ? nil : other
    }
}

/// Process-wide lookup of gateway capabilities, filled from
/// `AgentModelDiscovery` rows exactly like `AgentModelContextWindowCatalog`,
/// so the nonisolated configuration gates can consult it without touching the
/// main actor or UserDefaults.
nonisolated enum AgentGatewayCapabilityCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: AgentGatewayModelCapabilities] = [:]

    static func capabilities(forModel model: String) -> AgentGatewayModelCapabilities? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    /// Rows without capabilities leave previously learned ones alone, the
    /// same rule the context-window table follows.
    static func merge(_ discoveries: [AgentModelDiscovery]) {
        let reported = discoveries.compactMap { discovery -> (String, AgentGatewayModelCapabilities)? in
            guard let capabilities = discovery.gatewayCapabilities, !capabilities.protocols.isEmpty else {
                return nil
            }
            let key = discovery.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return key.isEmpty ? nil : (key, capabilities)
        }
        guard !reported.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (key, capabilities) in reported {
            entries[key] = capabilities
        }
    }

    /// Test-only: drop everything learned so a case can assert the fallback.
    static func _reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
