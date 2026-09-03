//
//  AgentLocalModelResidency.swift
//  WillDeep
//
//  Keeping the local Ollama LLM loaded, in two flavours:
//
//   - Lazy: the Worker routing judge only consults a model that is already
//     resident. A cold model is warmed in the background and the current
//     turn keeps its keyword verdict — the turn never waits for a load.
//   - Resident: when the user turned on "warm at launch and keep resident"
//     in the local-model settings, a keeper loads the model at launch and
//     re-asserts residency every few minutes, because Ollama's default
//     unload timer is 5 minutes and every request through its
//     OpenAI-compatible endpoint resets the timer to that default.
//
//  Loopback only, proxy-free: all traffic goes through
//  `AgentNetworkSupport.loopbackSession`, so a system proxy that does not
//  forward 127.0.0.1 cannot turn every probe into a timeout.
//

import Foundation

/// Latency-first readiness check for Ollama-backed routing. Pure helpers are
/// kept here so they can be tested without a running Ollama.
nonisolated enum AgentLocalModelRoutingReadiness {
    static let probeTimeout: TimeInterval = 0.35
    static let warmupTimeout: TimeInterval = 120
    /// Residency requested by a lazy warm-up: long enough for the next
    /// ambiguous request in the same sitting, short enough to hand the
    /// memory back afterwards.
    static let keepAlive = "10m"
    /// Ollama's "never unload" sentinel, used when the user opted into a
    /// resident LLM.
    static let residentKeepAlive = "-1"
    /// What the keeper hands back when residency is switched off: Ollama's
    /// own default unload timer.
    static let releasedKeepAlive = "5m"

    static func routingKeepAlive(warmOnLaunchAndKeepResident: Bool) -> String {
        warmOnLaunchAndKeepResident ? residentKeepAlive : keepAlive
    }
    /// Ollama unloads after 5 minutes by default and the OpenAI-compatible
    /// endpoint resets the timer on every request, so residency has to be
    /// re-asserted more often than that.
    static let residentRefreshInterval: TimeInterval = 4 * 60
    /// A probe that could not reach Ollama at all is not retried for this
    /// long. Without it, every ambiguous request on a machine whose Ollama
    /// is not running would pay the full probe timeout again.
    static let unreachableBackoff: TimeInterval = 60

    enum ProbeResult: Equatable, Sendable {
        case loaded
        case notLoaded
        case unreachable
    }

    static func ollamaEndpoint(baseURL: String, path: String) -> URL? {
        guard var components = URLComponents(string: baseURL),
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func containsLoadedModel(_ data: Data, model: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return false }
        let expected = canonicalModelID(model)
        return models.contains { item in
            [item["name"] as? String, item["model"] as? String]
                .compactMap { $0 }
                .map(canonicalModelID)
                .contains(expected)
        }
    }

    /// `POST /api/generate` with no prompt loads the model (or refreshes its
    /// unload timer) and returns immediately.
    static func keepAlivePayload(model: String, keepAlive: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "keep_alive": keepAlive,
        ])
    }

    static func shouldSkipProbe(lastUnreachableAt: Date?, now: Date = Date()) -> Bool {
        guard let lastUnreachableAt else { return false }
        return now.timeIntervalSince(lastUnreachableAt) < unreachableBackoff
    }

    /// Proxy-free loopback session with the same short bound on request and
    /// resource time, so a hung Ollama fails at `timeout`, not at 10 minutes.
    static func makeSession(timeout: TimeInterval) -> URLSession {
        AgentNetworkSupport.loopbackSession(requestTimeout: timeout, resourceTimeout: timeout)
    }

    private static func canonicalModelID(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(":latest") ? String(normalized.dropLast(7)) : normalized
    }
}

