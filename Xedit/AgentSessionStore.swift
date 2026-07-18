//
//  AgentSessionStore.swift
//  WillDeep
//
//  Persists Agent-mode chat sessions as JSON files under the app's
//  Application Support directory. One file per session.
//

import Foundation

nonisolated enum AgentSessionStore {
    private nonisolated final class MetadataOnlySessionTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        private var userMessageIDs: Set<UUID> = []

        func replace(with ids: Set<UUID>, userMessageIDs: Set<UUID>) {
            lock.lock()
            self.ids = ids
            self.userMessageIDs = userMessageIDs
            lock.unlock()
        }

        func contains(_ id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(id)
        }

        func containsUserMessage(_ id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return userMessageIDs.contains(id)
        }

        func remove(_ id: UUID) {
            lock.lock()
            ids.remove(id)
            userMessageIDs.remove(id)
            lock.unlock()
        }

#if DEBUG
        func insertForTesting(_ id: UUID, hasUserMessage: Bool) {
            lock.lock()
            ids.insert(id)
            if hasUserMessage {
                userMessageIDs.insert(id)
            } else {
                userMessageIDs.remove(id)
            }
            lock.unlock()
        }
#endif
    }

    private static let metadataOnlySessions = MetadataOnlySessionTracker()

    // MARK: - Async write pipeline
    //
    // Session JSON used to be encoded + atomically written on the main
    // actor at every persist — several times per turn, tens of ms each
    // for long transcripts, all of it blocking the UI while tokens
    // stream. Writes now ride a single serial utility queue:
    //
    //   - `saveAsync` coalesces by session id (a burst of persists in
    //     one turn encodes once, with the latest snapshot) and reports
    //     failures back through `onAsyncSaveFailure`.
    //   - `save` / `delete` keep their synchronous contracts but run
    //     their file work on the same queue, so per-id write order can
    //     never invert between the sync and async paths.
    //   - `load(id:)` consults the not-yet-flushed snapshot first so a
    //     session materialized milliseconds after eviction can't read
    //     a stale file.
    //   - `flushPendingWrites()` drains the queue at app termination.

    private static let writeQueue = DispatchQueue(
        label: "com.willdeep.agent-session-store.writes",
        qos: .utility
    )

    private nonisolated final class PendingWriteTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [UUID: (session: AgentSession, seq: UInt64)] = [:]
        /// The snapshot a drain block is writing RIGHT NOW. Kept visible
        /// to peek/allPending — between `claim` and the file landing, the
        /// session is neither queued nor on disk, and without this window
        /// a concurrent `loadAll` (Settings window) would not see it at
        /// all. The serial write queue guarantees at most one in-flight
        /// write per id at any moment.
        private var inFlight: [UUID: AgentSession] = [:]
        private var nextSeq: UInt64 = 0

        /// Stores the snapshot and returns this write's ticket. Every
        /// `saveAsync` schedules its own drain block carrying the ticket;
        /// coalescing happens at `claim` time instead of at scheduling
        /// time so ordering against `delete` stays provable.
        func put(_ session: AgentSession) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            nextSeq += 1
            payloads[session.id] = (session, nextSeq)
            return nextSeq
        }

        /// Moves the payload to the in-flight slot and returns it — only
        /// when it was enqueued at or before `seq`. A drain block must
        /// never write a snapshot queued AFTER itself — e.g.
        /// `saveAsync(S1) → delete → saveAsync(S2)`: S1's drain runs
        /// before the queued delete and must not grab S2, or the delete
        /// would wipe a save that logically followed it. S2 is written by
        /// its own (post-delete) drain instead.
        func claim(_ id: UUID, upTo seq: UInt64) -> AgentSession? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = payloads[id], entry.seq <= seq else { return nil }
            payloads.removeValue(forKey: id)
            inFlight[id] = entry.session
            return entry.session
        }

        /// The write finished (success or failure) — drop the in-flight
        /// marker. On failure the caller re-queues via `restoreIfAbsent`
        /// BEFORE calling this so the snapshot never goes dark.
        func finish(_ id: UUID) {
            lock.lock()
            inFlight.removeValue(forKey: id)
            lock.unlock()
        }

        func peek(_ id: UUID) -> AgentSession? {
            lock.lock()
            defer { lock.unlock() }
            return payloads[id]?.session ?? inFlight[id]
        }

        func cancel(_ id: UUID) {
            lock.lock()
            payloads.removeValue(forKey: id)
            lock.unlock()
        }

        /// Re-insert a payload whose disk write failed — unless a newer
        /// snapshot already superseded it. Keeps `load(id:)` serving the
        /// freshest state even while the disk is failing, instead of
        /// silently falling back to a stale file.
        func restoreIfAbsent(_ session: AgentSession, seq: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard payloads[session.id] == nil else { return }
            payloads[session.id] = (session, seq)
        }

        func allPending() -> [UUID: AgentSession] {
            lock.lock()
            defer { lock.unlock() }
            // Queued payloads win over in-flight ones — they are newer.
            return inFlight.merging(payloads.mapValues(\.session)) { _, queued in queued }
        }
    }

    private static let pendingWrites = PendingWriteTracker()

    /// Posted on the main queue when a background session write fails;
    /// `object` is the session `UUID`. A notification (not a single
    /// stored closure) because multiple AppState instances exist (the
    /// Settings window builds its own) and each must be able to claim
    /// failures for the runtimes it owns.
    static let saveDidFailNotification = Notification.Name("AgentSessionStore.saveDidFail")

    /// Enqueue an ordered, coalesced background write of this session.
    /// The snapshot is taken now (value copy); a burst of saves for the
    /// same id still encodes only once — earlier drain blocks see a
    /// newer-than-their-ticket payload and yield to the last one.
    static func saveAsync(_ session: AgentSession) {
        metadataOnlySessions.remove(session.id)
        let id = session.id
        let ticket = pendingWrites.put(session)
        writeQueue.async {
            guard let payload = pendingWrites.claim(id, upTo: ticket) else { return }
            do {
                try ensureDirectory()
                let url = directory.appendingPathComponent("\(id.uuidString).json")
                let data = try encoder.encode(payload.externalizingAttachmentContent())
                try coordinatedWrite(data, to: url)
                writeCatalogEntryBestEffort(for: payload, sourceURL: url)
            } catch {
                print("AgentSessionStore: failed to save session \(id): \(error)")
                // Keep the unwritten snapshot around as an in-memory
                // fallback so load(id:) stays fresh (an evicted session
                // would otherwise re-materialize from the stale file and
                // silently truncate history). The next save supersedes it.
                pendingWrites.restoreIfAbsent(payload, seq: ticket)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: saveDidFailNotification, object: id)
                }
            }
            pendingWrites.finish(id)
        }
    }

    /// Blocks until every queued write has hit the disk. Called from app
    /// termination so quitting right after a turn can't drop the last
    /// messages that were still riding the async pipeline.
    static func flushPendingWrites() {
        writeQueue.sync {}
    }

    private struct MessageIndex: Decodable {
        let role: String?

        enum CodingKeys: String, CodingKey {
            case role
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decodeIfPresent(String.self, forKey: .role)
        }
    }

    private struct SessionIndex: Decodable {
        let id: UUID
        let title: String
        let workspaceRootPath: String?
        let workspaceLocation: WorkspaceLocation?
        let localWorkspaceIdentity: LocalWorkspaceIdentity?
        let modelID: String?
        let providerID: String?
        let providerDisplayName: String?
        let createdAt: Date
        let updatedAt: Date
        let didEditFiles: Bool
        let agentEditedPaths: [String]
        let interactionMode: AgentInteractionMode
        let approvalMode: AgentApprovalMode
        let executionAgent: AgentExecutionAgent
        let activeExperts: Set<AgentExpert>
        let currentPlan: AgentPlan?
        let currentGoal: AgentGoal?
        let learningEvents: [AgentLearningEvent]
        let latestTurnRecall: AgentTurnRecallSnapshot?
        let pinnedAt: Date?
        let archivedAt: Date?
        let titleIsUserSet: Bool
        let hasUserMessage: Bool

        enum CodingKeys: String, CodingKey {
            case id, title, workspaceRootPath, workspaceLocation, localWorkspaceIdentity, modelID
            case providerID, providerDisplayName
            case createdAt, updatedAt, messages
            case didEditFiles, agentEditedPaths, interactionMode, approvalMode, executionAgent, activeExperts
            case currentPlan, currentGoal, learningEvents, latestTurnRecall
            case pinnedAt, archivedAt, titleIsUserSet
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            workspaceRootPath = try c.decodeIfPresent(String.self, forKey: .workspaceRootPath)
            workspaceLocation = try c.decodeIfPresent(WorkspaceLocation.self, forKey: .workspaceLocation)
                ?? workspaceRootPath.map { .local(path: $0) }
            localWorkspaceIdentity = try c.decodeIfPresent(LocalWorkspaceIdentity.self, forKey: .localWorkspaceIdentity)
            modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
            providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
            providerDisplayName = try c.decodeIfPresent(String.self, forKey: .providerDisplayName)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            didEditFiles = try c.decodeIfPresent(Bool.self, forKey: .didEditFiles) ?? false
            agentEditedPaths = try c.decodeIfPresent([String].self, forKey: .agentEditedPaths) ?? []
            interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode) ?? .normal
            approvalMode = try c.decodeIfPresent(AgentApprovalMode.self, forKey: .approvalMode) ?? .smart
            executionAgent = try c.decodeIfPresent(AgentExecutionAgent.self, forKey: .executionAgent) ?? .willDeep
            activeExperts = try c.decodeIfPresent(Set<AgentExpert>.self, forKey: .activeExperts) ?? []
            currentPlan = try c.decodeIfPresent(AgentPlan.self, forKey: .currentPlan)
            currentGoal = try c.decodeIfPresent(AgentGoal.self, forKey: .currentGoal)
            learningEvents = try c.decodeIfPresent([AgentLearningEvent].self, forKey: .learningEvents) ?? []
            latestTurnRecall = try c.decodeIfPresent(AgentTurnRecallSnapshot.self, forKey: .latestTurnRecall)
            pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
            archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
            titleIsUserSet = try c.decodeIfPresent(Bool.self, forKey: .titleIsUserSet) ?? false
            let messageIndex = try c.decodeIfPresent([MessageIndex].self, forKey: .messages) ?? []
            hasUserMessage = messageIndex.contains { $0.role == AgentRole.user.rawValue }
        }

        var session: AgentSession {
            AgentSession(
                id: id,
                title: title,
                workspaceRootPath: workspaceRootPath,
                workspaceLocation: workspaceLocation,
                localWorkspaceIdentity: localWorkspaceIdentity,
                modelID: modelID,
                providerID: providerID,
                providerDisplayName: providerDisplayName,
                createdAt: createdAt,
                updatedAt: updatedAt,
                messages: [],
                contextSummary: nil,
                contextSummaryThroughMessageID: nil,
                didEditFiles: didEditFiles,
                agentEditedPaths: agentEditedPaths,
                interactionMode: interactionMode,
                approvalMode: approvalMode,
                executionAgent: executionAgent,
                activeExperts: activeExperts,
                currentPlan: currentPlan,
                currentGoal: currentGoal,
                learningEvents: learningEvents,
                latestTurnRecall: latestTurnRecall,
                pinnedAt: pinnedAt,
                archivedAt: archivedAt,
                titleIsUserSet: titleIsUserSet
            )
        }
    }

    /// Small, independently persisted sidebar record. The source signature
    /// makes this a cache rather than a second source of truth: if an older
    /// app, another process, or a manual restore changes the conversation
    /// JSON without updating this sidecar, launch falls back to that JSON and
    /// repairs the sidecar automatically.
    private struct CatalogEntry: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let session: AgentSession
        let hasUserMessage: Bool
        let sourceSignature: SourceSignature

        init(session: AgentSession, hasUserMessage: Bool, sourceSignature: SourceSignature) {
            schemaVersion = Self.currentSchemaVersion
            self.session = session
            self.hasUserMessage = hasUserMessage
            self.sourceSignature = sourceSignature
        }

        var isCurrentSchema: Bool {
            schemaVersion == Self.currentSchemaVersion
        }
    }

    private struct SourceSignature: Codable, Equatable {
        let fileSize: UInt64
        let modificationTime: TimeInterval
    }

    private struct UsageImageIndex: Decodable {
        init(from _: Decoder) throws {}
    }

    private struct UsageTextAttachmentIndex: Decodable {
        let filename: String?
        let content: String

        enum CodingKeys: String, CodingKey {
            case filename, content
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            filename = try c.decodeIfPresent(String.self, forKey: .filename)
            content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        }

        var modelBlockCharacterCount: Int {
            let displayName: String
            if let filename,
               !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = filename
            } else {
                displayName = AgentTextAttachment.pastedTextFilename
            }
            return """
            ### Attached text: \(displayName)

            ```text
            \(content)
            ```
            """.count
        }
    }

    private struct UsageToolCallIndex: Decodable {
        let externalID: String
        let toolName: String
        let argumentsJSON: String

        enum CodingKeys: String, CodingKey {
            case externalID, toolName, argumentsJSON
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            externalID = try c.decodeIfPresent(String.self, forKey: .externalID) ?? ""
            toolName = try c.decodeIfPresent(String.self, forKey: .toolName) ?? ""
            argumentsJSON = try c.decodeIfPresent(String.self, forKey: .argumentsJSON) ?? ""
        }
    }

    private struct UsageMessageIndex: Decodable {
        let role: String?
        let content: String
        let reasoningContent: String?
        let images: [UsageImageIndex]
        let textAttachments: [UsageTextAttachmentIndex]
        let toolCalls: [UsageToolCallIndex]
        let toolCallID: String?
        let toolCallStatus: AgentToolCallStatus?
        let toolErrorMessage: String?
        let usageTokens: Int?
        let promptTokens: Int?
        let completionTokens: Int?
        let cachedPromptTokens: Int?
        let cacheWritePromptTokens: Int?
        let reasoningTokens: Int?
        let origin: AgentMessageOrigin?
        let originLabel: String?
        let requestStablePrefixCharacters: Int?
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case role, content, reasoningContent, images, textAttachments, toolCalls
            case toolCallID, toolCallStatus, toolErrorMessage
            case usageTokens, promptTokens, completionTokens
            case cachedPromptTokens, cacheWritePromptTokens, reasoningTokens
            case origin, originLabel, requestStablePrefixCharacters
            case createdAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
            reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
            images = try c.decodeIfPresent([UsageImageIndex].self, forKey: .images) ?? []
            textAttachments = try c.decodeIfPresent([UsageTextAttachmentIndex].self, forKey: .textAttachments) ?? []
            toolCalls = try c.decodeIfPresent([UsageToolCallIndex].self, forKey: .toolCalls) ?? []
            toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
            toolCallStatus = try c.decodeIfPresent(AgentToolCallStatus.self, forKey: .toolCallStatus)
            toolErrorMessage = try c.decodeIfPresent(String.self, forKey: .toolErrorMessage)
            usageTokens = try c.decodeIfPresent(Int.self, forKey: .usageTokens)
            promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
            completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
            cachedPromptTokens = try c.decodeIfPresent(Int.self, forKey: .cachedPromptTokens)
            cacheWritePromptTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWritePromptTokens)
            reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens)
            origin = try c.decodeIfPresent(AgentMessageOrigin.self, forKey: .origin)
            originLabel = try c.decodeIfPresent(String.self, forKey: .originLabel)
            requestStablePrefixCharacters = try c.decodeIfPresent(Int.self, forKey: .requestStablePrefixCharacters)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        }

        var snapshot: AgentUsageMessageSnapshot? {
            guard let roleValue = role,
                  let role = AgentRole(rawValue: roleValue),
                  let createdAt else {
                return nil
            }

            var modelContentLength = content.count
            if !textAttachments.isEmpty {
                var blockLengths: [Int] = []
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blockLengths.append(content.count)
                }
                blockLengths.append(contentsOf: textAttachments.map(\.modelBlockCharacterCount))
                modelContentLength = blockLengths.reduce(0, +) + max(0, blockLengths.count - 1) * 2
            }

            return AgentUsageMessageSnapshot(
                role: role,
                contentCharacterCount: modelContentLength,
                reasoningCharacterCount: reasoningContent?.count ?? 0,
                imageCount: images.count,
                toolCallArgumentCharacterCount: toolCalls.reduce(0) { $0 + $1.argumentsJSON.count },
                toolCallNames: toolCalls.map(\.toolName),
                toolCallExternalIDs: toolCalls.map(\.externalID),
                toolCallID: toolCallID,
                toolCallStatus: toolCallStatus,
                toolErrorMessage: toolErrorMessage,
                usageTokens: usageTokens,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedPromptTokens: cachedPromptTokens,
                cacheWritePromptTokens: cacheWritePromptTokens,
                reasoningTokens: reasoningTokens,
                origin: origin,
                originLabel: originLabel,
                requestStablePrefixCharacters: requestStablePrefixCharacters,
                createdAt: createdAt
            )
        }
    }

    private struct UsageSessionIndex: Decodable {
        let id: UUID
        let modelID: String?
        let providerID: String?
        let providerDisplayName: String?
        let createdAt: Date
        let updatedAt: Date
        let messages: [UsageMessageIndex]
        let workspaceLocation: WorkspaceLocation?
        let workspaceRootPath: String?
        let agentEditedPaths: [String]
        let agentArtifactPaths: [String]

        enum CodingKeys: String, CodingKey {
            case id, modelID, providerID, providerDisplayName, createdAt, updatedAt, messages
            case workspaceLocation, workspaceRootPath, agentEditedPaths, agentArtifactPaths
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
            providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
            providerDisplayName = try c.decodeIfPresent(String.self, forKey: .providerDisplayName)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            messages = try c.decodeIfPresent([UsageMessageIndex].self, forKey: .messages) ?? []
            workspaceLocation = try c.decodeIfPresent(WorkspaceLocation.self, forKey: .workspaceLocation)
            workspaceRootPath = try c.decodeIfPresent(String.self, forKey: .workspaceRootPath)
            agentEditedPaths = try c.decodeIfPresent([String].self, forKey: .agentEditedPaths) ?? []
            agentArtifactPaths = try c.decodeIfPresent([String].self, forKey: .agentArtifactPaths) ?? []
        }

        var snapshot: AgentUsageSessionSnapshot {
            AgentUsageSessionSnapshot(
                id: id,
                modelID: modelID,
                providerID: providerID,
                providerDisplayName: providerDisplayName,
                createdAt: createdAt,
                updatedAt: updatedAt,
                messages: messages.compactMap(\.snapshot),
                workspaceIdentifier: workspaceIdentifier,
                editedFileCount: agentEditedPaths.count,
                artifactCount: agentArtifactPaths.count,
                artifactPaths: agentArtifactPaths
            )
        }

        private var workspaceIdentifier: String? {
            let location = workspaceLocation ?? workspaceRootPath.map { .local(path: $0) }
            guard let location else { return nil }
            switch location {
            case .local(let path):
                let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : "local:\(normalized)"
            case .remote(let runtimeID, let path):
                let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : "remote:\(runtimeID.uuidString):\(normalized)"
            }
        }
    }

    /// Disk location for session JSON files. Created lazily.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("agent-sessions", isDirectory: true)
    }

    /// The product was named VeilWriter before 1.59. The rename changed the
    /// Application Support directory but did not move existing conversations,
    /// which also made usage tokens and streaks appear to reset. Keep this as
    /// a retryable, idempotent import rather than a one-shot defaults flag:
    /// files may arrive later from a backup or another still-running old build.
    private static var legacyDirectories: [URL] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return [
            base.appendingPathComponent("VeilWriter", isDirectory: true)
                .appendingPathComponent("agent-sessions", isDirectory: true)
        ]
    }

    private static func importLegacySessionsIfNeeded() {
        writeQueue.sync {
            do {
                try ensureDirectory()
                let importedCount = try legacyDirectories.reduce(into: 0) { count, legacyDirectory in
                    count += try importLegacySessions(
                        from: legacyDirectory,
                        into: directory
                    )
                }
                if importedCount > 0 {
                    print("AgentSessionStore: imported \(importedCount) legacy session(s)")
                }
            } catch {
                // A failed import must not prevent current WillDeep sessions
                // from loading. Because no completion marker is written, the
                // next launch safely retries files that are still absent.
                print("AgentSessionStore: failed to import legacy sessions: \(error)")
            }
        }
    }

    /// Validates and imports legacy session JSON without deleting its source.
    /// Existing destination IDs always win, so repeated launches and an old
    /// app process writing concurrently cannot overwrite newer WillDeep data.
    @discardableResult
    static func importLegacySessions(
        from sourceDirectory: URL,
        into destinationDirectory: URL
    ) throws -> Int {
        let fileManager = FileManager.default
        let standardizedSource = sourceDirectory.standardizedFileURL
        let standardizedDestination = destinationDirectory.standardizedFileURL
        guard standardizedSource != standardizedDestination else { return 0 }

        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedSource.path, isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else {
            return 0
        }
        var destinationIsDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: standardizedDestination.path, isDirectory: &destinationIsDirectory) {
            try fileManager.createDirectory(at: standardizedDestination, withIntermediateDirectories: true)
        } else if !destinationIsDirectory.boolValue {
            throw CocoaError(.fileWriteFileExists)
        }

        let sourceURLs = try fileManager.contentsOfDirectory(
            at: standardizedSource,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var importedCount = 0
        for sourceURL in sourceURLs where sourceURL.pathExtension.lowercased() == "json" {
            let data: Data
            let session: AgentSession
            do {
                data = try Data(contentsOf: sourceURL)
                session = try decoder.decode(AgentSession.self, from: data)
            } catch {
                // One corrupt legacy conversation must not block every other
                // recoverable session in the directory.
                print("AgentSessionStore: skipping unreadable legacy session \(sourceURL.lastPathComponent): \(error)")
                continue
            }

            let destinationURL = standardizedDestination
                .appendingPathComponent("\(session.id.uuidString).json")
            if try coordinatedImportIfAbsent(data, to: destinationURL) {
                importedCount += 1
            }
        }
        return importedCount
    }

    /// Lightweight launch index. Keeping it in a child directory prevents
    /// its JSON files from being mistaken for full conversation files by
    /// legacy builds that enumerate `agent-sessions/*.json`.
    static var catalogDirectory: URL {
        directory.appendingPathComponent("catalog-v1", isDirectory: true)
    }

    static func catalogURL(for id: UUID) -> URL {
        catalogDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func loadOrRebuildCatalogEntry(for sourceURL: URL) -> CatalogEntry? {
        if let id = UUID(uuidString: sourceURL.deletingPathExtension().lastPathComponent),
           let signature = sourceSignature(for: sourceURL),
           let data = try? Data(contentsOf: catalogURL(for: id)),
           let entry = try? decoder.decode(CatalogEntry.self, from: data),
           entry.isCurrentSchema,
           entry.session.id == id,
           entry.sourceSignature == signature {
            return entry
        }

        // Coordinate the fallback read with other WillDeep processes. The
        // signature is captured inside the same read slot, so a writer that
        // lands immediately afterwards merely makes this rebuilt sidecar
        // stale; it can never make stale metadata look current.
        var rebuilt: CatalogEntry?
        var readError: Error?
        coordinatedRead(at: sourceURL) { readURL in
            do {
                let data = try Data(contentsOf: readURL)
                let index = try decoder.decode(SessionIndex.self, from: data)
                guard let signature = sourceSignature(for: readURL) else { return }
                rebuilt = CatalogEntry(
                    session: index.session,
                    hasUserMessage: index.hasUserMessage,
                    sourceSignature: signature
                )
            } catch {
                readError = error
            }
        }

        guard let rebuilt else {
            if let readError {
                print("AgentSessionStore: skipping unreadable session at \(sourceURL.lastPathComponent): \(readError)")
            }
            return nil
        }
        writeCatalogEntryBestEffort(rebuilt)
        return rebuilt
    }

    private static func writeCatalogEntryBestEffort(for session: AgentSession, sourceURL: URL) {
        guard let signature = sourceSignature(for: sourceURL) else { return }
        let entry = CatalogEntry(
            session: metadataSession(from: session),
            hasUserMessage: session.messages.contains { $0.role == .user },
            sourceSignature: signature
        )
        writeCatalogEntryBestEffort(entry)
    }

    private static func writeCatalogEntryBestEffort(_ entry: CatalogEntry) {
        do {
            try ensureCatalogDirectory()
            let data = try encoder.encode(entry)
            try coordinatedWrite(data, to: catalogURL(for: entry.session.id))
        } catch {
            // Conversation persistence already succeeded. A missing sidecar
            // costs one fallback decode on the next launch but does not lose
            // user data, so keep this best-effort and self-healing.
            print("AgentSessionStore: failed to update catalog for \(entry.session.id): \(error)")
        }
    }

    private static func metadataSession(from session: AgentSession) -> AgentSession {
        var copy = session
        copy.messages = []
        copy.contextSummary = nil
        copy.contextSummaryThroughMessageID = nil
        copy.documentAttachments = []
        copy.knowledgeFolders = []
        copy.sidePanelState = .empty
        return copy
    }

    private static func sourceSignature(for url: URL) -> SourceSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let date = attributes[.modificationDate] as? Date else {
            return nil
        }
        return SourceSignature(fileSize: size, modificationTime: date.timeIntervalSince1970)
    }

    /// Loads the lightweight sidebar catalog, newest-updated first. Normal
    /// launches read only small sidecars; a missing/stale sidecar triggers a
    /// one-time full-session decode and is repaired for the next launch.
    /// Full messages are materialized by `load(id:)` when the user opens a
    /// session. Usage analytics are deliberately not loaded here.
    static func loadAll() -> [AgentSession] {
        importLegacySessionsIfNeeded()

        var sessions: [AgentSession] = []
        var metadataOnlyIDs: Set<UUID> = []
        var metadataOnlyUserMessageIDs: Set<UUID> = []

        // Capture the pending overlay BEFORE scanning the directory. In
        // the opposite order a write that completes between the two reads
        // is invisible on both sides (file listed too early, tracker
        // already drained); this way it shows up in at least one — worst
        // case both, and the overlay merge below makes that harmless.
        let pendingSnapshot = pendingWrites.allPending()

        let dir = directory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
           let entries = try? FileManager.default.contentsOfDirectory(
               at: dir,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            for url in entries where url.pathExtension == "json" {
                guard let entry = loadOrRebuildCatalogEntry(for: url) else { continue }
                let session = entry.session
                metadataOnlyIDs.insert(session.id)
                if entry.hasUserMessage {
                    metadataOnlyUserMessageIDs.insert(session.id)
                }
                sessions.append(session)
            }
        }

        // Overlay snapshots still riding the async write pipeline: the
        // disk copy is stale for them, and the SessionIndex decode above
        // may have mis-classified one as "no user message yet". Without
        // this merge, a second AppState instance (the Settings window
        // builds its own) calling loadAll during the write window would
        // re-mark a just-persisted session metadata-only-without-user-
        // message. The pending snapshot is the full session, so it is not
        // metadata-only at all.
        for (id, snapshot) in pendingSnapshot {
            metadataOnlyIDs.remove(id)
            metadataOnlyUserMessageIDs.remove(id)
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index] = snapshot
            } else {
                sessions.append(snapshot)
            }
        }

        metadataOnlySessions.replace(with: metadataOnlyIDs, userMessageIDs: metadataOnlyUserMessageIDs)
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func loadUsageSnapshots() -> [AgentUsageSessionSnapshot] {
        importLegacySessionsIfNeeded()

        let dir = directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var snapshots: [AgentUsageSessionSnapshot] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                snapshots.append(try decoder.decode(UsageSessionIndex.self, from: data).snapshot)
            } catch {
                print("AgentSessionStore: skipping unreadable usage snapshot at \(url.lastPathComponent): \(error)")
            }
        }
        return snapshots.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func load(id: UUID) -> AgentSession? {
        // A snapshot still riding the async write pipeline is fresher
        // than whatever is on disk — e.g. a session evicted milliseconds
        // ago being re-materialized by a click. Serve it directly.
        if let pending = pendingWrites.peek(id) {
            metadataOnlySessions.remove(id)
            return pending
        }
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let session = try decoder.decode(AgentSession.self, from: data)
            metadataOnlySessions.remove(id)
            return session
        } catch {
            print("AgentSessionStore: failed to load session \(id): \(error)")
            return nil
        }
    }

    static func isMetadataOnly(_ id: UUID) -> Bool {
        metadataOnlySessions.contains(id)
    }

    static func metadataOnlySessionHasUserMessage(_ id: UUID) -> Bool {
        metadataOnlySessions.containsUserMessage(id)
    }

