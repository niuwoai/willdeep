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
        var createdSessionIDs: [AgentSession.ID] = []
        defer { deleteSessionsCreatedByTest(createdSessionIDs) }

        #expect(appState.activeRuntime == nil)

        let appended = appState.appendAgentInputTextCreatingSessionIfNeeded("  语音输入  ")
        if let createdID = appState.activeAgentSessionID {
            createdSessionIDs.append(createdID)
        }

        #expect(appended == true)
        #expect(appState.activeRuntime != nil)
        #expect(appState.agentInput == "语音输入")
    }

    @Test("voice input appends to existing composer text")
    func voiceInputAppendsToExistingComposerText() {
        let appState = AppState(rootDirectory: nil)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }

        appState.agentInput = "前半句"

        let appended = appState.appendAgentInputTextCreatingSessionIfNeeded("后半句")

        #expect(appended == true)
        #expect(appState.agentInput == "前半句 后半句")
    }

    @Test("voice cleanup off appends raw transcript through async voice path")
    func voiceCleanupOffAppendsRawTranscript() async {
        let oldMode = UserPreferences.shared.transcriptCleanupMode
        UserPreferences.shared.transcriptCleanupMode = .off
        defer { UserPreferences.shared.transcriptCleanupMode = oldMode }

        let appState = AppState(rootDirectory: nil)
        var createdSessionIDs: [AgentSession.ID] = []
        defer { deleteSessionsCreatedByTest(createdSessionIDs) }

        let appended = await appState.appendVoiceTranscriptCreatingSessionIfNeeded("  先修一下登录，然后补测试  ")
        if let createdID = appState.activeAgentSessionID {
            createdSessionIDs.append(createdID)
        }

        #expect(appended == true)
        #expect(appState.agentInput == "先修一下登录，然后补测试")
    }

    @Test("voice AI cleanup strips wrapper text from provider output")
    func voiceCleanupSanitizesProviderOutput() {
        let cleaned = VoiceTranscriptPolisher.sanitize(
            """
            ```text
            整理后：
            - 先修登录
            - 再补测试
            ```
            """,
            source: "先修登录再补测试"
        )

        #expect(cleaned == "- 先修登录\n- 再补测试")
    }

    private func deleteSessionsCreatedByTest(_ ids: [AgentSession.ID]) {
        for id in ids {
            AgentSessionStore.delete(id: id)
        }
    }
}
