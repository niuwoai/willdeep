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
                return stored
            }
            #expect(value?.apiKey == "key-1")
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
                return nil
            }
            #expect(value == nil)
        }

        #expect(loads == 1)
    }

    @Test
    func invalidateForcesTheNextReadToReload() {
        let memo = SomeIMSharedSessionMemo()
        var current = session("old")
        var loads = 0
        let read = { memo.value { loads += 1; return current } }

        #expect(read()?.apiKey == "old")
        current = session("new")
        #expect(read()?.apiKey == "old")   // still memoized

        memo.invalidate()

        #expect(read()?.apiKey == "new")
        #expect(loads == 2)
    }

    /// A write path may invalidate more than once before anything reads back;
    /// that must stay harmless rather than wedging the memo.
    @Test
    func repeatedInvalidationIsIdempotent() {
        let memo = SomeIMSharedSessionMemo()
        var loads = 0
        let read = { memo.value { loads += 1; return self.session("k") } }

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

    /// The empty answer is cacheable, but not forever. An empty read is either a
    /// real sign-out or a read that raced a concurrent Keychain write, and this
    /// layer cannot tell them apart — so the answer has to expire on its own.
    @Test
    func anEmptyAnswerStopsBeingServedAfterTheTTL() {
        var clock = Date(timeIntervalSince1970: 0)
        let memo = SomeIMSharedSessionMemo(emptyTTL: 1, now: { clock })
        var loads = 0
        let read = { memo.value { loads += 1; return nil } }

        _ = read()
        _ = read()
        #expect(loads == 1)          // still inside the TTL

        clock = clock.addingTimeInterval(1.5)
        _ = read()
        #expect(loads == 2)          // expired, so the loader runs again
    }

    /// The bug this TTL exists for. `persistSharedSession` invalidates *before*
    /// it writes, and `SharedKeychain.write` can fall back to delete+add — so a
    /// concurrent reader lands between the two and reads nothing. Before the
    /// TTL, that answer stuck until the next invalidation and the entire app
    /// looked signed out: an empty model picker for seconds at a time.
    @Test
    func anEmptyReadThatRacedAWriteHealsWithoutAnInvalidate() {
        var clock = Date(timeIntervalSince1970: 0)
        var stored: SomeIMSharedSession?          // mid delete+add: nothing there
        let memo = SomeIMSharedSessionMemo(emptyTTL: 1, now: { clock })
        let read = { memo.value { stored } }

        #expect(read() == nil)
        stored = session("restored")              // the write lands
        #expect(read() == nil)                    // still serving the empty answer

        clock = clock.addingTimeInterval(1.5)
        #expect(read()?.apiKey == "restored")     // heals on its own
    }

    /// Only the *empty* answer expires. A real session stays memoized until
    /// something invalidates it, which is what keeps the 400ms-interval readers
    /// off the Keychain.
    @Test
    func aRealSessionStaysCachedPastTheEmptyTTL() {
        var clock = Date(timeIntervalSince1970: 0)
        let memo = SomeIMSharedSessionMemo(emptyTTL: 1, now: { clock })
        var loads = 0
        let read = { memo.value { loads += 1; return self.session("k") } }

        _ = read()
        clock = clock.addingTimeInterval(600)
        _ = read()

        #expect(loads == 1)
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
        let read = { memo.value { persisted } }

        #expect(read()?.apiKey == "before")

        // Simulate persistSharedSession: invalidate, then write.
        memo.invalidate()
        persisted = session("after")

        #expect(read()?.apiKey == "after")
    }
}
