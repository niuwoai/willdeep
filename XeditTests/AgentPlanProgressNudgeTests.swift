import Foundation
import Testing
@testable import WillDeep

/// The model is asked to call `update_plan` at every step change and mostly
/// reports only when the turn is over. The host now counts tool rounds
/// against an executing plan and asks after a fixed number of silent ones,
/// and Worker heartbeats are mirrored onto the plan card's in-progress step.
@Suite
struct AgentPlanProgressNudgeTests {
    // MARK: Policy

    @Test("no nudge below the threshold, one at it, none without an executing plan")
    func thresholdGatesTheNudge() {
        let limit = AgentPlanProgressNudgePolicy.roundThreshold
        #expect(!AgentPlanProgressNudgePolicy.shouldNudge(
            roundsSinceLastUpdate: limit - 1, hasActivePlan: true, isUnattendedDispatchTask: false
        ))
        #expect(AgentPlanProgressNudgePolicy.shouldNudge(
            roundsSinceLastUpdate: limit, hasActivePlan: true, isUnattendedDispatchTask: false
        ))
        #expect(!AgentPlanProgressNudgePolicy.shouldNudge(
            roundsSinceLastUpdate: limit * 3, hasActivePlan: false, isUnattendedDispatchTask: false
        ))
    }

    /// An unattended dispatch node has nobody reading the card; nudging it
    /// would only spend rounds.
    @Test("unattended dispatch tasks are never nudged")
    func unattendedTasksAreExempt() {
        #expect(!AgentPlanProgressNudgePolicy.shouldNudge(
            roundsSinceLastUpdate: 50, hasActivePlan: true, isUnattendedDispatchTask: true
        ))
    }

    @Test("the notice names the count and the tool")
    func noticeIsActionable() {
        let notice = AgentPlanProgressNudgePolicy.notice(roundsSinceLastUpdate: 7)
        #expect(notice.contains("7 tool rounds"))
        #expect(notice.contains("`update_plan`"))
        #expect(notice.hasPrefix("=== PROGRESS REPORT DUE ==="))
    }

    // MARK: Plan step detail

    /// Plans persisted before the field existed must still decode.
    @Test("a persisted step without detail decodes with nil detail")
    func stepDetailIsOptionalOnDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"改代码","status":"in_progress"}"#
        let step = try JSONDecoder().decode(AgentPlan.Step.self, from: Data(json.utf8))
        #expect(step.detail == nil)
        #expect(step.status == .inProgress)
    }

    @Test("detail round-trips through Codable")
    func stepDetailRoundTrips() throws {
        let step = AgentPlan.Step(text: "跑测试", status: .inProgress, detail: "测试员 · 第 2/8 轮")
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(AgentPlan.Step.self, from: data)
        #expect(decoded == step)
    }

    // MARK: Worker → plan card projection

    @MainActor
    private func fixture() throws -> (AppState, AgentRuntime, AgentToolCall.ID) {
        let app = AppState(
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            loadSessionCatalog: false
        )
        let session = app.startNewAgentSession()
        let runtime = try #require(app.agentRuntimes[session.id])
        runtime.currentPlan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "查证据", status: .done),
                AgentPlan.Step(text: "改代码", status: .inProgress),
                AgentPlan.Step(text: "跑测试", status: .pending),
            ]
        )
        let call = AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: "spawn_agent",
            arguments: [:],
            risk: .write,
            status: .running
        )
        runtime.toolCalls.append(call)
        return (app, runtime, call.id)
    }

    @Test("a Worker heartbeat lands on the in-progress step and only there")
    @MainActor
    func heartbeatProjectsOntoInProgressStep() throws {
        let (app, runtime, callID) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }

        app.applySubagentLiveProgress(
            AgentSubagentProgressUpdate(
                round: 3, maximumRounds: 8, completedToolInvocations: 5, activity: .runningTool("grep_files")
            ),
            recordID: callID,
            runtime: runtime,
            profileID: "implementer",
            workerName: "实现者",
            model: "deepseek-v4-flash"
        )

        let steps = try #require(runtime.currentPlan?.steps)
        let detail = try #require(steps[1].detail)
        #expect(detail.hasPrefix("实现者 · "))
        #expect(detail.contains("3"))
        #expect(steps[0].detail == nil)
        #expect(steps[2].detail == nil)
    }

    /// A settled step must never keep "round 3/8" under it.
    @Test("the closing heartbeat clears the detail")
    @MainActor
    func finishedWorkerClearsDetail() throws {
        let (app, runtime, callID) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        let progress = AgentSubagentProgressUpdate(
            round: 1, maximumRounds: 8, completedToolInvocations: 0, activity: .thinking
        )
        app.applySubagentLiveProgress(
            progress, recordID: callID, runtime: runtime,
            profileID: "implementer", workerName: "实现者", model: "m"
        )
        #expect(runtime.currentPlan?.steps[1].detail != nil)

        app.applySubagentLiveProgress(
            .runFinished, recordID: callID, runtime: runtime,
            profileID: "implementer", workerName: "实现者", model: "m"
        )
        #expect(runtime.currentPlan?.steps[1].detail == nil)
    }

    @Test("no in-progress step means nothing to project")
    @MainActor
    func noInProgressStepIsANoOp() throws {
        let (app, runtime, callID) = try fixture()
        defer { AgentSessionStore.delete(id: runtime.id) }
        runtime.currentPlan?.steps[1].status = .done
        let before = runtime.currentPlan

        app.applySubagentLiveProgress(
            AgentSubagentProgressUpdate(round: 1, maximumRounds: 8, completedToolInvocations: 0, activity: .thinking),
            recordID: callID, runtime: runtime,
            profileID: "implementer", workerName: "实现者", model: "m"
        )
        #expect(runtime.currentPlan == before)
    }
}
