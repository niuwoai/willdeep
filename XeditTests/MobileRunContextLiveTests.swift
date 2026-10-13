import Foundation
import Testing
@testable import WillDeep

@Suite("真实手机修改原生 Mac 配置", .serialized)
struct MobileRunContextLiveTests {
    @Test @MainActor
    func receivesPhoneConfigurationAndExecutesLocalModelRequest() async throws {
        guard let path = ProcessInfo.processInfo.environment["WILLDEEP_MOBILE_LIVE_CONFIG"] else { return }
        let config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String])
        let relay = try #require(URL(string: config["relay"] ?? ""))
        #expect(relay.host == "127.0.0.1")
        let room = try #require(config["room"])
        let token = try #require(config["token"])
        let ready = try #require(config["ready"])
        let done = try #require(config["done"])
        let modelBase = try #require(config["model_base"])
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-mac-context-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(rootDirectory: root, loadSessionCatalog: false)
        let alpha = AgentProviderEntry(providerID: AgentProviderPreset.ollamaID, displayName: "alpha", baseURL: modelBase,
                                       flashPrimary: "configured-model", proPrimary: "remote-model")
        let beta = AgentProviderEntry(providerID: AgentProviderPreset.ollamaID, displayName: "beta", baseURL: modelBase,
                                      flashPrimary: "beta-model", proPrimary: "remote-model")
        state.agentProviderLibrary = AgentProviderLibrary(entries: [alpha, beta], activeID: alpha.id)
        let session = state.startNewAgentSession()
        state.setAgentApprovalMode(.smart)
        let peer = AgentMobileGatewayDesktopPeer(appState: state)
        let transport = URLSessionConfiguration.ephemeral
        transport.connectionProxyDictionary = [:]
        peer.connectRelay(baseURL: relay, room: room, relayToken: token, session: URLSession(configuration: transport))
        defer {
            peer.disconnect()
            state.stopAgentResponse()
            AgentSessionStore.delete(id: session.id)
            try? FileManager.default.removeItem(at: root)
        }
        let safeSkill = try #require(AgentSkillDirectory.list(includeDisabled: false).first(where: { $0.source == .bundled }))
        try JSONSerialization.data(withJSONObject: ["skill_id": safeSkill.identifier]).write(to: URL(fileURLWithPath: ready))
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(FileManager.default.fileExists(atPath: done))
        #expect(state.activeAgentProviderEntry?.id == beta.id)
        #expect(state.agentProviderLibrary.activeID == alpha.id)
        #expect(state.activeRuntime?.approvalMode == .fullAccess)
        #expect(state.activeAgentModelID == "remote-model")
        #expect(state.activeRuntime?.messages.contains(where: { $0.role == .assistant && $0.content.contains("fixture complete") }) == true)
    }
}
