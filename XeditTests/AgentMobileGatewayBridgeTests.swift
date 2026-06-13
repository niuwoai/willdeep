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
            FakeMobileGatewayController.SentMessage(sessionID: session.id, text: "Implement the Android bridge")
        ])
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
}

@MainActor
private final class FakeMobileGatewayController: AgentMobileGatewayControlling {
    struct SentMessage: Equatable {
        var sessionID: UUID?
        var text: String
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
    var toolDecisions: [ToolDecision] = []
    var patchDecisions: [PatchDecision] = []
    var killedJobs: [JobKill] = []
    var fileReads: [FileRead] = []

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

    init(sessions: [AgentSession], activeSessionID: UUID?) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }

    var mobileGatewaySessions: [AgentSession] { sessions }
    var mobileGatewayActiveSessionID: UUID? { activeSessionID }
    var mobileGatewayPendingToolApprovals: [AgentMobileGatewayToolApprovalSnapshot] { pendingTools }
    var mobileGatewayPendingPatchProposals: [AgentMobileGatewayPatchSnapshot] { pendingPatches }
    var mobileGatewayJobs: [AgentMobileGatewayJobSnapshot] { jobs }

    func mobileGatewayRuntimeIsResponding(sessionID: UUID) -> Bool {
        false
    }

    func mobileGatewayStartSession() -> AgentSession {
        createdSessionCount += 1
        let session = AgentSession(title: "New mobile chat")
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

    func mobileGatewaySendMessage(sessionID: UUID?, text: String) throws -> AgentMobileGatewayCommandResult {
        if let sessionID {
            guard mobileGatewaySelectSession(id: sessionID) else {
                throw AgentMobileGatewayCommandError.sessionNotFound(sessionID)
            }
        }
        sentMessages.append(SentMessage(sessionID: sessionID, text: text))
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
}
