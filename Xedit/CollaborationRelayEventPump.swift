//
//  CollaborationRelayEventPump.swift
//  WillDeep
//
//  Pulls authenticated event envelopes from the existing collaboration
//  relay. Platform payloads stay untrusted all the way into the runtime
//  kernel; possession of the relay token authorizes transport, not content.
//

import Combine
import Foundation

nonisolated enum AgentRuntimeEventDefaults {
    static let relayBaseURL = "https://fly.niuwoai.com"
    static let relayProtocolVersion = "collab-relay.v2"
}

nonisolated struct AgentRuntimeEventSettings: Codable, Equatable {
    var relayPollingEnabled: Bool = false
    var relayBaseURL: String = AgentRuntimeEventDefaults.relayBaseURL
    var orchestratorSessionID: UUID?

    var normalized: Self {
        var copy = self
        copy.relayBaseURL = copy.relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

nonisolated enum AgentRuntimeEventSettingsStore {
    private static let settingsKey = "com.willdeep.agentRuntime.events.settings.v1"
    static let didChangeNotification = Notification.Name("AgentRuntimeEventSettingsDidChange")
    static let relayTokenAccount = "collaboration/relay/access-token"

    static func load(defaults: UserDefaults = .standard) -> AgentRuntimeEventSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentRuntimeEventSettings.self, from: data) else {
            return AgentRuntimeEventSettings()
        }
        return settings.normalized
    }

    static func save(_ settings: AgentRuntimeEventSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        defaults.set(data, forKey: settingsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func saveRelayToken(_ token: String) {
        AgentCredentialStore.save(token, account: relayTokenAccount)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func relayToken() -> String {
        AgentCredentialStore.load(account: relayTokenAccount)
    }
}

nonisolated struct CollaborationRelayIncomingEvent: Decodable {
    var id: String
    var platform: String
    var kind: String
    var receivedAt: Date?
    var body: AgentMobileGatewayJSON?
    var authenticatedIngress: Bool

    private enum CodingKeys: String, CodingKey {
        case id, platform, kind, body
        case receivedAt = "received_at"
        case authenticatedIngress = "authenticated_ingress"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        platform = try container.decode(String.self, forKey: .platform)
        kind = try container.decode(String.self, forKey: .kind)
        receivedAt = try container.decodeIfPresent(Date.self, forKey: .receivedAt)
        body = try container.decodeIfPresent(AgentMobileGatewayJSON.self, forKey: .body)
        authenticatedIngress = try container.decodeIfPresent(Bool.self, forKey: .authenticatedIngress) ?? false
    }
}

nonisolated private struct CollaborationRelayPollEnvelope: Decodable {
    struct Payload: Decodable {
        var events: [CollaborationRelayIncomingEvent]
        var remaining: Int
        var received: Int?
        var acknowledged: Int?
        var dropped: Int?
        var deduplicated: Int?
    }
    var ok: Bool
    var data: Payload?
    var error: String?
}

nonisolated private struct CollaborationRelayStatusEnvelope: Decodable {
    var ok: Bool
    var error: String?
}

nonisolated private struct CollaborationRelayAckEnvelope: Encodable {
    var eventIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case eventIDs = "event_ids"
    }
}

nonisolated struct CollaborationRelayPollBatch {
    var events: [CollaborationRelayIncomingEvent]
    var remaining: Int
    var received: Int?
    var acknowledged: Int?
    var dropped: Int?
    var deduplicated: Int?
}

nonisolated struct CollaborationRelayEventClient {
    var session: URLSession = .shared

    func poll(baseURL: URL, token: String, limit: Int = 10) async throws -> CollaborationRelayPollBatch {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("events/poll"),
            resolvingAgainstBaseURL: false
        ) else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard http.value(forHTTPHeaderField: "X-WillDeep-Relay-Protocol")
                == AgentRuntimeEventDefaults.relayProtocolVersion else {
            throw NSError(
                domain: "CollaborationRelay",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Relay protocol v2 is required for durable delivery"]
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CollaborationRelayPollEnvelope.self, from: data)
        guard envelope.ok else {
            throw NSError(
                domain: "CollaborationRelay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: envelope.error ?? "Relay rejected the poll request"]
            )
        }
        return CollaborationRelayPollBatch(
            events: envelope.data?.events ?? [],
            remaining: max(envelope.data?.remaining ?? 0, 0),
            received: envelope.data?.received,
            acknowledged: envelope.data?.acknowledged,
            dropped: envelope.data?.dropped,
            deduplicated: envelope.data?.deduplicated
        )
    }

    func acknowledge(baseURL: URL, token: String, eventIDs: [String]) async throws {
        guard !eventIDs.isEmpty else { return }
        let url = baseURL.appendingPathComponent("events/ack")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            CollaborationRelayAckEnvelope(eventIDs: Array(eventIDs.prefix(100)))
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard http.value(forHTTPHeaderField: "X-WillDeep-Relay-Protocol")
                == AgentRuntimeEventDefaults.relayProtocolVersion else {
            throw NSError(
                domain: "CollaborationRelay",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Relay protocol v2 is required for durable delivery"]
            )
        }
        let envelope = try JSONDecoder().decode(CollaborationRelayStatusEnvelope.self, from: data)
        guard envelope.ok else {
            throw NSError(
                domain: "CollaborationRelay",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: envelope.error ?? "Relay rejected the acknowledgement"]
            )
        }
    }
}

nonisolated enum CollaborationRelayPumpState: Equatable, Sendable {
    case disabled
    case configurationRequired
    case connecting
    case connected
    case backingOff
}

@MainActor
final class CollaborationRelayEventPump: ObservableObject {
    static let shared = CollaborationRelayEventPump()

    @Published private(set) var state: CollaborationRelayPumpState = .disabled
    @Published private(set) var lastPollAt: Date?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var receivedEventCount = 0
    @Published private(set) var acknowledgedEventCount = 0
    @Published private(set) var relayPendingEventCount = 0
    @Published private(set) var relayDroppedEventCount = 0
    @Published private(set) var relayDeduplicatedEventCount = 0

    private weak var fallbackAppState: AppState?
    private var task: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?
    private var connectorObserver: NSObjectProtocol?
    private let client: CollaborationRelayEventClient
    private var fallbackCountedEventIDs: Set<String> = []
    private var fallbackCountedEventOrder: [String] = []

    init(client: CollaborationRelayEventClient = CollaborationRelayEventClient()) {
        self.client = client
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AgentRuntimeEventSettingsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartIfNeeded()
            }
        }
        connectorObserver = NotificationCenter.default.addObserver(
            forName: CollaborationConnectorSettingsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartIfNeeded()
            }
        }
    }

    func attach(to appState: AppState) {
        fallbackAppState = appState
        guard task == nil else { return }
        restartIfNeeded()
    }

    private func restartIfNeeded() {
        task?.cancel()
        task = nil
        let settings = AgentRuntimeEventSettingsStore.load()
        let token = AgentRuntimeEventSettingsStore.relayToken()
        let connectors = CollaborationConnectorSettingsStore.load().connectors
        let hasRelayConnector = connectors.contains { $0.isEnabled && $0.cloudRelayEnabled }
        guard settings.relayPollingEnabled else {
            state = .disabled
            lastError = nil
            return
        }
        guard hasRelayConnector,
              !token.isEmpty,
              let baseURL = URL(string: settings.relayBaseURL),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && baseURL.host == "127.0.0.1") else {
            state = .configurationRequired
            lastError = nil
            return
        }

        state = .connecting
        lastError = nil

        task = Task { [weak self] in
            var failureDelay: UInt64 = 2
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    self.lastPollAt = Date()
                    let batch = try await self.client.poll(baseURL: baseURL, token: token)
                    failureDelay = 2
                    if let received = batch.received {
                        self.receivedEventCount = received
                    } else {
                        for event in batch.events where self.fallbackCountedEventIDs.insert(event.id).inserted {
                            self.fallbackCountedEventOrder.append(event.id)
                            self.receivedEventCount += 1
                        }
                        if self.fallbackCountedEventOrder.count > 5_000 {
                            let overflow = self.fallbackCountedEventOrder.count - 5_000
                            let expired = self.fallbackCountedEventOrder.prefix(overflow)
                            expired.forEach { self.fallbackCountedEventIDs.remove($0) }
                            self.fallbackCountedEventOrder.removeFirst(overflow)
                        }
                    }
                    if let acknowledged = batch.acknowledged {
                        self.acknowledgedEventCount = acknowledged
                    }
                    if let dropped = batch.dropped {
                        self.relayDroppedEventCount = dropped
                    }
                    if let deduplicated = batch.deduplicated {
                        self.relayDeduplicatedEventCount = deduplicated
                    }
                    self.relayPendingEventCount = batch.remaining + batch.events.count
                    var acceptedEventIDs: [String] = []
                    var acceptedRuntimeIDs: Set<UUID> = []
                    for event in batch.events {
                        guard !Task.isCancelled else { return }
                        let target = EditorAppStateRegistry.shared.current ?? self.fallbackAppState
                        if let runtimeID = target?.receiveCollaborationRelayEvent(event) {
                            acceptedEventIDs.append(event.id)
                            acceptedRuntimeIDs.insert(runtimeID)
                        }
                    }
                    if !acceptedEventIDs.isEmpty {
                        let persistenceFailures = await Task.detached(priority: .utility) {
                            AgentKernelEventStore.flushPendingWrites(for: acceptedRuntimeIDs)
                        }.value
                        guard persistenceFailures.isEmpty else {
                            throw NSError(
                                domain: "CollaborationRelay",
                                code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "Runtime event journal is not durable; Relay acknowledgement was withheld"]
                            )
                        }
                        try await self.client.acknowledge(
                            baseURL: baseURL,
                            token: token,
                            eventIDs: acceptedEventIDs
                        )
                        self.acknowledgedEventCount += acceptedEventIDs.count
                        self.relayPendingEventCount = max(
                            self.relayPendingEventCount - acceptedEventIDs.count,
                            batch.remaining
                        )
                    }
                    self.lastSuccessAt = Date()
                    self.lastError = nil
                    self.state = .connected
                    try await Task.sleep(for: .seconds(batch.events.isEmpty ? 2 : 0.25))
                } catch is CancellationError {
                    return
                } catch {
                    self.lastError = error.localizedDescription
                    self.state = .backingOff
                    try? await Task.sleep(for: .seconds(failureDelay))
                    failureDelay = min(failureDelay * 2, 30)
                }
            }
        }
    }
}
