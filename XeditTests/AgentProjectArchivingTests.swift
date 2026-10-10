import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentProjectArchivingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func project(age: TimeInterval, name: String = "fixture") -> AgentProject {
        let date = now.addingTimeInterval(-age)
        return AgentProject(displayName: name, folderPaths: ["/private/tmp/\(UUID())"],
                            createdAt: date, updatedAt: date)
    }

    private func session(_ project: AgentProject, date: Date) -> AgentSession {
        AgentSession(title: "history", workspaceRootPath: project.primaryFolderPath, projectID: project.id,
                     createdAt: date, updatedAt: date,
                     messages: [.init(role: .user, content: "retained conversation", createdAt: date)])
    }

    private func fixture() throws -> (AppState, UserDefaults, String) {
        let suite = "project-archiving-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
                           sessionManagementDefaults: defaults, loadSessionCatalog: false)
        app.agentProjects = []
        app.agentSessions = []
        app.activeAgentSessionID = nil
        app.projectArchivingCatalogUpdater = { [weak app] project in
            app?.agentProjects.map { $0.id == project.id ? project : $0 }
        }
        app.markSessionCatalogLoadedForTesting()
        return (app, defaults, suite)
    }

    @Test("严格超过 30 天才归档；保护、置顶和已归档项目不重复处理")
    func exactThresholdAndProtection() {
        let interval = AgentProjectArchiving.inactivityInterval
        let old = project(age: interval + 1)
        let boundary = project(age: interval)
        let recent = project(age: interval - 1)
        var pinned = project(age: interval + 1); pinned.pinnedAt = now
        var archived = project(age: interval + 1); archived.archivedAt = now
        let protected = project(age: interval + 1)
        #expect(AgentProjectArchiving.candidates(projects: [old, boundary, recent, pinned, archived, protected],
            sessions: [], protectedIDs: [protected.id], now: now) == [old.id])
    }

    @Test("项目内任何会话近期活跃都会保留项目，包括已归档会话和最后用户输入")
    func latestSessionActivityWins() {
        let p = project(age: AgentProjectArchiving.inactivityInterval * 2)
        var recent = session(p, date: now)
        recent.archivedAt = now
        #expect(AgentProjectArchiving.candidates(projects: [p], sessions: [recent], protectedIDs: [], now: now).isEmpty)
        recent.messages.insert(.init(role: .assistant, content: "old reply", createdAt: p.createdAt), at: 0)
        recent.updatedAt = p.createdAt
        #expect(AgentProjectArchiving.lastActivity(of: p, sessions: [recent]) == now)
    }

    @Test("旧项目缺少归档和活跃字段时可读；归档字段持久化不丢失其他元数据")
    func catalogCompatibility() throws {
        let p = project(age: 1)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        object.removeValue(forKey: "archivedAt"); object.removeValue(forKey: "lastActivityAt")
        let legacy = try JSONDecoder().decode(AgentProject.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy == p)
        var archived = legacy; archived.archivedAt = now; archived.lastActivityAt = now
        #expect(try JSONDecoder().decode(AgentProject.self, from: JSONEncoder().encode(archived)) == archived)
    }

    @Test("旧调度目标按主工作区归属项目；显式归属和远程工作区不会串项目")
    func legacyDispatchOwnership() throws {
        let p = project(age: AgentProjectArchiving.inactivityInterval * 2)
        let path = try #require(p.primaryFolderPath)
        var goal = AgentDispatchGoal(id: UUID(), sessionID: UUID(), title: "fixture", statement: "work",
            logicalProject: .init(displayName: "fixture", primaryWorkspacePath: path),
            workspaceLocation: .local(path: "/private/tmp/worker"), tasks: [],
            executorChoice: .automatic, targetChoice: .automatic, isPaused: false, commands: [],
            createdAt: p.createdAt, updatedAt: p.updatedAt)
        #expect(AgentProjectArchiving.belongs(goal, to: p))
        goal.logicalProject?.managedProjectID = UUID()
        #expect(!AgentProjectArchiving.belongs(goal, to: p))
        goal.logicalProject = nil
        goal.workspaceLocation = .local(path: path)
        #expect(AgentProjectArchiving.belongs(goal, to: p))
        goal.workspaceLocation = .remote(runtimeID: UUID(), path: path)
        #expect(!AgentProjectArchiving.belongs(goal, to: p))
    }

    @Test("归档整个项目；恢复保留会话原有归档状态且不会立即再次归档")
    func archiveRestorePreservesHistory() throws {
        let (app, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = project(age: AgentProjectArchiving.inactivityInterval * 2)
        let other = project(age: 0)
        var oldArchived = session(p, date: p.createdAt); oldArchived.archivedAt = p.createdAt
        app.agentProjects = [p, other]
        app.agentSessions = [session(p, date: p.createdAt), oldArchived, session(other, date: now)]
        let history = app.agentSessions
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-catalog-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(app.agentProjects).write(to: root, options: .atomic)
        app.projectArchivingCatalogUpdater = { AgentProjectStore.updateArchiving($0, at: root) }
        app.archiveInactiveAgentProjects(now: now)
        #expect(app.archivedAgentProjects.map(\.id) == [p.id])
        #expect(app.activeAgentProjects.map(\.id) == [other.id])
        #expect(app.agentSessions == history)
        #expect(AgentProjectArchiving.visibleSessions(history, projects: app.agentProjects).map(\.id) == [history[2].id])
        let disk = try JSONDecoder().decode([AgentProject].self, from: Data(contentsOf: root))
        #expect(disk.first?.archivedAt == now)
        #expect(app.setAgentProjectArchived(id: p.id, archived: false, now: now))
        app.archiveInactiveAgentProjects(now: now.addingTimeInterval(1))
        #expect(app.archivedAgentProjects.isEmpty)
        #expect(app.agentSessions == history)
        #expect(app.agentProjects.first?.updatedAt == p.updatedAt)
    }

    @Test("运行、草稿、当前会话和另一窗口的活跃项目不能归档")
    func protectsLiveWork() throws {
        let (app, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = project(age: AgentProjectArchiving.inactivityInterval * 2)
        let s = session(p, date: p.createdAt)
        app.agentProjects = [p]; app.agentSessions = [s]
        let runtime = AgentRuntime(session: s); app.agentRuntimes[s.id] = runtime
        runtime.isResponding = true
        #expect(!app.setAgentProjectArchived(id: p.id, archived: true, now: now))
        runtime.isResponding = false; runtime.input = "unsent"
        #expect(!app.canArchiveAgentProject(p))
        runtime.input = ""; app.activeAgentSessionID = s.id
        #expect(!app.canArchiveAgentProject(p))
        app.activeAgentSessionID = nil
        #expect(app.canArchiveAgentProject(p))
        let (peer, peerDefaults, peerSuite) = try fixture()
        defer { peerDefaults.removePersistentDomain(forName: peerSuite) }
        peer.agentProjects = [p]; peer.agentSessions = [s]; peer.activeAgentSessionID = s.id
        EditorAppStateRegistry.shared.register(peer)
        defer { EditorAppStateRegistry.shared.unregister(peer) }
        #expect(!app.canArchiveAgentProject(p))
    }

    @Test("保存失败保持项目和会话原样，并可重试")
    func failedSaveDoesNotHideProjects() throws {
        let (app, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = project(age: AgentProjectArchiving.inactivityInterval * 2)
        app.agentProjects = [p]; app.agentSessions = [session(p, date: p.createdAt)]
        app.projectArchivingCatalogUpdater = { _ in nil }
        #expect(!app.setAgentProjectArchived(id: p.id, archived: true, now: now))
        #expect(app.projectArchivingSaveFailed)
        #expect(app.agentProjects == [p])
        app.projectArchivingCatalogUpdater = { [weak app] project in
            app?.agentProjects.map { $0.id == project.id ? project : $0 }
        }
        #expect(app.setAgentProjectArchived(id: p.id, archived: true, now: now))
        #expect(!app.projectArchivingSaveFailed)
    }

    @Test("关闭自动归档可持久化；目录未加载时不会提前归档")
    func toggleAndCatalogGate() throws {
        let (app, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AgentProjectArchiving.isEnabled(defaults: defaults))
        app.projectAutoArchiveEnabled = false
        #expect(!AgentProjectArchiving.isEnabled(defaults: defaults))
        let p = project(age: AgentProjectArchiving.inactivityInterval * 2)
        app.agentProjects = [p]
        app.archiveInactiveAgentProjects(now: now)
        #expect(!app.agentProjects[0].isArchived)
        let unloaded = AppState(sessionManagementDefaults: defaults, loadSessionCatalog: false)
        unloaded.agentProjects = [p]
        #expect(!unloaded.canArchiveAgentProject(p))
        defaults.set(true, forKey: AgentProjectArchiving.enabledKey)
        unloaded.archiveInactiveAgentProjects(now: now)
        #expect(!unloaded.agentProjects[0].isArchived)
    }

    @Test("重新打开已有项目记录活跃时间并恢复项目，不新建重复项目")
    func reopeningRestoresSameProject() throws {
        let (app, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        var p = project(age: AgentProjectArchiving.inactivityInterval * 2); p.archivedAt = p.updatedAt
        app.agentProjects = [p]
        let path = try #require(p.primaryFolderPath)
        let restored = try #require(app.ensureAgentProject(forFolderPath: path))
        #expect(restored.id == p.id)
        #expect(!restored.isArchived)
        #expect(restored.lastActivityAt != nil)
        #expect(app.agentProjects.count == 1)
    }

    @Test("隐藏项目也隐藏其置顶会话，其他项目及未归属会话继续可见")
    func allSidebarEntryPointsRespectArchive() {
        var p = project(age: 0); p.archivedAt = now
        let other = project(age: 0, name: "visible")
        var pinned = session(p, date: now); pinned.pinnedAt = now
        let visible = session(other, date: now)
        let rows = AgentProjectArchiving.visibleSessions([pinned, visible], projects: [p, other])
        #expect(rows == [visible])
        #expect(AgentSessionSearch.titleResults(sessions: [pinned, visible], projects: [p, other], query: "fixture").isEmpty)
        #expect(AgentRecentSessionEdgeRailLogic.recentItems(from: [pinned, visible], hiddenWorkspaceKeys: [],
            limit: 10, projects: [p, other]).map(\.session.id) == [visible.id])
    }

    @Test("旧窗口归档不会覆盖其他窗口的新项目、重命名和文件夹编辑")
    func staleWindowPreservesNewCatalogMetadata() throws {
        let old = project(age: AgentProjectArchiving.inactivityInterval * 2)
        var renamed = old; renamed.displayName = "renamed"; renamed.folderPaths.append("/private/tmp/added")
        let added = project(age: 0, name: "new")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-merge-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode([renamed, added]).write(to: url, options: .atomic)
        var archived = old; archived.archivedAt = now
        let saved = try #require(AgentProjectStore.updateArchiving(archived, at: url))
        #expect(saved[0].displayName == renamed.displayName)
        #expect(saved[0].folderPaths == renamed.folderPaths)
        #expect(saved[0].archivedAt == now)
        #expect(saved[1] == added)
        let disk = try JSONDecoder().decode([AgentProject].self, from: Data(contentsOf: url))
        #expect(disk == saved)
        var reopened = renamed; reopened.lastActivityAt = now
        try JSONEncoder().encode([reopened, added]).write(to: url, options: .atomic)
        #expect(AgentProjectStore.updateArchiving(archived, at: url) == nil)
        #expect(try JSONDecoder().decode([AgentProject].self, from: Data(contentsOf: url)) == [reopened, added])
    }
}
