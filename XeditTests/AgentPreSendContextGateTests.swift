//
//  AgentPreSendContextGateTests.swift
//  WillDeepTests
//
//  发送前上下文硬闸与溢出 400 重试的判定。背景：2026-09-27 一次真实
//  会话向 1,048,576 窗口的模型发了 2,787,113 tokens——checkpoint 失效后
//  modelFacingHistory 回落到整份 transcript，runway 策略只加提示不拦截，
//  自动压缩又只在 turn 之间跑，主循环里没有任何一处在「必炸」时刹车。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("发送前上下文硬闸")
struct AgentPreSendContextGateTests {
    private let window = 1_048_576

    @Test("checkpoint 失效时无论用量多少都要先压")
    func staleCheckpointAlwaysGates() {
        #expect(AppState.requiresPreSendCompression(checkpointIsStale: true, usedTokens: 10, contextWindow: window))
        #expect(AppState.requiresPreSendCompression(checkpointIsStale: true, usedTokens: 0, contextWindow: window))
    }

    @Test("用量达到窗口就拦：真实事故的 2,787,113 / 1,048,576 与恰好相等的边界")
    func usedAtOrAboveWindowGates() {
        #expect(AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: 2_787_113, contextWindow: window))
        #expect(AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: window, contextWindow: window))
    }

    @Test("用量低于窗口不拦：90% 交给 runway，75% 交给 between-turns 自动压缩")
    func usedBelowWindowDoesNotGate() {
        #expect(!AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: window - 1, contextWindow: window))
        #expect(!AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: Int(Double(window) * 0.9), contextWindow: window))
        #expect(!AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: 0, contextWindow: window))
    }

    @Test("阈值常量钉在 1.0：硬闸只管必然被拒的请求")
    func thresholdIsWholeWindow() {
        #expect(AppState.preSendCompressionUsedFraction == 1.0)
    }

    @Test("窗口为 0 / 负数时按 1 处理，不会除零也不会放行")
    func degenerateWindowStillGates() {
        #expect(AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: 1, contextWindow: 0))
        #expect(AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: 1, contextWindow: -5))
        #expect(!AppState.requiresPreSendCompression(checkpointIsStale: false, usedTokens: -1, contextWindow: 0))
    }

    /// 事故里 provider 返回的原文（数字照抄），主循环的溢出重试靠它认出
    /// 「是长度问题」而不是别的 400。
    @Test("溢出 400 识别：事故原文 2787113 tokens 命中，无关 400 不命中")
    func overflowErrorFromIncidentIsRecognised() {
        func httpError(status: Int, body: String) -> AgentClientError {
            .serverStatus(
                AgentProviderHTTPError(
                    statusCode: status,
                    method: "POST",
                    url: "https://example.test/v1/chat/completions",
                    providerID: "someim",
                    model: "deepseek-v4-flash",
                    requestSummary: "chat",
                    requestBody: "(streamed request)",
                    responseBody: body
                )
            )
        }
        let incident = #"{"error":{"message":"This model's maximum context length is 1048576 tokens. However, you requested 2787113 tokens (2787113 in the messages, 0 in the completion). Please reduce the length of the messages or completion.","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#
        #expect(AppState.isContextOverflowError(httpError(status: 400, body: incident)))
        #expect(AppState.isContextOverflowError(httpError(status: 413, body: incident)))
        #expect(!AppState.isContextOverflowError(httpError(status: 400, body: #"{"error":{"message":"invalid api key"}}"#)))
        #expect(!AppState.isContextOverflowError(httpError(status: 500, body: incident)))
        #expect(!AppState.isContextOverflowError(CancellationError()))
    }
}

