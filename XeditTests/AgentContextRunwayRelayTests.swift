//
//  AgentContextRunwayRelayTests.swift
//  WillDeepTests
//
//  跑道交接后压缩失败时带着整份交接开新会话接力。
//

import Foundation
import Testing
import WillDeepCore
@testable import WillDeep

@Suite("压缩失败时接力到新会话", .serialized)
@MainActor
struct AgentContextRunwayRelayTests {
    private static let handover = """
    PAUSE: context runway, not completion
    DONE: parser rewritten; `swift test` 12/12
    ANCHORS: branch feat/parser, Sources/Parser.swift
    REMAINING: wire the --strict flag
    NEXT PROMPT: Add --strict in Sources/CLI.swift, anchored on Parser.parse(strict:)
    """

    @MainActor private struct Fixture {
        let app: AppState
        let source: AgentRuntime
        let defaults: UserDefaults
        let suite: String
        let root: URL
        func cleanup() {
            for id in app.agentRuntimes.keys { AgentSessionStore.delete(id: id) }
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Relay fixture cleanup failed: \(error)") }
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runway-relay-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "runway-relay-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let session = app.startNewAgentSession(inWorkspaceAt: root.path)
        let source = try #require(app.runtime(for: session.id))
        source.session.title = "解析器重写"
        source.session.titleIsUserSet = true
        source.messages = [
            .init(role: .user, content: "重写解析器，不要发布"),
            .init(role: .assistant, content: Self.handover),
        ]
        source.approvalMode = .fullAccess
        source.executionAgent = .claudeCode
        source.sessionModelOverride = "kimi-k3"
        source.contextRunwayResumeCount = 1
        return .init(app: app, source: source, defaults: defaults, suite: suite, root: root)
    }

    @Test("接力会话带整份交接、继承设置、续跑次数接着数，原会话留一行说明")
    func relayCarriesHandoverAndSettings() throws {
        let f = try fixture(); defer { f.cleanup() }
        let (relay, prompt) = try #require(f.app.prepareContextRunwayRelayAfterCompressionFailure(for: f.source))

        #expect(relay.id != f.source.id)
        #expect(prompt.contains("ANCHORS: branch feat/parser, Sources/Parser.swift"))
        #expect(prompt.contains("DONE: parser rewritten"))
        #expect(prompt.contains("could not be compressed"))
        #expect(relay.workspaceRootPath == f.source.workspaceRootPath)
        #expect(relay.approvalMode == .fullAccess)
        #expect(relay.executionAgent == .claudeCode)
        #expect(relay.sessionModelOverride == "kimi-k3")
        #expect(relay.contextRunwayResumeCount == 2)
        #expect(relay.session.title.contains("解析器重写"))
        #expect(relay.session.titleIsUserSet)
        // 原会话正在看，焦点跟过去。
        #expect(f.app.activeAgentSessionID == relay.id)

        let notice = try #require(f.source.messages.last)
        #expect(notice.transcriptEvent == .responseStopped)
        #expect(notice.content.contains(relay.session.title))
    }

    @Test("用户在看别的会话时接力不抢焦点")
    func relayDoesNotStealFocus() throws {
        let f = try fixture(); defer { f.cleanup() }
        let other = f.app.startNewAgentSession(inWorkspaceAt: f.root.path)
        #expect(f.app.activeAgentSessionID == other.id)

        let (relay, _) = try #require(f.app.prepareContextRunwayRelayAfterCompressionFailure(for: f.source))
        #expect(f.app.activeAgentSessionID == other.id)
        #expect(f.app.agentRuntimes[relay.id] != nil)
    }

    @Test("Goal、排队消息、找不到交接时不接力")
    func relayRefusals() throws {
        let f = try fixture(); defer { f.cleanup() }
        let sessionCount = f.app.agentSessions.count

        f.source.interactionMode = .goal
        #expect(f.app.prepareContextRunwayRelayAfterCompressionFailure(for: f.source) == nil)
        f.source.interactionMode = .normal

        f.source.queuedMessages = [AgentQueuedMessage(text: "换个方向", images: [])]
        #expect(f.app.prepareContextRunwayRelayAfterCompressionFailure(for: f.source) == nil)
        f.source.queuedMessages = []

        f.source.messages.append(.init(role: .assistant, content: "普通回复，没有交接"))
        #expect(f.app.prepareContextRunwayRelayAfterCompressionFailure(for: f.source) == nil)

        #expect(f.app.agentSessions.count == sessionCount)
        #expect(!f.source.messages.contains { $0.transcriptEvent != nil })
    }

    @Test("子会话不能接力成失去只读边界的顶层会话")
    func childCannotRelayToUnrestrictedSession() throws {
        let f = try fixture(); defer { f.cleanup() }
        let sessionCount = f.app.agentSessions.count
        f.source.session.parentSessionID = UUID()

        #expect(f.app.prepareContextRunwayRelayAfterCompressionFailure(for: f.source) == nil)
        #expect(f.app.makeContextRunwayRelaySession(from: f.source, makeActive: false) == nil)
        #expect(f.app.agentSessions.count == sessionCount)
    }

    @Test("远程工作区不接力")
    func remoteWorkspaceIsNotRelayed() throws {
        let f = try fixture(); defer { f.cleanup() }
        let sessionCount = f.app.agentSessions.count
        let remote = AgentRuntime(session: AgentSession(
            workspaceRootPath: "/srv/app",
            workspaceLocation: .remote(runtimeID: UUID(), path: "/srv/app")
        ))
        #expect(f.app.makeContextRunwayRelaySession(from: remote, makeActive: false) == nil)
        #expect(f.app.agentSessions.count == sessionCount)
    }

    @Test("取交接：只认最后一条 assistant 回复，进度块剥掉、NEXT PROMPT 保留")
    func latestHandoverExtraction() {
        let withProgress = Self.handover + "\n\n```progress\n- [x] 1\n```"
        let found = AppState.latestContextRunwayHandover(in: [.init(role: .assistant, content: withProgress)])
        #expect(found?.contains("NEXT PROMPT: Add --strict") == true)
        #expect(found?.contains("```progress") == false)

        let superseded: [AgentMessage] = [
            .init(role: .assistant, content: Self.handover),
            .init(role: .user, content: "继续"),
            .init(role: .assistant, content: "已完成 --strict"),
        ]
        #expect(AppState.latestContextRunwayHandover(in: superseded) == nil)
    }
}
