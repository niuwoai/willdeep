import Foundation
import Testing
@testable import WillDeep

/// A Goal completion candidate left in `.verifying` by a killed process must
/// come back into host verification, and a verifier still alive in this
/// process must keep ownership of its candidate.
@MainActor
@Suite("Goal 验收中断后重启归位", .serialized)
struct AgentGoalVerificationRelaunchTests {
    // MARK: - Pure restore policy

    @Test("陈旧 verifying 归位为 pending 并打上重启恢复标记；其它阶段原样保留")
    func staleVerifyingIsRequeued() {
        let registry = AgentGoalVerificationInFlightRegistry()
        let stale = makeGoal(phase: .verifying)
        let restored = AgentGoalVerificationRelaunchPolicy.normalizedForRestore(stale, registry: registry)
        #expect(restored.verification?.phase == .pending)
        #expect(restored.verification?.relaunchRecoveryPending == true)
        #expect(restored.verification?.id == stale.verification?.id)
        #expect(AgentGoalVerificationRelaunchPolicy.needsRecovery(stale, registry: registry))
        #expect(AgentGoalVerificationRelaunchPolicy.needsRecovery(restored, registry: registry))

        for phase in [AgentGoalVerification.Phase.pending, .rejected, .verified] {
            let settled = makeGoal(phase: phase)
            #expect(AgentGoalVerificationRelaunchPolicy.normalizedForRestore(settled, registry: registry) == settled)
            #expect(!AgentGoalVerificationRelaunchPolicy.needsRecovery(settled, registry: registry))
        }
        let noCandidate = AgentGoal(statement: "x", checklist: [.init(text: "y")])
        #expect(AgentGoalVerificationRelaunchPolicy.normalizedForRestore(noCandidate, registry: registry) == noCandidate)
    }

    @Test("本进程仍在复核的候选不被归位，也不触发恢复")
    func liveVerifierKeepsOwnership() throws {
        let registry = AgentGoalVerificationInFlightRegistry()
        let live = makeGoal(phase: .verifying)
        let id = try #require(live.verification?.id)
        registry.begin(id)
        #expect(AgentGoalVerificationRelaunchPolicy.normalizedForRestore(live, registry: registry) == live)
        #expect(!AgentGoalVerificationRelaunchPolicy.needsRecovery(live, registry: registry))
        registry.end(id)
        #expect(AgentGoalVerificationRelaunchPolicy.normalizedForRestore(live, registry: registry).verification?.phase == .pending)
    }

