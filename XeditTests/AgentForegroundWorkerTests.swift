//
//  AgentForegroundWorkerTests.swift
//  XeditTests
//
//  Operations Workers always run in the foreground, and a background Worker
//  can be pulled into the foreground as a pinned live card.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentForegroundWorkerTests {
    // MARK: - Operations Workers are foreground-only

    @Test("运维 Worker 一律前台，其它工种不受影响")
    func opsRunnerIsForegroundOnly() {
        #expect(AgentSubagentSchedulingPolicy.mustRunInForeground(profileID: AgentSubagentProfileCatalog.opsRunnerID))
        #expect(!AgentSubagentSchedulingPolicy.mustRunInForeground(profileID: AgentSubagentProfileCatalog.generalistID))
        let notice = AgentSubagentSchedulingPolicy.foregroundOnlyNotice(profileID: AgentSubagentProfileCatalog.opsRunnerID)
        #expect(notice.contains("foreground"))
        #expect(notice.contains("run_in_background"))
    }

    @Test("spawn_agent 在最终工种确定后才决定前后台，且运维工种强制前台")
    func spawnPathForcesForegroundAfterProfileResolution() throws {
        // The spawn flow needs a live model and runtime, so this pins the
        // ordering in source: the forcing must read the *resolved* profile
        // and happen before both the convergence check and the background
        // branch that consume `runInBackground`.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Xedit/AppStateAgentToolMessages.swift"),
            encoding: .utf8
        )
        let forcing = try #require(source.range(of: "!AgentSubagentSchedulingPolicy.mustRunInForeground(profileID: profile.id)"))
        let resolution = try #require(source.range(of: "var profile = AgentSubagentProfileStore.resolvedProfile("))
        let convergence = try #require(source.range(of: "AgentOpsConvergencePolicy.shouldReturnToParent(profileID: profile.id,"))
        let backgroundBranch = try #require(source.range(of: "        if runInBackground {"))
        #expect(resolution.lowerBound < forcing.lowerBound)
        #expect(forcing.lowerBound < convergence.lowerBound)
        #expect(forcing.lowerBound < backgroundBranch.lowerBound)
        #expect(source.contains("foregroundOnlyNotice(profileID: profile.id)"))
    }

    @Test("spawn_agent 的参数说明写明运维 Worker 总在前台")
    func toolDescriptionStatesTheRule() throws {
        let spawn = try #require(AgentToolRegistry.descriptor(for: "spawn_agent"))
        let background = try #require(spawn.parameters.first { $0.name == "run_in_background" })
        #expect(background.description.contains("ops_runner always runs in the foreground"))
    }

    // MARK: - Pinning a background Worker

    private func workerCall(runID: UUID, background: Bool, finished: Bool) -> AgentToolCall {
        var call = AgentToolCall(
            messageID: UUID(), externalID: UUID().uuidString,
            toolName: "spawn_agent", arguments: ["prompt": .string("check pods"), "profile": .string("ops_runner")],
            risk: .read, status: background ? .succeeded : .running, approvalSource: nil
        )
        call.subagentRunID = runID
        var activity = AgentSubagentLiveActivity(
            profileID: AgentSubagentProfileCatalog.opsRunnerID,
            workerName: "运维",
            model: "deepseek-v4-flash",
            round: 8,
            maximumRounds: 32,
            completedToolInvocations: 24,
            activityText: "",
            startedAt: Date(),
            isBackground: background
        )
        if finished { activity.finishedAt = Date() }
        call.subagentLiveActivity = activity
        return call
    }

    @Test("切到前台：钉住后台 Worker，收回后台后卡片消失")
    func pinAndReturn() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        let runID = UUID()
        runtime.toolCalls = [workerCall(runID: runID, background: true, finished: false)]

        #expect(appState.isBackgroundWorker(runID: runID))
        #expect(appState.foregroundWorkerCall == nil)
        appState.showWorkerInForeground(runID: runID)
        #expect(appState.foregroundWorkerCall?.subagentRunID == runID)
        #expect(appState.foregroundWorkerCall?.subagentIsWorking == true)

        appState.returnForegroundWorkerToBackground()
        #expect(appState.foregroundWorkerCall == nil)
        #expect(runtime.toolCalls.count == 1)
    }

    @Test("前台 Worker 不当作可钉住的后台 Worker")
    func foregroundWorkerIsNotPinnable() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        let runID = UUID()
        runtime.toolCalls = [workerCall(runID: runID, background: false, finished: false)]
        #expect(!appState.isBackgroundWorker(runID: runID))
    }

    @Test("下一回合开始时：还在跑的钉住保留，已完成的自动释放")
    func finishedPinIsReleasedAtNextTurn() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        let runID = UUID()
        runtime.toolCalls = [workerCall(runID: runID, background: true, finished: false)]
        appState.showWorkerInForeground(runID: runID)

        appState.releaseFinishedForegroundWorker(for: runtime)
        #expect(runtime.foregroundWorkerRunID == runID)

        runtime.toolCalls = [workerCall(runID: runID, background: true, finished: true)]
        #expect(appState.foregroundWorkerCall?.subagentIsWorking == false)
        appState.releaseFinishedForegroundWorker(for: runtime)
        #expect(runtime.foregroundWorkerRunID == nil)
    }

    @Test("再钉另一个 Worker 会替换，不叠加")
    func pinningReplaces() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        let first = UUID()
        let second = UUID()
        runtime.toolCalls = [
            workerCall(runID: first, background: true, finished: false),
            workerCall(runID: second, background: true, finished: false),
        ]
        appState.showWorkerInForeground(runID: first)
        appState.showWorkerInForeground(runID: second)
        #expect(appState.foregroundWorkerCall?.subagentRunID == second)
    }
}