#if DEBUG
    static func markMetadataOnlyForTesting(_ id: UUID, hasUserMessage: Bool) {
        metadataOnlySessions.insertForTesting(id, hasUserMessage: hasUserMessage)
    }

    static func clearMetadataOnlyForTesting(_ id: UUID) {
        metadataOnlySessions.remove(id)
    }
#endif

    static func decodeSessionIndexForTesting(_ data: Data) throws -> (session: AgentSession, hasUserMessage: Bool) {
        let index = try decoder.decode(SessionIndex.self, from: data)
        return (index.session, index.hasUserMessage)
    }

    static func decodeUsageSnapshotForTesting(_ data: Data) throws -> AgentUsageSessionSnapshot {
        try decoder.decode(UsageSessionIndex.self, from: data).snapshot
    }

    @discardableResult
    static func save(_ session: AgentSession) -> Bool {
        metadataOnlySessions.remove(session.id)
        // Run on the shared write queue (not inline) so a synchronous
        // save can never race ahead of an older `saveAsync` payload for
        // the same session and then get clobbered by it.
        return writeQueue.sync {
            do {
                try ensureDirectory()
                let url = directory.appendingPathComponent("\(session.id.uuidString).json")
                let data = try encoder.encode(session.externalizingAttachmentContent())
                try coordinatedWrite(data, to: url)
                writeCatalogEntryBestEffort(for: session, sourceURL: url)
                return true
            } catch {
                print("AgentSessionStore: failed to save session \(session.id): \(error)")
                return false
            }
        }
    }

    @discardableResult
    static func delete(id: UUID) -> Bool {
        // Drop any queued-but-unwritten snapshot first, then remove the
        // file on the write queue — otherwise a pending async save could
        // resurrect the session on disk right after the delete.
        pendingWrites.cancel(id)
        return writeQueue.sync {
            let url = directory.appendingPathComponent("\(id.uuidString).json")
            do {
                try coordinatedRemove(at: url)
                try coordinatedRemove(at: catalogURL(for: id))
                metadataOnlySessions.remove(id)
                return true
            } catch {
                print("AgentSessionStore: failed to delete session \(id): \(error)")
                return false
            }
        }
    }

    /// Deletes the session file ONLY if its on-disk copy is (still) empty
    /// — has no user message. Guards the startup prune against a
    /// cross-process lost delete: another running WillDeep may have
    /// flushed a real user message into this id AFTER our in-memory scan
    /// classified it as a prunable "New Chat" placeholder. We re-read the
    /// file under file coordination and bail if it now holds history.
    /// Returns true iff a file was actually removed.
    ///
    /// The unconditional `delete(id:)` above stays for user-initiated
    /// deletions where the caller owns the session and truly means it.
    private static func ensureDirectory() throws {
        let dir = directory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static func ensureCatalogDirectory() throws {
        try ensureDirectory()
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: catalogDirectory.path, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Cross-process file coordination
    //
    // Two WillDeep processes (a second window builds its own AppState, and
    // routine/agent processes touch the same directory) read and write the
    // same `<uuid>.json` files. The in-process `writeQueue` orders our own
    // writes but gives zero guarantee against another process. `.atomic`
    // stops half-written reads but not lost updates or a delete racing a
    // foreign write. `NSFileCoordinator` serializes access across processes
    // on the same URL, so a coordinated write completes before a foreign
    // coordinated read/write starts, and the delete-time re-read below sees
    // a consistent file rather than one mid-replacement.
    //
    // On the rare event coordination itself fails, we fall back to the
    // previous uncoordinated behavior rather than drop the operation — the
    // change only ever adds safety, never removes the baseline.

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if coordError != nil {
            // Couldn't acquire a coordinated slot — degrade to a direct
            // atomic write so the save is never silently dropped.
            try data.write(to: url, options: .atomic)
            return
        }
        if let writeError { throw writeError }
    }

    /// Writes an imported file only when the destination is still absent.
    /// The existence check lives inside the coordinated write slot so two
    /// WillDeep processes launching together cannot replace one another's
    /// current session with the legacy copy.
    private static func coordinatedImportIfAbsent(_ data: Data, to url: URL) throws -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var importError: Error?
        var didImport = false
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { writeURL in
            guard !FileManager.default.fileExists(atPath: writeURL.path) else { return }
            do {
                try data.write(to: writeURL, options: .atomic)
                didImport = true
            } catch {
                importError = error
            }
        }
        if coordinationError != nil {
            guard !FileManager.default.fileExists(atPath: url.path) else { return false }
            try data.write(to: url, options: .atomic)
            return true
        }
        if let importError { throw importError }
        return didImport
    }

    private static func coordinatedRemove(at url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var removeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordError) { removeURL in
            do {
                if FileManager.default.fileExists(atPath: removeURL.path) {
                    try FileManager.default.removeItem(at: removeURL)
                }
            } catch {
                removeError = error
            }
        }
        if coordError != nil {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        if let removeError { throw removeError }
    }

    private static func coordinatedRead(at url: URL, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { readURL in
            body(readURL)
        }
        if coordError != nil {
            // Coordination unavailable — read the URL directly so callers
            // still get a decision instead of stalling.
            body(url)
        }
    }

    /// Localized placeholder title for a session that has no derived or
    /// summarized title yet ("New Chat" / "新对话").
    nonisolated static var defaultTitle: String { L10n.Sidebar.defaultSessionTitle }

    /// Whether `title` is a generic placeholder (the localized default, an
    /// older hardcoded variant, or empty) rather than a real, content-
    /// derived or user-set title. Used to decide when opening a session
    /// should kick off a one-shot title summary.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return true }
        let placeholders: Set<String> = [
            defaultTitle.lowercased(),
            "new chat", "chat", "新对话", "新聊天", "新会话", "新的对话",
        ]
        return placeholders.contains(normalized)
    }

    /// Derive a short, human-readable title from the first user message.
    static func deriveTitle(from messages: [AgentMessage]) -> String {
        guard let firstUser = messages.first(where: { $0.role == .user }) else {
            return defaultTitle
        }
        let text = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let firstAttachment = firstUser.textAttachments.first {
            return firstAttachment.displayName
        }
        guard !text.isEmpty else { return defaultTitle }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 40 { return oneLine }
        return String(oneLine.prefix(40)) + "…"
    }
}
