//
//  AgentMobileGatewayPublishThrottleTests.swift
//  XeditTests
//
//  Guards the three pieces that keep the gateway's 400ms snapshot tick off the
//  main thread: per-type payload dedup, the queued-snapshot latch, and the
//  filesystem probe cache behind `mobileGatewayWorkspaceList`.
//
//  `#expect` wraps its expression in a closure, which captures locals
//  immutably — so every `mutating` call below happens on its own line and only
//  the result is asserted on.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentMobileGatewayPublishThrottleTests {
    private func envelope(
        type: String,
        payload: [String: AgentMobileGatewayJSON],
        timestamp: String
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(type: type, payload: payload, timestamp: timestamp)
    }

    // MARK: - Payload dedup

    @Test @MainActor
    func firstEnvelopeOfATypeIsAlwaysSent() {
        var dedup = AgentMobileGatewayPayloadDedup()
        let sent = dedup.shouldSend(envelope(
            type: "workspace.list",
            payload: ["workspaces": .array([])],
            timestamp: "t0"
        ))
        #expect(sent)
    }

    /// The reason this dedup compares payloads instead of envelopes: every tick
    /// stamps a fresh `ts`, so envelope equality would never hold and nothing
    /// would ever be suppressed.
    @Test @MainActor
    func identicalPayloadWithANewTimestampIsSuppressed() {
        var dedup = AgentMobileGatewayPayloadDedup()
        let payload: [String: AgentMobileGatewayJSON] = ["workspaces": .array([.string("/tmp/a")])]
        let first = dedup.shouldSend(envelope(type: "workspace.list", payload: payload, timestamp: "t0"))
        let second = dedup.shouldSend(envelope(type: "workspace.list", payload: payload, timestamp: "t1"))
        let third = dedup.shouldSend(envelope(type: "workspace.list", payload: payload, timestamp: "t2"))
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test @MainActor
    func changedPayloadIsSent() {
        var dedup = AgentMobileGatewayPayloadDedup()
        let first = dedup.shouldSend(envelope(
            type: "workspace.list",
            payload: ["workspaces": .array([.string("/tmp/a")])],
            timestamp: "t0"
        ))
        let second = dedup.shouldSend(envelope(
            type: "workspace.list",
            payload: ["workspaces": .array([.string("/tmp/a"), .string("/tmp/b")])],
            timestamp: "t1"
        ))
        #expect(first)
        #expect(second)
    }

    /// Only the most recent payload per type is remembered — A → B → A must put
    /// A back on the wire, because the phone's last word on this type was B.
    @Test @MainActor
    func payloadRevertingToAnEarlierValueIsSent() {
        var dedup = AgentMobileGatewayPayloadDedup()
        let a: [String: AgentMobileGatewayJSON] = ["n": .int(1)]
        let b: [String: AgentMobileGatewayJSON] = ["n": .int(2)]
        let first = dedup.shouldSend(envelope(type: "capabilities", payload: a, timestamp: "t0"))
        let second = dedup.shouldSend(envelope(type: "capabilities", payload: b, timestamp: "t1"))
        let third = dedup.shouldSend(envelope(type: "capabilities", payload: a, timestamp: "t2"))
        #expect(first)
        #expect(second)
        #expect(third)
    }

    @Test @MainActor
    func typesDoNotShadowEachOther() {
        var dedup = AgentMobileGatewayPayloadDedup()
        let payload: [String: AgentMobileGatewayJSON] = ["n": .int(1)]
        let snapshot = dedup.shouldSend(envelope(type: "state.snapshot", payload: payload, timestamp: "t0"))
        // Same payload, different type — the phone has not been told this one.
        let capabilities = dedup.shouldSend(envelope(type: "capabilities", payload: payload, timestamp: "t0"))
        let workspaces = dedup.shouldSend(envelope(type: "workspace.list", payload: payload, timestamp: "t0"))
        #expect(snapshot)
        #expect(capabilities)
        #expect(workspaces)
    }

    /// The reconnect guard. A new socket has been told nothing, so suppressing
    /// against the previous connection's memory would leave the phone with an
    /// empty workspace list until something happened to change it.
    @Test @MainActor
    func resetForcesAFullResendEvenWhenNothingChanged() {
        var dedup = AgentMobileGatewayPayloadDedup()
        let payload: [String: AgentMobileGatewayJSON] = ["workspaces": .array([.string("/tmp/a")])]
        let first = dedup.shouldSend(envelope(type: "workspace.list", payload: payload, timestamp: "t0"))
        let suppressed = dedup.shouldSend(envelope(type: "workspace.list", payload: payload, timestamp: "t1"))
        dedup.reset()
        let afterReset = dedup.shouldSend(envelope(type: "workspace.list", payload: payload, timestamp: "t2"))
        #expect(first)
        #expect(!suppressed)
        #expect(afterReset)
    }

    // MARK: - Queued-snapshot latch

    @Test
    func latchAdmitsOneCallerPerCycle() {
        let flag = AgentMobileGatewayAtomicFlag()
        #expect(flag.takeIfClear())
        #expect(!flag.takeIfClear())
        #expect(!flag.takeIfClear())
        flag.clear()
        #expect(flag.takeIfClear())
    }

    /// `objectWillChange` is not actor-isolated; a streaming reply can publish
    /// from more than one thread. Exactly one of a concurrent burst may win, or
    /// the peer would queue duplicate snapshot hops again.
    @Test
    func latchAdmitsExactlyOneOfAConcurrentBurst() async {
        let flag = AgentMobileGatewayAtomicFlag()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask { flag.takeIfClear() }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1)
    }

    // MARK: - Repo probe cache

    @Test @MainActor
    func repoProbeRunsOnceWithinTTL() {
        var cache = AgentMobileGatewayRepoProbeCache()
        let start = Date(timeIntervalSince1970: 1_000_000)
        var probes = 0
        for offset in stride(from: 0.0, to: AgentMobileGatewayRepoProbeCache.ttl, by: 0.4) {
            _ = cache.isGitRepo("/tmp/a", now: start.addingTimeInterval(offset)) {
                probes += 1
                return true
            }
        }
        #expect(probes == 1)
    }

    @Test @MainActor
    func repoProbeReRunsAfterTTL() {
        var cache = AgentMobileGatewayRepoProbeCache()
        let start = Date(timeIntervalSince1970: 1_000_000)
        var probes = 0
        _ = cache.isGitRepo("/tmp/a", now: start) {
            probes += 1
            return true
        }
        _ = cache.isGitRepo(
            "/tmp/a",
            now: start.addingTimeInterval(AgentMobileGatewayRepoProbeCache.ttl + 0.1)
        ) {
            probes += 1
            return true
        }
        #expect(probes == 2)
    }

    /// A negative result costs exactly as much to compute as a positive one, so
    /// "not a repo" must be cached too — most workspaces are not repos.
    @Test @MainActor
    func negativeResultsAreCached() {
        var cache = AgentMobileGatewayRepoProbeCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        var isRepoProbes = 0
        var rootProbes = 0
        var sawRepo = false
        var sawRoot: String?
        for _ in 0..<10 {
            sawRepo = cache.isGitRepo("/tmp/plain", now: now) {
                isRepoProbes += 1
                return false
            }
            sawRoot = cache.repositoryRoot(for: "/tmp/plain", now: now) {
                rootProbes += 1
                return nil
            }
        }
        #expect(!sawRepo)
        #expect(sawRoot == nil)
        #expect(isRepoProbes == 1)
        #expect(rootProbes == 1)
    }

    @Test @MainActor
    func pathsAreCachedIndependently() {
        var cache = AgentMobileGatewayRepoProbeCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let firstA = cache.isGitRepo("/tmp/a", now: now) { true }
        let firstB = cache.isGitRepo("/tmp/b", now: now) { false }
        // Both answers survive; neither path overwrote the other.
        let secondA = cache.isGitRepo("/tmp/a", now: now) {
            Issue.record("re-probed /tmp/a")
            return false
        }
        let secondB = cache.isGitRepo("/tmp/b", now: now) {
            Issue.record("re-probed /tmp/b")
            return true
        }
        #expect(firstA)
        #expect(!firstB)
        #expect(secondA)
        #expect(!secondB)
    }

    @Test @MainActor
    func repositoryRootIsCachedPerPath() {
        var cache = AgentMobileGatewayRepoProbeCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = cache.repositoryRoot(for: "/tmp/a/sub", now: now) { "/tmp/a" }
        let second = cache.repositoryRoot(for: "/tmp/a/sub", now: now) {
            Issue.record("walked the tree again")
            return nil
        }
        #expect(first == "/tmp/a")
        #expect(second == "/tmp/a")
    }

    @Test @MainActor
    func resetForcesAFreshProbe() {
        var cache = AgentMobileGatewayRepoProbeCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        var probes = 0
        _ = cache.isGitRepo("/tmp/a", now: now) {
            probes += 1
            return true
        }
        cache.reset()
        _ = cache.isGitRepo("/tmp/a", now: now) {
            probes += 1
            return true
        }
        #expect(probes == 2)
    }

    // MARK: - Phone presence gate

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// The whole point of the gate: a desktop sitting in the relay room with no
    /// phone attached must not rebuild snapshots on every `objectWillChange`.
    @Test @MainActor
    func connectedWithoutAPhoneSkipsTheSnapshotTick() {
        let decision = AgentMobileGatewaySnapshotSchedule.decide(
            isConnected: true,
            hasSocket: true,
            hasPendingSnapshot: false,
            presence: AgentMobileGatewayPhonePresence(),
            now: t0
        )
        #expect(decision == .skipNoActivePhone)
    }

    @Test @MainActor
    func activePhoneSchedulesExactlyOnePendingSnapshot() {
        var presence = AgentMobileGatewayPhonePresence()
        _ = presence.recordInbound(type: "session.list", at: t0)
        let first = AgentMobileGatewaySnapshotSchedule.decide(
            isConnected: true, hasSocket: true, hasPendingSnapshot: false,
            presence: presence, now: t0.addingTimeInterval(1)
        )
        let coalesced = AgentMobileGatewaySnapshotSchedule.decide(
            isConnected: true, hasSocket: true, hasPendingSnapshot: true,
            presence: presence, now: t0.addingTimeInterval(1.2)
        )
        #expect(first == .schedule)
        #expect(coalesced == .alreadyScheduled)
    }

    @Test @MainActor
    func disconnectedSocketSkipsEvenWithARecentPhone() {
        var presence = AgentMobileGatewayPhonePresence()
        _ = presence.recordInbound(type: "session.list", at: t0)
        let notVerified = AgentMobileGatewaySnapshotSchedule.decide(
            isConnected: false, hasSocket: true, hasPendingSnapshot: false,
            presence: presence, now: t0
        )
        let noSocket = AgentMobileGatewaySnapshotSchedule.decide(
            isConnected: true, hasSocket: false, hasPendingSnapshot: false,
            presence: presence, now: t0
        )
        #expect(notVerified == .skipDisconnected)
        #expect(noSocket == .skipDisconnected)
    }

    /// Android heartbeats every 5s (15s on older builds); once those stop for a
    /// full window the phone is gone and the tick must go quiet again.
    @Test @MainActor
    func presenceExpiresAfterTheActivityWindow() {
        var presence = AgentMobileGatewayPhonePresence()
        _ = presence.recordInbound(type: "session.list", at: t0)
        let window = AgentMobileGatewayPhonePresence.activityWindow
        #expect(presence.isPhoneActive(at: t0.addingTimeInterval(window)))
        #expect(!presence.isPhoneActive(at: t0.addingTimeInterval(window + 1)))
        let decision = AgentMobileGatewaySnapshotSchedule.decide(
            isConnected: true, hasSocket: true, hasPendingSnapshot: false,
            presence: presence, now: t0.addingTimeInterval(window + 1)
        )
        #expect(decision == .skipNoActivePhone)
    }

    /// The activity window must outlast several heartbeats of the slowest
    /// shipped client, or an idle-but-attached phone would flap.
    @Test @MainActor
    func activityWindowCoversSeveralSlowHeartbeats() {
        #expect(AgentMobileGatewayPhonePresence.activityWindow >= 3 * 15)
    }

    /// A relay echo of our own broadcast (or any desktop-originated event) is
    /// not a phone and must not keep the tick alive.
    @Test @MainActor
    func desktopOriginatedEnvelopesDoNotCountAsAPhone() {
        var presence = AgentMobileGatewayPhonePresence()
        let snapshotEcho = presence.recordInbound(type: "state.snapshot", at: t0)
        let ackEcho = presence.recordInbound(type: "ack", at: t0)
        let errorEcho = presence.recordInbound(type: "command.error", at: t0)
        #expect(!snapshotEcho)
        #expect(!ackEcho)
        #expect(!errorEcho)
        #expect(!presence.isPhoneActive(at: t0))
    }

    /// Only the idle -> active edge reports true: that is when the caller resets
    /// the payload dedup, and doing it on every heartbeat would resend
    /// `workspace.list` / `capabilities` every 5s.
    @Test @MainActor
    func onlyTheIdleToActiveEdgeAsksForAFullPicture() {
        var presence = AgentMobileGatewayPhonePresence()
        let window = AgentMobileGatewayPhonePresence.activityWindow
        let first = presence.recordInbound(type: "session.list", at: t0)
        let heartbeat = presence.recordInbound(type: "session.list", at: t0.addingTimeInterval(5))
        let command = presence.recordInbound(type: "message.send", at: t0.addingTimeInterval(9))
        let comeback = presence.recordInbound(
            type: "session.list",
            at: t0.addingTimeInterval(9 + window + 1)
        )
        #expect(first)
        #expect(!heartbeat)
        #expect(!command)
        #expect(comeback)
    }

    @Test @MainActor
    func resetForgetsThePhone() {
        var presence = AgentMobileGatewayPhonePresence()
        _ = presence.recordInbound(type: "session.list", at: t0)
        presence.reset()
        #expect(!presence.isPhoneActive(at: t0))
        #expect(presence.lastPhoneActivity == nil)
    }
}
