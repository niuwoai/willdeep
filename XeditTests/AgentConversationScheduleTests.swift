import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentConversationScheduleTests {
    @Test("legacy chat tasks do not silently switch execution mode")
    func legacyModeRemainsIndependent() throws {
        let original = AgentRoutine(originSessionID: UUID())
        let encoded = try JSONEncoder().encode(original)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "continueInSession")
        let decoded = try JSONDecoder().decode(AgentRoutine.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.continueInSession)
        #expect(decoded.originSessionID == original.originSessionID)
    }

    @Test("completion stops future triggers and preserves configuration")
    func completionPersistsWithoutDeleting() throws {
        var routine = AgentRoutine(name: "复查", prompt: "检查结果", originSessionID: UUID(), continueInSession: true)
        routine.completedAt = Date()
        let restored = try JSONDecoder().decode(AgentRoutine.self, from: JSONEncoder().encode(routine))
        #expect(restored.nextFireDate() == nil)
        #expect(restored.prompt == routine.prompt)
        #expect(restored.continueInSession)
    }

    @Test("a busy source is skipped without creating a new session or changing permission")
    func busySourceIsSkipped() throws {
        let state = AppState()
        let session = AgentSession(approvalMode: .workspaceAccess)
        let runtime = AgentRuntime(session: session)
        state.agentSessions = [session]
        state.agentRuntimes[session.id] = runtime
        runtime.isResponding = true
        let routine = AgentRoutine(name: "复查", prompt: "检查实际结果", originSessionID: session.id, continueInSession: true)
        state.agentRoutines = [routine]
        defer { AgentRoutineStore.delete(id: routine.id); runtime.isResponding = false }
        #expect(state.fireRoutine(id: routine.id) == nil)
        #expect(state.agentSessions.count == 1)
        #expect(runtime.approvalMode == .workspaceAccess)
        let run = try #require(state.agentRoutineRuns.first(where: { $0.routineID == routine.id }))
        #expect(run.outcome == .skipped)
        #expect(run.sessionID == session.id)
        #expect(state.agentRoutines.first?.lastRunAt != nil)
    }

    @Test("a scheduled continuation has temporary unattended state and records its result")
    func completionResetsOnlyScheduledDispatchState() throws {
        let state = AppState()
        let session = AgentSession()
        let runtime = AgentRuntime(session: session)
        let routine = AgentRoutine(name: "复查", prompt: "检查结果", originSessionID: session.id, continueInSession: true)
        runtime.activeScheduledRoutineID = routine.id
        runtime.messages = [AgentMessage(role: .user, content: "复查"), AgentMessage(role: .assistant, content: "实际检查结果")]
        state.agentRoutineRuns = [AgentRoutineRunRecord(routineID: routine.id, routineName: routine.name, sessionID: session.id)]
        #expect(runtime.isUnattendedRun)
        state.recordRoutineRunCompletionIfNeeded(for: runtime)
        #expect(runtime.activeScheduledRoutineID == nil)
        #expect(runtime.session.originRoutineID == nil)
        #expect(!runtime.isUnattendedRun)
        #expect(state.agentRoutineRuns.first?.outcome == .succeeded)
        #expect(state.agentRoutineRuns.first?.finishedAt != nil)
    }

    @Test("an old reply does not turn an interrupted scheduled turn into success")
    func oldReplyIsNotCurrentRunEvidence() {
        let state = AppState()
        let session = AgentSession()
        let runtime = AgentRuntime(session: session)
        let routine = AgentRoutine(originSessionID: session.id, continueInSession: true)
        runtime.activeScheduledRoutineID = routine.id
        runtime.messages = [AgentMessage(role: .user, content: "旧任务"), AgentMessage(role: .assistant, content: "旧结果"), AgentMessage(role: .user, content: "定时复查")]
        state.agentRoutineRuns = [AgentRoutineRunRecord(routineID: routine.id, routineName: routine.name, sessionID: session.id)]
        state.recordRoutineRunCompletionIfNeeded(for: runtime)
        #expect(state.agentRoutineRuns.first?.outcome == .interrupted)
    }
}
