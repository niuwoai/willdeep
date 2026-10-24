//
//  AgentMobileGatewayModels.swift
//  WillDeep
//
//  Created by Codex on 2026/6/16.
//

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
    /// Stable review-group identity. Legacy test/fake snapshots may omit it,
    /// but every live desktop proposal publishes its assistant message id.
    var batchID: UUID? = nil
    var batchCount: Int = 1
    var batchCollecting: Bool = false
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
    var text: String? = nil
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

struct AgentMobileGatewayWorkspaceSnapshot: Equatable {
    var path: String
    var name: String
    var lastUsedAt: Date?
    var sessionCount: Int
    var isCurrent: Bool
    var isGitRepo: Bool
    var repositoryRoot: String?
}

struct AgentMobileGatewayCapabilityOptionSnapshot: Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var isActive: Bool
}

struct AgentMobileGatewayCapabilitiesSnapshot: Equatable {
    var providers: [AgentMobileGatewayCapabilityOptionSnapshot]
    var models: [AgentMobileGatewayCapabilityOptionSnapshot]
    var skills: [AgentMobileGatewayCapabilityOptionSnapshot]
    var experts: [AgentMobileGatewayCapabilityOptionSnapshot]
    var plugins: [AgentMobileGatewayCapabilityOptionSnapshot]
    var activeProviderID: String?
    var activeModelID: String?
    var activeApprovalMode: String? = nil
    var supportsConfiguration: Bool = false
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
    func mobileGatewayStartSession(workspacePath: String?) -> AgentSession
    func mobileGatewaySelectSession(id: UUID) -> Bool
    func mobileGatewaySendMessage(
        sessionID: UUID?,
        text: String,
        images: [AgentImageAttachment],
        workspacePath: String?,
        providerID: String?,
        modelID: String?,
        approvalModeID: String?,
        skillIDs: [String],
        expertIDs: [String],
        pluginIDs: [String]
    ) throws -> AgentMobileGatewayCommandResult
    func mobileGatewayConfigure(sessionID: UUID?, patch: [String: AgentMobileGatewayJSON]) throws -> AgentMobileGatewayCommandResult
    func mobileGatewayStopTurn(sessionID: UUID?) throws -> AgentMobileGatewayCommandResult
    var mobileGatewayWorkspaceList: [AgentMobileGatewayWorkspaceSnapshot] { get }
    var mobileGatewayCapabilities: AgentMobileGatewayCapabilitiesSnapshot { get }
    func mobileGatewayValidateWorkspacePath(_ rawPath: String) throws -> String
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
        text: String?,
        images: [AgentImageAttachment]
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
    case patchBatchCollecting(UUID)
    case patchApplyFailed(UUID, String)
    case jobNotFound(String)
    case queueMessageNotFound(UUID)
    case queueMessageChanged
    case noWorkspace
    case workspaceUnavailable(String)
    case pathOutsideWorkspace(String)
    case fileNotFound(String)
    case notRegularFile(String)
    case binaryFile(String)
    case unsupportedCommand(String)
    case missingWorkspacePath
    case workspacePathNotFound(String)
    case workspacePathNotDirectory(String)
    case workspacePathForbidden(String)
    case invalidImagePayload(String)

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
        case .patchBatchCollecting(let id):
            return "Patch batch is still collecting changes: \(id.uuidString). Retry after the review group is complete."
        case .patchApplyFailed(let id, let message):
            return "Patch batch \(id.uuidString) failed to apply: \(message)"
        case .jobNotFound(let id):
            return "Background job not found: \(id)."
        case .queueMessageNotFound(let id):
            return "Queued message not found: \(id.uuidString)."
        case .queueMessageChanged:
            return "Queued message changed or started; refresh before editing."
        case .noWorkspace:
            return "No local workspace is available for this session."
        case .workspaceUnavailable(let message):
            return message
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
        case .missingWorkspacePath:
            return "session.create requires payload.workspace_path."
        case .workspacePathNotFound(let path):
            return "Workspace path does not exist: \(path)."
        case .workspacePathNotDirectory(let path):
            return "Workspace path is not a directory: \(path)."
        case .workspacePathForbidden(let path):
            return "Workspace path is not allowed: \(path)."
        case .invalidImagePayload(let reason):
            return "Invalid mobile image payload: \(reason)."
        }
    }
}

extension AgentMobileGatewayControlling {
    func mobileGatewayConfigure(sessionID: UUID?, patch: [String: AgentMobileGatewayJSON]) throws -> AgentMobileGatewayCommandResult {
        throw AgentMobileGatewayCommandError.invalidAction("configuration unavailable")
    }
}
