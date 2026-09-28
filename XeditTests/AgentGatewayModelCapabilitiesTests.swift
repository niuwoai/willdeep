//
//  AgentGatewayModelCapabilitiesTests.swift
//  WillDeepTests
//
//  some.im `/v1/model-capabilities` publishes per-protocol capabilities and
//  marks which ones an upstream probe verified. Only verified entries may
//  override the built-in id heuristics; unverified ones are usually the
//  gateway's default declaration.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentGatewayModelCapabilitiesTests {
    private static let body = #"""
    {"object":"list","data":[
      {"id":"mystery-text","capability_kinds":["llm"],"context_window":65536,
       "protocols":{
         "chat_completions":{"mode":"native","routes":1,"verified":true,"streaming":true,"function_tools":true,
                             "tool_choices":["auto"],"strict_json_schema":false,"image_input":false},
         "responses":{"mode":"bridge","routes":1,"verified":true,"streaming":true,"function_tools":true,
                      "tool_choices":["auto"],"image_input":false,"previous_response_id":false,"future":1}
       },
       "capability_verification":{"coverage":"all_verified","source":"active_probe","routes":1}},
      {"id":"deepseek-v4-flash-vision","protocols":{
         "chat_completions":{"mode":"native","verified":true,"image_input":true}}},
      {"id":"unverified-default","protocols":{
         "chat_completions":{"mode":"native","verified":false,"image_input":false}}},
      {"id":"responses-only","protocols":{"responses":{"mode":"native","verified":true}}},
      {"id":"legacy-row","context_window":128000}
    ]}
    """#

    private func discoveries() throws -> [AgentModelDiscovery] {
        try AgentSomeIMModelCapabilities.discoveries(from: Data(Self.body.utf8))
    }

    private func someIMConfig(model: String) -> AgentConfiguration {
        AgentConfiguration(
            providerID: "some-im",
            baseURL: "https://some.im/v1",
            model: model,
            flashModel: model,
            proModel: model,
            routingMode: .flash,
            imageDescription: .default,
            apiKey: "sk-test"
        )
    }

    @Test("protocols block decodes; rows without it stay nil")
    func decodesProtocols() throws {
        let rows = try discoveries()
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let text = try #require(byID["mystery-text"]?.gatewayCapabilities)
        #expect(text.coverage == "all_verified")
        #expect(text.protocols["chat_completions"]?.toolChoices == ["auto"])
        #expect(text.protocols["responses"]?.mode == "bridge")
        #expect(byID["mystery-text"]?.contextWindowTokens == 65536)
        #expect(byID["legacy-row"]?.gatewayCapabilities == nil)
        #expect(byID["legacy-row"]?.contextWindowTokens == 128_000)
    }

    @Test("persisted metadata without the new field still decodes")
    func oldPersistedMetadataDecodes() throws {
        let old = #"[{"id":"kimi-k3","isHot":true,"isNew":false,"contextWindowTokens":1000000}]"#
        let decoded = try JSONDecoder().decode([AgentModelDiscovery].self, from: Data(old.utf8))
        #expect(decoded.first?.gatewayCapabilities == nil)
        #expect(decoded.first?.contextWindowTokens == 1_000_000)
    }

    @Test("only verified entries give an image verdict")
    func imageVerdicts() throws {
        let byID = Dictionary(uniqueKeysWithValues: try discoveries().map { ($0.id, $0) })
        #expect(byID["mystery-text"]?.gatewayCapabilities?.acceptsImages(over: .openAIChat) == false)
        #expect(byID["deepseek-v4-flash-vision"]?.gatewayCapabilities?.acceptsImages(over: .openAIChat) == true)
        #expect(byID["unverified-default"]?.gatewayCapabilities?.acceptsImages(over: .openAIChat) == nil)
        #expect(byID["mystery-text"]?.gatewayCapabilities?.acceptsImages(over: .anthropicMessages) == nil)
    }

    @Test("some.im image gate follows the verified verdict, heuristics otherwise")
    func someIMImageGate() throws {
        AgentGatewayCapabilityCatalog._reset()
        defer { AgentGatewayCapabilityCatalog._reset() }

        // Before the catalogue is learned, the id denylist decides.
        #expect(someIMConfig(model: "mystery-text").supportsImageInput)
        #expect(!someIMConfig(model: "deepseek-v4-flash-vision").supportsImageInput)

        AgentGatewayCapabilityCatalog.merge(try discoveries())

        // Verified text-only model the denylist does not know.
        #expect(!someIMConfig(model: "mystery-text").supportsImageInput)
        // Verified vision model the denylist would have blocked.
        #expect(someIMConfig(model: "deepseek-v4-flash-vision").supportsImageInput)
        // Unverified default declaration must not switch images off.
        #expect(someIMConfig(model: "unverified-default").supportsImageInput)

        // A custom provider exposing the same id is a different upstream.
        var custom = someIMConfig(model: "mystery-text")
        custom.providerID = AgentProviderPreset.customID
        #expect(custom.someIMGatewayCapabilities == nil)
    }

    @Test("dialect falls back only when the gateway cannot serve the configured one")
    func dialectFallback() throws {
        AgentGatewayCapabilityCatalog._reset()
        defer { AgentGatewayCapabilityCatalog._reset() }
        AgentGatewayCapabilityCatalog.merge(try discoveries())

        #expect(someIMConfig(model: "responses-only").inferenceProviderKind == .openAIResponses)
        #expect(someIMConfig(model: "mystery-text").inferenceProviderKind == .openAIChat)
        // No protocols published: nothing to fall back on.
        #expect(someIMConfig(model: "legacy-row").inferenceProviderKind == .openAIChat)

        let caps = try #require(
            AgentGatewayCapabilityCatalog.capabilities(forModel: "RESPONSES-ONLY")
        )
        #expect(caps.fallbackKind(for: .anthropicMessages) == nil)
    }

    @Test("rows without capabilities leave learned entries alone")
    func mergeDoesNotDemote() throws {
        AgentGatewayCapabilityCatalog._reset()
        defer { AgentGatewayCapabilityCatalog._reset() }
        AgentGatewayCapabilityCatalog.merge(try discoveries())
        AgentGatewayCapabilityCatalog.merge([
            AgentModelDiscovery(id: "mystery-text", isHot: false, isNew: false, contextWindowTokens: nil)
        ])
        #expect(AgentGatewayCapabilityCatalog.capabilities(forModel: "mystery-text") != nil)
    }
}
