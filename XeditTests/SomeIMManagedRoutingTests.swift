import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct SomeIMManagedRoutingTests {
    @Test("实际上游回执按请求隔离，错误响应和其他供应商不覆盖")
    func physicalModelReceiptIsScoped() throws {
        let url = URL(string: "https://example.invalid/v1/responses")!
        let success = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Routed-Model": "physical-fixture"]))
        let failure = try #require(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil,
            headerFields: ["X-Routed-Model": "failed-fixture"]))
        var received: [String] = []
        AgentRoutedModelResponseObserver.$receive.withValue({ model in received.append(model) }) {
            AgentRoutedModelResponseObserver.capture(success, providerID: "openai")
            AgentRoutedModelResponseObserver.capture(failure, providerID: AgentProviderPreset.someIMID)
            AgentRoutedModelResponseObserver.$receive.withValue(nil) {
                AgentRoutedModelResponseObserver.capture(success, providerID: AgentProviderPreset.someIMID)
            }
            AgentRoutedModelResponseObserver.capture(success, providerID: AgentProviderPreset.someIMID)
        }
        #expect(received == ["physical-fixture"])
    }

    @Test("旧会话高档下限不影响新任务")
    func legacyFloorIsIgnored() throws {
        let state = try JSONDecoder().decode(AgentManagedRoutingState.self,
            from: Data(#"{"minimumTier":"premium","lastSelectedModel":"someim-code-premium"}"#.utf8))
        #expect(state.currentTaskID == nil)
        var session = AgentSession(title: "fixture")
        session.managedRouting = state
        let runtime = AgentRuntime(session: session)
        #expect(runtime.beginManagedTask(id: UUID()) == SomeIMManagedModel.autoFlash)
        #expect(runtime.managedRouting?.minimumTier == .low)
    }

    @Test("接手仅保留当前任务，新用户任务回到 Flash")
    func takeoverScope() throws {
        var session = AgentSession(title: "fixture")
        session.managedRouting = .init()
        let runtime = AgentRuntime(session: session)
        let taskID = UUID()
        #expect(runtime.beginManagedTask(id: taskID) == SomeIMManagedModel.autoFlash)
        runtime.noteManagedTaskTakeover(model: SomeIMManagedModel.autoPro, reason: "repetition_loop")
        #expect(runtime.beginManagedTask(id: taskID) == SomeIMManagedModel.autoPro)
        #expect(runtime.managedRouting?.minimumTier == .low)
        let restored = try JSONDecoder().decode(AgentManagedRoutingState.self,
            from: JSONEncoder().encode(runtime.managedRouting!))
        #expect(restored.currentTaskID == taskID)
        #expect(restored.currentTaskModel == SomeIMManagedModel.autoPro)
        #expect(runtime.beginManagedTask(id: UUID()) == SomeIMManagedModel.autoFlash)
        #expect(runtime.managedRouting?.lastEscalationReason == nil)
    }

    @Test("复杂任务初始化也不发送分类请求")
    func startsWithoutJudge() async {
        let app = AppState(loadSessionCatalog: false)
        var session = AgentSession(title: "fixture")
        session.managedRouting = .init(minimumTier: .premium)
        session.messages = [.init(role: .user, content: "复杂跨文件架构重构")]
        let runtime = AgentRuntime(session: session)
        let config = AgentConfiguration(providerID: AgentProviderPreset.someIMID,
            baseURL: "https://no-network.invalid/v1", model: "legacy", apiKey: "")
        let route = await app.resolveManagedTurnRoute(for: runtime, configuration: config, someIMContext: nil)
        guard case .routed(let model, let decision) = route else {
            Issue.record("Managed task did not resolve")
            return
        }
        #expect(model == SomeIMManagedModel.autoFlash)
        #expect(!decision.didEscalate)
        #expect(!decision.didFallback)
    }

    @Test("仅明确生成失败触发，限长和内容过滤不触发")
    func explicitFailurePolicy() {
        let repeated = Array(repeating: "This is a repeated generation failure sentence.", count: 6).joined(separator: "\n")
        #expect(!SomeIMManagedRouting.outputQuality(assistantText: "普通回答", finishReason: "stop").shouldRetry)
        #expect(SomeIMManagedRouting.outputQuality(assistantText: " \n", finishReason: "stop").failureType == "empty_output")
        #expect(SomeIMManagedRouting.outputQuality(assistantText: repeated, finishReason: "stop").failureType == "repetition_loop")
        #expect(!SomeIMManagedRouting.outputQuality(assistantText: "", finishReason: "length").shouldRetry)
        #expect(!SomeIMManagedRouting.outputQuality(assistantText: "", finishReason: "content_filter").shouldRetry)
        #expect(SomeIMManagedModel.escalated(from: SomeIMManagedModel.autoPremium) == nil)
    }

    @Test("历史配置不再调用废弃编程别名")
    func retiredAliases() {
        let config = AgentConfiguration(providerID: AgentProviderPreset.someIMID,
            baseURL: "https://example.invalid/v1", model: "someim-code-low",
            flashModel: "someim-coding-plan-low", proModel: "someim-code-high", apiKey: "")
        #expect(config.normalized.model == SomeIMManagedModel.autoFlash)
        #expect(config.normalized.flashModel == SomeIMManagedModel.autoFlash)
        #expect(config.normalized.proModel == SomeIMManagedModel.autoPro)
        #expect(AppState.applyingSessionModelOverride("someim-code-premium", to: config).model == SomeIMManagedModel.autoFlash)
        #expect(SomeIMManagedModel.isRetired("SomeIM-Coding-Plan-Premium"))
        #expect(SomeIMManagedModel.allowlist.count == 3)
        let entry = AgentProviderEntry(id: UUID(), providerID: AgentProviderPreset.someIMID,
            displayName: "fixture", baseURL: "https://example.invalid/v1",
            flashPrimary: "someim-code-low", proPrimary: "someim-coding-plan-high")
        let models = AgentModelPickerCatalog.models(for: entry,
            fetchedModels: ["someim-code-premium", "someim-coding-plan-low", SomeIMManagedModel.autoFlash])
        #expect(models == [SomeIMManagedModel.autoFlash])
    }

    @Test("页脚显示请求模型和切换原因")
    func footer() {
        var decision = AgentManagedRouteDecision(selectedModel: SomeIMManagedModel.autoPro,
            tier: .high, domain: .general, complexity: .low, didFallback: false,
            didEscalate: true, failureType: "repetition_loop")
        #expect(decision.footerChipText.contains(SomeIMManagedModel.autoPro))
        #expect(decision.footerChipText.contains(SomeIMManagedRouting.failureLabel("repetition_loop")))
        decision.actualModel = "physical-model-fixture"
        #expect(decision.footerChipText.contains("physical-model-fixture"))
        #expect(!decision.footerChipText.contains(SomeIMManagedModel.autoPro))
    }
}