/// 走真实 AppState 的 turn 内同步压缩：与 AgentContextCheckpointTests 同一
/// 套 fixture（钉住消费模型窗口，摘要模型走桩，不打网络）。
@Suite("turn 内同步压缩", .serialized)
@MainActor
struct AgentInTurnCompressionTests {
    @MainActor private struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let defaults: UserDefaults
        let suite: String
        let root: URL
        func cleanup() {
            app.contextCompressionSummaryOperation = nil
            app.dispatchDecisionResumptionTask?.cancel()
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("In-turn compression fixture cleanup failed: \(error)") }
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("in-turn-compression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "in-turn-compression-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let session = app.startNewAgentSession(inWorkspaceAt: root.path)
        let runtime = try #require(app.runtime(for: session.id))
        // 同 AgentContextCheckpointTests：不钉模型，reclamation 检查的分母
        // 就来自与真实 App 共享的 UserDefaults.standard，窗口忽大忽小。
        app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://in-turn-compression.invalid/v1",
                                                   model: "gpt-5-mini", apiKey: "test-placeholder"),
                                             URLSession(configuration: .ephemeral))
        runtime.session.titleIsUserSet = true
        runtime.contextSystemPromptTokenEstimate = 0
        runtime.currentGoal = .init(statement: "完整交付，不发布", checklist: [.init(text: "测试真实通过")])
        runtime.messages = [.init(role: .user, content: "不要改无关文件；必须实际验证。"),
                            .init(role: .assistant, content: String(repeating: "old reference data ", count: 2_000)),
                            .init(role: .user, content: "接着完成剩余工作"),
                            .init(role: .assistant, content: String(repeating: "more evidence ", count: 2_000)),
                            .init(role: .user, content: "再检查一遍"),
                            .init(role: .assistant, content: "")]
        return .init(app: app, runtime: runtime, defaults: defaults, suite: suite, root: root)
    }

    @Test("响应中也能压：写回 checkpoint，压缩位复位，事后 checkpoint 有效")
    func compressesWhileRespondingAndInstallsCheckpoint() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.isResponding = true
        var requests = 0
        f.app.contextCompressionSummaryOperation = { _, _ in
            requests += 1
            return "只保留简短模型摘要"
        }
        let outcome = await f.app.compressContextInTurn(for: f.runtime, reason: .preSendGate)
        guard case .reclaimed = outcome else {
            Issue.record("expected .reclaimed, got \(outcome)")
            return
        }
        #expect(requests == 1)
        #expect(!f.runtime.isCompressingContext)
        #expect(f.runtime.contextCheckpoint != nil)
        #expect(!f.app.contextCheckpointIsStale(for: f.runtime))
        // 压完的 model-facing 视图不再原样携带被摘要掉的头部。
        #expect(!f.app.modelFacingHistory(for: f.runtime).contains { $0.content.contains("old reference data") })
    }

    @Test("已在压缩中则跳过，不并发起第二次")
    func skipsWhenAlreadyCompressing() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.runtime.isCompressingContext = true
        f.app.contextCompressionSummaryOperation = { _, _ in
            Issue.record("summariser must not be called while another compression is in flight")
            return "unexpected"
        }
        let outcome = await f.app.compressContextInTurn(for: f.runtime, reason: .preSendGate)
        guard case .skippedAlreadyCompressing = outcome else {
            Issue.record("expected .skippedAlreadyCompressing, got \(outcome)")
            return
        }
        #expect(f.runtime.isCompressingContext)
        f.runtime.isCompressingContext = false
    }

    @Test("摘要模型报错返回 .failed，压缩位复位，原状态不动")
    func reportsFailureWithoutTouchingState() async throws {
        let f = try fixture(); defer { f.cleanup() }
        struct SummariserDown: Error {}
        f.app.contextCompressionSummaryOperation = { _, _ in throw SummariserDown() }
        let outcome = await f.app.compressContextInTurn(for: f.runtime, reason: .preSendGate)
        guard case .failed(let error) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(error is SummariserDown)
        #expect(!f.runtime.isCompressingContext)
        #expect(f.runtime.contextCheckpoint == nil)
        #expect(f.runtime.contextSummary == nil)
    }

    @Test("checkpoint 装好后目标合同变了即判失效——这正是事故里整份 transcript 被发出去的前置条件")
    func checkpointGoesStaleWhenGoalContractChanges() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.app.contextCompressionSummaryOperation = { _, _ in "摘要" }
        guard case .reclaimed = await f.app.compressContextInTurn(for: f.runtime, reason: .preSendGate) else {
            Issue.record("compression did not reclaim")
            return
        }
        #expect(!f.app.contextCheckpointIsStale(for: f.runtime))
        f.runtime.currentGoal?.statement = "用户改了目标"
        #expect(f.app.contextCheckpointIsStale(for: f.runtime))
        // 没装过 checkpoint 的会话谈不上失效。
        f.runtime.contextCheckpoint = nil
        #expect(!f.app.contextCheckpointIsStale(for: f.runtime))
    }
}
