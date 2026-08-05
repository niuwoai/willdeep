//
//  AgentNetworkSupportTests.swift
//  XeditTests
//
//  Locks the unified outgoing client identity (User-Agent) format so a
//  refactor can't silently drop the `some.im/WillDeep-{version}` branding.
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

    /// The unified client identity must brand every request as a some.im-family
    /// WillDeep client and carry the running version:
    /// `some.im/WillDeep-{version} (macOS)`.
    @Test
    func userAgentUsesSomeIMBrandedFormatWithVersionAndPlatform() {
        let ua = AgentNetworkSupport.userAgentHeaderValue
        #expect(ua.hasPrefix("some.im/WillDeep-"))
        #expect(ua.hasSuffix(" (macOS)"))
        // Carries the same version string the rest of the app reports.
        #expect(ua.contains(AgentNetworkSupport.appVersionHeaderValue))
        // No stale bare `WillDeep/{version}` form remains.
        #expect(!ua.contains("WillDeep/"))
    }

    /// `applyStandardHeaders` stamps both the version and the branded UA onto
    /// an outgoing request — this is the path all some.im requests go through.
    @Test
    func applyStandardHeadersStampsBrandedUserAgentAndVersion() throws {
        var request = URLRequest(url: try #require(URL(string: "https://some.im/v1/ping")))
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        #expect(request.value(forHTTPHeaderField: "User-Agent") == AgentNetworkSupport.userAgentHeaderValue)
        #expect(request.value(forHTTPHeaderField: "X-App-Version") == AgentNetworkSupport.appVersionHeaderValue)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("some.im/WillDeep-") == true)
    }
}
