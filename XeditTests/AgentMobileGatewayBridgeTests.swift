//
//  AgentMobileGatewayBridgeTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentMobileGatewayBridgeTests {
    @Test @MainActor
    func sessionListReturnsStateSnapshot() {
        let session = AgentSession(title: "Phone task", workspaceRootPath: "/tmp/project")
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(id: "cmd-1", type: "session.list"),
            controller: controller,
            now: fixedDate
        )

        #expect(response.id == "cmd-1")
        #expect(response.type == "state.snapshot")
        #expect(response.timestamp == "2026-06-13T12:00:00.000Z")
        guard case .array(let sessions)? = response.payload["sessions"] else {
            Issue.record("sessions payload missing")
            return
        }
        #expect(sessions.count == 1)
        guard case .object(let first)? = sessions.first else {
            Issue.record("session payload is not an object")
            return
        }
        #expect(first["id"]?.stringValue == session.id.uuidString)
        #expect(first["title"]?.stringValue == "Phone task")
        #expect(first["is_active"]?.boolValue == true)
    }

    @Test @MainActor
    func messageSendRoutesTextToSelectedSession() {
        let session = AgentSession(title: "Existing")
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: nil)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-2",
                type: "message.send",
                sessionID: session.id.uuidString,
                payload: ["text": .string("Implement the Android bridge")]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(response.sessionID == session.id.uuidString)
        #expect(controller.selectedSessionIDs == [session.id])
        #expect(controller.sentMessages == [
            FakeMobileGatewayController.SentMessage(
                sessionID: session.id,
                text: "Implement the Android bridge",
                workspacePath: nil
            )
        ])
    }

    @Test @MainActor
    func appStateMessageSendDispatchesIntoAgentRuntime() throws {
        let appState = AppState()
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            appState.stopAgentResponse()
            deleteSessionsCreatedByTest(appState, existingIDs: existingIDs)
        }

        let result = try appState.mobileGatewaySendMessage(
            sessionID: session.id,
            text: "Implement the Android live acceptance gate",
            workspacePath: nil
        )

        #expect(result.sessionID == session.id)
        #expect(appState.activeAgentSessionID == session.id)
        guard let runtime = appState.activeRuntime else {
            Issue.record("Expected active runtime after mobile message send")
            return
        }
        #expect(runtime.input.isEmpty)
        #expect(runtime.isResponding == true)
        #expect(runtime.messages.last?.role == .user)
        #expect(runtime.messages.last?.content == "Implement the Android live acceptance gate")
        #expect(runtime.requestTask != nil)
    }

    @Test @MainActor
    func sessionCreateCallsControllerAndReturnsUpsert() {
        let controller = FakeMobileGatewayController(sessions: [], activeSessionID: nil)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(id: "cmd-3", type: "session.create"),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "session.upsert")
        #expect(controller.createdSessionCount == 1)
        #expect(response.sessionID == controller.sessions.first?.id.uuidString)
    }

    @Test @MainActor
    func messageSendRoutesWorkspacePathToController() {
        let controller = FakeMobileGatewayController(sessions: [], activeSessionID: nil)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-workspace",
                type: "message.send",
                payload: [
                    "text": .string("Create the live acceptance marker"),
                    "workspace_path": .string("/tmp/willdeep-live")
                ]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(controller.sentMessages.last?.text == "Create the live acceptance marker")
        #expect(controller.sentMessages.last?.workspacePath == "/tmp/willdeep-live")
    }

    @Test @MainActor
    func unsupportedCommandReturnsCommandError() {
        let controller = FakeMobileGatewayController(sessions: [], activeSessionID: nil)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(id: "cmd-4", type: "file.read"),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "command.error")
        #expect(response.id == "cmd-4")
        #expect(response.payload["type"]?.stringValue == "file.read")
    }

    @Test @MainActor
    func diffGetReturnsPatchDiffInAckPayload() {
        let session = AgentSession(title: "Patch diff")
        let patchID = UUID()
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        controller.diffs[patchID] = AgentMobileGatewayDiffSnapshot(
            patchID: patchID,
            title: "Agent Patch",
            diff: "diff --git a/App.swift b/App.swift\n+print(\"hello\")",
            sessionID: session.id
        )

        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-diff",
                type: "diff.get",
                sessionID: session.id.uuidString,
                payload: ["patch_id": .string(patchID.uuidString)]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(response.sessionID == session.id.uuidString)
        #expect(response.payload["type"]?.stringValue == "diff.get")
        #expect(response.payload["patch_id"]?.stringValue == patchID.uuidString)
        #expect(response.payload["title"]?.stringValue == "Agent Patch")
        #expect(response.payload["diff"]?.stringValue == "diff --git a/App.swift b/App.swift\n+print(\"hello\")")
    }

    @Test @MainActor
    func snapshotIncludesPendingToolAndPatchApprovals() {
        let session = AgentSession(title: "Approval session")
        let patchID = UUID()
        let jobID = UUID()
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        controller.pendingTools = [
            AgentMobileGatewayToolApprovalSnapshot(
                id: "tool-1",
                title: "run_command",
                summary: "Waiting for approval",
                toolName: "run_command",
                inputPreview: "{\"command\":\"make test\"}",
                requiresConfirmation: true,
                sessionID: session.id
            )
        ]
        controller.pendingPatches = [
            AgentMobileGatewayPatchSnapshot(
                id: patchID,
                title: "Update file",
                summary: "Patch proposal",
                path: "Sources/App.swift",
                stats: "+2 -1",
                sessionID: session.id
            )
        ]
        controller.jobs = [
            AgentMobileGatewayJobSnapshot(
                id: jobID,
                handle: "job_abcdef",
                command: "yarn test",
                status: "running",
                isAlive: true,
                pid: 1234,
                exitCode: nil,
                outputByteCount: 42,
                startedAt: fixedDate,
                finishedAt: nil,
                sessionID: session.id
            )
        ]
        let queuedID = UUID()
        controller.queuedMessages = [
            AgentMobileGatewayQueuedMessageSnapshot(
                id: queuedID,
                textPreview: "Run the Android build after this turn",
                imageCount: 0,
                textAttachmentCount: 0,
                sessionID: session.id
            )
        ]
        let messageID = UUID()
        controller.messages = [
            AgentMobileGatewayMessageSnapshot(
                id: messageID,
                role: "assistant",
                content: "I can update the Android app from the Mac.",
                createdAt: fixedDate,
                sessionID: session.id
            )
        ]
        controller.worktrees = [
            AgentMobileGatewayWorktreeSnapshot(
                repositoryRoot: "/tmp/project",
                fileCount: 2,
                totalAddedLines: 12,
                totalDeletedLines: 3,
                files: [
                    AgentMobileGatewayWorktreeFileSnapshot(
                        path: "app/src/main/java/MainActivity.kt",
                        kind: "M",
                        addedLines: 10,
                        deletedLines: 2
                    ),
                    AgentMobileGatewayWorktreeFileSnapshot(
                        path: "README.md",
                        kind: "A",
                        addedLines: 2,
                        deletedLines: 1
                    )
                ],
                sessionID: session.id
            )
        ]

        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(id: "cmd-5", type: "session.list"),
            controller: controller,
            now: fixedDate
        )

        guard case .array(let tools)? = response.payload["pending_tools"],
              case .object(let tool)? = tools.first else {
            Issue.record("pending_tools payload missing")
            return
        }
        #expect(tool["id"]?.stringValue == "tool-1")
        #expect(tool["requires_confirmation"]?.boolValue == true)
        #expect(tool["session_id"]?.stringValue == session.id.uuidString)

        guard case .array(let patches)? = response.payload["patch_proposals"],
              case .object(let patch)? = patches.first else {
            Issue.record("patch_proposals payload missing")
            return
        }
        #expect(patch["id"]?.stringValue == patchID.uuidString)
        #expect(patch["path"]?.stringValue == "Sources/App.swift")

        guard case .array(let jobs)? = response.payload["jobs"],
              case .object(let job)? = jobs.first else {
            Issue.record("jobs payload missing")
            return
        }
        #expect(job["id"]?.stringValue == jobID.uuidString)
        #expect(job["handle"]?.stringValue == "job_abcdef")
        #expect(job["status"]?.stringValue == "running")
        #expect(job["is_alive"]?.boolValue == true)

        guard case .array(let queuedMessages)? = response.payload["queued_messages"],
              case .object(let queued)? = queuedMessages.first else {
            Issue.record("queued_messages payload missing")
            return
        }
        #expect(queued["id"]?.stringValue == queuedID.uuidString)
        #expect(queued["text_preview"]?.stringValue == "Run the Android build after this turn")
        #expect(queued["session_id"]?.stringValue == session.id.uuidString)

        guard case .array(let messages)? = response.payload["messages"],
              case .object(let message)? = messages.first else {
            Issue.record("messages payload missing")
            return
        }
        #expect(message["id"]?.stringValue == messageID.uuidString)
        #expect(message["role"]?.stringValue == "assistant")
        #expect(message["content"]?.stringValue == "I can update the Android app from the Mac.")
        #expect(message["created_at"]?.stringValue == "2026-06-13T12:00:00.000Z")

        guard case .array(let worktrees)? = response.payload["worktree_changes"],
              case .object(let worktree)? = worktrees.first,
              case .array(let files)? = worktree["files"],
              case .object(let firstFile)? = files.first else {
            Issue.record("worktree_changes payload missing")
            return
        }
        #expect(worktree["repository_root"]?.stringValue == "/tmp/project")
        #expect(worktree["file_count"]?.intValue == 2)
        #expect(worktree["total_added_lines"]?.intValue == 12)
        #expect(worktree["total_deleted_lines"]?.intValue == 3)
        #expect(firstFile["path"]?.stringValue == "app/src/main/java/MainActivity.kt")
        #expect(firstFile["kind"]?.stringValue == "M")
        #expect(firstFile["added_lines"]?.intValue == 10)
    }

    @Test @MainActor
    func messageEventStateEmitsAppendDeltaAndDone() {
        let sessionID = UUID()
        let messageID = UUID()
        let createdAt = fixedDate
        var state = AgentMobileGatewayMessageEventState()

        let first = state.envelopes(
            for: [
                AgentMobileGatewayMessageSnapshot(
                    id: messageID,
                    role: "assistant",
                    content: "Working",
                    createdAt: createdAt,
                    sessionID: sessionID
                )
            ],
            respondingSessionIDs: [sessionID],
            now: fixedDate
        )

        #expect(first.map(\.type) == ["message.append"])
        #expect(first.first?.sessionID == sessionID.uuidString)
        #expect(first.first?.payload["id"]?.stringValue == messageID.uuidString)
        #expect(first.first?.payload["content"]?.stringValue == "Working")

        let delta = state.envelopes(
            for: [
                AgentMobileGatewayMessageSnapshot(
                    id: messageID,
                    role: "assistant",
                    content: "Working on Android",
                    createdAt: createdAt,
                    sessionID: sessionID
                )
            ],
            respondingSessionIDs: [sessionID],
            now: fixedDate
        )

        #expect(delta.map(\.type) == ["message.delta"])
        #expect(delta.first?.payload["message_id"]?.stringValue == messageID.uuidString)
        #expect(delta.first?.payload["delta"]?.stringValue == " on Android")

        let done = state.envelopes(
            for: [
                AgentMobileGatewayMessageSnapshot(
                    id: messageID,
                    role: "assistant",
                    content: "Working on Android",
                    createdAt: createdAt,
                    sessionID: sessionID
                )
            ],
            respondingSessionIDs: [],
            now: fixedDate
        )

        #expect(done.map(\.type) == ["message.done"])
        #expect(done.first?.payload["message_id"]?.stringValue == messageID.uuidString)

        let duplicateDone = state.envelopes(
            for: [
                AgentMobileGatewayMessageSnapshot(
                    id: messageID,
                    role: "assistant",
                    content: "Working on Android",
                    createdAt: createdAt,
                    sessionID: sessionID
                )
            ],
            respondingSessionIDs: [],
            now: fixedDate
        )

        #expect(duplicateDone.isEmpty)
    }

    @Test @MainActor
    func toolDecideRoutesApprovalToController() {
        let session = AgentSession(title: "Tool approval")
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-6",
                type: "tool.decide",
                sessionID: session.id.uuidString,
                payload: [
                    "id": .string("tool-1"),
                    "decision": .string("approve")
                ]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(response.payload["type"]?.stringValue == "tool.decide")
        #expect(controller.toolDecisions == [
            FakeMobileGatewayController.ToolDecision(
                sessionID: session.id,
                toolID: "tool-1",
                approved: true,
                typedConfirmation: nil,
                answer: nil
            )
        ])
    }

    @Test @MainActor
    func toolDecideRejectsInvalidDecision() {
        let session = AgentSession(title: "Tool approval")
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-7",
                type: "tool.decide",
                sessionID: session.id.uuidString,
                payload: [
                    "id": .string("tool-1"),
                    "decision": .string("maybe")
                ]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "command.error")
        #expect(response.payload["message"]?.stringValue == "Decision must be approve or reject.")
        #expect(controller.toolDecisions.isEmpty)
    }

    @Test @MainActor
    func patchDecideRoutesDecisionToController() {
        let session = AgentSession(title: "Patch approval")
        let patchID = UUID()
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-8",
                type: "patch.decide",
                sessionID: session.id.uuidString,
                payload: [
                    "patch_id": .string(patchID.uuidString),
                    "approved": .bool(false)
                ]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(controller.patchDecisions == [
            FakeMobileGatewayController.PatchDecision(sessionID: session.id, patchID: patchID, approved: false)
        ])
    }

    @Test @MainActor
    func jobKillRoutesToController() {
        let session = AgentSession(title: "Jobs")
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-9",
                type: "job.kill",
                sessionID: session.id.uuidString,
                payload: ["job_id": .string("job_abcdef")]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(response.payload["type"]?.stringValue == "job.kill")
        #expect(controller.killedJobs == [
            FakeMobileGatewayController.JobKill(sessionID: session.id, jobID: "job_abcdef")
        ])
    }

    @Test @MainActor
    func fileReadReturnsContentInAckPayload() {
        let session = AgentSession(title: "Files")
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        controller.files["README.md"] = AgentMobileGatewayFileSnapshot(
            path: "README.md",
            content: "# WillDeep\n",
            truncated: false,
            byteCount: 11,
            sessionID: session.id
        )
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-10",
                type: "file.read",
                sessionID: session.id.uuidString,
                payload: [
                    "path": .string("README.md"),
                    "max_bytes": .int(512)
                ]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(response.sessionID == session.id.uuidString)
        #expect(response.payload["type"]?.stringValue == "file.read")
        #expect(response.payload["path"]?.stringValue == "README.md")
        #expect(response.payload["content"]?.stringValue == "# WillDeep\n")
        #expect(response.payload["truncated"]?.boolValue == false)
        #expect(controller.fileReads == [
            FakeMobileGatewayController.FileRead(sessionID: session.id, path: "README.md", maxBytes: 512)
        ])
    }

    @Test @MainActor
    func queueUpdateRoutesActionToController() {
        let session = AgentSession(title: "Queue")
        let queuedID = UUID()
        let controller = FakeMobileGatewayController(sessions: [session], activeSessionID: session.id)
        let response = AgentMobileGatewayCommandRouter.handle(
            AgentMobileGatewayEnvelope(
                id: "cmd-11",
                type: "queue.update",
                sessionID: session.id.uuidString,
                payload: [
                    "action": .string("send_now"),
                    "message_id": .string(queuedID.uuidString)
                ]
            ),
            controller: controller,
            now: fixedDate
        )

        #expect(response.type == "ack")
        #expect(response.sessionID == session.id.uuidString)
        #expect(response.payload["type"]?.stringValue == "queue.update")
        #expect(controller.queueUpdates == [
            FakeMobileGatewayController.QueueUpdate(
                sessionID: session.id,
                action: "send_now",
                messageID: queuedID,
                text: nil
            )
        ])
    }

    @Test @MainActor
    func appStateFileReadUsesWorkspacePathGuard() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_mobile_gateway_workspace_\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_mobile_gateway_outside_\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "inside\n".write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }

        let appState = AppState(rootDirectory: workspace)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer { deleteSessionsCreatedByTest(appState, existingIDs: existingIDs) }

        let file = try appState.mobileGatewayReadFile(
            sessionID: session.id,
            path: "README.md",
            maxBytes: 1024
        )
        #expect(file.path == "README.md")
        #expect(file.content == "inside\n")

        do {
            _ = try appState.mobileGatewayReadFile(
                sessionID: session.id,
                path: outside.path,
                maxBytes: 1024
            )
            Issue.record("Expected absolute path outside workspace to be rejected")
        } catch AgentMobileGatewayCommandError.pathOutsideWorkspace(let path) {
            #expect(path == outside.path)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func appStateToolDecideKeepsConfirmAndAnswerGates() throws {
        let appState = AppState()
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer { deleteSessionsCreatedByTest(appState, existingIDs: existingIDs) }

        let confirmCall = AgentToolCall(
            messageID: UUID(),
            externalID: "call-danger",
            toolName: "run_command",
            arguments: ["command": .string("rm -rf /tmp/example")],
            risk: .danger,
            status: .awaitingConfirm
        )
        appState.agentToolCalls = [confirmCall]

        do {
            _ = try appState.mobileGatewayDecideTool(
                sessionID: session.id,
                toolID: confirmCall.id.uuidString,
                approved: true,
                typedConfirmation: nil,
                answer: nil
            )
            Issue.record("Expected mobile approval without typed confirm to be rejected")
        } catch AgentMobileGatewayCommandError.confirmationRequired(let id) {
            #expect(id == confirmCall.id.uuidString)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let confirmResult = try appState.mobileGatewayDecideTool(
            sessionID: session.id,
            toolID: confirmCall.externalID,
            approved: true,
            typedConfirmation: " confirm ",
            answer: nil
        )
        #expect(confirmResult.sessionID == session.id)

        let askCall = AgentToolCall(
            messageID: UUID(),
            externalID: "call-ask-user",
            toolName: "ask_user",
            arguments: ["question": .string("Which branch should I use?")],
            risk: .userInput,
            status: .awaitingUserAnswer
        )
        appState.agentToolCalls = [askCall]

        do {
            _ = try appState.mobileGatewayDecideTool(
                sessionID: session.id,
                toolID: askCall.externalID,
                approved: true,
                typedConfirmation: nil,
                answer: "   "
            )
            Issue.record("Expected ask_user approval without an answer to be rejected")
        } catch AgentMobileGatewayCommandError.missingAnswer {
            #expect(true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let answerResult = try appState.mobileGatewayDecideTool(
            sessionID: session.id,
            toolID: askCall.id.uuidString,
            approved: true,
            typedConfirmation: nil,
            answer: "Use the current branch"
        )
        #expect(answerResult.sessionID == session.id)
    }

    @Test @MainActor
    func appStatePatchDecideUsesExistingPatchApplyAndReject() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_mobile_gateway_patch_\(UUID().uuidString)")
        let readme = workspace.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "hello\n".write(to: readme, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: workspace)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer { deleteSessionsCreatedByTest(appState, existingIDs: existingIDs) }

        let applyProposal = AgentPatchProposal(
            messageID: UUID(),
            title: "Update README",
            diff: """
            diff --git a/README.md b/README.md
            --- a/README.md
            +++ b/README.md
            @@ -1 +1 @@
            -hello
            +hello from Android
            """
        )
        appState.agentPatchProposals = [applyProposal]

        let applyResult = try appState.mobileGatewayDecidePatch(
            sessionID: session.id,
            patchID: applyProposal.id,
            approved: true
        )

        #expect(applyResult.sessionID == session.id)
        #expect(appState.agentPatchProposals.first?.status == .applied)
        #expect(try String(contentsOf: readme, encoding: .utf8) == "hello from Android\n")

        let rejectProposal = AgentPatchProposal(
            messageID: UUID(),
            title: "Rejected README update",
            diff: """
            diff --git a/README.md b/README.md
            --- a/README.md
            +++ b/README.md
            @@ -1 +1 @@
            -hello from Android
            +rejected content
            """
        )
        appState.agentPatchProposals = [rejectProposal]

        let rejectResult = try appState.mobileGatewayDecidePatch(
            sessionID: session.id,
            patchID: rejectProposal.id,
            approved: false
        )

        #expect(rejectResult.sessionID == session.id)
        #expect(appState.agentPatchProposals.first?.status == .rejected)
        #expect(try String(contentsOf: readme, encoding: .utf8) == "hello from Android\n")
    }

    private var fixedDate: Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 6,
            day: 13,
            hour: 12
        ).date ?? Date(timeIntervalSince1970: 0)
    }

    @MainActor
    private func deleteSessionsCreatedByTest(_ appState: AppState, existingIDs: Set<AgentSession.ID>) {
        for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
            AgentSessionStore.delete(id: id)
        }
    }
}

