import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentSessionSearchTests {
    private func session(
        title: String = "网关扩容",
        workspacePath: String? = "/Users/rocky/Sites/tokenhub",
        messages: [AgentMessage] = []
    ) -> AgentSession {
        AgentSession(
            title: title,
            workspaceRootPath: workspacePath,
            messages: messages
        )
    }

    private func conversation() -> [AgentMessage] {
        [
            AgentMessage(role: .user, content: "帮我评估并压测 500 RPS"),
            AgentMessage(role: .assistant, content: "扩容完成：2 个网关副本分别跑在 worker-01 和 worker-02。"),
            AgentMessage(role: .tool, content: "kubectl output: replicas=2 ready=2"),
            AgentMessage(role: .user, content: "保留上游错误详情"),
        ]
    }

    // MARK: Matching

    @Test("matching ignores case and accents but is a literal substring test")
    func matchingRules() {
        #expect(AgentSessionSearch.matches("Gateway replicas", query: "gateway"))
        #expect(AgentSessionSearch.matches("网关扩容完成", query: "网关"))
        #expect(!AgentSessionSearch.matches("gateway", query: "gatew.*y"), "regex must not be interpreted")
        #expect(!AgentSessionSearch.matches("anything", query: "   "))
    }

    @Test("空查询给的是最近会话：按最后更新时间倒序，不分项目")
    func emptyQueryListsRecentSessionsAcrossProjects() throws {
        var older = session(title: "旧会话", workspacePath: "/Users/rocky/Sites/a", messages: conversation())
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = session(title: "新会话", workspacePath: "/Users/rocky/Sites/b", messages: conversation())
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        var middle = session(title: "中间会话", workspacePath: nil, messages: conversation())
        middle.updatedAt = Date(timeIntervalSince1970: 1_500)

        let results = AgentSessionSearch.recentSessions([older, newer, middle])
        let titles = results.compactMap { result -> String? in
            guard case .session(let value) = result else { return nil }
            return value.title
        }
        #expect(titles == ["新会话", "中间会话", "旧会话"])
        // 项目不参与：面板里默认就是一条平铺的最近会话流
        #expect(results.allSatisfy { if case .project = $0 { return false } else { return true } })
    }

    @Test("最近会话有条数上限，不把整份历史铺进面板")
    func recentSessionsAreCapped() throws {
        let sessions = (0..<80).map { index -> AgentSession in
            var value = session(title: "会话 \(index)", messages: conversation())
            value.updatedAt = Date(timeIntervalSince1970: TimeInterval(index))
            return value
        }
        #expect(AgentSessionSearch.recentSessions(sessions).count == AgentSessionSearch.Limits.recentSessions)
        #expect(AgentSessionSearch.recentSessions(sessions, limit: 5).count == 5)
    }

    @Test("title results include matching projects before matching chats")
    func titleResultsIncludeProjectsAndChats() {
        let project = AgentProject(
            displayName: "支付平台",
            folderPaths: ["/tmp/payment"],
            createdAt: .distantPast,
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        let matchingChat = AgentSession(
            title: "支付接口排障",
            workspaceRootPath: "/tmp/payment",
            createdAt: .distantPast,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10),
            messages: conversation()
        )
        let results = AgentSessionSearch.titleResults(
            sessions: [matchingChat, session(title: "无关会话")],
            projects: [project],
            query: "支付"
        )

        #expect(results == [.project(project), .session(matchingChat)])
    }

    @Test("搜索排除空壳但保留有内容的默认标题和归档会话", arguments: [false, true])
    func emptyConversationsAreExcluded(withQuery: Bool) {
        let empty = session(title: "新对话")
        let renamedEmpty = session(title: "新对话：已改名但没发消息")
        let systemOnly = session(title: "新对话", messages: [AgentMessage(role: .system, content: "配置")])
        var populated = session(title: "新对话", messages: conversation())
        populated.archivedAt = .now
        let candidates = [empty, renamedEmpty, systemOnly, populated]
        let results = withQuery
            ? AgentSessionSearch.titleResults(sessions: candidates, projects: [], query: "新对话")
            : AgentSessionSearch.recentSessions(candidates)
        #expect(results == [.session(populated)])
    }

    @Test("搜索用元数据识别未加载的历史，不把真实历史隐藏", arguments: [false, true])
    func metadataOnlyHistoryIsPreserved(withQuery: Bool) {
        let history = session(title: "新对话")
        let empty = session(title: "新对话")
        let loadedEmpty = session(title: "新对话")
        let candidates = [empty, loadedEmpty, history]
        let isMetadataOnly: (UUID) -> Bool = { $0 != loadedEmpty.id }
        // 即使旧元数据残留，已加载会话也以当前正文为准。
        let hasUserMessage: (UUID) -> Bool = { $0 == history.id || $0 == loadedEmpty.id }
        let results = withQuery
            ? AgentSessionSearch.titleResults(
                sessions: candidates, projects: [], query: "新对话",
                isMetadataOnly: isMetadataOnly, metadataOnlyHasUserMessage: hasUserMessage
            )
            : AgentSessionSearch.recentSessions(
                candidates, isMetadataOnly: isMetadataOnly, metadataOnlyHasUserMessage: hasUserMessage
            )
        #expect(results == [.session(history)])
    }

    @Test("空壳不占最近会话额度，全空时返回空列表")
    func emptyConversationsDoNotConsumeLimit() {
        var history = session(messages: conversation())
        history.updatedAt = .distantPast
        let empty = session()
        #expect(AgentSessionSearch.recentSessions([empty, history], limit: 1) == [.session(history)])
        #expect(AgentSessionSearch.recentSessions([empty]).isEmpty)
        #expect(AgentSessionSearch.titleResults(sessions: [empty], projects: [], query: empty.title).isEmpty)
    }

    @Test("仅发送图片的会话仍可搜索", arguments: [false, true])
    func attachmentOnlyConversationIsPreserved(withQuery: Bool) {
        let image = AgentImageAttachment(mimeType: "image/png", dataBase64: "", filePath: "/tmp/search-fixture.png")
        var message = AgentMessage(role: .user, content: "")
        message.images = [image]
        let value = session(title: "新对话", messages: [message])
        let results = withQuery
            ? AgentSessionSearch.titleResults(sessions: [value], projects: [], query: "新对话")
            : AgentSessionSearch.recentSessions([value])
        #expect(results == [.session(value)])
    }

    @Test("没有对话的项目仍可搜索")
    func projectsWithoutConversationsRemainSearchable() {
        let project = AgentProject(displayName: "空项目", folderPaths: ["/tmp/empty-project"])
        #expect(AgentSessionSearch.titleResults(
            sessions: [session(title: "空项目")], projects: [project], query: "空项目"
        ) == [.project(project)])
    }

    @Test("sidebar reveal requests remain one-shot even for the same target")
    func sidebarRevealRequestsAreUnique() {
        let sessionID = UUID()
        let first = AgentSidebarRevealRequest(target: .session(sessionID))
        let second = AgentSidebarRevealRequest(target: .session(sessionID))

        #expect(first.target == .session(sessionID))
        #expect(first.id != second.id)
    }

    @Test("only user and assistant turns are searched")
    func toolOutputIsNotSearched() {
        let found = AgentSessionSearch.matches(
            in: session(messages: conversation()),
            query: "kubectl output"
        )

        // Tool payloads are bulky and machine-generated — not what someone
        // means by "what did we say about X".
        #expect(found.isEmpty)
    }

    @Test("a hit reports where it is and quotes the surrounding turns")
    func hitCarriesLocationAndContext() throws {
        let found = AgentSessionSearch.matches(
            in: session(messages: conversation()),
            query: "worker-01"
        )
        let match = try #require(found.first)

        #expect(match.sessionTitle == "网关扩容")
        #expect(match.messageIndex == 2)
        #expect(match.role == "assistant")
        // The question that prompted the answer is usually the useful half.
        #expect(match.excerpt.contains("500 RPS"))
        #expect(match.excerpt.contains("→ "), "the hit itself must be marked")
    }

    @Test("newest matches come first and per-session results are capped")
    func matchesAreNewestFirstAndCapped() throws {
        let many = (1...10).map { AgentMessage(role: .user, content: "扩容第 \($0) 次") }
        let found = AgentSessionSearch.matches(in: session(messages: many), query: "扩容", limit: 3)

        #expect(found.count == 3)
        // One chatty conversation must not crowd out every other result.
        #expect(found[0].messageIndex > found[1].messageIndex)
    }

    // MARK: Excerpt clamping

    @Test("long messages are clamped so results stay small")
    func excerptsAreClamped() {
        let huge = String(repeating: "词", count: 5_000)
        let clamped = AgentSessionSearch.clamped(huge)

        #expect(clamped.count <= AgentSessionSearch.Limits.excerptCharacters + 1)
        #expect(clamped.hasSuffix("…"))
    }

    // MARK: Workspace scoping

    @Test("scoping keeps the search inside the current workspace")
    func workspaceScoping() {
        let here = session(workspacePath: "/Users/rocky/Sites/tokenhub")
        let elsewhere = session(workspacePath: "/Users/rocky/Sites/other")

        #expect(AgentSessionSearch.belongsToWorkspace(here, groupKey: "/Users/rocky/Sites/tokenhub"))
        #expect(!AgentSessionSearch.belongsToWorkspace(elsewhere, groupKey: "/Users/rocky/Sites/tokenhub"))
        // No key means an unscoped (approved) search.
        #expect(AgentSessionSearch.belongsToWorkspace(elsewhere, groupKey: nil))
    }

    @Test("a worktree conversation still counts as part of its project")
    func worktreeSessionsStayWithTheirProject() {
        var worktree = session(workspacePath: "/Users/rocky/Sites/tokenhub-wt-a")
        worktree.sidebarWorkspaceRootPath = "/Users/rocky/Sites/tokenhub"

        // The sidebar groups it under tokenhub, so "this workspace" must too.
        #expect(AgentSessionSearch.belongsToWorkspace(worktree, groupKey: "/Users/rocky/Sites/tokenhub"))
    }

    // MARK: Approval boundary

    @Test("searching every workspace is write-tier so the user approves it")
    func crossWorkspaceSearchRequiresApproval() {
        let scoped = AgentToolRegistry.risk(
            for: "search_sessions",
            arguments: ["query": .string("网关")]
        )
        let everywhere = AgentToolRegistry.risk(
            for: "search_sessions",
            arguments: ["query": .string("网关"), "scope": .string("all")]
        )

        #expect(scoped == .read)
        // Other projects' conversations are the user's call, not the model's.
        #expect(everywhere == .write)
    }

    @Test("the tool is registered with a required query")
    func toolRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "search_sessions")

        #expect(descriptor != nil)
        #expect(descriptor?.parameters.first { $0.name == "query" }?.required == true)
        #expect(descriptor?.parameters.contains { $0.name == "scope" } == true)
    }

    // MARK: Rendering

    @Test("an empty result explains what was searched instead of going silent")
    func emptyResultIsInformative() {
        let payload = AgentSessionSearch.renderPayload(
            [],
            query: "从未提过的词",
            scopeDescription: "this workspace",
            sessionsScanned: 12,
            wasTruncated: false
        )

        #expect(payload.contains("No matches"))
        #expect(payload.contains("12"))
    }

    @Test("results carry session ids and admit when the scan was capped")
    func payloadCarriesIDsAndTruncationNotice() throws {
        let found = AgentSessionSearch.matches(
            in: session(messages: conversation()),
            query: "worker-01"
        )
        let match = try #require(found.first)
        let payload = AgentSessionSearch.renderPayload(
            found,
            query: "worker-01",
            scopeDescription: "this workspace",
            sessionsScanned: 40,
            wasTruncated: true
        )

        #expect(payload.contains(match.sessionID.uuidString))
        // Silently searching only part of the history would read as "not found".
        #expect(payload.contains("capped"))
        // And it must not promise a retrieval path that does not exist.
        #expect(!payload.lowercased().contains("reader subagent"))
    }
}
