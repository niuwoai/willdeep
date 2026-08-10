//
//  AgentStreamingCursorPolicyTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentStreamingCursorPolicyTests {
    @Test("streaming refresh cadence backs off as rendered content grows")
    func streamingRefreshCadenceBacksOff() {
        #expect(AgentStreamingRefreshPolicy.intervalNanoseconds(forContentLength: 0) == 200_000_000)
        #expect(AgentStreamingRefreshPolicy.intervalNanoseconds(forContentLength: 3_999) == 200_000_000)
        #expect(AgentStreamingRefreshPolicy.intervalNanoseconds(forContentLength: 4_000) == 333_000_000)
        #expect(AgentStreamingRefreshPolicy.intervalNanoseconds(forContentLength: 15_999) == 333_000_000)
        #expect(AgentStreamingRefreshPolicy.intervalNanoseconds(forContentLength: 16_000) == 500_000_000)
    }

    @Test("streaming cursor remains visible while output is newer than 500ms")
    func recentOutputShowsCursor() {
        let lastOutputAt = Date(timeIntervalSinceReferenceDate: 10)
        let now = lastOutputAt.addingTimeInterval(0.499)

        #expect(AgentStreamingCursorPolicy.shouldShow(lastOutputAt: lastOutputAt, now: now))
    }

    @Test("streaming cursor hides once output has been idle for 500ms")
    func idleOutputHidesCursor() {
        let lastOutputAt = Date(timeIntervalSinceReferenceDate: 10)
        let now = lastOutputAt.addingTimeInterval(0.5)

        #expect(!AgentStreamingCursorPolicy.shouldShow(lastOutputAt: lastOutputAt, now: now))
    }
}