@MainActor
private final class FakeMobileGatewayController: AgentMobileGatewayControlling {
    struct SentMessage: Equatable {
        var sessionID: UUID?
        var text: String
        var workspacePath: String?
    }

    var sessions: [AgentSession]
    var activeSessionID: UUID?
    var createdSessionCount = 0
    var selectedSessionIDs: [UUID] = []
    var sentMessages: [SentMessage] = []
    var stoppedSessionIDs: [UUID?] = []
    var pendingTools: [AgentMobileGatewayToolApprovalSnapshot] = []
    var pendingPatches: [AgentMobileGatewayPatchSnapshot] = []
    var diffs: [UUID: AgentMobileGatewayDiffSnapshot] = [:]
    var jobs: [AgentMobileGatewayJobSnapshot] = []
    var files: [String: AgentMobileGatewayFileSnapshot] = [:]
    var queuedMessages: [AgentMobileGatewayQueuedMessageSnapshot] = []
    var messages: [AgentMobileGatewayMessageSnapshot] = []
    var worktrees: [AgentMobileGatewayWorktreeSnapshot] = []
    var toolDecisions: [ToolDecision] = []
    var patchDecisions: [PatchDecision] = []
    var killedJobs: [JobKill] = []
    var fileReads: [FileRead] = []
    var queueUpdates: [QueueUpdate] = []

