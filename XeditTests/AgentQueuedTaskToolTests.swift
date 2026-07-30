//
//  AgentQueuedTaskToolTests.swift
//  WillDeepTests
//
//  Split from AgentToolIntegrationTests.swift to keep files under the
//  repository file-size limit. Session queue inspection tools and slash
//  command interaction.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentQueuedTaskToolTests {
    @Test("list_queued_tasks reports session queue and project build guard queue")
    @MainActor
    func testListQueuedTasksReportsSessionAndBuildQueues() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepQueuedTaskToolTests-\(UUID().uuidString)", isDirectory: true)
        let localStateDirectory = workspace.appendingPathComponent(".codex-build", isDirectory: true)
        let queueDirectory = workspace.appendingPathComponent("shared-build-queue", isDirectory: true)
        try FileManager.default.createDirectory(at: localStateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let coordinationData = try JSONSerialization.data(
            withJSONObject: ["queue_dir": queueDirectory.path],
            options: [.prettyPrinted]
        )
        try coordinationData.write(
            to: localStateDirectory.appendingPathComponent("coordination.json", isDirectory: false),
            options: [.atomic]
        )

        let buildEntry: [String: Any] = [
            "id": "queued-build-1",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "name": "xedit-tests",
            "kind": "xcode-test",
            "fingerprint": "abcdef1234567890",
            "command": ["xcodebuild", "test", "-scheme", "Xedit"],
            "created_at": Date().timeIntervalSince1970,
            "created_at_iso": ISO8601DateFormatter().string(from: Date())
        ]
        let buildData = try JSONSerialization.data(withJSONObject: buildEntry, options: [.prettyPrinted])
        try buildData.write(to: queueDirectory.appendingPathComponent("queued-build-1.json"))

        let runtimeID = UUID()
        let mediaRegistry = AgentMediaTaskRegistry(
            fileURL: workspace.appendingPathComponent("media-tasks.json", isDirectory: false)
        )
        let mediaTask = mediaRegistry.create(
            provider: .someIM,
            kind: .imageGeneration,
            title: "Queued illustration",
            runtimeID: runtimeID,
            status: .processing
        )
        let queuedMessage = AgentQueuedMessage(text: "用户后续还要继续修发布文案")
        let queuedDispatch = AgentQueuedDispatchSnapshot(
            userMessageID: UUID(),
            text: "provider slot 等待中的下一步",
            imageCount: 0,
            textAttachmentCount: 1,
            skillCount: 0,
            providerID: "some.im",
            enqueuedAt: Date().addingTimeInterval(-12)
        )
        let context = AgentToolContext(
            rootDirectory: workspace,
            runtimeID: runtimeID,
            mediaTaskRegistry: mediaRegistry,
            sessionQueueSnapshotProvider: {
                AgentSessionQueueSnapshot(
                    queuedMessages: [queuedMessage],
                    pendingDispatches: [queuedDispatch]
                )
            }
        )

        let result = try await AgentToolRunner.run(
            name: "list_queued_tasks",
            arguments: [:],
            context: context
        )

        #expect(result.summary.contains("queued user work: 1"))
        #expect(result.payload.contains("defer_heavy_actions_recommended: true"))
        #expect(result.payload.contains("用户后续还要继续修发布文案"))
        #expect(result.payload.contains("provider=some.im"))
        #expect(result.payload.contains(mediaTask.displayHandle))
        #expect(result.payload.contains("xedit-tests"))
        #expect(result.payload.contains("\"project_build_guard_queue\""))
    }

    @Test("list_workspace_sessions returns current workspace session snapshots")
    @MainActor
    func testListWorkspaceSessionsReturnsSnapshots() async throws {
        let sessionID = UUID()
        let context = AgentToolContext(
            rootDirectory: nil,
            workspaceSessionsSnapshotProvider: {
                [
                    AgentWorkspaceSessionSnapshot(
                        id: sessionID,
                        title: "修复登录流程",
                        workspaceRootPath: "/tmp/WillDeepProject",
                        workspaceDisplayName: "WillDeepProject",
                        presentationScope: .dispatchBoard,
                        isActive: true,
                        isPinned: true,
                        isArchived: false,
                        isResponding: false,
                        isAwaitingProviderSlot: true,
                        queuedMessageCount: 2,
                        updatedAt: Date(timeIntervalSince1970: 1_800),
                        lastActivityAt: Date(timeIntervalSince1970: 1_700),
                        interactionMode: .goal,
                        approvalMode: .smart,
                        executionAgent: .willDeep,
                        titleIsUserSet: true,
                        goalStatement: "完成登录流程修复",
                        goalCompletedItemCount: 1,
                        goalTotalItemCount: 2,
                        goalIsComplete: false,
                        goalPlanningPhase: .executing,
                        dispatchParentProjectID: nil,
                        dispatchTaskID: nil,
                        isDispatchProject: true,
                        isDispatchPaused: false
                    )
                ]
            }
        )

        let result = try await AgentToolRunner.run(
            name: "list_workspace_sessions",
            arguments: [:],
            context: context
        )

        #expect(result.summary == "1 workspace session")
        #expect(result.payload.contains("修复登录流程"))
        #expect(result.payload.contains("provider-queued"))
        #expect(result.payload.contains("queued_messages=2"))
        #expect(result.payload.contains("\"interaction_mode\":\"goal\""))
        #expect(result.payload.contains("\"goal_statement\":\"完成登录流程修复\""))
        #expect(result.payload.contains("\"goal_completed_item_count\":1"))
        #expect(result.payload.contains("\"is_dispatch_project\":true"))
    }

    @Test("suggest_session_title returns flash-backed suggestion snapshot")
    @MainActor
    func testSuggestSessionTitleReturnsSnapshot() async throws {
        let context = AgentToolContext(
            rootDirectory: nil,
            sessionTitleSuggestionProvider: {
                AgentSessionTitleSuggestionSnapshot(
                    currentTitle: "旧标题",
                    suggestedTitle: "整理发布队列",
                    modelID: "someim-auto-flash"
                )
            }
        )

        let result = try await AgentToolRunner.run(
            name: "suggest_session_title",
            arguments: [:],
            context: context
        )

        #expect(result.summary.contains("整理发布队列"))
        #expect(result.payload.contains("\"current_title\":\"旧标题\""))
        #expect(result.payload.contains("\"suggested_title\":\"整理发布队列\""))
        #expect(result.payload.contains("\"rename_recommended\":true"))
        #expect(result.payload.contains("someim-auto-flash"))
    }
}

