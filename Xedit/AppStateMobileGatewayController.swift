//
//  AppStateMobileGatewayController.swift
//  WillDeep
//
//  AppState adapter used by the LAN Mobile Gateway command router.
//

import Foundation

private struct AgentState_MobileGatewayWorkspaceBucket {
    var path: String
    var name: String
    var lastUsedAt: Date?
    var sessionCount: Int
    var isCurrent: Bool
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

    var mobileGatewayWorkspaceList: [AgentMobileGatewayWorkspaceSnapshot] {
        var buckets: [String: AgentState_MobileGatewayWorkspaceBucket] = [:]
        let currentPath = rootDirectory.map { Self.mobileGatewayRealpath($0.path) }

        for session in agentSessions {
            guard case .local(let raw)? = session.workspaceLocation else {
                if let raw = session.workspaceRootPath, !raw.isEmpty {
                    Self.mobileGatewayUpsertWorkspaceBucket(
                        into: &buckets,
                        rawPath: raw,
                        lastUsedAt: session.updatedAt,
                        currentPath: currentPath
                    )
                }
                continue
            }
            guard !raw.isEmpty else { continue }
            Self.mobileGatewayUpsertWorkspaceBucket(
                into: &buckets,
                rawPath: raw,
                lastUsedAt: session.updatedAt,
                currentPath: currentPath
            )
        }
        if let currentPath {
            Self.mobileGatewayUpsertWorkspaceBucket(
                into: &buckets,
                rawPath: currentPath,
                lastUsedAt: nil,
                currentPath: currentPath
            )
        }

        let now = Date()
        let snapshots = buckets.values.map { bucket -> AgentMobileGatewayWorkspaceSnapshot in
            let url = URL(fileURLWithPath: bucket.path)
            return AgentMobileGatewayWorkspaceSnapshot(
                path: bucket.path,
                name: bucket.name,
                lastUsedAt: bucket.lastUsedAt ?? (bucket.isCurrent ? now : nil),
                sessionCount: bucket.sessionCount,
                isCurrent: bucket.isCurrent,
                isGitRepo: Self.mobileGatewayIsGitRepo(url),
                repositoryRoot: Self.mobileGatewayRepositoryRoot(for: url)
            )
        }
        return snapshots.sorted { lhs, rhs in
            let l = lhs.lastUsedAt ?? .distantPast
            let r = rhs.lastUsedAt ?? .distantPast
            if l != r { return l > r }
            return lhs.path < rhs.path
        }
    }

    func mobileGatewayValidateWorkspacePath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentMobileGatewayCommandError.missingWorkspacePath
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = Self.mobileGatewayRealpath(expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw AgentMobileGatewayCommandError.workspacePathNotFound(rawPath)
        }
        guard isDir.boolValue else {
            throw AgentMobileGatewayCommandError.workspacePathNotDirectory(rawPath)
        }
        guard Self.mobileGatewayIsWorkspacePathAllowed(resolved) else {
            throw AgentMobileGatewayCommandError.workspacePathForbidden(rawPath)
        }
        return resolved
    }

    func mobileGatewayStartSession(workspacePath: String?) -> AgentSession {
        startNewAgentSession(inWorkspaceAt: workspacePath)
    }

    private static func mobileGatewayUpsertWorkspaceBucket(
        into buckets: inout [String: AgentState_MobileGatewayWorkspaceBucket],
        rawPath: String,
        lastUsedAt: Date?,
        currentPath: String?
    ) {
        let resolved = mobileGatewayRealpath(rawPath)
        guard !resolved.isEmpty, resolved != "/" else { return }
        guard mobileGatewayIsWorkspacePathAllowed(resolved) else { return }
        let name = (resolved as NSString).lastPathComponent
        let isCurrent = currentPath.map { $0 == resolved } ?? false
        if var existing = buckets[resolved] {
            if let lastUsedAt {
                if let prior = existing.lastUsedAt {
                    if lastUsedAt > prior { existing.lastUsedAt = lastUsedAt }
                } else {
                    existing.lastUsedAt = lastUsedAt
                }
                existing.sessionCount += 1
            }
            if isCurrent { existing.isCurrent = true }
            buckets[resolved] = existing
        } else {
            buckets[resolved] = AgentState_MobileGatewayWorkspaceBucket(
                path: resolved,
                name: name.isEmpty ? resolved : name,
                lastUsedAt: lastUsedAt,
                sessionCount: lastUsedAt == nil ? 0 : 1,
                isCurrent: isCurrent
            )
        }
    }

    private static func mobileGatewayRealpath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func mobileGatewayIsGitRepo(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let gitPath = url.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue || mobileGatewayIsGitFileWorktree(url.appendingPathComponent(".git"))
    }

    private static func mobileGatewayIsGitFileWorktree(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data.prefix(64), encoding: .utf8) else {
            return false
        }
        return text.hasPrefix("gitdir:")
    }

    private static func mobileGatewayRepositoryRoot(for url: URL) -> String? {
        var current = url.standardizedFileURL
        let fm = FileManager.default
        while true {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path, isDirectory: &isDir) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private static func mobileGatewayIsWorkspacePathAllowed(_ resolved: String) -> Bool {
        guard !resolved.isEmpty, resolved != "/" else { return false }
        let forbiddenExact: Set<String> = ["/etc", "/var", "/usr", "/bin", "/sbin", "/private", "/System", "/Library"]
        if forbiddenExact.contains(resolved) { return false }
        let forbiddenPrefixes = ["/etc/", "/private/etc/", "/System/", "/usr/", "/bin/", "/sbin/"]
        for prefix in forbiddenPrefixes where resolved.hasPrefix(prefix) {
            return false
        }
        let home = NSHomeDirectory()
        let userLibrary = (home as NSString).appendingPathComponent("Library")
        if resolved == userLibrary || resolved.hasPrefix(userLibrary + "/") {
            return false
        }
        return true
    }

    func mobileGatewaySelectSession(id: UUID) -> Bool {
        guard agentSessions.contains(where: { $0.id == id }) else { return false }
        selectAgentSession(id: id)
        return true
    }

    func mobileGatewaySendMessage(
        sessionID: UUID?,
        text: String,
        workspacePath: String?
    ) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        } else if let workspacePath, !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
            if let runtime = activeRuntime, runtime.isEmpty, !runtime.isResponding {
                runtime.rebindWorkspace(to: url.path)
            } else if activeRuntime?.workspaceRootPath != url.path || activeRuntime?.isResponding == true {
                _ = startNewAgentSession(inWorkspaceAt: url.path)
            }
        } else if activeRuntime == nil {
            _ = startNewAgentSession()
        }
        guard let runtime = activeRuntime else {
            let session = startNewAgentSession()
            return try mobileGatewaySendMessage(sessionID: session.id, text: text, workspacePath: nil)
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
