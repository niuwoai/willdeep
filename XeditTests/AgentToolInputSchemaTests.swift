import Foundation
import Testing
@testable import WillDeep

/// 插件 MCP 工具把自己的参数表交给模型（1.410.0-rc1），以及工具目录的后台预热判定。
@Suite
@MainActor
struct AgentToolInputSchemaTests {
    /// 短剧工坊 `episode.generate_frames` 的参数表形状（节选）。
    private let framesSchema: [String: Any] = [
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "properties": [
            "dramaID": ["type": "string"],
            "episodeID": ["type": "string"],
            "target": ["type": "string", "enum": ["start", "end", "both"]],
            "countPerModel": ["type": "integer", "minimum": 1, "maximum": 4],
            "shotOrders": ["type": "array", "items": ["type": "integer"]],
            "$comment": ["type": "string", "description": "a property whose name looks like a keyword"],
            "settings": ["$ref": "#/$defs/settings", "description": "batch settings"]
        ],
        "required": ["dramaID", "episodeID"],
        "$defs": [
            "settings": [
                "type": "object",
                "properties": ["onlyMissing": ["type": "boolean"]],
                "examples": [["onlyMissing": true]]
            ]
        ]
    ]

    @Test("normalization drops unsupported keywords, inlines local refs and keeps property names verbatim")
    func normalizesInputSchema() throws {
        let schema = try #require(AgentToolInputSchema.normalized(framesSchema))
        #expect(schema["$schema"] == nil)
        #expect(schema["$defs"] == nil)
        #expect(schema["type"] as? String == "object")
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["$comment"] != nil)
        let settings = try #require(properties["settings"] as? [String: Any])
        #expect(settings["description"] as? String == "batch settings")
        #expect(settings["examples"] == nil)
        #expect((settings["properties"] as? [String: Any])?["onlyMissing"] != nil)
        #expect(schema["required"] as? [String] == ["dramaID", "episodeID"])
        let target = try #require(properties["target"] as? [String: Any])
        #expect(target["enum"] as? [String] == ["start", "end", "both"])
    }

    @Test("oneOf becomes anyOf; non-object roots and unparsable text are refused")
    func refusesWhatProvidersCannotTake() {
        let union = AgentToolInputSchema.normalized([
            "type": "object",
            "properties": ["value": ["oneOf": [["type": "string"], ["type": "integer"]]]]
        ])
        let value = (union?["properties"] as? [String: Any])?["value"] as? [String: Any]
        #expect(value?["anyOf"] != nil)
        #expect(value?["oneOf"] == nil)
        #expect(AgentToolInputSchema.normalized(["type": "string"]) == nil)
        #expect(AgentToolInputSchema.normalized("not json") == nil)
        // 没写 properties 的对象补一个空表，接口才认。
        let bare = AgentToolInputSchema.normalized(["type": "object"])
        #expect((bare?["properties"] as? [String: Any])?.isEmpty == true)
    }

    @Test("oversized schemas lose nested descriptions first, then fall back to arguments_json")
    func capsSchemaSize() {
        let long = String(repeating: "很长的说明。", count: 400)
        var nested: [String: Any] = [:]
        for index in 0..<6 { nested["field\(index)"] = ["type": "string", "description": long] }
        let trimmed = AgentToolInputSchema.normalized([
            "type": "object",
            "properties": ["outer": ["type": "object", "description": "kept", "properties": nested]]
        ])
        let outer = (trimmed?["properties"] as? [String: Any])?["outer"] as? [String: Any]
        #expect(outer?["description"] as? String == "kept")
        let field = (outer?["properties"] as? [String: Any])?["field0"] as? [String: Any]
        #expect(field?["description"] == nil)

        var huge: [String: Any] = [:]
        for index in 0..<40 { huge["field\(index)"] = ["type": "string", "description": long] }
        #expect(AgentToolInputSchema.normalized(["type": "object", "properties": huge]) == nil)
    }

    @Test("Gemini gets the OpenAPI subset, and free-form objects fall back")
    func convertsForGemini() throws {
        let schema = try #require(AgentToolInputSchema.normalized(framesSchema))
        let gemini = try #require(AgentToolInputSchema.gemini(schema))
        #expect(gemini["type"] as? String == "OBJECT")
        let properties = try #require(gemini["properties"] as? [String: Any])
        #expect((properties["countPerModel"] as? [String: Any])?["type"] as? String == "INTEGER")
        #expect(((properties["shotOrders"] as? [String: Any])?["items"] as? [String: Any])?["type"] as? String == "INTEGER")
        let nullable = AgentToolInputSchema.gemini([
            "type": "object",
            "properties": ["note": ["type": ["string", "null"]]]
        ])
        #expect(((nullable?["properties"] as? [String: Any])?["note"] as? [String: Any])?["nullable"] as? Bool == true)
        let freeForm = AgentToolInputSchema.gemini([
            "type": "object",
            "properties": ["package": ["type": "object"]]
        ])
        #expect(freeForm == nil)
    }

    @Test("the catalog keeps each tool's schema and the descriptor carries it to the model client")
    func catalogCarriesSchemaToAnthropic() throws {
        let sandbox = try #require(UserDefaults(suiteName: "AgentToolInputSchemaTests-\(UUID().uuidString)"))
        AgentPluginMCPToolCatalog._setTestDefaultsOverride(sandbox)
        defer { AgentPluginMCPToolCatalog._setTestDefaultsOverride(nil) }
        let schemaData = try JSONSerialization.data(withJSONObject: framesSchema)
        let payload = """
        {"tools":[{"name":"episode.generate_frames","description":"Generate frames","inputSchema":\(String(decoding: schemaData, as: UTF8.self))},
                  {"name":"drama.list","description":"List dramas"}]}
        """
        let tools = try #require(AgentPluginMCPToolCatalog.parseTools(from: payload, serverName: "video-studio"))
        #expect(tools[0].inputSchema != nil)
        #expect(tools[1].inputSchema == nil) // 没写 inputSchema 的工具退回 arguments_json。

        AgentPluginMCPToolCatalog.record(
            serverID: "plugin:video-studio:video-studio", pluginID: "video-studio",
            serverName: "video-studio", listToolsPayload: payload, packageDigest: "digest-a"
        )
        let server = AgentMCPServerConfig(
            id: "plugin:video-studio:video-studio", name: "video-studio", source: .plugin,
            transport: .stdio, command: "/usr/bin/true", args: [], env: [:], startupTimeout: 10
        )
        let descriptors = AgentPluginMCPToolCatalog.descriptors(activeServers: [server])
        let frames = try #require(descriptors.first { $0.name == "mcp__video-studio__episode_generate_frames" })
        #expect(frames.inputSchemaJSON != nil)
        #expect(frames.parameters.map(\.name) == ["arguments_json"])

        let data = try AnthropicMessagesAdapter.encodeRequestBody(
            model: "claude-test", messages: [AgentMessage(role: .user, content: "hi")],
            tools: [frames], supportsImages: false
        )
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require((body["tools"] as? [[String: Any]])?.first)
        let inputSchema = try #require(encoded["input_schema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        #expect(properties["countPerModel"] != nil)
        #expect(properties["arguments_json"] == nil)
    }

    @Test("an old catalog entry without schema or digest still decodes")
    func decodesOldCatalogEntries() throws {
        let old = #"{"pluginID":"p","serverName":"s","tools":[{"rawName":"a.b","exposedName":"mcp__s__a_b","description":""}]}"#
        let decoded = try JSONDecoder().decode(AgentPluginMCPToolCatalog.ServerTools.self, from: Data(old.utf8))
        #expect(decoded.packageDigest == nil)
        #expect(decoded.tools.first?.inputSchema == nil)
    }

    @Test("model arguments go to MCP with whole numbers as integers")
    func convertsArgumentsForMCP() throws {
        let value = AgentJSONValue.object([
            "order": .number(3), "ratio": .number(0.5), "orders": .array([.number(1), .number(2)]), "dryRun": .bool(true)
        ])
        let foundation = try #require(value.foundationValue as? [String: Any])
        #expect(foundation["order"] as? Int == 3)
        #expect(foundation["ratio"] as? Double == 0.5)
        #expect(foundation["orders"] as? [Int] == [1, 2])
        let data = try JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self).contains("\"order\":3"))
    }

    @Test("warmup asks again only when the entry is missing or the plugin package changed")
    func warmupRefreshDecision() {
        let entry = AgentPluginMCPToolCatalog.ServerTools(pluginID: "p", serverName: "s", tools: [], packageDigest: "a")
        #expect(AgentPluginMCPToolWarmup.needsRefresh(cached: nil, currentDigest: "a"))
        #expect(!AgentPluginMCPToolWarmup.needsRefresh(cached: entry, currentDigest: "a"))
        #expect(AgentPluginMCPToolWarmup.needsRefresh(cached: entry, currentDigest: "b"))
        let legacy = AgentPluginMCPToolCatalog.ServerTools(pluginID: "p", serverName: "s", tools: [])
        #expect(AgentPluginMCPToolWarmup.needsRefresh(cached: legacy, currentDigest: "a"))
    }
}
