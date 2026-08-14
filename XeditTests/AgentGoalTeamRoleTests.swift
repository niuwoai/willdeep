import Foundation
import Testing
@testable import WillDeep

/// Execution-period roles: binding to unified profiles, tool-policy
/// narrowing, and the cross-validation rule that may not be a prompt promise.
@Suite
@MainActor
struct AgentGoalTeamRoleTests {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-goal-teams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Roster integrity

    @Test("the built-in roster binds real profiles and passes its own validation")
    func builtInRosterIsValid() {
        let profiles = AgentProfile.builtIns
        #expect(AgentGoalTeamRoster.builtIn.validationErrors(profiles: profiles).isEmpty)
    }

    @Test("a role that names itself as validator is rejected")
    func selfValidationIsRejected() {
        var roster = AgentGoalTeamRoster.builtIn
        let index = roster.roles.firstIndex { $0.id == AgentGoalTeamRoster.developerID }!
        roster.roles[index].validatorRoleID = AgentGoalTeamRoster.developerID

        let errors = roster.validationErrors(profiles: AgentProfile.builtIns)
        #expect(errors.contains { $0.contains("cannot validate itself") })
        #expect(!roster.canSignOff(
            roleID: AgentGoalTeamRoster.developerID,
            validatorRoleID: AgentGoalTeamRoster.developerID
        ))
    }

    @Test("only the named validator can sign a role off")
    func signOffRequiresTheNamedValidator() {
        let roster = AgentGoalTeamRoster.builtIn

        #expect(roster.canSignOff(
            roleID: AgentGoalTeamRoster.developerID,
            validatorRoleID: AgentGoalTeamRoster.reviewerID
        ))
        #expect(!roster.canSignOff(
            roleID: AgentGoalTeamRoster.developerID,
            validatorRoleID: AgentGoalTeamRoster.testerID
        ))
        // The reviewer answers to the human goal lead, so no role may sign it
        // off — including itself.
        #expect(!roster.canSignOff(
            roleID: AgentGoalTeamRoster.reviewerID,
            validatorRoleID: AgentGoalTeamRoster.reviewerID
        ))
        #expect(!roster.canSignOff(
            roleID: AgentGoalTeamRoster.reviewerID,
            validatorRoleID: AgentGoalTeamRoster.developerID
        ))
    }

    @Test("an unknown bound profile is reported rather than silently ignored")
    func unknownBoundProfileIsReported() {
        var roster = AgentGoalTeamRoster.builtIn
        roster.roles[0].boundProfileIDs = ["no-such-profile"]

        #expect(roster.validationErrors(profiles: AgentProfile.builtIns)
            .contains { $0.contains("unknown profile") })
    }

    // MARK: Tool policy narrows, never grants

    @Test("read-only strips the shell; read-plus-test keeps it but never the write door")
    func toolPolicyNarrowsCapability() throws {
        let profiles = AgentProfile.builtIns
        let roster = AgentGoalTeamRoster.builtIn

        let reviewer = try #require(roster.role(id: AgentGoalTeamRoster.reviewerID))
        let reviewerTrade = try #require(reviewer.resolvedTrade(profiles: profiles))
        #expect(!reviewerTrade.effectiveToolNames().contains("run_command"))
        #expect(!reviewerTrade.requiresWriteAccess)

        let tester = try #require(roster.role(id: AgentGoalTeamRoster.testerID))
        let testerTrade = try #require(tester.resolvedTrade(profiles: profiles))
        #expect(testerTrade.effectiveToolNames().contains("run_command"))
        #expect(!testerTrade.requiresWriteAccess)
        #expect(!testerTrade.effectiveToolNames(writeAccessGranted: true).contains("apply_patch"))
    }

    @Test("a policy cannot grant what its profile lacks")
    func policyCannotGrantCapability() throws {
        var role = AgentGoalTeamRole(
            id: "greedy",
            boundProfileIDs: [AgentSubagentProfileCatalog.reviewerID],
            toolPolicy: .writeScoped,
            lockedScope: "",
            doneCriteria: "",
            validatorRoleID: AgentGoalTeamRoster.reviewerID,
            memoryFileName: nil
        )
        let trade = try #require(role.resolvedTrade(profiles: AgentProfile.builtIns))

        // writeScoped on a reviewer profile is still a reviewer: the profile
        // has no write door to open.
        #expect(!trade.effectiveToolNames(writeAccessGranted: true).contains("apply_patch"))
        #expect(!trade.effectiveToolNames().contains("run_command"))

        // And the developer's write door only exists because the editor
        // profile carries it.
        role.boundProfileIDs = [AgentSubagentProfileCatalog.editorID]
        let editorTrade = try #require(role.resolvedTrade(profiles: AgentProfile.builtIns))
        #expect(editorTrade.requiresWriteAccess)
    }

    // MARK: Storage

    @Test("the roster round-trips through .codex/goal-teams/roles.json")
    func rosterRoundTrips() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        var roster = AgentGoalTeamRoster.builtIn
        roster.roles[0].lockedScope = "Xedit/AgentProfile*.swift"
        #expect(AgentGoalTeamRoleStore.save(roster, workspacePath: workspace.path))

        let url = AgentGoalTeamRoleStore.rosterURL(workspacePath: workspace.path)
        #expect(url.path.hasSuffix(".codex/goal-teams/roles.json"))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = AgentGoalTeamRoleStore.load(workspacePath: workspace.path)
        #expect(loaded.roles[0].lockedScope == "Xedit/AgentProfile*.swift")
    }

    @Test("a corrupt or missing roster falls back to the built-in one")
    func corruptRosterFallsBack() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(AgentGoalTeamRoleStore.load(workspacePath: workspace.path) == .builtIn)

        let url = AgentGoalTeamRoleStore.rosterURL(workspacePath: workspace.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: url)

        // A hand-edited roster must not make the goal unrunnable.
        #expect(AgentGoalTeamRoleStore.load(workspacePath: workspace.path) == .builtIn)
    }
}
