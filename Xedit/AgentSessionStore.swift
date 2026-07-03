//
//  AgentSessionStore.swift
//  WillDeep
//
//  Persists Agent-mode chat sessions as JSON files under the app's
//  Application Support directory. One file per session.
//

import Foundation

enum AgentSessionStore {
    private nonisolated final class MetadataOnlySessionTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []

        func replace(with ids: Set<UUID>) {
            lock.lock()
            self.ids = ids
            lock.unlock()
        }

        func contains(_ id: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(id)
        }

        func remove(_ id: UUID) {
            lock.lock()
            ids.remove(id)
            lock.unlock()
        }
    }

    private static let metadataOnlySessions = MetadataOnlySessionTracker()

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

        enum CodingKeys: String, CodingKey {
            case id, title, workspaceRootPath, workspaceLocation, localWorkspaceIdentity, modelID
            case providerID, providerDisplayName
            case createdAt, updatedAt
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

    /// Disk location for session JSON files. Created lazily.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("agent-sessions", isDirectory: true)
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

    /// Loads a lightweight session index, newest-updated first. Message bodies
    /// can contain pasted screenshots or generated media as base64, so keeping
    /// every transcript resident at launch makes the app grow with historical
    /// chat size. Full messages are materialized by `load(id:)` when the user
    /// opens a session.
    static func loadAll() -> [AgentSession] {
        let dir = directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            metadataOnlySessions.replace(with: [])
            return []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            metadataOnlySessions.replace(with: [])
            return []
        }

        var sessions: [AgentSession] = []
        var metadataOnlyIDs: Set<UUID> = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let session = try decoder.decode(SessionIndex.self, from: data).session
                metadataOnlyIDs.insert(session.id)
                sessions.append(session)
            } catch {
                print("AgentSessionStore: skipping unreadable session at \(url.lastPathComponent): \(error)")
            }
        }
        metadataOnlySessions.replace(with: metadataOnlyIDs)
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func load(id: UUID) -> AgentSession? {
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

    @discardableResult
    static func save(_ session: AgentSession) -> Bool {
        do {
            try ensureDirectory()
            let url = directory.appendingPathComponent("\(session.id.uuidString).json")
            let data = try encoder.encode(session)
            try data.write(to: url, options: .atomic)
            metadataOnlySessions.remove(session.id)
            return true
        } catch {
            print("AgentSessionStore: failed to save session \(session.id): \(error)")
            return false
        }
    }

    @discardableResult
    static func delete(id: UUID) -> Bool {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            metadataOnlySessions.remove(id)
            return true
        } catch {
            print("AgentSessionStore: failed to delete session \(id): \(error)")
            return false
        }
    }

    private static func ensureDirectory() throws {
        let dir = directory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Localized placeholder title for a session that has no derived or
    /// summarized title yet ("New Chat" / "新对话").
    static var defaultTitle: String { L10n.Sidebar.defaultSessionTitle }

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
