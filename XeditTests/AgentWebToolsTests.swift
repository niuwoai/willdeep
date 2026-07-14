//
//  AgentWebToolsTests.swift
//  XeditTests
//
//  Network-free coverage for the web_search / web_fetch tool layer:
//  SSRF host denylist, URL validation, the HTML→text reducer, Exa /
//  Brave response formatting, and the registry / authorization /
//  subagent wiring invariants.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct AgentWebToolsTests {

    // MARK: - Registry wiring

    @Test
    func webToolsAreRegisteredWithExpectedRisks() throws {
        let search = try #require(AgentToolRegistry.descriptor(for: "web_search"))
        #expect(search.risk == .read)
        #expect(search.parameters.contains { $0.name == "query" && $0.required })
        #expect(search.description.contains("Exa"))
        #expect(search.description.contains("Brave"))
        #expect(search.description.contains("some.im managed search"))

        let fetch = try #require(AgentToolRegistry.descriptor(for: "web_fetch"))
        #expect(fetch.risk == .write)
        #expect(fetch.parameters.contains { $0.name == "url" && $0.required })
    }

    /// Subagents may search (read tier) but must not fetch arbitrary
    /// URLs — there is no approval UI in the child loop.
    @Test
    func subagentAllowlistIncludesSearchButNotFetch() {
        #expect(AgentSubagentRunner.allowedToolNames.contains("web_search"))
        #expect(!AgentSubagentRunner.allowedToolNames.contains("web_fetch"))
    }

    // MARK: - Always-allow signature

    @Test
    func webFetchSignatureScopesByLowercasedHost() {
        let signature = AgentToolAuthorization.signature(
            toolName: "web_fetch",
            arguments: ["url": .string("https://Docs.Example.COM/guide/page?x=1")]
        )
        #expect(signature == "web_fetch:docs.example.com")
    }

    @Test
    func webFetchSignatureNilWithoutHost() {
        #expect(AgentToolAuthorization.signature(toolName: "web_fetch", arguments: [:]) == nil)
        #expect(AgentToolAuthorization.signature(
            toolName: "web_fetch",
            arguments: ["url": .string("not a url")]
        ) == nil)
    }

    // MARK: - SSRF guard

    @Test
    func blockedHostsAreRefused() {
        let blocked = [
            "localhost", "api.localhost", "printer.local", "vault.internal",
            "nas.home.arpa",
            "127.0.0.1", "127.8.8.8", "0.0.0.0", "10.0.0.5",
            "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
            "::1", "::", "[::1]", "fd00::1", "fe80::abcd",
            "::ffff:10.0.0.1",
        ]
        for host in blocked {
            #expect(AgentWebTools.isBlockedHost(host), "expected \(host) to be blocked")
        }
    }

    @Test
    func publicHostsAreAllowed() {
        let allowed = [
            "example.com", "api.exa.ai", "api.search.brave.com", "8.8.8.8",
            "172.32.0.1", "172.15.0.1", "192.169.1.1",
            "2606:4700::6810:84e5",
        ]
        for host in allowed {
            #expect(!AgentWebTools.isBlockedHost(host), "expected \(host) to be allowed")
        }
    }

    @Test
    func validatedPublicURLChecksSchemeAndHost() {
        #expect(AgentWebTools.validatedPublicURL("https://example.com/page") != nil)
        #expect(AgentWebTools.validatedPublicURL("http://example.com") != nil)
        #expect(AgentWebTools.validatedPublicURL("ftp://example.com") == nil)
        #expect(AgentWebTools.validatedPublicURL("file:///etc/passwd") == nil)
        #expect(AgentWebTools.validatedPublicURL("https://localhost/admin") == nil)
        #expect(AgentWebTools.validatedPublicURL("http://169.254.169.254/latest/meta-data/") == nil)
        #expect(AgentWebTools.validatedPublicURL("not a url") == nil)
    }

    // MARK: - HTML reducer

    @Test
    func extractsTitleAndDropsScriptStyle() {
        let html = """
        <!DOCTYPE html><html><head><title>My &amp; Page</title>
        <style>body { color: red }</style></head>
        <body><script>alert("nope")</script>
        <h1>Heading</h1><p>First paragraph.</p>
        <ul><li>one</li><li>two</li></ul>
        </body></html>
        """
        let extraction = AgentWebTools.extractReadableText(fromHTML: html)
        #expect(extraction.title == "My & Page")
        #expect(!extraction.text.contains("alert"))
        #expect(!extraction.text.contains("color: red"))
        #expect(extraction.text.contains("Heading"))
        #expect(extraction.text.contains("First paragraph."))
        #expect(extraction.text.contains("- one"))
        #expect(extraction.text.contains("- two"))
    }

    @Test
    func decodesNamedAndNumericEntities() {
        let decoded = AgentWebTools.decodeHTMLEntities("a &lt;b&gt; &amp;amp; &#65; &#x42; &nbsp;c")
        // "&amp;amp;" decodes exactly one layer: &lt; → <, then &amp; → &
        // last, so the literal "amp;" remains — no double decoding.
        #expect(decoded == "a <b> &amp; A B  c")
    }

    @Test
    func looksLikeHTMLDetectsDocuments() {
        #expect(AgentWebTools.looksLikeHTML("<!DOCTYPE html><html><body>x</body></html>"))
        #expect(AgentWebTools.looksLikeHTML("  <HTML lang=\"en\">"))
        #expect(!AgentWebTools.looksLikeHTML("{\"json\": true}"))
        #expect(!AgentWebTools.looksLikeHTML("plain text with a < b comparison"))
    }

    @Test
    func collapsesWhitespaceAndBlankRuns() {
        let html = "<p>a</p>\n\n\n\n<p>b    c</p>"
        let extraction = AgentWebTools.extractReadableText(fromHTML: html)
        #expect(extraction.text == "a\n\nb c")
    }

    // MARK: - Exa response formatting

    private let exaFixture = """
    {
      "results": [
        {
          "title": "Swift.org - <strong>Welcome</strong>",
          "url": "https://swift.org/",
          "publishedDate": "2026-01-02",
          "author": "Swift Team",
          "highlights": ["Swift is a <strong>general-purpose</strong> language &amp; more."]
        },
        {
          "title": "The Swift Programming Language",
          "url": "https://docs.swift.org/swift-book/",
          "summary": "Official book."
        }
      ],
      "costDollars": { "total": 0.00123 }
    }
    """

    @Test
    func formatsExaResultsWithHighlightsAndMetadata() throws {
        let result = try AgentWebTools.formatExaResults(
            data: Data(exaFixture.utf8),
            query: "swift language"
        )
        #expect(result.summary.contains("2 Exa results"))
        #expect(result.payload.contains("Web search results for \"swift language\" (Exa):"))
        #expect(result.payload.contains("1. Swift.org - Welcome"))
        #expect(result.payload.contains("https://swift.org/"))
        #expect(result.payload.contains("published: 2026-01-02"))
        #expect(result.payload.contains("author: Swift Team"))
        #expect(result.payload.contains("general-purpose language & more"))
        #expect(result.payload.contains("Provider cost estimate: $0.001230"))
        #expect(!result.payload.contains("<strong>"))
        #expect(result.references.map(\.url) == ["https://swift.org/", "https://docs.swift.org/swift-book/"])
        #expect(result.references.map(\.title) == ["Swift.org - Welcome", "The Swift Programming Language"])
    }

    @Test
    func emptyExaResultsReturnFriendlyMessage() throws {
        let result = try AgentWebTools.formatExaResults(
            data: Data("{\"results\": []}".utf8),
            query: "nothing"
        )
        #expect(result.payload.contains("no results"))
    }

    @Test
    func malformedExaResponseThrows() {
        #expect(throws: AgentToolError.self) {
            _ = try AgentWebTools.formatExaResults(
                data: Data("not json".utf8),
                query: "x"
            )
        }
    }

    // MARK: - Brave response formatting

    private let braveFixture = """
    {
      "web": {
        "results": [
          {
            "title": "Swift.org - <strong>Welcome</strong>",
            "url": "https://swift.org/",
            "description": "Swift is a <strong>general-purpose</strong> language &amp; more."
          },
          {
            "title": "The Swift Programming Language",
            "url": "https://docs.swift.org/swift-book/",
            "description": "Official book."
          }
        ]
      }
    }
    """

    @Test
    func formatsBraveResultsStrippingMarkup() throws {
        let result = try AgentWebTools.formatBraveResults(
            data: Data(braveFixture.utf8),
            query: "swift language"
        )
        #expect(result.summary.contains("2 results"))
        #expect(result.payload.contains("1. Swift.org - Welcome"))
        #expect(result.payload.contains("https://swift.org/"))
        #expect(result.payload.contains("general-purpose language & more"))
        #expect(result.payload.contains("2. The Swift Programming Language"))
        #expect(!result.payload.contains("<strong>"))
        #expect(result.references.map(\.url) == ["https://swift.org/", "https://docs.swift.org/swift-book/"])
        #expect(result.references.map(\.host) == ["swift.org", "docs.swift.org"])
    }

    @Test
    func emptyBraveResultsReturnFriendlyMessage() throws {
        let result = try AgentWebTools.formatBraveResults(
            data: Data("{\"web\": {\"results\": []}}".utf8),
            query: "nothing"
        )
        #expect(result.payload.contains("no results"))
    }

    @Test
    func malformedBraveResponseThrows() {
        #expect(throws: AgentToolError.self) {
            _ = try AgentWebTools.formatBraveResults(
                data: Data("not json".utf8),
                query: "x"
            )
        }
    }

    // MARK: - some.im managed response formatting

    private let someIMManagedFixture = """
    {
      "code": 0,
      "data": {
        "query": "swift language",
        "provider": "exa",
        "result_count": 1,
        "results": [
          {
            "title": "Swift.org - <strong>Welcome</strong>",
            "url": "https://swift.org/",
            "snippet": "Swift is a <strong>general-purpose</strong> language &amp; more.",
            "published_date": "2026-01-02",
            "author": "Swift Team"
          }
        ]
      }
    }
    """

    @Test
    func formatsSomeIMManagedResults() throws {
        let result = try AgentWebTools.formatSomeIMManagedResults(
            data: Data(someIMManagedFixture.utf8),
            query: "swift language"
        )
        #expect(result.summary.contains("some.im managed"))
        #expect(result.payload.contains("some.im managed / exa"))
        #expect(result.payload.contains("Swift.org - Welcome"))
        #expect(result.payload.contains("general-purpose language & more"))
        #expect(result.payload.contains("published: 2026-01-02"))
        #expect(result.references.map(\.url) == ["https://swift.org/"])
    }

    @Test
    func malformedSomeIMManagedResponseThrows() {
        #expect(throws: AgentToolError.self) {
            _ = try AgentWebTools.formatSomeIMManagedResults(
                data: Data("not json".utf8),
                query: "x"
            )
        }
    }

    // MARK: - Tool argument validation

    @Test
    func webFetchRejectsMissingAndPrivateURLs() async {
        await #expect(throws: AgentToolError.self) {
            _ = try await AgentWebTools.webFetch(arguments: [:])
        }
        await #expect(throws: AgentToolError.self) {
            _ = try await AgentWebTools.webFetch(arguments: ["url": .string("http://192.168.1.1/admin")])
        }
        await #expect(throws: AgentToolError.self) {
            _ = try await AgentWebTools.webFetch(arguments: ["url": .string("file:///etc/hosts")])
        }
    }

    @Test
    func webSearchRejectsEmptyQuery() async {
        await #expect(throws: AgentToolError.self) {
            _ = try await AgentWebTools.webSearch(arguments: ["query": .string("   ")])
        }
    }
}
