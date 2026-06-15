//
//  AgentMCPServerDirectoryTests.swift
//  WillDeepTests
//
//  Covers MCP server discovery and streamable HTTP configuration parsing.
//

import Testing
import Foundation
@testable import WillDeep

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

    // CI-skipped: writes a secret to the login keychain and reads it back.
    // GitHub's shared macOS runners often have no unlocked keychain in the
    // headless session, so `AgentCredentialStore.resolve` intermittently
    // returns "" and this flakes. The credential-reference logic is exercised
    // fully on a real machine (and locally). Not a product bug. Gate on
    // GITHUB_ACTIONS so it still runs in every developer's local test pass.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil))
    func userServerSecretsAreStoredAsKeychainReferences() throws {
        let suiteName = "willdeep-mcp-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let keychainService = AgentCredentialStore._setTestKeychainServiceOverride(suiteName)
        AgentMCPSettingsStore._setTestDefaultsOverride(defaults)
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
            AgentMCPSettingsStore._setTestDefaultsOverride(nil)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let server = AgentMCPServerConfig(
            name: "secure-mcp",
            source: .user,
            transport: .streamableHTTP,
            url: "https://example.com/mcp",
            headers: [
                "Authorization": "Bearer test-secret",
                "X-Workspace": "local"
            ]
        )

        AgentMCPSettingsStore.upsertUserServer(server)
        let stored = try #require(AgentMCPSettingsStore.load().userServers.first)
        let authorization = try #require(stored.headers["Authorization"])

        #expect(keychainService == suiteName)
        #expect(authorization.hasPrefix(AgentCredentialStore.referencePrefix))
        #expect(authorization != "Bearer test-secret")
        #expect(stored.headers["X-Workspace"] == "local")
        #expect(stored.redactedHeaders["Authorization"] == "[redacted]")
        #expect(AgentCredentialStore.resolve(authorization) == "Bearer test-secret")

        let account = String(authorization.dropFirst(AgentCredentialStore.referencePrefix.count))
        let updated = AgentMCPServerConfig(
            name: "secure-mcp",
            source: .user,
            transport: .streamableHTTP,
            url: "https://example.com/mcp",
            headers: ["X-Workspace": "local"]
        )
        AgentMCPSettingsStore.upsertUserServer(updated)
        #expect(AgentCredentialStore.load(account: account).isEmpty)
    }
}
