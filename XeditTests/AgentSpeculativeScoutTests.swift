import Foundation
import Testing
@testable import WillDeep

@Suite("Parallel scout")
@MainActor
struct AgentSpeculativeScoutTests {
    @Test("the parallel scout is on unless the shared config says otherwise")
    func enabledDefaults() {
        #expect(AppState.speculativeScoutEnabled(sharedConfig: AgentSharedRuntimeConfig()))

        var shared = AgentSharedRuntimeConfig()
        shared.speculativeScout = false
        #expect(!AppState.speculativeScoutEnabled(sharedConfig: shared))

        // No routing, no decision to scout for.
        shared = AgentSharedRuntimeConfig()
        shared.smallModelRouting = false
        #expect(!AppState.speculativeScoutEnabled(sharedConfig: shared))
    }

    @Test("a high-confidence read-only route scouts in parallel with its own trade")
    func readOnlyRouteScouts() throws {
        let decision = AgentRequestRouter.classify("这个函数定义在哪个文件")
        try #require(decision.autoDispatchEligible)
        let expected = try #require(decision.preflightProfileID)

        #expect(AppState.speculativeScoutProfileID(
            decision: decision,
            delegationPolicy: .automatic,
            serialPreflightEnabled: false,
            speculativeEnabled: true
        ) == expected)
        // `/subagent` asks for delegation; it does not turn the scout off.
        #expect(AppState.speculativeScoutProfileID(
            decision: decision,
            delegationPolicy: .required,
            serialPreflightEnabled: false,
            speculativeEnabled: true
        ) == expected)
    }

    @Test("`/no-subagent` keeps the turn scout-free")
    func noSubagentDisablesScout() {
        let decision = AgentRequestRouter.classify("这个函数定义在哪个文件")

        #expect(AppState.speculativeScoutProfileID(
            decision: decision,
            delegationPolicy: .forbidden,
            serialPreflightEnabled: false,
            speculativeEnabled: true
        ) == nil)
    }

    @Test("the serial preflight, a disabled switch, a pinned worker and a mutation route all yield to something else")
    func yieldsWhenSomethingElseOwnsTheRequest() {
        let readOnly = AgentRequestRouter.classify("这个函数定义在哪个文件")

        // Explicit serial preflight already delivers the same findings.
        #expect(AppState.speculativeScoutProfileID(
            decision: readOnly,
            delegationPolicy: .automatic,
            serialPreflightEnabled: true,
            speculativeEnabled: true
        ) == nil)
        #expect(AppState.speculativeScoutProfileID(
            decision: readOnly,
            delegationPolicy: .automatic,
            serialPreflightEnabled: false,
            speculativeEnabled: false
        ) == nil)
        // An operator-named worker is an instruction the root model follows.
        #expect(AppState.speculativeScoutProfileID(
            decision: AgentRequestRouter.pinnedDecision(profileID: AgentSubagentProfileCatalog.scoutID),
            delegationPolicy: .automatic,
            serialPreflightEnabled: false,
            speculativeEnabled: true
        ) == nil)
        // A write route's scout prepares a write task; that stays serial.
        let mutation = AgentRequestRouter.classify("实现新的重试策略")
        #expect(!mutation.autoDispatchEligible)
        #expect(AppState.speculativeScoutProfileID(
            decision: mutation,
            delegationPolicy: .automatic,
            serialPreflightEnabled: false,
            speculativeEnabled: true
        ) == nil)
        #expect(AppState.speculativeScoutProfileID(
            decision: nil,
            delegationPolicy: .automatic,
            serialPreflightEnabled: false,
            speculativeEnabled: true
        ) == nil)
    }

    @Test("the steering note tells the root model not to wait and not to duplicate the scout")
    func steeringNote() {
        let steering = AppState.steeringWithParallelScout(
            existing: "<runtime-route tier=\"worker\" profile=\"scout\">…</runtime-route>",
            profileID: "scout",
            model: "someim-32b-scout"
        )

        #expect(steering.contains("<runtime-route"))
        #expect(steering.contains("<runtime-parallel-scout profile=\"scout\""))
        #expect(steering.contains("Do not wait for it"))
        #expect(steering.contains("do not spawn another read-only worker"))
        #expect(steering.contains("answer directly"))
    }

    @Test("the report notice frames the findings as evidence and keeps the report text")
    func reportNotice() {
        let notice = AppState.parallelScoutReportNotice(
            profileID: "scout",
            model: "someim-32b-scout",
            rounds: 2,
            report: "AuthGate.swift:42 gates the permission check."
        )

        #expect(notice.hasPrefix("<runtime-parallel-scout-report profile=\"scout\""))
        #expect(notice.contains("rounds=\"2\""))
        #expect(notice.contains("AuthGate.swift:42"))
        #expect(notice.contains("evidence"))
    }

    @Test("the ledger source round-trips and stays distinct from the serial preflight")
    func ledgerSource() throws {
        let record = AgentHostWorkerRunRecord(
            userMessageID: nil,
            profileID: "scout",
            source: .speculativeScout
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AgentHostWorkerRunRecord.self, from: data)

        #expect(decoded.source == .speculativeScout)
        #expect(AgentHostWorkerRunRecord.Source.speculativeScout.rawValue == "speculativeScout")
        #expect(AgentHostWorkerRunRecord.Source.speculativeScout != .requestPreflight)
    }

    @Test("a report is delivered exactly once, at a tool boundary")
    func reportDeliveredOnce() throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let scout = makeScout(app: app, runtime: runtime)
        scout.report = "AuthGate.swift:42 gates the permission check."
        scout.phase = .reported
        runtime.speculativeScout = scout

        let notice = try #require(app.takeSpeculativeScoutReportIfReady(for: runtime))
        #expect(notice.contains("AuthGate.swift:42"))
        #expect(scout.phase == .delivered)
        #expect(app.takeSpeculativeScoutReportIfReady(for: runtime) == nil)
        let ledger = try #require(runtime.session.hostWorkerRuns?.first { $0.id == scout.hostRunID })
        #expect(ledger.acceptedOutput == true)

        // Turn end after delivery: nothing more to do, phase reported back.
        #expect(app.finalizeSpeculativeScoutAtTurnEnd(for: runtime) == "delivered")
        #expect(runtime.speculativeScout == nil)
    }

    @Test("a report that never met a tool boundary is dropped at turn end, not queued")
    func undeliveredReportIsDropped() throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let scout = makeScout(app: app, runtime: runtime)
        scout.report = "late"
        scout.phase = .reported
        runtime.speculativeScout = scout

        #expect(app.finalizeSpeculativeScoutAtTurnEnd(for: runtime) == "dropped")
        #expect(scout.phase == .dropped)
        #expect(runtime.speculativeScout == nil)
        #expect(app.takeSpeculativeScoutReportIfReady(for: runtime) == nil)
        let ledger = try #require(runtime.session.hostWorkerRuns?.first { $0.id == scout.hostRunID })
        #expect(ledger.acceptedOutput == false)
        // Never a background wake-up: the registry knows nothing about it.
        #expect(app.agentSubagentRegistry.pendingReportCount(forParentRuntime: runtime.id) == 0)
    }

    @Test("a scout still running at turn end is cancelled")
    func runningScoutIsCancelledAtTurnEnd() async throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let scout = makeScout(app: app, runtime: runtime)
        let neverEnding = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        scout.task = neverEnding
        runtime.speculativeScout = scout

        #expect(app.finalizeSpeculativeScoutAtTurnEnd(for: runtime) == "cancelled")
        #expect(scout.phase == .cancelled)
        #expect(neverEnding.isCancelled)
        #expect(runtime.speculativeScout == nil)
        // No scout at all: nil, so the turn line can tell "none" from "cancelled".
        #expect(app.finalizeSpeculativeScoutAtTurnEnd(for: runtime) == nil)
    }

    @Test("the turn timing probe is consumed once and only for its own turn")
    func turnTimingProbeConsumedOnce() throws {
        let app = AppState()
        let session = app.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(app.agentRuntimes[session.id])
        let turnID = UUID()
        runtime.currentTurnTiming = AgentTurnTimingProbe(
            sessionID: runtime.id,
            turnID: turnID,
            dispatchedAt: Date(),
            providerID: "some-im",
            model: "glm-5",
            routeProfileID: nil,
            routeConfidence: nil,
            delegationPolicy: "automatic"
        )

        // A different turn id must not consume this probe.
        app.finalizeTurnTiming(for: runtime, turnID: UUID(), outcome: "succeeded")
        #expect(runtime.currentTurnTiming != nil)

        app.finalizeTurnTiming(for: runtime, turnID: turnID, outcome: "succeeded")
        #expect(runtime.currentTurnTiming == nil)
    }

    private func makeScout(app: AppState, runtime: AgentRuntime) -> AgentSpeculativeScout {
        let hostRunID = app.beginHostWorkerRun(
            profileID: AgentSubagentProfileCatalog.scoutID,
            source: .speculativeScout,
            userMessageID: nil,
            model: "someim-32b-scout",
            providerID: "some-im",
            runtime: runtime
        )
        return AgentSpeculativeScout(
            profileID: AgentSubagentProfileCatalog.scoutID,
            model: "someim-32b-scout",
            providerID: "some-im",
            hostRunID: hostRunID,
            cardRecordID: UUID(),
            userMessageID: UUID()
        )
    }
}
