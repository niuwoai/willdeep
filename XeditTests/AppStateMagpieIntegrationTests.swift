import Foundation
import Testing
@testable import WillDeep

@Suite("Magpie 会话来源与真实请求", .serialized)
@MainActor
struct AppStateMagpieIntegrationTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("magpie-app-tests-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ home: URL, model: String = "mock/model-a", baseURL: String = "http://127.0.0.1:3425/v1") throws {
        let directory = AgentMagpieIntegration.directoryComponents.reduce(home) { $0.appendingPathComponent($1) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "client_id": "willdeep",
            "enabled": true, "base_url": baseURL, "client_marker": "magpie-willdeep", "model": model,
            "context_window": 8192, "max_output_tokens": 1024])
        try data.write(to: directory.appendingPathComponent("connection.json"), options: .atomic)
    }

    private func disconnect(_ home: URL) throws {
        let directory = AgentMagpieIntegration.directoryComponents.reduce(home) { $0.appendingPathComponent($1) }
        try Data("{\"model\":\"native/restored\"}".utf8).write(to: directory.appendingPathComponent("connection.json"), options: .atomic)
    }

    private func app(home: URL) -> AppState {
        let app = AppState(loadSessionCatalog: false)
        let saved = AgentProviderEntry(providerID: AgentProviderPreset.customID, displayName: "Saved fixture",
            baseURL: "http://127.0.0.1:9/v1", apiKey: "synthetic-fixture",
            flashPrimary: "saved/model", proPrimary: "saved/model", routingMode: .flash,
            customKindOverride: .openAIChat)
        app.agentProviderLibrary = AgentProviderLibrary(entries: [saved], activeID: saved.id)
        app.applyActiveProviderLibraryEntry()
        app.magpieIntegrationHome = home
        return app
    }

    private func storedLibrary() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(AgentSettingsStore.loadProviderLibrary())
    }

    private func draft(_ app: AppState) -> AgentRuntime {
        let saved = app.agentProviderLibrary.active!
        let runtime = AgentRuntime(session: AgentSession(modelID: saved.flashPrimary, providerEntryID: saved.id,
            providerID: saved.providerID, providerDisplayName: saved.displayName))
        app.prepareMagpieDefaultForNewSession(runtime)
        return runtime
    }

    @Test("新 A 固定来源，外部 B 只影响新会话；用户存储保持不变")
    func pinnedModelsAndStorage() async throws {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(home: root)
        let before = try storedLibrary()
        let savedConfiguration = app.agentConfiguration
        try write(root, model: " mock/model-a ")
        let old = draft(app)
        try await app.prepareMagpieConnectionForTurn(old)
        #expect(old.sessionProviderEntryID == AgentMagpieIntegration.providerEntryID)
        #expect(old.sessionModelOverride == " mock/model-a ")
        #expect(app.configurationForCurrentTurn(for: old).model(for: .interactive) == " mock/model-a ")
        let activeSnapshot = app.configurationForCurrentTurn(for: old)
        try write(root, model: "mock/model-b")
        let new = draft(app)
        try await app.prepareMagpieConnectionForTurn(new)
        try await app.prepareMagpieConnectionForTurn(old)
        #expect(new.sessionModelOverride == "mock/model-b")
        #expect(app.configurationForCurrentTurn(for: old).model(for: .interactive) == " mock/model-a ")
        #expect(app.configurationForCurrentTurn(for: old).magpieConnection?.contextWindow == nil)
        #expect(app.auxiliaryBaseConfiguration(for: old).model == " mock/model-a ")
        #expect(activeSnapshot.magpieConnection?.contextWindow == 8192)
        #expect(app.effectiveAgentProviderLibrary.entries.count == 2)
        #expect(app.agentProviderLibrary.entries.count == 1)
        #expect(app.agentConfiguration == savedConfiguration)
        #expect(try storedLibrary() == before)
        #expect(AgentSettingsStore.loadProviderLibrary().entries.allSatisfy { $0.id != AgentMagpieIntegration.providerEntryID })
        #expect(!AgentSettingsStore.materializeProviderLibraryAPIKey(in: &app.agentProviderLibrary, id: AgentMagpieIntegration.providerEntryID))

        try disconnect(root)
        await app.refreshMagpieIntegration()
        #expect(throws: Never.self) { try activeSnapshot.validateMagpieConnection() }
        do { try await app.prepareMagpieConnectionForTurn(old); Issue.record("断开的集成会话必须报错") }
        catch let failure as AgentMagpieIntegration.Failure { #expect(failure.code == .disconnected) }
        #expect(throws: AgentMagpieIntegration.Failure.self) { try app.configurationForCurrentTurn(for: old).validateMagpieConnection() }
        let after = draft(app)
        try await app.prepareMagpieConnectionForTurn(after)
        #expect(after.sessionProviderEntryID == app.agentProviderLibrary.activeID)
        #expect(after.sessionModelOverride != "native/restored")
        #expect(try storedLibrary() == before)
    }

    @Test("无绑定旧会话跳过集成；显式其他选择不被 invalid 阻断")
    func legacyAndExplicitChoices() async throws {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(home: root)
        try write(root)
        let legacy = AgentRuntime(session: AgentSession())
        app.seedPersistedSessionModelOverride(for: legacy)
        try await app.prepareMagpieConnectionForTurn(legacy)
        #expect(legacy.sessionProviderEntryID == nil)
        #expect(app.configurationForCurrentTurn(for: legacy).magpieConnection == nil)
        #expect(app.configurationForCurrentTurn(for: legacy).baseURL == app.agentConfiguration.baseURL)
        let pending = draft(app)
        pending.sessionModelOverride = "explicit/model"
        let file = AgentMagpieIntegration.directoryComponents.reduce(root) { $0.appendingPathComponent($1) }.appendingPathComponent("connection.json")
        try Data("{\"enabled\":false,\"unknown\":true}".utf8).write(to: file, options: .atomic)
        try await app.prepareMagpieConnectionForTurn(pending)
        #expect(pending.sessionProviderEntryID == app.agentProviderLibrary.activeID)
        #expect(app.configurationForCurrentTurn(for: pending).magpieConnection == nil)
        let implicit = draft(app)
        do { try await app.prepareMagpieConnectionForTurn(implicit); Issue.record("隐式新会话必须显示无效配置") }
        catch let failure as AgentMagpieIntegration.Failure { #expect(failure.code == .field) }
    }

    @Test("同 UUID 冲突拒绝覆盖；同址辅助请求仍保留集成来源")
    func conflictsAndAuxiliaryProvenance() async throws {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(home: root)
        try write(root)
        let runtime = draft(app)
        try await app.prepareMagpieConnectionForTurn(runtime)
        let session = app.magpieConfiguration(for: runtime)
        var sameAddress = session
        sameAddress.magpieConnection = nil
        #expect(AppState.auxiliaryBaseConfiguration(global: sameAddress, session: session).magpieConnection != nil)
        let titleCandidates = app.titleSummaryConfigurationCandidates(remoteModelID: session.model, base: session)
        #expect(titleCandidates.count == 1)
        #expect(titleCandidates.first?.magpieConnection != nil)
        #expect(app.contextCompressionConfigurationCandidates(for: runtime).first?.magpieConnection != nil)
        let conflicting = AgentProviderEntry(id: AgentMagpieIntegration.providerEntryID,
            providerID: AgentProviderPreset.customID, baseURL: "http://127.0.0.1:9/v1",
            flashPrimary: "saved/conflict", proPrimary: "saved/conflict")
        app.agentProviderLibrary.entries.append(conflicting)
        #expect(app.magpieIntegrationFailure?.code == .conflict)
        #expect(app.magpieProviderEntry == nil)
        #expect(app.agentProviderLibrary.entries.last == conflicting)
        #expect(throws: AgentMagpieIntegration.Failure.self) { try app.magpieConfiguration(for: runtime).validateMagpieConnection() }
    }

    @Test("异步连接准备期间标记忙碌，invalid 保留消息并停止派发")
    func dispatchPreparationState() async throws {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = app(home: root)
        try write(root)
        let file = AgentMagpieIntegration.directoryComponents.reduce(root) { $0.appendingPathComponent($1) }.appendingPathComponent("connection.json")
        try Data("{\"enabled\":".utf8).write(to: file, options: .atomic)
        let runtime = draft(app)
        app.dispatchAgentMessage(for: runtime, text: "fixture unsent", images: [])
        #expect(runtime.isResponding)
        let pending = try #require(runtime.requestTask)
        await pending.value
        #expect(!runtime.isResponding)
        #expect(runtime.requestTask == nil)
        #expect(runtime.errorMessage != nil)
        #expect(runtime.messages.filter { $0.role == .user }.count == 1)
        #expect(runtime.messages.last?.content == "fixture unsent")
        #expect(runtime.activeTurnConfiguration == nil)
    }

    @Test("真实 AgentClient 发送目录、流式请求和辅助请求；断开后零请求")
    func nativeClientRequests() async throws {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let sse = "data: {\"id\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let upstream = try MagpieFakeUpstream(responses: [
            MagpieFakeUpstream.response("{\"data\":[{\"id\":\"mock/model-a\"}]}"),
            MagpieFakeUpstream.response(sse, contentType: "text/event-stream"),
            MagpieFakeUpstream.response("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"auxiliary\"}}]}")
        ])
        defer { upstream.stop() }
        let app = app(home: root)
        try write(root, baseURL: upstream.baseURL.replacingOccurrences(of: "127.0.0.1", with: "localhost"))
        let runtime = draft(app)
        try await app.prepareMagpieConnectionForTurn(runtime)
        let client = AgentClient(configuration: app.configurationForCurrentTurn(for: runtime))
        #expect(try await client.fetchModels() == ["mock/model-a"])
        try await client.streamChat(messages: [AgentMessage(role: .user, content: "fixture")], tools: [], onEvent: { _ in })
        let auxiliary = AgentClient(configuration: app.auxiliaryBaseConfiguration(for: runtime))
        #expect(try await auxiliary.budgetedRouteJudge(model: "mock/model-a", systemPrompt: "fixture", userPayload: "fixture", maxTokens: 16) == "auxiliary")
        let requests = upstream.requests
        #expect(requests.count == 3)
        let decoded = requests.map { String(decoding: $0, as: UTF8.self) }
        #expect(decoded[0].hasPrefix("GET /v1/models "))
        #expect(decoded[1].hasPrefix("POST /v1/chat/completions "))
        #expect(decoded.allSatisfy { $0.lowercased().contains("authorization: bearer magpie-willdeep") })
        #expect(decoded.allSatisfy { !$0.lowercased().contains("synthetic-fixture") })
        let boundary = try #require(requests[1].range(of: Data("\r\n\r\n".utf8)))
        let body = try #require(JSONSerialization.jsonObject(with: requests[1][boundary.upperBound...]) as? [String: Any])
        #expect(body["model"] as? String == "mock/model-a")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(!AgentLocalModelPrompting.isLocalProvider(app.configurationForCurrentTurn(for: runtime)))
        try disconnect(root)
        await app.refreshMagpieIntegration()
        let disconnectedClient = AgentClient(configuration: app.configurationForCurrentTurn(for: runtime))
        do { _ = try await disconnectedClient.fetchModels(); Issue.record("断开后不能回退") }
        catch let failure as AgentMagpieIntegration.Failure { #expect(failure.code == .disconnected) }
        #expect(upstream.requests.count == 3)
    }
}
