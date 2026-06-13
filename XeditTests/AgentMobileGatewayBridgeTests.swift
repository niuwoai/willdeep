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

    init(sessions: [AgentSession], activeSessionID: UUID?) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }

    var mobileGatewaySessions: [AgentSession] { sessions }
    var mobileGatewayActiveSessionID: UUID? { activeSessionID }

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
}