    @Test("新增的恢复标记可选：旧 JSON 能解，标记能往返")
    func markerIsBackwardsCompatible() throws {
        let plain = try #require(makeGoal(phase: .pending).verification)
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("relaunchRecoveryPending"))
        #expect(try JSONDecoder().decode(AgentGoalVerification.self, from: Data(plainJSON.utf8)).relaunchRecoveryPending == nil)
        var marked = plain
        marked.relaunchRecoveryPending = true
        #expect(try JSONDecoder().decode(AgentGoalVerification.self, from: JSONEncoder().encode(marked)) == marked)
    }

    // MARK: - Launch recovery policy

    @Test("计划已收尾、验收中断：启动恢复不再丢弃，而是恢复验收")
    func finishedPlanResumesVerification() {
        for checkpoint in [nil, AgentGoalTurnRecoveryCheckpoint()] {
            let session = makeSession(planStatus: .done, phase: .verifying, checkpoint: checkpoint)
            #expect(AgentGoalLaunchRecoveryPolicy.action(for: session) == .resumeVerification)
        }
        let rejected = makeSession(planStatus: .done, phase: .rejected)
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: rejected) == .none)
    }

    @Test("执行中的计划：有检查点仍走原执行恢复，无检查点靠验收中断恢复")
    func executingPlanPrefersExecutionCheckpoint() {
        let withCheckpoint = makeSession(planStatus: .executing, phase: .verifying,
            checkpoint: AgentGoalTurnRecoveryCheckpoint())
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: withCheckpoint) == .resumeExecution)
        let withoutCheckpoint = makeSession(planStatus: .executing, phase: .verifying)
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: withoutCheckpoint) == .resumeVerification)
    }

    @Test("恢复后的 runtime 状态经 reconcile 仍判定为恢复验收；进行中的不判")
    func restoredRuntimeReconcilesToVerificationRecovery() throws {
        let session = makeSession(planStatus: .done, phase: .verifying)
        let restored = AgentRuntime(session: session)
        #expect(restored.currentGoal?.verification?.phase == .pending)
        var live = restored.session
        live.currentGoal = restored.currentGoal
        live.currentPlan = restored.currentPlan
        live.goalPlanningState = restored.goalPlanningState
        #expect(live.goalPlanningState?.phase == .executing)
        #expect(AgentGoalLaunchRecoveryPolicy.reconciledAction(catalogAction: .resumeVerification,
            restoredSession: live) == .resumeVerification)

        let owned = makeSession(planStatus: .done, phase: .verifying)
        let ownedID = try #require(owned.currentGoal?.verification?.id)
        AgentGoalVerificationInFlightRegistry.shared.begin(ownedID)
        defer { AgentGoalVerificationInFlightRegistry.shared.end(ownedID) }
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: owned) == .none)
        #expect(AgentRuntime(session: owned).currentGoal?.verification?.phase == .verifying)
    }

    // MARK: - Host verification re-entry

    @Test("重启归位后的候选能再次进入宿主复验并通过")
    func requeuedCandidateReentersHostVerification() async throws {
        let f = try verificationFixture(); defer { f.cleanup() }
        #expect(!f.app.captureAgentGoalEvaluationFromLatestMessage(for: f.runtime))
        // The process died right after host verification persisted
        // `.verifying`; the verifier is gone with it.
        var persisted = f.runtime.session
        persisted.currentGoal?.verification?.phase = .verifying
        let candidateID = try #require(persisted.currentGoal?.verification?.id)

        let restored = relaunchRuntime(f, from: persisted)
        #expect(restored.currentGoal?.verification?.phase == .pending)
        #expect(restored.currentGoal?.verification?.relaunchRecoveryPending == true)
        #expect(restored.currentGoal?.verification?.id == candidateID)
        installReviewer(f, runtime: restored)
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: restored))
        #expect(restored.currentGoal?.verification?.phase == .verified)
        #expect(restored.currentGoal?.verification?.relaunchRecoveryPending == nil)
        #expect(restored.currentGoal?.checklist.allSatisfy(\.done) == true)
        #expect(!AgentGoalVerificationInFlightRegistry.shared.contains(candidateID))
    }

    @Test("复核进行中另一处恢复同一会话不打断它，复核照常完成")
    func inFlightVerificationIsNotInterrupted() async throws {
        let f = try verificationFixture(); defer { f.cleanup() }
        #expect(!f.app.captureAgentGoalEvaluationFromLatestMessage(for: f.runtime))
        let candidateID = try #require(f.runtime.currentGoal?.verification?.id)
        var release: CheckedContinuation<Void, Never>?
        var verification: Task<Bool, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            installReviewer(f, runtime: f.runtime) {
                started.resume()
                await withCheckedContinuation { release = $0 }
            }
            verification = Task { await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) }
        }
        #expect(AgentGoalVerificationInFlightRegistry.shared.contains(candidateID))
        #expect(f.runtime.session.currentGoal?.verification?.phase == .verifying)
        let secondWindow = AgentRuntime(session: f.runtime.session)
        #expect(secondWindow.currentGoal?.verification?.phase == .verifying)
        #expect(secondWindow.currentGoal?.verification?.relaunchRecoveryPending == nil)
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: f.runtime.session) != .resumeVerification)
        #expect(f.runtime.currentGoal?.verification?.phase == .verifying)

        release?.resume()
        let task = try #require(verification)
        #expect(await task.value)
        #expect(f.runtime.currentGoal?.verification?.phase == .verified)
        #expect(!AgentGoalVerificationInFlightRegistry.shared.contains(candidateID))
    }

    // MARK: - Launch dispatch

    @Test("启动恢复为中断的验收派发一次续推，接受后清除标记，不重复派发")
    func launchRecoveryDispatchesOnce() throws {
        let f = try launchFixture(); defer { f.cleanup() }
        #expect(f.runtime.currentGoal?.verification?.relaunchRecoveryPending == true)
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch() == [f.runtime.id])
        let queued = f.app.pendingDispatchQueue.filter { $0.runtimeID == f.runtime.id }
        #expect(queued.count == 1)
        #expect(queued.first?.text.contains("verifying this Goal's latest completion candidate") == true)
        #expect(f.runtime.currentGoal?.verification?.relaunchRecoveryPending == nil)
        #expect(f.runtime.currentGoal?.verification?.phase == .pending)
        #expect(f.app.resumeInterruptedGoalSessionsAfterLaunch().isEmpty)
        #expect(f.app.pendingDispatchQueue.count == 1)
    }

    // MARK: - Fixtures

    private func makeGoal(phase: AgentGoalVerification.Phase) -> AgentGoal {
        var goal = AgentGoal(statement: "Ship verified work", checklist: [.init(text: "Work verified")])
        var verification = AgentGoalVerification(id: UUID(), messageID: UUID(),
            contractDigest: AgentGoalVerification.contractDigest(goal), criterionIDs: goal.checklist.map(\.id))
        verification.phase = phase
        goal.verification = verification
        return goal
    }

    private func makeSession(
        planStatus: AgentPlan.Status,
        phase: AgentGoalVerification.Phase,
        checkpoint: AgentGoalTurnRecoveryCheckpoint? = nil
    ) -> AgentSession {
        let goal = makeGoal(phase: phase)
        let stepStatus: AgentPlan.StepStatus = planStatus == .done ? .done : .inProgress
        var session = AgentSession(
            interactionMode: .goal,
            currentPlan: AgentPlan(status: planStatus, steps: [.init(text: "Implement", status: stepStatus)], summary: ""),
            currentGoal: goal,
            goalTurnRecoveryCheckpoint: checkpoint
        )
        session.goalPlanningState = AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal),
            phase: .executing,
            members: [
                .init(roleID: "requirements", displayName: "Requirements", status: .completed),
                .init(roleID: "architecture", displayName: "Architecture", status: .completed),
                .init(roleID: "testing", displayName: "Testing", status: .completed),
            ]
        )
        return session
    }

    @MainActor private struct VerificationFixture {
        let app: AppState
        let runtime: AgentRuntime
        let root: URL
        let defaults: UserDefaults
        let suite: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            AgentSessionStore.delete(id: runtime.id)
            do { try FileManager.default.removeItem(at: root) } catch {
                Issue.record("Relaunch fixture cleanup failed: \(error)")
            }
        }
    }

    private func verificationFixture() throws -> VerificationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-relaunch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "goal-relaunch-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults,
            loadSessionCatalog: false)
        let session = app.startNewAgentSession(inWorkspaceAt: root.path)
        let runtime = try #require(app.runtime(for: session.id))
        runtime.interactionMode = .goal
        runtime.currentGoal = .init(statement: "交付经过验证的成果", checklist: [.init(text: "成果正确")])
        runtime.messages = [AgentMessage(role: .assistant, content: "已完成\n```goal-check\n1: done\n```")]
        try Data("verified source\n".utf8).write(to: root.appendingPathComponent("report.md"))
        runtime.toolCalls.append(.init(messageID: UUID(), externalID: UUID().uuidString, toolName: "read_file",
            arguments: ["path": .string("report.md")], risk: .read, status: .succeeded,
            result: .init(summary: "read", payload: "fixture read")))
        return .init(app: app, runtime: runtime, root: root, defaults: defaults, suite: suite)
    }

    /// Stand-in for a relaunch: a new runtime built from the persisted
    /// session replaces the live one. Tool receipts are runtime-only, so the
    /// fixture's evidence read is carried over by hand.
    private func relaunchRuntime(_ f: VerificationFixture, from session: AgentSession) -> AgentRuntime {
        let runtime = AgentRuntime(session: session)
        runtime.toolCalls = f.runtime.toolCalls
        f.app.agentRuntimes[session.id] = runtime
        return runtime
    }

    private func installReviewer(_ f: VerificationFixture, runtime: AgentRuntime,
                                 beforeReturn: (@MainActor () async -> Void)? = nil) {
        f.app.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _, _, _, _, _ in
            let raw = try #require(prompt.components(separatedBy: "Host evidence:\n").last)
            let evidence = try JSONDecoder().decode([AgentGoalVerification.Evidence].self, from: Data(raw.utf8))
            let candidate = try #require(runtime.currentGoal?.verification)
            let review = AgentGoalVerification.Review(verdicts: candidate.criterionIDs.map {
                .init(criterionID: $0, kind: .analysis, passed: true, evidenceIDs: evidence.map(\.id),
                      detail: "Evidence covers the criterion.")
            })
            await beforeReturn?()
            return .init(report: String(decoding: try JSONEncoder().encode(review), as: UTF8.self), usageTokens: 1,
                         roundCount: 1, toolInvocationCount: 0)
        }
    }

    @MainActor private struct LaunchFixture {
        let app: AppState
        let runtime: AgentRuntime
        let network: URLSession
        func cleanup() {
            app.goalLaunchRecoveryTask?.cancel()
            app.cancelPendingGoalLaunchRecovery(for: runtime)
            runtime.requestTask?.cancel()
            app.pendingDispatchQueue.removeAll()
            network.invalidateAndCancel()
            AgentSessionStore.delete(id: runtime.id)
        }
    }

    private func launchFixture() throws -> LaunchFixture {
        let session = makeSession(planStatus: .done, phase: .verifying)
        let app = AppState(runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            loadSessionCatalog: false)
        app.agentSessions = [session]
        app.markSessionCatalogLoadedForTesting()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalLoopURLProtocol.self]
        let network = URLSession(configuration: configuration)
        app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://relaunch-verification.invalid/v1",
            model: "fixture", apiKey: "test-placeholder"), network)
        // Accepted into the real dispatch queue, never a network request.
        app.inFlightCountByProvider["openai"] = app.perProviderConcurrencyLimit + 1
        let runtime = try #require(app.runtime(for: session.id))
        return .init(app: app, runtime: runtime, network: network)
    }
}
