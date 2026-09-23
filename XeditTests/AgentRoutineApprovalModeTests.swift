import Foundation
import Testing
@testable import WillDeep

/// A scheduled task runs with nobody watching, so the approval mode it runs
/// under is chosen per task (default: smart review) instead of inheriting the
/// composer. These pin the default, the compatibility of tasks saved before the
/// field existed, and that a fired run's conversation actually carries it.
@Suite
@MainActor
struct AgentRoutineApprovalModeTests {
    private static let legacyRoutineJSON = """
    {
      "id" : "6F1C2A43-8F0B-4C55-9A0E-3B1B5D2E7C11",
      "name" : "检查 some.im 线上日志",
      "prompt" : "看看前 24 小时有没有需要注意的日志",
      "workspaceRootPath" : "/Users/rocky/Sites/muchtoken",
      "schedule" : { "kind" : "dailyAt", "hour" : 22, "minute" : 0 },
      "isEnabled" : true,
      "createdAt" : 1787000000,
      "updatedAt" : 1787000000
    }
    """

    @Test("new tasks default to smart review")
    func newTaskDefaultsToSmart() {
        #expect(AgentRoutine().approvalMode == .smart)
        #expect(AgentRoutine(name: "每日简报", prompt: "总结一下").approvalMode == .smart)
    }

    @Test("a task saved before approval modes existed loads as smart review")
    func legacyTaskDecodesAsSmart() throws {
        let routine = try JSONDecoder().decode(
            AgentRoutine.self,
            from: Data(Self.legacyRoutineJSON.utf8)
        )
        #expect(routine.approvalMode == .smart)
        #expect(routine.schedule == .dailyAt(hour: 22, minute: 0))
    }

    @Test("the chosen approval mode survives a save and reload", arguments: AgentApprovalMode.allCases)
    func approvalModeRoundTrips(mode: AgentApprovalMode) throws {
        let original = AgentRoutine(name: "巡检", prompt: "检查服务", approvalMode: mode)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentRoutine.self, from: data)
        #expect(decoded.approvalMode == mode)
        #expect(decoded == original)
    }

    @Test("an approval mode written by a newer version falls back to smart review")
    func unknownModeFallsBackToSmart() throws {
        let json = Self.legacyRoutineJSON.replacingOccurrences(
            of: "\"isEnabled\" : true,",
            with: "\"isEnabled\" : true,\n  \"approvalMode\" : \"someFutureMode\","
        )
        let routine = try JSONDecoder().decode(AgentRoutine.self, from: Data(json.utf8))
        #expect(routine.approvalMode == .smart)
    }

    @Test("a fired run's conversation and runtime use the task's approval mode", arguments: AgentApprovalMode.allCases)
    func runSessionCarriesTaskMode(mode: AgentApprovalMode) {
        let appState = AppState()
        let routine = AgentRoutine(
            name: "检查 some.im 线上日志",
            prompt: "看看前 24 小时有没有需要注意的日志",
            workspaceRootPath: "/Users/rocky/Sites/muchtoken",
            approvalMode: mode
        )

        let session = appState.makeRoutineRunSession(for: routine)

        #expect(session.approvalMode == mode)
        #expect(session.originRoutineID == routine.id)
        #expect(AgentRuntime(session: session).approvalMode == mode)
    }

    @Test("the task card names the approval mode only when it is not smart review")
    func cardBadgeOnlyForNonDefaultModes() {
        #expect(AgentRoutine(approvalMode: .smart).approvalModeBadge == nil)
        for mode in AgentApprovalMode.allCases where mode != .smart {
            #expect(AgentRoutine(approvalMode: mode).approvalModeBadge == mode.displayName)
        }
    }
}
