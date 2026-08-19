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
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let results = AgentSessionSearch.titleResults(
            sessions: [matchingChat, session(title: "无关会话")],
            projects: [project],
            query: "支付"
        )

        #expect(results == [.project(project), .session(matchingChat)])
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