    struct ToolDecision: Equatable {
        var sessionID: UUID?
        var toolID: String
        var approved: Bool
        var typedConfirmation: String?
        var answer: String?
    }

    struct PatchDecision: Equatable {
        var sessionID: UUID?
        var patchID: UUID
        var approved: Bool
    }

    struct JobKill: Equatable {
        var sessionID: UUID?
        var jobID: String
    }

    struct FileRead: Equatable {
        var sessionID: UUID?
        var path: String
        var maxBytes: Int?
    }

    struct QueueUpdate: Equatable {
        var sessionID: UUID?
        var action: String
        var messageID: UUID?
        var text: String?
    }

    init(sessions: [AgentSession], activeSessionID: UUID?) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }

    var mobileGatewaySessions: [AgentSession] { sessions }
    var mobileGatewayActiveSessionID: UUID? { activeSessionID }
    var mobileGatewayPendingToolApprovals: [AgentMobileGatewayToolApprovalSnapshot] { pendingTools }
    var mobileGatewayPendingPatchProposals: [AgentMobileGatewayPatchSnapshot] { pendingPatches }
    var mobileGatewayJobs: [AgentMobileGatewayJobSnapshot] { jobs }
    var mobileGatewayQueuedMessages: [AgentMobileGatewayQueuedMessageSnapshot] { queuedMessages }
    var mobileGatewayRecentMessages: [AgentMobileGatewayMessageSnapshot] { messages }
    var mobileGatewayWorktreeChanges: [AgentMobileGatewayWorktreeSnapshot] { worktrees }

    func mobileGatewayRuntimeIsResponding(sessionID: UUID) -> Bool {
        false
    }

    func mobileGatewayStartSession(workspacePath: String?) -> AgentSession {
        createdSessionCount += 1
        let session = AgentSession(title: "New mobile chat", workspaceRootPath: workspacePath)
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        return session
    }

    func mobileGatewaySelectSession(id: UUID) -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        selectedSessionIDs.append(id)
        activeSessionID = id
        return true
    }

    func mobileGatewaySendMessage(
        sessionID: UUID?,
        text: String,
        workspacePath: String?
    ) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        }
        sentMessages.append(SentMessage(sessionID: sessionID, text: text, workspacePath: workspacePath))
        return .ok(sessionID: sessionID ?? activeSessionID)
    }

    func mobileGatewayStopTurn(sessionID: UUID?) throws -> AgentMobileGatewayCommandResult {
        stoppedSessionIDs.append(sessionID)
        return .ok(sessionID: sessionID ?? activeSessionID)
    }

    func mobileGatewayDecideTool(
        sessionID: UUID?,
        toolID: String,
        approved: Bool,
        typedConfirmation: String?,
        answer: String?
    ) throws -> AgentMobileGatewayCommandResult {
        toolDecisions.append(
            ToolDecision(
                sessionID: sessionID,
                toolID: toolID,
                approved: approved,
                typedConfirmation: typedConfirmation,
                answer: answer
            )
        )
        return .ok(sessionID: sessionID ?? activeSessionID)
    }

    func mobileGatewayDecidePatch(
        sessionID: UUID?,
        patchID: UUID,
        approved: Bool
    ) throws -> AgentMobileGatewayCommandResult {
        patchDecisions.append(PatchDecision(sessionID: sessionID, patchID: patchID, approved: approved))
        return .ok(sessionID: sessionID ?? activeSessionID)
    }

    func mobileGatewayDiff(
        sessionID: UUID?,
        patchID: UUID
    ) throws -> AgentMobileGatewayDiffSnapshot {
        guard let diff = diffs[patchID] else {
            throw AgentMobileGatewayCommandError.patchNotFound(patchID)
        }
        return diff
    }

    func mobileGatewayKillJob(
        sessionID: UUID?,
        jobID: String
    ) throws -> AgentMobileGatewayCommandResult {
        killedJobs.append(JobKill(sessionID: sessionID, jobID: jobID))
        return .ok(sessionID: sessionID ?? activeSessionID, message: "Job killed")
    }

    func mobileGatewayReadFile(
        sessionID: UUID?,
        path: String,
        maxBytes: Int?
    ) throws -> AgentMobileGatewayFileSnapshot {
        fileReads.append(FileRead(sessionID: sessionID, path: path, maxBytes: maxBytes))
        guard let file = files[path] else {
            throw AgentMobileGatewayCommandError.fileNotFound(path)
        }
        return file
    }

    func mobileGatewayUpdateQueue(
        sessionID: UUID?,
        action: String,
        messageID: UUID?,
        text: String?
    ) throws -> AgentMobileGatewayCommandResult {
        queueUpdates.append(
            QueueUpdate(
                sessionID: sessionID,
                action: action,
                messageID: messageID,
                text: text
            )
        )
        return .ok(sessionID: sessionID ?? activeSessionID, message: "Queue updated")
    }
}
