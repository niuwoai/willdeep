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

struct AgentMobileGatewayToolApprovalSnapshot: Equatable {
    var id: String
    var title: String
    var summary: String
    var toolName: String
    var inputPreview: String
    var sessionID: UUID
}

struct AgentMobileGatewayPatchSnapshot: Equatable {
    var id: UUID
    var title: String
    var summary: String
    var path: String
    var stats: String
    var sessionID: UUID
}

struct AgentMobileGatewayDiffSnapshot: Equatable {
    var patchID: UUID
    var title: String
    var diff: String
    var sessionID: UUID
}

struct AgentMobileGatewayJobSnapshot: Equatable {
    var id: UUID
    var handle: String
    var command: String
    var status: String
    var isAlive: Bool
    var pid: Int32
    var exitCode: Int32?
    var outputByteCount: Int
    var startedAt: Date
    var finishedAt: Date?
    var sessionID: UUID
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
    var mobileGatewayPendingToolApprovals: [AgentMobileGatewayToolApprovalSnapshot] { get }
    var mobileGatewayPendingPatchProposals: [AgentMobileGatewayPatchSnapshot] { get }
    func mobileGatewayDecideTool(
        sessionID: UUID?,
        toolID: String,
        approved: Bool,
        typedConfirmation: String?,
        answer: String?
    ) throws -> AgentMobileGatewayCommandResult
    func mobileGatewayDecidePatch(
        sessionID: UUID?,
        patchID: UUID,
        approved: Bool
    ) throws -> AgentMobileGatewayCommandResult
    func mobileGatewayDiff(
        sessionID: UUID?,
        patchID: UUID
    ) throws -> AgentMobileGatewayDiffSnapshot
    var mobileGatewayJobs: [AgentMobileGatewayJobSnapshot] { get }
    func mobileGatewayKillJob(
        sessionID: UUID?,
        jobID: String
    ) throws -> AgentMobileGatewayCommandResult
}