@Suite
struct SlashCommandInteractionTests {
    @Test("slash workflow metadata distinguishes required optional and immediate commands")
    @MainActor
    func argumentModes() {
        let appState = AppState()
        let commands = SlashCommand.builtIn(state: appState)

        let research = commands.first { $0.title == "/research" }
        let bugHunt = commands.first { $0.title == "/bug-hunt" }
        let clear = commands.first { $0.title == "/clear" }

        #expect(research?.argumentMode.requiresArguments == true)
        #expect(research?.argumentMode.placeholder == "research question…")
        #expect(bugHunt?.argumentMode.acceptsArguments == true)
        #expect(bugHunt?.argumentMode.requiresArguments == false)
        #expect(clear?.argumentMode == SlashCommandArgumentMode.none)
    }

    @Test("slash invocation parser separates the exact command from its arguments")
    func invocationParsing() throws {
        let command = SlashCommand(
            id: "research",
            title: "/research",
            subtitle: "Research",
            symbol: "magnifyingglass",
            argumentMode: .required(placeholder: "question")
        ) { _ in }

        let withArguments = try #require(
            SlashCommand.invocation(in: "/research   cache behavior", commands: [command])
        )
        #expect(withArguments.command.id == "research")
        #expect(withArguments.args == "cache behavior")

        let staged = try #require(
            SlashCommand.invocation(in: "/research ", commands: [command])
        )
        #expect(staged.args.isEmpty)
        #expect(SlashCommand.invocation(in: "/researcher topic", commands: [command]) == nil)
        #expect(SlashCommand.invocation(in: "please /research topic", commands: [command]) == nil)
    }
}
