//
//  AgentNetworkSupportTests.swift
//  XeditTests
//
//  Locks the unified outgoing client identity (User-Agent, X-Client-Name) so
//  a refactor can't silently drop the `WillDeep Desktop (some.im)` branding
//  or let the two headers drift into different spellings of the same client.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentNetworkSupportTests {
    @Test
    func modelRequestTimeoutAllowsLongReasoningGaps() {
        let configuration = AgentNetworkSupport.defaultSession().configuration

        #expect(AgentNetworkSupport.requestTimeout == 180)
        #expect(configuration.timeoutIntervalForRequest == 180)
        #expect(configuration.timeoutIntervalForResource == 600)
    }

    /// The unified client identity must brand every request as this client and
    /// carry the running version: `WillDeep Desktop (some.im) {version} (macOS)`.
    @Test
    func userAgentUsesSomeIMBrandedFormatWithVersionAndPlatform() {
        let ua = AgentNetworkSupport.userAgentHeaderValue
        // `X-Client-Name` is the bare name — the build travels in
        // `X-Client-Version` beside it. Only the UA, which has nowhere else to
        // put a version, appends one.
        #expect(AgentNetworkSupport.clientNameHeaderValue == "WillDeep Desktop (some.im)")
        #expect(
            ua == "WillDeep Desktop (some.im) \(AgentNetworkSupport.appVersionHeaderValue) (macOS)"
        )
        #expect(ua.hasPrefix(AgentNetworkSupport.clientNameHeaderValue + " "))
        #expect(ua.hasSuffix(" (macOS)"))
        // Carries the same version string the rest of the app reports.
        #expect(ua.contains(AgentNetworkSupport.appVersionHeaderValue))
        // Separators are spaces: none of the retired hyphen/slash forms
        // (`WillDeep/{version}`, `some.im/WillDeep-{version}`) may come back.
        #expect(!ua.contains("WillDeep/"))
        #expect(!ua.contains("WillDeep-"))
        #expect(!ua.contains("some.im/"))
    }

    /// The webhook stamps the version captured with the event, but must not
    /// grow a second spelling of the client while doing it.
    @Test
    func webhookUserAgentSharesTheSameFormat() {
        let ua = AgentNetworkSupport.userAgent(forVersion: "9.9.9-rc1")
        #expect(ua == "WillDeep Desktop (some.im) 9.9.9-rc1 (macOS)")
    }

    /// `applyStandardHeaders` stamps both the version and the branded UA onto
    /// an outgoing request — this is the path all some.im requests go through.
    @Test
    func applyStandardHeadersStampsBrandedUserAgentAndVersion() throws {
        var request = URLRequest(url: try #require(URL(string: "https://some.im/v1/ping")))
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        #expect(request.value(forHTTPHeaderField: "User-Agent") == AgentNetworkSupport.userAgentHeaderValue)
        #expect(request.value(forHTTPHeaderField: "X-App-Version") == AgentNetworkSupport.appVersionHeaderValue)
        #expect(request.value(forHTTPHeaderField: "X-Client-Name") == AgentNetworkSupport.clientNameHeaderValue)
        #expect(request.value(forHTTPHeaderField: "X-Client-Version") == AgentNetworkSupport.appVersionHeaderValue)
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")?
                .hasPrefix(AgentNetworkSupport.clientNameHeaderValue) == true
        )
    }
}
