//
//  AgentToolCallGroupingTests.swift
//  WillDeepTests
//
//  Split from AgentToolIntegrationTests.swift to keep files under the
//  repository file-size limit. Tool-call grouping, live activity
//  presentation, approval waiters, and approval notice copy.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentToolCallGroupingPresentationTests {
    private func makeCall(_ name: String) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: name,
            arguments: [:],
            risk: .read,
            status: .running
        )
    }

    @Test("delegated agent activity labels name the target tool")
    func delegatedAgentActivityLabelsNameTargetTool() {
        #expect(AgentToolKind.of(makeCall("spawn_agent")).delegatedActivityLabel(progress: nil) == "委派给子代理")
        #expect(AgentToolKind.of(makeCall("claude_code")).delegatedActivityLabel(progress: nil) == "委派给 Claude Code")
        #expect(AgentToolKind.of(makeCall("codex_cli")).delegatedActivityLabel(progress: nil) == "委派给 Codex")
        #expect(AgentToolKind.of(makeCall("cursor_agent")).delegatedActivityLabel(progress: nil) == "委派给 Cursor Agent")
        #expect(AgentToolKind.of(makeCall("cline_cli")).delegatedActivityLabel(progress: nil) == "委派给 Cline")
        #expect(
            AgentToolKind.of(makeCall("spawn_agent")).delegatedActivityLabel(progress: " 第 5/12 轮 · 11 次工具 ")
                == "委派给子代理 · 第 5/12 轮 · 11 次工具"
        )
    }
}

extension WillDeepTests {
    // MARK: - Tool call grouping

