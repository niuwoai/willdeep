import Foundation
import Testing
@testable import WillDeep

private actor ResidencyCallRecorder {
    struct Call: Equatable {
        let baseURL: String
        let model: String
        let keepAlive: String
    }

    private(set) var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }

    func waitForCalls(count: Int, attempts: Int = 40) async -> [Call] {
        for _ in 0..<attempts where calls.count < count {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return calls
    }
}

@Suite("Local model residency")
struct AgentLocalModelResidencyTests {
    private func settings(enabled: Bool, resident: Bool, model: String = "gemma4:e4b-it-qat") -> AgentLocalModelSettings {
        AgentLocalModelSettings(
            enabled: enabled,
            baseURL: "http://127.0.0.1:11434/v1",
            visionModel: model,
            summaryModel: model,
            preferForImageUnderstanding: true,
            preferForTitles: true,
            preferForWorkerRouting: true,
            warmOnLaunchAndKeepResident: resident,
            exposeAsComposerModel: false,
            composerDisplayName: "Local"
        )
    }

    @Test("the resident flag is off for settings saved before it existed")
    func residentFlagDefaultsOffWhenAbsent() throws {
        let legacy = Data(#"{"enabled":true,"baseURL":"http://127.0.0.1:11434/v1","summaryModel":"gemma4:e4b-it-qat"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentLocalModelSettings.self, from: legacy)

        #expect(decoded.enabled)
        #expect(!decoded.warmOnLaunchAndKeepResident)
        #expect(!AgentLocalModelSettings.default.warmOnLaunchAndKeepResident)
    }

    @Test("the resident flag survives an encode/decode round trip")
    func residentFlagRoundTrips() throws {
        let data = try JSONEncoder().encode(settings(enabled: true, resident: true))
        let decoded = try JSONDecoder().decode(AgentLocalModelSettings.self, from: data)

        #expect(decoded.warmOnLaunchAndKeepResident)
    }

    @Test("keep-alive payload names the model and the requested residency")
    func keepAlivePayload() throws {
        let data = try #require(AgentLocalModelRoutingReadiness.keepAlivePayload(
            model: "gemma4:e4b-it-qat",
            keepAlive: AgentLocalModelRoutingReadiness.residentKeepAlive
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["model"] as? String == "gemma4:e4b-it-qat")
        #expect(object["keep_alive"] as? String == "-1")
        #expect(AgentLocalModelRoutingReadiness.keepAlive == "10m")
        #expect(AgentLocalModelRoutingReadiness.releasedKeepAlive == "5m")
        #expect(AgentLocalModelRoutingReadiness.routingKeepAlive(
            warmOnLaunchAndKeepResident: false
        ) == "10m")
        #expect(AgentLocalModelRoutingReadiness.routingKeepAlive(
            warmOnLaunchAndKeepResident: true
        ) == "-1")
    }

    @Test("an unreachable Ollama is not probed again inside the back-off window")
    func unreachableBackoff() {
        let now = Date()
        #expect(!AgentLocalModelRoutingReadiness.shouldSkipProbe(lastUnreachableAt: nil, now: now))
        #expect(AgentLocalModelRoutingReadiness.shouldSkipProbe(
            lastUnreachableAt: now.addingTimeInterval(-10),
            now: now
        ))
        #expect(!AgentLocalModelRoutingReadiness.shouldSkipProbe(
            lastUnreachableAt: now.addingTimeInterval(-AgentLocalModelRoutingReadiness.unreachableBackoff - 1),
            now: now
        ))
    }

    @Test("probe and warm-up sessions bypass the system proxy and bound both timeouts")
    func loopbackSessionIsProxyFree() {
        let session = AgentLocalModelRoutingReadiness.makeSession(timeout: 0.35)
        defer { session.finishTasksAndInvalidate() }
        let configuration = session.configuration

        #expect(configuration.timeoutIntervalForRequest == 0.35)
        #expect(configuration.timeoutIntervalForResource == 0.35)
        let proxies = configuration.connectionProxyDictionary ?? [:]
        #expect(proxies["HTTPEnable"] as? Int == 0)
        #expect(proxies["HTTPSEnable"] as? Int == 0)
        #expect(proxies["SOCKSEnable"] as? Int == 0)
    }

    @Test("the residency target exists only when local models and the flag are both on")
    func residencyTarget() {
        #expect(AgentLocalModelResidencyKeeper.target(for: settings(enabled: true, resident: true))
                == AgentLocalModelResidencyKeeper.Target(baseURL: "http://127.0.0.1:11434/v1", model: "gemma4:e4b-it-qat"))
        #expect(AgentLocalModelResidencyKeeper.target(for: settings(enabled: false, resident: true)) == nil)
        #expect(AgentLocalModelResidencyKeeper.target(for: settings(enabled: true, resident: false)) == nil)
    }

    @Test("the keeper asserts residency on enable and releases it on disable")
    @MainActor
    func keeperAssertsAndReleases() async {
        let recorder = ResidencyCallRecorder()
        let keeper = AgentLocalModelResidencyKeeper(
            startsLoops: true,
            refreshInterval: 3_600,
            assertResident: { baseURL, model, keepAlive in
                await recorder.record(.init(baseURL: baseURL, model: model, keepAlive: keepAlive))
                return true
            }
        )

        keeper.apply(settings: settings(enabled: true, resident: true))
        var calls = await recorder.waitForCalls(count: 1)
        #expect(calls == [.init(baseURL: "http://127.0.0.1:11434/v1", model: "gemma4:e4b-it-qat", keepAlive: "-1")])

        // Same target again: no restart, no extra load request.
        keeper.apply(settings: settings(enabled: true, resident: true))
        try? await Task.sleep(nanoseconds: 100_000_000)
        calls = await recorder.waitForCalls(count: 1)
        #expect(calls.count == 1)

        keeper.apply(settings: settings(enabled: true, resident: false))
        calls = await recorder.waitForCalls(count: 2)
        #expect(calls.last == ResidencyCallRecorder.Call(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "gemma4:e4b-it-qat",
            keepAlive: "5m"
        ))
        #expect(keeper.activeTarget == nil)
    }

    @Test("a keeper that does not start loops still tracks the target")
    @MainActor
    func keeperWithoutLoopsTracksTarget() async {
        let recorder = ResidencyCallRecorder()
        let keeper = AgentLocalModelResidencyKeeper(
            startsLoops: false,
            assertResident: { baseURL, model, keepAlive in
                await recorder.record(.init(baseURL: baseURL, model: model, keepAlive: keepAlive))
                return true
            }
        )

        keeper.apply(settings: settings(enabled: true, resident: true))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(keeper.activeTarget?.model == "gemma4:e4b-it-qat")
        let calls = await recorder.calls
        #expect(calls.isEmpty)
    }
}