/// The one process-wide owner of local-model loading. Both the lazy routing
/// warm-up and the launch keeper go through it, so the same model is never
/// loaded twice concurrently and an unreachable Ollama is remembered once.
actor AgentLocalModelResidency {
    static let shared = AgentLocalModelResidency()

    private var warmingKeys: Set<String> = []
    private var lastUnreachableAt: [String: Date] = [:]

    /// Routing readiness. `true` only when the model is already loaded; a
    /// cold model is warmed in the background exactly once, and an
    /// unreachable Ollama is not probed again for `unreachableBackoff`.
    func isWarmOrSchedule(
        baseURL: String,
        model: String,
        keepAlive: String = AgentLocalModelRoutingReadiness.keepAlive
    ) async -> Bool {
        let key = Self.key(baseURL: baseURL, model: model)
        guard !warmingKeys.contains(key) else { return false }
        guard let psURL = AgentLocalModelRoutingReadiness.ollamaEndpoint(
            baseURL: baseURL,
            path: "/api/ps"
        ) else { return false }
        guard !AgentLocalModelRoutingReadiness.shouldSkipProbe(
            lastUnreachableAt: lastUnreachableAt[baseURL]
        ) else { return false }

        switch await Self.probe(psURL: psURL, model: model) {
        case .loaded:
            lastUnreachableAt[baseURL] = nil
            return true
        case .unreachable:
            lastUnreachableAt[baseURL] = Date()
            return false
        case .notLoaded:
            lastUnreachableAt[baseURL] = nil
            guard warmingKeys.insert(key).inserted else { return false }
            Task { [baseURL, model, keepAlive, key] in
                _ = await Self.sendKeepAlive(baseURL: baseURL, model: model, keepAlive: keepAlive)
                self.finish(key: key)
            }
            return false
        }
    }

    /// Load the model, or refresh its unload timer, with the given keep-alive.
    /// Returns whether Ollama accepted the request. Skipped (returns false)
    /// while a lazy warm-up for the same model is still in flight.
    func assertResident(baseURL: String, model: String, keepAlive: String) async -> Bool {
        let key = Self.key(baseURL: baseURL, model: model)
        guard warmingKeys.insert(key).inserted else { return false }
        let accepted = await Self.sendKeepAlive(baseURL: baseURL, model: model, keepAlive: keepAlive)
        warmingKeys.remove(key)
        lastUnreachableAt[baseURL] = accepted ? nil : Date()
        return accepted
    }

    private func finish(key: String) {
        warmingKeys.remove(key)
    }

    private static func key(baseURL: String, model: String) -> String {
        "\(baseURL)\u{1F}\(model)"
    }

    private nonisolated static func probe(
        psURL: URL,
        model: String
    ) async -> AgentLocalModelRoutingReadiness.ProbeResult {
        var request = URLRequest(url: psURL)
        request.timeoutInterval = AgentLocalModelRoutingReadiness.probeTimeout
        let session = AgentLocalModelRoutingReadiness.makeSession(
            timeout: AgentLocalModelRoutingReadiness.probeTimeout
        )
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .unreachable }
            return AgentLocalModelRoutingReadiness.containsLoadedModel(data, model: model)
                ? .loaded
                : .notLoaded
        } catch {
            return .unreachable
        }
    }

    private nonisolated static func sendKeepAlive(baseURL: String, model: String, keepAlive: String) async -> Bool {
        guard let url = AgentLocalModelRoutingReadiness.ollamaEndpoint(
            baseURL: baseURL,
            path: "/api/generate"
        ) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = AgentLocalModelRoutingReadiness.warmupTimeout
        request.httpBody = AgentLocalModelRoutingReadiness.keepAlivePayload(model: model, keepAlive: keepAlive)
        let session = AgentLocalModelRoutingReadiness.makeSession(
            timeout: AgentLocalModelRoutingReadiness.warmupTimeout
        )
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }
}

/// Keeps the configured local LLM loaded for the lifetime of the app when the
/// user asked for it. `apply(settings:)` runs at launch and after every save
/// of the local-model settings; turning the option off (or changing the
/// model) hands the previous model back to Ollama's default unload timer.
@MainActor
final class AgentLocalModelResidencyKeeper {
    struct Target: Equatable, Sendable {
        let baseURL: String
        let model: String
    }

    typealias Asserter = @Sendable (_ baseURL: String, _ model: String, _ keepAlive: String) async -> Bool

    static let shared = AgentLocalModelResidencyKeeper(
        // Unit tests construct AppState against the developer's real settings;
        // they must not start poking the developer's Ollama.
        startsLoops: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    )

    private let startsLoops: Bool
    private let refreshInterval: TimeInterval
    private let assertResident: Asserter
    private var loop: Task<Void, Never>?
    private(set) var activeTarget: Target?

    init(
        startsLoops: Bool = true,
        refreshInterval: TimeInterval = AgentLocalModelRoutingReadiness.residentRefreshInterval,
        assertResident: @escaping Asserter = { baseURL, model, keepAlive in
            await AgentLocalModelResidency.shared.assertResident(
                baseURL: baseURL,
                model: model,
                keepAlive: keepAlive
            )
        }
    ) {
        self.startsLoops = startsLoops
        self.refreshInterval = refreshInterval
        self.assertResident = assertResident
    }

    nonisolated static func target(for rawSettings: AgentLocalModelSettings) -> Target? {
        let settings = rawSettings.normalized
        guard settings.enabled, settings.warmOnLaunchAndKeepResident else { return nil }
        return Target(baseURL: settings.baseURL, model: settings.summaryModel)
    }

    func apply(settings: AgentLocalModelSettings) {
        let target = Self.target(for: settings)
        guard target != activeTarget else { return }
        loop?.cancel()
        loop = nil
        let previous = activeTarget
        activeTarget = target
        guard startsLoops else { return }

        if let previous {
            let release = assertResident
            Task.detached(priority: .utility) {
                _ = await release(
                    previous.baseURL,
                    previous.model,
                    AgentLocalModelRoutingReadiness.releasedKeepAlive
                )
            }
        }
        guard let target else { return }
        let assert = assertResident
        let interval = refreshInterval
        loop = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                _ = await assert(
                    target.baseURL,
                    target.model,
                    AgentLocalModelRoutingReadiness.residentKeepAlive
                )
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}
