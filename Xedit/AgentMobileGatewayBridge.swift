//
//  AgentMobileGatewayBridge.swift
//  WillDeep
//
//  Desktop-side bridge for the LAN Mobile Gateway. The Go gateway owns
//  pairing, device auth, revocation, and fan-out. The Swift app remains
//  the authority for Agent sessions and safety gates: mobile commands
//  are translated back into the same AppState entry points the Mac UI
//  uses.
//

import Combine
import Foundation

indirect enum AgentMobileGatewayJSON: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case object([String: AgentMobileGatewayJSON])
    case array([AgentMobileGatewayJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AgentMobileGatewayJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([AgentMobileGatewayJSON].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

struct AgentMobileGatewayEnvelope: Codable, Equatable, Identifiable {
    var id: String?
    var type: String
    var sessionID: String?
    var payload: [String: AgentMobileGatewayJSON]
    var timestamp: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case sessionID = "session_id"
        case payload
        case timestamp = "ts"
    }

    init(
        id: String? = nil,
        type: String,
        sessionID: String? = nil,
        payload: [String: AgentMobileGatewayJSON] = [:],
        timestamp: String? = nil
    ) {
        self.id = id
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.timestamp = timestamp
    }
}

struct AgentMobileGatewaySessionSnapshot: Codable, Equatable {
    var id: UUID
    var title: String
    var workspaceName: String
    var updatedAt: Date
    var messageCount: Int
    var isActive: Bool
    var isResponding: Bool
}

struct AgentMobileGatewayCommandResult: Equatable {
    var sessionID: UUID?
    var message: String?

    static func ok(sessionID: UUID? = nil, message: String? = nil) -> AgentMobileGatewayCommandResult {
        AgentMobileGatewayCommandResult(sessionID: sessionID, message: message)
    }
}

@MainActor
protocol AgentMobileGatewayControlling: AnyObject {
    var mobileGatewaySessions: [AgentSession] { get }
    var mobileGatewayActiveSessionID: UUID? { get }

    func mobileGatewayRuntimeIsResponding(sessionID: UUID) -> Bool
    func mobileGatewayStartSession() -> AgentSession
    func mobileGatewaySelectSession(id: UUID) -> Bool
    func mobileGatewaySendMessage(sessionID: UUID?, text: String) throws -> AgentMobileGatewayCommandResult
    func mobileGatewayStopTurn(sessionID: UUID?) throws -> AgentMobileGatewayCommandResult
}

enum AgentMobileGatewayCommandError: LocalizedError, Equatable {
    case missingText
    case invalidSessionID(String)
    case sessionNotFound(UUID)
    case unsupportedCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingText:
            return "message.send requires payload.text."
        case .invalidSessionID(let value):
            return "Invalid session id: \(value)."
        case .sessionNotFound(let id):
            return "Session not found: \(id.uuidString)."
        case .unsupportedCommand(let type):
            return "Unsupported mobile command: \(type)."
        }
    }
}

@MainActor
enum AgentMobileGatewayCommandRouter {
    static func handle(
        _ envelope: AgentMobileGatewayEnvelope,
        controller: AgentMobileGatewayControlling,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        do {
            switch envelope.type {
            case "session.list":
                return snapshotEnvelope(
                    id: envelope.id,
                    controller: controller,
                    now: now
                )
            case "session.create":
                let session = controller.mobileGatewayStartSession()
                return sessionEnvelope(
                    type: "session.upsert",
                    id: envelope.id,
                    session: session,
                    isActive: controller.mobileGatewayActiveSessionID == session.id,
                    isResponding: controller.mobileGatewayRuntimeIsResponding(sessionID: session.id),
                    now: now
                )
            case "session.select":
                let sessionID = try requiredSessionID(from: envelope)
                guard controller.mobileGatewaySelectSession(id: sessionID) else {
                    throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
                }
                return ackEnvelope(for: envelope, sessionID: sessionID, now: now)
            case "message.send":
                let text = envelope.payload["text"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { throw AgentMobileGatewayCommandError.missingText }
                let result = try controller.mobileGatewaySendMessage(
                    sessionID: try optionalSessionID(from: envelope),
                    text: text
                )
                return ackEnvelope(
                    for: envelope,
                    sessionID: result.sessionID,
                    message: result.message,
                    now: now
                )
            case "turn.stop":
                let result = try controller.mobileGatewayStopTurn(
                    sessionID: try optionalSessionID(from: envelope)
                )
                return ackEnvelope(
                    for: envelope,
                    sessionID: result.sessionID,
                    message: result.message,
                    now: now
                )
            default:
                throw AgentMobileGatewayCommandError.unsupportedCommand(envelope.type)
            }
        } catch {
            return errorEnvelope(for: envelope, error: error, now: now)
        }
    }

    static func snapshotEnvelope(
        id: String? = nil,
        controller: AgentMobileGatewayControlling,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        let activeID = controller.mobileGatewayActiveSessionID
        let sessions = controller.mobileGatewaySessions.map { session in
            sessionJSON(
                session,
                isActive: session.id == activeID,
                isResponding: controller.mobileGatewayRuntimeIsResponding(sessionID: session.id)
            )
        }
        return AgentMobileGatewayEnvelope(
            id: id,
            type: "state.snapshot",
            payload: [
                "sessions": .array(sessions),
                "active_session_id": activeID.map { .string($0.uuidString) } ?? .null
            ],
            timestamp: isoTimestamp(now)
        )
    }

    private static func sessionEnvelope(
        type: String,
        id: String?,
        session: AgentSession,
        isActive: Bool,
        isResponding: Bool,
        now: Date
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            id: id,
            type: type,
            sessionID: session.id.uuidString,
            payload: ["session": sessionJSON(session, isActive: isActive, isResponding: isResponding)],
            timestamp: isoTimestamp(now)
        )
    }

