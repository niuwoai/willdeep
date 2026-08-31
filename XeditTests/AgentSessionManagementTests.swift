import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentSessionManagementTests {
    private func session(projectID: UUID?, age: Int) -> AgentSession {
        AgentSession(title: "fixture-\(age)", projectID: projectID,
                     updatedAt: Date(timeIntervalSince1970: Double(age)),
                     messages: [AgentMessage(role: .user, content: "fixture message")])
    }

    private func state(defaults: UserDefaults) -> AppState {
        let state = AppState(rootDirectory: nil, sessionManagementDefaults: defaults, loadSessionCatalog: false)
        state.agentSessions = []
        state.agentProjects = []
        state.markSessionCatalogLoadedForTesting()
        return state
    }

    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "willdeep-session-management-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults)
    }

    private func payload(_ result: AgentToolResult) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any])
    }

    @Test("default retention is off with twenty sessions and settings persist")
    func settingsRoundTrip() async throws {
        try await withDefaults { defaults in
            #expect(AgentSessionRetentionSettings.load(defaults: defaults) == AgentSessionRetentionSettings())
            let settings = AgentSessionRetentionSettings(enabled: true, keepCount: 35)
            settings.save(defaults: defaults)
            #expect(AgentSessionRetentionSettings.load(defaults: defaults) == settings)
            AgentSessionRetentionSettings(enabled: true, keepCount: -1).save(defaults: defaults)
            #expect(AgentSessionRetentionSettings.load(defaults: defaults).keepCount == 1)
            defaults.set(Data("bad".utf8), forKey: AgentSessionRetentionSettings.storageKey)
            #expect(!AgentSessionRetentionSettings.load(defaults: defaults).enabled)
        }
    }

    @Test("retention keeps exactly newest twenty per project", arguments: [19, 20, 21, 45])
    func retentionBoundary(count: Int) {
        let project = UUID()
        let sessions = (0..<count).map { session(projectID: project, age: $0) }
        let result = AgentSessionRetentionPolicy.candidates(sessions: sessions, projectIDs: [project], keepCount: 20, protectedIDs: [])
        #expect(Set(result) == Set(sessions.prefix(max(0, count - 20)).map(\.id)))
    }

    @Test("projects are independent and orphan/archive/workflow sessions are excluded")
    func projectIsolation() {
        let a = UUID(), b = UUID()
        let rowsA = (0..<22).map { session(projectID: a, age: $0) }
        let rowsB = (0..<20).map { session(projectID: b, age: $0) }
        var archived = session(projectID: a, age: 100)
        archived.archivedAt = .now
        var workflow = session(projectID: a, age: 101)
        workflow.presentationScope = .dispatchBoard
        let rows = rowsA + rowsB + [archived, workflow, session(projectID: nil, age: 1), session(projectID: UUID(), age: 2)]
        #expect(Set(AgentSessionRetentionPolicy.candidates(sessions: rows, projectIDs: [a,b], keepCount: 20, protectedIDs: [])) == Set(rowsA.prefix(2).map(\.id)))
    }

    @Test("protected older sessions do not displace the newest twenty")
    func protectedSessionsAreExtra() {
        let project = UUID()
        var rows = (0..<24).map { session(projectID: project, age: $0) }
        rows[0].pinnedAt = .now
        let result = AgentSessionRetentionPolicy.candidates(sessions: rows, projectIDs: [project], keepCount: 20, protectedIDs: [rows[1].id])
        #expect(Set(result) == Set([rows[2].id, rows[3].id]))
    }

    @Test("equal timestamps use deterministic IDs instead of input ordering")
    func tiesAreStable() {
        let project = UUID()
        let rows = (0..<24).map { _ in session(projectID: project, age: 0) }
        #expect(AgentSessionRetentionPolicy.candidates(sessions: rows, projectIDs: [project], keepCount: 20, protectedIDs: []) ==
                AgentSessionRetentionPolicy.candidates(sessions: rows.reversed(), projectIDs: [project], keepCount: 20, protectedIDs: []))
    }

    @Test("management defaults to preview and deduplicates exact IDs")
    func previewParsing() throws {
        let id = UUID()
        let request = try AgentSessionManagementRequest.parse(tool: "manage_sessions", arguments: [
            "action": .string("delete"), "session_ids": .array([.string(id.uuidString), .string(id.uuidString)])
        ])
        guard case .manage(let ids, let action, let preview) = request else { Issue.record("Expected management request"); return }
        #expect(ids == [id]); #expect(action == .delete); #expect(preview)
    }

    @Test("invalid batch and pagination parameters fail before handling")
    func invalidRequests() {
        for ids: [AgentJSONValue] in [[], [.string("all")], Array(repeating: .string(UUID().uuidString), count: 101)] {
            #expect(throws: (any Error).self) {
                try AgentSessionManagementRequest.parse(tool: "manage_sessions", arguments: ["action": .string("archive"), "session_ids": .array(ids)])
            }
        }
        #expect(throws: (any Error).self) { try AgentSessionManagementRequest.parse(tool: "list_projects", arguments: ["offset": .number(-1)]) }
        #expect(throws: (any Error).self) { try AgentSessionManagementRequest.parse(tool: "list_project_sessions", arguments: ["project_id": .string("guess")]) }
    }

    @Test("project and session listings paginate, include empty projects, and do not load transcripts")
    func paginatedListings() async throws {
        try await withDefaults { defaults in
            let state = state(defaults: defaults)
            let project = AgentProject(displayName: "fixture", folderPaths: ["/tmp/fixture"])
            let empty = AgentProject(displayName: "empty", folderPaths: ["/tmp/empty"])
            state.agentProjects = [project, empty]
            let rows = (0..<3).map { session(projectID: project.id, age: $0) }
            state.agentSessions = rows
            let page = try payload(await state.handleSessionManagement(.projects(offset: 0, limit: 1), callerID: nil))
            #expect(page["total"] as? Int == 2); #expect(page["next_offset"] as? Int == 1)
            let chats = try payload(await state.handleSessionManagement(.sessions(projectID: project.id, includeArchived: false, offset: 1, limit: 2), callerID: nil))
            let listed = try #require(chats["sessions"] as? [[String: Any]])
            #expect(listed.map { $0["id"] as? String } == [rows[1].id.uuidString, rows[0].id.uuidString])
            #expect(chats["next_offset"] is NSNull)
            #expect(!String(describing: chats).contains("fixture message"))
        }
    }

    @Test("batch preview never writes and unknown IDs reject the entire batch")
    func previewAndUnknownIDs() async throws {
        try await withDefaults { defaults in
            let state = state(defaults: defaults)
            let row = session(projectID: nil, age: 1)
            state.agentSessions = [row]
            let result = try payload(await state.handleSessionManagement(.manage(ids: [row.id], action: .delete, dryRun: true), callerID: nil))
            #expect((result["outcomes"] as? [[String: Any]])?.first?["status"] as? String == "would_delete")
            #expect(state.agentSessions == [row])
            await #expect(throws: (any Error).self) {
                try await state.handleSessionManagement(.manage(ids: [row.id, UUID()], action: .delete, dryRun: false), callerID: nil)
            }
            #expect(state.agentSessions == [row])
        }
    }

    @Test("active, pinned, running and draft conversations are protected")
    func protectionReasons() async throws {
        try await withDefaults { defaults in
            let state = state(defaults: defaults)
            var row = session(projectID: nil, age: 1)
            state.activeAgentSessionID = row.id
            #expect(state.sessionManagementProtectionReason(row) == "active_session")
            state.activeAgentSessionID = nil
            row.pinnedAt = .now
            #expect(state.sessionManagementProtectionReason(row) == "pinned")
            row.pinnedAt = nil
            let runtime = AgentRuntime(session: row)
            state.agentRuntimes[row.id] = runtime
            runtime.isResponding = true
            #expect(state.sessionManagementProtectionReason(row) == "running_or_queued")
            runtime.isResponding = false
            runtime.input = "unsent"
            #expect(state.sessionManagementProtectionReason(row) == "unsent_draft")
        }
    }

    @Test("archive and unarchive preserve transcript and recency, including metadata-only sessions")
    func archiveRoundTrip() async throws {
        try await withDefaults { defaults in
            let state = state(defaults: defaults)
            let original = session(projectID: nil, age: 1)
            #expect(AgentSessionStore.save(original))
            // Establish the persisted baseline (the store rounds dates to seconds).
            let row = try #require(AgentSessionStore.load(id: original.id))
            defer { AgentSessionStore.delete(id: row.id) }
            var skeleton = row; skeleton.messages = []
            state.agentSessions = [skeleton]
            state.markAgentSessionMetadataOnlyForTesting(row.id, hasUserMessage: true)
            _ = try await state.handleSessionManagement(.manage(ids: [row.id], action: .archive, dryRun: false), callerID: nil)
            #expect(AgentSessionStore.load(id: row.id)?.isArchived == true)
            #expect(AgentSessionStore.load(id: row.id)?.messages == row.messages)
            #expect(AgentSessionStore.load(id: row.id)?.updatedAt == row.updatedAt)
            _ = try await state.handleSessionManagement(.manage(ids: [row.id], action: .unarchive, dryRun: false), callerID: nil)
            #expect(AgentSessionStore.load(id: row.id) == row)
        }
    }

    @Test("deletion removes only selected unprotected synthetic sessions")
    func deleteBatch() async throws {
        try await withDefaults { defaults in
            let state = state(defaults: defaults)
            let target = session(projectID: nil, age: 1)
            var pinned = session(projectID: nil, age: 2); pinned.pinnedAt = .now
            #expect(AgentSessionStore.save(target)); #expect(AgentSessionStore.save(pinned))
            defer { AgentSessionStore.delete(id: target.id); AgentSessionStore.delete(id: pinned.id) }
            state.agentSessions = [target, pinned]
            _ = try await state.handleSessionManagement(.manage(ids: [target.id, pinned.id], action: .delete, dryRun: false), callerID: nil)
            #expect(AgentSessionStore.load(id: target.id) == nil)
            #expect(AgentSessionStore.load(id: pinned.id) != nil)
            #expect(state.agentSessions.map(\.id) == [pinned.id])
        }
    }

    @Test("automatic archiving is opt-in, runs immediately, persists and is idempotent")
    func automaticArchiving() async throws {
        try await withDefaults { defaults in
            let state = state(defaults: defaults)
            let project = AgentProject(displayName: "retention-fixture", folderPaths: ["/tmp/retention-fixture"])
            let rows = (0..<22).map { session(projectID: project.id, age: $0) }
            state.agentProjects = [project]; state.agentSessions = rows
            rows.forEach { _ = AgentSessionStore.save($0) }
            defer { rows.forEach { AgentSessionStore.delete(id: $0.id) } }
            state.requestAutomaticSessionArchiving()
            #expect(state.sessionAutoArchiveTask == nil)
            state.sessionRetentionSettings.enabled = true
            await state.sessionAutoArchiveTask?.value
            #expect(state.sessionAutoArchiveLastCount == 2)
            #expect(state.agentSessions.filter { !$0.isArchived }.count == 20)
            #expect(AgentSessionStore.load(id: rows[0].id)?.isArchived == true)
            state.requestAutomaticSessionArchiving()
            await state.sessionAutoArchiveTask?.value
            #expect(state.sessionAutoArchiveLastCount == 0)
            #expect(AgentSessionRetentionSettings.load(defaults: defaults).enabled)
        }
    }

    @Test("writes always require approval even in Full Access and Goal mode")
    func approvalBoundary() async throws {
        try await withDefaults { defaults in
            let state = state(defaults: defaults)
            for action in ["archive", "unarchive", "delete"] {
                let args: [String: AgentJSONValue] = ["action": .string(action), "dry_run": .bool(false)]
                let risk = AgentToolRegistry.risk(for: "manage_sessions", arguments: args)
                #expect(risk == (action == "delete" ? .danger : .write))
                #expect(await state.autoApprovalSource(toolName: "manage_sessions", arguments: args, risk: risk,
                                                      rootDirectory: nil, interactionMode: .goal, approvalMode: .fullAccess) == nil)
                #expect(state.fullAccessApprovalSource(toolName: "manage_sessions", arguments: args, risk: risk) == nil)
            }
            #expect(AgentToolRegistry.risk(for: "manage_sessions", arguments: [:]) == .read)
        }
    }

    @Test("tool handler survives context copies; unattended and missing handlers cannot mutate")
    func toolContextWiring() async throws {
        var calls = 0
        let context = AgentToolContext(rootDirectory: nil, sessionManagementHandler: { _ in
            calls += 1; return AgentToolResult(summary: "fixture", payload: "{}")
        })
        _ = try await AgentSessionManagementTools.run(tool: "list_projects", arguments: [:], context: context.withSandboxMode(.readOnly).withAdditionalSecretRedactionValues([]))
        #expect(calls == 1)
        let unattended = AgentToolContext(rootDirectory: nil, sessionManagementHandler: context.sessionManagementHandler, isUnattendedDispatchTask: true)
        await #expect(throws: (any Error).self) {
            try await AgentSessionManagementTools.run(tool: "manage_sessions", arguments: [
                "session_ids": .array([.string(UUID().uuidString)]), "action": .string("delete"), "dry_run": .bool(false)
            ], context: unattended)
        }
        #expect(calls == 1)
        await #expect(throws: (any Error).self) {
            try await AgentSessionManagementTools.run(tool: "list_projects", arguments: [:], context: AgentToolContext(rootDirectory: nil))
        }
    }
}