    private func makeCall(
        _ name: String,
        status: AgentToolCallStatus = .succeeded,
        arguments: [String: AgentJSONValue] = [:],
        messageID: UUID = UUID()
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: messageID,
            externalID: UUID().uuidString,
            toolName: name,
            arguments: arguments,
            risk: .read,
            status: status
        )
    }

    @Test("AgentToolCallGrouping merges consecutive same-kind calls")
    func testToolCallGroupingMergesAdjacent() {
        let calls = [
            makeCall("run_command"),
            makeCall("run_command"),
            makeCall("run_command")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .runCommand)
        #expect(segments[0].count == 3)
        #expect(segments[0].kind.groupTitle(3) == "已运行 3 条命令")
    }

    @Test("provider status headlines become localized activity phases")
    func testProviderStatusHeadlinePresentation() {
        let planning = AgentActivityHeadlinePresentation.make(
            from: "Planning font size clamping implementation"
        )
        let verifying = AgentActivityHeadlinePresentation.make(
            from: "Verifying activity timeline snapshots"
        )

        #expect(planning?.title == L10n.AgentActivity.planning)
        #expect(planning?.systemImage == "list.bullet.clipboard")
        #expect(verifying?.title == L10n.AgentActivity.verifying)
        #expect(AgentActivityHeadlinePresentation.make(from: "Planning is useful for every project.") == nil)
        #expect(AgentActivityHeadlinePresentation.make(from: "普通的中文回答正文") == nil)
    }

    @Test("live tool rows show useful file context without exposing command bodies")
    func testLiveToolRowPresentationKeepsCommandPrivate() {
        let file = AgentToolActivityRowPresentation(call: makeCall(
            "read_file",
            arguments: ["path": .string("/tmp/Xedit/AgentToolCallGrouping.swift")]
        ))
        let command = AgentToolActivityRowPresentation(call: makeCall(
            "run_command",
            arguments: [
                "cwd": .string("/tmp/Xedit"),
                "command": .string("deploy --token super-sensitive-value"),
            ]
        ))

        #expect(file.title == "已读取文件")
        #expect(file.detail == "AgentToolCallGrouping.swift")
        #expect(command.title == "已运行命令")
        #expect(command.detail == "Xedit 工作区")
        #expect(command.detail?.contains("super-sensitive-value") == false)
    }

    @Test("live activity timeline keeps recent rows and never hides approvals")
    func testLiveActivityTimelineBoundsCompletedRows() {
        var calls = (0..<12).map { index in
            makeCall(
                "read_file",
                arguments: ["path": .string("file-\(index).swift")]
            )
        }
        let approval = makeCall("run_command", status: .pendingApproval)
        calls.insert(approval, at: 1)

        let presentation = AgentLiveActivityTimelinePresentation(
            calls: calls,
            maximumDetailedRows: 4
        )

        #expect(presentation.visibleCalls.count == 5)
        #expect(presentation.visibleCalls.contains(where: { $0.id == approval.id }))
        #expect(presentation.hiddenOperationCount == 8)
        #expect(presentation.visibleCalls.suffix(4).map(\.id) == calls.suffix(4).map(\.id))
    }

    @Test("AgentToolCallGrouping merges visible terminal operations")
    func testToolCallGroupingMergesVisibleTerminalOperations() {
        let calls = [
            makeCall("terminal_send_command"),
            makeCall("terminal_snapshot"),
            makeCall("terminal_send_control")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .terminalOperation)
        #expect(segments[0].count == 3)
        #expect(segments[0].title == "已执行 3 次终端操作")
    }

    @Test("successful terminal operations hide the duplicate live detail card")
    func testSuccessfulTerminalOperationsHideFromLivePresentation() {
        let calls = [
            makeCall("terminal_send_command"),
            makeCall("terminal_snapshot")
        ]

        #expect(AgentToolCallGrouping.livePresentationSegments(calls).isEmpty)
    }

    @Test("non-successful terminal operations keep the live detail card")
    func testUnsettledOrFailedTerminalOperationsStayInLivePresentation() {
        for status in [
            AgentToolCallStatus.running,
            .pendingApproval,
            .awaitingConfirm,
            .awaitingUserAnswer,
            .failed,
            .denied
        ] {
            let segments = AgentToolCallGrouping.livePresentationSegments([
                makeCall("terminal_send_command", status: status)
            ])
            #expect(segments.count == 1)
            #expect(segments[0].kind == .terminalOperation)
        }
    }

    @Test("AgentToolCallGrouping splits when kind changes")
    func testToolCallGroupingSplitsOnKindChange() {
        let calls = [
            makeCall("run_command"),
            makeCall("read_file"),
            makeCall("grep_files"),
            makeCall("run_command")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .runCommand)
        #expect(segments[0].count == 1)
        #expect(segments[1].kind == .fileExploration)
        #expect(segments[1].count == 2)
        #expect(segments[2].kind == .runCommand)
        #expect(segments[2].count == 1)
        #expect(segments[1].title == "已读取 1 个文件 · 已搜索代码")
    }

    @Test("live presentation coalesces commands split by other tool kinds")
    func testLivePresentationCoalescesCommandsAcrossSegments() {
        let calls = [
            makeCall("run_command"),
            makeCall("read_file"),
            makeCall("run_command"),
            makeCall("grep_files"),
            makeCall("run_command")
        ]

        let segments = AgentToolCallGrouping.livePresentationSegments(calls)

        #expect(segments.count == 3)
        #expect(segments[0].kind == .runCommand)
        #expect(segments[0].count == 3)
        #expect(segments[1].kind == .fileExploration)
        #expect(segments[2].kind == .fileExploration)
    }

    @Test("active turn combines commands from provider-split assistant messages")
    func testActiveTurnToolCallsCombineAcrossAssistantMessages() throws {
        let firstAssistantID = UUID()
        let secondAssistantID = UUID()
        let thirdAssistantID = UUID()
        let firstRawCalls = [
            AgentMessageToolCall(externalID: "first-1", toolName: "run_command", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "first-2", toolName: "run_command", argumentsJSON: "{}")
        ]
        let messages = [
            AgentMessage(role: .user, content: "检查一下"),
            AgentMessage(id: firstAssistantID, role: .assistant, content: "", toolCalls: firstRawCalls),
            AgentMessage(
                role: .system,
                content: "模型已切换",
                transcriptEvent: .modelChanged
            ),
            AgentMessage(
                id: secondAssistantID,
                role: .assistant,
                content: "继续检查。",
                toolCalls: [
                    AgentMessageToolCall(externalID: "second-1", toolName: "run_command", argumentsJSON: "{}")
                ]
            ),
            AgentMessage(
                id: thirdAssistantID,
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentMessageToolCall(externalID: "third-1", toolName: "run_command", argumentsJSON: "{}")
                ]
            )
        ]
        let calls = [
            makeCall("run_command", messageID: firstAssistantID),
            makeCall("run_command", messageID: firstAssistantID),
            makeCall("run_command", messageID: secondAssistantID),
            makeCall("run_command", status: .running, messageID: thirdAssistantID)
        ]

        let presentation = try #require(AgentActiveTurnToolCallPresentation.make(
            messages: messages,
            toolCalls: calls,
            isResponding: true
        ))

        #expect(presentation.messageIDs == [firstAssistantID, secondAssistantID, thirdAssistantID])
        #expect(presentation.calls.count == 4)
        #expect(presentation.hidingToolCalls(in: messages[1]).toolCalls.isEmpty)
        #expect(presentation.hidingToolCalls(in: messages[2]) == messages[2])
        #expect(presentation.hidingToolCalls(in: messages[3]).content == "继续检查。")
        #expect(presentation.hidingToolCalls(in: messages[3]).toolCalls.isEmpty)
    }

    @Test("active turn aggregation never crosses the latest user input")
    func testActiveTurnToolCallsStopAtLatestUserInput() throws {
        let previousMessageID = UUID()
        let currentMessageID = UUID()
        let messages = [
            AgentMessage(role: .user, content: "第一轮"),
            AgentMessage(id: previousMessageID, role: .assistant, content: "旧结果"),
            AgentMessage(role: .user, content: "第二轮"),
            AgentMessage(id: currentMessageID, role: .assistant, content: "新结果")
        ]
        let calls = [
            makeCall("run_command", messageID: previousMessageID),
            makeCall("run_command", status: .running, messageID: currentMessageID)
        ]

        let presentation = try #require(AgentActiveTurnToolCallPresentation.make(
            messages: messages,
            toolCalls: calls,
            isResponding: true
        ))

        #expect(presentation.messageIDs == [currentMessageID])
        #expect(presentation.calls.count == 1)
    }

    @Test("AgentToolActivitySummary counts exploration searches and commands")
    func testToolActivitySummaryCountsTurnActivity() {
        let calls = [
            makeCall("read_file", arguments: ["path": .string("README.md")]),
            makeCall("read_file", arguments: ["path": .string("README.md")]),
            makeCall("list_directory", arguments: ["path": .string("Xedit")]),
            makeCall("grep_files", arguments: ["pattern": .string("Agent")]),
            makeCall("git_status"),
            makeCall("run_command", arguments: ["command": .string("git diff --stat")])
        ]

        let summary = AgentToolActivitySummary(calls: calls)

        #expect(summary.readFileCount == 1)
        #expect(summary.listedDirectoryCount == 1)
        #expect(summary.exploredPathCount == 2)
        #expect(summary.searchCount == 1)
        #expect(summary.gitStatusCount == 1)
        #expect(summary.commandCount == 1)
        #expect(summary.explorationText == "已读取 1 个文件 · 已浏览 1 个目录 · 已搜索代码 · 已查看 Git 状态")
        #expect(summary.commandText == "已运行 1 条命令")
    }

    @Test("collapsed live tool summary hides arguments and describes file creation")
    func testCollapsedLiveToolSummaryUsesAggregateDescription() {
        let calls = [
            makeCall("create_file", arguments: ["path": .string("private/episode-16.md")]),
            makeCall("create_file", arguments: ["path": .string("private/episode-17.md")]),
            makeCall("create_file", arguments: ["path": .string("private/episode-18.md")])
        ]

        let summary = AgentCollapsedToolActivitySummary.text(for: calls)

        #expect(summary == "生成了 3 个文件")
        #expect(summary?.contains("private/") == false)
        #expect(summary?.contains("create_file") == false)
    }

    @Test("consecutive file creations merge into one live activity row")
    func testToolCallGroupingMergesConsecutiveFileCreations() {
        let calls = [
            makeCall("create_file", arguments: ["path": .string("episode-1.md")]),
            makeCall("create_file", arguments: ["path": .string("episode-2.md")])
        ]

        let segments = AgentToolCallGrouping.livePresentationSegments(calls)

        #expect(segments.count == 1)
        #expect(segments[0].kind == .fileMutation)
        #expect(segments[0].calls.count == 2)
        #expect(AgentCollapsedToolActivitySummary.text(for: segments[0].calls) == "生成了 2 个文件")
    }

    @Test("interactive patch proposals remain separate")
    func testToolCallGroupingKeepsPatchProposalsStandalone() {
        let calls = [
            makeCall("apply_patch", status: .awaitingConfirm),
            makeCall("apply_patch", status: .awaitingConfirm)
        ]

        let segments = AgentToolCallGrouping.livePresentationSegments(calls)

        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.kind == .applyPatch })
        #expect(segments.allSatisfy { $0.calls.count == 1 })
    }

    @Test("AgentToolCallGrouping never merges ask_user even when adjacent")
    func testToolCallGroupingKeepsAskUserStandalone() {
        let calls = [
            makeCall("ask_user", status: .awaitingUserAnswer),
            makeCall("ask_user", status: .awaitingUserAnswer)
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.kind == .askUser })
        #expect(segments.allSatisfy { $0.count == 1 })
    }

    @Test("AgentToolCallGrouping treats unknown tools as their own .other kind")
    func testToolCallGroupingUnknownKindGroupsBySameName() {
        let calls = [
            makeCall("mystery_tool"),
            makeCall("mystery_tool"),
            makeCall("other_tool")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 1)
    }

    @Test("tool approval clicked before waiter registration is delivered")
    @MainActor
    func testToolApprovalClickedBeforeWaiterRegistrationIsDelivered() async throws {
        let appState = AppState()
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let call = AgentToolCall(
            messageID: UUID(),
            externalID: "call-approve-before-waiter",
            toolName: "terminal_send_command",
            arguments: ["command": .string("kubectl -n tokenhub rollout status deploy/tokenhub")],
            risk: .write,
            status: .pendingApproval
        )
        appState.agentToolCalls = [call]

        appState.approveAgentToolCall(id: call.id)

        #expect(appState.hasPendingAgentToolDecision(id: call.id))
        let decision = await appState.awaitToolDecision(for: runtime, forCallID: call.id)
        if case .approved = decision {
            // Expected path.
        } else {
            Issue.record("Expected approved decision, got \(decision)")
        }
        #expect(!appState.hasPendingAgentToolDecision(id: call.id))
        #expect(runtime.toolCalls.first?.status == .running)
    }

    @Test("switching to workspace access resumes the current eligible approval")
    @MainActor
    func testWorkspaceAccessModeChangeResumesCurrentApproval() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepApprovalModeChange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.interactionMode = .plan
        runtime.currentPlan = AgentPlan(
            status: .executing,
            steps: (1...16).map { step in
                AgentPlan.Step(
                    text: "Step \(step)",
                    status: step < 6 ? .done : (step == 6 ? .inProgress : .pending)
                )
            },
            summary: "Long-running workspace update"
        )
        runtime.approvalMode = .requestEveryTime
        #expect(!runtime.isPlanGateActive)

        let call = AgentToolCall(
            messageID: UUID(),
            externalID: "call-workspace-mode-change",
            toolName: "run_command",
            arguments: ["command": .string("touch mode-change.txt")],
            risk: .write,
            status: .pendingApproval
        )
        runtime.toolCalls = [call]

        let waiter = Task { @MainActor in
            await appState.awaitToolDecision(for: runtime, forCallID: call.id)
        }
        for _ in 0..<3 { await Task.yield() }
        #expect(runtime.toolDecisionWaiterCallID == call.id)

        appState.setAgentApprovalMode(.workspaceAccess)
        for _ in 0..<20 where runtime.toolCalls[0].status == .pendingApproval {
            await Task.yield()
        }
        if runtime.toolCalls[0].status == .pendingApproval {
            appState.denyAgentToolCall(id: call.id)
        }

        let decision = await waiter.value
        if case .approved = decision {
            // Expected path.
        } else {
            Issue.record("Expected Workspace access to approve the current call, got \(decision)")
        }
        #expect(runtime.toolCalls[0].status == .running)
        #expect(runtime.toolCalls[0].approvalSource == .workspaceAccess)
    }

    @Test("switching to workspace access keeps danger confirmation blocked")
    @MainActor
    func testWorkspaceAccessModeChangeKeepsDangerConfirmationBlocked() async throws {
        let appState = AppState()
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.approvalMode = .requestEveryTime

        let call = AgentToolCall(
            messageID: UUID(),
            externalID: "call-danger-mode-change",
            toolName: "run_command",
            arguments: ["command": .string("rm -rf build-output")],
            risk: .danger,
            status: .awaitingConfirm
        )
        runtime.toolCalls = [call]

        appState.setAgentApprovalMode(.workspaceAccess)
        for _ in 0..<5 { await Task.yield() }

        #expect(runtime.toolCalls[0].status == .awaitingConfirm)
        #expect(runtime.toolCalls[0].approvalSource == nil)
    }

    @Test("tool approval resumes only the matching waiter")
    @MainActor
    func testToolApprovalResumesOnlyMatchingWaiter() async throws {
        let appState = AppState()
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        guard let runtime = appState.agentRuntimes[session.id] else {
            Issue.record("Expected runtime for new agent session")
            return
        }

        let first = AgentToolCall(
            messageID: UUID(),
            externalID: "call-first",
            toolName: "run_command",
            arguments: ["command": .string("deploy first")],
            risk: .write,
            status: .pendingApproval
        )
        let second = AgentToolCall(
            messageID: UUID(),
            externalID: "call-second",
            toolName: "run_command",
            arguments: ["command": .string("deploy second")],
            risk: .write,
            status: .pendingApproval
        )
        appState.agentToolCalls = [first, second]

        let firstWait = Task { @MainActor in
            await appState.awaitToolDecision(for: runtime, forCallID: first.id)
        }
        for _ in 0..<3 {
            await Task.yield()
        }

        #expect(runtime.toolDecisionWaiterCallID == first.id)
        appState.approveAgentToolCall(id: second.id)
        #expect(runtime.toolDecisionWaiterCallID == first.id)
        #expect(appState.hasPendingAgentToolDecision(id: second.id))

        appState.approveAgentToolCall(id: first.id)
        let firstDecision = await firstWait.value
        if case .approved = firstDecision {
            // Expected path.
        } else {
            Issue.record("Expected first call to be approved, got \(firstDecision)")
        }

        let secondDecision = await appState.awaitToolDecision(for: runtime, forCallID: second.id)
        if case .approved = secondDecision {
            // Expected path.
        } else {
            Issue.record("Expected second call to be approved, got \(secondDecision)")
        }
    }

    @Test("tool approval actions stay compact without collapsing")
    func testToolApprovalActionMetrics() {
        #expect(AgentApprovalActionMetrics.minimumButtonHeight == 36)
        #expect(AgentApprovalActionMetrics.minimumButtonWidth >= 108)
        #expect(AgentApprovalActionMetrics.spacing >= 10)
        #expect(AgentApprovalActionMetrics.cornerRadius >= 12)
    }

    @Test("command confirmation stays calm, scrollable, and honest about shortcuts")
    func testCommandConfirmationReviewMetrics() {
        #expect(AgentConfirmationReviewMetrics.commandVisibleLineCount == 3)
        #expect(AgentConfirmationReviewMetrics.commandViewportHeight >= 68)
        #expect(AgentConfirmationReviewMetrics.commandViewportHeight <= 76)
        #expect(AgentConfirmationReviewMetrics.actionButtonHeight >= 26)
        #expect(AgentConfirmationReviewMetrics.actionButtonHeight <= 30)
        #expect(AgentConfirmationReviewMetrics.actionButtonMaxWidth >= 112)
        #expect(AgentConfirmationReviewMetrics.actionButtonMaxWidth <= 132)
        #expect(AgentConfirmationReviewMetrics.actionButtonSpacing >= 10)
        #expect(AgentConfirmationReviewMetrics.outerCornerRadius >= 18)
        #expect(AgentConfirmationReviewMetrics.innerCornerRadius >= 12)
        #expect(AgentConfirmationReviewMetrics.horizontalMinimumWidth >= 640)
        #expect(AgentConfirmationReviewMetrics.horizontalMinimumWidth <= 740)
        #expect(
            AgentConfirmationReviewMetrics.usesHorizontalLayout(
                availableWidth: AgentConfirmationReviewMetrics.horizontalMinimumWidth
            )
        )
        #expect(
            !AgentConfirmationReviewMetrics.usesHorizontalLayout(
                availableWidth: AgentConfirmationReviewMetrics.horizontalMinimumWidth - 1
            )
        )
        #expect(AgentConfirmationReviewMetrics.showsKeyboardShortcutHint == false)
    }
}