    private static func ackEnvelope(
        for envelope: AgentMobileGatewayEnvelope,
        sessionID: UUID?,
        message: String? = nil,
        now: Date
    ) -> AgentMobileGatewayEnvelope {
        var payload: [String: AgentMobileGatewayJSON] = [
            "type": .string(envelope.type)
        ]
        if let message {
            payload["message"] = .string(message)
        }
        return AgentMobileGatewayEnvelope(
            id: envelope.id,
            type: "ack",
            sessionID: sessionID?.uuidString ?? envelope.sessionID,
            payload: payload,
            timestamp: isoTimestamp(now)
        )
    }

    private static func errorEnvelope(
        for envelope: AgentMobileGatewayEnvelope,
        error: Error,
        now: Date
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            id: envelope.id,
            type: "command.error",
            sessionID: envelope.sessionID,
            payload: [
                "type": .string(envelope.type),
                "message": .string(error.localizedDescription)
            ],
            timestamp: isoTimestamp(now)
        )
    }

    private static func sessionJSON(
        _ session: AgentSession,
        isActive: Bool,
        isResponding: Bool
    ) -> AgentMobileGatewayJSON {
        .object([
            "id": .string(session.id.uuidString),
            "title": .string(session.title),
            "workspace_name": .string(session.workspaceName),
            "updated_at": .string(isoTimestamp(session.updatedAt)),
            "message_count": .int(session.messages.count),
            "is_active": .bool(isActive),
            "is_responding": .bool(isResponding)
        ])
    }

    private static func requiredSessionID(from envelope: AgentMobileGatewayEnvelope) throws -> UUID {
        guard let sessionID = try optionalSessionID(from: envelope) else {
            throw AgentMobileGatewayCommandError.invalidSessionID("")
        }
        return sessionID
    }

    private static func optionalSessionID(from envelope: AgentMobileGatewayEnvelope) throws -> UUID? {
        let raw = envelope.sessionID ?? envelope.payload["session_id"]?.stringValue
        guard let raw, !raw.isEmpty else { return nil }
        guard let id = UUID(uuidString: raw) else {
            throw AgentMobileGatewayCommandError.invalidSessionID(raw)
        }
        return id
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter.agentMobileGatewayFormatter.string(from: date)
    }
}

@MainActor
final class AgentMobileGatewayDesktopPeer: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastErrorMessage: String?

    private weak var appState: AppState?
    private var webSocketTask: URLSessionWebSocketTask?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(appState: AppState) {
        self.appState = appState
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func connect(baseURL: URL, desktopToken: String, session: URLSession = .shared) {
        disconnect()
        guard let url = websocketURL(from: baseURL) else {
            lastErrorMessage = "Invalid Mobile Gateway URL."
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(desktopToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        isConnected = true
        lastErrorMessage = nil
        task.resume()
        receiveNext()
        publishSnapshot()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    func publishSnapshot() {
        guard let appState else { return }
        send(AgentMobileGatewayCommandRouter.snapshotEnvelope(controller: appState))
    }

    private func receiveNext() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveNext()
                case .failure(let error):
                    self.isConnected = false
                    self.lastErrorMessage = error.localizedDescription
                    self.webSocketTask = nil
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard let appState else { return }
        do {
            let data: Data
            switch message {
            case .data(let value):
                data = value
            case .string(let value):
                data = Data(value.utf8)
            @unknown default:
                return
            }
            let envelope = try decoder.decode(AgentMobileGatewayEnvelope.self, from: data)
            let response = AgentMobileGatewayCommandRouter.handle(envelope, controller: appState)
            send(response)
            if response.type == "ack" {
                publishSnapshot()
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func send(_ envelope: AgentMobileGatewayEnvelope) {
        guard let task = webSocketTask else { return }
        do {
            let data = try encoder.encode(envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.lastErrorMessage = error.localizedDescription
                    self?.isConnected = false
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func websocketURL(from baseURL: URL) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        switch components?.scheme?.lowercased() {
        case "http":
            components?.scheme = "ws"
        case "https":
            components?.scheme = "wss"
        case "ws", "wss":
            break
        default:
            return nil
        }
        components?.path = "/mobile/ws"
        components?.query = nil
        return components?.url
    }
}

extension AppState: AgentMobileGatewayControlling {
    var mobileGatewaySessions: [AgentSession] { agentSessions }
    var mobileGatewayActiveSessionID: UUID? { activeAgentSessionID }

    func mobileGatewayRuntimeIsResponding(sessionID: UUID) -> Bool {
        agentRuntimes[sessionID]?.isResponding ?? false
    }

    func mobileGatewayStartSession() -> AgentSession {
        startNewAgentSession()
    }

    func mobileGatewaySelectSession(id: UUID) -> Bool {
        guard agentSessions.contains(where: { $0.id == id }) else { return false }
        selectAgentSession(id: id)
        return true
    }

    func mobileGatewaySendMessage(sessionID: UUID?, text: String) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        } else if activeRuntime == nil {
            _ = startNewAgentSession()
        }
        guard let runtime = activeRuntime else {
            let session = startNewAgentSession()
            return try mobileGatewaySendMessage(sessionID: session.id, text: text)
        }
        runtime.input = text
        sendAgentMessage()
        return .ok(sessionID: runtime.id)
    }

    func mobileGatewayStopTurn(sessionID: UUID?) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        }
        stopAgentResponse()
        return .ok(sessionID: activeAgentSessionID)
    }
}

private extension ISO8601DateFormatter {
    static let agentMobileGatewayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
