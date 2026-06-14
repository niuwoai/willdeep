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

    var intValue: Int? {
        if case .int(let value) = self { return value }
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
    var requiresConfirmation: Bool = false
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

struct AgentMobileGatewayFileSnapshot: Equatable {
    var path: String
    var content: String
    var truncated: Bool
    var byteCount: Int
    var sessionID: UUID
}

struct AgentMobileGatewayQueuedMessageSnapshot: Equatable {
    var id: UUID
    var textPreview: String
    var imageCount: Int
    var textAttachmentCount: Int
    var sessionID: UUID
}

struct AgentMobileGatewayMessageSnapshot: Equatable {
    var id: UUID
    var role: String
    var content: String
    var createdAt: Date
    var sessionID: UUID
}

struct AgentMobileGatewayMessageEventState {
    private var contentByMessageID: [UUID: String] = [:]
    private var doneMessageIDs: Set<UUID> = []

    mutating func reset() {
        contentByMessageID.removeAll()
        doneMessageIDs.removeAll()
    }

    mutating func envelopes(
        for messages: [AgentMobileGatewayMessageSnapshot],
        respondingSessionIDs: Set<UUID>,
        now: Date = Date()
    ) -> [AgentMobileGatewayEnvelope] {
        var envelopes: [AgentMobileGatewayEnvelope] = []
        let orderedMessages = messages.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let liveIDs = Set(orderedMessages.map(\.id))
        contentByMessageID = contentByMessageID.filter { liveIDs.contains($0.key) }
        doneMessageIDs = doneMessageIDs.intersection(liveIDs)

        for message in orderedMessages {
            let previous = contentByMessageID[message.id]
            let content = message.content
            guard !content.isEmpty else { continue }

            if let previous {
                if content != previous {
                    doneMessageIDs.remove(message.id)
                    if content.hasPrefix(previous) {
                        let delta = String(content.dropFirst(previous.count))
                        if !delta.isEmpty {
                            envelopes.append(
                                AgentMobileGatewayCommandRouter.messageDeltaEnvelope(
                                    messageID: message.id,
                                    sessionID: message.sessionID,
                                    delta: delta,
                                    now: now
                                )
                            )
                        }
                    } else {
                        envelopes.append(
                            AgentMobileGatewayCommandRouter.messageAppendEnvelope(message, now: now)
                        )
                    }
                    contentByMessageID[message.id] = content
                }
            } else {
                envelopes.append(AgentMobileGatewayCommandRouter.messageAppendEnvelope(message, now: now))
                contentByMessageID[message.id] = content
            }

            if message.role == AgentRole.assistant.rawValue,
               !respondingSessionIDs.contains(message.sessionID),
               !doneMessageIDs.contains(message.id) {
                envelopes.append(
                    AgentMobileGatewayCommandRouter.messageDoneEnvelope(
                        messageID: message.id,
                        sessionID: message.sessionID,
                        now: now
                    )
                )
                doneMessageIDs.insert(message.id)
            }
        }

        return envelopes
    }
}

struct AgentMobileGatewayWorktreeFileSnapshot: Equatable {
    var path: String
    var kind: String
    var addedLines: Int
    var deletedLines: Int
}

struct AgentMobileGatewayWorktreeSnapshot: Equatable {
    var repositoryRoot: String?
    var fileCount: Int
    var totalAddedLines: Int
    var totalDeletedLines: Int
    var files: [AgentMobileGatewayWorktreeFileSnapshot]
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
    func mobileGatewayReadFile(
        sessionID: UUID?,
        path: String,
        maxBytes: Int?
    ) throws -> AgentMobileGatewayFileSnapshot
    var mobileGatewayQueuedMessages: [AgentMobileGatewayQueuedMessageSnapshot] { get }
    var mobileGatewayRecentMessages: [AgentMobileGatewayMessageSnapshot] { get }
    var mobileGatewayWorktreeChanges: [AgentMobileGatewayWorktreeSnapshot] { get }
    func mobileGatewayUpdateQueue(
        sessionID: UUID?,
        action: String,
        messageID: UUID?,
        text: String?
    ) throws -> AgentMobileGatewayCommandResult
}

enum AgentMobileGatewayCommandError: LocalizedError, Equatable {
    case missingText
    case missingID(String)
    case missingAction(String)
    case missingPath(String)
    case missingAnswer
    case invalidAction(String)
    case invalidDecision
    case invalidSessionID(String)
    case sessionNotFound(UUID)
    case toolNotFound(String)
    case toolNotPending(String)
    case confirmationRequired(String)
    case invalidPatchID(String)
    case patchNotFound(UUID)
    case jobNotFound(String)
    case queueMessageNotFound(UUID)
    case noWorkspace
    case pathOutsideWorkspace(String)
    case fileNotFound(String)
    case notRegularFile(String)
    case binaryFile(String)
    case unsupportedCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingText:
            return "message.send requires payload.text."
        case .missingID(let type):
            return "\(type) requires payload.id."
        case .missingAction(let type):
            return "\(type) requires payload.action."
        case .missingPath(let type):
            return "\(type) requires payload.path."
        case .missingAnswer:
            return "ask_user decisions require payload.answer."
        case .invalidAction(let value):
            return "Unsupported queue action: \(value)."
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
        case .queueMessageNotFound(let id):
            return "Queued message not found: \(id.uuidString)."
        case .noWorkspace:
            return "No local workspace is available for this session."
        case .pathOutsideWorkspace(let path):
            return "Path is outside the session workspace: \(path)."
        case .fileNotFound(let path):
            return "File not found: \(path)."
        case .notRegularFile(let path):
            return "Path is not a regular file: \(path)."
        case .binaryFile(let path):
            return "Refusing to read binary file: \(path)."
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
            case "file.read":
                let path = try requiredPayloadPath(from: envelope)
                let maxBytes = envelope.payload["max_bytes"]?.intValue
                let file = try controller.mobileGatewayReadFile(
                    sessionID: try optionalSessionID(from: envelope),
                    path: path,
                    maxBytes: maxBytes
                )
                return fileAckEnvelope(
                    for: envelope,
                    file: file,
                    now: now
                )
            case "queue.update":
                let action = try requiredPayloadAction(from: envelope)
                let messageID = try optionalPayloadUUID("id", aliases: ["message_id", "queued_id"], from: envelope)
                let result = try controller.mobileGatewayUpdateQueue(
                    sessionID: try optionalSessionID(from: envelope),
                    action: action,
                    messageID: messageID,
                    text: envelope.payload["text"]?.stringValue
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
                "jobs": .array(controller.mobileGatewayJobs.map(jobJSON)),
                "queued_messages": .array(controller.mobileGatewayQueuedMessages.map(queuedMessageJSON)),
                "messages": .array(controller.mobileGatewayRecentMessages.map(messageJSON)),
                "worktree_changes": .array(controller.mobileGatewayWorktreeChanges.map(worktreeJSON))
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

    static func worktreeUpdatedEnvelope(
        _ worktree: AgentMobileGatewayWorktreeSnapshot,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            type: "worktree.updated",
            sessionID: worktree.sessionID.uuidString,
            payload: worktreePayload(worktree),
            timestamp: isoTimestamp(now)
        )
    }

    static func messageAppendEnvelope(
        _ message: AgentMobileGatewayMessageSnapshot,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            type: "message.append",
            sessionID: message.sessionID.uuidString,
            payload: messagePayload(message),
            timestamp: isoTimestamp(now)
        )
    }

    static func messageDeltaEnvelope(
        messageID: UUID,
        sessionID: UUID,
        delta: String,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            type: "message.delta",
            sessionID: sessionID.uuidString,
            payload: [
                "message_id": .string(messageID.uuidString),
                "delta": .string(delta)
            ],
            timestamp: isoTimestamp(now)
        )
    }

    static func messageDoneEnvelope(
        messageID: UUID,
        sessionID: UUID,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            type: "message.done",
            sessionID: sessionID.uuidString,
            payload: ["message_id": .string(messageID.uuidString)],
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

    private static func fileAckEnvelope(
        for envelope: AgentMobileGatewayEnvelope,
        file: AgentMobileGatewayFileSnapshot,
        now: Date
    ) -> AgentMobileGatewayEnvelope {
        AgentMobileGatewayEnvelope(
            id: envelope.id,
            type: "ack",
            sessionID: file.sessionID.uuidString,
            payload: [
                "type": .string(envelope.type),
                "path": .string(file.path),
                "content": .string(file.content),
                "truncated": .bool(file.truncated),
                "byte_count": .int(file.byteCount)
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
            "requires_confirmation": .bool(approval.requiresConfirmation),
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

    private static func queuedMessageJSON(_ message: AgentMobileGatewayQueuedMessageSnapshot) -> AgentMobileGatewayJSON {
        .object([
            "id": .string(message.id.uuidString),
            "text_preview": .string(message.textPreview),
            "image_count": .int(message.imageCount),
            "text_attachment_count": .int(message.textAttachmentCount),
            "session_id": .string(message.sessionID.uuidString)
        ])
    }

    private static func messageJSON(_ message: AgentMobileGatewayMessageSnapshot) -> AgentMobileGatewayJSON {
        .object(messagePayload(message))
    }

    private static func messagePayload(_ message: AgentMobileGatewayMessageSnapshot) -> [String: AgentMobileGatewayJSON] {
        [
            "id": .string(message.id.uuidString),
            "role": .string(message.role),
            "content": .string(message.content),
            "created_at": .string(isoTimestamp(message.createdAt)),
            "session_id": .string(message.sessionID.uuidString)
        ]
    }

    private static func worktreeJSON(_ worktree: AgentMobileGatewayWorktreeSnapshot) -> AgentMobileGatewayJSON {
        .object(worktreePayload(worktree))
    }

    private static func worktreePayload(_ worktree: AgentMobileGatewayWorktreeSnapshot) -> [String: AgentMobileGatewayJSON] {
        [
            "repository_root": worktree.repositoryRoot.map { .string($0) } ?? .null,
            "file_count": .int(worktree.fileCount),
            "total_added_lines": .int(worktree.totalAddedLines),
            "total_deleted_lines": .int(worktree.totalDeletedLines),
            "session_id": .string(worktree.sessionID.uuidString),
            "files": .array(worktree.files.map { file in
                .object([
                    "path": .string(file.path),
                    "kind": .string(file.kind),
                    "added_lines": .int(file.addedLines),
                    "deleted_lines": .int(file.deletedLines)
                ])
            })
        ]
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

    private static func requiredPayloadPath(from envelope: AgentMobileGatewayEnvelope) throws -> String {
        for candidate in ["path", "file", "file_path"] {
            if let value = envelope.payload[candidate]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        throw AgentMobileGatewayCommandError.missingPath(envelope.type)
    }

    private static func requiredPayloadAction(from envelope: AgentMobileGatewayEnvelope) throws -> String {
        if let value = envelope.payload["action"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !value.isEmpty {
            return value
        }
        throw AgentMobileGatewayCommandError.missingAction(envelope.type)
    }

    private static func optionalPayloadUUID(
        _ key: String,
        aliases: [String] = [],
        from envelope: AgentMobileGatewayEnvelope
    ) throws -> UUID? {
        let raw = try? requiredPayloadString(key, aliases: aliases, from: envelope)
        guard let raw else { return nil }
        guard let id = UUID(uuidString: raw) else {
            throw AgentMobileGatewayCommandError.missingID(envelope.type)
        }
        return id
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
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBaseURL: URL?
    private var reconnectDesktopToken: String?
    private var reconnectSession: URLSession = .shared
    private var shouldReconnect = false
    private var appStateCancellable: AnyCancellable?
    private var snapshotTask: Task<Void, Never>?
    private var messageEventState = AgentMobileGatewayMessageEventState()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(appState: AppState) {
        self.appState = appState
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.appStateCancellable = appState.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSnapshot()
            }
        }
    }

    func connect(baseURL: URL, desktopToken: String, session: URLSession = .shared) {
        disconnect()
        shouldReconnect = true
        reconnectBaseURL = baseURL
        reconnectDesktopToken = desktopToken
        reconnectSession = session
        open(baseURL: baseURL, desktopToken: desktopToken, session: session)
    }

    private func open(baseURL: URL, desktopToken: String, session: URLSession) {
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
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        messageEventState.reset()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        reconnectBaseURL = nil
        reconnectDesktopToken = nil
        reconnectSession = .shared
    }

    func publishSnapshot() {
        guard let appState else { return }
        let respondingSessionIDs = Set(
            appState.mobileGatewaySessions
                .filter { appState.mobileGatewayRuntimeIsResponding(sessionID: $0.id) }
                .map(\.id)
        )
        for event in messageEventState.envelopes(
            for: appState.mobileGatewayRecentMessages,
            respondingSessionIDs: respondingSessionIDs
        ) {
            send(event)
        }
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
        for worktree in appState.mobileGatewayWorktreeChanges {
            send(AgentMobileGatewayCommandRouter.worktreeUpdatedEnvelope(worktree))
        }
    }

    private func scheduleSnapshot() {
        guard isConnected, webSocketTask != nil else { return }
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.publishSnapshot()
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
                    self.scheduleReconnect()
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
                    self?.webSocketTask = nil
                    self?.scheduleReconnect()
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect,
              reconnectTask == nil,
              let baseURL = reconnectBaseURL,
              let desktopToken = reconnectDesktopToken else {
            return
        }
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, !Task.isCancelled, self.shouldReconnect else { return }
            self.reconnectTask = nil
            self.open(baseURL: baseURL, desktopToken: desktopToken, session: self.reconnectSession)
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
                        requiresConfirmation: call.status == .awaitingConfirm,
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

    var mobileGatewayQueuedMessages: [AgentMobileGatewayQueuedMessageSnapshot] {
        agentSessions.compactMap { runtime(for: $0.id) }.flatMap { runtime in
            runtime.queuedMessages.map { message in
                AgentMobileGatewayQueuedMessageSnapshot(
                    id: message.id,
                    textPreview: Self.mobileGatewayQueuedTextPreview(message),
                    imageCount: message.images.count,
                    textAttachmentCount: message.textAttachments.count,
                    sessionID: runtime.id
                )
            }
        }
    }

    var mobileGatewayRecentMessages: [AgentMobileGatewayMessageSnapshot] {
        agentSessions.compactMap { runtime(for: $0.id) }.flatMap { runtime in
            runtime.messages
                .filter { message in
                    message.role == .user ||
                    message.role == .assistant ||
                    message.role == .system
                }
                .suffix(Self.mobileGatewayMaxRecentMessagesPerSession)
                .map { message in
                    AgentMobileGatewayMessageSnapshot(
                        id: message.id,
                        role: message.role.rawValue,
                        content: Self.mobileGatewayMessageContentPreview(message),
                        createdAt: message.createdAt,
                        sessionID: runtime.id
                    )
                }
        }
    }

    var mobileGatewayWorktreeChanges: [AgentMobileGatewayWorktreeSnapshot] {
        agentSessions.compactMap { runtime(for: $0.id) }.compactMap { runtime in
            let changes = runtime.worktreeChanges
            guard !changes.isEmpty else { return nil }
            return AgentMobileGatewayWorktreeSnapshot(
                repositoryRoot: changes.repositoryRoot?.standardizedFileURL.path,
                fileCount: changes.fileCount,
                totalAddedLines: changes.totalAddedLines,
                totalDeletedLines: changes.totalDeletedLines,
                files: changes.files.map { file in
                    AgentMobileGatewayWorktreeFileSnapshot(
                        path: file.path,
                        kind: file.kind.rawValue,
                        addedLines: file.addedLines,
                        deletedLines: file.deletedLines
                    )
                },
                sessionID: runtime.id
            )
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

    func mobileGatewayReadFile(
        sessionID: UUID?,
        path: String,
        maxBytes: Int?
    ) throws -> AgentMobileGatewayFileSnapshot {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        guard let workspaceRootPath = runtime.workspaceRootPath, !workspaceRootPath.isEmpty else {
            throw AgentMobileGatewayCommandError.noWorkspace
        }
        let root = URL(fileURLWithPath: workspaceRootPath).standardizedFileURL
        let rootPath = root.path
        let requestedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetURL: URL
        if (requestedPath as NSString).isAbsolutePath {
            targetURL = URL(fileURLWithPath: requestedPath).standardizedFileURL
        } else {
            targetURL = root.appendingPathComponent(requestedPath).standardizedFileURL
        }
        let targetPath = targetURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw AgentMobileGatewayCommandError.pathOutsideWorkspace(path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory) else {
            throw AgentMobileGatewayCommandError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw AgentMobileGatewayCommandError.notRegularFile(path)
        }
        guard !Self.isBinaryFile(at: targetURL) else {
            throw AgentMobileGatewayCommandError.binaryFile(path)
        }

        let limit = max(1, min(maxBytes ?? Self.mobileGatewayDefaultReadBytes, Self.mobileGatewayAbsoluteMaxReadBytes))
        let handle = try FileHandle(forReadingFrom: targetURL)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit + 1)
        let truncated = data.count > limit
        let usable = truncated ? Data(data.prefix(limit)) : data
        let content = String(data: usable, encoding: .utf8) ?? Self.decodeText(from: usable)
        return AgentMobileGatewayFileSnapshot(
            path: Self.mobileGatewayRelativePath(for: targetURL, rootPath: rootPath),
            content: content,
            truncated: truncated,
            byteCount: usable.count,
            sessionID: runtime.id
        )
    }

    func mobileGatewayUpdateQueue(
        sessionID: UUID?,
        action: String,
        messageID: UUID?,
        text: String?
    ) throws -> AgentMobileGatewayCommandResult {
        let runtime = try mobileGatewayRuntime(sessionID: sessionID)
        let normalizedAction = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch normalizedAction {
        case "add":
            let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else {
                throw AgentMobileGatewayCommandError.missingText
            }
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt))
            return .ok(sessionID: runtime.id, message: "Queued message added")

        case "clear":
            runtime.queuedMessages.removeAll()
            runtime.shouldConsumeQueueAfterStop = false
            return .ok(sessionID: runtime.id, message: "Queue cleared")

        case "remove", "delete":
            guard let messageID else {
                throw AgentMobileGatewayCommandError.missingID("queue.update")
            }
            guard let index = runtime.queuedMessages.firstIndex(where: { $0.id == messageID }) else {
                throw AgentMobileGatewayCommandError.queueMessageNotFound(messageID)
            }
            runtime.queuedMessages.remove(at: index)
            if runtime.queuedMessages.isEmpty {
                runtime.shouldConsumeQueueAfterStop = false
            }
            return .ok(sessionID: runtime.id, message: "Queued message removed")

        case "send_now":
            guard let messageID else {
                throw AgentMobileGatewayCommandError.missingID("queue.update")
            }
            guard let index = runtime.queuedMessages.firstIndex(where: { $0.id == messageID }) else {
                throw AgentMobileGatewayCommandError.queueMessageNotFound(messageID)
            }
            let message = runtime.queuedMessages.remove(at: index)
            runtime.queuedMessages.insert(message, at: 0)
            if activeAgentSessionID != runtime.id {
                selectAgentSession(id: runtime.id)
            }
            sendQueuedAgentMessageNow(id: messageID)
            return .ok(sessionID: runtime.id, message: "Queued message sent")

        default:
            throw AgentMobileGatewayCommandError.invalidAction(action)
        }
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

    private static func mobileGatewayQueuedTextPreview(_ message: AgentQueuedMessage) -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return mobileGatewayTruncated(trimmed)
        }
        if !message.textAttachments.isEmpty {
            return "\(message.textAttachments.count) text attachments"
        }
        if !message.images.isEmpty {
            return "\(message.images.count) images"
        }
        return "Queued message"
    }

    private static let mobileGatewayMaxRecentMessagesPerSession = 40
    private static let mobileGatewayMaxMessageCharacters = 12_000

    private static func mobileGatewayMessageContentPreview(_ message: AgentMessage) -> String {
        var blocks: [String] = []
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(trimmed)
        }
        if message.role == .user {
            if !message.images.isEmpty {
                blocks.append("[\(message.images.count) images]")
            }
            if !message.textAttachments.isEmpty {
                let names = message.textAttachments
                    .map(\.displayName)
                    .prefix(3)
                    .joined(separator: ", ")
                blocks.append("[attachments: \(names)]")
            }
        }
        let joined = blocks.joined(separator: "\n\n")
        if joined.count <= mobileGatewayMaxMessageCharacters {
            return joined
        }
        return String(joined.prefix(mobileGatewayMaxMessageCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n..."
    }

    private static let mobileGatewayDefaultReadBytes = 64 * 1024
    private static let mobileGatewayAbsoluteMaxReadBytes = 256 * 1024

    private static func mobileGatewayRelativePath(for url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
