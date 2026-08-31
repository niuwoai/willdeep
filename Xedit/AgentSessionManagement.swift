import Foundation

nonisolated struct AgentSessionRetentionSettings: Codable, Equatable {
    static let storageKey = "com.willdeep.agentSettings.sessionRetention.v1"
    static let defaultLimit = 20
    static let allowedLimits = 1...500
    var enabled = false
    var keepCount = defaultLimit

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.keepCount = min(allowedLimits.upperBound, max(allowedLimits.lowerBound, value.keepCount))
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

nonisolated enum AgentSessionManagementAction: String {
    case archive, unarchive, delete
}

nonisolated enum AgentSessionRetentionPolicy {
    /// Keep the newest N first, then exempt protected older sessions as well.
    /// Protection never displaces a newer session just to satisfy a quota.
    static func candidates(
        sessions: [AgentSession], projectIDs: Set<UUID>, keepCount: Int, protectedIDs: Set<UUID>
    ) -> [UUID] {
        let groups = Dictionary(grouping: sessions.filter {
            $0.presentationScope == .workspace && !$0.isArchived
                && $0.projectID.map(projectIDs.contains) == true
        }, by: { $0.projectID! })
        return groups.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { projectID in
            groups[projectID, default: []].sorted(by: newestFirst)
                .dropFirst(max(1, keepCount))
                .filter { !$0.isPinned && !protectedIDs.contains($0.id) }
                .map(\.id)
        }
    }

    static func newestFirst(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum AgentSessionManagementRequest {
    static let maximumBatch = 100
    case projects(offset: Int, limit: Int)
    case sessions(projectID: UUID, includeArchived: Bool, offset: Int, limit: Int)
    case manage(ids: [UUID], action: AgentSessionManagementAction, dryRun: Bool)

    static func parse(tool: String, arguments: [String: AgentJSONValue]) throws -> Self {
        if tool == "manage_sessions" {
            guard let action = arguments["action"]?.stringValue().flatMap(AgentSessionManagementAction.init) else {
                throw AgentToolError.invalidArgument("action must be archive, unarchive, or delete")
            }
            guard case .array(let rawIDs) = arguments["session_ids"],
                  !rawIDs.isEmpty, rawIDs.count <= maximumBatch else {
                throw AgentToolError.invalidArgument("session_ids must contain 1...100 exact session UUIDs")
            }
            let ids = try rawIDs.map { value -> UUID in
                guard let string = value.stringValue(), let id = UUID(uuidString: string) else {
                    throw AgentToolError.invalidArgument("session_ids contains an invalid UUID")
                }
                return id
            }
            var seen = Set<UUID>()
            return .manage(ids: ids.filter { seen.insert($0).inserted }, action: action,
                           dryRun: arguments["dry_run"]?.boolValue() ?? true)
        }
        let offset = arguments["offset"]?.intValue() ?? 0
        let limit = arguments["limit"]?.intValue() ?? 50
        guard offset >= 0, (1...maximumBatch).contains(limit) else {
            throw AgentToolError.invalidArgument("offset must be nonnegative; limit must be 1...100")
        }
        if tool == "list_projects" { return .projects(offset: offset, limit: limit) }
        guard tool == "list_project_sessions",
              let rawID = arguments["project_id"]?.stringValue(), let id = UUID(uuidString: rawID) else {
            throw AgentToolError.invalidArgument("project_id must be an exact UUID from list_projects")
        }
        return .sessions(projectID: id, includeArchived: arguments["include_archived"]?.boolValue() ?? false,
                         offset: offset, limit: limit)
    }
}

enum AgentSessionManagementTools {
    static let descriptors: [AgentToolDescriptor] = [
        AgentToolDescriptor(
            name: "list_projects", description: "List all WillDeep workspace projects with stable IDs, folder roots and session counts, including empty projects. Returns metadata only. Paginate using next_offset until null.",
            risk: .read, parameters: pagination
        ),
        AgentToolDescriptor(
            name: "list_project_sessions", description: "List sessions in an exact project returned by list_projects, newest updated_at first. Includes empty conversations and protection reasons; no transcript text. Paginate using next_offset until null.",
            risk: .read, parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Exact project UUID from list_projects.", required: true),
                AgentToolParameter(name: "include_archived", type: .boolean, description: "Include archived sessions. Default false.", required: false)
            ] + pagination
        ),
        AgentToolDescriptor(
            name: "manage_sessions", description: "Batch archive, unarchive or permanently delete exact WillDeep sessions. Use only when requested by the user. First list sessions and preview with dry_run=true (default), explain the exact targets, then apply with dry_run=false. Apply always requires human approval, including Full Access. Active, pinned, running or awaiting-attention sessions are protected from archiving/deletion. Invalid or missing IDs fail before any changes. Returns per-session outcomes; deletion cannot be undone. Prefer reversible archive.",
            risk: .danger, parameters: [
                AgentToolParameter(name: "session_ids", type: .stringArray, description: "1...100 exact UUIDs from session listings. No names, wildcards or implicit all.", required: true),
                AgentToolParameter(name: "action", type: .string, description: "archive, unarchive or delete. Delete permanently removes the conversation and its stored images.", required: true),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "Default true: preview only. Explicit false applies the approved action.", required: false)
            ]
        )
    ]

    private static let pagination = [
        AgentToolParameter(name: "offset", type: .integer, description: "Zero-based offset, default 0; use next_offset from the preceding page.", required: false),
        AgentToolParameter(name: "limit", type: .integer, description: "Page size, default 50, range 1...100.", required: false)
    ]

    static func requiresConfirmation(tool: String, arguments: [String: AgentJSONValue]) -> Bool {
        tool == "manage_sessions" && arguments["dry_run"]?.boolValue() == false
    }

    static func run(tool: String, arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let request = try AgentSessionManagementRequest.parse(tool: tool, arguments: arguments)
        guard let handler = context.sessionManagementHandler else {
            throw AgentToolError.invalidArgument("Session management is unavailable in this context")
        }
        guard !context.isUnattendedDispatchTask || !requiresConfirmation(tool: tool, arguments: arguments) else {
            throw AgentToolError.invalidArgument("Batch session changes require an attached operator")
        }
        return try await handler(request)
    }
}
