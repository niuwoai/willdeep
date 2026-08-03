//
//  AgentDispatchGraphRuntimeLookupTests.swift
//  WillDeepTests
//

import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentDispatchGraphRuntimeLookupTests {
    @Test("调度图只读查询不会物化或淘汰 runtime")
    func loadedRuntimeLookupNeverMutatesSessionState() throws {
        let appState = AppState()
        let session = AgentSession(title: "Dispatch task")
        let runtime = AgentRuntime(session: session)
        appState.agentSessions = [session]
        appState.agentRuntimes = [session.id: runtime]

        let loaded = try #require(appState.loadedRuntime(for: session.id))
        #expect(loaded === runtime)

        appState.agentRuntimes.removeValue(forKey: session.id)
        let sessionsBeforeLookup = appState.agentSessions
        let runtimeIDsBeforeLookup = Set(appState.agentRuntimes.keys)

        #expect(appState.loadedRuntime(for: session.id) == nil)
        #expect(appState.agentSessions == sessionsBeforeLookup)
        #expect(Set(appState.agentRuntimes.keys) == runtimeIDsBeforeLookup)
    }
}
