import Foundation
import Testing
@testable import WillDeep

@Suite("主 Goal 宿主证据门禁", .serialized)
@MainActor
struct AgentGoalHostVerificationTests {
    private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let root: URL
        let defaults: UserDefaults
        let suite: String

        func cleanup() throws {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "goal-evidence-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let session = app.startNewAgentSession(inWorkspaceAt: root.path)
        let runtime = try #require(app.runtime(for: session.id))
        runtime.interactionMode = .goal
        runtime.currentGoal = .init(statement: "交付经过验证的成果", checklist: [.init(text: "成果正确")])
        runtime.messages = [AgentMessage(role: .assistant, content: "已完成\n```goal-check\n1: done\n```")]
        return .init(app: app, runtime: runtime, root: root, defaults: defaults, suite: suite)
    }

    private func readEvidence(_ fixture: Fixture, path: String = "report.md") throws {
        try Data("verified source\n".utf8).write(to: fixture.root.appendingPathComponent(path))
        fixture.runtime.toolCalls.append(.init(messageID: UUID(), externalID: UUID().uuidString, toolName: "read_file",
            arguments: ["path": .string(path)], risk: .read, status: .succeeded,
            result: .init(summary: "read", payload: "old payload must not substitute for the actual file")))
    }

    private func installReviewer(_ fixture: Fixture, kind: AgentGoalVerification.Review.Verdict.Kind = .analysis,
                                 beforeReturn: (() throws -> Void)? = nil) {
        fixture.app.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, schema, profile, _, context, _ in
            #expect(profile.toolNames.isEmpty)
            #expect(schema != nil)
            #expect(context.approvedCommand == nil)
            let raw = try #require(prompt.components(separatedBy: "Host evidence:\n").last)
            let evidence = try JSONDecoder().decode([AgentGoalVerification.Evidence].self, from: Data(raw.utf8))
            let candidate = try #require(fixture.runtime.currentGoal?.verification)
            let review = AgentGoalVerification.Review(verdicts: candidate.criterionIDs.map {
                .init(criterionID: $0, kind: kind, passed: true, evidenceIDs: evidence.map(\.id), detail: "Evidence covers the criterion.")
            })
            try beforeReturn?()
            return .init(report: String(decoding: try JSONEncoder().encode(review), as: UTF8.self), usageTokens: 123,
                         roundCount: 1, toolInvocationCount: 0)
        }
    }

    @Test("模型 done 只生成候选，不能同步完成")
    func selfClaimIsNotCompletion() throws {
        let f = try fixture(); defer { try? f.cleanup() }
        #expect(!f.app.captureAgentGoalEvaluationFromLatestMessage(for: f.runtime))
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        #expect(f.runtime.currentGoal?.verification?.phase == .pending)
        #expect(f.runtime.currentGoal?.verification?.receipts.isEmpty == true)
    }

    @Test("没有任何宿主证据不启动复核，也不完成")
    func emptyEvidenceRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        f.app.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _, _, _, _ in
            Issue.record("No-evidence candidate must not spend a reviewer call")
            throw CancellationError()
        }
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
        #expect(f.runtime.currentGoal?.verification?.phase == .rejected)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("取回的历史图片及其转发副本不能满足 UI 新截图验收")
    func historicalImagesCannotVerifyCurrentUI() async throws {
        for relayed in [false, true] {
            let f = try fixture()
            let transport = URLSession(configuration: .ephemeral)
            defer {
                f.app.agentLoopInferenceEnvironment = nil
                transport.invalidateAndCancel()
                f.app.dispatchDecisionResumptionTask?.cancel()
                AgentSessionStore.delete(id: f.runtime.id)
                do { try f.cleanup() } catch { Issue.record("Historical evidence cleanup failed: \(error)") }
            }
            let configuration = AgentConfiguration(providerID: "openai", baseURL: "https://context-evidence.invalid/v1",
                model: "gpt-4.1", apiKey: "fixture-placeholder")
            #expect(configuration.supportsImageInput)
            f.app.agentLoopInferenceEnvironment = (configuration, transport)
            let image = AgentImageAttachment(mimeType: "image/png", dataBase64:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
            let original = AgentMessage(role: .user, content: "Historical screenshot", images: [image])
            f.runtime.messages.insert(original, at: 0)
            let context = AgentToolContext(rootDirectory: f.root, contextMessageReader: f.app.contextMessageReader(for: f.runtime))
            let historical = try await AgentToolRunner.run(name: "read_context_message", arguments: [
                "message_id": .string(original.id.uuidString), "attachment_id": .string(image.id.uuidString)
            ], context: context)
            f.runtime.toolCalls = [
                .init(messageID: UUID(), externalID: "old-image", toolName: relayed ? "capture_screenshot" : "read_context_message",
                      arguments: [:], risk: .read, status: .succeeded, result: historical),
                .init(messageID: UUID(), externalID: "fixture-click", toolName: "computer_use_click",
                      arguments: [:], risk: .read, status: .succeeded,
                      result: .init(summary: "fixture interaction", payload: "A controlled interaction receipt, not a real device click."))
            ]
            var reviewedImageCount: Int?
            f.app.agentSubagentRegistry.runOperation = { prompt, _, _, _, _, _, _, _, _, workerContext, _ in
                reviewedImageCount = workerContext.openingImages.count
                let raw = try #require(prompt.components(separatedBy: "Host evidence:\n").last)
                let evidence = try JSONDecoder().decode([AgentGoalVerification.Evidence].self, from: Data(raw.utf8))
                let candidate = try #require(f.runtime.currentGoal?.verification)
                let review = AgentGoalVerification.Review(verdicts: candidate.criterionIDs.map {
                    .init(criterionID: $0, kind: .interface, passed: true, evidenceIDs: evidence.map(\.id),
                          detail: "A deliberately overoptimistic UI review must still pass the host's evidence-kind gate.")
                })
                return .init(report: String(decoding: try JSONEncoder().encode(review), as: UTF8.self),
                             usageTokens: 1, roundCount: 1, toolInvocationCount: 0)
            }
            #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
            #expect(reviewedImageCount == 0)
            #expect(f.runtime.currentGoal?.checklist.first?.done == false)
            #expect(f.runtime.currentGoal?.verification?.findings.contains { $0.contains("UI acceptance needs actual pixels") } == true)
        }
    }

    @Test("分析按真实文件证据验收，不强制代码测试，回执与用量可持久化")
    func analysisReceipt() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        let evidenceStore = AgentExecutionEvidenceStore(root: f.root.appendingPathComponent("execution-events"))
        let runID = UUID()
        f.runtime.executionEvidenceTrace = AgentExecutionTrace(store: evidenceStore,
            seed: .init(runID: runID, rootRunID: runID, sessionID: f.runtime.id, mode: "root", kind: "started"))
        f.runtime.currentPlan = .init(status: .done, summary: "Verified analysis", stepTexts: ["Inspect evidence"])
        try readEvidence(f)
        installReviewer(f)
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime))
        f.app.prepareNextAgentGoalPlanningCycleIfNeeded(for: f.runtime)
        #expect(f.runtime.interactionMode == .normal)
        #expect(f.app.agentInteractionMode == .normal)
        #expect(f.runtime.session.interactionMode == .normal)
        let goal = try #require(f.runtime.currentGoal)
        #expect(goal.checklist.first?.done == true)
        #expect(goal.verification?.evidence.first?.content == "verified source\n")
        #expect(goal.verification?.receipts.first?.inputDigests["report.md"] != nil)
        #expect(try JSONDecoder().decode(AgentGoal.self, from: JSONEncoder().encode(goal)) == goal)
        #expect(f.runtime.session.hostWorkerRuns?.last?.source == .goalVerification)
        #expect(f.runtime.session.hostWorkerRuns?.last?.usage?.usageTokens == 123)
        let hostReceipt = try #require(evidenceStore.events().first { $0.kind == "goal_verified" })
        #expect(hostReceipt.verifierPassed == true && hostReceipt.verifierInputSHA256 != nil && hostReceipt.verifierEvidenceSHA256 != nil)
    }

    @Test("真实前台 Ruby 验证通过，且绑定源文件与验证脚本")
    func actualCommandReceipt() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f, path: "source.rb")
        f.runtime.agentEditedPaths.insert("source.rb")
        try Data("abort 'wrong source' unless File.read('source.rb') == \"verified source\\n\"\nputs '1 check passed'\n".utf8)
            .write(to: f.root.appendingPathComponent("verify_test.rb"))
        addCommand(f, "ruby verify_test.rb")
        installReviewer(f, kind: .code)
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime))
        let state = try #require(f.runtime.currentGoal?.verification)
        #expect(state.evidence.contains { $0.kind == .command && $0.exitCode == 0 && $0.content.contains("1 check passed") })
        #expect(state.receipts.first?.inputDigests["verify_test.rb"] != nil)
    }

    private func addCommand(_ f: Fixture, _ command: String) {
        // A historical success is only a command hint; the host MUST rerun it.
        f.runtime.toolCalls.append(.init(messageID: UUID(), externalID: UUID().uuidString, toolName: "run_command",
            arguments: ["command": .string(command)], risk: .write, status: .succeeded,
            result: .init(summary: "claimed success", payload: "not trusted")))
    }

    @Test("实际失败命令不能被历史成功或模型自报绕过")
    func failedCommandRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f, path: "source.rb")
        f.runtime.agentEditedPaths.insert("source.rb")
        try Data("abort 'actual failed check'\n".utf8).write(to: f.root.appendingPathComponent("verify_test.rb"))
        addCommand(f, "ruby verify_test.rb")
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
        #expect(f.runtime.currentGoal?.verification?.findings.joined().contains("actual failed check") == true)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        #expect(f.runtime.session.hostWorkerRuns?.isEmpty != false)
    }

    @Test("代码变更没有相关命令不能通过")
    func codeRequiresTests() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f, path: "source.rb")
        f.runtime.agentEditedPaths.insert("source.rb")
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("复核中相关输入变化使证据失效")
    func changedInputRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f)
        installReviewer(f) { try Data("changed".utf8).write(to: f.root.appendingPathComponent("report.md")) }
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
        #expect(f.runtime.currentGoal?.verification?.phase == .rejected)
    }

    @Test("无关文件改变不作废所有证据")
    func unrelatedInputAllowed() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f)
        installReviewer(f) { try Data("user unrelated change".utf8).write(to: f.root.appendingPathComponent("unrelated.txt")) }
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime))
        #expect(f.runtime.currentGoal?.verification?.receipts.first?.inputDigests["unrelated.txt"] == nil)
    }

    @Test("复核期间目标改变，旧结果不能完成新目标")
    func changedGoalRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f)
        installReviewer(f) { f.runtime.currentGoal?.statement = "changed objective" }
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("复核返回时预算耗尽仍拒绝完成")
    func expiredBudgetRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f)
        installReviewer(f) { f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 1, segmentStartedAt: .distantPast) }
        #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
    }

    @Test("复核期间工作区或归因文件集合变化拒绝旧回执")
    func changedWorkspaceOrArtifactsRejected() async throws {
        for changeWorkspace in [false, true] {
            let f = try fixture(); defer { try? f.cleanup() }
            try readEvidence(f)
            installReviewer(f) {
                if changeWorkspace {
                    f.runtime.rebindWorkspace(to: f.root.appendingPathComponent("another").path)
                } else {
                    f.runtime.agentEditedPaths.insert("new-artifact.md")
                }
            }
            #expect(await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime) == false)
            #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        }
    }

    @Test("取消真实异步复核任务后不能晚到完成")
    func cancelledReviewRejected() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try readEvidence(f)
        var verification: Task<Bool, Never>?
        var didStart = false
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            f.app.agentSubagentRegistry.runOperation = { _, _, _, _, _, _, _, _, _, _, _ in
                didStart = true
                started.resume()
                try await Task.sleep(for: .seconds(10))
                Issue.record("Cancelled reviewer must not finish normally")
                throw CancellationError()
            }
            verification = Task {
                let result = await f.app.captureAndVerifyAgentGoalEvaluation(for: f.runtime)
                if !didStart { started.resume() }
                return result
            }
        }
        #expect(didStart)
        let task = try #require(verification)
        task.cancel()
        #expect(await task.value == false)
        #expect(f.runtime.currentGoal?.checklist.first?.done == false)
        #expect(f.runtime.currentGoal?.verification?.phase == .rejected)
    }

    @Test("协议拒绝重复验收项、伪造证据与无交互 UI 证明")
    func protocolBoundary() {
        let item = UUID(), evidenceID = UUID()
        let state = AgentGoalVerification(id: UUID(), messageID: UUID(), contractDigest: "x", criterionIDs: [item])
        let evidence = AgentGoalVerification.Evidence(id: evidenceID, kind: .source, label: "x", content: "source", exitCode: nil)
        let valid = AgentGoalVerification.Review.Verdict(criterionID: item, kind: .analysis, passed: true, evidenceIDs: [evidenceID], detail: "supported")
        #expect(state.validate(review: .init(verdicts: [valid]), evidence: [evidence], requiresCodeVerification: false).isEmpty)
        #expect(!state.validate(review: .init(verdicts: [valid, valid]), evidence: [evidence], requiresCodeVerification: false).isEmpty)
        let forged = AgentGoalVerification.Review.Verdict(criterionID: item, kind: .analysis, passed: true, evidenceIDs: [UUID()], detail: "claimed")
        #expect(!state.validate(review: .init(verdicts: [forged]), evidence: [evidence], requiresCodeVerification: false).isEmpty)
        let ui = AgentGoalVerification.Review.Verdict(criterionID: item, kind: .interface, passed: true, evidenceIDs: [evidenceID], detail: "claimed")
        #expect(!state.validate(review: .init(verdicts: [ui]), evidence: [evidence], requiresCodeVerification: false).isEmpty)
    }

    @Test("文件证据拒绝越界、敏感文件和越界软链")
    func evidencePathBoundary() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("outside"), withDestinationURL: f.root.deletingLastPathComponent())
        for path in ["../outside.txt", ".env", "outside/anything", ".env\0ignored"] {
            await #expect(throws: (any Error).self) { try await AgentGoalEvidenceFiles.capture(root: f.root, paths: [path]) }
        }
        let absent = try await AgentGoalEvidenceFiles.capture(root: f.root, paths: ["missing/deleted.txt"])
        #expect(absent.digests["missing/deleted.txt"] == "deleted")
    }

    @Test("旧 Goal JSON 没有验证字段仍可读取")
    func legacyDecode() throws {
        let raw = #"{"statement":"old","checklist":[]}"#
        #expect(try JSONDecoder().decode(AgentGoal.self, from: Data(raw.utf8)).verification == nil)
        let result = AgentToolResult(summary: "ok", payload: "secret", commandExitCode: 0)
        #expect(AgentSecretStore.redact(result, secretValues: ["secret"]).commandExitCode == 0)
        #expect(AgentToolResult(summary: "started", payload: "background job").commandExitCode == nil)
    }

    @Test("长文件证据明确标注不完整，不伪装全文")
    func partialEvidenceIsLabeled() async throws {
        let f = try fixture(); defer { try? f.cleanup() }
        try Data(String(repeating: "a", count: 13_000).utf8).write(to: f.root.appendingPathComponent("long.md"))
        let snapshot = try await AgentGoalEvidenceFiles.capture(root: f.root, paths: ["long.md"])
        #expect(snapshot.text["long.md"]?.hasPrefix("[Partial evidence:") == true)
        #expect(snapshot.digests["long.md"] == AgentGoalVerification.digest(Data(String(repeating: "a", count: 13_000).utf8)))
    }
}
