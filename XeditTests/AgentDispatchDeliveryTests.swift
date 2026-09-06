import Foundation
import Testing
@testable import WillDeep

@Suite("宿主验收到真实下游交付", .serialized)
@MainActor
struct AgentDispatchDeliveryTests {
    @Test("验收不允许切换目录、内联执行、只列测试或持续监听")
    func verificationCommandBoundary() {
        for command in ["ruby verify_test.rb", "yarn test", "swift test", "go test ./..."] {
            #expect(AppState.isCandidateVerificationCommand(command))
        }
        for command in ["ruby verify_test.rb -C../other", "ruby verify_test.rb -eexit", "yarn test --cwd=../other",
                        "swift test --list-tests", "yarn test --watch", "ruby /tmp/test.rb", "yarn test; git push"] {
            #expect(!AppState.isCandidateVerificationCommand(command))
        }
    }

    @Test("推断的第七条验收失败仍阻止交付与下游解锁")
    func laterInferredVerificationFailureBlocksDelivery() async throws {
        let f = try await fixture(commands: [], verifierBody:
            "abort 'seventh verifier failed' if ARGV.first == '7'\nputs 'verified interface'\n")
        defer { f.cleanup() }
        let commands = (1...7).map { "ruby verify_test.rb \($0)" }
        for command in commands + [commands[0], commands[6]] {
            f.runtime.toolCalls.append(.init(messageID: UUID(), externalID: UUID().uuidString,
                toolName: "run_command", arguments: ["command": .string(command)],
                risk: .read, status: .succeeded,
                result: .init(summary: "previous worker claim", payload: "must be replayed by host")))
        }
        #expect(AppState.dispatchVerificationCommands(task: try f.task(f.firstID), runtime: f.runtime) == commands)
        do {
            try await f.deliver()
            Issue.record("A failing seventh verifier must prevent publication")
        } catch {
            #expect(error.localizedDescription.contains("seventh verifier failed"))
        }
        let loaded = try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)
        let record = try #require(loaded)
        #expect(record.phase == .prepared)
        #expect(record.verificationReceipt == nil)
        #expect(try f.task(f.firstID).integrationReceipt == nil)
        #expect(try f.task(f.nextID).state != .queued)
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: f.repository,
            goalID: f.goalID, baseRevision: f.base) == f.base)
    }

    @Test("全部七条推断验收通过时完整记录回执且不重复执行")
    func allInferredVerifiersAppearInReceipt() async throws {
        let f = try await fixture(commands: [], verifierBody: "puts 'verified interface'\n")
        defer { f.cleanup() }
        let commands = (1...7).map { "ruby verify_test.rb \($0)" }
        for command in commands + commands {
            f.runtime.toolCalls.append(.init(messageID: UUID(), externalID: UUID().uuidString,
                toolName: "run_command", arguments: ["command": .string(command)],
                risk: .read, status: .succeeded,
                result: .init(summary: "previous worker claim", payload: "must be replayed by host")))
        }
        try await f.deliver()
        let loaded = try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)
        let record = try #require(loaded)
        #expect(record.phase == .delivered)
        #expect(record.verificationReceipt?.commands == commands)
        #expect(record.verificationReceipt?.outputDigests.count == commands.count)
        #expect(try f.task(f.nextID).state == .queued)
    }

    private struct Fixture {
        let root: URL
        let repository: URL
        let checkout: URL
        let base: String
        let defaults: UserDefaults
        let suite: String
        let app: AppState
        let runtime: AgentRuntime
        let goalID: UUID
        let firstID: UUID
        let nextID: UUID

        func task(_ id: UUID) throws -> AgentDispatchTask {
            try #require(app.agentDispatchCoordinator.goals.first(where: { $0.id == goalID })?.tasks.first(where: { $0.id == id }))
        }

        func deliver() async throws {
            try await app.deliverVerifiedDispatchTask(runtime: runtime, goalID: goalID, taskID: firstID)
        }

        func cleanup() {
            app.invalidateDispatchMonitor(taskID: firstID)
            app.invalidateDispatchMonitor(taskID: nextID)
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
    }

    @Test("后续节点改坏先前产物时组合回归阻止交付，修复后自动通过", arguments: [false, true])
    func combinedCandidateRechecksEarlierNode(operatorOverride: Bool) async throws {
        let f = try await fixture(verifierBody:
            "abort 'prior interface regressed' unless ARGV.first == 'current' || File.read('interface.txt') == \"A\\n\"\nputs 'verified'\n")
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try await f.deliver()
        let receipt = try #require(try f.task(f.firstID).integrationReceipt)
        let checkout = f.root.appendingPathComponent("second-worker")
        _ = try await git(["worktree", "add", "--detach", checkout.path, receipt.integratedRevision], at: f.repository)
        #expect(try await AgentDispatchArtifactIntegrator.repositoryIdentity(in: checkout)
            == AgentDispatchArtifactIntegrator.repositoryIdentity(in: f.repository))
        let child = f.app.startNewAgentSession(inWorkspaceAt: checkout.path)
        let runtime = try #require(f.app.runtime(for: child.id))
        runtime.session.dispatchParentProjectID = f.goalID
        runtime.session.dispatchTaskID = f.nextID
        runtime.agentEditedPaths = ["interface.txt"]
        runtime.currentGoal = .init(statement: "Consumer", checklist: [.init(text: "Consumer works", done: true)])
        let goal = try #require(f.app.agentDispatchCoordinator.goals.first { $0.id == f.goalID })
        let binding = try #require(goal.resolvedWorkspaceBinding(for: try f.task(f.nextID)))
        f.app.agentDispatchCoordinator.pinTaskInputRevision(goalID: f.goalID, taskID: f.nextID,
            bindingID: binding.id, baseRevision: f.base, inputRevision: receipt.integratedRevision)
        f.app.agentDispatchCoordinator.markTaskStarted(goalID: f.goalID, taskID: f.nextID,
            executor: .willDeep, target: .local, runtimeSessionID: runtime.id)
        f.app.agentDispatchCoordinator.updateTask(goalID: f.goalID, taskID: f.nextID) {
            $0.verificationCommands = ["ruby verify_test.rb current", "ruby verify_test.rb current"]
        }
        if operatorOverride { f.app.agentDispatchCoordinator.recordOperatorAcceptance(goalID: f.goalID, taskID: f.nextID) }
        _ = f.app.beginDispatchMonitor(runtimeID: runtime.id, taskID: f.nextID)
        try Data("broken\n".utf8).write(to: checkout.appendingPathComponent("interface.txt"))
        do {
            try await f.app.deliverVerifiedDispatchTask(runtime: runtime, goalID: f.goalID, taskID: f.nextID)
            Issue.record("Current-node success must not hide a prior-node regression")
        } catch { #expect(error.localizedDescription.contains("prior interface regressed")) }
        #expect(try f.task(f.nextID).state != .merged)
        #expect(f.app.agentDispatchCoordinator.goals.first { $0.id == f.goalID }?.isComplete == false)
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: f.repository,
            goalID: f.goalID, baseRevision: f.base) == receipt.integratedRevision)
        try Data("A\n".utf8).write(to: checkout.appendingPathComponent("interface.txt"))
        try await f.app.deliverVerifiedDispatchTask(runtime: runtime, goalID: f.goalID, taskID: f.nextID)
        let record = try #require(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.nextID))
        let expected = operatorOverride ? ["ruby verify_test.rb"] : ["ruby verify_test.rb", "ruby verify_test.rb current"]
        #expect(record.verificationReceipt?.commands == expected)
        #expect(record.verificationReceipt?.outputDigests.count == expected.count)
        #expect(record.phase == .delivered)
        #expect(try await git(["rev-parse", "HEAD"], at: f.repository) == f.base)
    }

    @Test("交付新代次隔离旧终态与停止回执，重验不覆盖历史证据")
    func deliveryRevisionPreservesOldEvidence() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try await f.deliver()
        let legacy = f.app.dispatchDeliveryJournal
        let original = try #require(try legacy.load(goalID: f.goalID, taskID: f.firstID))
        let revisionID = UUID()
        f.app.agentDispatchCoordinator.updateTask(goalID: f.goalID, taskID: f.firstID) {
            $0.deliveryRevisionID = revisionID
            $0.state = .reviewing
            $0.integrationReceipt = nil
            $0.integrationCandidate = nil
            $0.operatorAcceptedAt = nil
        }
        let restoredBoard = AgentDispatchCoordinator(store: AgentDispatchStore(defaults: f.defaults))
        #expect(restoredBoard.goals.first { $0.id == f.goalID }?.tasks.first { $0.id == f.firstID }?.deliveryRevisionID == revisionID)
        #expect(throws: AgentDispatchJournalError.invalidTransition) {
            try f.app.agentDispatchCoordinator.applyDeliveredRecord(original)
        }
        let revised = try f.app.dispatchDeliveryJournal(goalID: f.goalID, taskID: f.firstID)
        #expect(try revised.load(goalID: f.goalID, taskID: f.firstID) == nil)
        let prepared = AgentDispatchDeliveryRecord(goalID: f.goalID, taskID: f.firstID,
            runtimeID: f.runtime.id, deliveryRevisionID: revisionID, generation: 0,
            phase: .prepared, candidate: original.candidate)
        try revised.save(prepared, expectedGeneration: nil)
        f.app.stopDispatchDelivery(goalID: f.goalID, taskID: f.firstID)
        #expect(try revised.load(goalID: f.goalID, taskID: f.firstID)?.phase == .stopped)
        #expect(try legacy.load(goalID: f.goalID, taskID: f.firstID) == original)
        #expect(throws: AgentDispatchDeliveryError.self) {
            try f.app.resumeStoppedDispatchDelivery(goalID: f.goalID, taskID: f.firstID,
                runtimeID: f.runtime.id, explicitlyRequested: false)
        }
        try f.app.resumeStoppedDispatchDelivery(goalID: f.goalID, taskID: f.firstID,
            runtimeID: f.runtime.id, explicitlyRequested: true)
        _ = f.app.beginDispatchMonitor(runtimeID: f.runtime.id, taskID: f.firstID)
        try await f.deliver()
        let result = try #require(try revised.load(goalID: f.goalID, taskID: f.firstID))
        #expect(result.phase == .delivered && result.deliveryRevisionID == revisionID)
        #expect(result.verificationID != original.verificationID)
        #expect(try legacy.load(goalID: f.goalID, taskID: f.firstID) == original)
        #expect(try f.task(f.firstID).state == .merged)
    }

    @Test("已交付节点编辑或重新规划后自动续跑，暂停仍保持暂停", arguments: [false, true], [false, true])
    func editedOutcomeAutomaticallyQueuesFreshExecution(paused: Bool, projection: Bool) async throws {
        let f = try await fixture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalLoopURLProtocol.self]
        let network = URLSession(configuration: configuration)
        defer {
            f.app.dispatchDecisionResumptionTask?.cancel()
            f.app.pendingDispatchQueue.removeAll()
            network.invalidateAndCancel()
            f.cleanup()
        }
        f.app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://outcome-revision.invalid/v1",
            model: "fixture", apiKey: "test-placeholder"), network)
        f.app.inFlightCountByProvider["openai"] = f.app.perProviderConcurrencyLimit + 1
        f.app.agentDispatchCoordinator.updateTask(goalID: f.goalID, taskID: f.firstID) { $0.executorChoice = .willDeep }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try await f.deliver()
        let original = try #require(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID))
        f.app.agentDispatchCoordinator.updateGoal(id: f.goalID) { $0.isPaused = paused }
        if projection {
            let parent = try #require(f.app.runtime(for: f.goalID))
            parent.currentGoal?.dispatchPlan?.nodes[0].title = "Updated interface"
            parent.currentGoal?.dispatchPlan?.nodes[0].acceptanceCriteria = ["Interface A and a new report"]
            f.app.persistAgentSession(runtime: parent)
            f.app.agentDispatchCoordinator.synchronize(with: f.app.agentSessions)
        } else {
            #expect(f.app.reviseDispatchTaskOutcome(goalID: f.goalID, taskID: f.firstID,
                title: "Updated interface", acceptanceCriteria: ["Interface A and a new report"]))
        }
        if paused {
            #expect(f.app.dispatchDecisionResumptionTask == nil)
            #expect(try f.task(f.firstID).state == .queued)
            #expect(try f.task(f.firstID).runtimeSessionID == f.runtime.id)
            #expect(f.app.pendingDispatchQueue.isEmpty)
            return
        }
        #expect(f.app.dispatchDecisionResumptionTask != nil)
        await f.app.dispatchDecisionResumptionTask?.value
        let task = try f.task(f.firstID)
        let runtimeID = try #require(task.runtimeSessionID)
        let fresh = try #require(f.app.loadedRuntime(for: runtimeID))
        #expect(runtimeID != f.runtime.id)
        #expect(task.deliveryRevisionID != nil && task.pendingOutcomeRevision != true)
        #expect(fresh.currentGoal?.checklist.map(\.text) == ["Interface A and a new report"])
        #expect(fresh.currentGoal?.checklist.allSatisfy { !$0.done } == true)
        #expect(fresh.agentEditedPaths == ["interface.txt"])
        #expect(fresh.workspaceLocation == f.runtime.workspaceLocation)
        #expect(fresh.isAwaitingProviderSlot && fresh.requestTask == nil)
        #expect(f.app.pendingDispatchQueue.filter { $0.runtimeID == runtimeID }.count == 1)
        #expect(try f.task(f.nextID).state == .blocked)
        #expect(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID) == original)
        f.app.agentDispatchCoordinator.synchronize(with: f.app.agentSessions)
        #expect(try f.task(f.firstID).title == "Updated interface")
    }

    private func seedVerifiedCheckpoint(_ f: Fixture) async throws -> AgentDispatchDeliveryRecord {
        let snapshot = try await AgentDispatchArtifactIntegrator.snapshot(in: f.checkout,
            goalID: f.goalID, taskID: f.firstID, baseRevision: f.base, paths: ["interface.txt"])
        let candidate = try await AgentDispatchArtifactIntegrator.prepareIntegration(snapshot,
            in: f.repository, goalID: f.goalID, goalBaseRevision: f.base)
        var record = AgentDispatchDeliveryRecord(goalID: f.goalID, taskID: f.firstID,
            runtimeID: f.runtime.id, generation: 0, phase: .prepared, candidate: candidate)
        try f.app.dispatchDeliveryJournal.save(record, expectedGeneration: nil)
        record.generation = 1
        record.phase = .verified
        let id = UUID()
        record.verificationID = id
        record.verificationReceipt = .init(id: id, revision: candidate.revision,
            commands: ["ruby verify_test.rb"], outputDigests: ["fixture prior host digest"],
            operatorOverride: false, verifiedAt: Date())
        try f.app.dispatchDeliveryJournal.save(record, expectedGeneration: 0)
        return record
    }

    @Test("已验证记录恢复时追上并发集成，不反复重试同一旧候选", arguments: [false, true])
    func verifiedRecoveryRepreparesAdvancedIntegration(alreadyPublished: Bool) async throws {
        let f = try await fixture(verifierBody:
            "abort 'interface mismatch' unless ARGV.first == 'current' || File.read('interface.txt') == \"A\\n\"\nputs 'verified'\n")
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        let checkpoint = try await seedVerifiedCheckpoint(f)
        if alreadyPublished {
            _ = try await AgentDispatchArtifactIntegrator.publish(checkpoint.candidate,
                verifiedRevision: checkpoint.candidate.revision, in: f.repository)
        }
        let checkout = f.root.appendingPathComponent("concurrent-worker")
        _ = try await git(["worktree", "add", "--detach", checkout.path, f.base], at: f.repository)
        try Data("other node artifact\n".utf8).write(to: checkout.appendingPathComponent("consumer.txt"))
        let child = f.app.startNewAgentSession(inWorkspaceAt: checkout.path)
        let runtime = try #require(f.app.runtime(for: child.id))
        runtime.session.dispatchParentProjectID = f.goalID
        runtime.session.dispatchTaskID = f.nextID
        runtime.agentEditedPaths = ["consumer.txt"]
        runtime.currentGoal = .init(statement: "Independent consumer", checklist: [.init(text: "Consumer checked", done: true)])
        let goal = try #require(f.app.agentDispatchCoordinator.goals.first { $0.id == f.goalID })
        let binding = try #require(goal.resolvedWorkspaceBinding(for: try f.task(f.nextID)))
        f.app.agentDispatchCoordinator.updateTask(goalID: f.goalID, taskID: f.nextID) {
            $0.dependencyIDs = []
            $0.verificationCommands = ["ruby verify_test.rb current"]
        }
        f.app.agentDispatchCoordinator.pinTaskInputRevision(goalID: f.goalID, taskID: f.nextID,
            bindingID: binding.id, baseRevision: f.base, inputRevision: f.base)
        f.app.agentDispatchCoordinator.markTaskStarted(goalID: f.goalID, taskID: f.nextID,
            executor: .willDeep, target: .local, runtimeSessionID: runtime.id)
        _ = f.app.beginDispatchMonitor(runtimeID: runtime.id, taskID: f.nextID)
        try await f.app.deliverVerifiedDispatchTask(runtime: runtime, goalID: f.goalID, taskID: f.nextID)
        let concurrent = try #require(try f.task(f.nextID).integrationReceipt)
        try await f.deliver()
        let restored = try #require(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID))
        #expect(restored.phase == .delivered)
        #expect(restored.candidate.previousRevision == concurrent.integratedRevision)
        #expect(restored.verificationID != checkpoint.verificationID)
        #expect(restored.verificationReceipt?.commands == ["ruby verify_test.rb current", "ruby verify_test.rb"])
        #expect(try await git(["show", "\(restored.candidate.revision):consumer.txt"], at: f.repository) == "other node artifact")
        #expect(try await git(["show", "\(restored.candidate.revision):interface.txt"], at: f.repository) == "A")
        #expect(try await git(["rev-parse", "HEAD"], at: f.repository) == f.base)
    }

    @Test("发布后尚未记账的恢复不重复集成，源产物改变则重新验证", arguments: [false, true])
    func verifiedRecoveryChecksSourceAndPublication(sourceChanged: Bool) async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        let checkpoint = try await seedVerifiedCheckpoint(f)
        if sourceChanged {
            try Data("regressed\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
            await #expect(throws: (any Error).self) { try await f.deliver() }
            #expect(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)?.phase == .prepared)
            #expect(try f.task(f.firstID).state != .merged)
            #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: f.repository,
                goalID: f.goalID, baseRevision: f.base) == f.base)
        } else {
            _ = try await AgentDispatchArtifactIntegrator.publish(checkpoint.candidate,
                verifiedRevision: checkpoint.candidate.revision, in: f.repository)
            try await f.deliver()
            let recovered = try #require(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID))
            #expect(recovered.candidate == checkpoint.candidate)
            #expect(recovered.verificationID == checkpoint.verificationID)
            #expect(recovered.generation == 3)
        }
    }

    private func fixture(commands: [String] = ["ruby verify_test.rb"], verifierBody: String? = nil,
                         scheduling: AgentDispatchSchedulingHints? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-app-test-\(UUID().uuidString)")
        let repository = root.appendingPathComponent("repository")
        let checkout = root.appendingPathComponent("worker")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await git(["init", "-b", "develop"], at: repository)
        try Data("base\n".utf8).write(to: repository.appendingPathComponent("interface.txt"))
        let verifier = verifierBody ?? "abort 'interface mismatch' unless File.read('interface.txt') == \"A\\n\"\nputs 'verified interface'\n"
        try Data(verifier.utf8)
            .write(to: repository.appendingPathComponent("verify_test.rb"))
        _ = try await git(["add", "interface.txt", "verify_test.rb"], at: repository)
        _ = try await git(["commit", "-m", "fixture"], at: repository)
        let base = try await git(["rev-parse", "HEAD"], at: repository)
        _ = try await git(["worktree", "add", "--detach", checkout.path, base], at: repository)
        let suite = "delivery-app-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let project = app.startDispatchGoalSession(inWorkspaceAt: repository.path)
        let projectRuntime = try #require(app.runtime(for: project.id))
        let firstID = UUID(), nextID = UUID()
        projectRuntime.currentGoal = AgentGoal(
            statement: "交付接口给下游", checklist: [.init(text: "验收全部产物")],
            dispatchPlan: .init(nodes: [
                .init(id: firstID, key: "A", title: "接口", dependencyIDs: [], primaryProfileID: nil,
                      fallbackProfileIDs: [], acceptanceCriteria: ["接口为 A"], verificationCommands: commands, scheduling: scheduling),
                .init(id: nextID, key: "B", title: "消费接口", dependencyIDs: [firstID], primaryProfileID: nil,
                      fallbackProfileIDs: [], acceptanceCriteria: ["消费 A"]),
            ])
        )
        app.persistAgentSession(runtime: projectRuntime)
        app.agentDispatchCoordinator.synchronize(with: app.agentSessions)
        let goal = try #require(app.agentDispatchCoordinator.goals.first(where: { $0.id == project.id }))
        let first = try #require(goal.tasks.first(where: { $0.id == firstID }))
        let binding = try #require(goal.resolvedWorkspaceBinding(for: first))
        app.agentDispatchCoordinator.pinTaskInputRevision(goalID: goal.id, taskID: firstID, bindingID: binding.id, baseRevision: base, inputRevision: base)
        let child = app.startNewAgentSession(inWorkspaceAt: checkout.path)
        let runtime = try #require(app.runtime(for: child.id))
        runtime.session.dispatchParentProjectID = goal.id
        runtime.session.dispatchTaskID = firstID
        runtime.currentGoal = .init(statement: "接口", checklist: [.init(text: "接口为 A", done: true)])
        runtime.agentEditedPaths = ["interface.txt"]
        app.agentDispatchCoordinator.markTaskStarted(goalID: goal.id, taskID: firstID, executor: .willDeep, target: .local, runtimeSessionID: child.id)
        _ = app.beginDispatchMonitor(runtimeID: child.id, taskID: firstID)
        return .init(root: root, repository: repository, checkout: checkout, base: base, defaults: defaults,
                     suite: suite, app: app, runtime: runtime, goalID: goal.id, firstID: firstID, nextID: nextID)
    }

    private func git(_ arguments: [String], at directory: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge(["GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@localhost",
                           "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@localhost"]) { _, new in new }
        process.environment = environment
        let result = try await AgentSubprocess.run(process, timeout: 30)
        guard result.exitStatus == 0, !result.timedOut else {
            throw AgentDispatchIntegrationError.commandFailed(operation: arguments[0], status: result.exitStatus)
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("真实测试成功后才解锁 B，B 固定到已集成 A，旧看板重放不重复交付")
    func deliversAndReplaysWithoutDuplicateIntegration() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        #expect(try f.task(f.nextID).state == .blocked)
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try await f.deliver()
        let task = try f.task(f.firstID)
        #expect(task.state == .merged)
        let receipt = try #require(task.integrationReceipt)
        #expect(try f.task(f.nextID).state == .queued)
        let loaded = try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)
        let record = try #require(loaded)
        #expect(record.phase == .delivered)
        #expect(record.verificationReceipt?.commands == ["ruby verify_test.rb"])
        #expect(record.verificationReceipt?.operatorOverride == false)
        let goal = try #require(f.app.agentDispatchCoordinator.goals.first(where: { $0.id == f.goalID }))
        let next = try f.task(f.nextID)
        let binding = try #require(goal.resolvedWorkspaceBinding(for: next))
        let preparedRevision = try f.app.prepareDispatchInputRevision(goal: goal, task: next, binding: binding).get()
        let revision = try #require(preparedRevision)
        #expect(revision == receipt.integratedRevision)
        let downstream = f.root.appendingPathComponent("downstream")
        _ = try await git(["worktree", "add", "--detach", downstream.path, revision], at: f.repository)
        #expect(try String(contentsOf: downstream.appendingPathComponent("interface.txt"), encoding: .utf8) == "A\n")
        f.app.agentDispatchCoordinator.updateTaskState(goalID: f.goalID, taskID: f.firstID, state: .reviewing)
        try await f.deliver()
        #expect(try f.task(f.firstID).integrationReceipt == receipt)
        #expect(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)?.generation == record.generation)
        #expect(try await git(["rev-parse", "HEAD"], at: f.repository) == f.base)
    }

    @Test("源分支推进并重投影后仍以原基准真实交付，不要求用户重新确认")
    func projectedPinnedInputStillDeliversAfterSourceHeadAdvances() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try Data("unrelated upstream change\n".utf8).write(to: f.repository.appendingPathComponent("upstream.txt"))
        _ = try await git(["add", "upstream.txt"], at: f.repository)
        _ = try await git(["commit", "-m", "unrelated source advance"], at: f.repository)
        let advancedHead = try await git(["rev-parse", "HEAD"], at: f.repository)
        #expect(advancedHead != f.base)
        for _ in 0..<3 { f.app.agentDispatchCoordinator.synchronize(with: f.app.agentSessions) }
        let projected = try #require(f.app.agentDispatchCoordinator.goals.first { $0.id == f.goalID })
        let first = try f.task(f.firstID)
        let binding = try #require(projected.resolvedWorkspaceBinding(for: first))
        #expect(projected.integrationBaseRevisions?[binding.id] == f.base)
        let restored = AgentDispatchCoordinator(store: AgentDispatchStore(defaults: f.defaults))
        restored.synchronize(with: f.app.agentSessions)
        #expect(restored.goals.first { $0.id == f.goalID }?.integrationBaseRevisions?[binding.id] == f.base)
        try await f.deliver()
        let delivered = try f.task(f.firstID)
        #expect(delivered.state == .merged)
        #expect(delivered.integrationReceipt?.snapshot.baseRevision == f.base)
        #expect(try f.task(f.nextID).state == .queued)
        #expect(try await git(["rev-parse", "HEAD"], at: f.repository) == advancedHead)
        #expect(try String(contentsOf: f.repository.appendingPathComponent("upstream.txt"), encoding: .utf8) == "unrelated upstream change\n")
    }

    @Test("失败测试阻止解锁，修复后替换候选并重新验收")
    func failedVerificationCanRecoverOnFreshCandidate() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try Data("wrong\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        await #expect(throws: (any Error).self) { try await f.deliver() }
        let loaded = try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)
        let failed = try #require(loaded)
        #expect(failed.phase == .prepared)
        #expect(try f.task(f.nextID).state == .blocked)
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try await f.deliver()
        #expect(try f.task(f.firstID).state == .merged)
        #expect(try f.task(f.firstID).integrationReceipt?.integratedRevision != failed.candidate.revision)
    }

    @Test("无宿主证据不能靠模型勾选完成交付")
    func checklistAloneDoesNotDeliver() async throws {
        let f = try await fixture(commands: [])
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        await #expect(throws: (any Error).self) { try await f.deliver() }
        #expect(try f.task(f.firstID).integrationReceipt == nil)
        #expect(try f.task(f.nextID).state == .blocked)
    }

    @Test("重新运行不会继承旧的人工放行")
    func freshRuntimeClearsOperatorOverride() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        f.app.agentDispatchCoordinator.recordOperatorAcceptance(goalID: f.goalID, taskID: f.firstID)
        #expect(try f.task(f.firstID).operatorAcceptedAt != nil)
        f.app.agentDispatchCoordinator.markTaskStarted(goalID: f.goalID, taskID: f.firstID, executor: .willDeep, target: .local, runtimeSessionID: UUID())
        #expect(try f.task(f.firstID).operatorAcceptedAt == nil)
    }

    @Test("换执行器保留归因产物并重新验收，不带入用户脏文件")
    func executorHandoffPreservesArtifactsWithoutCopyingAcceptance() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try Data("user work\n".utf8).write(to: f.checkout.appendingPathComponent("unrelated.txt"))
        let task = try f.task(f.firstID)
        let manifest = try f.app.prepareDispatchTaskHandoff(goalID: f.goalID, task: task, workspaceLocation: .local(path: f.checkout.path))
        let handoff = try #require(manifest)
        #expect(handoff.predecessorIDs == [f.runtime.id])
        #expect(handoff.inputRevision == f.base)
        #expect(handoff.editedPaths == ["interface.txt"])
        #expect(handoff.claimedCompletedCriteria == ["接口为 A"])
        #expect(handoff.verificationCommands == ["ruby verify_test.rb"])
        #expect(try handoff.instruction().contains("do not start over"))

        let next = f.app.startNewAgentSession(inWorkspaceAt: f.checkout.path)
        let replacement = try #require(f.app.runtime(for: next.id))
        replacement.session.dispatchParentProjectID = f.goalID
        replacement.session.dispatchTaskID = f.firstID
        replacement.currentGoal = .init(statement: "接口", checklist: [.init(text: "接口为 A")])
        f.app.applyDispatchTaskHandoff(handoff, to: replacement)
        #expect(replacement.currentGoal?.checklist.first?.done == false)
        #expect(replacement.toolCalls.isEmpty)
        #expect(replacement.delegatedTaskRuns.isEmpty)
        #expect(replacement.agentEditedPaths == ["interface.txt"])
        #expect(replacement.didEditFiles)
        f.app.persistAgentSession(runtime: replacement)
        let persisted = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(replacement.session))
        let restored = AgentRuntime(session: persisted)
        #expect(restored.agentEditedPaths == ["interface.txt"])
        #expect(restored.currentGoal?.checklist.first?.done == false)

        // A fresh completion claim still goes through the real host verifier.
        replacement.currentGoal?.checklist[0].done = true
        f.app.agentDispatchCoordinator.markTaskStarted(goalID: f.goalID, taskID: f.firstID, executor: .willDeep,
                                                       target: .local, runtimeSessionID: replacement.id)
        _ = f.app.beginDispatchMonitor(runtimeID: replacement.id, taskID: f.firstID)
        try await f.app.deliverVerifiedDispatchTask(runtime: replacement, goalID: f.goalID, taskID: f.firstID)
        let delivered = try f.task(f.firstID)
        let receipt = try #require(delivered.integrationReceipt)
        #expect(delivered.state == .merged)
        #expect(try await git(["show", "\(receipt.integratedRevision):interface.txt"], at: f.repository) == "A")
        await #expect(throws: (any Error).self) {
            _ = try await git(["show", "\(receipt.integratedRevision):unrelated.txt"], at: f.repository)
        }
        #expect(try String(contentsOf: f.checkout.appendingPathComponent("unrelated.txt"), encoding: .utf8) == "user work\n")
        #expect(try f.task(f.nextID).state == .queued)
    }

    @Test("续接只累计同一任务同一目录的历史，不执行旧审批")
    func handoffUsesPersistedLineageAndExcludesOtherTasks() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let firstSession = f.app.startNewAgentSession(inWorkspaceAt: f.checkout.path)
        let first = try #require(f.app.runtime(for: firstSession.id))
        first.session.dispatchParentProjectID = f.goalID
        first.session.dispatchTaskID = f.firstID
        first.agentEditedPaths = ["earlier.txt"]
        f.app.persistAgentSession(runtime: first)
        f.app.agentRuntimes.removeValue(forKey: first.id)
        let otherSession = f.app.startNewAgentSession(inWorkspaceAt: f.checkout.path)
        let other = try #require(f.app.runtime(for: otherSession.id))
        other.session.dispatchParentProjectID = f.goalID
        other.session.dispatchTaskID = f.nextID
        other.agentEditedPaths = ["not-ours.txt"]
        var task = try f.task(f.firstID)
        task.runtimeSessionIDs = [first.id, other.id, f.runtime.id, first.id]
        let manifest = try f.app.prepareDispatchTaskHandoff(goalID: f.goalID, task: task, workspaceLocation: .local(path: f.checkout.path))
        #expect(manifest?.editedPaths == ["earlier.txt", "interface.txt"])
        #expect(manifest?.predecessorIDs == [first.id, f.runtime.id])
        #expect(f.app.loadedRuntime(for: first.id) == nil)
        #expect(other.agentEditedPaths == ["not-ours.txt"])
    }

    @Test("续接拒绝活动执行器、错误工作区和缺失历史，不伪装成首次运行")
    func handoffRejectsUnreconciledState() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let task = try f.task(f.firstID)
        #expect(throws: AgentDispatchHandoffError.differentWorkspace) {
            try f.app.prepareDispatchTaskHandoff(goalID: f.goalID, task: task, workspaceLocation: .local(path: f.repository.path))
        }
        f.runtime.isResponding = true
        #expect(throws: AgentDispatchHandoffError.predecessorStillRunning) {
            try f.app.prepareDispatchTaskHandoff(goalID: f.goalID, task: task, workspaceLocation: .local(path: f.checkout.path))
        }
        f.runtime.isResponding = false
        var missing = task
        let absentID = UUID()
        missing.runtimeSessionID = absentID
        #expect(throws: AgentDispatchHandoffError.missingSession(absentID)) {
            try f.app.prepareDispatchTaskHandoff(goalID: f.goalID, task: missing, workspaceLocation: .local(path: f.checkout.path))
        }
        #expect(!AgentDispatchTaskHandoff.sameWorkspace(.remote(runtimeID: UUID(), path: "/repo"), .local(path: "/repo")))
    }

    @Test("Stop 后自动恢复被拒绝，用户明确重启可重新验证交付")
    func explicitResumeAfterStop() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try Data("wrong\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        await #expect(throws: (any Error).self) { try await f.deliver() }
        #expect(f.app.stopDispatchTask(goalID: f.goalID, taskID: f.firstID))
        #expect(try f.task(f.firstID).state == .cancelled)
        #expect(throws: (any Error).self) {
            try f.app.resumeStoppedDispatchDelivery(goalID: f.goalID, taskID: f.firstID, runtimeID: f.runtime.id, explicitlyRequested: false)
        }
        #expect(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)?.phase == .stopped)
        try f.app.resumeStoppedDispatchDelivery(goalID: f.goalID, taskID: f.firstID, runtimeID: f.runtime.id, explicitlyRequested: true)
        f.app.agentDispatchCoordinator.updateTaskState(goalID: f.goalID, taskID: f.firstID, state: .reviewing)
        _ = f.app.beginDispatchMonitor(runtimeID: f.runtime.id, taskID: f.firstID)
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        try await f.deliver()
        #expect(try f.task(f.firstID).state == .merged)
        #expect(try f.task(f.nextID).state == .queued)
    }

    @Test("同一 runtime 的旧监控租约不能写新一轮结果，Stop 会取消所属验证任务")
    func monitorEpochFencesSameRuntimeAndOwnsCancellation() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let oldLease = f.app.beginDispatchMonitor(runtimeID: f.runtime.id, taskID: f.firstID)
        let owned: Task<Void, Never> = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
        }
        f.app.dispatchMonitorTasksByTaskID[f.firstID] = owned
        let freshLease = f.app.beginDispatchMonitor(runtimeID: f.runtime.id, taskID: f.firstID)
        #expect(owned.isCancelled)
        #expect(throws: (any Error).self) {
            try f.app.requireDispatchDeliveryLease(runtime: f.runtime, goalID: f.goalID, taskID: f.firstID, leaseID: oldLease)
        }
        try f.app.requireDispatchDeliveryLease(runtime: f.runtime, goalID: f.goalID, taskID: f.firstID, leaseID: freshLease)
        await owned.value
    }

    @Test("验证执行期间合同改变，旧成功结果不能发布或解锁下游",
          arguments: ["criteria", "statement", "input", "workspace", "override", "revision"])
    func changedContractRejectsLateVerifier(field: String) async throws {
        let f = try await fixture(verifierBody: """
        File.write('verifier.started', 'ready')
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until File.exist?('verifier.continue')
          abort 'fixture release timeout' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.01
        end
        puts 'old contract verification passed'
        """)
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        let delivery: Task<Void, Never> = Task {
            do {
                try await f.deliver()
                Issue.record("Old contract result was delivered")
            } catch {
                if case AgentDispatchDeliveryError.staleRuntime = error {} else {
                    Issue.record("Expected stale contract rejection, received \(error)")
                }
            }
        }
        f.app.dispatchMonitorTasksByTaskID[f.firstID] = delivery
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var verifier: URL?
        while ContinuousClock.now < deadline {
            let worktrees = try await git(["worktree", "list", "--porcelain"], at: f.repository)
            verifier = worktrees.split(separator: "\n").filter { $0.hasPrefix("worktree ") }
                .map { URL(fileURLWithPath: String($0.dropFirst(9))) }
                .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("verifier.started").path) }
            if verifier != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let verifier {
            switch field {
            case "statement": f.app.agentDispatchCoordinator.updateGoal(id: f.goalID) { $0.statement = "New outcome" }
            case "workspace": f.app.agentDispatchCoordinator.updateGoal(id: f.goalID) {
                $0.workspaceBindings = []
                $0.workspaceLocation = nil
            }
            case "override": f.app.agentDispatchCoordinator.recordOperatorAcceptance(goalID: f.goalID, taskID: f.firstID)
            case "revision": f.app.agentDispatchCoordinator.updateTask(goalID: f.goalID, taskID: f.firstID) {
                $0.deliveryRevisionID = UUID()
            }
            default: f.app.agentDispatchCoordinator.updateTask(goalID: f.goalID, taskID: f.firstID) {
                if field == "input" { $0.inputRevision = "changed input" }
                else { $0.acceptanceCriteria = ["New acceptance requirement"] }
            }
            }
            try Data("continue\n".utf8).write(to: verifier.appendingPathComponent("verifier.continue"))
        } else { delivery.cancel() }
        await delivery.value
        #expect(verifier != nil)
        #expect(try f.task(f.firstID).state != .merged)
        #expect(try f.task(f.nextID).state == .blocked)
        #expect(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)?.phase == .prepared)
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: f.repository,
            goalID: f.goalID, baseRevision: f.base) == f.base)
        #expect(!(try await git(["worktree", "list", "--porcelain"], at: f.repository)).contains("willdeep-verify-"))
    }

    @Test("Stop 终止真实宿主验证进程并回收专属工作树，不解锁下游")
    func stopCancelsRealVerifier() async throws {
        let f = try await fixture(verifierBody: "File.write('verifier.started', 'ready')\nsleep 30\n")
        defer { f.cleanup() }
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        let delivery: Task<Void, Never> = Task {
            await #expect(throws: (any Error).self) { try await f.deliver() }
        }
        f.app.dispatchMonitorTasksByTaskID[f.firstID] = delivery
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var started = false
        while ContinuousClock.now < deadline {
            let worktrees = try await git(["worktree", "list", "--porcelain"], at: f.repository)
            let paths = worktrees.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
            started = paths.contains {
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("verifier.started").path)
            }
            if started { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(started)
        let stoppingAt = ContinuousClock.now
        #expect(f.app.stopDispatchTask(goalID: f.goalID, taskID: f.firstID))
        await delivery.value
        #expect(stoppingAt.duration(to: .now) < .seconds(5))
        #expect(try f.task(f.firstID).state == .cancelled)
        #expect(try f.task(f.nextID).state == .blocked)
        #expect(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID)?.phase == .stopped)
        let remainingWorktrees = try await git(["worktree", "list", "--porcelain"], at: f.repository)
        #expect(!remainingWorktrees.contains("willdeep-verify-"))
    }

    @Test("实际调度入口保留未集成依赖，声明范围之外的产物不能发布")
    func schedulerAdapterAndFrozenArtifactScope() async throws {
        let f = try await fixture(scheduling: .init(writePaths: ["allowed.txt"]))
        defer { f.cleanup() }
        f.app.agentDispatchCoordinator.updateTaskState(goalID: f.goalID, taskID: f.firstID, state: .queued)
        #expect(f.app.readyDispatchTaskIDs(goalID: f.goalID, capacity: 3) == [f.firstID])
        f.app.agentDispatchCoordinator.updateTaskState(goalID: f.goalID, taskID: f.firstID, state: .reviewing)
        #expect(f.app.readyDispatchTaskIDs(goalID: f.goalID, capacity: 3).isEmpty)
        try Data("A\n".utf8).write(to: f.checkout.appendingPathComponent("interface.txt"))
        await #expect(throws: (any Error).self) { try await f.deliver() }
        #expect(try f.task(f.firstID).integrationReceipt == nil)
        #expect(try f.task(f.nextID).state == .blocked)
        #expect(try f.app.dispatchDeliveryJournal.load(goalID: f.goalID, taskID: f.firstID) == nil)
    }
}
