import Foundation
import Testing
@testable import WillDeep

@Suite("上下文压缩增量复用", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct AgentCompressionReuseTests {
    private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
    }

    /// Defaults follow this task (including compression Tasks); session files
    /// use AgentSessionStore's process sandbox under XCTest and unique IDs.
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-checkpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "context-checkpoint-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            TestDefaultsHygiene.cleanup(suite: defaults, named: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Compression reuse fixture cleanup failed: \(error)") }
        }
        try await AppDefaults._withTestDefaults(defaults) {
            let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
                runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
                sessionManagementDefaults: defaults, loadSessionCatalog: false)
            let session = app.startNewAgentSession(inWorkspaceAt: root.path)
            let runtime = try #require(app.runtime(for: session.id))
            app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://compression-reuse.invalid/v1",
                model: "gpt-5-mini", apiKey: "test-placeholder"), URLSession(configuration: .ephemeral))
            runtime.session.titleIsUserSet = true
            runtime.contextSystemPromptTokenEstimate = 0
            runtime.messages = [.init(role: .user, content: "只改解析器，不要发布。")]
                + (1...7).map { .init(role: .assistant, content: String(repeating: "original-evidence-\($0) ", count: 2_000)) }
            defer {
                app.contextCompressionSummaryOperation = nil
                app.dispatchDecisionResumptionTask?.cancel()
                app.agentLoopInferenceEnvironment?.session.invalidateAndCancel()
                AgentSessionStore.delete(id: runtime.id)
            }
            try await body(.init(app: app, runtime: runtime))
        }
    }

    private func withHostFixture(
        _ body: (AgentGoalOvernightResilienceTests.Fixture) async throws -> Void
    ) async throws {
        let suite = "context-checkpoint-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suite) }
        try await AppDefaults._withTestDefaults(defaults) {
            let fixture = try AgentGoalOvernightResilienceTests().fixture()
            defer { fixture.cleanup() }
            try await body(fixture)
        }
    }

    private static let normalReply = (
        status: 200,
        body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Parser inspection completed.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
    )

    private func firstCompression(_ f: Fixture, summary: String = "accepted-first-summary") async throws {
        f.app.contextCompressionSummaryOperation = { _, _ in summary }
        let outcome = await f.app.compressContextInTurn(for: f.runtime, reason: .preSendGate)
        guard case .reclaimed = outcome else {
            Issue.record("First compression must reclaim, got \(outcome)")
            throw AgentContextCheckpoint.Failure.stale
        }
        #expect(f.runtime.contextSummaryThroughMessageID == f.runtime.messages[3].id)
    }

    @Test("首次压缩一次，真实新增批次只摘要 delta 并推进边界")
    func firstCompressionAndRealDelta() async throws {
        try await withFixture { f in
            var inputs: [[String]] = []
            f.app.contextCompressionSummaryOperation = { segments, _ in
                inputs.append(segments)
                return inputs.count == 1 ? "accepted-first-summary" : "accepted-second-summary"
            }
            let initial = f.runtime.messages
            let first = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 2))
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: first.head, tail: first.tail,
                configurations: [.default], reason: .automatic)
            #expect(inputs.count == 1)
            #expect(inputs[0].joined().contains("original-evidence-1"))
            let firstThrough = f.runtime.contextSummaryThroughMessageID
            f.runtime.messages += [.init(role: .assistant, content: String(repeating: "fresh-delta-evidence ", count: 2_000)),
                                   .init(role: .user, content: "保留这条最近指令"),
                                   .init(role: .assistant, content: "latest tail")]
            let second = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 2, reason: .automatic))
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: second.head, tail: second.tail,
                priorSummary: second.priorSummary, configurations: [.default], reason: .automatic)
            #expect(inputs.count == 2)
            let input = try #require(inputs.last).joined()
            #expect(input.components(separatedBy: "accepted-first-summary").count - 1 == 1)
            #expect(input.contains("fresh-delta-evidence"))
            #expect(!input.contains("original-evidence-1"))
            #expect(f.runtime.contextSummaryThroughMessageID != firstThrough)
            #expect(f.runtime.contextSummaryThroughMessageID == second.head.last?.id)
            #expect(f.runtime.messages.prefix(initial.count).elementsEqual(initial))
            #expect(!f.runtime.isCompressingContext)
            #expect(f.runtime.session.contextSummary == "accepted-second-summary")
        }
    }

    @Test("无增量自动检查不启动，执行端也不调用摘要器或覆盖持久摘要")
    func emptyDeltaSkipsTriggerAndExecution() async throws {
        try await withFixture { f in
            try await firstCompression(f)
            // The second plan may still absorb the two messages the first
            // keepRecent=4 retained. Install that boundary before testing no delta.
            f.app.contextCompressionSummaryOperation = { _, _ in "settled-summary" }
            _ = await f.app.compressContextInTurn(for: f.runtime, reason: .manual)
            let plan = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 2))
            let summary = f.runtime.contextSummary
            let checkpoint = f.runtime.contextCheckpoint
            let installed = f.runtime.contextSummaryInstalledAt
            let resumes = f.runtime.contextRunwayResumeCount
            var requests = 0
            f.app.contextCompressionSummaryOperation = { _, _ in requests += 1; return "unexpected overwrite" }
            // Only the kept tail grows. It can exceed 75% without producing
            // a new compressible message; ordinary checks must stay idle.
            f.runtime.messages[f.runtime.messages.count - 1].content = String(repeating: "尾", count: 320_000)
            #expect(!f.app.shouldAutoCompressNow(for: f.runtime))
            f.app.maybeAutoCompressContext(for: f.runtime)
            #expect(!f.runtime.isCompressingContext)
            #expect(f.app.compressionPlan(for: f.runtime, keepRecent: 2, reason: .automatic) == nil)
            // A previously captured plan must also be harmless if the async
            // executor reaches it after the same boundary was already covered.
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: plan.head, tail: plan.tail,
                priorSummary: plan.priorSummary, configurations: [.default], reason: .automatic)
            // Also cover a plan captured before the accepted summary existed:
            // omitted priorSummary must not bypass the execution-side check.
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: plan.head, tail: plan.tail,
                configurations: [.default], reason: .automatic)
            #expect(requests == 0)
            #expect(!f.runtime.isCompressingContext)
            #expect(f.runtime.contextSummary == summary)
            #expect(f.runtime.contextCheckpoint == checkpoint)
            #expect(f.runtime.contextSummaryInstalledAt == installed)
            #expect(f.runtime.session.contextSummary == summary)
            #expect(f.runtime.contextRunwayResumeCount == resumes)
            #expect(!f.runtime.pendingContextRunwayResume)
            #expect(f.runtime.errorMessage == nil)
        }
    }

    @Test("失效 checkpoint 无 delta 也从原文重建，不复用无效摘要")
    func staleCheckpointStillRecompresses() async throws {
        try await withFixture { f in
            try await firstCompression(f)
            f.runtime.messages[0].content = "新增约束：禁止删除文件"
            #expect(f.app.contextCheckpointIsStale(for: f.runtime))
            var requests = 0
            f.app.contextCompressionSummaryOperation = { segments, _ in
                requests += 1
                #expect(segments.joined().contains("禁止删除文件"))
                #expect(segments.joined().contains("original-evidence-1"))
                #expect(!segments.joined().contains("accepted-first-summary"))
                return "rebuilt-after-edit"
            }
            let plan = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 4, reason: .automatic))
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: plan.head, tail: plan.tail,
                priorSummary: plan.priorSummary, configurations: [.default], reason: .automatic)
            #expect(requests == 1)
            #expect(!f.app.contextCheckpointIsStale(for: f.runtime))
            #expect(f.runtime.contextSummary == "rebuilt-after-edit")
            #expect(f.runtime.contextCheckpoint?.userInputs.first?.text == "新增约束：禁止删除文件")
            #expect(!f.runtime.isCompressingContext)
        }
    }

    @Test("短会话失效 checkpoint 绕过普通自动条数门槛并重建覆盖前缀", arguments: [3, 6])
    func staleCheckpointInShortHistoryStillRebuilds(messageCount: Int) async throws {
        try await withFixture { f in
            f.runtime.messages = Array(f.runtime.messages.prefix(6))
            f.app.contextCompressionSummaryOperation = { _, _ in "accepted-short-history-summary" }
            let initial = await f.app.compressContextInTurn(for: f.runtime, reason: .preSendGate)
            guard case .reclaimed = initial else { Issue.record("Initial short-history compression failed"); return }
            let through = try #require(f.runtime.contextSummaryThroughMessageID)
            #expect(through == f.runtime.messages[1].id)
            f.runtime.messages = Array(f.runtime.messages.prefix(messageCount))
            f.runtime.messages[0].content = "短会话新增约束：保留解析器接口"
            #expect(!f.app.shouldAutoCompressNow(for: f.runtime))
            #expect(f.app.staleCheckpointNeedsRecompression(for: f.runtime))
            let plan = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 4, reason: .automatic))
            #expect(plan.priorSummary == nil)
            #expect(plan.head.last?.id == through)
            var requests = 0
            f.app.contextCompressionSummaryOperation = { segments, _ in
                requests += 1
                let input = segments.joined()
                #expect(input.contains("保留解析器接口"))
                #expect(input.contains("original-evidence-1"))
                #expect(!input.contains("accepted-short-history-summary"))
                return "rebuilt-short-history-summary"
            }
            let result = await f.app.compressContextInTurn(for: f.runtime, reason: .automatic)
            guard case .reclaimed = result else { Issue.record("Stale short-history checkpoint must rebuild"); return }
            #expect(requests == 1)
            #expect(f.runtime.contextSummaryThroughMessageID == through)
            #expect(f.runtime.contextSummary == "rebuilt-short-history-summary")
            #expect(!f.app.contextCheckpointIsStale(for: f.runtime))
            #expect(!f.runtime.isCompressingContext)
        }
    }

    @Test("手动、发送硬闸和 overflow 允许无增量时再缩短摘要",
          arguments: [AppState.ContextCompressionReason.manual, .preSendGate, .overflowRecovery, .runwayRecovery])
    func explicitReclamationCanShortenAnExistingSummary(reason: AppState.ContextCompressionReason) async throws {
        try await withFixture { f in
            let prior = String(repeating: "summary-detail ", count: 1_000)
            f.app.contextCompressionSummaryOperation = { _, _ in prior }
            let plan = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 2))
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: plan.head, tail: plan.tail, configurations: [.default])
            let acceptedSummary = try #require(f.runtime.contextSummary)
            #expect(acceptedSummary == prior.trimmingCharacters(in: .whitespacesAndNewlines))
            let through = f.runtime.contextSummaryThroughMessageID
            var requests = 0
            f.app.contextCompressionSummaryOperation = { segments, _ in
                requests += 1
                #expect(segments.count == 1, "只重压旧摘要，不能回传已覆盖原文")
                #expect(segments[0].contains(acceptedSummary))
                return "shorter-summary"
            }
            let outcome = await f.app.compressContextInTurn(for: f.runtime, reason: reason)
            guard case .reclaimed = outcome else {
                Issue.record("Explicit reclamation must run, got \(outcome)")
                return
            }
            #expect(requests == 1)
            #expect(f.runtime.contextSummary == "shorter-summary")
            #expect(f.runtime.contextSummaryThroughMessageID == through)
            #expect(f.runtime.session.contextSummary == "shorter-summary")
            #expect(!f.runtime.isCompressingContext)
        }
    }

    @Test("升档优化没有增量则不调用摘要器，但窗口缩小后的硬闸仍可重压")
    func modelChangeDoesNotDisableRequiredReclamation() async throws {
        try await withFixture { f in
            let prior = String(repeating: "summary-detail ", count: 1_000)
            f.app.contextCompressionSummaryOperation = { _, _ in prior }
            let plan = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 2))
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: plan.head, tail: plan.tail, configurations: [.default])
            // A smaller consumer window is a real reclamation need even when
            // no new head has accumulated since the old model's checkpoint.
            f.app.agentLoopInferenceEnvironment?.configuration.model = "gpt-4o"
            f.runtime.messages[f.runtime.messages.count - 1].content = "tail"
            f.runtime.messages[f.runtime.messages.count - 2].content = "tail"
            var requests = 0
            f.app.contextCompressionSummaryOperation = { _, _ in requests += 1; return "short" }
            let optimized = await f.app.compressContextInTurn(for: f.runtime, reason: .managedEscalation)
            guard case .nothingToCompress = optimized else { Issue.record("Expected no incremental work"); return }
            #expect(requests == 0)
            let required = await f.app.compressContextInTurn(for: f.runtime, reason: .preSendGate)
            guard case .reclaimed = required else { Issue.record("Smaller window must still allow reclamation"); return }
            #expect(requests == 1)
            #expect(!f.runtime.isCompressingContext)
        }
    }

    @Test("空增量执行结束仍释放压缩位并消费等待中的用户消息")
    func skippedCompressionStillDrainsTheQueue() async throws {
        try await withHostFixture { f in
            f.runtime.currentGoal = nil
            f.runtime.currentPlan = nil
            f.runtime.interactionMode = .normal
            f.runtime.contextSystemPromptTokenEstimate = 0
            f.runtime.messages = [.init(role: .user, content: "只检查解析器")]
                + (1...7).map { .init(role: .assistant, content: String(repeating: "evidence \($0) ", count: 2_000)) }
            let plan = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 2))
            try f.app.installContextCompression(for: f.runtime, summary: "accepted-summary",
                ticket: f.app.prepareContextCompression(for: f.runtime, through: try #require(plan.head.last?.id), sourceTokens: 50_000))
            var requests = 0
            f.app.contextCompressionSummaryOperation = { _, _ in requests += 1; return "unexpected" }
            f.install { _ in Self.normalReply }
            f.runtime.queuedMessages = [.init(text: "检查新的输入", images: [])]
            f.runtime.pendingContextRunwayResume = true
            f.runtime.isCompressingContext = true
            await f.app.runContextCompression(for: f.runtime, head: plan.head, tail: plan.tail,
                priorSummary: "accepted-summary", configurations: [.default], reason: .automatic)
            #expect(!f.runtime.isCompressingContext)
            #expect(f.runtime.queuedMessages.isEmpty)
            #expect(!f.runtime.pendingContextRunwayResume)
            await f.awaitAllTurns()
            #expect(requests == 0)
            #expect(f.provider.requests == 1)
            #expect(f.provider.lastUserTexts.last?.contains("检查新的输入") == true)
            #expect(f.runtime.contextSummary == "accepted-summary")
            #expect(!f.runtime.isResponding)
            #expect(!f.runtime.isCompressingContext)
        }
    }

    @Test("Goal 压缩重试唤醒入口允许无增量时继续缩短摘要")
    func goalRetryWakeRecompressesExistingSummary() async throws {
        try await withHostFixture { f in
            f.runtime.contextSystemPromptTokenEstimate = 0
            f.runtime.messages = [.init(role: .user, content: "只检查解析器")]
                + (1...7).map { .init(role: .assistant, content: String(repeating: "evidence \($0) ", count: 2_000)) }
            let plan = try #require(f.app.compressionPlan(for: f.runtime, keepRecent: 2))
            let through = try #require(plan.head.last?.id)
            let old = String(repeating: "summary-detail ", count: 1_000)
            try f.app.installContextCompression(for: f.runtime, summary: old,
                ticket: f.app.prepareContextCompression(for: f.runtime, through: through, sourceTokens: 50_000))
            var requests = 0
            f.app.contextCompressionSummaryOperation = { segments, _ in
                requests += 1
                #expect(segments.count == 1)
                #expect(segments[0].contains("summary-detail"))
                return "short-goal-summary"
            }
            // This test stops only after observing the wake's first dispatch;
            // the adjacent lifecycle test covers normal reply completion.
            f.install { _ in try f.stopFromProvider() }
            #expect(f.app.deferGoalAfterCompressionFailure(URLError(.timedOut), for: f.runtime))
            let wake = try #require(f.wake)
            #expect(wake.reason == .compressionRetry)
            f.app.catchUpGoalWakes(rearmPending: false, now: wake.dueAt)
            #expect(f.runtime.isCompressingContext)
            await f.provider.awaitRequests(1)
            await f.awaitAllTurns()
            #expect(requests == 1)
            #expect(f.provider.requests == 1)
            #expect(f.runtime.contextSummary == "short-goal-summary")
            #expect(f.runtime.contextSummaryThroughMessageID == through)
            #expect(f.wake == nil)
            #expect(!f.runtime.pendingContextRunwayResume)
            #expect(!f.runtime.isCompressingContext)
        }
    }

    @Test("真实回合收尾触发无增量 runway 重压，正常回复后只续跑一次")
    func summaryOnlyRunwayCompressionResumesOnce() async throws {
        try await withHostFixture { f in
            f.runtime.currentGoal = nil
            f.runtime.currentPlan = nil
            f.runtime.interactionMode = .normal
            f.runtime.contextSystemPromptTokenEstimate = 0
            f.runtime.messages = [.init(role: .user, content: "只检查解析器")]
                + (1...7).map { .init(role: .assistant, content: String(repeating: "evidence \($0) ", count: 2_000)) }
            let old = String(repeating: "summary-detail ", count: 1_000)
            // Cover the entire old transcript. The host turn adds exactly the
            // two kept messages, so its finish must recompress only the summary.
            try f.app.installContextCompression(for: f.runtime, summary: old,
                ticket: f.app.prepareContextCompression(for: f.runtime,
                    through: try #require(f.runtime.messages.last?.id), sourceTokens: 50_000))
            var requests = 0
            f.app.contextCompressionSummaryOperation = { segments, _ in
                requests += 1
                #expect(segments.count == 1)
                #expect(segments[0].contains("summary-detail"))
                return "short-summary"
            }
            f.install { request in
                if request == 1 { f.runtime.pendingContextRunwayResume = true }
                return Self.normalReply
            }
            try await f.runHostTurn()
            await f.provider.awaitRequests(2)
            await f.awaitAllTurns()
            #expect(requests == 1)
            #expect(f.provider.requests == 2, "原回合和唯一一次恢复回合")
            #expect(f.runtime.contextRunwayResumeCount == 1)
            #expect(!f.runtime.pendingContextRunwayResume)
            #expect(!f.runtime.isResponding)
            #expect(!f.runtime.isCompressingContext)
            #expect(f.runtime.contextSummary == "short-summary")
        }
    }
}
