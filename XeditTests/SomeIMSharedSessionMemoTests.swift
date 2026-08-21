//
//  SomeIMSharedSessionMemoTests.swift
//  WillDeepTests
//

import Foundation
import Testing
import SomeIMSharedSession
@testable import WillDeep

@MainActor
@Suite
struct SomeIMSharedSessionMemoTests {
    private func session(_ apiKey: String) -> SomeIMSharedSession {
        SomeIMSharedSession(apiKey: apiKey, baseURL: "https://api.some.im")
    }

    @Test
    func repeatedReadsHitTheLoaderOnce() {
        let memo = SomeIMSharedSessionMemo()
        let stored = session("key-1")
        var loads = 0

        for _ in 0..<10 {
            let value = memo.value {
                loads += 1
                return .session(stored)
            }
            #expect(value.session?.apiKey == "key-1")
        }

        #expect(loads == 1)
        #expect(memo.loadCount == 1)
    }

    /// "Nobody is logged in" is a real answer, not a cache miss — otherwise a
    /// signed-out app would re-hit the Keychain on every single access, which
    /// is exactly the 400ms-interval case this cache exists for.
    @Test
    func cachesTheSignedOutAnswerToo() {
        let memo = SomeIMSharedSessionMemo()
        var loads = 0

        for _ in 0..<5 {
            let value = memo.value {
                loads += 1
                return .signedOut
            }
            #expect(value == .signedOut)
        }

        #expect(loads == 1)
    }

    @Test
    func invalidateForcesTheNextReadToReload() {
        let memo = SomeIMSharedSessionMemo()
        var current = session("old")
        var loads = 0
        let read = { memo.value { loads += 1; return .session(current) } }

        #expect(read().session?.apiKey == "old")
        current = session("new")
        #expect(read().session?.apiKey == "old")   // still memoized

        memo.invalidate()

        #expect(read().session?.apiKey == "new")
        #expect(loads == 2)
    }

    /// A write path may invalidate more than once before anything reads back;
    /// that must stay harmless rather than wedging the memo.
    @Test
    func repeatedInvalidationIsIdempotent() {
        let memo = SomeIMSharedSessionMemo()
        var loads = 0
        let read = { memo.value { loads += 1; return .session(self.session("k")) } }

        _ = read()
        memo.invalidate()
        memo.invalidate()
        memo.invalidate()
        _ = read()

        #expect(loads == 2)
    }

    /// The DEBUG test override must stay outside the cache. Tests set it
    /// directly and expect the very next read to see the new value; if the memo
    /// ever fronted this path, every existing SomeIM test would start depending
    /// on invalidation order.
    @Test
    func testOverrideIsNeverServedFromTheCache() {
        SomeIMIntegrationStore._setTestSharedSessionOverride(
            enabled: true,
            session: session("first")
        )
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        #expect(SomeIMIntegrationStore.loadAPIKey() == "first")

        SomeIMIntegrationStore._setTestSharedSessionOverride(
            enabled: true,
            session: session("second")
        )

        #expect(SomeIMIntegrationStore.loadAPIKey() == "second")
    }

    /// A failed read is not an answer, so it must not stick. Before this, one
    /// unreadable moment left the whole app believing it was signed out until
    /// some notification happened along — an empty model picker for seconds.
    @Test
    func anUnavailableReadStopsBeingServedAfterTheTTL() {
        var clock = Date(timeIntervalSince1970: 0)
        let memo = SomeIMSharedSessionMemo(unavailableTTL: 1, now: { clock })
        var loads = 0
        let read = { memo.value { loads += 1; return .unavailable } }

        _ = read()
        _ = read()
        #expect(loads == 1)          // still inside the TTL

        clock = clock.addingTimeInterval(1.5)
        _ = read()
        #expect(loads == 2)          // expired, so the loader runs again
    }

    /// A read that could not complete heals on its own once the underlying
    /// condition clears — no invalidation required.
    @Test
    func anUnavailableReadHealsWithoutAnInvalidate() {
        var clock = Date(timeIntervalSince1970: 0)
        var outcome = SomeIMSessionReadOutcome.unavailable
        let memo = SomeIMSharedSessionMemo(unavailableTTL: 1, now: { clock })
        let read = { memo.value { outcome } }

        #expect(read() == .unavailable)
        outcome = .session(session("restored"))   // the condition clears
        #expect(read() == .unavailable)           // still inside the TTL

        clock = clock.addingTimeInterval(1.5)
        #expect(read().session?.apiKey == "restored")
    }

    /// Only `unavailable` expires. Both real answers — a session and a
    /// confirmed sign-out — stay memoized, which is what keeps the
    /// 400ms-interval readers off the Keychain.
    @Test
    func realAnswersStayCachedPastTheUnavailableTTL() {
        var clock = Date(timeIntervalSince1970: 0)
        var loads = 0

        let live = SomeIMSharedSessionMemo(unavailableTTL: 1, now: { clock })
        let readLive = { live.value { loads += 1; return .session(self.session("k")) } }
        _ = readLive()
        clock = clock.addingTimeInterval(600)
        _ = readLive()
        #expect(loads == 1)

        var signedOutClock = Date(timeIntervalSince1970: 0)
        var signedOutLoads = 0
        let out = SomeIMSharedSessionMemo(unavailableTTL: 1, now: { signedOutClock })
        let readOut = { out.value { signedOutLoads += 1; return .signedOut } }
        _ = readOut()
        signedOutClock = signedOutClock.addingTimeInterval(600)
        _ = readOut()
        #expect(signedOutLoads == 1)
    }

    /// Guards the trap that made this cache risky in the first place:
    /// `updateSharedSession` verifies its own write by reading the session back
    /// and comparing keys. If a write left a stale value memoized, that check
    /// would compare the new key against the *old* cached one and the caller
    /// would wrongly report failure — or, with the operands the other way
    /// round, pass without ever reaching the Keychain.
    @Test
    func invalidatingBeforeAWriteMakesTheReadbackObserveIt() {
        let memo = SomeIMSharedSessionMemo()
        var persisted = session("before")
        let read = { memo.value { .session(persisted) } }

        #expect(read().session?.apiKey == "before")

        // Simulate persistSharedSession: invalidate, then write.
        memo.invalidate()
        persisted = session("after")

        #expect(read().session?.apiKey == "after")
    }
}
