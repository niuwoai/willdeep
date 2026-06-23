//
//  AgentMCPBridgeCoreTests.swift
//  XeditTests
//
//  Covers the pure, testable surface of AgentMCPBridge and friends:
//  AgentMCPServerConfig init normalization (whitespace + clamps),
//  AgentMCPSettings.normalized (id rewriting + dedupe), the redacted
//  value heuristic that keeps secrets out of the UI, parseToolCount,
//  and prettyJSON's truncation + sort behavior.
//
//  Process/Network paths (stdio JSON-RPC, SSE HTTP) live behind private
//  helpers and are out of scope for unit tests — they require a fixture
//  Process or a URLSession stub, which would 4x the file. We exercise
//  everything that's reachable from the public/internal seam.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentMCPBridgeCoreTests {

    // MARK: - AgentMCPServerConfig init normalization

    /// Init trims whitespace from name / command / url so persisted
    /// configs from imported tools don't carry stray spaces.
    @Test
    func serverConfigInitTrimsWhitespace() {
        let server = AgentMCPServerConfig(
            name: "  github  ",
            source: .user,
            transport: .stdio,
            command: "  /usr/local/bin/mcp-github  ",
            url: "  https://example.com/mcp  "
        )
        #expect(server.name == "github")
        #expect(server.command == "/usr/local/bin/mcp-github")
        #expect(server.url == "https://example.com/mcp")
    }

    /// startupTimeout is clamped to 1...180 — values outside the band
    /// would either deadlock the stdio loop or feel instant-buggy.
    @Test
    func serverConfigClampsStartupTimeout() {
        let tooSmall = AgentMCPServerConfig(name: "a", source: .user, transport: .stdio, startupTimeout: 0)
        let tooBig   = AgentMCPServerConfig(name: "b", source: .user, transport: .stdio, startupTimeout: 1_000_000)
        let okValue  = AgentMCPServerConfig(name: "c", source: .user, transport: .stdio, startupTimeout: 25)
        #expect(tooSmall.startupTimeout == 1)
        #expect(tooBig.startupTimeout == 180)
        #expect(okValue.startupTimeout == 25)
    }

    /// When no explicit id is given, it's derived from `source:name`.
    /// Source + name together uniquely identify a server in the merged
    /// list, so the default id keeps the dedupe logic deterministic.
    @Test
    func serverConfigDerivesDefaultID() {
        let server = AgentMCPServerConfig(name: "foo", source: .cursor, transport: .stdio)
        #expect(server.id == "cursor:foo")
    }

    /// Explicit id wins over the source:name default.
    @Test
    func serverConfigPreservesExplicitID() {
        let server = AgentMCPServerConfig(id: "user:override", name: "foo", source: .user, transport: .stdio)
        #expect(server.id == "user:override")
    }

    // MARK: - AgentMCPSettings.normalized

    /// disabledServerIDs collapses to a unique, sorted, non-empty set.
    /// The on-disk shape can drift over time as the user toggles
    /// servers; normalize keeps it canonical for diff equality.
    @Test
    func settingsNormalizationDedupesAndSortsDisabledIDs() {
        let raw = AgentMCPSettings(
            disabledServerIDs: ["b", "a", "b", "", "c"],
            userServers: []
        )
        #expect(raw.normalized.disabledServerIDs == ["a", "b", "c"])
    }

    /// userServers get their `source` forced to `.user` and their id
    /// rewritten to `user:<name>` — that's how the dedupe-by-source
    /// path keeps user overrides ahead of imported configs.
    @Test
    func settingsNormalizationForcesUserSourceAndIDPrefix() {
        let server = AgentMCPServerConfig(
            id: "cursor:foo",       // wrong prefix on purpose
            name: "foo",
            source: .cursor,        // wrong source on purpose
            transport: .stdio
        )
        let settings = AgentMCPSettings(disabledServerIDs: [], userServers: [server]).normalized
        #expect(settings.userServers.first?.source == .user)
        #expect(settings.userServers.first?.id == "user:foo")
    }

    // MARK: - Redaction

    /// Any header/env key containing the words `token` / `secret` /
    /// `password` / `key`, or the exact words `authorization` /
    /// `cookie`, gets redacted. The UI uses this to render the server
    /// detail sheet without ever rendering live credentials.
    @Test
    func redactedValueMasksSensitiveKeys() {
        let pairs: [(String, String, String)] = [
            ("Authorization", "Bearer xyz", "[redacted]"),
            ("authorization", "Bearer xyz", "[redacted]"),
            ("X-Api-Token",   "abcdef",     "[redacted]"),
            ("MY_SECRET",     "shh",        "[redacted]"),
            ("DB_PASSWORD",   "hunter2",    "[redacted]"),
            ("Cookie",        "sid=1",      "[redacted]"),
            ("OPENAI_API_KEY","sk-1",       "[redacted]")
        ]
        for (key, value, expected) in pairs {
            #expect(AgentMCPServerConfig.redactedValue(for: key, value: value) == expected,
                    "key \(key) should be redacted")
        }
    }

    /// Non-sensitive keys pass through unchanged so the UI can render
    /// them for debugging.
    @Test
    func redactedValueLeavesOrdinaryKeysAlone() {
        #expect(AgentMCPServerConfig.redactedValue(for: "Accept", value: "json") == "json")
        #expect(AgentMCPServerConfig.redactedValue(for: "X-Trace-Id", value: "abc") == "abc")
    }

    /// `redactedHeaders` / `redactedEnv` apply the same rule across the
    /// whole dictionary — instance-level wrapper that the detail sheet
    /// reads from.
    @Test
    func redactedHeadersAppliesRuleAcrossDictionary() {
        let server = AgentMCPServerConfig(
            name: "x",
            source: .user,
            transport: .streamableHTTP,
            url: "https://example.com",
            headers: [
                "Authorization": "Bearer xyz",
                "X-Trace-Id":    "abc"
            ]
        )
        #expect(server.redactedHeaders["Authorization"] == "[redacted]")
        #expect(server.redactedHeaders["X-Trace-Id"]    == "abc")
    }

    // MARK: - Transport / Source Codable

    /// Transport raw values are part of the persisted MCP config; lock
    /// them in so a rename can't silently brick old configs.
    @Test
    func transportRawValuesAreStable() {
        #expect(AgentMCPTransport.stdio.rawValue == "stdio")
        #expect(AgentMCPTransport.streamableHTTP.rawValue == "streamable-http")
    }

    /// Source raw values are referenced from default ids + dedupe rank
    /// — same stability requirement.
    @Test
    func sourceRawValuesAreStable() {
        #expect(AgentMCPServerSource.user.rawValue == "user")
        #expect(AgentMCPServerSource.cursor.rawValue == "cursor")
        #expect(AgentMCPServerSource.codex.rawValue == "codex")
    }

    /// Playwright MCP is intentionally launched through npx with `-y`
    /// so first use downloads @playwright/mcp without stopping at the
    /// interactive "Ok to proceed?" prompt.
    @Test
    func playwrightPresetUsesNonInteractiveNpx() {
        let server = AgentMCPServerPreset.playwright.server

        #expect(server.name == "playwright")
        #expect(server.transport == .stdio)
        #expect(server.command == "/usr/bin/env")
        #expect(server.args == ["npx", "-y", "@playwright/mcp@latest"])
        #expect(server.env.isEmpty)
        #expect(server.startupTimeout == 90)
    }

    /// China mirror mode should not switch package managers. It stays on
    /// npx and only injects npm_config_registry, which npm/npx honor.
    @Test
    func playwrightChinaMirrorPresetUsesNpmRegistryEnvOnly() {
        let server = AgentMCPServerPreset.playwrightChinaMirror.server

        #expect(server.command == "/usr/bin/env")
        #expect(server.args == ["npx", "-y", "@playwright/mcp@latest"])
        #expect(server.env == ["npm_config_registry": "https://registry.npmmirror.com"])
    }

    // MARK: - parseToolCount

    /// `parseToolCount` returns the length of the `tools` array. The
    /// payload comes back from a real MCP server, so we feed it the
    /// minimum shape it cares about.
    @Test
    func parseToolCountReadsToolsArrayLength() {
        let payload = """
        {"tools": [{"name":"a"}, {"name":"b"}, {"name":"c"}]}
        """
        #expect(AgentMCPBridge.parseToolCount(from: payload) == 3)
    }

    /// Empty `tools` is a valid response — count is 0, not nil.
    @Test
    func parseToolCountAcceptsEmptyToolsArray() {
        #expect(AgentMCPBridge.parseToolCount(from: "{\"tools\": []}") == 0)
    }

    /// Malformed JSON / missing `tools` key → nil, so the caller can
    /// fall through to a sensible "unknown" badge.
    @Test
    func parseToolCountReturnsNilForBadShape() {
        #expect(AgentMCPBridge.parseToolCount(from: "not json") == nil)
        #expect(AgentMCPBridge.parseToolCount(from: "{}") == nil)
        #expect(AgentMCPBridge.parseToolCount(from: "{\"tools\": \"oops\"}") == nil)
    }

    // MARK: - prettyJSON

    /// `prettyJSON` returns sorted-key pretty output for valid JSON
    /// objects — the detail sheet relies on the ordering being stable
    /// so the diff between two server responses is meaningful.
    @Test
    func prettyJSONSortsKeysAndIndents() {
        let dict: [String: Any] = ["b": 2, "a": 1]
        let out = AgentMCPBridge.prettyJSON(dict)
        // keys appear in sorted order
        guard let aIdx = out.range(of: "\"a\""), let bIdx = out.range(of: "\"b\"") else {
            Issue.record("expected both keys in output")
            return
        }
        #expect(aIdx.lowerBound < bIdx.lowerBound)
        #expect(out.contains("\n")) // pretty-printed = at least one newline
    }

    /// Long payloads are truncated with a `[truncated]` marker to keep
    /// the UI scrollable. Anything past 48k chars is dropped.
    @Test
    func prettyJSONTruncatesPayloadsOver48KChars() {
        let value = String(repeating: "x", count: 100_000)
        let out = AgentMCPBridge.prettyJSON(["data": value])
        #expect(out.contains("[truncated]"))
        #expect(out.count < value.count + 200)
    }

    /// Non-JSON-serializable input falls back to a description string
    /// rather than crashing the assistant turn.
    @Test
    func prettyJSONHandlesNonSerializableInput() {
        let out = AgentMCPBridge.prettyJSON(Date(timeIntervalSince1970: 0))
        #expect(!out.isEmpty)
        #expect(!out.contains("[truncated]"))
    }
}
