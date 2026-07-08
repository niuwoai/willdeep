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

import Foundation

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
                let rawWorkspacePath = envelope.payload["workspace_path"]?.stringValue
                let resolvedWorkspacePath: String?
                if let raw = rawWorkspacePath?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    resolvedWorkspacePath = try controller.mobileGatewayValidateWorkspacePath(raw)
                } else if rawWorkspacePath != nil {
                    throw AgentMobileGatewayCommandError.missingWorkspacePath
                } else {
                    resolvedWorkspacePath = nil
                }
                let session = controller.mobileGatewayStartSession(
                    workspacePath: resolvedWorkspacePath
                )
                return sessionEnvelope(
                    type: "session.upsert",
                    id: envelope.id,
                    session: session,
                    isActive: controller.mobileGatewayActiveSessionID == session.id,
                    isResponding: controller.mobileGatewayRuntimeIsResponding(sessionID: session.id),
                    now: now
                )
            case "workspace.list":
                return workspaceListEnvelope(
                    id: envelope.id,
                    controller: controller,
                    now: now
                )
            case "capabilities.get":
                return capabilitiesEnvelope(
                    id: envelope.id,
                    controller: controller,
                    now: now
                )
            case "push.register":
                let provider = try requiredPayloadString("provider", from: envelope)
                let clientID = try requiredPayloadString("client_id", aliases: ["device_token", "token", "cid"], from: envelope)
                let appID = envelope.payload["app_id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                MobileRemotePushNotifier.shared.register(provider: provider, clientID: clientID, appID: appID)
                return ackEnvelope(
                    for: envelope,
                    sessionID: try optionalSessionID(from: envelope),
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
                let images = try imageAttachments(from: envelope)
                guard !text.isEmpty || !images.isEmpty else { throw AgentMobileGatewayCommandError.missingText }
                let result = try controller.mobileGatewaySendMessage(
                    sessionID: try optionalSessionID(from: envelope),
                    text: text,
                    images: images,
                    workspacePath: envelope.payload["workspace_path"]?.stringValue,
                    providerID: envelope.payload["provider_id"]?.stringValue,
                    modelID: envelope.payload["model"]?.stringValue ?? envelope.payload["model_id"]?.stringValue,
                    approvalModeID: envelope.payload["approval_mode"]?.stringValue,
                    skillIDs: stringArrayPayload("skills", from: envelope),
                    expertIDs: stringArrayPayload("experts", from: envelope),
                    pluginIDs: stringArrayPayload("plugins", from: envelope)
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
                    text: envelope.payload["text"]?.stringValue,
                    images: try imageAttachments(from: envelope)
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

    static func workspaceListEnvelope(
        id: String? = nil,
        controller: AgentMobileGatewayControlling,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        let workspaces = controller.mobileGatewayWorkspaceList.map(workspaceJSON)
        return AgentMobileGatewayEnvelope(
            id: id,
            type: "workspace.list",
            payload: ["workspaces": .array(workspaces)],
            timestamp: isoTimestamp(now)
        )
    }

    static func capabilitiesEnvelope(
        id: String? = nil,
        controller: AgentMobileGatewayControlling,
        now: Date = Date()
    ) -> AgentMobileGatewayEnvelope {
        let capabilities = controller.mobileGatewayCapabilities
        var payload: [String: AgentMobileGatewayJSON] = [
            "providers": .array(capabilities.providers.map(capabilityOptionJSON)),
            "models": .array(capabilities.models.map(capabilityOptionJSON)),
            "skills": .array(capabilities.skills.map(capabilityOptionJSON)),
            "experts": .array(capabilities.experts.map(capabilityOptionJSON)),
            "plugins": .array(capabilities.plugins.map(capabilityOptionJSON))
        ]
        if let activeProviderID = capabilities.activeProviderID {
            payload["active_provider_id"] = .string(activeProviderID)
        }
        if let activeModelID = capabilities.activeModelID {
            payload["active_model_id"] = .string(activeModelID)
        }
        return AgentMobileGatewayEnvelope(
            id: id,
            type: "capabilities.updated",
            payload: payload,
            timestamp: isoTimestamp(now)
        )
    }

    private static func capabilityOptionJSON(
        _ option: AgentMobileGatewayCapabilityOptionSnapshot
    ) -> AgentMobileGatewayJSON {
        var fields: [String: AgentMobileGatewayJSON] = [
            "id": .string(option.id),
            "title": .string(option.title),
            "is_active": .bool(option.isActive)
        ]
        if let subtitle = option.subtitle, !subtitle.isEmpty {
            fields["subtitle"] = .string(subtitle)
        }
        return .object(fields)
    }

    private static func workspaceJSON(_ workspace: AgentMobileGatewayWorkspaceSnapshot) -> AgentMobileGatewayJSON {
        var fields: [String: AgentMobileGatewayJSON] = [
            "path": .string(workspace.path),
            "name": .string(workspace.name),
            "session_count": .int(workspace.sessionCount),
            "is_current": .bool(workspace.isCurrent),
            "is_git_repo": .bool(workspace.isGitRepo)
        ]
        if let lastUsedAt = workspace.lastUsedAt {
            fields["last_used_at"] = .string(isoTimestamp(lastUsedAt))
        }
        if let root = workspace.repositoryRoot {
            fields["repository_root"] = .string(root)
        }
        return .object(fields)
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

    private static func stringArrayPayload(
        _ key: String,
        from envelope: AgentMobileGatewayEnvelope
    ) -> [String] {
        guard case .array(let values)? = envelope.payload[key] else { return [] }
        return values.compactMap { value in
            value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func imageAttachments(from envelope: AgentMobileGatewayEnvelope) throws -> [AgentImageAttachment] {
        guard case .array(let values)? = envelope.payload["images"] else { return [] }
        return try values.compactMap { value in
            guard let dataURL = imageDataURL(from: value) else { return nil }
            return try imageAttachment(fromDataURL: dataURL)
        }
    }

    private static func imageDataURL(from value: AgentMobileGatewayJSON) -> String? {
        if let raw = value.stringValue {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard case .object(let object) = value else { return nil }
        if let raw = object["url"]?.stringValue ?? object["image_url"]?.stringValue {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if case .object(let nested)? = object["image_url"],
           let raw = nested["url"]?.stringValue {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func imageAttachment(fromDataURL dataURL: String) throws -> AgentImageAttachment {
        guard dataURL.hasPrefix("data:") else {
            throw AgentMobileGatewayCommandError.invalidImagePayload("only data URLs are supported")
        }
        guard let comma = dataURL.firstIndex(of: ",") else {
            throw AgentMobileGatewayCommandError.invalidImagePayload("missing data URL payload")
        }
        let metadata = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let dataBase64 = String(dataURL[dataURL.index(after: comma)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = metadata.split(separator: ";").map(String.init)
        let mimeType = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard mimeType.hasPrefix("image/") else {
            throw AgentMobileGatewayCommandError.invalidImagePayload("mime type must be image/*")
        }
        guard parts.contains(where: { $0.lowercased() == "base64" }) else {
            throw AgentMobileGatewayCommandError.invalidImagePayload("image data URL must be base64")
        }
        guard !dataBase64.isEmpty,
              Data(base64Encoded: dataBase64, options: [.ignoreUnknownCharacters]) != nil else {
            throw AgentMobileGatewayCommandError.invalidImagePayload("base64 image data is invalid")
        }
        return AgentImageAttachment(mimeType: mimeType, dataBase64: dataBase64)
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

private extension ISO8601DateFormatter {
    static let agentMobileGatewayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
