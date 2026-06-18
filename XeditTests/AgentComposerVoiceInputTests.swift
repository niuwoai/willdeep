//
//  AgentComposerVoiceInputTests.swift
//  WillDeepTests
//
//  Covers voice input handoff into the Agent composer.
//

import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentComposerVoiceInputTests {
    @Test("voice input creates an active session before appending")
    func voiceInputCreatesSessionBeforeAppending() {
        let appState = AppState(rootDirectory: nil)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        defer { deleteSessionsCreatedByTest(appState, existingIDs: existingIDs) }

        #expect(appState.activeRuntime == nil)

        let appended = appState.appendAgentInputTextCreatingSessionIfNeeded("  语音输入  ")

        #expect(appended == true)
        #expect(appState.activeRuntime != nil)
        #expect(appState.agentInput == "语音输入")
    }

    @Test("voice input appends to existing composer text")
    func voiceInputAppendsToExistingComposerText() {
        let appState = AppState(rootDirectory: nil)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        defer { deleteSessionsCreatedByTest(appState, existingIDs: existingIDs) }

        appState.startNewAgentSession()
        appState.agentInput = "前半句"

        let appended = appState.appendAgentInputTextCreatingSessionIfNeeded("后半句")

        #expect(appended == true)
        #expect(appState.agentInput == "前半句 后半句")
    }

    private func deleteSessionsCreatedByTest(_ appState: AppState, existingIDs: Set<AgentSession.ID>) {
        for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
            AgentSessionStore.delete(id: id)
        }
    }
}