@Suite
struct AgentAuthorizationNoticeTests {
    @Test("authorization notice copy adapts to command, terminal, and web access")
    func descriptorsAdaptToToolContext() {
        let command = AgentApprovalNoticeCopy.descriptor(
            toolName: "run_command",
            arguments: [
                "command": .string("yarn test"),
                "cwd": .string("/tmp/Xedit"),
            ]
        )
        #expect(command.title == "Agent 准备执行一条命令")
        #expect(command.approveTitle == "继续")
        #expect(command.declineTitle == "暂不执行")
        #expect(command.metadata.contains("在 Xedit 工作区运行"))

        let terminal = AgentApprovalNoticeCopy.descriptor(
            toolName: "terminal_send_command",
            arguments: [
                "command": .string("yarn dev"),
                "terminal_tab_id": .string("sidebar-1"),
            ]
        )
        #expect(terminal.title == "Agent 准备发送命令到终端")
        #expect(terminal.approveTitle == "发送到终端")
        #expect(terminal.metadata.contains("侧边栏可见"))
        #expect(terminal.metadata.contains("指定终端标签"))

        let web = AgentApprovalNoticeCopy.descriptor(
            toolName: "web_fetch",
            arguments: [
                "url": .string("https://example.com"),
                "max_chars": .number(12_000),
            ]
        )
        #expect(web.title == "Agent 想读取一个网页")
        #expect(web.approveTitle == "本次允许")
        #expect(web.declineTitle == "暂不访问")
        #expect(web.metadata.contains("仅发送 GET 请求"))
        #expect(web.metadata.contains { $0.hasPrefix("最多读取 12") })
    }
}
