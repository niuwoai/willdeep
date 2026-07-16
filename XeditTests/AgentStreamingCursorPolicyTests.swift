//
//  AgentStreamingCursorPolicyTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentStreamingCursorPolicyTests {
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
