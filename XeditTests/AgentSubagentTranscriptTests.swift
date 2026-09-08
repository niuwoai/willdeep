import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSubagentTranscriptTests {
    @Test @MainActor
    func liveRecordSurvivesHeartbeatAndCancellation() {
        let store = AgentSubagentLiveTranscripts()
        let id = UUID()
        let round = makeRound(index: 1, toolCalls: 2)
        store.update(runID: id, label: "worker", prompt: "task", model: "model",
                     progress: .init(round: 1, maximumRounds: 32, completedToolInvocations: 2,
                                     activity: .thinking, recordedRounds: [round]))
        store.update(runID: id, label: "worker", prompt: "task", model: "model",
                     progress: .init(round: 2, maximumRounds: 32, completedToolInvocations: 2,
                                     activity: .thinking, recordedRounds: []))
        #expect(store.records[id]?.toolInvocationCount == 2)
        var final = makeTranscript(runID: id)
        final.status = .cancelled
        let saved = store.finish(final)
        #expect(saved.rounds == [round])
        store.update(runID: id, label: "worker", prompt: "task", model: "model",
                     progress: .init(round: 3, maximumRounds: 32, completedToolInvocations: 0,
                                     activity: .thinking))
        #expect(store.records[id]?.status == .cancelled)
    }
    private func makeTranscript(
        runID: UUID = UUID(),
        rounds: [AgentSubagentTranscript.Round] = []
    ) -> AgentSubagentTranscript {
        AgentSubagentTranscript(
            runID: runID,
            label: "audit permissions",
            prompt: "Check every tenant permission check.",
            model: "claude-opus-5",
            status: .completed,
            rounds: rounds,
            report: "Found three unguarded paths.",
            usageTokens: 4_200,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_760_000_042)
        )
    }

    private func makeRound(index: Int, toolCalls: Int) -> AgentSubagentTranscript.Round {
        AgentSubagentTranscript.Round(
            index: index,
            content: "round \(index) output",
            reasoning: nil,
            toolCalls: (0..<toolCalls).map { offset in
                AgentSubagentTranscript.ToolCall(
                    externalID: "call-\(index)-\(offset)",
                    name: "read_file",
                    argumentsJSON: #"{"path":"a.swift"}"#,
                    result: "file body",
                    resultWasTruncated: false,
                    durationSeconds: 0.25
                )
            },
            usageTokens: 100,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_760_000_010)
        )
    }

    // MARK: Storage caps

    @Test("text under the cap is recorded verbatim")
    func clampedLeavesShortTextAlone() {
        let (text, didTruncate) = AgentSubagentTranscript.clamped("short", to: 100)

        #expect(text == "short")
        #expect(!didTruncate)
    }

    @Test("oversized tool output is capped and reports the truncation")
    func clampedTruncatesAndReports() {
        let oversized = String(repeating: "x", count: 50)
        let (text, didTruncate) = AgentSubagentTranscript.clamped(oversized, to: 10)

        #expect(text.count == 10)
        #expect(didTruncate)
    }

    // MARK: Derived values

    @Test("tool invocation count sums across rounds")
    func toolInvocationCountAcrossRounds() {
        let transcript = makeTranscript(rounds: [
            makeRound(index: 1, toolCalls: 2),
            makeRound(index: 2, toolCalls: 3),
        ])

        #expect(transcript.toolInvocationCount == 5)
    }

    // MARK: Sidecar store

    @Test("a saved transcript loads back with its rounds intact")
    func saveAndLoadRoundTrip() throws {
        let runID = UUID()
        let transcript = makeTranscript(runID: runID, rounds: [makeRound(index: 1, toolCalls: 1)])
        defer { AgentSubagentTranscriptStore.delete(runID: runID) }

        AgentSubagentTranscriptStore.save(transcript)
        let loaded = try #require(AgentSubagentTranscriptStore.load(runID: runID))

        #expect(loaded == transcript)
        #expect(loaded.rounds.first?.toolCalls.first?.name == "read_file")
    }

    @Test("an unknown run id loads as nil rather than throwing")
    func loadingUnknownRunReturnsNil() {
        #expect(AgentSubagentTranscriptStore.load(runID: UUID()) == nil)
    }

    @Test("transcripts live outside the session directory")
    func storeDirectoryIsSeparateFromSessions() {
        // The whole point of the sidecar is to keep these bytes out of the
        // session store's write pipeline.
        #expect(AgentSubagentTranscriptStore.directory != AgentSessionStore.directory)
        #expect(AgentSubagentTranscriptStore.directory.lastPathComponent == "subagent-transcripts")
    }

    // MARK: skill-workers.v1 verifier fields

    @Test("verifier outcome and repo anchor survive a save/load round trip")
    func verifierFieldsRoundTrip() throws {
        let runID = UUID()
        var transcript = makeTranscript(runID: runID)
        transcript.verifierCommand = "swift test --filter AuthTests"
        transcript.verifierPassed = false
        transcript.attemptCount = 3
        transcript.repoCommit = "caba8df7"
        defer { AgentSubagentTranscriptStore.delete(runID: runID) }

        AgentSubagentTranscriptStore.save(transcript)
        let loaded = try #require(AgentSubagentTranscriptStore.load(runID: runID))

        #expect(loaded.verifierCommand == "swift test --filter AuthTests")
        #expect(loaded.verifierPassed == false)
        #expect(loaded.attemptCount == 3)
        #expect(loaded.repoCommit == "caba8df7")
    }

    @Test("sidecar files written before verifier fields existed still decode")
    func legacySidecarDecodesWithoutVerifierFields() throws {
        let legacyJSON = """
        {"runID":"11111111-2222-3333-4444-555555555555","label":"audit","prompt":"go",\
        "model":"glm-5","status":"completed","rounds":[],"report":"done","usageTokens":10,\
        "startedAt":"2026-08-01T00:00:00Z","didTruncate":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(AgentSubagentTranscript.self, from: Data(legacyJSON.utf8))

        // No verifier is nil, never false: absence of evidence must not
        // count as a failed verification in the KPI denominators.
        #expect(decoded.verifierCommand == nil)
        #expect(decoded.verifierPassed == nil)
        #expect(decoded.attemptCount == nil)
        #expect(decoded.repoCommit == nil)
    }

    // MARK: Runner outcome plumbing

    @Test("outcome rounds default to empty for callers that ignore recording")
    func outcomeDefaultsKeepExistingCallSitesValid() {
        let outcome = AgentSubagentRunner.Outcome(
            report: "done",
            usageTokens: 10,
            roundCount: 1,
            toolInvocationCount: 0
        )

        #expect(outcome.rounds.isEmpty)
        #expect(!outcome.didTruncate)
    }

    @Test("spawn_agent tool calls persist their run id with the message")
    func messageToolCallCarriesRunID() throws {
        let runID = UUID()
        let call = AgentMessageToolCall(
            externalID: "call_1",
            toolName: "spawn_agent",
            argumentsJSON: #"{"prompt":"go"}"#,
            subagentRunID: runID
        )

        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(AgentMessageToolCall.self, from: data)

        #expect(decoded.subagentRunID == runID)
    }

    @Test("tool calls recorded before run ids existed still decode")
    func messageToolCallDecodesWithoutRunID() throws {
        let legacyJSON = #"{"externalID":"call_1","toolName":"read_file","argumentsJSON":"{}"}"#

        let decoded = try JSONDecoder().decode(
            AgentMessageToolCall.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.subagentRunID == nil)
    }
}