enum AgentMobileGatewayCommandError: LocalizedError, Equatable {
    case missingText
    case missingID(String)
    case missingAnswer
    case invalidDecision
    case invalidSessionID(String)
    case sessionNotFound(UUID)
    case toolNotFound(String)
    case toolNotPending(String)
    case confirmationRequired(String)
    case invalidPatchID(String)
    case patchNotFound(UUID)
    case jobNotFound(String)
    case unsupportedCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingText:
            return "message.send requires payload.text."
        case .missingID(let type):
            return "\(type) requires payload.id."
        case .missingAnswer:
            return "ask_user decisions require payload.answer."
        case .invalidDecision:
            return "Decision must be approve or reject."
        case .invalidSessionID(let value):
            return "Invalid session id: \(value)."
        case .sessionNotFound(let id):
            return "Session not found: \(id.uuidString)."
        case .toolNotFound(let id):
            return "Tool call not found: \(id)."
        case .toolNotPending(let id):
            return "Tool call is not awaiting a mobile decision: \(id)."
        case .confirmationRequired(let id):
            return "Tool call \(id) requires typed confirmation."
        case .invalidPatchID(let value):
            return "Invalid patch id: \(value)."
        case .patchNotFound(let id):
            return "Patch proposal not found: \(id.uuidString)."
        case .jobNotFound(let id):
            return "Background job not found: \(id)."
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
            case "tool.decide":
                let toolID = try requiredPayloadString("id", aliases: ["tool_call_id", "approval_id"], from: envelope)
                let result = try controller.mobileGatewayDecideTool(
                    sessionID: try optionalSessionID(from: envelope),
                    toolID: toolID,
                    approved: try approvedDecision(from: envelope),
                    typedConfirmation: envelope.payload["typed_confirmation"]?.stringValue,
                    answer: envelope.payload["answer"]?.stringValue
                )
                return ackEnvelope(
                    for: envelope,
                    sessionID: result.sessionID,
                    message: result.message,
                    now: now
                )
            case "patch.decide":
                let rawPatchID = try requiredPayloadString("id", aliases: ["patch_id"], from: envelope)
                guard let patchID = UUID(uuidString: rawPatchID) else {
                    throw AgentMobileGatewayCommandError.invalidPatchID(rawPatchID)
                }
                let result = try controller.mobileGatewayDecidePatch(
                    sessionID: try optionalSessionID(from: envelope),
                    patchID: patchID,
                    approved: try approvedDecision(from: envelope)
                )
                return ackEnvelope(
                    for: envelope,
                    sessionID: result.sessionID,
                    message: result.message,
                    now: now
                )
            case "diff.get":
                let rawPatchID = try requiredPayloadString("id", aliases: ["patch_id"], from: envelope)
                guard let patchID = UUID(uuidString: rawPatchID) else {
                    throw AgentMobileGatewayCommandError.invalidPatchID(rawPatchID)
                }
                let diff = try controller.mobileGatewayDiff(
                    sessionID: try optionalSessionID(from: envelope),
                    patchID: patchID
                )
                return diffAckEnvelope(
                    for: envelope,
                    diff: diff,
                    now: now
                )
            case "job.kill":
                let jobID = try requiredPayloadString("id", aliases: ["job_id"], from: envelope)
                let result = try controller.mobileGatewayKillJob(
                    sessionID: try optionalSessionID(from: envelope),
                    jobID: jobID
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
                "active_session_id": activeID.map { .string($0.uuidString) } ?? .null,
                "pending_tools": .array(controller.mobileGatewayPendingToolApprovals.map(toolApprovalJSON)),
                "patch_proposals": .array(controller.mobileGatewayPendingPatchProposals.map(patchProposalJSON)),
                "jobs": .array(controller.mobileGatewayJobs.map(jobJSON))
            ],
            timestamp: isoTimestamp(now)
        )
    }

    static func toolPendingEnvelope(
        _ approval: AgentMobileGatewayToolApprovalSnapshot,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            type: "tool.pending",
            sessionID: approval.sessionID.uuidString,
            payload: toolApprovalPayload(approval),
            timestamp: isoTimestamp(now)
        )
    }

    static func patchUpsertEnvelope(
        _ proposal: AgentMobileGatewayPatchSnapshot,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            type: "patch.upsert",
            sessionID: proposal.sessionID.uuidString,
            payload: patchProposalPayload(proposal),
            timestamp: isoTimestamp(now)
        )
    }

    static func jobUpdatedEnvelope(
        _ job: AgentMobileGatewayJobSnapshot,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            type: "job.updated",
            sessionID: job.sessionID.uuidString,
            payload: jobPayload(job),
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

    private static func diffAckEnvelope(
        for envelope: AgentMobileGatewayEnvelope,
        diff: AgentMobileGatewayDiffSnapshot,
        now: Date
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            id: envelope.id,
            type: "ack",
            sessionID: diff.sessionID.uuidString,
            payload: [
                "type": .string(envelope.type),
                "patch_id": .string(diff.patchID.uuidString),
                "title": .string(diff.title),
                "diff": .string(diff.diff)
            ],
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

    private static func toolApprovalJSON(_ approval: AgentMobileGatewayToolApprovalSnapshot) -> AgentMobileGatewayJSON {
        .object(toolApprovalPayload(approval))
    }

    private static func toolApprovalPayload(_ approval: AgentMobileGatewayToolApprovalSnapshot) -> [String: AgentMobileGatewayJSON] {
        [
            "id": .string(approval.id),
            "title": .string(approval.title),
            "summary": .string(approval.summary),
            "tool_name": .string(approval.toolName),
            "input_preview": .string(approval.inputPreview),
            "session_id": .string(approval.sessionID.uuidString)
        ]
    }

    private static func patchProposalJSON(_ proposal: AgentMobileGatewayPatchSnapshot) -> AgentMobileGatewayJSON {
        .object(patchProposalPayload(proposal))
    }

    private static func patchProposalPayload(_ proposal: AgentMobileGatewayPatchSnapshot) -> [String: AgentMobileGatewayJSON] {
        [
            "id": .string(proposal.id.uuidString),
            "title": .string(proposal.title),
            "summary": .string(proposal.summary),
            "path": .string(proposal.path),
            "stats": .string(proposal.stats),
            "session_id": .string(proposal.sessionID.uuidString)
        ]
    }

    private static func jobJSON(_ job: AgentMobileGatewayJobSnapshot) -> AgentMobileGatewayJSON {
        .object(jobPayload(job))
    }

    private static func jobPayload(_ job: AgentMobileGatewayJobSnapshot) -> [String: AgentMobileGatewayJSON] {
        var payload: [String: AgentMobileGatewayJSON] = [
            "id": .string(job.id.uuidString),
            "handle": .string(job.handle),
            "command": .string(job.command),
            "status": .string(job.status),
            "is_alive": .bool(job.isAlive),
            "pid": .int(Int(job.pid)),
            "output_byte_count": .int(job.outputByteCount),
            "started_at": .string(isoTimestamp(job.startedAt)),
            "session_id": .string(job.sessionID.uuidString)
        ]
        if let exitCode = job.exitCode {
            payload["exit_code"] = .int(Int(exitCode))
        }
        if let finishedAt = job.finishedAt {
            payload["finished_at"] = .string(isoTimestamp(finishedAt))
        }
        return payload
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

    private static func requiredPayloadString(
        _ key: String,
        aliases: [String] = [],
        from envelope: AgentMobileGatewayEnvelope
    ) throws -> String {
        for candidate in [key] + aliases {
            if let value = envelope.payload[candidate]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        throw AgentMobileGatewayCommandError.missingID(envelope.type)
    }

    private static func approvedDecision(from envelope: AgentMobileGatewayEnvelope) throws -> Bool {
        if let approved = envelope.payload["approved"]?.boolValue {
            return approved
        }
        guard let raw = envelope.payload["decision"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else {
            throw AgentMobileGatewayCommandError.invalidDecision
        }
        switch raw {
        case "approve", "approved", "allow", "confirm", "yes", "true":
            return true
        case "reject", "rejected", "deny", "denied", "no", "false":
            return false
        default:
            throw AgentMobileGatewayCommandError.invalidDecision
        }
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
        for approval in appState.mobileGatewayPendingToolApprovals {
            send(AgentMobileGatewayCommandRouter.toolPendingEnvelope(approval))
        }
        for proposal in appState.mobileGatewayPendingPatchProposals {
            send(AgentMobileGatewayCommandRouter.patchUpsertEnvelope(proposal))
        }
        for job in appState.mobileGatewayJobs {
            send(AgentMobileGatewayCommandRouter.jobUpdatedEnvelope(job))
        }
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
    var mobileGatewayPendingToolApprovals: [AgentMobileGatewayToolApprovalSnapshot] {
        agentRuntimes.values.flatMap { runtime in
            runtime.toolCalls
                .filter { call in
                    call.status == .pendingApproval ||
                    call.status == .awaitingConfirm ||
                    call.status == .awaitingUserAnswer
                }
                .map { call in
                    AgentMobileGatewayToolApprovalSnapshot(
                        id: call.id.uuidString,
                        title: mobileGatewayToolTitle(for: call),
                        summary: mobileGatewayToolSummary(for: call),
                        toolName: call.toolName,
                        inputPreview: Self.mobileGatewayArgumentsPreview(call.arguments),
                        sessionID: runtime.id
                    )
                }
        }
        .sorted { lhs, rhs in
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.id < rhs.id
        }
    }

    var mobileGatewayPendingPatchProposals: [AgentMobileGatewayPatchSnapshot] {
        agentRuntimes.values.flatMap { runtime in
            runtime.patchProposals
                .filter { $0.status == .pending }
                .map { proposal in
                    AgentMobileGatewayPatchSnapshot(
                        id: proposal.id,
                        title: proposal.title,
                        summary: "Patch proposal",
                        path: Self.mobileGatewayPatchPath(from: proposal.diff),
                        stats: Self.mobileGatewayPatchStats(from: proposal.diff),
                        sessionID: runtime.id
                    )
                }
        }
        .sorted { lhs, rhs in
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var mobileGatewayJobs: [AgentMobileGatewayJobSnapshot] {
        agentRuntimes.values.flatMap { runtime in
            agentJobRegistry.jobs(forRuntime: runtime.id).map { job in
                AgentMobileGatewayJobSnapshot(
                    id: job.id,
                    handle: job.displayHandle,
                    command: Self.mobileGatewayTruncated(job.command),
                    status: job.status.rawValue,
                    isAlive: job.isAlive,
                    pid: job.pid,
                    exitCode: job.exitCode,
                    outputByteCount: job.outputByteCount,
                    startedAt: job.startedAt,
                    finishedAt: job.finishedAt,
                    sessionID: runtime.id
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.sessionID != rhs.sessionID {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

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

    func mobileGatewayDecideTool(
        sessionID: UUID?,
        toolID: String,
        approved: Bool,
        typedConfirmation: String?,
        answer: String?
    ) throws -> AgentMobileGatewayCommandResult {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        guard let index = runtime.toolCalls.firstIndex(where: { call in
            call.id.uuidString == toolID || call.externalID == toolID
        }) else {
            throw AgentMobileGatewayCommandError.toolNotFound(toolID)
        }
        let call = runtime.toolCalls[index]
        guard call.status == .pendingApproval || call.status == .awaitingConfirm || call.status == .awaitingUserAnswer else {
            throw AgentMobileGatewayCommandError.toolNotPending(toolID)
        }

        let decision: AgentToolDecision
        if approved {
            switch call.status {
            case .awaitingConfirm:
                guard typedConfirmation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "confirm" else {
                    throw AgentMobileGatewayCommandError.confirmationRequired(toolID)
                }
                decision = .approved
            case .awaitingUserAnswer:
                guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                    throw AgentMobileGatewayCommandError.missingAnswer
                }
                decision = .answered(answer)
            default:
                decision = .approved
            }
        } else {
            decision = .denied(reason: "Denied from Android")
            runtime.toolCalls[index].status = .denied
            runtime.toolCalls[index].errorMessage = "Denied from Android"
        }

        runtime.toolDecisionWaiter?.resume(returning: decision)
        runtime.toolDecisionWaiter = nil
        return .ok(sessionID: runtime.id, message: approved ? "Tool approved" : "Tool rejected")
    }

    func mobileGatewayDecidePatch(
        sessionID: UUID?,
        patchID: UUID,
        approved: Bool
    ) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        }
        guard agentPatchProposals.contains(where: { $0.id == patchID && $0.status == .pending }) else {
            throw AgentMobileGatewayCommandError.patchNotFound(patchID)
        }
        if approved {
            applyAgentPatchProposal(id: patchID)
        } else {
            rejectAgentPatchProposal(id: patchID)
        }
        return .ok(sessionID: activeAgentSessionID, message: approved ? "Patch approved" : "Patch rejected")
    }

    func mobileGatewayDiff(
        sessionID: UUID?,
        patchID: UUID
    ) throws -> AgentMobileGatewayDiffSnapshot {
        let runtime: AgentRuntime
        if let sessionID {
            runtime = try mobileGatewayRuntime(sessionID: sessionID)
        } else if let found = agentRuntimes.values.first(where: { runtime in
            runtime.patchProposals.contains(where: { $0.id == patchID })
        }) {
            runtime = found
        } else {
            throw AgentMobileGatewayCommandError.patchNotFound(patchID)
        }

        guard let proposal = runtime.patchProposals.first(where: { $0.id == patchID && $0.status == .pending }) else {
            throw AgentMobileGatewayCommandError.patchNotFound(patchID)
        }
        return AgentMobileGatewayDiffSnapshot(
            patchID: proposal.id,
            title: proposal.title,
            diff: proposal.diff,
            sessionID: runtime.id
        )
    }

    func mobileGatewayKillJob(
        sessionID: UUID?,
        jobID: String
    ) throws -> AgentMobileGatewayCommandResult {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        guard let job = agentJobRegistry.job(matchingHandle: jobID, runtimeID: runtime.id) else {
            throw AgentMobileGatewayCommandError.jobNotFound(jobID)
        }
        let didSignal = agentJobRegistry.kill(id: job.id)
        return .ok(
            sessionID: runtime.id,
            message: didSignal ? "Job killed" : "Job was not running"
        )
    }

    private func mobileGatewayRuntime(sessionID: UUID?) throws -> AgentRuntime {
        if let sessionID {
            guard let runtime = runtime(for: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
            return runtime
        }
        guard let runtime = activeRuntime else {
            throw AgentMobileGatewayCommandError.invalidSessionID("")
        }
        return runtime
    }

    private func mobileGatewayToolTitle(for call: AgentToolCall) -> String {
        switch call.status {
        case .awaitingConfirm:
            return "\(call.toolName) requires confirmation"
        case .awaitingUserAnswer:
            return call.toolName == "ask_user" ? "Agent asks a question" : call.toolName
        default:
            return call.toolName
        }
    }

    private func mobileGatewayToolSummary(for call: AgentToolCall) -> String {
        switch call.status {
        case .pendingApproval:
            return "Waiting for approval"
        case .awaitingConfirm:
            return "Danger-tier tool requires typed confirmation on the Mac protocol."
        case .awaitingUserAnswer:
            return "Waiting for your answer"
        default:
            return ""
        }
    }

    private static func mobileGatewayArgumentsPreview(_ arguments: [String: AgentJSONValue]) -> String {
        guard !arguments.isEmpty else { return "" }
        let object = arguments.mapValues(\.rawAny)
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return mobileGatewayTruncated(text)
        }
        return mobileGatewayTruncated(arguments.map { "\($0.key): \($0.value.displaySummary)" }.sorted().joined(separator: ", "))
    }

    private static func mobileGatewayPatchPath(from diff: String) -> String {
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+++ b/") {
                return String(line.dropFirst(6))
            }
            if line.hasPrefix("--- a/") {
                return String(line.dropFirst(6))
            }
        }
        return ""
    }

    private static func mobileGatewayPatchStats(from diff: String) -> String {
        var added = 0
        var deleted = 0
        for line in diff.split(separator: "\n") {
            guard !line.hasPrefix("+++") && !line.hasPrefix("---") else { continue }
            if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                deleted += 1
            }
        }
        return "+\(added) -\(deleted)"
    }

    private static func mobileGatewayTruncated(_ text: String, limit: Int = 300) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

private extension ISO8601DateFormatter {
    static let agentMobileGatewayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
