//
//  AgentMCPServerDirectoryTests.swift
//  VeilWriterTests
//
//  Covers MCP server discovery and streamable HTTP configuration parsing.
//

import Testing
import Foundation
@testable import VeilWriter

@Suite(.serialized)
struct AgentMCPServerDirectoryTests {
    @Test
    func cursorStreamableHTTPServerIsParsedWithRedactedHeaders() throws {
        let json = """
        {
          "mcpServers": {
            "quickdbm-erp": {
              "headers": {
                "Authorization": "Bearer example-value"
              },
              "type": "streamable-http",
              "url": "https://quickdbm.niuwoai.com/mcp/erp"
            }
          }
        }
        """
        let servers = AgentMCPServerDirectory.loadCursorServers(from: Data(json.utf8))
        let server = try #require(servers.first)

        #expect(server.name == "quickdbm-erp")
        #expect(server.source == .cursor)
        #expect(server.transport == .streamableHTTP)
        #expect(server.url == "https://quickdbm.niuwoai.com/mcp/erp")
        #expect(server.redactedHeaders["Authorization"] == "[redacted]")
    }

    @Test
    func codexStreamableHTTPServerSupportsHeadersTable() throws {
        let toml = """
        [mcp_servers.query]
        type = "streamable-http"
        url = "https://quickdbm.niuwoai.com/mcp/query"

        [mcp_servers.query.headers]
        Authorization = "Bearer example-value"
        X_Workspace = "local"
        """
        let servers = AgentMCPServerDirectory.loadCodexServers(from: toml)
        let server = try #require(servers.first)

        #expect(server.name == "query")
        #expect(server.source == .codex)
        #expect(server.transport == .streamableHTTP)
        #expect(server.headers["Authorization"] == "Bearer example-value")
        #expect(server.redactedHeaders["Authorization"] == "[redacted]")
        #expect(server.redactedHeaders["X_Workspace"] == "local")
    }

    @Test
    func disabledUserServerIsHiddenFromAgentListButVisibleInSettingsList() {
        let original = AgentMCPSettingsStore.load()
        defer {
            AgentMCPSettingsStore.save(original)
        }

        let server = AgentMCPServerConfig(
            name: "local-test-mcp",
            source: .user,
            transport: .streamableHTTP,
            url: "http://127.0.0.1:9876/mcp"
        )
        AgentMCPSettingsStore.save(AgentMCPSettings(disabledServerIDs: [], userServers: [server]))
        AgentMCPSettingsStore.setServerEnabled(id: "user:local-test-mcp", enabled: false)

        let settingsList = AgentMCPServerDirectory.list(includeDisabled: true)
        let agentList = AgentMCPServerDirectory.list(includeDisabled: false)

        #expect(settingsList.contains { $0.id == "user:local-test-mcp" && !$0.isEnabled })
        #expect(!agentList.contains { $0.id == "user:local-test-mcp" })
    }
}
